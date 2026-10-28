import Cocoa
import SQLite3

// The ChatGPT desktop app (built on Codex) keeps its threads on this Mac in ~/.codex: a SQLite list
// (title, pinned, archived, last change) and a log per thread whose last "task started / complete" line
// says whether it's working. Kikumap only reads them; nothing is changed or sent anywhere.

struct GPTThread {
    let id: String
    let title: String
    let pinned: Bool
    let updated: Date
    let cwd: String
    let running: Bool
    /// When its last task ended (nil while running or when unknown).
    let finished: Date?
}

@MainActor
final class GPTWatcher {
    static let bundleID = "com.openai.codex"
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
    /// The newest state_N.sqlite (the number goes up with the app's data format).
    static var database: URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let n = names.compactMap { s -> Int? in
            guard s.hasPrefix("state_"), s.hasSuffix(".sqlite") else { return nil }
            return Int(s.dropFirst(6).dropLast(7))
        }.max()
        return n.map { home.appendingPathComponent("state_\($0).sqlite") }
    }
    static var available: Bool { database != nil }

    /// On unless turned off in Settings → Access (it only reads files on this Mac, no prompts).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "ChatGPTOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ChatGPTOn") }
    }

    var onThreads: (([GPTThread]) -> Void)?
    private var watcher: FileWatcher?
    private var timer: Timer?
    /// Each log's last lifecycle line, cached by size so a quiet thread isn't read again.
    private var tails: [String: (size: UInt64, started: Bool?, at: Date?)] = [:]
    private var pending = false

    func start() {
        stop()
        guard GPTWatcher.enabled, GPTWatcher.available else { return }
        // ~/.codex changes while ChatGPT works; a slow tick catches tasks that stopped without a word
        watcher = FileWatcher(paths: [GPTWatcher.home.path], latency: 2) { [weak self] in self?.read() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        read()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        timer?.invalidate()
        timer = nil
    }

    func read() {
        guard !pending, let db = GPTWatcher.database else { return }
        pending = true
        let cache = tails
        DispatchQueue.global(qos: .utility).async {
            var cache = cache
            let threads = GPTWatcher.load(db.path, &cache)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending = false
                    self.tails = cache
                    if let t = threads { self.onThreads?(t) }
                }
            }
        }
    }

    /// Threads you started (not helpers), not archived, pinned or changed in the last three days.
    nonisolated private static func load(_ path: String, _ cache: inout [String: (size: UInt64, started: Bool?, at: Date?)]) -> [GPTThread]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let since = Int64((Date().timeIntervalSince1970 - 3 * 86400) * 1000)
        let full = """
            SELECT id, rollout_path, updated_at_ms, COALESCE(NULLIF(name, ''), title), is_pinned, cwd FROM threads
            WHERE archived = 0 AND COALESCE(thread_source, 'user') = 'user' AND (is_pinned = 1 OR updated_at_ms > ?)
            """
        let basic = "SELECT id, rollout_path, updated_at * 1000, title, 0, cwd FROM threads WHERE archived = 0 AND updated_at * 1000 > ?"
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, full, -1, &st, nil) != SQLITE_OK {
            sqlite3_finalize(st)
            st = nil
            guard sqlite3_prepare_v2(db, basic, -1, &st, nil) == SQLITE_OK else { sqlite3_finalize(st); return nil }
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, since)
        func text(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        var out: [GPTThread] = []
        let now = Date()
        while sqlite3_step(st) == SQLITE_ROW {
            let rollout = text(1)
            let size = ((try? FileManager.default.attributesOfItem(atPath: rollout))?[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (try? FileManager.default.attributesOfItem(atPath: rollout))?[.modificationDate] as? Date
            let old = cache[rollout]
            if old?.size != size {
                let grew = old.flatMap { size > $0.size ? $0.size : nil }
                if let t = lastTask(rollout, after: grew) {
                    cache[rollout] = (size, t.started, t.at)
                } else {
                    cache[rollout] = (size, old?.started, old?.at)
                }
            }
            let c = cache[rollout] ?? (size, nil, nil)
            // started and still writing (a task that went quiet for 20 minutes has stopped)
            let running = c.started == true && now.timeIntervalSince(mtime ?? .distantPast) < 20 * 60
            let title = text(3).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(GPTThread(id: text(0), title: title.isEmpty ? "ChatGPT" : title, pinned: sqlite3_column_int(st, 4) != 0,
                                 updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 2)) / 1000),
                                 cwd: text(5), running: running, finished: c.started == false ? c.at : nil))
        }
        return out
    }

    /// The last "task_started" or "task_complete" / "turn_aborted" in a thread's log. Only what was added
    /// since `known` is read; with nothing known, it reads backwards from the end until it finds one.
    nonisolated private static func lastTask(_ path: String, after known: UInt64?) -> (started: Bool?, at: Date?)? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 1 << 20
        var end = size
        while end > 0 {
            // a little overlap, so a line cut at the edge is still seen whole
            let start = max(known.map { $0 > 4096 ? $0 - 4096 : 0 } ?? 0, end > chunk ? end - chunk : 0)
            try? h.seek(toOffset: start)
            guard let data = try? h.read(upToCount: Int(min(end + 4096, size) - start)) else { return nil }
            for line in data.split(separator: 0x0A).reversed() {
                guard let hit = marks.first(where: { line.range(of: $0.0) != nil }) else { continue }
                let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
                return (hit.1, (o?["timestamp"] as? String).flatMap(isoFrac.date(from:)))
            }
            if let k = known, start <= k { return nil }           // nothing new: keep what we had
            if size - start > 64 << 20 { break }                   // don't read huge logs whole
            end = start
        }
        return (nil, nil)
    }

    nonisolated private static let marks: [(Data, Bool)] =
        [("\"type\":\"task_started\"", true), ("\"type\":\"task_complete\"", false), ("\"type\":\"turn_aborted\"", false)]
        .map { (Data($0.0.utf8), $0.1) }

    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Opens the thread in the ChatGPT app.
    static func open(_ threadID: String) {
        guard let u = URL(string: "codex://threads/" + threadID) else { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(u)
        }
    }

    /// A small "GPT" tag that marks ChatGPT threads, the way the terminal marks Claude Code sessions.
    static func mark(_ color: NSColor, height: CGFloat = 12) -> NSImage {
        let font = NSFont.systemFont(ofSize: height * 0.62, weight: .heavy)
        let s = NSAttributedString(string: "GPT", attributes: [.font: font, .foregroundColor: color, .kern: -0.2])
        let w = ceil(s.size().width) + 4
        return NSImage(size: NSSize(width: w, height: height), flipped: false) { r in
            color.setStroke()
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.6, dy: 0.6), xRadius: 2.5, yRadius: 2.5)
            box.lineWidth = 1
            box.stroke()
            let ts = s.size()
            s.draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2 + 0.3))
            return true
        }
    }
}
