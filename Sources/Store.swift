import Cocoa

struct Chat: Codable, Equatable {
    var id: String
    var title: String
    var updated_at: String
    var path: String?
    var source: String?
    var last_note: String?
    /// Pinned in the Claude app (read from its sidebar); nil = not seen there yet.
    var pinned: Bool?
    /// Position in the Claude app's pinned list.
    var pinIndex: Int?
    /// Claude Code sessions: working folder and the app it runs in (bundle id or TERM_PROGRAM).
    var cwd: String?
    var app: String?
    /// Linked to the Claude app (Remote Control): shown through its pinned chat there instead.
    var linked: Bool?

    var isCode: Bool { source == "code" }
    /// A Codex thread started in an editor or a terminal (not the ChatGPT app): shown like a Claude Code session.
    var isCodexSession: Bool { source == "gpt" && app != nil && app != "com.openai.codex" }
    /// A thread in the ChatGPT app.
    var isGPT: Bool { source == "gpt" }
    /// Not a chat in the Claude app (its pins, sidebar and archive don't apply).
    var outsideClaude: Bool { isCode || isGPT }
}

/// A stretch of time when Claude was working on a chat.
struct Interval: Codable {
    var id: String
    var start: String
    var end: String
}

private struct ActivityFile: Codable {
    var intervals: [Interval]
    var open: [String: String]
}

/// Days too old for the timeline, kept as totals for the statistics.
private struct HistoryFile: Codable {
    var days: [String: [String: Double]]       // "2026-10-28" → chat → seconds
    var titles: [String: String]
}

private struct ChatsFile: Codable {
    var refreshed_at: String?
    var chats: [Chat]
}

/// Everything the app knows: chats, what you've read, what's running, and your map.
@MainActor
final class Store {
    let dir: URL
    private(set) var chats: [Chat] = []
    private var index: [String: Int] = [:]
    private(set) var seen: [String: String] = [:]
    var running = Set<String>()
    var axUnread = Set<String>()
    /// ChatGPT threads unread here, following the dot ChatGPT shows (`gptListed` is its own list as last read).
    var gptUnread = Set<String>()
    private var gptListed: Set<String>?
    let map: MapModel
    private var observers: [() -> Void] = []
    private(set) var intervals: [Interval] = []
    private(set) var runStart: [String: String] = [:]
    private var history: [String: [String: Double]] = [:]
    private var historyTitles: [String: String] = [:]

    var chatsURL: URL { dir.appendingPathComponent("data/chats.json") }
    var seenURL: URL { dir.appendingPathComponent("data/seen.json") }
    var rulesURL: URL { dir.appendingPathComponent("data/rules.json") }
    var activityURL: URL { dir.appendingPathComponent("data/activity.json") }
    var historyURL: URL { dir.appendingPathComponent("data/history.json") }
    var logsDir: URL { dir.appendingPathComponent("logs") }

