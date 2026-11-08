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
    /// When it was last open in the Claude app, under its own address. A deleted chat never is again: among chats with
    /// one title, the one open last is the one the title stands for.
    var liveAt: String?
    /// A Claude Code run started by a script (`claude -p`, the SDK): shown only while it runs (or pinned, or filed),
    /// with no sound and nothing left unread.
    var headless: Bool?
    /// A Claude Code or Codex session: when it started, as far as KIKUmap knows (its first hook line; a Codex thread's
    /// time when it was first listed). The left column keeps sessions in this order, never reshuffled by activity.
    var startedAt: String?
    /// Found finished (or with a new reply) only a while after it was last seen: when that was (`after`), and the
    /// `updated_at` it was found at (`at`; the change came in between). Its time says "done after …", not "just now";
    /// once the chat changes again (`updated_at` moves on) it says nothing.
    var doneAfter: DoneAfter?
    struct DoneAfter: Codable, Equatable { var after: String; var at: String }

    var isCode: Bool { source == "code" }
    /// A Codex thread started in an editor or a terminal (not the ChatGPT app): shown like a Claude Code session.
    var isCodexSession: Bool { source == "gpt" && app != nil && app != "com.openai.codex" }
    /// A thread in the ChatGPT app.
    var isGPT: Bool { source == "gpt" }
    /// An ordinary chat pinned in the ChatGPT app (not a Codex thread): its status comes from ChatGPT's window.
    var isGPTChat: Bool { id.hasPrefix("gpt-chat-") }
    /// Not a chat in the Claude app (its pins, sidebar and archive don't apply).
    var outsideClaude: Bool { isCode || isGPT }
}

/// A stretch of time when Claude was working on a chat.
struct Interval: Codable {
    var id: String
    var start: String
    var end: String
    /// A stretch KIKUmap didn't see (the run was out of its sight), estimated: shown "≈".
    var est: Bool? = nil
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

/// Requests KIKUmap is unsure of ("needs you?"), since when, and which notification put each request on its chat: kept
/// so that a relaunch doesn't turn a doubt back into a sure "needs you", nor forget whose banner is whose.
private struct RequestsFile: Codable {
    var maybeAnswered: [String: Date]
    var requests: [String: String]
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
    /// When each chat last finished (a notification or the sidebar), for reads that began before that.
    private var finishedAt: [String: Date] = [:]
    /// ChatGPT's own unread dots, as last read (nil: it doesn't say). Unread for its app threads follows them; what
    /// you do here (read, unread again) is kept in `seen`, so it lasts across restarts.
    private var gptListed: Set<String>?
    /// Threads whose task went quiet before it finished: when the finish comes, it's announced.
    private var gptQuiet = Set<String>()
    /// Where a quiet task's counted time stopped (its seen time and the estimate after it): if it moves again or
    /// finishes, the time from there is counted too.
    private var gptQuietUntil: [String: Date] = [:]
    /// When each ChatGPT thread's task log was last written (a running one quiet for minutes isn't known to run).
    private var gptActive: [String: Date] = [:]
    /// The Codex tasks shown "running?" as of the last read (one turning so redraws the menu bar and the counts).
    private var gptUnsure = Set<String>()
    /// Ordinary ChatGPT chats whose row in ChatGPT's window has been read since KIKUmap started: whether they run is
    /// known (as of the last time the window could be seen).
    private(set) var gptChatsRead = Set<String>()
    /// Ordinary ChatGPT chats whose row showed ChatGPT's unread dot when last seen. Kept (data/gpt-dots.json) across
    /// restarts, ChatGPT turned off and on, and reads that miss the row: a dot gone since was read in ChatGPT, one still
    /// on is no new reply.
    private(set) var gptMarked = Set<String>()
    /// ChatGPT is read (Settings → Access); when it's off its threads aren't shown.
    nonisolated static var gptOn: Bool { UserDefaults.standard.object(forKey: "ChatGPTOn") as? Bool ?? true }
    /// Time counted in the totals (Today, the timeline, Statistics, the widget): every chat's, ChatGPT's only while
    /// it's on. (ChatGPT ids all start with "gpt-", also for threads no longer in `chats`.)
    nonisolated static func counted(_ id: String) -> Bool { gptOn || !id.hasPrefix("gpt-") }
    let map: MapModel
    private var observers: [() -> Void] = []
    private(set) var intervals: [Interval] = []
    private(set) var runStart: [String: String] = [:]
    private var history: [String: [String: Double]] = [:]
    private var historyTitles: [String: String] = [:]
    /// Chats you marked read here while Claude still showed its unread mark: the chat's `updated_at` then. That mark
    /// is passed over until the chat changes again, or Claude drops it.
    private var dismissed: [String: String] = [:]
    /// When a read of Claude's sidebar last saw each running chat's spinner.
    private var seenRunningAt: [String: Date] = [:]
    /// Running Claude-app chats the sidebar can't see right now (window closed, sidebar hidden, Pinned folded): their
    /// time stopped when a read last saw them run. They stay running until a read says otherwise.
    private var paused = Set<String>()
    /// Paused because the Claude app quit (not a window out of sight): whether they went on isn't known.
    private var quitPaused = Set<String>()
    /// Running Claude-app chats missing from whole reads of the sidebar (deleted while running), since when.
    private var missingSince: [String: Date] = [:]
    /// When a read last showed each chat's row (Claude's sidebar, ChatGPT's window) since KIKUmap started: a reply it
    /// shows anew came after then.
    private var rowSeenAt: [String: Date] = [:]
    /// The chat open in Claude's window (from the sidebar's last read).
    var openChatID: (() -> String?)?
    /// Claude has been in front at some point since the last read of its sidebar began (it was in front when that read
    /// came back, or it has left the front since), and when it last left the front. Told by the order things happen
    /// in, not by comparing times: once the clock is set back, a time from before stays ahead of everything after.
    private var claudeFrontSince = false
    private var claudeLeftAt = Date.distantPast
    /// What the last read went by: Claude in front then, or at some point since the read before it began.
    private(set) var claudeWasFront = false
    /// The same for ChatGPT: in front at some point since its window was last read, when it last left the front (a
    /// Codex thread's finish is known to the second: it goes by that), and what the last read of its window or its
    /// files went by.
    private var gptFrontSince = false
    private var gptLeftAt = Date.distantPast
    private(set) var gptWasFront = false
    /// When Claude last asked for an approval in a chat KIKUmap couldn't tell (its window closed, several chats running,
    /// chats running in plain sight): said in the To-do, for half an hour at most.
    private(set) var approvalAsked: Date?
    static let approvalShown: TimeInterval = 1800
    /// Those requests' banners still in Notification Center (by key). `approvalUnsure`: they've all left it since
    /// (answered elsewhere, or only cleared: the two look the same), so whether Claude still waits isn't known.
    private var approvalKeys = Set<String>()
    private(set) var approvalUnsure = false
    /// Why the chat couldn't be told, as of when Claude asked (what the To-do says while nothing is in the way of reading
    /// Claude's chats): chats were running in plain sight (not guessed at: the one that waits shows it in Claude's
    /// sidebar), more than one out of sight, none at all, or KIKUmap wasn't running then (nothing was seen).
    enum NoChat { case inSight, several, noneRunning, beforeLaunch }
    private(set) var approvalNoChat = NoChat.noneRunning
    /// A row Claude shows waiting that turned so this close to such a banner is the same request: the banner is posted
    /// as the row turns, and a read of the row comes seconds before or after it.
    static let approvalNear: TimeInterval = 30
    /// How many times a chat's id has changed: a sidebar read begun before a change is stale.
    private(set) var idMoves = 0
    /// Each Claude Code session's last hook event, and since when Claude Code could have sent any (the last wake).
    private var lastCodeEvent: [String: Date] = [:]
    private var awakeSince = Date.distantPast
    /// Data files that couldn't be read at launch (kept in data/backups), and files that can't be saved right now.
    private(set) var unreadable: [String] = []
    private(set) var failed: [String: String] = [:]
    private var blocked = Set<String>()
    /// The newest version of each file that couldn't be saved, written again by `retrySaves`.
    private var pending: [String: (data: Data, url: URL, report: Bool)] = [:]
    /// Renames in Claude's sidebar are worked out only once it has been watched for a while: what changed while it
    /// wasn't (KIKUmap not running, the Mac asleep, the list out of sight) may be an unpin and a pin, two chats.
    private var renamesFrom = Date().addingTimeInterval(Store.renameHold)
    static let renameHold: TimeInterval = 120

    var chatsURL: URL { dir.appendingPathComponent("data/chats.json") }
    var seenURL: URL { dir.appendingPathComponent("data/seen.json") }
    var rulesURL: URL { dir.appendingPathComponent("data/rules.json") }
    var activityURL: URL { dir.appendingPathComponent("data/activity.json") }
    var historyURL: URL { dir.appendingPathComponent("data/history.json") }
    var dismissedURL: URL { dir.appendingPathComponent("data/dismissed.json") }
    var gptDotsURL: URL { dir.appendingPathComponent("data/gpt-dots.json") }
    var requestsURL: URL { dir.appendingPathComponent("data/requests.json") }
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
        if let f = load(ChatsFile.self, chatsURL) { chats = f.chats }
        // sessions kept from before KIKUmap noted when each started: their last change stands in, so from now on they
        // keep their places
        for i in chats.indices where (chats[i].isCode || chats[i].isCodexSession) && chats[i].startedAt == nil {
            chats[i].startedAt = chats[i].updated_at.isEmpty ? Clock.iso() : chats[i].updated_at
        }
        if let s = load([String: String].self, seenURL) { seen = s }
        if let s = load([String: String].self, dismissedURL) { dismissed = s }
        if let s = load([String].self, gptDotsURL) { gptMarked = Set(s) }
        if let r = load(RequestsFile.self, requestsURL) {
            // (only for chats still known: a doubt or a banner of one gone says nothing)
            let ids = Set(chats.map(\.id))
            maybeAnswered = r.maybeAnswered.filter { ids.contains($0.key) }
            requests = r.requests.filter { ids.contains($0.value) }
        }
        var closed = false
        if let a = load(ActivityFile.self, activityURL) {
            intervals = a.intervals
            // still open: KIKUmap stopped without closing them (a crash, a forced quit). They end when it was last
            // seen running, not now: the time it was away isn't work it saw.
            let alive = UserDefaults.standard.string(forKey: "AliveAt").flatMap(Clock.parse)
                ?? ((try? FileManager.default.attributesOfItem(atPath: activityURL.path))?[.modificationDate] as? Date) ?? Date()
            let end = Clock.iso(min(alive, Date()))
            for (id, start) in a.open { intervals.append(Interval(id: id, start: start, end: max(start, end))) }
            closed = !a.open.isEmpty
        }
        if let h = load(HistoryFile.self, historyURL) {
            history = Store.offsetKeys(h.days)
            historyTitles = h.titles
            if h.days.keys.contains(where: { $0.count == 13 }) { saveHistory(report: false) }   // done once
        }
        if let m = map.unreadable { unreadable.append(m) }
        prune()
        reindex()
        // (saved at once, now that the chats are known for the totals' names: should this run of KIKUmap end without a
        // save too, the next launch would end them at its own last minute)
        if closed { saveActivity() }
        let before = map.root.children.count
        writeDefaultRules()
        log("\(Clock.iso()) start · data \(dir.path) · chats \(chats.count) · topics \(before)→\(map.root.children.count)\n", file: "app.log")
    }

