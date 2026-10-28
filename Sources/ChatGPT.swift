import Cocoa
import SQLite3

// The ChatGPT desktop app (built on Codex) keeps its threads on this Mac in ~/.codex: a SQLite list
// (title, archived, last change), a log per thread whose last "task started / complete" line says
// whether it's working and whose answers carry the plan limits, and the window state with its pins
// and unread dots. Kikumap only reads them; nothing is changed or sent anywhere.

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

/// ChatGPT's plan limits (a 5-hour and/or a weekly window), as its latest answer reported them.
struct GPTUsage: Equatable {
    struct Window: Equatable {
        let percent: Double
        let minutes: Int
        let resets: Date?
    }
    let windows: [Window]
    let at: Date
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

    /// The threads, and the ones ChatGPT shows as unread (nil when its window state can't be read).
    var onThreads: (([GPTThread], Set<String>?) -> Void)?
    /// Plan usage as of the latest answer (nil until one is found).
    private(set) var usage: GPTUsage?
    private var watcher: FileWatcher?
    private var timer: Timer?
    private var cache = Cache()
    private var pending = false

    /// What's been read, so files that didn't change aren't read again.
    private struct Cache {
        /// Each log's last lifecycle line, by size.
        var tails: [String: (size: UInt64, started: Bool?, at: Date?)] = [:]
        /// The newest logs' last limits line, by size.
        var limits: [String: (size: UInt64, usage: GPTUsage?)] = [:]
        var state: (stamp: Date, unread: Set<String>?, pinned: Set<String>)?
    }

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
        usage = nil
    }

    func read() {
        guard !pending, let db = GPTWatcher.database else { return }
        pending = true
        let state = GPTWatcher.home.appendingPathComponent(".codex-global-state.json").path
        let start = cache
        DispatchQueue.global(qos: .utility).async {
            var c = start
            let window = GPTWatcher.windowState(state, &c.state)
            let found = GPTWatcher.load(db.path, pinned: window.pinned, &c.tails)
            let usage = GPTWatcher.limits(found?.newest ?? [], &c.limits)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending = false
                    guard self.watcher != nil else { return }          // turned off meanwhile
                    self.cache = c
                    if let u = usage { self.usage = u }
                    if let t = found?.threads { self.onThreads?(t, window.unread) }
                }
            }
        }
    }

    /// Threads you started (not helpers), not archived, pinned or changed in the last three days;
    /// and the logs of the three last changed threads of any kind (for the plan limits). ChatGPT keeps
    /// its pins in the window state (`pinned`); older versions kept them in the list.
    nonisolated private static func load(_ path: String, pinned: Set<String>, _ cache: inout [String: (size: UInt64, started: Bool?, at: Date?)]) -> (threads: [GPTThread], newest: [String])? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let since = Int64((Date().timeIntervalSince1970 - 3 * 86400) * 1000)
        let pins = Array(pinned)
        let listed = pins.isEmpty ? "" : " OR id IN (" + pins.map { _ in "?" }.joined(separator: ",") + ")"
        let full = """
            SELECT id, rollout_path, updated_at_ms, COALESCE(NULLIF(name, ''), title), is_pinned, cwd FROM threads
            WHERE archived = 0 AND COALESCE(thread_source, 'user') = 'user' AND (is_pinned = 1 OR updated_at_ms > ?\(listed))
            """
        let basic = "SELECT id, rollout_path, updated_at * 1000, title, 0, cwd FROM threads WHERE archived = 0 AND (updated_at * 1000 > ?\(listed))"
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, full, -1, &st, nil) != SQLITE_OK {
            sqlite3_finalize(st)
            st = nil
            guard sqlite3_prepare_v2(db, basic, -1, &st, nil) == SQLITE_OK else { sqlite3_finalize(st); return nil }
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, since)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, id) in pins.enumerated() { sqlite3_bind_text(st, Int32(i + 2), id, -1, transient) }
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
            let id = text(0)
            out.append(GPTThread(id: id, title: title.isEmpty ? "ChatGPT" : title, pinned: sqlite3_column_int(st, 4) != 0 || pinned.contains(id),
                                 updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 2)) / 1000),
                                 cwd: text(5), running: running, finished: c.started == false ? c.at : nil))
        }
        var newest: [String] = []
        var q: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads ORDER BY updated_at_ms DESC LIMIT 3", -1, &q, nil) == SQLITE_OK {
            while sqlite3_step(q) == SQLITE_ROW { if let p = sqlite3_column_text(q, 0) { newest.append(String(cString: p)) } }
        }
        sqlite3_finalize(q)
        return (out, newest)
    }

    private enum Scan { case found(Data, mark: Int), none, unchanged }

    /// The last line in a log holding one of `marks`. Only what was added since `known` is read; with nothing
    /// known, it reads backwards from the end until it finds one.
    nonisolated private static func scan(_ path: String, after known: UInt64?, for marks: [Data]) -> Scan {
        guard let h = FileHandle(forReadingAtPath: path) else { return .unchanged }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 1 << 20
        var end = size
        while end > 0 {
            // a little overlap, so a line cut at the edge is still seen whole
            let start = max(known.map { $0 > 4096 ? $0 - 4096 : 0 } ?? 0, end > chunk ? end - chunk : 0)
            try? h.seek(toOffset: start)
            guard let data = try? h.read(upToCount: Int(min(end + 4096, size) - start)) else { return .unchanged }
            for line in data.split(separator: 0x0A).reversed() {
                if let m = marks.firstIndex(where: { line.range(of: $0) != nil }) { return .found(Data(line), mark: m) }
            }
            if let k = known, start <= k { return .unchanged }    // nothing new: keep what we had
            if size - start > 64 << 20 { break }                   // don't read huge logs whole
            end = start
        }
        return .none
    }

    /// The last "task_started" or "task_complete" / "turn_aborted" in a thread's log (nil: nothing new).
    nonisolated private static func lastTask(_ path: String, after known: UInt64?) -> (started: Bool?, at: Date?)? {
        switch scan(path, after: known, for: marks.map(\.0)) {
        case .unchanged: return nil
        case .none: return (nil, nil)
        case .found(let line, let m):
            let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            return (marks[m].1, (o?["timestamp"] as? String).flatMap(isoFrac.date(from:)))
        }
    }

    nonisolated private static let marks: [(Data, Bool)] =
        [("\"type\":\"task_started\"", true), ("\"type\":\"task_complete\"", false), ("\"type\":\"turn_aborted\"", false)]
        .map { (Data($0.0.utf8), $0.1) }

    /// The plan limits as of the newest answer in these logs (each answer's log line carries them).
    nonisolated private static func limits(_ paths: [String], _ cache: inout [String: (size: UInt64, usage: GPTUsage?)]) -> GPTUsage? {
        var fresh: [String: (size: UInt64, usage: GPTUsage?)] = [:]
        for p in paths {
            let size = ((try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.uint64Value ?? 0
            let old = cache[p]
            var u = old?.usage
            if old?.size != size {
                let grew = old.flatMap { size > $0.size ? $0.size : nil }
                if case .found(let line, _) = scan(p, after: grew, for: [limitMark]), let n = parseLimits(line) { u = n }
            }
            fresh[p] = (size, u)
        }
        cache = fresh
        return fresh.values.compactMap(\.usage).max { $0.at < $1.at }
    }

    nonisolated private static let limitMark = Data("\"rate_limits\":{".utf8)

    nonisolated private static func parseLimits(_ line: Data) -> GPTUsage? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let r = (o["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { return nil }
        let at = (o["timestamp"] as? String).flatMap(isoFrac.date(from:)) ?? .distantPast
        let windows = ["primary", "secondary"].compactMap { k -> GPTUsage.Window? in
            guard let w = r[k] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            var resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if resets == nil, let s = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { resets = at.addingTimeInterval(s) }
            return GPTUsage.Window(percent: pct, minutes: (w["window_minutes"] as? NSNumber)?.intValue ?? 0, resets: resets)
        }
        return windows.isEmpty ? nil : GPTUsage(windows: windows.sorted { $0.minutes < $1.minutes }, at: at)
    }

    /// From the window state ChatGPT keeps in ~/.codex: the threads it shows a dot for (nil if that can't
    /// be read) and the ones pinned in its sidebar (the last ones read, if it can't be read).
    nonisolated private static func windowState(_ path: String, _ cache: inout (stamp: Date, unread: Set<String>?, pinned: Set<String>)?) -> (unread: Set<String>?, pinned: Set<String>) {
        guard let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            return (nil, cache?.pinned ?? [])
        }
        if let c = cache, c.stamp == stamp { return (c.unread, c.pinned) }
        var unread: Set<String>?
        var pinned = cache?.pinned ?? []
        if let data = FileManager.default.contents(atPath: path),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let state = o["electron-thread-read-state-v1"] as? [String: Any],
               let byAccount = state["unreadByIdentity"] as? [String: [String: [String]]] {
                unread = Set(byAccount.values.flatMap { $0.values.joined() })
            }
            if let ids = o["pinned-thread-ids"] as? [String] { pinned = Set(ids) }
        }
        cache = (stamp, unread, pinned)
        return (unread, pinned)
    }

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