    init() {
        if let p = UserDefaults.standard.string(forKey: "DataDir"), !p.isEmpty {
            dir = URL(fileURLWithPath: p)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClaudeConsole")
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir.appendingPathComponent("data"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        map = MapModel(url: dir.appendingPathComponent("data/map.json"))
        if let d = try? Data(contentsOf: chatsURL), let f = try? JSONDecoder().decode(ChatsFile.self, from: d) {
            chats = f.chats
        }
        if let d = try? Data(contentsOf: seenURL), let s = try? JSONDecoder().decode([String: String].self, from: d) {
            seen = s
        }
        if let d = try? Data(contentsOf: activityURL), let a = try? JSONDecoder().decode(ActivityFile.self, from: d) {
            intervals = a.intervals
            // still open: Kikumap stopped without closing them (a crash, a forced quit). They end when it was last
            // seen running, not now: the time it was away isn't work it saw.
            let alive = UserDefaults.standard.string(forKey: "AliveAt").flatMap(Clock.parse)
                ?? ((try? FileManager.default.attributesOfItem(atPath: activityURL.path))?[.modificationDate] as? Date) ?? Date()
            let end = Clock.iso(min(alive, Date()))
            for (id, start) in a.open { intervals.append(Interval(id: id, start: start, end: max(start, end))) }
        }
        if let d = try? Data(contentsOf: historyURL), let h = try? JSONDecoder().decode(HistoryFile.self, from: d) {
            history = h.days
            historyTitles = h.titles
        }
        reindex()
        let before = map.root.children.count
        writeDefaultRules()
        log("\(Clock.iso()) start · data \(dir.path) · chats \(chats.count) · topics \(before)→\(map.root.children.count)\n", file: "app.log")
    }

    // MARK: change notification

    func observe(_ f: @escaping () -> Void) { observers.append(f) }
    func notify() { for f in observers { f() } }

    // MARK: lookups

    private func reindex() {
        chats.sort { $0.updated_at > $1.updated_at }
        index = [:]
        for (i, c) in chats.enumerated() { index[c.id] = i }
    }

    func chat(_ id: String) -> Chat? { index[id].map { chats[$0] } }

    func isRunning(_ id: String) -> Bool { running.contains(id) }

    func isUnread(_ c: Chat) -> Bool {
        if running.contains(c.id) { return false }
        if axUnread.contains(c.id) || gptUnread.contains(c.id) { return true }
        if c.isGPT && gptListed != nil { return false }       // ChatGPT says which ones are unread
        return !c.updated_at.isEmpty && c.updated_at > (seen[c.id] ?? "")
    }

    func isUnread(id: String) -> Bool {
        guard let c = chat(id) else { return false }
        return isUnread(c)
    }

    /// Only pinned chats are shown — pinned in Claude, or in ChatGPT for its threads. Until the Claude sidebar has
    /// been read, nothing is (the sidebar says why) — never every chat. Claude Code sessions show while they run or
    /// wait for you, for 12 hours after, or for good once you pin them here or file them on the map.
    var pinsKnown: Bool { chats.contains { !$0.outsideClaude && $0.pinned != nil } }
    func isShown(_ c: Chat) -> Bool {
        if c.isCode || c.isCodexSession {
            // linked to the Claude app (Remote Control): shown through Claude's chat — only if that one is pinned
            if c.isCode && c.linked == true && chats.contains(where: { !$0.isCode && $0.pinned == true && $0.title == c.title }) { return false }
            if c.pinned == true || running.contains(c.id) || isUnread(c) || map.placedChats().contains(c.id) { return true }
            guard let d = Clock.parse(c.updated_at) else { return false }
            return Date().timeIntervalSince(d) < 12 * 3600
        }
        return c.pinned == true
    }

    /// Today so far: how long Claude worked on each chat you can see (running ones up to now), longest first.
    func today() -> [(id: String, secs: Double)] {
        let t = worked([Calendar.current.startOfDay(for: Date()), Date()])[0]
        return t.filter { isShown(id: $0.key) }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// How long Claude worked on each chat in each slot bounds[i] ..< bounds[i + 1], running chats up to
    /// now. Chats running side by side share the time (two at once: half each), so a slot never holds more
    /// than its own length and the chats add up to the time Claude was busy. Time older than the timeline's
    /// week comes from the hourly totals, each hour whole in the slot it starts in; from before those there
    /// are only daily totals, left out when the slots are shorter than a day (`wholeDays` false: see
    /// `dailyOnlyUntil`).
    func worked(_ bounds: [Date], wholeDays: Bool = true) -> [[String: Double]] {
        var out = [[String: Double]](repeating: [:], count: max(bounds.count - 1, 0))
        guard let first = bounds.first, let last = bounds.last, !out.isEmpty else { return out }
        func slot(_ d: Date) -> Int? { d >= first && d < last ? bounds.lastIndex { $0 <= d } : nil }
        var runs: [(id: String, a: Date, b: Date)] = []
        func run(_ id: String, _ a: Date?, _ b: Date?) {
            guard let a = a, let b = b, b > first, a < last else { return }
            runs.append((id, max(a, first), min(b, last)))
        }
        for iv in intervals { run(iv.id, Clock.parse(iv.start), Clock.parse(iv.end)) }
        let now = Date()
        for (id, s) in runStart { run(id, Clock.parse(s), now) }
        Store.share(runs) { id, a, b, part in
            var i = slot(a) ?? 0
            while i < out.count && bounds[i] < b {
                let s = max(a, bounds[i]), e = min(b, bounds[i + 1])
                if e > s { out[i][id, default: 0] += e.timeIntervalSince(s) * part }
                i += 1
            }
        }
        for (key, t) in history {
            let hourly = key.count > 10
            guard hourly || wholeDays, let d = (hourly ? Store.hourFormatter : Store.dayFormatter).date(from: key),
                  let i = slot(d) else { continue }
            // folded before time was shared: an hour (a day) never holds more than itself
            let total = t.values.reduce(0, +), most: Double = hourly ? 3600 : 86400
            let scale = total > most ? most / total : 1
            for (id, s) in t { out[i][id, default: 0] += s * scale }
        }
        return out
    }

    /// Runs that overlap share their time: while k chats run at once, each gets 1/k of it. `take` gets each
    /// stretch of one chat's share: (chat, from, to, part).
    static func share(_ runs: [(id: String, a: Date, b: Date)], _ take: (String, Date, Date, Double) -> Void) {
        var edges: [(t: Date, id: String, open: Bool)] = []
        for r in runs where r.b > r.a { edges.append((r.a, r.id, true)); edges.append((r.b, r.id, false)) }
        edges.sort { $0.t != $1.t ? $0.t < $1.t : (!$0.open && $1.open) }     // at one instant, ends before starts
        var active: [String: Int] = [:]        // a chat counts once, even if two of its runs overlap
        var prev: Date?
        for e in edges {
            if let p = prev, e.t > p, !active.isEmpty {
                let part = 1 / Double(active.count)
                for id in active.keys { take(id, p, e.t, part) }
            }
            if e.open {
                active[e.id, default: 0] += 1
            } else if let n = active[e.id] {
                if n <= 1 { active.removeValue(forKey: e.id) } else { active[e.id] = n - 1 }
            }
            prev = e.t
        }
    }

    /// Before this, only daily totals were kept (older versions folded old time by day; nil if none).
    var dailyOnlyUntil: Date? {
        history.keys.filter { $0.count == 10 }.max().flatMap { Store.dayFormatter.date(from: $0) }
            .flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) }
    }

    static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// A chat the archive just started in the Claude app (pinned there too).
    func addImported(id: String, title: String) {
        if let i = index[id] {
            chats[i].title = title
            chats[i].pinned = true
        } else {
            chats.append(Chat(id: id, title: title, updated_at: Clock.iso(), path: "/chat/" + id, source: "sidebar", last_note: nil, pinned: true))
            seen[id] = Clock.iso()
            saveSeen()
            reindex()
        }
        saveChats()
    }

    /// Claude Code sessions can be pinned here (the Claude app can't pin them).
    func setPinned(_ id: String, _ on: Bool) {
        guard let i = index[id] else { return }
        chats[i].pinned = on
        saveChats(); notify()
    }

    /// Waiting on you to approve something, not just finished.
    func needsInput(_ c: Chat) -> Bool {
        isUnread(c) && (c.last_note ?? "").range(of: "input|permission|approve|输入|授权", options: [.regularExpression, .caseInsensitive]) != nil
    }
    func isShown(id: String) -> Bool { chat(id).map(isShown) ?? false }

    var runningChats: [Chat] { chats.filter { running.contains($0.id) && isShown($0) } }
    var unreadChats: [Chat] { chats.filter { isUnread($0) && isShown($0) } }

    func name(_ id: String) -> String { map.aliases[id] ?? chat(id)?.title ?? historyTitles[id] ?? tr("(已删除的对话)", "(deleted chat)") }
    func mapLabel(_ id: String) -> String { map.aliases[id] ?? (chat(id)?.title.strippedPrefix ?? tr("(已删除的对话)", "(deleted chat)")) }

    /// 0 plain, 1 waiting for you, 2 running.
    func state(_ id: String) -> Int { running.contains(id) ? 2 : (isUnread(id: id) ? 1 : 0) }

    func timeLabel(_ c: Chat) -> String {
        if running.contains(c.id) { return tr("进行中", "running") }
        if isUnread(c), let n = c.last_note, n.range(of: "input|permission|输入", options: [.regularExpression, .caseInsensitive]) != nil {
            return tr("需要你操作", "needs you")
        }
        return Clock.ago(c.updated_at)
    }

    /// The highlight of the branch a chat sits in (nil = no colour).
    func branchColor(_ id: String) -> NSColor? { Theme.highlight(map.branchColorKey(ofChat: id)) }

    /// The sidebar: every pinned chat, in the Claude app's order (placing one on the map doesn't remove it).
    /// Claude's pinned chats in Claude's order, then Claude Code sessions in the order they started —
    /// never reshuffled by activity.
    func pinnedList() -> [Chat] {
        chats.enumerated().filter { isShown($0.element) }.sorted {
            (Store.group($0.element), $0.element.pinIndex ?? Int.max, $0.offset) < (Store.group($1.element), $1.element.pinIndex ?? Int.max, $1.offset)
        }.map { $0.element }
    }

    private static func group(_ c: Chat) -> Int { c.isCode || c.isCodexSession ? 1 : (c.isGPT ? 2 : 0) }

    /// Chats not yet placed on the map.
    func unplaced() -> [Chat] {
        let placed = map.placedChats()
        func rank(_ c: Chat) -> Int { running.contains(c.id) ? 2 : (isUnread(c) ? 1 : 0) }
        return chats.filter { !placed.contains($0.id) && isShown($0) }.sorted {
            let a = rank($0), b = rank($1)
            return a != b ? a > b : $0.updated_at > $1.updated_at
        }
    }

    // MARK: read state

    func markSeen(_ ids: [String]) {
        for id in ids {
            let u = chat(id)?.updated_at ?? ""
            seen[id] = u.isEmpty ? Clock.iso() : u
            axUnread.remove(id)
            gptUnread.remove(id)
        }
        saveSeen()
        notify()
    }

    func markAllSeen() { markSeen(unreadChats.map { $0.id }) }

    /// Unread again (from the map): stays until you open the chat in Claude, or mark it read.
    func setUnread(_ ids: [String], _ on: Bool) {
        guard on else { markSeen(ids); return }
        var changed = false
        for id in ids {
            guard let i = index[id], !running.contains(id) else { continue }
            if chats[i].updated_at.isEmpty { chats[i].updated_at = Clock.iso(); changed = true }
            seen[id] = ""
            if chats[i].isGPT { gptUnread.insert(id) }
        }
        if changed { saveChats() }
        saveSeen()
        notify()
    }

    private func saveSeen() {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let d = try? e.encode(seen) { try? d.write(to: seenURL, options: .atomic) }
    }

    private func saveChats() {
        reindex()
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let d = try? e.encode(ChatsFile(refreshed_at: Clock.iso(), chats: chats)) {
            try? d.write(to: chatsURL, options: .atomic)
        }
    }

    // MARK: activity (for the timeline)

    private func saveActivity() {
        let cutoff = Clock.iso(Date().addingTimeInterval(-8 * 86400))
        let old = intervals.filter { $0.end < cutoff }
        if !old.isEmpty { fold(old) }
        intervals.removeAll { $0.end < cutoff }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        if let d = try? e.encode(ActivityFile(intervals: intervals, open: runStart)) { try? d.write(to: activityURL, options: .atomic) }
    }

    /// Intervals leaving the timeline are added to the hourly totals (kept for about a year), so the
    /// statistics can still show any hours of them.
    private func fold(_ old: [Interval]) {
        let cal = Calendar.current
        let runs = old.compactMap { iv -> (id: String, a: Date, b: Date)? in
            guard let a = Clock.parse(iv.start), let b = Clock.parse(iv.end) else { return nil }
            return (iv.id, a, b)
        }
        Store.share(runs) { id, from, b, part in
            var a = from
            while a < b {
                let e = min(b, cal.dateInterval(of: .hour, for: a)?.end ?? b)
                self.history[Store.hourFormatter.string(from: a), default: [:]][id, default: 0] += e.timeIntervalSince(a) * part
                a = e
            }
        }
        for iv in old { historyTitles[iv.id] = name(iv.id) }
        let keep = Store.dayFormatter.string(from: Date().addingTimeInterval(-400 * 86400))
        history = history.filter { $0.key >= keep }
        let ids = Set(history.values.flatMap { $0.keys })
        historyTitles = historyTitles.filter { ids.contains($0.key) }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        if let d = try? e.encode(HistoryFile(days: history, titles: historyTitles)) { try? d.write(to: historyURL, options: .atomic) }
    }

    /// Kikumap is quitting, or the Mac going to sleep: running chats stop counting now (nothing can be seen
    /// while it's away, and time it can't see isn't counted).
    func closeRuns(at when: Date) {
        guard !runStart.isEmpty else { return }
        let end = Clock.iso(when)
        for (id, start) in runStart { intervals.append(Interval(id: id, start: start, end: max(start, end))) }
        runStart = [:]
        saveActivity()
    }

    /// The Mac woke up: chats still running count again from now (the next read says whether they still are).
    func resumeRuns(at when: Date) {
        let now = Clock.iso(when)
        var changed = false
        for id in running where runStart[id] == nil { runStart[id] = now; changed = true }
        if changed { saveActivity() }
    }

    /// Records when chats start and stop running.
    private func track(_ nowRunning: Set<String>, at now: String) {
        var changed = false
        for id in nowRunning where runStart[id] == nil {
            runStart[id] = now; changed = true
        }
        for (id, start) in runStart where !nowRunning.contains(id) {
            intervals.append(Interval(id: id, start: start, end: now))
            runStart.removeValue(forKey: id)
            changed = true
        }
        if changed { saveActivity() }
    }

    // MARK: events

    enum Event { case finished(String), needsInput(String) }

    /// Claude posted notifications ("done", "needs your input").
    func apply(_ notes: [Notif]) -> [Event] {
        var events: [Event] = []
        for n in notes {
            let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // "Claude is done using your computer." and similar carry no chat title
            if title.isEmpty || title.lowercased() == "claude" { continue }
            let when = Clock.iso(n.date)
            var i = n.chatId.flatMap { index[$0] }
            if i == nil { i = chats.firstIndex { $0.title == title } }
            let id: String
            if let i = i {
                if chats[i].updated_at < when { chats[i].updated_at = when }
                chats[i].title = title
                chats[i].last_note = n.body
                id = chats[i].id
            } else {
                id = n.chatId ?? ("n-" + Store.fnv(title))
                chats.append(Chat(id: id, title: title, updated_at: when, path: nil, source: "notification", last_note: n.body))
            }
            running.remove(id)
            if let start = runStart.removeValue(forKey: id) {
                intervals.append(Interval(id: id, start: start, end: when))
                saveActivity()
            }
            let input = n.body.range(of: "input|permission|输入", options: [.regularExpression, .caseInsensitive]) != nil
            events.append(input ? .needsInput(id) : .finished(id))
            reindex()
        }
        if !notes.isEmpty { saveChats(); notify() }
        return events.filter(shown)
    }

    struct Rules {
        var running: NSRegularExpression?
        var unread: NSRegularExpression?
        var current: NSRegularExpression?
        var markFinishedUnread = true
    }

    func writeDefaultRules() {
        if FileManager.default.fileExists(atPath: rulesURL.path) { return }
        let r: [String: Any] = [
            "_about": "Regexes matched against the sidebar flags in logs/claude-sidebar.txt. Changes apply on the next scan.",
            "running": "(?i)(AXProgressIndicator|AXBusyIndicator|busy=1|spinner|animate-spin|generating|thinking|responding|running|in progress|正在)",
            "unread": "(?i)(unread|未读)",
            "current": "(?i)(sel=1|cur=page|cur=true|cur=1)",
            "markFinishedUnread": true,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: rulesURL)
        }
    }

