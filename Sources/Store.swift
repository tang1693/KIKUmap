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
    let map: MapModel
    private var observers: [() -> Void] = []
    private(set) var intervals: [Interval] = []
    private(set) var runStart: [String: String] = [:]

    var chatsURL: URL { dir.appendingPathComponent("data/chats.json") }
    var seenURL: URL { dir.appendingPathComponent("data/seen.json") }
    var rulesURL: URL { dir.appendingPathComponent("data/rules.json") }
    var activityURL: URL { dir.appendingPathComponent("data/activity.json") }
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
            runStart = a.open
        }
        reindex()
        let before = map.root.children.count
        if map.needsSeed && !chats.isEmpty { map.seed(from: chats) }
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
        if axUnread.contains(c.id) { return true }
        return !c.updated_at.isEmpty && c.updated_at > (seen[c.id] ?? "")
    }

    func isUnread(id: String) -> Bool {
        guard let c = chat(id) else { return false }
        return isUnread(c)
    }

    /// Only pinned chats are shown. Until the Claude sidebar has been read, nothing is (the sidebar
    /// says why) — never every chat. Claude Code sessions show while they run or wait for you, for 12 hours after, or for good once
    /// you pin them here or file them on the map.
    var pinsKnown: Bool { chats.contains { !$0.isCode && $0.pinned != nil } }
    func isShown(_ c: Chat) -> Bool {
        if c.isCode {
            // linked to the Claude app (Remote Control): shown through Claude's chat — only if that one is pinned
            if c.linked == true && chats.contains(where: { !$0.isCode && $0.pinned == true && $0.title == c.title }) { return false }
            if c.pinned == true || running.contains(c.id) || isUnread(c) || map.placedChats().contains(c.id) { return true }
            guard let d = Clock.parse(c.updated_at) else { return false }
            return Date().timeIntervalSince(d) < 12 * 3600
        }
        return c.pinned == true
    }

    /// Today so far: how long Claude worked on each chat you can see (running ones up to now), longest first.
    func today() -> [(id: String, secs: Double)] {
        let start = Calendar.current.startOfDay(for: Date()), now = Date()
        var t: [String: Double] = [:]
        func add(_ id: String, _ a: Date?, _ b: Date?) {
            guard let a = a, let b = b else { return }
            let s = max(a, start), e = min(b, now)
            if e > s { t[id, default: 0] += e.timeIntervalSince(s) }
        }
        for iv in intervals { add(iv.id, Clock.parse(iv.start), Clock.parse(iv.end)) }
        for (id, s) in runStart { add(id, Clock.parse(s), now) }
        return t.filter { isShown(id: $0.key) }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

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

    func name(_ id: String) -> String { map.aliases[id] ?? chat(id)?.title ?? tr("(已删除的对话)", "(deleted chat)") }
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
            ($0.element.isCode ? 1 : 0, $0.element.pinIndex ?? Int.max, $0.offset) < ($1.element.isCode ? 1 : 0, $1.element.pinIndex ?? Int.max, $1.offset)
        }.map { $0.element }
    }

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
        }
        saveSeen()
        notify()
    }

    func markAllSeen() { markSeen(unreadChats.map { $0.id }) }

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
        intervals.removeAll { $0.end < cutoff }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        if let d = try? e.encode(ActivityFile(intervals: intervals, open: runStart)) { try? d.write(to: activityURL, options: .atomic) }
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
        let code = Set(chats.filter { $0.isCode }.map { $0.id })
        let keep = running.intersection(code)        // Claude Code sessions don't live in the Claude app
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
    func apply(scan links: [AXLink], claudeFront: Bool) -> [Event] {
        // An empty read means the sidebar is hidden or still loading, not that everything finished.
        guard !links.isEmpty else { return [] }
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
                if !l.title.isEmpty && chats[i].title != l.title && !l.id.hasPrefix("n-") && !chats[i].isCode {
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
        if !pinnedIDs.isEmpty {
            for (n, id) in pinnedIDs.enumerated() { if let i = index[id], chats[i].pinIndex != n { chats[i].pinIndex = n; changed = true } }
            // the Pinned section was read whole: anything else is no longer pinned (unpinned or deleted in Claude)
            let pinnedSet = Set(pinnedIDs)
            for i in chats.indices where !chats[i].isCode && chats[i].pinned == true && !pinnedSet.contains(chats[i].id) {
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