    /// Reads a data file. Missing: nil (a first run). There but unreadable (damaged, or from a newer KIKUmap): moved
    /// aside to data/backups first, so nothing overwrites it, and listed in the To-do; nil.
    private func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) } catch { keepAside(url, error); return nil }
    }

    private func keepAside(_ url: URL, _ error: Error) {
        let fm = FileManager.default, backups = dir.appendingPathComponent("data/backups")
        try? fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let to = backups.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-unreadable-" + f.string(from: Date()) + ".json")
        do { try fm.moveItem(at: url, to: to); unreadable.append("data/backups/" + to.lastPathComponent) }
        catch { blocked.insert(url.lastPathComponent); unreadable.append("data/" + url.lastPathComponent) }   // left alone: never written over
        log("\(Clock.iso()) couldn't read \(url.lastPathComponent) (\(error.localizedDescription)); kept as \(to.lastPathComponent)\n", file: "app.log")
    }

    /// Every data file is written here: whole (atomic), the folder made again if it went missing; a failure is
    /// logged once and shown in the To-do until a later write works (`report` false: a file nothing depends on is
    /// only logged). The screen hears of it once the change under way is done, which a save can be halfway through.
    private func write(_ d: Data, _ url: URL, report: Bool = true) {
        let name = url.lastPathComponent
        guard !blocked.contains(name) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: url, options: .atomic)
            pending[name] = nil
            if failed.removeValue(forKey: name) != nil { notifyLater() }
        } catch {
            if pending[name] == nil { log("\(Clock.iso()) couldn't save \(name): \(error.localizedDescription)\n", file: "app.log") }
            pending[name] = (d, url, report)
            guard report else { return }
            let first = failed[name] == nil
            failed[name] = error.localizedDescription
            if first { notifyLater() }
        }
    }

    /// Files that couldn't be saved are written again (every minute, at sleep and at quit): what's in memory reaches
    /// the disk once there's room, without waiting for the next change to the same file.
    func retrySaves() { for p in pending.values { write(p.data, p.url, report: p.report) } }

    /// Chats nothing refers to any more, unchanged for 30 days, are forgotten (their names stay with their time):
    /// not pinned, not on the map or named there, not in a map backup still kept (one may be put back), not running
    /// or unread. Not while a data file couldn't be read, or an empty map stands in for one kept aside: what refers
    /// to what isn't known then.
    private func prune() {
        guard unreadable.isEmpty else { return }
        let cut = Clock.iso(Date().addingTimeInterval(-30 * 86400))
        let placed = map.placedChats(), named = Set(map.aliases.keys), timed = Set(intervals.map(\.id))
        var drop = Set(chats.filter { c in
            guard c.pinned != true, !placed.contains(c.id), !named.contains(c.id), !timed.contains(c.id) else { return false }
            if c.updated_at.isEmpty { return true }          // never active while KIKUmap watched: nothing to keep
            return c.updated_at < cut && seen[c.id] != "" && (seen[c.id] ?? "") >= c.updated_at   // read, and old
        }.map(\.id))
        guard !drop.isEmpty else { return }
        let backups = dir.appendingPathComponent("data/backups")
        for n in (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [] where n.hasSuffix(".json") {
            if n.hasPrefix("unreadable-map-") && placed.isEmpty && named.isEmpty { return }
            guard n.hasPrefix("map-") || n.hasPrefix("unreadable-map-"), let d = try? Data(contentsOf: backups.appendingPathComponent(n)),
                  let m = try? JSONDecoder().decode(MapDoc.self, from: d) else { continue }
            map.walkChats(m.root) { _ = drop.remove($0) }
            drop.subtract(m.aliases.keys)
        }
        let before = chats.count
        chats.removeAll { drop.contains($0.id) }
        guard chats.count != before else { return }
        let ids = Set(chats.map(\.id))
        seen = seen.filter { ids.contains($0.key) }
        dismissed = dismissed.filter { ids.contains($0.key) }
        gptMarked = gptMarked.filter { ids.contains($0) }
        maybeAnswered = maybeAnswered.filter { ids.contains($0.key) }
        requests = requests.filter { ids.contains($0.value) }
        log("\(Clock.iso()) forgot \(before - chats.count) chats unchanged for 30 days\n", file: "app.log")
        saveChats(); saveSeen()
    }

    // MARK: change notification

    func observe(_ f: @escaping () -> Void) { observers.append(f) }
    func notify() { for f in observers { f() } }
    private func notifyLater() { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.notify() } } }

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
        // Claude's row shows it waiting for you: it stays listed while it does, whatever was marked read here
        if let n = c.last_note, SidebarWatcher.waitingStatuses.contains(n) { return true }
        if c.isGPT {
            if seen[c.id] == "" { return !c.updated_at.isEmpty }          // marked unread here
            // an app thread: ChatGPT's dot, unless read here since its last change (a session: like Claude Code; an
            // ordinary chat has no dot: finished after you last saw it)
            if !c.isCodexSession, !c.isGPTChat, let dots = gptListed { return dots.contains(c.id) && (seen[c.id] ?? "") <= c.updated_at }
        }
        return !c.updated_at.isEmpty && c.updated_at > (seen[c.id] ?? "")
    }

    func isUnread(id: String) -> Bool {
        guard let c = chat(id) else { return false }
        return isUnread(c)
    }

    /// Can be marked read or unread here (✉, ⇧⌘U, the menu): a chat with a record, not running (nothing to mark yet),
    /// and not one Claude's own row shows waiting for you (that's unread while it does, whatever is marked here).
    func markable(_ id: String) -> Bool {
        guard let c = chat(id), !running.contains(id) else { return false }
        return c.last_note.map(SidebarWatcher.waitingStatuses.contains) != true
    }

    /// Only pinned chats are shown — pinned in Claude, or in ChatGPT for its threads. Until the Claude sidebar has
    /// been read, nothing is (the sidebar says why) — never every chat. Claude Code sessions show while they run or
    /// wait for you, for 12 hours after, or for good once you pin them here or file them on the map.
    var pinsKnown: Bool { chats.contains { !$0.outsideClaude && $0.pinned != nil } }
    func isShown(_ c: Chat) -> Bool {
        if c.isGPT && !Store.gptOn { return false }
        if c.isCode || c.isCodexSession {
            // linked to the Claude app (Remote Control): shown through Claude's chat — only if that one is pinned
            if c.isCode && c.linked == true && chats.contains(where: { !$0.isCode && $0.pinned == true && $0.title == c.title }) { return false }
            if c.headless == true { return c.pinned == true || running.contains(c.id) || map.placedChats().contains(c.id) }
            if c.pinned == true || running.contains(c.id) || isUnread(c) || map.placedChats().contains(c.id) { return true }
            return !c.updated_at.isEmpty && c.updated_at > recentCutoff       // ISO times sort as they read
        }
        return c.pinned == true
    }

    /// 12 hours ago, as an ISO time (worked out at most once a second).
    private var cutoff = (at: 0.0, iso: "")
    private var recentCutoff: String {
        let n = Date().timeIntervalSince1970
        if n - cutoff.at >= 1 { cutoff = (n, Clock.iso(Date(timeIntervalSince1970: n - 12 * 3600))) }
        return cutoff.iso
    }

    /// Today so far: how long Claude worked on each chat (running ones up to now), longest first. The same time as
    /// Statistics and the widget count.
    func today() -> [(id: String, secs: Double)] {
        worked([Calendar.current.startOfDay(for: Date()), Date()])[0].sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    /// How much of today's time is estimated (stretches KIKUmap didn't see).
    /// A Codex task whose log went quiet for good ("quiet since …"): not running, not known to be done.
    func isQuiet(_ id: String) -> Bool { gptQuiet.contains(id) }

    func todayEstimated() -> Double { estimated([Calendar.current.startOfDay(for: Date()), Date()])[0].values.reduce(0, +) }

    // MARK: time KIKUmap didn't see

    /// When each running chat's run began (kept while it's out of sight), for the estimate of its unseen time.
    private var runBegan: [String: Date] = [:]
    private var typicalCache: [Bool: (count: Int, last: String, value: TimeInterval)] = [:]

    /// How long a run of this kind (a Claude-app chat, or a Codex task) typically lasts here: the median of the stretches
    /// KIKUmap saw lately (the timeline's week: older ones are folded into totals); 20 minutes until there are a few.
    func typicalRun(_ id: String) -> TimeInterval {
        let codex = id.hasPrefix("gpt-")
        if let c = typicalCache[codex], c.count == intervals.count, c.last == (intervals.last?.end ?? "") { return c.value }
        let since = Date().addingTimeInterval(-30 * 86400)
        let seen = intervals.compactMap { iv -> TimeInterval? in
            guard iv.est != true, iv.id.hasPrefix("gpt-") == codex, !iv.id.hasPrefix("cc-"),
                  let s = Clock.parse(iv.start), let e = Clock.parse(iv.end), s > since else { return nil }
            let d = e.timeIntervalSince(s)
            return d >= 5 ? d : nil
        }.sorted()
        let v = seen.count >= 5 ? seen[seen.count / 2] : 20 * 60
        typicalCache[codex] = (intervals.count, intervals.last?.end ?? "", v)
        return v
    }

    /// Where the time of a run out of sight since `seen` is taken to end: a typical run from its start (nothing more if
    /// it had run longer already), never past `by` (when it was found finished, or now).
    private func estimatedEnd(_ id: String, seen: Date, by: Date) -> Date {
        min(by, max(seen, (runBegan[id] ?? seen).addingTimeInterval(typicalRun(id))))
    }

    /// When the Mac last went to sleep (time asleep is never counted).
    private var sleptAt: Date?
    /// From the Mac's sleep notice to its wake: no run opens. KIKUmap hears of the sleep a moment before it comes, and a
    /// read or a hook line that lands in that moment would open its runs again, counting the whole sleep as work seen.
    private(set) var asleep = false
    /// The Mac's uptime at the sleep notice (uptime stands still while it sleeps).
    private var sleptUptime: TimeInterval = 0

    /// Where a run seen starting at `t` begins to count: not while the Mac sleeps (nil: it opens at the wake), nor before
    /// the last wake (a hook line from before the sleep, read only after it, would count the sleep; a wake still to come
    /// is from before the clock was set back).
    private func openRun(at t: Date) -> String? {
        if asleep { return nil }
        return Clock.iso(awakeSince > t && awakeSince <= Date() ? awakeSince : t)
    }

    /// The screens woke while KIKUmap still takes the Mac to be asleep: if it did sleep since the notice (the clock ran on
    /// past the uptime), or has been up a minute since without sleeping (the sleep called off), the wake notice didn't
    /// come, and runs count again from now. (In a sleep KIKUmap isn't woken for, the screens stay off.)
    func screensWoke(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard asleep, let z = sleptAt else { return }
        let up = uptime - sleptUptime
        if now.timeIntervalSince(z) - up > 5 || up > 60 { resumeRuns(at: now) }
    }

    /// The parts of a..<b the Mac was awake (the last sleep left out).
    private func awake(_ a: Date, _ b: Date) -> [(Date, Date)] {
        guard b > a else { return [] }
        if let s = sleptAt, awakeSince > a, s < b { return [(a, min(max(s, a), b)), (max(awakeSince, a), b)].filter { $0.1 > $0.0 } }
        return [(a, b)]
    }

    /// A stretch KIKUmap didn't see, counted as estimated.
    private func estimate(_ id: String, from a: Date, to b: Date) {
        let parts = awake(a, b).filter { $0.1.timeIntervalSince($0.0) >= 1 }
        guard !parts.isEmpty else { return }
        for (x, y) in parts { intervals.append(Interval(id: id, start: Clock.iso(x), end: Clock.iso(y), est: true)) }
        saveActivity()
    }

    /// Runs out of sight right now and their estimated time so far: a Claude-app chat from when it was last seen
    /// running, a Codex task from its log's last activity.
    func unseenStretches(now: Date = Date()) -> [(id: String, a: Date, b: Date)] {
        var out: [(id: String, a: Date, b: Date)] = []
        for id in paused where running.contains(id) {
            guard let seen = seenRunningAt[id] else { continue }
            for (x, y) in awake(seen, estimatedEnd(id, seen: seen, by: now)) { out.append((id, x, y)) }
        }
        for (id, s) in runStart where id.hasPrefix("gpt-") && outOfSight(id) {
            guard let a = gptActive[id], let start = Clock.parse(s) else { continue }
            let from = max(a, start)
            for (x, y) in awake(from, estimatedEnd(id, seen: from, by: now)) { out.append((id, x, y)) }
        }
        return out
    }

    /// How long Claude worked on each chat in each slot bounds[i] ..< bounds[i + 1], running chats up to
    /// now. Chats running side by side share the time (two at once: half each), so a slot never holds more
    /// than its own length and the chats add up to the time Claude was busy. Time older than the timeline's
    /// week comes from the hourly totals, each hour whole in the slot it starts in; from before those there
    /// are only daily totals, left out when the slots are shorter than a day (`wholeDays` false: see
    /// `dailyOnlyUntil`).
    func worked(_ bounds: [Date], wholeDays: Bool = true) -> [[String: Double]] { workedSplit(bounds, wholeDays: wholeDays).all }

    /// How much of `worked` is estimated (stretches KIKUmap didn't see), by slot and chat.
    func estimated(_ bounds: [Date]) -> [[String: Double]] { workedSplit(bounds, wholeDays: false).est }

    private func workedSplit(_ bounds: [Date], wholeDays: Bool) -> (all: [[String: Double]], est: [[String: Double]]) {
        var out = [[String: Double]](repeating: [:], count: max(bounds.count - 1, 0))
        var est = out
        guard let first = bounds.first, let last = bounds.last, !out.isEmpty else { return (out, est) }
        func slot(_ d: Date) -> Int? { d >= first && d < last ? bounds.lastIndex { $0 <= d } : nil }
        var runs: [(id: String, a: Date, b: Date)] = []
        // (an estimated stretch goes in under "≈" + its chat, so its share is told apart)
        func run(_ id: String, _ a: Date?, _ b: Date?, estimated: Bool = false) {
            guard Store.counted(id), let a = a, let b = b, b > first, a < last else { return }
            runs.append(((estimated ? "≈" : "") + id, max(a, first), min(b, last)))
        }
        for iv in intervals { run(iv.id, Clock.parse(iv.start), Clock.parse(iv.end), estimated: iv.est == true) }
        let now = Date()
        for (id, s) in runStart { run(id, Clock.parse(s), liveEnd(id, now: now)) }
        for u in unseenStretches(now: now) { run(u.id, u.a, u.b, estimated: true) }
        Store.shareSeenFirst(runs) { key, a, b, part in
            let guess = key.hasPrefix("≈"), id = guess ? String(key.dropFirst()) : key
            var i = slot(a) ?? 0
            while i < out.count && bounds[i] < b {
                let s = max(a, bounds[i]), e = min(b, bounds[i + 1])
                if e > s {
                    out[i][id, default: 0] += e.timeIntervalSince(s) * part
                    if guess { est[i][id, default: 0] += e.timeIntervalSince(s) * part }
                }
                i += 1
            }
        }
        // the keys start with their local day (in the zone they were folded in): anything two days or more outside the
        // slots is passed over unread
        let lo = Store.dayFormatter.string(from: first.addingTimeInterval(-2 * 86400)), hi = Store.dayFormatter.string(from: last.addingTimeInterval(2 * 86400))
        for (key, t) in history where key.prefix(10) >= lo && key.prefix(10) <= hi {
            let hourly = key.count > 10
            guard hourly || wholeDays, let d = Store.historyDate(key), let i = slot(d) else { continue }
            // folded before time was shared: an hour (a day) never holds more than itself (a day can be 23 or 25 hours)
            let most = hourly ? 3600 : Calendar.current.dateInterval(of: .day, for: d)?.duration ?? 86400
            func real(_ key: String) -> String { key.hasPrefix("≈") ? String(key.dropFirst()) : key }
            let total = t.filter { Store.counted(real($0.key)) }.values.reduce(0, +)
            let scale = total > most ? most / total : 1
            for (key, s) in t where Store.counted(real(key)) {
                out[i][real(key), default: 0] += s * scale
                if key.hasPrefix("≈") { est[i][real(key), default: 0] += s * scale }
            }
        }
        return (out, est)
    }

    /// When a history key starts: "2026-11-01 01-0400" (an hour with its UTC offset, so the hour that comes twice
    /// when daylight saving ends is two keys, and a move to another time zone changes nothing), or the older
    /// "2026-11-01 01" (an hour, local) and "2026-11-01" (a day).
    static func historyDate(_ key: String) -> Date? {
        switch key.count {
        case 10: return dayFormatter.date(from: key)
        case 13: return hourFormatter.date(from: key)
        default: return hourKeyFormatter.date(from: key)
        }
    }

    /// Hours an older version folded ("2026-11-01 01", local) with their UTC offset added, as of the zone they're read
    /// in: from then on a move to another time zone doesn't shift them. The hour that comes twice when daylight saving
    /// ends held both: what's more than an hour goes to the second. (An hour that doesn't exist here, which only
    /// another zone could have written, keeps its own key.)
    static func offsetKeys(_ days: [String: [String: Double]]) -> [String: [String: Double]] {
        var out = days.filter { $0.key.count != 13 }
        for (key, t) in days where key.count == 13 {
            guard let d = hourFormatter.date(from: key) else { out[key] = t; continue }
            let hours = [d.addingTimeInterval(-3600), d, d.addingTimeInterval(3600)].filter { hourFormatter.string(from: $0) == key }
            let total = t.values.reduce(0, +)
            let first = hours.count > 1 && total > 3600 ? 3600 / total : 1
            func add(_ h: Date, _ part: Double) {
                let k = key + String(hourKeyFormatter.string(from: h).suffix(5))
                for (id, s) in t { out[k, default: [:]][id, default: 0] += s * part }
            }
            add(hours.first ?? d, first)
            if first < 1 { add(hours[1], 1 - first) }
        }
        return out
    }

    /// Seen runs share their time among themselves; an estimated stretch ("≈" + its chat) only has the time no seen run
    /// covers, so a guess never takes time from a chat that was seen working.
    static func shareSeenFirst(_ runs: [(id: String, a: Date, b: Date)], _ take: (String, Date, Date, Double) -> Void) {
        let seen = runs.filter { !$0.id.hasPrefix("≈") && $0.b > $0.a }.sorted { $0.a < $1.a }
        share(seen, take)
        var cover: [(a: Date, b: Date)] = []
        for r in seen {
            if let l = cover.last, r.a <= l.b { cover[cover.count - 1].b = max(l.b, r.b) } else { cover.append((r.a, r.b)) }
        }
        var rest: [(id: String, a: Date, b: Date)] = []
        for r in runs where r.id.hasPrefix("≈") {
            var a = r.a
            for c in cover where c.b > a && c.a < r.b {
                if c.a > a { rest.append((r.id, a, c.a)) }
                a = max(a, c.b)
            }
            if a < r.b { rest.append((r.id, a, r.b)) }
        }
        share(rest, take)
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

    /// Lenient: a local time that doesn't exist (skipped when daylight saving starts) still reads.
    static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH"
        f.isLenient = true
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    static let hourKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHxx"
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = true
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    /// A chat Import just started in the Claude app, as Claude shows it: its name there, and pinned only if pinning it
    /// worked.
    func addImported(id: String, title: String, pinned: Bool) {
        if let i = index[id] {
            chats[i].title = title
            chats[i].pinned = pinned
            chats[i].liveAt = Clock.iso()
        } else {
            chats.append(Chat(id: id, title: title, updated_at: Clock.iso(), path: "/chat/" + id, source: "sidebar", last_note: nil, pinned: pinned,
                              liveAt: Clock.iso()))
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
        guard let n = c.last_note else { return false }
        // Claude's row shows it waiting (mirrored on every read): so whether or not it was marked read here; a request
        // from a notification, or a stop on an error, until it's read
        if SidebarWatcher.waitingStatuses.contains(n) { return true }
        if maybeAnswered[c.id] != nil { return false }
        return isUnread(c) && (Store.isInputNote(n) || n.hasPrefix(Store.stopMark))
    }

    /// Requests for your approval that may have been answered where no word of it comes from, since when: a Claude Code
    /// session's whose app has come to the front (no hook says so until the approved step ends), a Claude chat's whose
    /// notification left Notification Center (answered, or only cleared: the two look the same). Shown as "needs you?",
    /// without the "!", while the chat is unread. Marking it read answers nothing: the doubt stays, for when it's marked
    /// unread again, and one raised while it's read is kept the same way (the request may be answered whichever way it
    /// was marked). Saved on every change (data/requests.json): nothing would bring the doubt back after a relaunch.
    private var maybeAnswered: [String: Date] = [:] { didSet { if maybeAnswered != oldValue { saveRequests() } } }
    /// The app in front now (its bundle id).
    var frontApp: (() -> String?)?

    /// No other session has worked in that app this past hour: with several, its coming to the front says nothing about
    /// this one, which keeps its "!".
    private func onlySession(_ c: Chat) -> Bool {
        !chats.contains { $0.isCode && $0.id != c.id && $0.app == c.app && (lastCodeEvent[$0.id].map { Date().timeIntervalSince($0) < 3600 } ?? false) }
    }
    /// A chat shown "needs you?": you may have answered it (shown while it's unread, as a sure request is).
    func maybeWaiting(_ id: String) -> Bool { maybeAnswered[id] != nil && isUnread(id: id) }

    /// An app came to the front: a Claude Code session in it that asks for your approval may be answered from now on
    /// (read here or not: marked unread later, it's "needs you?" all the same).
    func appCameToFront(_ bundle: String) {
        var changed = false
        for c in chats where c.isCode && c.app == bundle && maybeAnswered[c.id] == nil && !running.contains(c.id)
            && c.last_note.map({ Store.isInputNote($0) && !$0.hasPrefix(Store.stopMark) }) == true && onlySession(c) {
            maybeAnswered[c.id] = Date(); changed = true
        }
        if changed { notify() }
        readCodeInFront(bundle)
    }

    /// Claude left the front (another app came forward, or it was hidden): a reply that had just finished in the chat
    /// open there was still watched, though the read that finds it done comes back a moment later.
    func claudeLeftFront(at when: Date = Date()) { claudeLeftAt = when; claudeFrontSince = true }
    /// ChatGPT left the front: the same for its chats and its Codex threads.
    func gptLeftFront(at when: Date = Date()) { gptLeftAt = when; gptFrontSince = true }

    /// The title of the front app's focused window (read with Accessibility), or nil.
    var frontWindowTitle: (() -> String?)?
    /// The titles of the front app's other windows, and of its windows' tabs but the one shown in front (read with
    /// Accessibility): what else in that app could show a session's folder. nil: they can't be read.
    var otherWindowTitles: (() -> [String]?)?

    /// A finished Claude Code or Codex session whose app is in front on a window that can only be that session's:
    /// you're looking at it there, so it's read, as a Claude chat open in Claude's window in front is. The window's
    /// title names the session's own folder (an editor's titled by its project, VS Code's or Cursor's: that folder or
    /// one it's in), and a terminal's says Claude Code runs in it, not a shell in that folder. When which session the
    /// window shows can't be told, it stays unread: KIKUmap knows another folder of that name, another window or tab
    /// of the app could show it too (an editor's on its folder or any folder it's in; or they can't be read), another
    /// session there works or has worked this past hour; so does one waiting for you or stopped on an error. A Codex
    /// session in a terminal always does: which terminal runs it isn't known.
    func readCodeInFront(_ bundle: String? = nil) {
        guard let b = bundle ?? frontApp?(), b != claudeBundleID, b != GPTWatcher.bundleID else { return }
        let sessions = chats.filter { ($0.isCode || $0.isCodexSession) && $0.cwd != nil }
        let mine = sessions.filter { Store.sessionApp($0) == b }
        guard mine.contains(where: isUnread), let title = frontWindowTitle?() else { return }
        let editor = Store.titledByProject(b)
        let here = mine.compactMap { c in c.cwd.flatMap { Store.folder(title, shows: $0, above: editor) }.map { (c, $0) } }
        // the one folder the title names: not one of two KIKUmap knows by that name (a bare name doesn't say which)
        guard let folder = here.first?.1,
              Set(sessions.compactMap { $0.cwd.flatMap { Store.folder(title, shows: $0, above: editor) } }).count == 1 else { return }
        let lately = here.map(\.0).filter {
            running.contains($0.id) || isUnread($0)
                || (($0.isCode ? lastCodeEvent[$0.id] : gptActive[$0.id]).map { Date().timeIntervalSince($0) < 3600 } ?? false)
        }
        guard lately.count == 1, let c = lately.first, isUnread(c), c.last_note == nil, let cwd = c.cwd else { return }
        // a terminal: its title says it's Claude Code's tab, not a shell in the same folder
        if !editor && !Store.showsClaudeCode(title, in: folder) { return }
        // no other window or tab of the app could show it too: a terminal's in its folder that says claude runs there; an
        // editor's on its folder or any folder it's in, the home folder too (from that window's terminal, after a `cd`,
        // it may run there as well: which window it is can't be told)
        guard let others = otherWindowTitles?(), !others.contains(where: { t in
            guard let f = Store.folder(t, shows: cwd, above: editor, pastHome: true) else { return false }
            return editor || Store.showsClaudeCode(t, in: f)
        }) else { return }
        markSeen([c.id])
    }

    /// The app a session runs in, by bundle id: a Claude Code session's own (or the one its terminal named itself by,
    /// "Apple_Terminal"); a Codex session's from VS Code, VS Code. nil: not known (a Codex session from a terminal or
    /// another editor).
    static func sessionApp(_ c: Chat) -> String? {
        if c.isCodexSession { return c.app == "vscode" ? appBundles["vscode"] : nil }
        guard c.isCode, let a = c.app, !a.isEmpty else { return nil }
        return appBundles[a] ?? a
    }
    /// The apps a session may give by name instead: its terminal's (TERM_PROGRAM), a Codex session's editor.
    static let appBundles = ["vscode": "com.microsoft.VSCode", "Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2"]

    /// Editors whose windows are titled by the project folder they have open (VS Code and the editors built on it:
    /// Cursor, Windsurf, VSCodium; JetBrains'): a session there may run in a folder inside it.
    static func titledByProject(_ bundle: String) -> Bool {
        let b = bundle.lowercased()
        return b.contains("vscode") || b.contains("vscodium") || b == "com.todesktop.230313mzl4w4u92" || b.hasPrefix("com.exafunction.windsurf")
            || b.hasPrefix("com.jetbrains.") || b == "com.google.android.studio"
    }

    /// The folder a Claude Code session was started in: of `cwd` and the folders it's in, the one Claude Code files the
    /// session's transcript under (~/.claude/projects/<the path, each character but a letter or digit as "-">/…).
    /// That's the folder its editor window has open; a `cd` in the session moves `cwd`, not this. nil: not one of them.
    static func sessionFolder(cwd: String, transcript: String) -> String? {
        let key = (transcript as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? ""
        guard !cwd.isEmpty, key.hasPrefix("-") else { return nil }
        func code(_ p: String, ascii: Bool) -> String {
            String(p.map { c -> Character in (ascii ? c.isASCII : true) && (c.isLetter || c.isNumber) ? c : "-" })
        }
        var u = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            if code(u.path, ascii: true) == key || code(u.path, ascii: false) == key { return u.path }
            if u.path == "/" { return nil }
            u.deleteLastPathComponent()
        }
    }

    /// A window's title names this folder or one it's in (short of the home folder): VS Code's "Store.swift — Claude",
    /// Terminal's "Claude — zsh — 80×24" or "you@Mac: ~/Desktop/Claude".
    static func window(_ title: String, shows cwd: String) -> Bool { folder(title, shows: cwd, above: true) != nil }

    /// The folder of `cwd`'s a window's title names: `cwd` itself; with `above` (an editor's window, titled by the
    /// project it has open), else the nearest folder it's in, short of the home folder (with `pastHome`, the home
    /// folder and those it's in too). A part of the title that's a path ("you@Mac: ~/Desktop/Claude") names that
    /// folder only; a bare name ("Claude — zsh — 80×24") any folder of that name. nil: neither.
    static func folder(_ title: String, shows cwd: String, above: Bool, pastHome: Bool = false) -> String? {
        guard cwd.hasPrefix("/") else { return nil }
        let parts = titleParts(title)
        let names = Set(parts), paths = Set(parts.compactMap(titlePath))
        var u = URL(fileURLWithPath: cwd).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        while u.path != "/" && !(above && !pastHome && u.path == home) {
            if paths.contains(u.path) || names.contains(u.lastPathComponent) { return u.path }
            guard above else { return nil }
            u.deleteLastPathComponent()
        }
        return nil
    }

    /// A terminal window's title says Claude Code runs in it, in `folder`: besides the part naming the folder, a part
    /// that's its process, "claude" (with its arguments, if shown), as Terminal and iTerm put it.
    static func showsClaudeCode(_ title: String, in folder: String) -> Bool {
        var parts = titleParts(title)
        let name = (folder as NSString).lastPathComponent
        if let i = parts.firstIndex(where: { $0 == name || titlePath($0) == folder }) { parts.remove(at: i) }
        return parts.contains { $0.lowercased().split(whereSeparator: { $0 == " " || $0 == "(" }).first == "claude" }
    }

    /// A window title's parts, between its dashes.
    private static func titleParts(_ title: String) -> [String] {
        title.replacingOccurrences(of: " – ", with: " — ").replacingOccurrences(of: " - ", with: " — ")
            .components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    /// A title part that's a path ("~/Desktop/Claude", "/tmp/x", after "you@Mac:"), in full; nil: not one.
    private static func titlePath(_ part: String) -> String? {
        var p = Substring(part)
        if let colon = p.firstIndex(of: ":"), p[..<colon].contains("@") { p = p[p.index(after: colon)...] }
        let s = p.trimmingCharacters(in: .whitespaces)
        let full = s == "~" || s.hasPrefix("~/") ? NSHomeDirectory() + s.dropFirst() : s
        return full.hasPrefix("/") ? URL(fileURLWithPath: full).standardizedFileURL.path : nil
    }
    /// Put before a chat's note when its run stopped on an error (Claude Code's StopFailure, a status on Claude's row
    /// KIKUmap doesn't know, ChatGPT's failed mark): its words are shown, and it wants you, not "done". Invisible.
    static let stopMark = "\u{2062}"
    /// After `stopMark` on a Claude Code session's error stop: the error as Claude Code gave it follows, and "stopped:"
    /// is put before it when it's shown, in the language shown then (the note is saved in chats.json). Invisible.
    static let codeStopMark = "\u{2063}"
    /// After `stopMark` on an ordinary ChatGPT chat whose reply failed: ChatGPT's words for its failed mark follow
    /// (it shows a red mark; the words are for screen readers). Its English default, which it says in every language
    /// for now, is shown as "reply failed" in the language shown then; words of its own in a language, as they are.
    /// Invisible.
    static let gptFailMark = "\u{2064}"
    /// How an earlier version saved that note: its "stopped:" in the language KIKUmap was in then.
    private static let oldStopWords = ["出错停下：", "stopped: "]
    /// A stop note as it's shown: Claude's words as they are; a Claude Code error after "stopped:" in today's language;
    /// ChatGPT's failed mark as "reply failed" in today's language, unless ChatGPT words it in its own language.
    static func stopText(_ note: String) -> String {
        var t = String(note.dropFirst(note.hasPrefix(stopMark) ? 1 : 0))
        if t.hasPrefix(gptFailMark) {
            t.removeFirst()
            return t.isEmpty || GPTSidebar.failedWords.contains(GPTSidebar.norm(t).lowercased()) ? tr("回复失败", "reply failed") : t
        }
        if t.hasPrefix(codeStopMark) { t.removeFirst() }
        else if let w = oldStopWords.first(where: { t.hasPrefix($0) }) { t.removeFirst(w.count) }
        else { return t }
        return tr("出错停下：", "stopped: ") + t
    }

    /// Claude's notifications that it waits for you (your input, or permission to use your computer), in each language
    /// it speaks; and the English words Claude Code uses.
    private static let inputNotes = [
        "Claude needs your input to continue", "Claude benötigt deine Eingabe, um fortzufahren", "Claude necesita tu respuesta para continuar",
        "Claude a besoin de votre réponse pour continuer", "जारी रखने के लिए Claude को आपके इनपुट की आवश्यकता है", "Claude butuh masukanmu untuk melanjutkan",
        "Claude ha bisogno del tuo input per continuare", "Claudeが続行するには入力が必要です", "Claude가 계속하려면 입력이 필요합니다",
        "Claude precisa da sua resposta para continuar",
        "Claude needs permission to continue using your computer", "Claude braucht deine Erlaubnis, um deinen Computer weiter zu nutzen",
        "Claude necesita permiso para seguir usando tu computadora", "Claude necesita permiso para seguir usando tu ordenador",
        "Claude a besoin de votre autorisation pour continuer à utiliser votre ordinateur",
        "आपके कंप्यूटर का इस्तेमाल जारी रखने के लिए Claude को अनुमति चाहिए", "Claude memerlukan izin untuk terus menggunakan komputer Anda",
        "Claude ha bisogno dell’autorizzazione per continuare a usare il tuo computer", "Claude がコンピューターの使用を続けるには許可が必要です",
        "컴퓨터를 계속 사용하려면 Claude에게 권한이 필요합니다", "O Claude precisa de permissão para continuar usando seu computador",
    ]
    /// Claude's "a tool is waiting for your approval" banner (title and body, in each language): it names no chat.
    static let approvalTitles: Set<String> = [
        "Claude needs your approval", "Claude benötigt deine Genehmigung", "Claude necesita tu aprobación", "Claude a besoin de votre approbation.",
        "Claude को आपकी स्वीकृति चाहिए", "Claude membutuhkan persetujuan Anda", "Claude ha bisogno della tua approvazione", "Claudeが承認を必要としています",
        "Claude가 승인을 요청합니다", "O Claude precisa da sua aprovação",
    ]
    private static let approvalBodies = [
        "A tool is waiting for your approval", "Ein Tool wartet auf deine Genehmigung", "Una herramienta está esperando tu aprobación",
        "Un outil attend votre approbation", "एक टूल आपकी स्वीकृति की प्रतीक्षा कर रहा है", "Sebuah alat menunggu persetujuan Anda",
        "Uno strumento è in attesa della tua approvazione", "ツールが承認を待っています", "도구가 승인을 기다리고 있습니다", "Uma ferramenta está aguardando sua aprovação",
    ]
    /// Claude's "waiting for your input" when a task's turn is over (its own word for done, not a request).
    private static let idleNotes = [
        "Claude is waiting for your input", "Claude wartet auf deine Eingabe", "Claude está esperando tu respuesta", "Claude attend votre réponse",
        "Claude आपके इनपुट की प्रतीक्षा कर रहा है", "Claude sedang menunggu masukanmu", "Claude sta aspettando il tuo input", "Claudeはあなたの入力を待っています",
        "Claude가 입력을 기다리고 있습니다", "Claude está aguardando sua resposta",
    ]
    static func isInputNote(_ body: String) -> Bool {
        if body.hasPrefix(waitsMark) { return true }
        if idleNotes.contains(where: { body.contains($0) }) { return false }
        return inputNotes.contains { body.contains($0) } || approvalBodies.contains { body.contains($0) }
            || body.range(of: "needs your input|permission|approv|输入|授权", options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Put before a note that waits for you by Claude's own mark, though its words don't say so (a question's text,
    /// "Allow Claude to run …?"): invisible.
    static let waitsMark = "\u{2063}"

    enum NoteKind { case waits, ended, ignore }

    /// What a Claude notification is, by what Claude marks it with (its kind, its identifier), whatever its words say: it
    /// waits for you, a turn ended, or it's nothing to act on (a Code session's, which come through Claude Code's hooks;
    /// computer use taken or let go: the task works on). nil: it doesn't say, its words decide.
    static func kind(_ detail: String) -> NoteKind? {
        if detail.contains("product=ccd") || detail.contains("iden=cu-lock-") { return .ignore }
        if detail.contains("notificationType=remote_requires_action") { return .waits }
        if detail.contains("notificationType=remote_turn_complete") || detail.contains("notificationType=remote_idle") { return .ended }
        if detail.contains("type=permission_request") || detail.contains("type=ask_user_question")
            || detail.contains("iden=permission-") || detail.contains("iden=cowork-permission-") { return .waits }
        if detail.contains("type=idle_notification") { return .ended }
        return nil
    }

    /// Requests Claude's notifications put on a chat ("needs you"), by the notification's key: if the notification
    /// leaves Notification Center, KIKUmap is no longer sure the chat waits. Saved with the doubts (a banner cleared after
    /// a relaunch still raises one).
    private var requests: [String: String] = [:] { didSet { if requests != oldValue { saveRequests() } } }

    /// A new request on a chat: the chat waits for this one now, so the banners of its earlier ones say nothing
    /// about it any more (clearing an older one while this one is still there leaves it "needs you").
    private func request(_ key: String, on id: String) {
        requests = requests.filter { $0.value != id }
        if !key.isEmpty { requests[key] = id }
    }

    /// One of the Claude app's own chats (not a Claude Code session, not one of ChatGPT's).
    private func inClaude(_ id: String) -> Bool { !id.hasPrefix("cc-") && !id.hasPrefix("gpt-") && chat(id)?.outsideClaude == false }

    /// What a "needs your approval" banner posted at `date` is about (it names no chat), never guessed at among chats
    /// whose rows can show it (a chat running in plain sight shows its own wait, with its alert, at the next read):
    /// - the one chat whose row turned waiting with it (within `approvalNear`; a row that turned earlier was an earlier
    ///   request); several did: it's one of theirs, and each shows it already, with its alert (`shown`: nothing to add);
    /// - else the one open in Claude's window, if it was running there (not one that was idle: it had no tool waiting);
    /// - else the only one of Claude's chats running, if it's out of KIKUmap's sight (its row can't show it: Claude's
    ///   window closed, Code mode, …).
    /// Otherwise no chat, and why (`unknown`).
    enum ApprovalTarget: Equatable { case chat(String), shown, unknown(NoChat) }
    private func approvalTarget(at date: Date) -> ApprovalTarget {
        let turned = chats.filter { c in
            inClaude(c.id) && c.last_note.map(SidebarWatcher.waitingStatuses.contains) == true
                && Clock.parse(c.updated_at).map { abs($0.timeIntervalSince(date)) <= Store.approvalNear } == true
        }
        if turned.count == 1 { return .chat(turned[0].id) }
        if turned.count > 1 { return .shown }
        if let o = openChatID?(), inClaude(o), running.contains(o) { return .chat(o) }
        let mine = running.filter(inClaude)
        if mine.count == 1, let m = mine.first, outOfSight(m) { return .chat(m) }
        return .unknown(mine.contains { !outOfSight($0) } ? .inSight : mine.isEmpty ? .noneRunning : .several)
    }

    /// These notifications left Notification Center. A request that's gone, on a chat still waiting for it, was
    /// answered somewhere KIKUmap can't see, or only cleared to deal with later: the two look the same, so the chat
    /// still waits as far as anyone knows, unsure ("needs you?", no "!"), until Claude's sidebar or a new notification
    /// says. So also on one marked read here (shown once it's marked unread again). It isn't running: no time is counted
    /// from here (a turn's end notified later counts the approved run up to it, see `apply(_:)`). The same for a request
    /// no chat could be told for (the To-do): unsure once its banners are all gone. With Claude not running nothing was
    /// answered: left as is. (Both maps save themselves.)
    func withdrawn(_ keys: Set<String>, claudeOpen: Bool = true) {
        var changed = false
        for k in keys {
            guard let id = requests.removeValue(forKey: k), claudeOpen, let i = index[id], let n = chats[i].last_note,
                  Store.isInputNote(n), !SidebarWatcher.waitingStatuses.contains(n), !running.contains(id),
                  maybeAnswered[id] == nil else { continue }
            maybeAnswered[id] = Date()
            changed = true
        }
        if !approvalKeys.isDisjoint(with: keys) {
            approvalKeys.subtract(keys)
            if claudeOpen && approvalKeys.isEmpty && approvalAsked != nil && !approvalUnsure { approvalUnsure = true; changed = true }
        }
        if changed { notify() }
    }

    /// A run ends where a notification says (it finished, or waits for you): its time up to then. Out of KIKUmap's
    /// sight, it's counted from the last sighting as estimated (≈), not as time seen (time asleep isn't counted: a
    /// finish after the last wake counts from that wake).
    private func stopRun(_ id: String, at date: Date) {
        running.remove(id)
        let when = Clock.iso(date)
        if let start = runStart.removeValue(forKey: id) {
            intervals.append(Interval(id: id, start: start, end: max(start, when)))
            saveActivity()
        } else if paused.contains(id), let seen = seenRunningAt[id] {
            estimate(id, from: date > awakeSince ? max(seen, awakeSince) : seen, to: date)
        }
        paused.remove(id); quitPaused.remove(id); missingSince.removeValue(forKey: id)
        finishedAt[id] = date
    }

    func isShown(id: String) -> Bool { chat(id).map(isShown) ?? false }

    var runningChats: [Chat] { chats.filter { running.contains($0.id) && isShown($0) } }
    var unreadChats: [Chat] { chats.filter { isUnread($0) && isShown($0) } }

    func name(_ id: String) -> String { map.aliases[id] ?? chat(id)?.title ?? historyTitles[id] ?? tr("(已删除的对话)", "(deleted chat)") }
    func mapLabel(_ id: String) -> String { map.aliases[id] ?? (chat(id)?.title.strippedPrefix ?? tr("(已删除的对话)", "(deleted chat)")) }

    /// 0 plain, 1 waiting for you, 2 running.
    func state(_ id: String) -> Int { running.contains(id) ? 2 : (isUnread(id: id) ? 1 : 0) }

    func timeLabel(_ c: Chat) -> String {
        if running.contains(c.id) { return outOfSight(c.id) ? tr("在跑？", "running?") : tr("在跑", "running") }
        // an ordinary ChatGPT chat whose row in ChatGPT's window hasn't been read since KIKUmap started (the window
        // can't be seen, Accessibility is off): whether it runs isn't known
        if c.isGPTChat && !gptChatsRead.contains(c.id) { return tr("没同步", "not synced") }
        // a Codex task that went quiet without finishing: since when, not a finish time it doesn't have
        if gptQuiet.contains(c.id), let a = gptActive[c.id] { return tr("\(UsageMonitor.stamp(a)) 起没动静", "quiet since \(UsageMonitor.stamp(a))") }
        // stopped on an error: Claude's own words (Claude Code's, after "stopped:" in the language shown now)
        if let n = c.last_note, n.hasPrefix(Store.stopMark) { let t = Store.stopText(n); return t.count > 34 ? String(t.prefix(33)) + "…" : t }
        if needsInput(c) { return tr("等你确认", "waiting for you") }
        if maybeWaiting(c.id), let n = c.last_note, Store.isInputNote(n) { return tr("可能在等你", "maybe waiting for you") }
        // found done only a while after it was last seen: not when it finished, which isn't known, but since when it may have
        if let d = c.doneAfter, d.at == c.updated_at, let a = Clock.parse(d.after) {
            return tr("\(UsageMonitor.stamp(a)) 后做完", "done after \(UsageMonitor.stamp(a))")
        }
        return Clock.ago(c.updated_at)
    }

    /// A change on chat `i` found at `now` (a finish, a reply) by a read that last saw the chat at `lastSeen`: dated `now`,
    /// as found (the order and Export go by it). Last seen a minute or more before, when it came isn't known, only that
    /// it was after then: kept, so its time says so.
    private func dateFound(_ i: Int, _ now: String, lastSeen: Date?) {
        chats[i].updated_at = now
        if let a = lastSeen, let n = Clock.parse(now), n.timeIntervalSince(a) >= 60 {
            chats[i].doneAfter = Chat.DoneAfter(after: Clock.iso(a), at: now)
        } else {
            chats[i].doneAfter = nil
        }
    }

    /// Running when last seen, but out of KIKUmap's sight since (Claude's window closed, its sidebar hidden): whether
    /// it has finished isn't known, and it isn't shown as if it were.
    func outOfSight(_ id: String) -> Bool {
        guard running.contains(id) else { return false }
        if paused.contains(id) { return true }
        // a Codex task whose log has been quiet a few minutes: waiting for your approval, or ChatGPT (or a session's
        // Codex) stopped?
        return id.hasPrefix("gpt-") && (gptActive[id].map { Date().timeIntervalSince($0) > 180 } ?? false)
    }
    /// When a chat out of sight was last seen running (for a Codex task: when its log last moved).
    func lastSeenRunning(_ id: String) -> Date? { Store.codexThread(id) ? gptActive[id] : seenRunningAt[id] }
    /// A Codex thread's id (its status comes from its log), not an ordinary ChatGPT chat's (from ChatGPT's window).
    static func codexThread(_ id: String) -> Bool { id.hasPrefix("gpt-") && !id.hasPrefix("gpt-chat-") }
    /// Where a run's time stops for now: the present, or for a Codex task whose log has gone quiet ("running?") its
    /// last activity. What it has done since (waited for you, or a long step) isn't known, so it isn't counted for now;
    /// once it finishes or moves again (that end is known), that stretch is counted, estimated (≈).
    func liveEnd(_ id: String, now: Date = Date()) -> Date {
        Store.codexThread(id) && outOfSight(id) ? min(gptActive[id] ?? now, now) : now
    }
    /// Running, as far as KIKUmap can see now (what the menu-bar ring and the counts go by).
    var seenRunningChats: [Chat] { runningChats.filter { !outOfSight($0.id) } }

    /// The highlight of the branch a chat sits in (nil = no colour).
    func branchColor(_ id: String) -> NSColor? { Theme.highlight(map.branchColorKey(ofChat: id)) }

    /// The sidebar: every pinned chat, in the Claude app's order (placing one on the map doesn't remove it).
    /// Claude's pinned chats in Claude's order, then Claude Code sessions in the order they started —
    /// never reshuffled by activity.
    func pinnedList() -> [Chat] {
        chats.enumerated().filter { isShown($0.element) }.sorted {
            let a = Store.place($0.element), b = Store.place($1.element)
            return a != b ? a < b : $0.offset < $1.offset
        }.map { $0.element }
    }

    private static func group(_ c: Chat) -> Int { c.isCode || c.isCodexSession ? 1 : (c.isGPT ? 2 : 0) }

    /// Where a chat goes in the left column: its group, then Claude's (ChatGPT's) pinned order; a session without one by
    /// when it started (then its id), not by when it was last active.
    private static func place(_ c: Chat) -> (Int, Int, String, String) {
        let session = group(c) == 1
        return (group(c), c.pinIndex ?? Int.max, session ? c.startedAt ?? "" : "", session ? c.id : "")
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

    /// (A "needs you?" doubt stays: reading the chat answers nothing, and marked unread again it's that again, not a sure
    /// "needs you"; see `maybeAnswered`.)
    func markSeen(_ ids: [String]) {
        for id in ids {
            let u = chat(id)?.updated_at ?? ""
            // a ChatGPT thread: read as of now, and in any case just after its last change ("+" sorts after it), since
            // its dot in ChatGPT may stay until it's opened there
            seen[id] = chat(id)?.isGPT == true ? max(Clock.iso(), u + "+") : (u.isEmpty ? Clock.iso() : u)
            // a Claude-app chat: its unread mark in Claude's sidebar may stay until it's opened there; passed over
            // (so is ChatGPT's dot on an ordinary chat)
            if chat(id)?.outsideClaude == false || gptMarked.contains(id) { dismissed[id] = u }
            axUnread.remove(id)
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
            dismissed.removeValue(forKey: id)
        }
        if changed { saveChats() }
        saveSeen()
        notify()
    }

    private func saveSeen() {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let d = try? e.encode(seen) { write(d, seenURL) }
        if let d = try? e.encode(dismissed) { write(d, dismissedURL) }
        if let d = try? e.encode(gptMarked.sorted()) { write(d, gptDotsURL) }
    }

    private func saveRequests() {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let d = try? e.encode(RequestsFile(maybeAnswered: maybeAnswered, requests: requests)) { write(d, requestsURL) }
    }

    /// Everything written again from memory (another copy of KIKUmap may have written over it).
    func saveAll() { saveChats(); saveSeen(); saveRequests(); saveActivity(); saveHistory() }

    private func saveChats() {
        reindex()
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let d = try? e.encode(ChatsFile(refreshed_at: Clock.iso(), chats: chats)) { write(d, chatsURL) }
    }

    // MARK: activity (for the timeline)

    private func saveActivity() {
        // the hours before the timeline's week go into the hourly totals whole, every run in them at once (one that goes
        // on past them, its part in them): runs side by side share them there as on the timeline (folded one at a
        // time, each would have had the hour to itself)
        let back = Date().addingTimeInterval(-8 * 86400)
        let cutoff = Clock.iso(Calendar.current.dateInterval(of: .hour, for: back)?.start ?? back)
        var old: [Interval] = []
        for k in intervals.indices where intervals[k].start < cutoff {
            var part = intervals[k]
            if part.end > cutoff { part.end = cutoff; intervals[k].start = cutoff }
            old.append(part)
        }
        if !old.isEmpty { fold(old) }
        intervals.removeAll { $0.end <= cutoff }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        if let d = try? e.encode(ActivityFile(intervals: intervals, open: runStart)) { write(d, activityURL) }
    }

    /// Intervals leaving the timeline are added to the hourly totals (kept for about a year), so the
    /// statistics can still show any hours of them.
    private func fold(_ old: [Interval]) {
        let cal = Calendar.current
        // (estimated time goes in under "≈" + its chat, so it's still told apart)
        let runs = old.compactMap { iv -> (id: String, a: Date, b: Date)? in
            guard let a = Clock.parse(iv.start), let b = Clock.parse(iv.end) else { return nil }
            return ((iv.est == true ? "≈" : "") + iv.id, a, b)
        }
        Store.shareSeenFirst(runs) { id, from, b, part in
            var a = from
            while a < b {
                let e = min(b, cal.dateInterval(of: .hour, for: a)?.end ?? b)
                self.history[Store.hourKeyFormatter.string(from: a), default: [:]][id, default: 0] += e.timeIntervalSince(a) * part
                a = e
            }
        }
        for iv in old { historyTitles[iv.id] = name(iv.id) }
        // about a year, counted back from the newest time folded: a clock set far ahead, even once, can't empty it
        let newest = runs.map(\.b).max() ?? Date()
        let keep = Store.dayFormatter.string(from: min(Date(), newest).addingTimeInterval(-400 * 86400))
        history = history.filter { $0.key >= keep }
        let ids = Set(history.values.flatMap { $0.keys }.map { $0.hasPrefix("≈") ? String($0.dropFirst()) : $0 })
        historyTitles = historyTitles.filter { ids.contains($0.key) }
        saveHistory()
    }

    private func saveHistory(report: Bool = true) {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        if let d = try? e.encode(HistoryFile(days: history, titles: historyTitles)) { write(d, historyURL, report: report) }
    }

    /// KIKUmap is quitting, or the Mac going to sleep: running chats stop counting now (nothing can be seen
    /// while it's away, and time it can't see isn't counted). Quitting, runs out of sight end too, with the ≈ time
    /// Today showed for them: the next launch knows nothing of them. Not at a sleep: they stay, the sleep left out.
    func closeRuns(at when: Date, quitting: Bool = false) {
        // (before `sleptAt` moves to now: the Mac's last sleep is still left out of them, as Today left it out)
        if quitting { endUnseen(paused, at: when) }
        sleptAt = when
        // going to sleep: until the wake nothing opens again (a read under way, a hook line, can still land meanwhile)
        if !quitting { asleep = true; sleptUptime = ProcessInfo.processInfo.systemUptime }
        for id in Array(runStart.keys) { endRun(id, at: when) }
        // with nothing open too: all that's in memory is on disk before KIKUmap goes (a Mac asleep may never wake)
        saveActivity()
    }

    /// A run's time ends at `when` (a sleep, a quit, the task gone from the list); a Codex task whose log went quiet
    /// ("running?"): seen up to its last activity, the rest estimated. Saved at once: a run still open on disk would
    /// be ended at KIKUmap's last minute by the next launch.
    private func endRun(_ id: String, at when: Date) {
        guard let start = runStart.removeValue(forKey: id) else { return }
        let seenTo = min(when, liveEnd(id, now: when))
        intervals.append(Interval(id: id, start: start, end: max(start, Clock.iso(seenTo))))
        if seenTo < when, let s = Clock.parse(start) { estimate(id, from: max(seenTo, s), to: estimatedEnd(id, seen: max(seenTo, s), by: when)) }
        saveActivity()
    }

    /// The Mac woke up: chats still running count again from now (the next read says whether they still are).
    func resumeRuns(at when: Date) {
        awakeSince = when
        unwatched()                       // Claude's list may still show how it was before the sleep
        // (Claude or ChatGPT in front before the sleep says nothing of what finished during it)
        claudeFrontSince = false; gptFrontSince = false
        let now = Clock.iso(when)
        var changed = false
        // a run opened anyway since the sleep notice (nothing should open one) counts from the wake, not through the sleep
        if asleep, let z = sleptAt.map(Clock.iso) {
            for (id, s) in runStart where s > z && s < now { runStart[id] = now; changed = true }
        }
        asleep = false
        for id in running where runStart[id] == nil && !paused.contains(id) { runStart[id] = now; changed = true }
        if changed { saveActivity() }
    }

    /// Records when chats start and stop running (a paused chat's time waits for the sidebar to see it again; none opens
    /// while the Mac sleeps, see `openRun`).
    private func track(_ nowRunning: Set<String>, at now: String) {
        var changed = false
        let when = Clock.parse(now) ?? Date()
        for id in nowRunning where runBegan[id] == nil { runBegan[id] = when }
        runBegan = runBegan.filter { nowRunning.contains($0.key) }
        for id in nowRunning where runStart[id] == nil && !paused.contains(id) {
            guard let from = openRun(at: when) else { break }
            runStart[id] = from; changed = true
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
    /// `quietBefore`: notifications from before then (posted while KIKUmap wasn't running) update the chats but
    /// make no sound.
    func apply(_ notes: [Notif], quietBefore: Date = .distantPast) -> [Event] {
        var events: [Event] = []
        for n in notes {
            let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // "Claude is done using your computer." and similar carry no chat title
            if title.isEmpty || title.lowercased() == "claude" { continue }
            let when = Clock.iso(n.date)
            // what kind it is, as Claude marks it (a turn ended, or it waits for you), whatever its text says; one with
            // nothing to act on (a Code session's, computer use) is left out, also when it asks for an approval
            let kind = Store.kind(n.detail)
            if kind == .ignore { continue }
            // Claude's "needs your approval" names no chat: the one `approvalTarget` finds, else it's said as such (never
            // made into a chat of that name)
            if n.chatId == nil && Store.approvalTitles.contains(title) {
                switch approvalTarget(at: n.date) {
                case .shown: break
                case .chat(let id):
                    guard let k = index[id] else { break }
                    // (its row shows it waiting already: Claude's own word for it stays, mirrored on every read)
                    let known = chats[k].last_note.map(SidebarWatcher.waitingStatuses.contains) == true
                    if !known { chats[k].last_note = Store.isInputNote(n.body) ? n.body : Store.waitsMark + n.body }
                    if chats[k].updated_at < when { chats[k].updated_at = when }
                    // it waits for you now: no longer running (or "running?"), its time up to the request
                    stopRun(id, at: n.date)
                    maybeAnswered[id] = nil                  // (a new word from Claude: no "needs you?" doubt)
                    request(n.key, on: id)
                    if n.date >= quietBefore && !known { events.append(.needsInput(id)) }
                case .unknown(let why):
                    // (the banners of a request whose To-do has gone say nothing of this one)
                    if approvalAsked.map({ n.date.timeIntervalSince($0) >= Store.approvalShown }) ?? true { approvalKeys = [] }
                    approvalAsked = max(approvalAsked ?? .distantPast, n.date)
                    if !n.key.isEmpty { approvalKeys.insert(n.key) }
                    approvalUnsure = false                   // (a new request: Claude waits, for this one at least)
                    approvalNoChat = n.date < quietBefore ? .beforeLaunch : why
                }
                continue
            }
            var i = n.chatId.flatMap { index[$0] }
            if i == nil, let c = n.chatId {
                // an address new here: the chat known only by this title takes it on; a chat with another address is
                // another chat (one deleted since, say), and this one becomes a chat of its own
                if adopt(AXLink(id: c, path: "", title: title, flags: ""), taken: []) { i = index[c] }
            } else if i == nil {
                let owners = titleOwners()
                // (a Cowork task's may end in " · <account>")
                i = (owners[title] ?? title.range(of: " · ", options: .backwards).flatMap { owners[String(title[..<$0.lowerBound])] }).flatMap { index[$0] }
            }
            // a Cowork task or Code session no listed chat is (Code sessions come through Claude Code's hooks): left out
            if i == nil && kind != nil { continue }
            let id: String
            let input = kind.map { $0 == .waits } ?? Store.isInputNote(n.body)
            var known = false                       // the sidebar already showed it waiting: said once is enough
            if let i = i {
                known = input && chats[i].last_note.map(SidebarWatcher.waitingStatuses.contains) == true
                if chats[i].updated_at < when { chats[i].updated_at = when }
                if kind == nil { chats[i].title = title }
                // (a turn's end keeps no note; a request whose words don't say it is marked so)
                chats[i].last_note = kind == .ended ? nil : input && !Store.isInputNote(n.body) ? Store.waitsMark + n.body : n.body
                id = chats[i].id
            } else {
                id = n.chatId ?? ("n-" + Store.fnv(title))
                chats.append(Chat(id: id, title: title, updated_at: when, path: nil, source: "notification", last_note: n.body))
            }
            // its turn ended after a request that may have been answered ("needs you?"): taken as answered, the approved
            // run went on to here, estimated (a typical run's length at most: the wait for your answer isn't work), as a
            // Claude Code session's approved step is
            if !input, !running.contains(id), let asked = maybeAnswered[id], n.date >= asked {
                estimate(id, from: max(asked, n.date.addingTimeInterval(-typicalRun(id))), to: n.date)
            }
            stopRun(id, at: n.date)
            maybeAnswered[id] = nil                          // (a new word from Claude: no "needs you?" doubt)
            if input { request(n.key, on: id) }
            if n.date >= quietBefore && !known { events.append(input ? .needsInput(id) : .finished(id)) }
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

    /// The rules as shipped: also what's used for any rule that's missing or doesn't parse in rules.json.
    static let builtInRules: [String: String] = [
        "running": "(?i)(AXProgressIndicator|AXBusyIndicator|busy=1|spinner|animate-spin|generating|thinking|responding|running|in progress|正在)",
        "unread": "(?i)(unread|未读|未讀|未読|ungelesen|no leída|non lue|अपठित|belum dibaca|non letta|읽지 않은|não lida)",
        "current": "(?i)(sel=1|cur=page|cur=true|cur=1)",
    ]
    /// What's wrong with rules.json, if anything (the built-in rules stand in for it).
    private(set) var rulesProblem: String?
    private var rulesCache: (stamp: Date?, rules: Rules)?

    /// (Written only at launch, so a failure isn't one for the To-do: the built-in rules stand in for a missing file,
    /// and an old one still works and is brought up to date at the next launch.)
    func writeDefaultRules() {
        if FileManager.default.fileExists(atPath: rulesURL.path) {
            // still an old default unread rule (fewer of Claude's languages): bring it up to date, keep everything else
            if let d = try? Data(contentsOf: rulesURL), var r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let u = r["unread"] as? String, ["(?i)(unread|未读)", "(?i)(unread|未读|未讀|未読)"].contains(u) {
                r["unread"] = Store.builtInRules["unread"]
                if let out = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { write(out, rulesURL, report: false) }
            }
            return
        }
        var r: [String: Any] = Store.builtInRules
        r["_about"] = "Regexes matched against the sidebar flags in logs/claude-sidebar.txt. Changes apply on the next scan. A rule that's missing or doesn't parse falls back to the built-in one; \"\" turns it off."
        r["markFinishedUnread"] = true
        if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { write(d, rulesURL, report: false) }
    }

    /// rules.json, read again whenever it changes. A typo can't switch detection off: whatever doesn't parse uses
    /// the built-in rule (and the To-do says so).
    func loadRules() -> Rules {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: rulesURL.path))?[.modificationDate] as? Date
        if let c = rulesCache, c.stamp == stamp { return c.rules }
        var r = Rules()
        var problems: [String] = []
        var o: [String: Any] = [:]
        if let d = try? Data(contentsOf: rulesURL) {
            if let x = (try? JSONSerialization.jsonObject(with: d, options: [.json5Allowed])) as? [String: Any] { o = x }
            else { problems.append(tr("rules.json 不是有效的 JSON", "rules.json isn't valid JSON")) }
        }
        func rx(_ k: String) -> NSRegularExpression? {
            if let s = o[k] as? String {
                if s.isEmpty { return nil }                                  // "" turns the rule off on purpose
                if let x = try? NSRegularExpression(pattern: s) { return x }
                problems.append(tr("「\(k)」这条规则写得不对", "the \"\(k)\" rule has a mistake"))
            }
            return Store.builtInRules[k].flatMap { try? NSRegularExpression(pattern: $0) }
        }
        r.running = rx("running"); r.unread = rx("unread"); r.current = rx("current")
        if let b = o["markFinishedUnread"] as? Bool { r.markFinishedUnread = b }
        let problem = problems.isEmpty ? nil : problems.joined(separator: tr("；", "; "))
        if problem != rulesProblem, let p = problem { log("\(Clock.iso()) rules: \(p); using the built-in ones\n", file: "app.log") }
        rulesProblem = problem
        rulesCache = (stamp, r)
        return r
    }

    static func matches(_ rx: NSRegularExpression?, _ s: String) -> Bool {
        guard let rx = rx else { return false }
        return rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// The Claude app quit: nothing is running any more (not "finished" — no sound, no unread).
    func clearRunning() {
        let code = Set(chats.filter { $0.outsideClaude }.map { $0.id })
        missingSince = [:]
        unwatched()
        claudeFrontSince = false              // (Claude in front before it quit says nothing of what it shows next)
        // Claude's own runs: out of sight, not known to have stopped (a reply may finish on its servers); their time
        // stops at the last sighting, and Claude's next read says how they ended
        // the Claude app's own Code sessions stop with it (Claude warns that quitting interrupts them): ended at their
        // last word from the hooks, quietly
        var ended = false
        for id in running where id.hasPrefix("cc-") && chat(id)?.app == claudeBundleID {
            running.remove(id)
            if let k = index[id], let n = chats[k].last_note, Store.isInputNote(n) { chats[k].last_note = nil }   // its request went with it
            let end = Clock.iso(lastCodeEvent[id] ?? Date())
            if let start = runStart.removeValue(forKey: id), end > start { intervals.append(Interval(id: id, start: start, end: end)) }
            _ = endedQuietly(id, at: end)
            ended = true
        }
        if ended { saveActivity(); saveChats(); saveSeen() }
        let claude = running.subtracting(code)
        guard !claude.isEmpty else { if ended { notify() }; return }
        quitPaused.formUnion(claude)
        pause(claude)
        notify()
    }

    /// Runs out of sight that end here (KIKUmap quitting, ChatGPT turned off, gone from ChatGPT's list or from Claude's
    /// whole reads): their time after the last sighting, as
    /// Today showed it, is kept, estimated (a typical run's length at most, as when they're forgotten after 6 hours).
    /// No longer paused, so it isn't counted twice.
    private func endUnseen(_ ids: Set<String>, at when: Date) {
        for id in ids where paused.contains(id) && running.contains(id) {
            if let seen = seenRunningAt[id] { estimate(id, from: seen, to: estimatedEnd(id, seen: seen, by: when)) }
            paused.remove(id); quitPaused.remove(id)
        }
    }

    /// Claude's runs out of sight this long (Claude closed for hours) are no longer said to run: as of the last sighting.
    func forgetUnseenRuns(after secs: TimeInterval = 6 * 3600) {
        let gone = running.filter { paused.contains($0) && Date().timeIntervalSince(seenRunningAt[$0] ?? .distantPast) > secs }
        guard !gone.isEmpty else { return }
        // their time after the last sighting: estimated, a typical run's length at most
        for id in gone { if let seen = seenRunningAt[id] { estimate(id, from: seen, to: estimatedEnd(id, seen: seen, by: Date())) } }
        running.subtract(gone); paused.subtract(gone); quitPaused.subtract(gone)
        runBegan = runBegan.filter { running.contains($0.key) }
        notify()
    }

    /// The sidebar can't be seen (window closed, sidebar hidden, Code mode, Pinned folded, Accessibility off):
    /// the time of these running Claude-app chats stops when a read last saw them run. They stay running.
    func pause(_ ids: Set<String>) {
        unwatched()
        var changed = false
        for id in ids where !id.hasPrefix("cc-") && !id.hasPrefix("gpt-") && chat(id)?.outsideClaude != true && running.contains(id) {
            paused.insert(id)
            guard let start = runStart.removeValue(forKey: id) else { continue }
            let end = Clock.iso(max(seenRunningAt[id] ?? Clock.parse(start) ?? Date(), Clock.parse(start) ?? .distantPast))
            if end > start { intervals.append(Interval(id: id, start: start, end: end)) }
            changed = true
        }
        if changed { saveActivity() }
    }

    // MARK: Claude Code

    /// Events from the Claude Code hooks. Returns sounds to play; `needsTitle` gets sessions whose name should be
    /// (re)read from their transcript, once each. `quietBefore`: lines written before then (while KIKUmap wasn't
    /// running) update the sessions but make no sound.
    func apply(code evs: [CodeEvent], quietBefore: Date = .distantPast, needsTitle: (String, String) -> Void) -> [Event] {
        var events: [Event] = []
        var changed = false, seenChanged = false, timeChanged = false
        var titles: [String: String] = [:]
        let wasRunning = running
        for e in evs {
            let id = "cc-" + e.session
            // the session's own folder (where it was started), not where a `cd` in it has gone since
            let home = Store.sessionFolder(cwd: e.cwd, transcript: e.transcript)
            if index[id] == nil {
                guard e.name != "SessionEnd" else { continue }
                let cwd = home ?? e.cwd
                let folder = (cwd as NSString).lastPathComponent
                chats.append(Chat(id: id, title: folder.isEmpty ? "Claude Code" : folder, updated_at: "", path: nil,
                                  source: "code", last_note: nil, cwd: cwd.isEmpty ? nil : cwd, app: e.app.isEmpty ? nil : e.app,
                                  startedAt: Clock.iso(e.time)))
                reindex()
                changed = true
            }
            guard let i = index[id] else { continue }
            if !e.app.isEmpty && chats[i].app != e.app { chats[i].app = e.app; changed = true }
            // (not known from the transcript: the first folder seen stays)
            if let h = home, chats[i].cwd != h { chats[i].cwd = h; changed = true }
            else if home == nil, chats[i].cwd == nil, !e.cwd.isEmpty { chats[i].cwd = e.cwd; changed = true }
            if e.name == "UserPromptSubmit" && !e.entry.isEmpty {
                let scripted: Bool? = e.entry.hasPrefix("sdk-") ? true : nil
                if chats[i].headless != scripted { chats[i].headless = scripted; changed = true }
            }
            let quiet = chats[i].headless == true                   // a script's run: no sound, nothing to read
            let when = Clock.iso(e.time)
            // "t" is whole seconds: a line from the launch second still counts as new
            let loud = e.time.addingTimeInterval(1) > quietBefore
            let prev = lastCodeEvent[id]
            lastCodeEvent[id] = max(prev ?? e.time, e.time)
            // a word from the session after it may have been answered: that's settled (the approved step ran till now)
            if let asked = maybeAnswered[id], e.time >= asked {
                maybeAnswered.removeValue(forKey: id)
                // (a typical run's length at most: the wait for your answer isn't work)
                if e.name == "PostToolUse" { estimate(id, from: max(asked, e.time.addingTimeInterval(-typicalRun(id))), to: e.time); if let n = chats[i].last_note, Store.isInputNote(n) { chats[i].last_note = nil; changed = true } }
            }
            /// The turn is over: its time ends at `end`.
            func stop(at end: String) {
                running.remove(id)
                if let start = runStart.removeValue(forKey: id) {
                    if end > start { intervals.append(Interval(id: id, start: start, end: end)) }
                    timeChanged = true
                }
            }
            /// Over without a Stop (Esc, a closed terminal): nothing new to read, but its 12 hours start there.
            func stopQuietly(at end: String) {
                stop(at: end)
                if endedQuietly(id, at: end) { changed = true; seenChanged = true }
            }
            switch e.name {
            case "UserPromptSubmit":
                // a turn left open (Esc, an error, a closed terminal) and now a new one: the wait in between isn't work
                if running.contains(id), let p = prev, e.time.timeIntervalSince(p) > 60 { stop(at: Clock.iso(p)) }
                running.insert(id)
                // (not while the Mac sleeps, nor from before its last wake: see `openRun`)
                if runStart[id] == nil, let from = openRun(at: e.time) { runStart[id] = from; timeChanged = true }
                // you just wrote to it, so you've seen it: up to just before (hook times are whole seconds, and a reply or
                // an error in that same second is news)
                seen[id] = max(chats[i].updated_at, Clock.iso(e.time.addingTimeInterval(-1))); seenChanged = true
                if chats[i].last_note != nil { chats[i].last_note = nil; changed = true }
                titles[id] = e.transcript
            case "PostToolUse":
                running.insert(id)                                  // e.g. carrying on after you approved something
            case "Notification":
                let needs = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input", "worker_permission_prompt"]
                if needs.contains(e.kind) || (e.kind.isEmpty && e.message.range(of: "permission|approve|needs your|授权", options: [.regularExpression, .caseInsensitive]) != nil) {
                    // waiting on you to approve something (its kind says so, whatever its words: "w1 needs network access to
                    // …", "Auto mode has a … notice to acknowledge" are marked so, as Claude's own notifications are)
                    stop(at: when)
                    chats[i].updated_at = when
                    chats[i].last_note = Store.isInputNote(e.message) ? e.message : Store.waitsMark + e.message
                    changed = true
                    // its app is in front: you can answer right there, and no hook will say you did
                    if chats[i].app != nil, frontApp?() == chats[i].app, onlySession(chats[i]) { maybeAnswered[id] = e.time }
                    if loud && !quiet { events.append(.needsInput(id)) }
                } else if e.kind == "idle_prompt" || e.message.range(of: "waiting for your input", options: .caseInsensitive) != nil {
                    // idle a minute after the turn ended: one ended without a Stop (Esc) isn't running any more
                    if running.contains(id) { stopQuietly(at: Clock.iso(prev ?? e.time)) }
                    // at its prompt, so nothing asks for your approval any more (one cancelled with Esc)
                    if let n = chats[i].last_note, Store.isInputNote(n) { chats[i].last_note = nil; changed = true }
                }
            case "Stop", "StopFailure":
                stop(at: when)
                chats[i].updated_at = when
                // an API error (a limit, an outage) ended the turn: say so
                let failed = e.name == "StopFailure"
                chats[i].last_note = failed ? Store.stopMark + Store.codeStopMark + (e.error.isEmpty ? "API" : e.error) : nil
                changed = true
                if loud && !quiet { events.append(failed ? .needsInput(id) : .finished(id)) }
                if quiet { seen[id] = when; seenChanged = true }
                titles[id] = e.transcript
            case "SessionEnd":
                if running.contains(id) { stopQuietly(at: when) }
                if let n = chats[i].last_note, Store.isInputNote(n) { chats[i].last_note = nil; changed = true }
            default: break
            }
        }
        for (id, t) in titles where !t.isEmpty { needsTitle(id, t) }
        expireCode()
        track(running, at: Clock.iso())
        if timeChanged { saveActivity() }
        if changed { saveChats() }
        if seenChanged { saveSeen() }
        if changed || seenChanged || running != wasRunning || timeChanged { notify() }
        return events.filter(shown)
    }

    /// A Claude Code session that has sent nothing for 20 minutes (while the Mac was awake) isn't running any more:
    /// a turn ended by Esc, or a terminal closed, sends no Stop. Its time ends at its last event: no sound, not unread.
    @discardableResult
    func expireCode(now: Date = Date()) -> Bool {
        let stale = running.filter { id in
            id.hasPrefix("cc-") && now.timeIntervalSince(max(lastCodeEvent[id] ?? .distantPast, awakeSince)) > 20 * 60
        }
        guard !stale.isEmpty else { return false }
        for id in stale {
            running.remove(id)
            let end = Clock.iso(lastCodeEvent[id] ?? now)
            if let start = runStart.removeValue(forKey: id), end > start { intervals.append(Interval(id: id, start: start, end: end)) }
            _ = endedQuietly(id, at: end)
        }
        saveActivity(); saveChats(); saveSeen()
        notify()
        return true
    }

    /// A Claude Code turn over without a Stop: shown for 12 hours from `end`, like one that stopped, and not unread
    /// (unless you marked it so). False if nothing changed.
    private func endedQuietly(_ id: String, at end: String) -> Bool {
        guard let i = index[id], chats[i].updated_at < end else { return false }
        chats[i].updated_at = end
        if seen[id] != "" && (seen[id] ?? "") < end { seen[id] = end }
        return true
    }

    // MARK: ChatGPT

    /// The ChatGPT app's threads, read from ~/.codex. Returns sounds to play. Pins follow ChatGPT's.
    /// `pinsRead`: ChatGPT's window state, where it keeps its pins, was read (so a pin missing from it is gone).
    func apply(gpt threads: [GPTThread], unread: Set<String>?, pinsRead: Bool = true, front: Bool) -> [Event] {
        var events: [Event] = []
        var changed = false, seenChanged = false, dotsChanged = false
        let now = Clock.iso()
        // ChatGPT in front now, or at some point since a task finished: you were looking at it (its log is read a
        // second or two after, when you may have switched apps already; a time still to come is from before the clock
        // was set back)
        func sawFinish(_ f: Date) -> Bool { front || (gptLeftAt >= f && gptLeftAt <= Date()) }
        for t in threads {
            let id = "gpt-" + t.id
            let before = gptActive[id]
            if let a = t.lastActive { gptActive[id] = a }
            // its log moves again after a quiet stretch ("running?"): that stretch (it waited for you, or a long step
            // ran) is counted as estimated, time asleep aside; seen time goes on from the new activity
            if t.running && running.contains(id), let b = before, let a = t.lastActive, a.timeIntervalSince(b) > 180,
               let start = runStart[id], let s = Clock.parse(start) {
                if b > s { intervals.append(Interval(id: id, start: start, end: Clock.iso(b))) }
                estimate(id, from: max(b, s), to: a)
                runStart[id] = Clock.iso(max(a, s))
                saveActivity()
            }
            guard let i = index[id] else {
                // already there before KIKUmap saw it: not unread (unless ChatGPT's own list says so)
                // (an ordinary chat has no time of its own here: none is shown rather than a guess)
                chats.append(Chat(id: id, title: t.title, updated_at: t.isChat ? "" : Clock.iso(t.finished ?? t.updated), path: nil, source: "gpt",
                                  last_note: nil, pinned: t.pinned ? true : nil, cwd: t.cwd.isEmpty ? nil : t.cwd,
                                  app: t.editor.map { $0.isEmpty ? "codex-cli" : $0 } ?? GPTWatcher.bundleID, startedAt: Clock.iso(t.updated)))
                chats[chats.count - 1].pinIndex = t.order
                if t.scripted { chats[chats.count - 1].headless = true }
                if !t.isChat { seen[id] = Clock.iso(t.finished ?? t.updated) }
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
            if t.scripted && chats[i].headless != true { chats[i].headless = true; changed = true }
            if t.isChat { continue }                                // its status comes from ChatGPT's window
            let quiet = chats[i].headless == true                   // a script's run: no sound, nothing to read
            if t.running && !running.contains(id) {
                running.insert(id)
                // it moves again after going quiet: the stretch since its counted time is counted too (estimated;
                // not after 6 hours: by then it may have been left)
                if gptQuiet.remove(id) != nil, let from = gptQuietUntil.removeValue(forKey: id), let a = t.lastActive,
                   a > from, a.timeIntervalSince(from) <= 6 * 3600 { estimate(id, from: from, to: a) }
                // you just asked it something: read up to just before its log last moved (a finish in that second is news)
                seen[id] = max(chats[i].updated_at, Clock.iso(min(t.lastActive ?? Date(), Date()).addingTimeInterval(-1))); seenChanged = true
                changed = true
            } else if !t.running && running.contains(id) {
                running.remove(id)
                if t.quiet {
                    gptQuiet.insert(id)                             // quiet, not finished: its finish is still to come
                    // its seen time ends where its log went quiet; after that, estimated (a typical task's length at most)
                    if let start = runStart.removeValue(forKey: id) {
                        let quietFrom = max(t.lastActive ?? Date(), Clock.parse(start) ?? .distantPast)
                        let end = Clock.iso(quietFrom)
                        if end > start { intervals.append(Interval(id: id, start: start, end: end)) }
                        let until = estimatedEnd(id, seen: quietFrom, by: Date())
                        estimate(id, from: quietFrom, to: until)
                        gptQuietUntil[id] = until
                        saveActivity()                          // (a long run has nothing estimated: saved all the same)
                    }
                } else {
                    // its log quiet a while ("running?") before the finish: seen up to its last activity, the rest
                    // estimated, as when it moves again
                    if let b = before, let fin = t.finished, fin.timeIntervalSince(b) > 180,
                       let start = runStart.removeValue(forKey: id), let s = Clock.parse(start) {
                        if b > s { intervals.append(Interval(id: id, start: start, end: Clock.iso(b))) }
                        estimate(id, from: max(b, s), to: fin)
                        saveActivity()
                    }
                    let when = Clock.iso(t.finished ?? Date())
                    chats[i].updated_at = when
                    if t.stopped {
                        seen[id] = when; seenChanged = true         // you pressed Stop: nothing new to read, no sound
                    } else if quiet {
                        seen[id] = when; seenChanged = true         // a script's run: nothing to read, no sound
                    } else if let f = t.finished {
                        events.append(.finished(id))
                        // you were looking at ChatGPT (its own threads; a session runs in its editor, like Claude Code)
                        if sawFinish(f) && !chats[i].isCodexSession { seen[id] = when; seenChanged = true }
                    }
                }
                changed = true
            } else if !t.running, let f = t.finished.map(Clock.iso), f > chats[i].updated_at {
                chats[i].updated_at = f                             // finished while KIKUmap wasn't watching
                if t.stopped { gptQuiet.remove(id); seen[id] = f; seenChanged = true }      // stopped: nothing to read
                else if gptQuiet.remove(id) != nil {
                    // the quiet task did finish: its time runs to that known finish, estimated as when it moves again
                    // (what it did while quiet isn't known: it waited for you, or a long step ran; not after 6 hours)
                    if let from = gptQuietUntil.removeValue(forKey: id), let fin = t.finished, fin > from, fin.timeIntervalSince(from) <= 6 * 3600 {
                        estimate(id, from: from, to: fin)
                    }
                    if !quiet { events.append(.finished(id)) }
                }
                changed = true
            }
        }
        // archived or gone from the list: no longer running (one whose log had gone quiet: seen up to its last activity)
        let listed = Set(threads.map { "gpt-" + $0.id })
        for id in running where id.hasPrefix("gpt-") && !listed.contains(id) {
            endUnseen([id], at: Date())      // one out of sight keeps the ≈ time Today showed for it
            endRun(id, at: Date()); running.remove(id); paused.remove(id); changed = true
        }
        // unpinned or deleted in ChatGPT, so no longer listed: no longer pinned here either
        for i in chats.indices where pinsRead && chats[i].isGPT && chats[i].pinned == true && !listed.contains(chats[i].id) {
            chats[i].pinned = nil; changed = true
        }
        // ChatGPT's own unread dots. One read there (no dot) is read here too, also in `seen`, so it stays read if
        // ChatGPT ever stops saying.
        if let list = unread.map({ Set($0.map { "gpt-" + $0 }) }) {
            if list != gptListed { gptListed = list; dotsChanged = true }
            // ChatGPT's read state takes over: a dot that comes back later is unread again
            for c in chats where c.isGPT && !c.isCodexSession && !c.isGPTChat && !list.contains(c.id) && !running.contains(c.id)
                && seen[c.id] != "" && seen[c.id] != c.updated_at && !c.updated_at.isEmpty {
                seen[c.id] = c.updated_at; seenChanged = true
            }
        }
        if changed {
            track(running, at: now)
            saveChats()
        }
        if seenChanged { saveSeen() }
        let unsure = Set(running.filter { $0.hasPrefix("gpt-") && outOfSight($0) })
        if unsure != gptUnsure { gptUnsure = unsure; dotsChanged = true }
        if changed || seenChanged || dotsChanged { notify() }
        let out = events.filter(shown)
        // what its sounds go by: ChatGPT in front now, or at some point since each finish they announce
        let ends = Dictionary(threads.compactMap { t in t.finished.map { ("gpt-" + t.id, $0) } }, uniquingKeysWith: { a, _ in a })
        gptWasFront = front || (!out.isEmpty && out.allSatisfy { e in
            if case .finished(let id) = e, let f = ends[id] { return sawFinish(f) }
            return false
        })
        return out
    }

    /// The pinned ordinary ChatGPT chats' names (to look for in ChatGPT's sidebar), and whether one of them runs.
    var gptChatNames: [String] { chats.filter { $0.isGPTChat && $0.pinned == true }.map(\.title) }
    var gptChatRunning: Bool { running.contains { $0.hasPrefix("gpt-chat-") } }
    /// A pinned ordinary ChatGPT chat that was running is out of sight now ("running?").
    var gptChatUnseen: Bool { running.contains { $0.hasPrefix("gpt-chat-") && paused.contains($0) } }

    /// ChatGPT's window was read: its pinned ordinary chats' rows, by name, and the name of the chat open in it; nil
    /// rows: it can't be seen now. A chat whose row shows a status runs; once the status goes, it's done: unread,
    /// unless it's the chat open in ChatGPT in front (you watched it finish). If ChatGPT's failed mark took the
    /// status's place, the reply failed: it shows "reply failed" (ChatGPT's words for the mark once it has them in
    /// its language), and it wants you, not "done" (as a Claude chat that stops on an error); that goes once its row
    /// doesn't show the mark. Opening it there reads it. A chat out of sight (or whose row isn't found: renamed just
    /// now, or a name two pinned chats share) keeps its state, a running one "running?" with its time as of the last
    /// sighting. Returns sounds to play.
    func apply(gptWindow rows: [String: GPTSidebarRow]?, open: String?, front: Bool, at date: Date = Date()) -> [Event] {
        var events: [Event] = []
        var changed = false, seenChanged = false, moved = false
        let now = Clock.iso(date)
        // ChatGPT in front now, or at some point since its window was last read: the chat open there that finished
        // meanwhile was watched, as with Claude's (the read after you switch apps comes a moment later; a read takes
        // a few hundredths of a second, so leaving during one isn't looked for)
        let watched = front || gptFrontSince
        gptWasFront = watched
        gptFrontSince = front
        let mine = chats.indices.filter { chats[$0].isGPTChat && chats[$0].pinned == true }
        var named: [String: Int] = [:]
        for i in mine { named[GPTSidebar.norm(chats[i].title), default: 0] += 1 }
        for i in mine {
            let id = chats[i].id, name = GPTSidebar.norm(chats[i].title)
            guard let rows, named[name] == 1, let r = rows[name] else {
                if running.contains(id) && !paused.contains(id) { hideGPTChat(id, at: date); moved = true }
                if rows != nil && gptChatsRead.remove(id) != nil { moved = true }
                continue                                            // its dot as last seen stays: nothing new to go by
            }
            if gptChatsRead.insert(id).inserted { moved = true }
            let looking = watched && open.map(GPTSidebar.norm) == name
            if r.working {
                // running again after a stretch out of sight: it ran through it (estimated, time asleep aside)
                if paused.remove(id) != nil, let s = seenRunningAt[id] { estimate(id, from: s, to: date); moved = true }
                if !running.contains(id) {
                    running.insert(id)
                    // you just asked it something: read up to just before (a reply over within that second is news)
                    seen[id] = max(chats[i].updated_at, Clock.iso(date.addingTimeInterval(-1))); seenChanged = true
                    moved = true
                }
                seenRunningAt[id] = date
            } else if running.contains(id) {
                running.remove(id)
                // finished while out of sight: when isn't known, so its time after the last sighting is estimated (and its
                // time says "done after" the sighting)
                if paused.remove(id) != nil, let s = seenRunningAt[id] { estimate(id, from: s, to: estimatedEnd(id, seen: s, by: date)) }
                dateFound(i, now, lastSeen: seenRunningAt[id]); changed = true
                finishedAt[id] = date
                // you watched it finish: no sound. Not if ChatGPT has left the front and puts its unread dot on it: it
                // ended after you looked away (a finish watched with ChatGPT in front never rings, dot or not)
                if looking && (front || !r.unread) { seen[id] = now; seenChanged = true }
                else if let f = r.failed {
                    // the reply failed (ChatGPT's failed mark took the spinner's place): "reply failed" (or ChatGPT's
                    // own words for it in its language), and it wants you
                    chats[i].last_note = Store.stopMark + Store.gptFailMark + f
                    events.append(.needsInput(id))
                }
                else { events.append(.finished(id)) }
                moved = true
            } else if looking && !r.unread && isUnread(chats[i]) {
                seen[id] = max(now, chats[i].updated_at + "+"); seenChanged = true
            }
            // the failure it stopped on: shown while ChatGPT's row shows its mark (running again, or read or retried
            // there: over)
            if r.failed == nil, let n = chats[i].last_note, n.hasPrefix(Store.stopMark) { chats[i].last_note = nil; changed = true }
            // ChatGPT's yellow dot (a reply you haven't read through): mirrored. It shows: unread (if KIKUmap had it read,
            // the reply came where it didn't see, dated now), unless you marked it read here since. It goes: read there.
            if r.unread && !r.working && !running.contains(id) {
                if gptMarked.insert(id).inserted { moved = true; seenChanged = true }
                let u = chats[i].updated_at
                if !(dismissed[id] == u && !u.isEmpty) && !isUnread(chats[i]) {
                    // (came after its row was last seen; at a launch, after its last change known)
                    if u < now { dateFound(i, now, lastSeen: rowSeenAt[id] ?? Clock.parse(u)); changed = true }
                    seen[id] = ""; seenChanged = true
                }
            } else if gptMarked.remove(id) != nil {
                dismissed.removeValue(forKey: id)
                if !r.working && isUnread(chats[i]) { seen[id] = chats[i].updated_at }
                moved = true; seenChanged = true
            }
            rowSeenAt[id] = date
        }
        if moved || changed { track(running, at: now) }
        if changed { saveChats() }
        if seenChanged { saveSeen() }
        if moved || changed || seenChanged { notify() }
        return events.filter(shown)
    }

    /// A running ordinary ChatGPT chat out of sight: it stays running ("running?"), its time as of the last sighting.
    private func hideGPTChat(_ id: String, at date: Date) {
        paused.insert(id)
        if seenRunningAt[id] == nil { seenRunningAt[id] = date }
        guard let start = runStart.removeValue(forKey: id) else { return }
        let end = Clock.iso(max(seenRunningAt[id] ?? date, Clock.parse(start) ?? .distantPast))
        if end > start { intervals.append(Interval(id: id, start: start, end: end)) }
        saveActivity()
    }

    /// ChatGPT was turned off: forget its threads' running and unread state.
    func clearGPT() {
        let before = running
        // (a task whose log had gone quiet: seen up to its last activity; an ordinary chat out of sight: its ≈ time so
        // far is kept, and counts again once ChatGPT is back on)
        for id in running where id.hasPrefix("gpt-") { endRun(id, at: Date()) }
        endUnseen(paused.filter { $0.hasPrefix("gpt-") }, at: Date())
        running = running.filter { !$0.hasPrefix("gpt-") }
        paused = paused.filter { !$0.hasPrefix("gpt-") }
        // (ChatGPT's dots on its ordinary chats as last seen stay, as their read state does: a dot gone by the next
        // read once it's on again was read in ChatGPT)
        gptChatsRead = []
        let dots = gptListed != nil
        gptListed = nil
        gptQuiet = []; gptQuietUntil = [:]
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
    /// Only a real address takes over (a twin with the same title is a chat of its own), and never a record that
    /// another row of this read is.
    private func adopt(_ l: AXLink, taken: Set<String>) -> Bool {
        guard !l.title.isEmpty, !l.id.hasPrefix("n-"),
              let i = chats.firstIndex(where: { $0.id.hasPrefix("n-") && $0.title == l.title && !taken.contains($0.id) }) else { return false }
        let old = chats[i].id
        chats[i].id = l.id
        chats[i].path = l.path.isEmpty ? nil : l.path
        if !l.path.isEmpty { chats[i].liveAt = Clock.iso() }
        if let p = l.pinned { chats[i].pinned = p }
        reindex()
        if let s = seen.removeValue(forKey: old) { seen[l.id] = s; saveSeen() }
        map.renameChat(old, to: l.id)
        moveState(old, to: l.id)
        return true
    }

    /// A chat's id changed (its address became known, or a copy under a new name was folded in): its running
    /// state and its time go with it, instead of staying behind under the old id.
    private func moveState(_ old: String, to new: String) {
        guard old != new else { return }
        idMoves += 1
        if running.remove(old) != nil { running.insert(new) }
        if axUnread.remove(old) != nil { axUnread.insert(new) }
        if paused.remove(old) != nil { paused.insert(new) }
        if quitPaused.remove(old) != nil { quitPaused.insert(new) }
        if let b = runBegan.removeValue(forKey: old) { runBegan[new] = b }
        if let f = finishedAt.removeValue(forKey: old) { finishedAt[new] = f }
        if let s = seenRunningAt.removeValue(forKey: old) { seenRunningAt[new] = s }
        if let m = missingSince.removeValue(forKey: old) { missingSince[new] = m }
        if let r = rowSeenAt.removeValue(forKey: old) { rowSeenAt[new] = r }
        if let a = maybeAnswered.removeValue(forKey: old) { maybeAnswered[new] = a }
        for (k, v) in requests where v == old { requests[k] = new }        // its notifications are still its own
        var moved = false
        if let start = runStart.removeValue(forKey: old) {
            if runStart[new] == nil { runStart[new] = start }
            moved = true
        }
        for k in intervals.indices where intervals[k].id == old { intervals[k].id = new; moved = true }
        if moved { saveActivity() }
        onIDMove?(old, new)
    }

    /// A chat's id changed (its address became known, a copy folded in): for what others keep by it (the archive).
    var onIDMove: ((String, String) -> Void)?

    /// Renamed in Claude (seen while open, so its address is known). The copy picked up under the new
    /// name before that — an "n-" id — is folded in, with its place on the map.
    private func retitle(_ i: Int, _ title: String, taken: Set<String> = []) {
        let id = chats[i].id
        chats[i].title = title
        // (never a copy another row of this read is: that's a chat of its own)
        guard let j = chats.firstIndex(where: { $0.id.hasPrefix("n-") && $0.title == title && !taken.contains($0.id) }) else { return }
        let dup = chats[j].id
        let placed = map.placedChats()
        if placed.contains(dup) && !placed.contains(id) { map.renameChat(dup, to: id) }
        if !map.placedChats().contains(dup) {
            chats.remove(at: j)
            reindex()                                     // before anything below looks a chat up
            seen.removeValue(forKey: dup)
            moveState(dup, to: id)
        }
    }

    /// The Claude app's sidebar was read: which chats run, which are unread, which one is open.
    /// `whole`: the chat list was read with nothing in the way (no sync problem): a running chat missing from it is
    /// gone. `readKnown`: Claude's unread marks can be relied on, so a listed chat without one has been read in Claude.
    /// `startedAt`: when this read of the sidebar began (a chat that finished after that isn't running again).
    func apply(scan links: [AXLink], claudeFront: Bool, noPins: Bool = false, readKnown: Bool = false,
               startedAt: Date = .distantFuture, whole: Bool = true) -> [Event] {
        func claudeRunning() -> Set<String> { running.filter { !$0.hasPrefix("cc-") && !$0.hasPrefix("gpt-") && chat($0)?.outsideClaude != true } }
        // Claude in front now, or at some point since the last read began: the chat open there that finished meanwhile
        // was watched (this read comes back a second or so after the finish, when you may have switched apps already)
        let watched = claudeFront || claudeFrontSince
        claudeWasFront = watched
        // and for the next read: in front now, or it left after this read began (not at a time still to come: that's
        // from before the clock was set back)
        claudeFrontSince = claudeFront || (claudeLeftAt >= startedAt && claudeLeftAt <= Date())
        // An empty read means the sidebar is hidden or still loading, not that everything finished. A list read whole
        // and empty (every chat deleted, another account) is read like any other: what it doesn't list isn't there.
        guard !links.isEmpty || whole else {
            var changed = false
            for i in chats.indices where noPins && !chats[i].outsideClaude && chats[i].pinned == true { chats[i].pinned = false; changed = true }
            pause(claudeRunning())                                 // nothing seen: their time waits
            if changed { saveChats(); notify() }
            return []
        }
        // an approval Claude asked for without naming the chat: a whole read begun after it shows which chat waits, if
        // one still does (its row says so), so the question is settled
        if whole, let a = approvalAsked, startedAt > a { approvalAsked = nil; approvalKeys = []; approvalUnsure = false }
        var links = links
        let rules = loadRules()
        let now = Clock.iso()
        var changed = false, seenChanged = false
        // the pins weren't all seen: what changes by the next read may be more than one change
        if !whole || !links.contains(where: { $0.pinned == true }) { unwatched() }
        // renamed in Claude: one pinned row no chat knows, in the place of one pinned chat no row shows any more
        if let r = renamed(links) {
            let (k, j) = r, old = chats[j].id
            if old.hasPrefix("n-") {
                // known only by its title: the record takes the new title's id and the title, with its place on the map
                // and its state (rows with an "n-" id are never retitled below)
                let new = links[k].id
                chats[j].id = new
                chats[j].title = links[k].title
                changed = true
                reindex()
                if let v = seen.removeValue(forKey: old) { seen[new] = v; seenChanged = true }
                if let v = dismissed.removeValue(forKey: old) { dismissed[new] = v }
                map.renameChat(old, to: new)
                moveState(old, to: new)
            } else {
                links[k] = AXLink(id: old, path: "", title: links[k].title, flags: links[k].flags, pinned: true)
            }
            log("\(Clock.iso()) a pinned chat was renamed in Claude: \(old) kept\n", file: "app.log")
        }
        var nowRunning = Set<String>(), nowUnread = Set<String>()
        var current: String?
        for l in links {
            // a notification said it finished after this read began: the spinner it saw is old news
            if SidebarWatcher.showsRunning(l.flags, rules.running), !(finishedAt[l.id].map { $0 > startedAt } ?? false) { nowRunning.insert(l.id) }
            if Store.matches(rules.unread, l.flags) {
                // marked read here since its last change: Claude's mark is passed over until it's opened there
                if let d = dismissed[l.id], let i = index[l.id], chats[i].updated_at <= d { } else {
                    nowUnread.insert(l.id)
                    // Claude marks it unread, though by KIKUmap's own record it was read: something came that KIKUmap
                    // didn't see (a reply from the phone, or with Claude's window closed): dated now, learned late (it came
                    // after its row was last read; at a launch, after its last change known)
                    if !axUnread.contains(l.id), let i = index[l.id], !chats[i].outsideClaude, !chats[i].updated_at.isEmpty,
                       chats[i].updated_at <= (seen[l.id] ?? ""), !running.contains(l.id) {
                        dateFound(i, now, lastSeen: rowSeenAt[l.id] ?? Clock.parse(chats[i].updated_at)); changed = true
                    }
                }
            } else if dismissed.removeValue(forKey: l.id) != nil {
                seenChanged = true                                  // Claude dropped its mark: nothing to pass over
            }
            if current == nil && Store.matches(rules.current, l.flags) { current = l.id }
        }
        var events: [Event] = []
        let ids = Set(links.map(\.id))
        let openNoted = Clock.iso(Date().addingTimeInterval(-600))
        for l in links {
            if let i = index[l.id] {
                if (chats[i].path ?? "").isEmpty && !l.path.isEmpty { chats[i].path = l.path; changed = true }
                // open under its address (the only row with a path): noted at most every 10 minutes, not on every read
                if !l.path.isEmpty && (chats[i].liveAt ?? "") < openNoted { chats[i].liveAt = now; changed = true }
                if let p = l.pinned, chats[i].pinned != p { chats[i].pinned = p; changed = true }
                if !l.title.isEmpty && chats[i].title != l.title && !l.id.hasPrefix("n-") && !chats[i].outsideClaude {
                    retitle(i, l.title, taken: ids); changed = true
                }
            } else if adopt(l, taken: ids) {
                changed = true
            } else if !l.title.isEmpty {
                let active = nowRunning.contains(l.id) || nowUnread.contains(l.id)
                chats.append(Chat(id: l.id, title: l.title, updated_at: active ? now : "", path: l.path, source: "sidebar", last_note: nil, pinned: l.pinned,
                                  liveAt: l.path.isEmpty ? nil : now))
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
        let listed = ids
        // a request KIKUmap was unsure of ("needs you?"): its row, read since, says how it stands (running again,
        // still waiting, or neither: over), as below
        var settled = false
        for id in listed { if let t = maybeAnswered[id], startedAt > t { maybeAnswered[id] = nil; settled = true } }
        for id in nowRunning {
            // running again after a stretch out of sight: it ran through it (estimated, time asleep aside)
            if paused.contains(id), let seen = seenRunningAt[id] { estimate(id, from: seen, to: Date()) }
            seenRunningAt[id] = Date(); paused.remove(id); quitPaused.remove(id); missingSince.removeValue(forKey: id)
            // running again (say after you approved it): what it was waiting for is over
            if let i = index[id], needsInput(chats[i]) || chats[i].last_note.map(SidebarWatcher.waitingStatuses.contains) == true {
                chats[i].last_note = nil; changed = true
            }
        }
        let flagsOf = Dictionary(links.map { ($0.id, $0.flags) }, uniquingKeysWith: { a, _ in a })
        // finished while you weren't looking at it → waiting for you (and if Claude shows it waiting for your input or
        // an answer, it's that, not "done")
        for id in running.subtracting(nowRunning) where listed.contains(id) {
            guard let i = index[id] else { continue }
            let waits = flagsOf[id].flatMap(SidebarWatcher.waiting)
            // Claude quit while it ran, and now shows nothing new for it (no unread mark, no status): it stopped with
            // Claude, as far as anyone can tell; it ends quietly at its last sighting, not "done"
            if quitPaused.remove(id) != nil, waits == nil, !nowUnread.contains(id), flagsOf[id].flatMap(SidebarWatcher.unknownStatus) == nil {
                paused.remove(id); missingSince.removeValue(forKey: id)
                continue
            }
            // finished while out of sight: when isn't known, so its time after the last sighting is estimated (and its
            // time says "done after" the sighting: also after a sleep, or reads far apart)
            if paused.contains(id), let seen = seenRunningAt[id] { estimate(id, from: seen, to: estimatedEnd(id, seen: seen, by: Date())) }
            paused.remove(id); missingSince.removeValue(forKey: id)
            if watched && current == id {
                dateFound(i, now, lastSeen: seenRunningAt[id]); changed = true     // it changed (Export goes by this), and you saw it
                seen[id] = now; seenChanged = true
            } else if rules.markFinishedUnread || waits != nil {
                dateFound(i, now, lastSeen: seenRunningAt[id]); changed = true
                finishedAt[id] = Date()
                // stopped with a status KIKUmap doesn't know ("Your context window is full"…): Claude's words, and it
                // wants you, not "done"
                let err = flagsOf[id].flatMap(SidebarWatcher.unknownStatus)
                if let w = waits { chats[i].last_note = w }
                else if let e = err { chats[i].last_note = Store.stopMark + e }
                else if let n = chats[i].last_note, Store.isInputNote(n) || n.hasPrefix(Store.stopMark) { chats[i].last_note = nil }   // that's over
                events.append(waits != nil || err != nil ? .needsInput(id) : .finished(id))
            }
        }
        // a chat that's left the list (unpinned, deleted): its row can't say it still waits
        if whole {
            for i in chats.indices where !chats[i].outsideClaude && !listed.contains(chats[i].id) {
                if let n = chats[i].last_note, SidebarWatcher.waitingStatuses.contains(n) { chats[i].last_note = nil; changed = true }
            }
        }
        // Claude's "waiting for you" on a row, mirrored on every read (not only when KIKUmap saw it start): shown while
        // Claude shows it, and gone once it doesn't (answered here or elsewhere, or cancelled)
        for l in links where !nowRunning.contains(l.id) {
            guard let i = index[l.id], !chats[i].outsideClaude else { continue }
            if let w = SidebarWatcher.waiting(l.flags) {
                guard chats[i].last_note != w, !(claudeFront && current == l.id) else { continue }
                let wasUnread = isUnread(chats[i])
                chats[i].last_note = w
                if !wasUnread { chats[i].updated_at = now }
                changed = true
            } else if let n = chats[i].last_note, n.hasPrefix(Store.stopMark) {
                // the error status it stopped with: shown while Claude's row shows it
                if SidebarWatcher.unknownStatus(l.flags) == nil { chats[i].last_note = nil; changed = true }
            } else if let n = chats[i].last_note, SidebarWatcher.waitingStatuses.contains(n)
                        || (Store.isInputNote(n) && (finishedAt[l.id] ?? .distantPast) < startedAt) {
                chats[i].last_note = nil; changed = true
            }
        }
        // read inside the Claude app → read here too
        // (only while Claude's marks can be read: one worded anew, or a relaunch after Claude changed them, isn't "read")
        for id in axUnread.subtracting(nowUnread) where readKnown && !nowRunning.contains(id) && listed.contains(id)
                                                        && flagsOf[id].flatMap(SidebarWatcher.unknownStatus) == nil {
            if let i = index[id] {
                let u = chats[i].updated_at
                seen[id] = u.isEmpty ? now : max(u, seen[id] ?? ""); seenChanged = true
            }
        }
        if watched, let c = current, let i = index[c] {
            let u = chats[i].updated_at
            if !u.isEmpty && u > (seen[c] ?? "") { seen[c] = u; seenChanged = true }
            if dismissed.removeValue(forKey: c) != nil { seenChanged = true }
        }
        // Claude shows no unread mark on it, so it was read there (say while KIKUmap wasn't running): read here too.
        // Not one that finished in the last minute (Claude may not have marked it yet), one you marked unread, one
        // waiting for you (Claude marks that differently), or the one open in Claude's window while Claude hasn't been
        // in front since the last read (Claude never marks the chat it shows: no mark there says nothing about you
        // having seen it).
        if readKnown {
            for l in links where !nowRunning.contains(l.id) && !nowUnread.contains(l.id) && dismissed[l.id] == nil
                                  && (watched || l.id != current)
                                  && !SidebarWatcher.statusLabels(l.flags).contains(where: SidebarWatcher.waitingStatuses.contains)
                                  && SidebarWatcher.unknownStatus(l.flags) == nil {
                guard let i = index[l.id], !chats[i].outsideClaude, seen[l.id] != "", !needsInput(chats[i]) else { continue }
                if let f = finishedAt[l.id], Date().timeIntervalSince(f) < 60 { continue }
                let u = chats[i].updated_at
                if !u.isEmpty && u > (seen[l.id] ?? "") { seen[l.id] = u; seenChanged = true }
            }
        }
        // running Claude-app chats this read doesn't list (as of now: a title-only id that just got its address, above,
        // has passed its run on)
        let claudeRunning = claudeRunning()
        var gone = Set<String>()
        for id in claudeRunning.subtracting(listed) {
            if whole {
                // missing from whole reads for a minute (deleted while running, another account): it stopped, as of
                // when it went missing; no sound
                let since = missingSince[id] ?? Date()
                missingSince[id] = since
                if Date().timeIntervalSince(since) >= 60 {
                    gone.insert(id)
                    if let start = runStart.removeValue(forKey: id) {
                        let end = Clock.iso(max(since, Clock.parse(start) ?? since))
                        if end > start { intervals.append(Interval(id: id, start: start, end: end)) }
                        saveActivity()
                    }
                    // one out of sight keeps its ≈ time, up to when it went missing (one that stopped with Claude, as
                    // when it's listed, ends at its last sighting)
                    if !quitPaused.contains(id) { endUnseen([id], at: since) }
                    missingSince.removeValue(forKey: id); paused.remove(id); quitPaused.remove(id)
                    continue
                }
            }
            nowRunning.insert(id)
        }
        if !whole { pause(claudeRunning.subtracting(listed)) }
        nowRunning.formUnion(running.filter { $0.hasPrefix("cc-") || $0.hasPrefix("gpt-") || chat($0)?.outsideClaude == true })
        nowRunning.subtract(gone)
        nowUnread.formUnion(axUnread.subtracting(listed))
        let stateChanged = running != nowRunning || axUnread != nowUnread
        let read = Date()
        for id in listed { rowSeenAt[id] = read }
        track(nowRunning, at: now)
        running = nowRunning
        axUnread = nowUnread
        if changed { saveChats() }
        if seenChanged { saveSeen() }
        if changed || seenChanged || stateChanged || settled { notify() }
        return events.filter(shown)
    }

    /// A pinned chat renamed in Claude: exactly one pinned row that no chat knows (by id or title), in the same
    /// place as exactly one chat that was pinned until now and whose title no row shows any more, with as many
    /// pinned rows as before. (An unpin and a new pin come one read apart; a rename is one change.) Only while the
    /// list has been watched a while, and never when the row is open under an address of its own.
    private func renamed(_ links: [AXLink]) -> (row: Int, chat: Int)? {
        guard Date() >= renamesFrom else { return nil }
        let pinnedRows = links.indices.filter { links[$0].pinned == true }
        let rowIDs = Set(links.map(\.id)), rowTitles = Set(links.map(\.title))
        let fresh = pinnedRows.filter { k in
            index[links[k].id] == nil && !links[k].title.isEmpty && !chats.contains { !$0.outsideClaude && $0.title == links[k].title }
        }
        let before = chats.indices.filter { !chats[$0].outsideClaude && chats[$0].pinned == true }
        let vanished = before.filter { !rowIDs.contains(chats[$0].id) && !rowTitles.contains(chats[$0].title) }
        guard fresh.count == 1, vanished.count == 1, pinnedRows.count == before.count,
              let place = pinnedRows.firstIndex(of: fresh[0]), chats[vanished[0]].pinIndex == place,
              links[fresh[0]].path.isEmpty || chats[vanished[0]].id.hasPrefix("n-") else { return nil }
        return (fresh[0], vanished[0])
    }

    /// The list wasn't (or won't have been) seen whole, or wasn't read for a while: renames are worked out again
    /// only after a while.
    func unwatched() { renamesFrom = max(renamesFrom, Date().addingTimeInterval(Store.renameHold)) }

    /// Which chat a title stands for, when a row of Claude's sidebar or a notification gives only the title: one whose
    /// address is known before one known by its title alone; then one pinned in Claude (its row maps to it too, see
    /// SidebarWatcher.addresses); then the one open in Claude last (a deleted chat never is again); then the one last active.
    func titleOwners() -> [String: String] {
        var best: [String: (rank: (Int, Int, String, String), id: String)] = [:]
        for c in chats where !c.outsideClaude && !c.title.isEmpty {
            let r = (c.id.hasPrefix("n-") ? 0 : 1, c.pinned == true ? 1 : 0, c.liveAt ?? "", c.updated_at)
            if let b = best[c.title], b.rank >= r { continue }
            best[c.title] = (r, c.id)
        }
        return best.mapValues(\.id)
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

    /// Appends to a log in logs/. Past 1 MB the log moves to <name>.1.log (the one before that goes), so logs
    /// never grow without end. A full disk or a missing folder never stops anything.
    func log(_ text: String, file: String) {
        let fm = FileManager.default, url = logsDir.appendingPathComponent(file)
        guard let d = text.data(using: .utf8) else { return }
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        if let n = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, n.intValue > 1 << 20 {
            let old = url.deletingPathExtension().appendingPathExtension("1." + url.pathExtension)
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        guard fm.fileExists(atPath: url.path), let h = try? FileHandle(forWritingTo: url) else { try? d.write(to: url); return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: d)
    }
}
