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
    /// Where it sits in ChatGPT's pinned section (nil when not pinned there).
    var order: Int? = nil
    /// Started from an editor or a terminal (the Codex extension in VS Code, the Codex CLI), not the ChatGPT app:
    /// "vscode" or "" (somewhere else). Those are shown like Claude Code sessions.
    var editor: String? = nil
    /// Its task started but its log has been quiet for a while (waiting for approval, a long tool call, or stopped
    /// without a word): not shown as running, and its finish is still announced if it comes.
    var quiet = false
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
    /// The state_N.sqlite in use: the one written to last (the number goes up with the app's data format, but a
    /// newer Codex elsewhere, VS Code say, may make the next one while the app still writes the old one).
    static var database: URL? {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        func written(_ n: Int) -> Date {
            ["", "-wal"].compactMap { (try? fm.attributesOfItem(atPath: home.appendingPathComponent("state_\(n).sqlite" + $0).path))?[.modificationDate] as? Date }
                .max() ?? .distantPast
        }
        let n = names.compactMap { s -> Int? in
            guard s.hasPrefix("state_"), s.hasSuffix(".sqlite") else { return nil }
            return Int(s.dropFirst(6).dropLast(7))
        }.max { (written($0), $0) < (written($1), $1) }
        return n.map { home.appendingPathComponent("state_\($0).sqlite") }
    }
    static var available: Bool { database != nil }

    /// A usage window's name by its length: the 5-hour session, the week, or how long it is.
    static func windowLabel(_ minutes: Int) -> String {
        switch minutes {
        case 300: return tr("会话", "Session")
        case 10080: return tr("本周", "Week")
        case 1..<1440: return tr("\(minutes / 60) 小时", "\(minutes / 60)h")
        case 1440...: return tr("\(minutes / 1440) 天", "\(minutes / 1440)d")
        default: return tr("用量", "Usage")
        }
    }

    /// Where a ChatGPT thread opens: the ChatGPT app, or for a session, its folder in VS Code (or Finder).
    static func openLabel(_ c: Chat) -> String {
        guard c.isCodexSession else { return tr("在 ChatGPT 里打开", "Open in ChatGPT") }
        return c.app == "vscode" ? tr("在 VS Code 里打开", "Open in VS Code") : tr("打开它的文件夹", "Open its folder")
    }

    /// Who did the work, in the app's words: "Claude & ChatGPT" while ChatGPT is read, else "Claude".
    static var who: String { enabled && available ? tr("Claude 和 ChatGPT", "Claude & ChatGPT") : "Claude" }

    /// On unless turned off in Settings → Access (it only reads files on this Mac, no prompts).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "ChatGPTOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ChatGPTOn") }
    }

    /// The threads, the ones ChatGPT shows as unread (nil when it doesn't say), and whether its pins were read.
    var onThreads: (([GPTThread], Set<String>?, Bool) -> Void)?
    /// Plan usage as of the latest answer (nil until one is found).
    private(set) var usage: GPTUsage?
    /// When its files were last read, and when they will be next at the latest (also whenever they change).
    private(set) var lastRead: Date?
    var nextRead: Date? { timer?.fireDate }
    private var watcher: FileWatcher?
    private var timer: Timer?
    private var cache = Cache()
    private var pending = false
    private var again = false

    /// What's been read, so files that didn't change aren't read again.
    private struct Cache {
        /// Each log's last lifecycle line, by size.
        var tails: [String: (size: UInt64, started: Bool?, at: Date?)] = [:]
        /// The newest logs' last limits line, by size.
        var limits: [String: (size: UInt64, usage: GPTUsage?)] = [:]
        var state: (stamp: Date, window: Window)?
    }

    /// What the window state says: unread dots (nil if they can't be read) and what's pinned.
    private struct Window {
        var unread: Set<String>?
        var pins = Pins()
        /// The file was read: what's pinned is known (an empty list means nothing is pinned).
        var read = false
    }

    /// What's pinned in ChatGPT's sidebar, in its order: threads one by one, then projects (folders) with the
    /// threads in them.
    struct Pins {
        /// A pinned project: threads filed in it, its folders, and its ids (old and new: threads may name it).
        struct Project { var threads: Set<String> = []; var roots: Set<String> = []; var ids: Set<String> = [] }
        var direct: [String] = []
        var projects: [Project] = []
        /// Threads filed in some project or moved out of one: a project's folder doesn't pull these in.
        var filed: Set<String> = []
        /// A thread filed in a pinned project, or working in its folder unless filed elsewhere.
        var threads: Set<String> { Set(direct).union(projects.flatMap(\.threads)) }
        var roots: Set<String> { Set(projects.flatMap(\.roots)) }
        var projectIDs: Set<String> { Set(projects.flatMap(\.ids)) }
        /// Pinned alone (its place in that list), or the 1-based number of its pinned project × 1000. A thread is in a
        /// project when filed there, when it names the project, or when it works in one of its folders (or below).
        func rank(_ id: String, cwd: String, project: String = "") -> Int? {
            if let i = direct.firstIndex(of: id) { return i }
            for (k, p) in projects.enumerated() {
                let inFolder = !filed.contains(id) && p.roots.contains { cwd == $0 || cwd.hasPrefix($0 + "/") }
                if p.threads.contains(id) || (!project.isEmpty && p.ids.contains(project)) || inFolder { return 1000 * (k + 1) }
            }
            return nil
        }
    }

    func start() {
        stop()
        guard GPTWatcher.enabled else { return }
        guard GPTWatcher.available else {
            // not installed (yet): look again now and then, and start once it's there
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if GPTWatcher.available { self?.start() } }
            }
            return
        }
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
        guard !pending else { again = true; return }       // a change came in meanwhile: read once more after
        guard let db = GPTWatcher.database else { return }
        pending = true
        let state = GPTWatcher.home.appendingPathComponent(".codex-global-state.json").path
        let start = cache
        DispatchQueue.global(qos: .utility).async {
            var c = start
            let window = GPTWatcher.windowState(state, &c.state)
            let found = GPTWatcher.load(db.path, pins: window.pins, &c.tails)
            let usage = GPTWatcher.limits(found?.newest ?? [], &c.limits)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending = false
                    defer { if self.again { self.again = false; self.read() } }
                    guard self.watcher != nil else { return }          // turned off meanwhile
                    self.cache = c
                    self.lastRead = Date()
                    if let u = usage { self.usage = u }
                    if let t = found?.threads { self.onThreads?(t, window.unread, window.read) }
                }
            }
        }
    }

    /// Threads you started (not helpers), not archived, pinned or changed in the last three days;
    /// and the logs of the three last changed threads of any kind (for the plan limits). ChatGPT keeps
    /// its pins in the window state (`pins`); older versions kept them in the list.
    nonisolated private static func load(_ path: String, pins: Pins, _ cache: inout [String: (size: UInt64, started: Bool?, at: Date?)]) -> (threads: [GPTThread], newest: [String])? {
        // read-only, the usual way (SQLite may add its shared-memory file next to the database, as readers do);
        // where that can't be done, the file as it is, and that read only counts if the file didn't change meanwhile
        if let r = query(path, immutable: false, pins: pins, &cache) { return r }
        let before = stamp(path)
        guard let r = query(path, immutable: true, pins: pins, &cache), stamp(path) == before else { return nil }
        return r
    }

    nonisolated private static func stamp(_ path: String) -> String {
        ["", "-wal"].map { s -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: path + s)
            return "\((a?[.size] as? NSNumber)?.int64Value ?? -1)/\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    nonisolated private static func query(_ path: String, immutable: Bool, pins: Pins,
                                          _ cache: inout [String: (size: UInt64, started: Bool?, at: Date?)]) -> (threads: [GPTThread], newest: [String])? {
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + (immutable ? "?immutable=1" : "?mode=ro")
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        // the columns this version has: each newer one has a stand-in, so one renamed doesn't lose everything
        var cols = Set<String>()
        var info: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &info, nil) == SQLITE_OK {
            while sqlite3_step(info) == SQLITE_ROW { if let n = sqlite3_column_text(info, 1) { cols.insert(String(cString: n)) } }
        }
        sqlite3_finalize(info)
        guard cols.contains("id"), cols.contains("rollout_path") else { return nil }
        func has(_ c: String) -> Bool { cols.contains(c) }
        let updated = has("updated_at_ms") ? "updated_at_ms" : has("updated_at") ? "updated_at * 1000" : "0"
        let title = has("name") && has("title") ? "COALESCE(NULLIF(name, ''), title)" : has("title") ? "title" : "''"
        let pinned = has("is_pinned") ? "is_pinned" : "0"
        let cwd = has("cwd") ? "COALESCE(cwd, '')" : "''"
        let lastActive = has("recency_at_ms") ? "COALESCE(recency_at_ms, \(updated))" : updated
        let originator = has("originator") ? "COALESCE(originator, '')" : "''"
        let project = has("project_id") ? "COALESCE(project_id, '')" : "''"
        let ids = Array(pins.threads), roots = has("cwd") ? Array(pins.roots) : [], projects = has("project_id") ? Array(pins.projectIDs) : []
        func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
        // threads you started (not helpers), not archived: pinned, in a pinned project, or changed in the last three days
        var wanted = ["\(pinned) = 1", "\(updated) > ?"]
        if !ids.isEmpty { wanted.append("id IN (\(marks(ids.count)))") }
        for _ in roots { wanted.append("cwd = ? OR cwd LIKE ?") }
        if !projects.isEmpty { wanted.append("project_id IN (\(marks(projects.count)))") }
        var filters = ["(" + wanted.joined(separator: " OR ") + ")"]
        if has("archived") { filters.append("archived = 0") }
        if has("thread_source") { filters.append("COALESCE(thread_source, 'user') = 'user'") }
        let sql = "SELECT id, rollout_path, \(updated), \(title), \(pinned), \(cwd), \(lastActive), \(originator), \(project) FROM threads WHERE "
            + filters.joined(separator: " AND ")
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { sqlite3_finalize(st); return nil }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var k: Int32 = 1
        sqlite3_bind_int64(st, k, Int64((Date().timeIntervalSince1970 - 3 * 86400) * 1000)); k += 1
        func bind(_ v: String) { sqlite3_bind_text(st, k, v, -1, transient); k += 1 }
        ids.forEach(bind)
        for r in roots { bind(r); bind(r + "/%") }
        projects.forEach(bind)
        func text(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        var out: [GPTThread] = []
        var recency: [String: Int64] = [:]
        let now = Date()
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW {
            let rollout = text(1)
            let attrs = try? FileManager.default.attributesOfItem(atPath: rollout)
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = attrs?[.modificationDate] as? Date
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
            // started and still writing; a task quiet for 20 minutes isn't shown as running (but may still finish)
            let recent = now.timeIntervalSince(mtime ?? .distantPast) < 20 * 60
            let name = text(3).trimmingCharacters(in: .whitespacesAndNewlines)
            let id = text(0), folder = text(5), rank = pins.rank(id, cwd: folder, project: text(8))
            recency[id] = sqlite3_column_int64(st, 6)
            var t = GPTThread(id: id, title: name.isEmpty ? "ChatGPT" : name, pinned: sqlite3_column_int(st, 4) != 0 || rank != nil,
                              updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 2)) / 1000),
                              cwd: folder, running: c.started == true && recent, finished: c.started == false ? c.at : nil, order: rank,
                              editor: editor(text(7)))
            t.quiet = c.started == true && !recent
            out.append(t)
            rc = sqlite3_step(st)
        }
        guard rc == SQLITE_DONE else { return nil }           // a read cut short isn't the list
        // within a pinned project, the latest active first (as ChatGPT lists them)
        let inProjects = out.indices.filter { (out[$0].order ?? 0) >= 1000 }
            .sorted { (out[$0].order!, -(recency[out[$0].id] ?? 0)) < (out[$1].order!, -(recency[out[$1].id] ?? 0)) }
        for (n, i) in inProjects.enumerated() { out[i].order = out[i].order! + n }
        var newest: [String] = []
        var q: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads ORDER BY \(updated) DESC LIMIT 3", -1, &q, nil) == SQLITE_OK {
            while sqlite3_step(q) == SQLITE_ROW { if let p = sqlite3_column_text(q, 0) { newest.append(String(cString: p)) } }
        }
        sqlite3_finalize(q)
        return (out, newest)
    }

    /// Which app started a thread, from the name it signs with ("Codex Desktop", "codex_vscode", "codex_cli_rs"…):
    /// nil for the ChatGPT app (also when unsigned), "vscode" for VS Code, "" for another editor or a terminal.
    nonisolated private static func editor(_ originator: String) -> String? {
        let o = originator.lowercased()
        if o.isEmpty || o.contains("desktop") { return nil }
        return o.contains("vscode") ? "vscode" : ""
    }

    private enum Scan { case found(Data, mark: Int), none, unchanged }

    /// The last line in a log holding one of `marks`. Only what was added since `known` is read; with nothing
    /// known, it reads backwards from the end until it finds one.
    nonisolated private static func scan(_ path: String, after known: UInt64?, for marks: [Data]) -> Scan {
        guard let h = FileHandle(forReadingAtPath: path) else { return .unchanged }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 1 << 20, overlap: UInt64 = 1 << 16       // log lines run to a few KB
        var end = size
        while end > 0 {
            // a little overlap, so a line cut at the edge is still seen whole
            let start = max(known.map { $0 > overlap ? $0 - overlap : 0 } ?? 0, end > chunk ? end - chunk : 0)
            try? h.seek(toOffset: start)
            guard let data = try? h.read(upToCount: Int(min(end + overlap, size) - start)) else { return .unchanged }
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
                if case .found(let line, _) = scan(p, after: grew, for: [limitMark]) {
                    switch parseLimits(line) {
                    case .usage(let n): u = n
                    case .other: break                 // a model's own bucket: the plan's meter stays as it was
                    }
                }
            }
            fresh[p] = (size, u)
        }
        cache = fresh
        return fresh.values.compactMap(\.usage).max { $0.at < $1.at }
    }

    nonisolated private static let limitMark = Data("\"rate_limits\":{".utf8)

    private enum Limits { case usage(GPTUsage), other }

    /// The plan's limits from one log line: its windows (none, on a plan without limits), or `.other` for a bucket
    /// of one model's own ("limit_id" other than "codex"), which isn't the plan's meter.
    nonisolated private static func parseLimits(_ line: Data) -> Limits {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let r = (o["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { return .other }
        if let bucket = r["limit_id"] as? String, bucket != "codex" { return .other }
        let at = (o["timestamp"] as? String).flatMap(isoFrac.date(from:)) ?? .distantPast
        let windows = ["primary", "secondary"].compactMap { k -> GPTUsage.Window? in
            guard let w = r[k] as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            var resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            if resets == nil, let s = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { resets = at.addingTimeInterval(s) }
            return GPTUsage.Window(percent: pct, minutes: (w["window_minutes"] as? NSNumber)?.intValue ?? 0, resets: resets)
        }
        return .usage(GPTUsage(windows: windows.sorted { $0.minutes < $1.minutes }, at: at))
    }

    /// From the window state ChatGPT keeps in ~/.codex: the threads it shows a dot for, and what's pinned in
    /// its sidebar (the last ones read, if it can't be read). Chats pinned on its chat side aren't read: ChatGPT
    /// keeps a copy of them that isn't updated when they're unpinned.
    nonisolated private static func windowState(_ path: String, _ cache: inout (stamp: Date, window: Window)?) -> Window {
        guard let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            return Window(unread: nil, pins: cache?.window.pins ?? Pins())
        }
        if let c = cache, c.stamp == stamp { return c.window }
        var w = Window(unread: nil, pins: cache?.window.pins ?? Pins())
        if let data = FileManager.default.contents(atPath: path),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            w.read = true
            if let state = o["electron-thread-read-state-v1"] as? [String: Any],
               let byAccount = state["unreadByIdentity"] as? [String: [String: [String]]] {
                // the threads on this Mac ("local:" hosts); the others are kept elsewhere and aren't listed here
                w.unread = Set(byAccount.values.flatMap { $0.filter { $0.key.hasPrefix("local") }.values.joined() })
            }
            w.pins = pins(o)
        }
        cache = (stamp, w)
        return w
    }

    /// Threads pinned in ChatGPT's sidebar, and the projects pinned there with what's filed in them: threads
    /// assigned to one, and threads working in its folders that weren't assigned elsewhere or moved out.
    nonisolated private static func pins(_ o: [String: Any]) -> Pins {
        var p = Pins()
        p.direct = o["pinned-thread-ids"] as? [String] ?? []
        let projects = o["pinned-project-ids"] as? [String] ?? []
        guard !projects.isEmpty else { return p }
        // each project by its id, and by the id its newer project list gives it
        var which: [String: Int] = [:]
        for (k, id) in projects.enumerated() { which[id] = k }
        for case let byID as [String: Any] in (o["app-server-project-id-by-legacy-project-id-by-host"] as? [String: Any] ?? [:]).values {
            for (old, new) in byID { if let k = which[old], let n = new as? String { which[n] = k } }
        }
        let local = o["local-projects"] as? [String: Any] ?? [:]
        p.projects = projects.map { Pins.Project(roots: Set((local[$0] as? [String: Any])?["rootPaths"] as? [String] ?? []), ids: [$0]) }
        for (id, k) in which { p.projects[k].ids.insert(id) }
        let movedOut = Set(o["projectless-thread-ids"] as? [String] ?? [])
        p.filed = movedOut
        for (thread, a) in o["thread-project-assignments"] as? [String: Any] ?? [:] {
            guard let project = (a as? [String: Any])?["projectId"] as? String else { continue }
            p.filed.insert(thread)
            if let k = which[project], !movedOut.contains(thread) { p.projects[k].threads.insert(thread) }
        }
        return p
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