    func loadRules() -> Rules {
        var r = Rules()
        guard let d = try? Data(contentsOf: rulesURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return r }
        func rx(_ k: String) -> NSRegularExpression? {
            guard let s = o[k] as? String, !s.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: s)
        }
        r.running = rx("running"); r.unread = rx("unread"); r.current = rx("current")
        if let b = o["markFinishedUnread"] as? Bool { r.markFinishedUnread = b }
        return r
    }

    static func matches(_ rx: NSRegularExpression?, _ s: String) -> Bool {
        guard let rx = rx else { return false }
        return rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// The Claude app quit: nothing is running any more (not "finished" — no sound, no unread).
    func clearRunning() {
        let code = Set(chats.filter { $0.outsideClaude }.map { $0.id })
        let keep = running.intersection(code)        // Claude Code sessions and ChatGPT don't live in the Claude app
        guard running != keep || !axUnread.isEmpty else { return }
        track(keep, at: Clock.iso())
        running = keep
        axUnread = []
        notify()
    }

    // MARK: Claude Code

    /// Events from the Claude Code hooks. Returns sounds to play; `needsTitle` gets sessions whose
    /// name should be (re)read from their transcript.
    func apply(code evs: [CodeEvent], needsTitle: (String, String) -> Void) -> [Event] {
        var events: [Event] = []
        var changed = false, seenChanged = false
        for e in evs {
            let id = "cc-" + e.session
            if index[id] == nil {
                guard e.name != "SessionEnd" else { continue }
                let folder = (e.cwd as NSString).lastPathComponent
                chats.append(Chat(id: id, title: folder.isEmpty ? "Claude Code" : folder, updated_at: "", path: nil,
                                  source: "code", last_note: nil, cwd: e.cwd.isEmpty ? nil : e.cwd, app: e.app.isEmpty ? nil : e.app))
                reindex()
                changed = true
            }
            guard let i = index[id] else { continue }
            if !e.app.isEmpty && chats[i].app != e.app { chats[i].app = e.app; changed = true }
            if !e.cwd.isEmpty && chats[i].cwd != e.cwd { chats[i].cwd = e.cwd; changed = true }
            let when = Clock.iso(e.time)
            switch e.name {
            case "UserPromptSubmit":
                running.insert(id)
                seen[id] = when; seenChanged = true                // you just wrote to it, so you've seen it
                chats[i].last_note = nil
                needsTitle(id, e.transcript)
            case "PostToolUse":
                running.insert(id)                                  // e.g. carrying on after you approved something
            case "Notification":
                // "needs your permission" → waiting on you; the idle reminder after a finish adds nothing
                if e.message.range(of: "permission|approve|needs your|授权", options: [.regularExpression, .caseInsensitive]) != nil {
                    running.remove(id)
                    chats[i].updated_at = when
                    chats[i].last_note = e.message
                    events.append(.needsInput(id))
                }
            case "Stop":
                running.remove(id)
                chats[i].updated_at = when
                chats[i].last_note = nil
                events.append(.finished(id))
                needsTitle(id, e.transcript)
            case "SessionEnd":
                running.remove(id)
            default: break
            }
            changed = true
        }
        track(running, at: Clock.iso())
        if changed { saveChats() }
        if seenChanged { saveSeen() }
        if changed || seenChanged { notify() }
        return events.filter(shown)
    }

    // MARK: ChatGPT

    /// The ChatGPT app's threads, read from ~/.codex. Returns sounds to play. Pins follow ChatGPT's.
    /// `pinsRead`: ChatGPT's window state, where it keeps its pins, was read (so a pin missing from it is gone).
    func apply(gpt threads: [GPTThread], unread: Set<String>?, pinsRead: Bool = true, front: Bool) -> [Event] {
        var events: [Event] = []
        var changed = false, seenChanged = false, dotsChanged = false
        let now = Clock.iso()
        for t in threads {
            let id = "gpt-" + t.id
            guard let i = index[id] else {
                // already there before Kikumap saw it: not unread (unless ChatGPT's own list says so)
                chats.append(Chat(id: id, title: t.title, updated_at: Clock.iso(t.finished ?? t.updated), path: nil, source: "gpt",
                                  last_note: nil, pinned: t.pinned ? true : nil, cwd: t.cwd.isEmpty ? nil : t.cwd,
                                  app: t.editor.map { $0.isEmpty ? "codex-cli" : $0 } ?? GPTWatcher.bundleID))
                chats[chats.count - 1].pinIndex = t.order
                seen[id] = Clock.iso(t.finished ?? t.updated)
                if t.running { running.insert(id) }
                reindex()
                changed = true; seenChanged = true
                continue
            }
            if chats[i].title != t.title { chats[i].title = t.title; changed = true }
            if (chats[i].pinned == true) != t.pinned { chats[i].pinned = t.pinned ? true : nil; changed = true }
            if chats[i].pinIndex != t.order { chats[i].pinIndex = t.order; changed = true }      // ChatGPT's order
            let app = t.editor.map { $0.isEmpty ? "codex-cli" : $0 } ?? GPTWatcher.bundleID
            if chats[i].app != app { chats[i].app = app; changed = true }
            if t.running && !running.contains(id) {
                running.insert(id)
                seen[id] = now; seenChanged = true                  // you just asked it something
                gptUnread.remove(id)
                changed = true
            } else if !t.running && running.contains(id) {
                running.remove(id)
                let when = Clock.iso(t.finished ?? Date())
                chats[i].updated_at = when
                if t.finished != nil {
                    events.append(.finished(id))
                    if front { seen[id] = when; seenChanged = true }   // you were looking at ChatGPT (when its own list can't be read)
                    // still unread in ChatGPT, and new again; a session in an editor, until you open it or ask again
                    if gptListed?.contains(id) == true || chats[i].isCodexSession { gptUnread.insert(id) }
                }
                changed = true
            } else if !t.running, let f = t.finished.map(Clock.iso), f > chats[i].updated_at {
                chats[i].updated_at = f                             // finished while Kikumap wasn't watching
                changed = true
            }
        }
        // archived or gone from the list: no longer running
        let listed = Set(threads.map { "gpt-" + $0.id })
        for id in running where id.hasPrefix("gpt-") && !listed.contains(id) { running.remove(id); changed = true }
        // unpinned or deleted in ChatGPT, so no longer listed: no longer pinned here either
        for i in chats.indices where pinsRead && chats[i].isGPT && chats[i].pinned == true && !listed.contains(chats[i].id) {
            chats[i].pinned = nil; changed = true
        }
        // ChatGPT's own unread dots: one that appears there is unread here too, one read there is read here
        // (marking it read here holds until ChatGPT has something new)
        if let list = unread.map({ Set($0.map { "gpt-" + $0 }) }), list != gptListed {
            let before = gptListed ?? []
            gptUnread.formUnion(list.subtracting(before))
            gptUnread.subtract(before.subtracting(list))
            gptListed = list
            dotsChanged = true
        }
        if changed {
            track(running, at: now)
            saveChats()
        }
        if seenChanged { saveSeen() }
        if changed || seenChanged || dotsChanged { notify() }
        return events.filter(shown)
    }

    /// ChatGPT was turned off: forget its threads' running and unread state.
    func clearGPT() {
        let before = running
        running = running.filter { !$0.hasPrefix("gpt-") }
        let dots = !gptUnread.isEmpty || gptListed != nil
        gptUnread = []
        gptListed = nil
        if running != before { track(running, at: Clock.iso()) }
        if running != before || dots { notify() }
    }

    /// The name Claude Code gave the session (or yours, if you renamed it there).
    func setCodeInfo(_ id: String, title: String?, linked: Bool) {
        guard let i = index[id] else { return }
        let t = title ?? chats[i].title
        guard chats[i].title != t || (chats[i].linked ?? false) != linked else { return }
        chats[i].title = t
        chats[i].linked = linked ? true : nil
        saveChats(); notify()
    }

    /// A chat first known only from a notification ("n-…") turned up in the sidebar: give it the real id.
    private func adopt(_ l: AXLink) -> Bool {
        guard !l.title.isEmpty, let i = chats.firstIndex(where: { $0.id.hasPrefix("n-") && $0.title == l.title }) else { return false }
        let old = chats[i].id
        chats[i].id = l.id
        chats[i].path = l.path.isEmpty ? nil : l.path
        if let p = l.pinned { chats[i].pinned = p }
        if let s = seen.removeValue(forKey: old) { seen[l.id] = s; saveSeen() }
        map.renameChat(old, to: l.id)
        reindex()
        return true
    }

    /// Renamed in Claude (seen while open, so its address is known). The copy picked up under the new
    /// name before that — an "n-" id — is folded in, with its place on the map.
    private func retitle(_ i: Int, _ title: String) {
        let id = chats[i].id
        chats[i].title = title
        guard let j = chats.firstIndex(where: { $0.id.hasPrefix("n-") && $0.title == title }) else { return }
        let dup = chats[j].id
        let placed = map.placedChats()
        if placed.contains(dup) && !placed.contains(id) { map.renameChat(dup, to: id) }
        if !map.placedChats().contains(dup) {
            chats.remove(at: j)
            seen.removeValue(forKey: dup)
            reindex()
        }
    }

    /// The Claude app's sidebar was read: which chats run, which are unread, which one is open.
    func apply(scan links: [AXLink], claudeFront: Bool, noPins: Bool = false) -> [Event] {
        // An empty read means the sidebar is hidden or still loading, not that everything finished; unless the
        // list was read whole and is empty: every chat is gone, so nothing is pinned any more
        guard !links.isEmpty else {
            var changed = false
            for i in chats.indices where noPins && !chats[i].outsideClaude && chats[i].pinned == true { chats[i].pinned = false; changed = true }
            if changed { saveChats(); notify() }
            return []
        }
        let rules = loadRules()
        var nowRunning = Set<String>(), nowUnread = Set<String>()
        var current: String?
        for l in links {
            if Store.matches(rules.running, l.flags) { nowRunning.insert(l.id) }
            if Store.matches(rules.unread, l.flags) { nowUnread.insert(l.id) }
            if current == nil && Store.matches(rules.current, l.flags) { current = l.id }
        }
        let now = Clock.iso()
        var changed = false, seenChanged = false
        var events: [Event] = []
        for l in links {
            if let i = index[l.id] {
                if (chats[i].path ?? "").isEmpty && !l.path.isEmpty { chats[i].path = l.path; changed = true }
                if let p = l.pinned, chats[i].pinned != p { chats[i].pinned = p; changed = true }
                if !l.title.isEmpty && chats[i].title != l.title && !l.id.hasPrefix("n-") && !chats[i].outsideClaude {
                    retitle(i, l.title); changed = true
                }
            } else if adopt(l) {
                changed = true
            } else if !l.title.isEmpty {
                let active = nowRunning.contains(l.id) || nowUnread.contains(l.id)
                chats.append(Chat(id: l.id, title: l.title, updated_at: active ? now : "", path: l.path, source: "sidebar", last_note: nil, pinned: l.pinned))
                index[l.id] = chats.count - 1
                changed = true
            }
        }
        // pinned order, as in the Claude app
        let pinnedIDs = links.filter { $0.pinned == true }.map { $0.id }
        if !pinnedIDs.isEmpty || noPins {
            for (n, id) in pinnedIDs.enumerated() { if let i = index[id], chats[i].pinIndex != n { chats[i].pinIndex = n; changed = true } }
            // the Pinned section was read whole: anything else is no longer pinned (unpinned or deleted in Claude)
            let pinnedSet = Set(pinnedIDs)
            for i in chats.indices where !chats[i].outsideClaude && chats[i].pinned == true && !pinnedSet.contains(chats[i].id) {
                chats[i].pinned = false; changed = true
            }
        }
        // the sidebar only lists recent chats: one that scrolled off it is unchanged, not finished or read
        let listed = Set(links.map { $0.id })
        // finished while you weren't looking at it → waiting for you
        for id in running.subtracting(nowRunning) where listed.contains(id) {
            guard let i = index[id] else { continue }
            if claudeFront && current == id {
                seen[id] = now; seenChanged = true
            } else if rules.markFinishedUnread {
                chats[i].updated_at = now; changed = true
                events.append(.finished(id))
            }
        }
        // read inside the Claude app → read here too
        for id in axUnread.subtracting(nowUnread) where !nowRunning.contains(id) && listed.contains(id) {
            if let i = index[id] {
                let u = chats[i].updated_at
                seen[id] = u.isEmpty ? now : max(u, seen[id] ?? ""); seenChanged = true
            }
        }
        if claudeFront, let c = current, let i = index[c] {
            let u = chats[i].updated_at
            if !u.isEmpty && u > (seen[c] ?? "") { seen[c] = u; seenChanged = true }
        }
        nowRunning.formUnion(running.subtracting(listed))
        nowUnread.formUnion(axUnread.subtracting(listed))
        let stateChanged = running != nowRunning || axUnread != nowUnread
        track(nowRunning, at: now)
        running = nowRunning
        axUnread = nowUnread
        if changed { saveChats() }
        if seenChanged { saveSeen() }
        if changed || seenChanged || stateChanged { notify() }
        return events.filter(shown)
    }

    /// Sounds only for chats you can see (pinned).
    private func shown(_ e: Event) -> Bool {
        switch e { case .finished(let id), .needsInput(let id): return isShown(id: id) }
    }

    nonisolated static func fnv(_ s: String) -> String {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return String(format: "%08x", h)
    }

    // MARK: logs

    func log(_ text: String, file: String) {
        let url = logsDir.appendingPathComponent(file)
        guard let d = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(d); h.closeFile()
        } else {
            try? d.write(to: url)
        }
    }
}
