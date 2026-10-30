import Cocoa
import SQLite3

// The ChatGPT desktop app (built on Codex) keeps its threads on this Mac in ~/.codex: a SQLite list
// (title, archived, last change), a log per thread whose last "task started / complete" line says
// whether it's working and whose answers carry the plan limits, and the window state with its pins
// and unread dots. Kikumap only reads them; nothing is changed or sent anywhere.

struct GPTThread {
    let id: String
    var title: String
    var pinned: Bool
    let updated: Date
    let cwd: String
    let running: Bool
    /// When its last task ended (nil while running or when unknown).
    let finished: Date?
    /// That task was stopped (Stop pressed), not finished.
    var stopped = false
    /// Where it sits in ChatGPT's pinned section (nil when not pinned there).
    var order: Int? = nil
    /// Started from an editor or a terminal (the Codex extension in VS Code, the Codex CLI), not the ChatGPT app:
    /// "vscode" or "" (somewhere else). Those are shown like Claude Code sessions.
    var editor: String? = nil
    /// Its task started but its log has been quiet for a while (waiting for approval, a long tool call, or stopped
    /// without a word): not shown as running, and its finish is still announced if it comes.
    var quiet = false
    /// When its task log was last written.
    var lastActive: Date? = nil
    /// Started by a script (`codex exec`, the Codex SDK, Codex as an MCP server), not by someone at the keyboard.
    var scripted = false
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
    /// The state_N.sqlite files in use: the one written to last, and any other written in the last hour (the number
    /// goes up with the app's data format, and a Codex elsewhere, VS Code say, may write the next one while the app
    /// still writes the old one: then both are read and put together). ChatGPT's own (`keep`, see `pick`) stays in
    /// use while it was written in the last three days, since the app may sit idle while that other Codex works;
    /// while it isn't known yet, every one written in the last three days is read, so it can be told by its pins.
    static var databases: [URL] { databases(in: home) }
    static func databases(in dir: URL, keep: String? = nil) -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        func file(_ n: Int) -> URL { dir.appendingPathComponent("state_\(n).sqlite") }
        func written(_ n: Int) -> Date {
            ["", "-wal"].compactMap { (try? fm.attributesOfItem(atPath: file(n).path + $0))?[.modificationDate] as? Date }
                .max() ?? .distantPast
        }
        let ns = names.compactMap { s -> Int? in
            guard s.hasPrefix("state_"), s.hasSuffix(".sqlite") else { return nil }
            return Int(s.dropFirst(6).dropLast(7))
        }.sorted { (written($0), $0) > (written($1), $1) }
        guard let first = ns.first else { return [] }
        let recent = ns.dropFirst().filter {
            let age = Date().timeIntervalSince(written($0))
            return age < 3600 || (age < 3 * 86400 && (keep == nil || file($0).path == keep))
        }
        return ([first] + recent).map(file)
    }
    static var database: URL? { databases.first }
    /// Codex's own record of thread names (~/.codex/session_index.jsonl, one line per naming): the name each
    /// thread was given last. Read only when several databases disagree and no pin says which is ChatGPT's.
    nonisolated static func sessionNames(in dir: URL) -> [String: String] {
        guard let h = FileHandle(forReadingAtPath: dir.appendingPathComponent("session_index.jsonl").path) else { return [:] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [:] }
        var best: [String: (name: String, at: String)] = [:]
        for line in text.split(separator: "\n") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = o["id"] as? String, let name = (o["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let at = o["updated_at"] as? String ?? ""
            if (best[id]?.at ?? "") <= at { best[id] = (name, at) }
        }
        return best.mapValues(\.name)
    }

    /// How long since a database (or its write-ahead log) was last written.
    nonisolated static func idle(_ db: URL) -> TimeInterval {
        let at = ["", "-wal"].compactMap { (try? FileManager.default.attributesOfItem(atPath: db.path + $0))?[.modificationDate] as? Date }.max()
        return at.map { Date().timeIntervalSince($0) } ?? .infinity
    }
    static var available: Bool { database != nil }
    /// The older ChatGPT app (before it was built on Codex) is on this Mac: it keeps nothing Kikumap can read.
    static var oldAppOnly: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat") != nil
    }
    /// The current ChatGPT app is installed (whether or not it has been used yet).
    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

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
    /// Reads have failed several times in a row (its database couldn't be opened or read): why.
    private(set) var readError: String?
    private var failures = 0
    /// Its data went away (ChatGPT removed, ~/.codex deleted): that was passed on once.
    private var gone = false
    /// ChatGPT's own database (see `pick`), by path, and the latest pin seen in it. Kept across launches: the app may
    /// sit idle for hours while another Codex writes the newest file, and its pins must not drop meanwhile.
    private var primary: (path: String, pinnedAt: Int64)? = UserDefaults.standard.string(forKey: "GPTPrimaryDB").map {
        ($0, (UserDefaults.standard.object(forKey: "GPTPrimaryPinnedAt") as? NSNumber)?.int64Value ?? 0)
    } {
        didSet {
            guard primary?.path != oldValue?.path || primary?.pinnedAt != oldValue?.pinnedAt else { return }
            UserDefaults.standard.set(primary?.path, forKey: "GPTPrimaryDB")
            UserDefaults.standard.set(primary.map { NSNumber(value: $0.pinnedAt) }, forKey: "GPTPrimaryPinnedAt")
        }
    }
    private var watcher: FileWatcher?
    private var timer: Timer?
    private var cache = Cache()
    private var pending = false
    private var again = false

    /// What's been read, so files that didn't change aren't read again.
    private struct Cache {
        /// Each log's last lifecycle line, by size.
        var tails: [String: Tail] = [:]
        /// The newest logs' last limits line, by size.
        var limits: [String: (size: UInt64, usage: GPTUsage?)] = [:]
        var state: (stamp: Date, window: Window)?
    }

    /// What the window state says: unread dots (nil if they can't be read) and what's pinned.
    private struct Window {
        var unread: Set<String>?
        var pins = Pins()
        /// The file was read and lists its pins: what's pinned is known (an empty list means nothing is pinned).
        var read = false
    }

    /// A log's last lifecycle line: started or ended (nil: none yet), when, and whether Stop ended it.
    typealias Tail = (size: UInt64, started: Bool?, at: Date?, stopped: Bool)

    /// A thread as one database lists it, with what putting several together needs: the project it names, when it
    /// last worked, and its place in that database's Pinned section (nil: not there).
    private struct Row { var t: GPTThread; var project = ""; var recency: Int64 = 0; var spot: Int64?; var named = false }
    /// What one database gave: its threads, the newest logs (by last activity), whether it keeps the pins and when
    /// something was last pinned there (0: nothing is), and the threads it has archived (asked only when several
    /// databases are read).
    private struct Rows {
        var rows: [Row] = []
        var newest: [(String, Int64)] = []
        var dbPins = false
        var pinnedAt: Int64 = 0
        var archived: Set<String> = []
    }
    private enum Loaded { case success(Rows), failure(String) }

    /// ChatGPT's built-in "Pinned" section in its database (the same id in every install).
    nonisolated private static let pinnedSection = "01984de2-8f74-7c91-a3b2-5c5e937cf318"

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
            return projectRank(id, cwd: cwd, project: project)
        }
        func projectRank(_ id: String, cwd: String, project: String = "") -> Int? {
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
            // not installed (yet), or its data is gone: nothing of it is pinned or running; look again now and then,
            // and start once it's there
            reportGone()
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
        lastRead = nil
        readError = nil
        failures = 0
    }

    /// Its data is gone: once, an empty list, so nothing of it stays pinned or running.
    private func reportGone() {
        guard !gone else { return }
        gone = true
        usage = nil
        onThreads?([], nil, true)
    }

    func read() {
        guard !pending else { again = true; return }       // a change came in meanwhile: read once more after
        // (one picked without a pin to go by is a guess: every file written lately is read then)
        let keep = primary.flatMap { $0.pinnedAt > 0 ? $0.path : nil }
        let dbs = GPTWatcher.databases(in: GPTWatcher.home, keep: keep)
        guard !dbs.isEmpty else { reportGone(); return }
        gone = false
        pending = true
        let state = GPTWatcher.home.appendingPathComponent(".codex-global-state.json").path
        let start = cache, was = primary, app = GPTWatcher.installed, codex = GPTWatcher.home
        DispatchQueue.global(qos: .utility).async {
            var c = start
            let window = GPTWatcher.windowState(state, &c.state)
            // every database in use, put together (ChatGPT's own decides); one that can't be read spoils the pass,
            // since a partial list would drop pins
            var loaded: [(path: String, rows: Rows)] = []
            var reason: String?
            for db in dbs {
                switch GPTWatcher.load(db.path, pins: window.pins, archived: dbs.count > 1, &c.tails) {
                case .failure(let why):
                    // (one read only to tell ChatGPT's own by its pins, idle for over an hour: left out, not a failure)
                    if keep == nil && db != dbs.first && GPTWatcher.idle(db) > 3600 { continue }
                    reason = why
                case .success(let r): loaded.append((db.path, r))
                }
            }
            let (k, pinnedAt) = GPTWatcher.pick(loaded, was: was)
            let names = pinnedAt > 0 || loaded.count < 2 ? [:] : GPTWatcher.sessionNames(in: codex)
            let merged = reason == nil ? GPTWatcher.merge(loaded.map(\.rows), main: k, pins: window.pins, byPins: pinnedAt > 0, names: names) : []
            let threads = app ? merged : GPTWatcher.appGone(merged)
            let dbPins = loaded.indices.contains(k) && loaded[k].rows.dbPins
            let newest = loaded.flatMap(\.rows.newest).sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
            let usage = GPTWatcher.limits(Array(newest), &c.limits)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending = false
                    defer { if self.again { self.again = false; self.read() } }
                    guard self.watcher != nil else { return }          // turned off meanwhile
                    self.cache = c
                    if let why = reason {
                        // busy or changing while ChatGPT writes: only a few failures in a row count
                        self.failures += 1
                        if self.failures >= 3 { self.readError = why }
                        return
                    }
                    self.failures = 0
                    self.readError = nil
                    self.lastRead = Date()
                    self.primary = (loaded[k].path, pinnedAt)
                    // never back to an older snapshot (opening an old thread doesn't make its limits current)
                    if let u = usage, u.at >= (self.usage?.at ?? .distantPast) { self.usage = u }
                    // without the app none of its threads is pinned, so a pin missing from the list is gone
                    self.onThreads?(threads, window.unread, window.read || dbPins || !app)
                }
            }
        }
    }

    /// Which database is ChatGPT's own when several are read (the others' pins, names and archive may be old
    /// copies): the one something was last pinned in, as far as seen (so one you unpin everything in stays: another
    /// file's older pins aren't ChatGPT's); if none has pins (or they tie), the one used before, else the one written
    /// last. Also the latest pin seen in it.
    nonisolated private static func pick(_ loaded: [(path: String, rows: Rows)], was: (path: String, pinnedAt: Int64)?) -> (Int, Int64) {
        let at = loaded.map { $0.path == was?.path ? max($0.rows.pinnedAt, was?.pinnedAt ?? 0) : $0.rows.pinnedAt }
        let last = at.max() ?? 0
        let tied = loaded.indices.filter { at[$0] == last }
        return (tied.first { loaded[$0].path == was?.path } ?? tied.first ?? 0, last)
    }

    /// The databases' threads put together. ChatGPT's own (`main`) decides every thread it lists or has archived;
    /// the others add only threads it doesn't list (the newest copy of each), pinned only through a pinned project.
    /// Then the pinned ones are put in ChatGPT's order. `byPins` false: no pin told which file is ChatGPT's (`main`
    /// is a guess), so a thread archived in any of them is archived, and a name given in any of them counts.
    nonisolated private static func merge(_ all: [Rows], main k: Int, pins: Pins, byPins: Bool = true, names: [String: String] = [:]) -> [GPTThread] {
        guard all.indices.contains(k) else { return [] }
        let archived = byPins ? all[k].archived : all.reduce(into: Set<String>()) { $0.formUnion($1.archived) }
        var rows = all[k].rows.filter { !archived.contains($0.t.id) }
        if !byPins {
            // Codex's own record of names (`names`: the one given last, wherever) decides; else a name set in any file
            var other: [String: String] = [:]
            for (j, o) in all.enumerated() where j != k { for r in o.rows where r.named { other[r.t.id] = r.t.title } }
            for i in rows.indices {
                if let n = names[rows[i].t.id] { rows[i].t.title = n; rows[i].named = true }
                else if !rows[i].named, let n = other[rows[i].t.id] { rows[i].t.title = n; rows[i].named = true }
            }
        }
        let decided = Set(rows.map(\.t.id)).union(archived)
        var added: [String: Int] = [:]
        for (j, other) in all.enumerated() where j != k {
            for var r in other.rows where !decided.contains(r.t.id) {
                r.spot = nil
                r.t.order = all[k].dbPins ? pins.projectRank(r.t.id, cwd: r.t.cwd, project: r.project)
                    : pins.rank(r.t.id, cwd: r.t.cwd, project: r.project)
                r.t.pinned = r.t.order != nil
                if let i = added[r.t.id] { if rows[i].t.updated < r.t.updated { rows[i] = r } }
                else { added[r.t.id] = rows.count; rows.append(r) }
            }
        }
        var out = rows.map(\.t)
        if !byPins { for i in out.indices { if let n = names[out[i].id] { out[i].title = n } } }
        // pinned in the database only: after the others, in its order
        let unlisted = out.indices.filter { out[$0].order == 500 }.sorted { (rows[$0].spot ?? 0) < (rows[$1].spot ?? 0) }
        for (n, i) in unlisted.enumerated() { out[i].order = 500 + n }
        // within a pinned project, the latest active first (as ChatGPT lists them)
        let inProjects = out.indices.filter { (out[$0].order ?? 0) >= 1000 }
            .sorted { (out[$0].order!, -rows[$0].recency) < (out[$1].order!, -rows[$1].recency) }
        for (n, i) in inProjects.enumerated() { out[i].order = out[i].order! + n }
        return out
    }

    /// The ChatGPT app isn't on this Mac (any more): its own threads can't be pinned or opened (they come back with
    /// the app); sessions from editors and the terminal stay as they are.
    nonisolated private static func appGone(_ threads: [GPTThread]) -> [GPTThread] {
        threads.map { t in
            guard t.editor == nil else { return t }
            var u = t
            u.pinned = false
            u.order = nil
            return u
        }
    }

    /// Threads you started (not helpers), not archived, pinned or changed in the last three days;
    /// and the logs of the three last changed threads of any kind (for the plan limits). ChatGPT keeps
    /// its pins in the window state (`pins`); older versions kept them in the list. `archived`: also which threads
    /// it has archived.
    nonisolated private static func load(_ path: String, pins: Pins, archived: Bool = false, _ cache: inout [String: Tail]) -> Loaded {
        // read-only, the usual way (SQLite may add its shared-memory file next to the database, as readers do);
        // where that can't be done, the file as it is, and that read only counts if the file didn't change meanwhile
        let first = query(path, immutable: false, pins: pins, archived: archived, &cache)
        if case .success = first { return first }
        let before = stamp(path)
        let second = query(path, immutable: true, pins: pins, archived: archived, &cache)
        if case .success = second, stamp(path) == before { return second }
        return first
    }

    nonisolated private static func stamp(_ path: String) -> String {
        ["", "-wal"].map { s -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: path + s)
            return "\((a?[.size] as? NSNumber)?.int64Value ?? -1)/\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    nonisolated private static func query(_ path: String, immutable: Bool, pins: Pins, archived: Bool, _ cache: inout [String: Tail]) -> Loaded {
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + (immutable ? "?immutable=1" : "?mode=ro")
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) } ?? tr("原因不明", "no reason given")
            sqlite3_close(db)
            let name = (path as NSString).lastPathComponent
            return .failure(tr("打不开 \(name)：", "can't open \(name): ") + why)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        // the columns this version has: each newer one has a stand-in, so one renamed doesn't lose everything
        var cols = Set<String>()
        var info: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(threads)", -1, &info, nil) == SQLITE_OK {
            while sqlite3_step(info) == SQLITE_ROW { if let n = sqlite3_column_text(info, 1) { cols.insert(String(cString: n)) } }
        }
        sqlite3_finalize(info)
        guard cols.contains("id"), cols.contains("rollout_path") else {
            return .failure(tr("它的数据库里没有对话列表，ChatGPT 可能改了格式", "its database has no thread list (ChatGPT changed its format?)"))
        }
        func has(_ c: String) -> Bool { cols.contains(c) }
        let updated = has("updated_at_ms") ? "updated_at_ms" : has("updated_at") ? "updated_at * 1000" : "0"
        let title = has("name") && has("title") ? "COALESCE(NULLIF(name, ''), title)" : has("title") ? "title" : "''"
        let pinned = has("is_pinned") ? "is_pinned" : "0"
        let cwd = has("cwd") ? "COALESCE(cwd, '')" : "''"
        // the last turn (opening a thread changes `updated` but not this; it's 0 when unknown)
        let lastActive = has("recency_at_ms") ? "COALESCE(NULLIF(recency_at_ms, 0), \(updated))" : updated
        let originator = has("originator") ? "COALESCE(originator, '')" : "''"
        let project = has("project_id") ? "COALESCE(project_id, '')" : "''"
        // newer versions keep the pins in the database too, in a built-in "Pinned" section: then that says what's pinned
        let sections = has("thread_section_id")
        let inSection = sections ? "COALESCE(thread_section_id = '\(pinnedSection)', 0)" : "0"
        let position = has("section_position") ? "COALESCE(section_position, 0)" : "0"
        let entered = has("section_entered_at_ms") ? "COALESCE(section_entered_at_ms, 0)" : "0"
        // the section replaces only the threads pinned one by one: those filed in a pinned project still count
        let ids = sections ? Array(Set(pins.projects.flatMap(\.threads))) : Array(pins.threads)
        let roots = has("cwd") ? Array(pins.roots) : [], projects = has("project_id") ? Array(pins.projectIDs) : []
        func marks(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
        // threads you started (not helpers), not archived: pinned, in a pinned project, or changed in the last three days
        var wanted = ["\(pinned) = 1", "\(updated) > ?"]
        if sections { wanted.append("thread_section_id = '\(pinnedSection)'") }
        if !ids.isEmpty { wanted.append("id IN (\(marks(ids.count)))") }
        for _ in roots { wanted.append("cwd = ? OR cwd LIKE ?") }
        if !projects.isEmpty { wanted.append("project_id IN (\(marks(projects.count)))") }
        var filters = ["(" + wanted.joined(separator: " OR ") + ")"]
        if has("archived") { filters.append("archived = 0") }
        if has("thread_source") { filters.append("COALESCE(thread_source, 'user') = 'user'") }
        let named = has("name") ? "COALESCE(name, '') <> ''" : "0"
        let sql = "SELECT id, rollout_path, \(updated), \(title), \(pinned), \(cwd), \(lastActive), \(originator), \(project), \(inSection), \(position), \(entered), \(named) FROM threads WHERE "
            + filters.joined(separator: " AND ")
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            let why = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(st)
            return .failure(tr("读不了它的对话列表：", "can't read its thread list: ") + why)
        }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var k: Int32 = 1
        sqlite3_bind_int64(st, k, Int64((Date().timeIntervalSince1970 - 3 * 86400) * 1000)); k += 1
        func bind(_ v: String) { sqlite3_bind_text(st, k, v, -1, transient); k += 1 }
        ids.forEach(bind)
        for r in roots { bind(r); bind(r + "/%") }
        projects.forEach(bind)
        func text(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        var out = Rows(dbPins: sections)
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
                    cache[rollout] = (size, t.started, t.at, t.stopped)
                } else {
                    cache[rollout] = (size, old?.started, old?.at, old?.stopped ?? false)
                }
            }
            let c = cache[rollout] ?? (size, nil, nil, false)
            // started and still writing; a task quiet for 20 minutes isn't shown as running (but may still finish)
            let recent = now.timeIntervalSince(mtime ?? .distantPast) < 20 * 60
            let name = text(3).trimmingCharacters(in: .whitespacesAndNewlines)
            let id = text(0), folder = text(5)
            var rank: Int?, spot: Int64?
            if sections {
                // in ChatGPT's Pinned section (in the order its window lists them, where it does); else by project
                if sqlite3_column_int(st, 9) != 0 {
                    rank = pins.direct.firstIndex(of: id) ?? 500
                    spot = sqlite3_column_int64(st, 10)
                    out.pinnedAt = max(out.pinnedAt, sqlite3_column_int64(st, 11), 1)
                } else { rank = pins.projectRank(id, cwd: folder, project: text(8)) }
            } else {
                rank = pins.rank(id, cwd: folder, project: text(8))
            }
            var t = GPTThread(id: id, title: name.isEmpty ? "ChatGPT" : name, pinned: sqlite3_column_int(st, 4) != 0 || rank != nil,
                              updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(st, 2)) / 1000),
                              cwd: folder, running: c.started == true && recent, finished: c.started == false ? c.at : nil, order: rank,
                              editor: editor(text(7)))
            t.quiet = c.started == true && !recent
            t.lastActive = mtime
            t.scripted = GPTWatcher.scripted(text(7))
            t.stopped = c.started == false && c.stopped
            out.rows.append(Row(t: t, project: text(8), recency: sqlite3_column_int64(st, 6), spot: spot, named: sqlite3_column_int(st, 12) != 0))
            rc = sqlite3_step(st)
        }
        guard rc == SQLITE_DONE else {      // a read cut short isn't the list
            return .failure(tr("对话列表没读完，它正忙", "its thread list was cut short (busy)"))
        }
        // the logs of the last turns (for the plan limits): by when they last worked, not when they were last opened
        var q: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT rollout_path, \(lastActive) FROM threads ORDER BY \(lastActive) DESC LIMIT 5", -1, &q, nil) == SQLITE_OK {
            while sqlite3_step(q) == SQLITE_ROW { if let p = sqlite3_column_text(q, 0) { out.newest.append((String(cString: p), sqlite3_column_int64(q, 1))) } }
        }
        sqlite3_finalize(q)
        var a: OpaquePointer?
        if archived && has("archived") && sqlite3_prepare_v2(db, "SELECT id FROM threads WHERE archived = 1", -1, &a, nil) == SQLITE_OK {
            while sqlite3_step(a) == SQLITE_ROW { if let p = sqlite3_column_text(a, 0) { out.archived.insert(String(cString: p)) } }
        }
        sqlite3_finalize(a)
        return .success(out)
    }

    /// Which app started a thread, from the name it signs with ("Codex Desktop", "codex_vscode", "codex_cli_rs"…):
    /// nil for the ChatGPT app (also when unsigned), "vscode" for VS Code, "" for another editor or a terminal.
    /// Codex run by a script rather than a person (its own names for those clients).
    nonisolated static func scripted(_ originator: String) -> Bool {
        ["codex_exec", "codex_sdk_ts", "codex_mcp_server", "codex-app-server-sdk"].contains(originator.lowercased())
    }

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

    /// The last "task_started" or "task_complete" / "turn_aborted" in a thread's log (nil: nothing new). A turn
    /// aborted because you pressed Stop ("interrupted") was stopped, not finished.
    nonisolated private static func lastTask(_ path: String, after known: UInt64?) -> (started: Bool?, at: Date?, stopped: Bool)? {
        switch scan(path, after: known, for: marks.map(\.0)) {
        case .unchanged: return nil
        case .none: return (nil, nil, false)
        case .found(let line, let m):
            let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            let reason = (o?["payload"] as? [String: Any])?["reason"] as? String ?? "interrupted"
            return (marks[m].1, (o?["timestamp"] as? String).flatMap(isoFrac.date(from:)), m == 2 && reason == "interrupted")
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
            // it says what's pinned only if it lists pins at all (a version that stopped writing them says nothing)
            w.read = o["pinned-thread-ids"] != nil || o["pinned-project-ids"] != nil
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

    /// Opens the thread in the ChatGPT app (or whatever opens its links); says why not when nothing can.
    static func open(_ threadID: String) {
        guard let u = URL(string: "codex://threads/" + threadID) else { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) ?? NSWorkspace.shared.urlForApplication(toOpen: u) {
            NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            Permissions.alert(tr("打不开：这台 Mac 上没有 ChatGPT", "Can't open it: ChatGPT isn't on this Mac"),
                              tr("这个对话在 ChatGPT 桌面 App 里，装上 App 才能打开。装好后，在 ChatGPT 里置顶的对话也会回到 Kikumap。",
                                 "This chat lives in the ChatGPT desktop app, so it opens only there. Once the app is installed, chats pinned in ChatGPT show in Kikumap again."))
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
