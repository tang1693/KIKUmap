import Cocoa
import SQLite3
import ApplicationServices

let claudeBundleID = "com.anthropic.claudefordesktop"
let ownBundleID = "ninja.tang.claudeconsole"

// MARK: - FSEvents

/// Calls `handler` on the main queue whenever something under `paths` changes.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    let handler: @MainActor () -> Void

    init(paths: [String], latency: Double, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let w = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { w.handler() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let s = stream {
            FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
            FSEventStreamStart(s)
        }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}

// MARK: - Notification Center database

struct Notif {
    let recId: Int64
    let title: String
    let body: String
    let date: Date
    let chatId: String?
    let detail: String
    /// The record's own key (its uuid where macOS keeps one): told again when Claude takes the notification back.
    var key: String = ""
}

/// Watches macOS Notification Center's database; reports Claude's new notifications.
/// Each of Claude's notifications is known by its own id (row numbers come back when rows are removed, and start
/// over when the database is made anew), so none is missed and none is reported twice.
@MainActor
final class NotificationWatcher: NSObject {
    /// `unreadable`: access is there, but the database can't be read as expected (`problem` says why).
    enum Status { case starting, ok, noAccess, noDB, unreadable }
    private(set) var status = Status.starting
    private(set) var problem: String?
    var onNotes: (([Notif]) -> Void)?
    var onStatus: (() -> Void)?
    private let store: Store
    private var watcher: FileWatcher?
    private var retry: Timer?
    /// Claude's notifications in the database now, already handled (kept across launches).
    private var handled: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "HandledNotifs") ?? [])
    private let handledKey = "HandledNotifs"

    init(store: Store) {
        self.store = store
        super.init()
    }

    var dbPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"]
        var buf = [CChar](repeating: 0, count: 1024)
        if confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 {
            candidates.append(String(cString: buf) + "com.apple.notificationcenter/db2/db")
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        forgetOldLog()
        check()
        watcher?.stop()
        watcher = nil
        if let p = dbPath {
            watcher = FileWatcher(paths: [(p as NSString).deletingLastPathComponent], latency: 0.2) { [weak self] in self?.check() }
        }
    }

    /// Before 1.0 the log kept what each notification said (titles, the start of replies): that copy goes, once.
    private func forgetOldLog() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "NotifLogClean") else { return }
        for f in ["notifications.log", "notifications.1.log"] { try? FileManager.default.removeItem(at: store.logsDir.appendingPathComponent(f)) }
        d.set(true, forKey: "NotifLogClean")
    }

    /// No database where macOS keeps it. With Full Disk Access on, a macOS update moved it: that's `unreadable`
    /// (shown as on, with why), not access missing, which granting it again couldn't fix.
    static func missing(fullDisk: Bool) -> (Status, String?) {
        fullDisk ? (.unreadable, tr("它不在 macOS 原来放它的位置", "it isn't where macOS used to keep it")) : (.noDB, nil)
    }

    @objc private func retryTick() { recheck() }

    /// Checks access again; starts watching as soon as it's granted.
    func recheck() {
        let before = status
        check()
        if before != .ok && status == .ok { start() }
    }

    func check() {
        let before = status
        defer {
            if status != before { onStatus?() }
            if status == .ok {
                retry?.invalidate(); retry = nil
            } else if retry == nil {
                retry = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(retryTick), userInfo: nil, repeats: true)
            }
        }
        guard let path = dbPath else { (status, problem) = NotificationWatcher.missing(fullDisk: ClaudeExport.canLookInDownloads); return }
        // no access, or something else in the way
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            let e = errno
            if e == EPERM || e == EACCES { status = .noAccess } else { status = .unreadable; problem = String(cString: strerror(e)) }
            return
        }
        close(fd)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            problem = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db); status = .unreadable; return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        guard let rows = claudeRows(db) else { return }        // busy, or failed (status says which)
        status = .ok
        problem = nil
        let keys = Set(rows.map { $0.key })
        let d = UserDefaults.standard
        let firstRun = d.object(forKey: handledKey) == nil
        // coming from 0.9.x, which kept the last row number it had read: Claude's rows after it came while it was off
        let mark = firstRun ? (d.object(forKey: "LastNotifRecId") as? NSNumber)?.int64Value : nil
        let fresh = firstRun ? rows.filter { r in mark.map { r.note.recId > $0 } ?? false }.map { $0.note }
                             : rows.filter { !handled.contains($0.key) }.map { $0.note }
        let gone = handled.subtracting(keys), removed = gone.count
        if removed > 0 { store.log("\(Clock.iso()) [removed] \(removed) Claude notification(s) cleared or opened\n", file: "notifications.log") }
        if !gone.isEmpty && !firstRun { store.withdrawn(gone) }
        if keys != handled || firstRun {
            handled = keys
            d.set(Array(keys).sorted(), forKey: handledKey)
            if firstRun { d.removeObject(forKey: "LastNotifRecId") }       // only once this read has worked
        }
        if firstRun && mark == nil { writeLog(rows.suffix(10).map { $0.note }, "first run"); return }
        if !fresh.isEmpty {
            writeLog(fresh, "new")
            onNotes?(fresh)
        }
    }

    /// Every Claude notification in the database, with the key that stays its own: nil when it couldn't be read
    /// (busy: the status stays; anything else: `unreadable`).
    private func claudeRows(_ db: OpaquePointer?) -> [(key: String, note: Notif)]? {
        let filter = "(lower(a.identifier) LIKE '%anthropic%' OR lower(a.identifier) LIKE '%claude%')"
        var st: OpaquePointer?
        // with its uuid where the database has one (it has on current macOS); else its row and contents
        var withUUID = true
        if sqlite3_prepare_v2(db, "SELECT r.rec_id, a.identifier, r.data, r.delivered_date, hex(r.uuid) FROM record r JOIN app a ON a.app_id = r.app_id WHERE \(filter) ORDER BY r.rec_id", -1, &st, nil) != SQLITE_OK {
            // only a database without the column (older macOS) is read by row: busy or anything else is no read this
            // time (keys by row for one read would make every notification new, twice)
            guard String(cString: sqlite3_errmsg(db)).contains("no such column") else { fail(db); sqlite3_finalize(st); return nil }
            sqlite3_finalize(st); st = nil; withUUID = false
            guard sqlite3_prepare_v2(db, "SELECT r.rec_id, a.identifier, r.data, r.delivered_date FROM record r JOIN app a ON a.app_id = r.app_id WHERE \(filter) ORDER BY r.rec_id", -1, &st, nil) == SQLITE_OK else {
                fail(db); sqlite3_finalize(st); return nil
            }
        }
        defer { sqlite3_finalize(st) }
        var out: [(key: String, note: Notif)] = []
        let chatRx = try! NSRegularExpression(pattern: "/chat/([0-9a-fA-F-]{36})")
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW {
            defer { rc = sqlite3_step(st) }
            let bundle = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            if bundle == ownBundleID { continue }
            let rec = sqlite3_column_int64(st, 0)
            let req = NotificationWatcher.plist(st, 2)["req"] as? [String: Any] ?? [:]
            var extra: [String] = []
            for k in ["usda", "thre", "iden"] { if let v = req[k] { NotificationWatcher.flatten(v, k, into: &extra) } }
            let detail = extra.joined(separator: " | ")
            var chatId: String?
            let ns = detail as NSString
            if let m = chatRx.firstMatch(in: detail, range: NSRange(location: 0, length: ns.length)) {
                chatId = ns.substring(with: m.range(at: 1)).lowercased()
            }
            let when = sqlite3_column_double(st, 3)
            let title = (req["titl"] as? String) ?? "", body = (req["body"] as? String) ?? ""
            let uuid = withUUID ? (sqlite3_column_text(st, 4).map { String(cString: $0) } ?? "") : ""
            let key = uuid.isEmpty ? "r\(rec):" + Store.fnv(title + "\u{1}" + body + "\u{1}" + detail) : uuid
            out.append((key, Notif(recId: rec, title: title, body: body, date: when > 0 ? Date(timeIntervalSinceReferenceDate: when) : Date(),
                                   chatId: chatId, detail: detail, key: key)))
        }
        if rc != SQLITE_DONE { fail(db); return nil }
        return out
    }

    /// A read that failed: busy (try again soon, status unchanged), or something else (macOS changed the database?).
    private func fail(_ db: OpaquePointer?) {
        let code = sqlite3_errcode(db)
        if code == SQLITE_BUSY || code == SQLITE_LOCKED { return }
        let why = String(cString: sqlite3_errmsg(db))
        if problem != why { store.log("\(Clock.iso()) can't read Notification Center's database: \(why)\n", file: "notifications.log") }
        problem = why
        status = .unreadable
    }

    private static func plist(_ st: OpaquePointer?, _ col: Int32) -> [String: Any] {
        guard let blob = sqlite3_column_blob(st, col) else { return [:] }
        let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(st, col)))
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] ?? [:]
    }

    private static func flatten(_ v: Any, _ prefix: String, into out: inout [String]) {
        if let d = v as? [String: Any] {
            for (k, x) in d { flatten(x, prefix.isEmpty ? k : prefix + "." + k, into: &out) }
        } else if let a = v as? [Any] {
            for (i, x) in a.enumerated() { flatten(x, "\(prefix)[\(i)]", into: &out) }
        } else if let data = v as? Data {
            if let inner = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                flatten(inner, prefix + "<plist>", into: &out)
            } else if let s = String(data: data, encoding: .utf8) {
                out.append("\(prefix)=\(s)")
            } else {
                out.append("\(prefix)=<\(data.count) bytes>")
            }
        } else {
            out.append("\(prefix)=\(v)")
        }
    }

    /// What came in, without what it says (the log can be sent to someone): when, which chat, what kind.
    private func writeLog(_ notes: [Notif], _ note: String) {
        var text = ""
        for n in notes {
            let input = n.body.range(of: "input|permission|输入", options: [.regularExpression, .caseInsensitive]) != nil
            text += "\(Clock.iso()) [\(note)] rec=\(n.recId) at=\(Clock.iso(n.date)) chat=\(n.chatId ?? "-") \(input ? "needs-input" : "done")\n"
        }
        if notes.isEmpty { text = "\(Clock.iso()) [\(note)] no Claude notifications yet\n" }
        store.log(text, file: "notifications.log")
    }
}

// MARK: - Claude app sidebar (Accessibility)

struct AXLink: Sendable {
    let id: String
    let path: String
    let title: String
    let flags: String
    /// true / false when read from the sidebar's sections, nil when unknown
    var pinned: Bool? = nil
}

/// Why the Claude app's sidebar can't be read right now: a short note for the header, and on hover,
/// what it holds up and what to do.
enum SyncIssue: Sendable {
    case accessOff, noWindow, codeMode, pinsCollapsed, sidebarHidden, noChatsShown

    /// Claude's notifications can be read (Full Disk Access): finishes still come while the sidebar can't be seen.
    nonisolated(unsafe) static var alerts = false

    var note: String {
        switch self {
        case .accessOff: return tr("辅助功能授权失效，请在系统设置里删掉再加回来", "Accessibility is off for this build — remove and re-add it in System Settings")
        case .noWindow:
            return SyncIssue.alerts
                ? tr("看不到 Claude 的窗口（关了，或在别的桌面）：要你批准的提醒照常（Claude 的通知开着的话），对话等窗口回来再更新", "Claude's window can't be seen (closed, or on another desktop): approval alerts still come (with Claude's notifications on); chats update when it's back")
                : tr("看不到 Claude 的窗口（关了，或在别的桌面）：对话等窗口回来再更新", "Claude's window can't be seen (closed, or on another desktop): chats update when it's back")
        case .codeMode: return tr("Claude 在 Code 模式，切回 Chat 才能同步置顶对话", "Claude is in Code mode — switch back to Chat to sync pinned chats")
        case .pinsCollapsed: return tr("Claude 的 Pinned 区折叠了，展开才能同步", "Claude's Pinned section is collapsed — expand it to sync")
        case .sidebarHidden: return tr("Claude 的侧边栏收起来了（或窗口太窄），展开才能同步", "Claude's sidebar is hidden (or its window is too narrow) — show it to sync")
        case .noChatsShown: return tr("Claude 的侧边栏现在一个对话也没显示，显示出来就会同步", "Claude's sidebar shows no chats right now — syncing resumes once it does")
        }
    }

    /// What keeps working meanwhile.
    private var still: String {
        SyncIssue.alerts
            ? tr("不受影响：Claude 的通知（要你批准或回答；Claude App 里的 Cowork 任务做完）、Claude Code、ChatGPT。",
                 "Still works: Claude's notifications (it needs your approval or an answer; a Cowork task in the Claude app finished), Claude Code, ChatGPT.")
            : tr("不受影响：Claude Code、ChatGPT。（开了「完全磁盘访问」的话，Claude 要你批准、Cowork 任务做完时的通知也能收到。）",
                 "Still works: Claude Code, ChatGPT. (With Full Disk Access on, Claude's notifications would also say when it needs your approval and when a Cowork task finishes.)")
    }

    /// What it means, what it affects, what to do.
    var help: String {
        switch self {
        case .accessOff:
            return tr("macOS 关掉了 Kikumap 的「辅助功能」权限（重新安装或更新后常见）。\n受影响：进行中状态、置顶对话、侧边栏里的未读。\n",
                      "macOS switched off Kikumap's Accessibility access (common after reinstalling or updating).\nAffected: running status, pinned chats, unread from Claude's sidebar.\n")
                + still + tr("\n怎么办：系统设置 → 隐私与安全性 → 辅助功能，把 Kikumap 删掉（−）再加回来。",
                             "\nFix: System Settings → Privacy & Security → Accessibility: remove Kikumap (−) and add it again.")
        case .noWindow:
            // with Claude's notifications read, a finish ends the time the window hid at the notification
            let time = SyncIssue.alerts
                ? tr("在跑的对话显示「在跑？」。看不到的这段时长是估算的（标 ≈）：按你一次运行的常见时长算，不超过它被看到做完的时候；发通知说做完的（Cowork 任务）算到通知那一刻。普通对话回复完 Claude 不发通知，要等窗口回来才知道。\n",
                     "Chats that were running show \"running?\". The time Kikumap can't see is estimated (marked ≈): your typical run's length, never past when it's seen finished; one whose finish Claude notifies (a Cowork task) counts up to that notification. Claude sends none when an ordinary chat's reply finishes: that shows when the window is back.\n")
                : tr("在跑的对话显示「在跑？」。看不到的这段时长是估算的（标 ≈）：按你一次运行的常见时长算，不超过它被看到做完的时候；做完没有，要等窗口回来才知道。\n",
                     "Chats that were running show \"running?\". The time Kikumap can't see is estimated (marked ≈): your typical run's length, never past when it's seen finished; whether they've finished shows when the window is back.\n")
            return tr("Kikumap 看不到 Claude 的窗口：关了（⌘W 和红色按钮只是把它藏起来，Claude 还在运行），或者在别的桌面上（全屏也算单独一个桌面）。\n暂停：Claude 对话的进行中、做完和置顶同步，窗口回到这个桌面就自动恢复。",
                      "Kikumap can't see Claude's window: it's closed (⌘W and the red button only hide it; Claude keeps running), or it's on another desktop (full screen counts as a desktop of its own).\nPaused: running, finished and pins for Claude's chats; they resume once the window is back on this desktop. ")
                + time + still + tr("\n怎么办：点程序坞里的 Claude（关着的窗口会重新打开，在别的桌面会切过去）。想在别的桌面工作时也同步，就把 Claude 的窗口放到你用的那个桌面。",
                             "\nFix: click Claude in the Dock (it reopens a closed window, or takes you to its desktop). To keep syncing while you work on another desktop, move Claude's window to the desktop you use.")
        case .codeMode:
            return tr("Claude 的侧边栏现在显示的是 Code，不是 Chat，里面没有你的置顶对话。\n暂停：置顶对话同步、对话的进行中状态。\n",
                      "Claude's sidebar is showing Code instead of Chat, so your pinned chats aren't in it.\nPaused: syncing pins and the running status of chats.\n")
                + still + tr("\n怎么办：在 Claude 侧边栏顶部切回 Chat。", "\nFix: switch Claude back to Chat at the top of its sidebar.")
        case .pinsCollapsed:
            return tr("Claude 侧边栏里的 Pinned 区折叠起来了，Kikumap 看不到哪些对话被置顶。\n暂停：置顶列表同步（左栏不会更新），以及置顶对话的进行中和未读。\n",
                      "The Pinned section in Claude's sidebar is folded, so Kikumap can't see which chats are pinned.\nPaused: syncing your pins (the left column won't update), and running and unread for pinned chats.\n")
                + still + tr("\n怎么办：在 Claude 侧边栏里点一下 Pinned，把它展开。", "\nFix: click \"Pinned\" in Claude's sidebar to unfold it.")
        case .sidebarHidden:
            return tr("Claude 的侧边栏收起来了，Kikumap 没有东西可读。\n暂停：进行中状态、置顶对话、侧边栏里的未读。\n",
                      "Claude's sidebar is hidden, so there's nothing for Kikumap to read.\nPaused: running status, pinned chats, unread from the sidebar.\n")
                + still + tr("\n怎么办：在 Claude 窗口左上角把侧边栏打开；窗口太窄时 Claude 会自动收起它，把窗口拉宽一点。",
                             "\nFix: show the sidebar in Claude's window (top left). Claude folds it away when the window is narrow: make the window wider.")
        case .noChatsShown:
            return tr("Claude 侧边栏的对话列表里一个对话也没显示：还在加载、没能加载出来（断网了？），或者分组都折叠起来了。\n暂停：进行中状态、置顶对话、侧边栏里的未读；置顶不会因此被清掉。\n",
                      "The chat list in Claude's sidebar shows no chats: it's still loading, couldn't load (offline?), or its groups are folded.\nPaused: running status, pinned chats, unread from the sidebar; your pins aren't cleared meanwhile.\n")
                + still + tr("\n怎么办：等它加载完；Claude 显示「重试」的话点一下，或者检查网络；分组折叠了就点一下它的标题展开。",
                             "\nFix: wait for it to load; if Claude shows \"Try again\", click it, or check your connection; click a folded group's heading to unfold it.")
        }
    }
}

enum AXScan {
    static let uuidRx = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func str(_ el: AXUIElement, _ name: String) -> String {
        guard let v = attr(el, name) else { return "" }
        if let s = v as? String { return s }
        if let u = v as? URL { return u.absoluteString }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? [String] { return a.joined(separator: " ") }
        return ""
    }

    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func list(_ v: CFTypeRef?) -> [AXUIElement] {
        guard let v = v, CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as! [AnyObject]).compactMap { element($0) }
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] { list(attr(el, "AXChildren")) }

    static func short(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count > n ? String(t.prefix(n)) + "…" : t
    }

    /// One-line description of an element subtree (used by rules and the diagnostic log).
    static func describe(_ root: AXUIElement, limit: Int) -> String {
        var parts: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var n = 0
        while let (el, d) = stack.popLast(), n < limit {
            n += 1
            var p = str(el, "AXRole")
            let sub = str(el, "AXSubrole"); if !sub.isEmpty { p += "/" + sub }
            for (k, label) in [("AXTitle", "t"), ("AXDescription", "d"), ("AXHelp", "h")] {
                let v = str(el, k); if !v.isEmpty { p += " \(label)='\(short(v, 40))'" }
            }
            let val = str(el, "AXValue"); if !val.isEmpty { p += " v='\(short(val, 40))'" }
            let cls = str(el, "AXDOMClassList"); if !cls.isEmpty { p += " cls='\(short(cls, 120))'" }
            if str(el, "AXSelected") == "1" { p += " sel=1" }
            let cur = str(el, "AXARIACurrent"); if !cur.isEmpty && cur != "0" && cur != "false" { p += " cur=\(cur)" }
            if str(el, "AXElementBusy") == "1" { p += " busy=1" }
            parts.append(String(repeating: ">", count: d) + p)
            if d < 6 { for c in children(el).reversed() { stack.append((c, d + 1)) } }
        }
        return parts.joined(separator: " ; ")
    }

    static func linkText(_ el: AXUIElement) -> String {
        var t = str(el, "AXTitle")
        if t.isEmpty { t = str(el, "AXDescription") }
        if !t.isEmpty { return t }
        var out: [String] = []
        var stack: [(AXUIElement, Int)] = [(el, 0)]
        var n = 0
        while let (e, d) = stack.popLast(), n < 30 {
            n += 1
            if str(e, "AXRole") == "AXStaticText" { let v = str(e, "AXValue"); if !v.isEmpty { out.append(v) } }
            if d < 5 { for c in children(e).reversed() { stack.append((c, d + 1)) } }
        }
        return out.joined(separator: " ")
    }

    /// Indented outline of a subtree, for the diagnostic log.
    static func outline(_ root: AXUIElement, limit: Int) -> String {
        var lines: [String] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (el, d) = stack.popLast(), lines.count < limit {
            var p = str(el, "AXRole")
            let sub = str(el, "AXSubrole"); if !sub.isEmpty { p += "/" + sub }
            // a menu button's own title is what it shows (the account menu: your name and plan): left out
            let popup = str(el, "AXRole") == "AXPopUpButton"
            for (k, label) in [("AXTitle", "t"), ("AXDescription", "d"), ("AXValue", "v"), ("AXURL", "u")] {
                let v = str(el, k); if !v.isEmpty { p += " \(label)='\(popup && k != "AXDescription" ? "‹…›" : short(v, 60))'" }
            }
            if str(el, "AXSelected") == "1" { p += " sel=1" }
            if str(el, "AXElementBusy") == "1" { p += " busy=1" }
            lines.append(String(repeating: "  ", count: min(d, 30)) + p)
            if d < 60 { for c in children(el).reversed() { stack.append((c, d + 1)) } }
        }
        return lines.joined(separator: "\n")
    }

    private static let itemRoles: Set<String> = ["AXLink", "AXButton", "AXRow", "AXCell", "AXMenuItem", "AXRadioButton"]

    /// "Sidebar" in the languages Claude speaks.
    static let sidebarNames: Set<String> = ["Sidebar", "Seitenleiste", "Barra lateral", "Barre latérale", "साइडबार", "Bilah sisi",
                                            "Barra laterale", "サイドバー", "사이드바"]

    /// The Claude app's chat list (the "Sidebar" landmark), if it's open, by its name in any language Claude speaks
    /// (so an empty list is told from a hidden one); else the first side landmark that holds chats.
    static func sidebar(in web: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(web, 0)]
        var n = 0
        var others: [AXUIElement] = []
        while !queue.isEmpty, n < 400 {
            let (el, d) = queue.removeFirst()
            n += 1
            if str(el, "AXSubrole") == "AXLandmarkComplementary" {
                if sidebarNames.contains(str(el, "AXDescription")) { return el }
                others.append(el)
            }
            if d < 10 { queue += children(el).map { ($0, d + 1) } }
        }
        return others.first { !rows(in: $0).isEmpty }
    }

    /// One chat row: its button, title and status flags (never the title text itself, so a chat
    /// called "thinking…" can't look busy), the heading it's under, and its menu's words with the title
    /// left out ("More options for {label}": which language Claude speaks).
    struct Row { let button: AXUIElement; let title: String; let flags: String; var section = Section(); var pinned: Bool? = false; var menu = "" }

    /// A heading in the sidebar: its text, its level and how deep it sits, and which one it is (in order).
    struct Section: Equatable { var title = ""; var level = ""; var depth = -1; var order = -1 }

    /// "Pinned" in the languages Claude speaks (where a word is missing, `markPinned` goes by the layout).
    static let pinnedHeadings: Set<String> = ["Pinned", "已置顶", "置顶", "固定", "已固定", "ピン留め", "ピン留め済み", "고정됨",
                                              "Épinglés", "Épinglées", "Angepinnt", "Angeheftet", "Fijados", "Fijadas", "Fissati", "Fissate",
                                              "Fixados", "Fixadas", "Disematkan", "पिन किए गए"]

    /// A row's menu in each language Claude speaks: all of them have their "Pinned" above.
    static let knownMenus: Set<String> = ["More options for {label}", "Weitere Optionen für {label}", "Más opciones para {label}",
                                          "Plus d'options pour {label}", "{label} के लिए अधिक विकल्प", "Opsi lainnya untuk {label}",
                                          "Altre opzioni per {label}", "{label}のその他のオプション", "{label}에 대한 더 많은 옵션",
                                          "Mais opções para {label}"]

    /// Which rows are pinned: the ones under a "Pinned" heading. In a language without a word above, the
    /// section above the date groups (Today, Yesterday…): those sit one level deeper in the sidebar, under
    /// headings of the same rank. When every row sits at one depth: under that section with (folded or empty) date
    /// groups below it, pinned; under several date groups, not; under one heading that isn't "Pinned" in a language
    /// whose word is known, not (a date group, or the list's own heading); otherwise unknown (nil: nothing changes).
    static func markPinned(_ rows: [Row], sections: [Section] = []) -> [Row] {
        var out = rows
        if rows.contains(where: { pinnedHeadings.contains($0.section.title) }) {
            for i in out.indices { out[i].pinned = pinnedHeadings.contains(out[i].section.title) }
            return out
        }
        let depths = Set(rows.map(\.section.depth))
        guard let deepest = depths.max(), let first = rows.first?.section,
              let dates = rows.first(where: { $0.section.depth == deepest })?.section else { return out }
        if depths.count >= 2 {
            for i in out.indices {
                let s = out[i].section
                out[i].pinned = s.depth >= 0 && s.depth < deepest && !s.level.isEmpty && s.level == dates.level && s.order < dates.order
            }
            return out
        }
        let datesBelow = !first.level.isEmpty && sections.contains { $0.level == first.level && $0.depth > first.depth && $0.order > first.order }
        let several = Set(rows.map(\.section.order)).count >= 2
        let known = rows.contains { knownMenus.contains($0.menu) }
        let verdict: Bool? = datesBelow && !several ? true : (several || known ? false : nil)
        for i in out.indices { out[i].pinned = verdict }
        return out
    }

    /// Rows are buttons whose row also holds a menu, "More options for …" (in another language other
    /// words, still with the chat's title in them). Scheduled tasks have a second label ("Monthly",
    /// "One-time") and are left out.
    static func rows(in sidebar: AXUIElement) -> [Row] {
        var headings: [String] = [], sections: [Section] = [], texts = Set<String>()
        return rows(in: sidebar, headings: &headings, sections: &sections, texts: &texts)
    }

    /// `headings`: every heading's text; `sections`: every heading (also the ones with no chats under them);
    /// `texts`: every text of every row, chat or not (a scheduled task's name), kept out of the log.
    static func rows(in sidebar: AXUIElement, headings: inout [String], sections: inout [Section], texts userTexts: inout Set<String>) -> [Row] {
        var out: [Row] = []
        var stack: [(AXUIElement, Int)] = [(sidebar, 0)]
        var n = 0
        var section = Section()     // the last heading passed ("Pinned", "Today", "Oct 23", "Older"…)
        while let (el, d) = stack.popLast(), n < 6000 {
            n += 1
            if str(el, "AXRole") == "AXHeading" {
                section = Section(title: str(el, "AXTitle"), level: str(el, "AXValue"), depth: d, order: headings.count)
                headings.append(section.title)
                sections.append(section)
                continue
            }
            let kids = children(el)
            let menus = kids.flatMap { children($0) }.filter { str($0, "AXRole") == "AXPopUpButton" }
            if let button = kids.first(where: { str($0, "AXRole") == "AXButton" }),
               let menu = menus.first(where: { str($0, "AXDescription").hasPrefix("More options for") }) ?? menus.first {
                var texts: [String] = []
                var flags: [String] = []
                func scan(_ e: AXUIElement, _ depth: Int, inButton: Bool) {
                    let role = str(e, "AXRole"), sub = str(e, "AXSubrole")
                    if inButton && role == "AXStaticText" { let v = str(e, "AXValue"); if !v.isEmpty { texts.append(v) } }
                    if sub == "AXApplicationStatus" || role == "AXProgressIndicator" || role == "AXBusyIndicator" || role == "AXImage" {
                        var f = sub.isEmpty ? role : role + "/" + sub
                        for k in ["AXDescription", "AXTitle", "AXValue"] { let v = str(e, k); if !v.isEmpty { f += " '\(short(v, 40))'" } }
                        flags.append(f)
                    }
                    if str(e, "AXElementBusy") == "1" { flags.append("busy=1") }
                    if role != "AXPopUpButton" && depth < 5 { for c in children(e) { scan(c, depth + 1, inButton: inButton) } }
                }
                scan(button, 0, inButton: true)
                for k in kids where !CFEqual(k, button) { scan(k, 1, inButton: false) }
                for t in texts { userTexts.insert(t.trimmingCharacters(in: .whitespacesAndNewlines)) }
                if str(button, "AXSelected") == "1" || str(el, "AXSelected") == "1" { flags.append("sel=1") }
                let cur = str(button, "AXARIACurrent"); if !cur.isEmpty && cur != "0" && cur != "false" { flags.append("cur=\(cur)") }
                let title = texts.count == 1 ? texts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let label = str(menu, "AXDescription"), english = label.hasPrefix("More options for")
                // (a one-character title: only where the menu reads exactly as Claude words it, or any row would pass)
                if !title.isEmpty, english || (title.count >= 2 && label.count > title.count && label.contains(title))
                    || (title.count == 1 && knownMenus.contains { $0.replacingOccurrences(of: "{label}", with: title) == label }) {
                    let at = label.range(of: title, options: [.anchored, .backwards]) ?? label.range(of: title, options: .anchored)
                    out.append(Row(button: button, title: title, flags: flags.joined(separator: " ; "), section: section,
                                   menu: at.map { label.replacingCharacters(in: $0, with: "{label}") } ?? ""))
                    continue
                }
                if english { continue }     // a row, but not a chat (a scheduled task)
            }
            if d < 40 { for c in kids.reversed() { stack.append((c, d + 1)) } }
        }
        return markPinned(out, sections: sections)
    }

    /// A chat list with no chats that's still loading them or couldn't: something in it is busy or a placeholder row,
    /// or it says so in a status line ("Couldn't load your chats.", "You're offline…"), in any language.
    static func loading(_ sidebar: AXUIElement) -> Bool {
        var stack: [(AXUIElement, Int)] = [(sidebar, 0)]
        var n = 0
        while let (el, d) = stack.popLast(), n < 3000 {
            n += 1
            let role = str(el, "AXRole")
            if role == "AXProgressIndicator" || role == "AXBusyIndicator" || str(el, "AXElementBusy") == "1" { return true }
            if str(el, "AXSubrole") == "AXApplicationStatus", !linkText(el).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            let cls = str(el, "AXDOMClassList")
            if cls.contains("placeholder-rows") || cls.contains("skeleton") { return true }
            if d < 40 { for c in children(el) { stack.append((c, d + 1)) } }
        }
        return false
    }

    /// A list showing no chats that isn't empty either: group headings below its top one with nothing under them
    /// (folded; a known "Pinned" is told apart as such), or Claude still loading them or saying it couldn't (`busy`).
    static func unshown(headings: [String], sections: [Section], busy: () -> Bool) -> Bool {
        !headings.contains(where: { pinnedHeadings.contains($0) }) && (Set(sections.map(\.level)).count > 1 || busy())
    }

    /// What Claude's page showed on a read: the open chat's address, the page title, and whether that title may still
    /// be the chat's open before (the title can lag behind the address while the next chat loads).
    struct Page: Sendable, Equatable { var id = ""; var title = ""; var stale = false }

    /// This read's page against the last one's. `steady`: the title was seen with this address the read before too,
    /// and isn't one left over from before the address changed (only then can the title tell which row is open).
    static func follow(_ last: Page?, id: String, title: String) -> (page: Page, steady: Bool) {
        let stale = last.map { $0.id == id ? $0.stale && $0.title == title : $0.title == title } ?? false
        return (Page(id: id, title: title, stale: stale), last.map { $0.id == id && $0.title == title } == true && !stale)
    }

    /// A chat list read, as to pins. `none`: chats were read, none under a "Pinned" heading, all under headings of one
    /// depth (the date groups) and none of their rank above them: nothing is pinned any more. `partial`: such a heading
    /// above them holds no rows: a folded Pinned whose word isn't known, so the pinned chats aren't in this read (a
    /// running one missing from it isn't gone).
    static func pins(_ rows: [Row], headings: [String], sections: [Section]) -> (none: Bool, partial: Bool) {
        let depth = rows.map(\.section.depth).max() ?? -1
        let level = rows.first { $0.section.depth == depth }?.section.level ?? ""
        let foldedAbove = sections.contains { $0.level == level && $0.depth >= 0 && $0.depth < depth }
        let flat = !rows.isEmpty && Set(rows.map(\.section.depth)).count <= 1
        let none = flat && !headings.contains(where: { pinnedHeadings.contains($0) }) && rows.allSatisfy({ $0.pinned == false }) && !foldedAbove
        return (none, flat && foldedAbove)
    }

    /// Which row is the open chat (`open`: its address). The one row Claude marks as current (the mark follows the
    /// address, the page title can lag), unless the page title is a chat known by this very address and the row
    /// isn't it (a switch caught halfway). With no row marked, the first with the page's title, if that title is
    /// steady (see `follow`) and belongs to no other address.
    static func openRow(_ rows: [Row], open: String?, title: String, steady: Bool, known: [String: String]) -> Int? {
        guard let o = open else { return nil }
        let marked = rows.indices.filter { rows[$0].flags.contains("sel=1") || rows[$0].flags.contains("cur=") }
        if marked.count == 1, rows[marked[0]].title == title || known[title] != o { return marked[0] }
        guard steady, let k = rows.firstIndex(where: { $0.title == title }), known[title].map({ $0 == o }) ?? true,
              !known.contains(where: { k in k.value == o && k.key != title && rows.contains { r in r.title == k.key } }) else { return nil }
        return k
    }

    /// The chat each row stands for: the address its title is known by, else its title's own id (a second row with
    /// the same title: one of its own). The open row is the open chat, and that address is its alone (another row
    /// its old title points to is another chat now). An id `seen` already (in another window) is left out.
    static func links(_ rows: [Row], known: [String: String], open: String?, openRow: Int?, seen: inout Set<String>) -> [AXLink] {
        var out: [AXLink] = [], sameTitle: [String: Int] = [:]
        for (k, r) in rows.enumerated() {
            let own = "n-" + Store.fnv(r.title)
            var id = known[r.title] ?? own
            var path = "", flags = r.flags
            let twin = sameTitle[r.title, default: 0]
            sameTitle[r.title] = twin + 1
            if twin > 0 { id = own + "-\(twin + 1)" }
            if let o = open, let at = openRow {
                if k == at { id = o; path = "/chat/" + o; flags += " ; cur=1" } else if id == o { id = own }
            }
            if !seen.insert(id).inserted { continue }
            out.append(AXLink(id: id, path: path, title: r.title, flags: flags, pinned: r.pinned))
        }
        return out
    }

    /// Clicks the chat's row in the Claude app (for chats whose address we don't know yet).
    static func press(pid: pid_t, title: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3.0)
        for w in list(attr(app, "AXWindows")) {
            var stack: [(AXUIElement, Int)] = [(w, 0)]
            var visited = 0
            while let (el, d) = stack.popLast(), visited < 4000 {
                visited += 1
                if str(el, "AXRole") == "AXWebArea" {
                    if let sb = sidebar(in: el), let r = rows(in: sb).first(where: { $0.title == title }) {
                        return AXUIElementPerformAction(r.button, kAXPressAction as CFString) == .success
                    }
                    continue
                }
                if d < 40 { for c in children(el) { stack.append((c, d + 1)) } }
            }
        }
        return false
    }

    /// Every link to a chat in the Claude app's windows.
    /// Every chat in the Claude app's sidebar. `note` says why syncing can't work right now (nil = fine).
    /// `noPins`: the chat list was read whole and has no Pinned section (the last pin was removed, or every chat
    /// deleted), so nothing is pinned any more.
    /// `emptyList`: a chat list was read and holds no chats at all. `readKnown`: Claude speaks a language whose
    /// "Unread" mark the built-in rule knows (English, Japanese), so a chat without one may have been read.
    /// `whole`: a chat list was read with nothing in the way, so a running chat missing from it is gone.
    /// `known`: Claude's chats by title, those with an address; `hidden`: titles kept out of the log besides.
    /// `last`/`page`: the page the read before saw, and this one's (for telling which row is the open chat).
    static func scan(pid: pid_t, wantDump: Bool, known: [String: String] = [:], hidden: Set<String> = [], last: Page? = nil)
        -> (links: [AXLink], dump: String, issue: SyncIssue?, noPins: Bool, emptyList: Bool, readKnown: Bool, whole: Bool, page: Page?) {
        var issue: SyncIssue?
        var page: Page?
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3.0)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var dump = ""
        var out: [AXLink] = []
        var seen = Set<String>()
        var allWebs: [AXUIElement] = [], sidebars: [AXUIElement] = []
        // links to chats anywhere in the window: only for the log (the list is the sidebar's rows)
        var linkSeen = Set<String>()
        var noPins: Bool?
        var emptyList = false, readKnown = false, partial = false
        var hiddenLists = 0, codeLists = 0, unshownLists = 0
        var titles = Set(known.keys).union(hidden)            // left out of the log
        // Electron builds its accessibility tree only after AXManualAccessibility is set — give it a moment
        var winErr = AXError.success
        var windows: [AXUIElement] = []
        for attempt in 0..<3 {
            var v: CFTypeRef?
            winErr = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &v)
            windows = list(v)
            if windows.isEmpty { windows = children(app).filter { str($0, "AXRole") == "AXWindow" } }
            if !windows.isEmpty || attempt == 2 { break }
            Thread.sleep(forTimeInterval: 1)
        }
        if wantDump {
            dump += "# pid=\(pid) trusted=\(AXIsProcessTrusted()) manualAX=\(manual.rawValue) windowsErr=\(winErr.rawValue) windows=\(windows.count)\n"
            if windows.isEmpty {
                dump += "# No windows readable. -25211 = Accessibility is off for this build (remove and re-add it); "
                dump += "-25204 = Claude didn't answer in time; 0 = Claude has no open window.\n"
            }
        }
        for w in windows {
            titles.insert(str(w, "AXTitle"))
            if wantDump { dump += "WINDOW title='\(str(w, "AXTitle"))'\n" }
            var webs: [AXUIElement] = []
            var stack: [(AXUIElement, Int)] = [(w, 0)]
            var visited = 0
            while let (el, d) = stack.popLast(), visited < 4000 {
                visited += 1
                if str(el, "AXRole") == "AXWebArea" { webs.append(el); continue }
                if d < 40 { for c in children(el) { stack.append((c, d + 1)) } }
            }
            for web in webs {
                var links: [AXUIElement] = []
                let pred: [String: Any] = ["AXSearchKey": "AXLinkSearchKey", "AXResultsLimit": 3000,
                                           "AXDirection": "AXDirectionNext", "AXVisibleOnly": false,
                                           "AXImmediateDescendantsOnly": false]
                var res: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(web, "AXUIElementsForSearchPredicate" as CFString, pred as CFDictionary, &res) == .success {
                    links = list(res)
                }
                if links.isEmpty {
                    var st: [(AXUIElement, Int)] = [(web, 0)]
                    var n = 0
                    while let (el, d) = st.popLast(), n < 12000 {
                        n += 1
                        if str(el, "AXRole") == "AXLink" { links.append(el); continue }
                        if d < 60 { for c in children(el) { st.append((c, d + 1)) } }
                    }
                }
                if wantDump { dump += " WEBAREA url='\(str(web, "AXURL"))' links=\(links.count)\n" }
                for l in links {
                    let url = str(l, "AXURL")
                    let ns = url as NSString
                    // only links to chats — a UUID inside some web page a chat cites, or an artifact, doesn't count
                    guard url.contains("claude.ai/chat/") || url.contains("claude.ai/code/"), !url.contains("/artifact"),
                          let m = uuidRx.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) else { continue }
                    let id = ns.substring(with: m.range).lowercased()
                    if linkSeen.contains(id) { continue }
                    linkSeen.insert(id)
                    let path = URL(string: url)?.path ?? ""
                    let title = linkText(l)
                    titles.insert(title)
                    var flags = describe(l, limit: 40)
                    if let parent = element(attr(l, "AXParent")), children(parent).count <= 6 {
                        flags += " || parent: " + describe(parent, limit: 50)
                    }
                    if wantDump { dump += "LINK \(path)\n  title=\(short(title, 80))\n  flags=\(flags)\n" }
                }
            }
            allWebs.append(contentsOf: webs)
            if webs.isEmpty { allWebs.append(w) }
        }
        if windows.isEmpty {
            issue = winErr == .apiDisabled ? .accessOff : .noWindow
        }
        // the sidebar's chat list first, always (links in the page, to an artifact say, mustn't hide it)
        var foundSidebar = false
        if !windows.isEmpty {
            for web in allWebs {
                guard let sb = sidebar(in: web) else { continue }
                foundSidebar = true
                sidebars.append(sb)
                // the Chat / Code switch at the top of the sidebar (in another language: the switch of two, Code second)
                var codeMode = false, named = false
                var pair: [AXUIElement] = []
                var q: [(AXUIElement, Int)] = [(sb, 0)]
                while let (el, d) = q.popLast(), !codeMode {
                    let role = str(el, "AXRole"), desc = str(el, "AXDescription")
                    if role == "AXRadioButton" && (desc == "Code" || desc == "Claude") { named = true }
                    if role == "AXRadioButton" && desc == "Code" && str(el, "AXValue") == "1" { codeMode = true }
                    if role == "AXRadioGroup" && pair.isEmpty {
                        let radios = children(el).filter { str($0, "AXRole") == "AXRadioButton" }
                        if radios.count == 2 { pair = radios }
                    }
                    if d < 4 { q += children(el).map { ($0, d + 1) } }
                }
                if !named && pair.count == 2 && str(pair[1], "AXValue") == "1" { codeMode = true }
                // the open chat: its address is in the page URL, its title in the page title
                let url = str(web, "AXURL"), ns = url as NSString
                let openID = uuidRx.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
                var openTitle = str(web, "AXTitle")
                if openTitle.hasSuffix(" - Claude") { openTitle = String(openTitle.dropLast(9)) }
                titles.insert(openTitle)
                // (the first list's page is followed from read to read)
                let followed = follow(last, id: openID ?? "", title: openTitle)
                let steady = sidebars.count == 1 && followed.steady
                if sidebars.count == 1 { page = followed.page }
                var headings: [String] = [], sections: [Section] = [], texts = Set<String>()
                let rows = rows(in: sb, headings: &headings, sections: &sections, texts: &texts)
                titles.formUnion(texts)
                // a chat opened while the list was read: Claude's marks (read late) needn't be the address's (read early)
                let settled = str(web, "AXURL") == url
                // the landmark is there but shows no list at all, not even a heading: collapsed or narrow, not empty
                if !codeMode && rows.isEmpty && headings.isEmpty { hiddenLists += 1; continue }
                if !codeMode && rows.isEmpty && unshown(headings: headings, sections: sections, busy: { loading(sb) }) {
                    hiddenLists += 1; unshownLists += 1; continue
                }
                if codeMode {
                    issue = .codeMode
                    codeLists += 1
                } else if headings.contains(where: { pinnedHeadings.contains($0) }) && !rows.contains(where: { $0.pinned == true }) {
                    issue = .pinsCollapsed
                }
                // Claude speaks a language whose "Unread" mark the built-in rule knows (every one it ships), so its
                // absence can say "read"
                if !codeMode && rows.contains(where: { knownMenus.contains($0.menu) }) { readKnown = true }
                let p = pins(rows, headings: headings, sections: sections)
                noPins = (noPins ?? true) && !codeMode && p.none
                if !codeMode && p.partial { partial = true }
                if !codeMode && rows.isEmpty { emptyList = true }
                if wantDump { dump += "\nSIDEBAR: \(rows.count) rows · menus '\(rows.first?.menu ?? "")' · open chat '\(short(openTitle, 60))' \(openID ?? "-")\n" }
                // the Code list holds sessions (their hooks report them), not chats: nothing to apply from it
                if codeMode { continue }
                // the open chat: only a /chat/ address that's the same before and after the list was read
                let openChat = url.contains("/chat/") && settled ? openID : nil
                let open = openRow(rows, open: openChat, title: openTitle, steady: steady, known: known)
                for l in links(rows, known: known, open: openChat, openRow: open, seen: &seen) {
                    titles.insert(l.title)
                    out.append(l)
                    if wantDump { dump += "ROW \(l.pinned == true ? "📌 " : l.pinned == nil ? "? " : "")\(short(l.title, 70))  →  \(l.id)\n  flags=\(l.flags)\n" }
                }
            }
        }
        // no chat list: nothing (links elsewhere in the page aren't the list, and their text isn't a status). A list
        // that's hidden, folded, loading or in Code mode gives nothing: what isn't seen isn't changed.
        if wantDump {
            // the chat list only: the rest of the window is the conversation itself (without a chat list,
            // the window with its longer texts left out). The Code list holds session titles: left out.
            for (i, root) in (sidebars.isEmpty ? allWebs : sidebars).enumerated() where codeLists == 0 {
                let o = outline(root, limit: 700)
                dump += "\n== OUTLINE \(i) \(sidebars.isEmpty ? "window" : "sidebar")\n" + maskLong(o) + "\n"
            }
        }
        if issue == nil && !windows.isEmpty && out.isEmpty && unshownLists > 0 && !emptyList { issue = .noChatsShown }
        if issue == nil && !windows.isEmpty && (!foundSidebar || (out.isEmpty && hiddenLists > 0 && !emptyList)) { issue = .sidebarHidden }
        if wantDump, let n = issue { dump = "# Sync problem: \(n.note)\n" + dump }
        if wantDump { dump = redact(dump, titles: titles) }
        let whole = issue == nil && foundSidebar && hiddenLists < sidebars.count && !partial
        return (out, dump, issue, issue == nil && noPins == true, issue == nil && emptyList && out.isEmpty, readKnown, whole, page)
    }

    /// The log without chat titles (each becomes ‹title›), so it can be sent to someone.
    static func redact(_ text: String, titles: Set<String>) -> String {
        var t = text
        for title in titles.sorted(by: { $0.count > $1.count }) {
            let key = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
            guard key.count >= 3 else {
                // a short title (one or two characters, common in Chinese and Japanese): where it stands whole
                guard !key.isEmpty else { continue }
                // (a field, a quoted label, a sidebar row "ROW 📌 X  →", a menu "More options for X'")
                t = t.replacingOccurrences(of: "=" + key + "\n", with: "=‹title›\n").replacingOccurrences(of: "'" + key + "'", with: "'‹title›'")
                    .replacingOccurrences(of: " " + key + "  →", with: " ‹title›  →").replacingOccurrences(of: " " + key + "'", with: " ‹title›'")
                continue
            }
            t = t.replacingOccurrences(of: NSRegularExpression.escapedPattern(for: key) + "[^'\\n→]*", with: "‹title›", options: .regularExpression)
        }
        return t
    }

    /// Quoted texts longer than a label left out.
    static func maskLong(_ text: String) -> String {
        text.replacingOccurrences(of: "'[^'\\n]{25,}'", with: "'‹…›'", options: .regularExpression)
    }
}

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let w = Unmanaged<SidebarWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { w.changed() }
}

/// Reads the Claude desktop app's sidebar (needs Accessibility permission).
@MainActor
final class SidebarWatcher: NSObject {
    /// `notInstalled`: there's no Claude desktop app on this Mac (nothing to ask for, nothing to wait for).
    enum Status { case starting, ok, noAccess, noApp, notInstalled }
    private(set) var status = Status.starting
    /// The chats read; whether nothing is pinned any more (seen twice in a row, or an empty list for a minute, so a
    /// list still loading doesn't count); whether Claude's unread marks can be relied on; when the read began; whether
    /// the list was read whole.
    var onScan: (([AXLink], Bool, Bool, Date, Bool) -> Void)?
    private var noPinsSeen = 0
    private var emptySince: Date?
    /// What Claude's page showed on the last read (which chat was open, under which title).
    private var lastPage: AXScan.Page?
    /// Chats running on the last read; the ones that stopped since while not open, and when.
    private var wasRunning = Set<String>()
    private var awaitingMark: [String: Date] = [:]
    /// A chat that finished in the background got no unread mark Kikumap knows (Claude worded it anew?): until one
    /// is seen again, a chat without a mark isn't taken as read in Claude.
    private(set) var marksMissed = UserDefaults.standard.bool(forKey: "UnreadMarkMissed")
    /// A status on a chat row that Kikumap doesn't know (an error, or a mark worded anew), as last read: for the
    /// diagnostic report (that row isn't taken as read, see Store; the others sync as usual).
    private(set) var unknownMark: String?
    /// Background finishes with no mark Kikumap knows, one after another: two (not one chat read elsewhere right as it
    /// finished) say Claude's marks can't be read.
    private var lateMisses = 0
    private var loggedUnknown: String?

    /// The statuses Claude puts on a chat row, in each language it speaks (from its message catalogs): unread,
    /// running, waiting for input or an answer, using the browser, idle, done.
    static let knownStatuses: Set<String> = [
        "Unread response", "Ungelesene Antwort", "Respuesta no leída", "Réponse non lue", "अपठित प्रतिक्रिया", "Respons yang belum dibaca",
        "Risposta non letta", "未読の返答", "읽지 않은 응답", "Resposta não lida",
        "Running", "Läuft", "En ejecución", "En cours", "चल रहा है", "Berjalan", "In esecuzione", "実行中", "실행 중", "Em execução",
        "Awaiting input", "Warte auf Eingabe", "Esperando entrada", "En attente de saisie", "इनपुट की प्रतीक्षा में", "Menunggu input",
        "In attesa di input", "入力待ち", "입력 대기 중", "Aguardando entrada",
        "Awaiting answer", "Warte auf Antwort", "Esperando respuesta", "En attente de réponse", "उत्तर की प्रतीक्षा है", "Menunggu jawaban",
        "In attesa di risposta", "回答待ち", "답변 대기 중", "Aguardando resposta",
        "Using the browser", "Browser wird verwendet", "Usando el navegador", "Utilisation du navigateur", "ब्राउज़र का उपयोग कर रहे हैं",
        "Menggunakan browser", "Utilizzo del browser", "ブラウザを使用中", "브라우저 사용", "Usando o navegador",
        "Idle", "Inaktiv", "Sin actividad", "Inactivo", "Inactif", "निष्क्रिय", "Tidak aktif", "Inattivo", "アイドル", "유휴", "Sem atividade",
        "Done", "Abgeschlossen", "Completado", "Terminé", "पूरा हुआ", "Selesai", "Completato", "完了", "완료됨", "Concluído",
    ]
    /// Of those, "Running" (in every language: the built-in running rule only knows the English words).
    static let runningStatuses: Set<String> = ["Running", "Läuft", "En ejecución", "En cours", "चल रहा है", "Berjalan", "In esecuzione",
                                               "実行中", "실행 중", "Em execução",
                                               // working in its built-in browser: running too
                                               "Using the browser", "Browser wird verwendet", "Usando el navegador", "Utilisation du navigateur",
                                               "ब्राउज़र का उपयोग कर रहे हैं", "Menggunakan browser", "Utilizzo del browser", "ブラウザを使用中", "브라우저 사용",
                                               "Usando o navegador"]
    /// A status on a row that isn't one of Claude's own seven (an error such as "Your context window is full", or a
    /// mark worded anew): that row isn't taken as read for having no unread mark.
    static func unknownStatus(_ flags: String) -> String? {
        statusLabels(flags).first { !knownStatuses.contains($0.trimmingCharacters(in: .whitespaces)) }
    }
    /// A row that shows Claude running it, by its spinner or its status in any language.
    static func showsRunning(_ flags: String, _ rule: NSRegularExpression?) -> Bool {
        Store.matches(rule, flags) || statusLabels(flags).contains(where: runningStatuses.contains)
    }
    /// The waiting status a row shows, if any.
    static func waiting(_ flags: String) -> String? { statusLabels(flags).first(where: waitingStatuses.contains) }
    /// Of those, the ones that say the chat waits for you (input, an answer): that's not "read".
    static let waitingStatuses: Set<String> = [
        "Awaiting input", "Warte auf Eingabe", "Esperando entrada", "En attente de saisie", "इनपुट की प्रतीक्षा में", "Menunggu input",
        "In attesa di input", "入力待ち", "입력 대기 중", "Aguardando entrada",
        "Awaiting answer", "Warte auf Antwort", "Esperando respuesta", "En attente de réponse", "उत्तर की प्रतीक्षा है", "Menunggu jawaban",
        "In attesa di risposta", "回答待ち", "답변 대기 중", "Aguardando resposta",
    ]
    private static let statusRx = try! NSRegularExpression(pattern: "AXApplicationStatus((?: '[^']*')+)")
    private static let quotedRx = try! NSRegularExpression(pattern: "'([^']*)'")
    /// The status labels in a row's flags ("AXGroup/AXApplicationStatus 'Unread response'").
    static func statusLabels(_ flags: String) -> [String] {
        let ns = flags as NSString
        return statusRx.matches(in: flags, range: NSRange(location: 0, length: ns.length)).flatMap { m -> [String] in
            let part = ns.substring(with: m.range(at: 1)), ps = part as NSString
            return quotedRx.matches(in: part, range: NSRange(location: 0, length: ps.length)).map { ps.substring(with: $0.range(at: 1)) }
        }
    }
    /// Claude's other marks on a chat that stopped, none of them "unread": waiting for you (approve a tool, answer a
    /// question), done, idle, using the browser.
    private static let otherMarks = try! NSRegularExpression(pattern: "(?i)(await|waiting|input|answer|approv|permission|done|idle|browser|待ち|输入|授权)")
    /// A read was asked for while one ran: it runs again when that one ends.
    private var rescan = false
    var onQuit: (() -> Void)?
    var onStatus: (() -> Void)?
    private let store: Store
    private var observer: AXObserver?
    private var pid: pid_t = 0
    /// The Claude app's process (0 when it isn't running).
    var claudePID: pid_t { pid }
    /// The chat open in Claude's window as last read (its address; nil: none, or not known).
    var openChat: String? { lastPage.flatMap { $0.id.isEmpty ? nil : $0.id } }
    private var scheduled = false
    private var scanning = false
    private var lastScan = Date.distantPast
    private var dumpNext = true
    private var fallback: Timer?
    /// When the sidebar was last read cleanly, and what's stopping it otherwise.
    private(set) var lastSync: Date?
    /// When the sidebar was last looked at, and when it will be next at the latest (it's also read the moment
    /// Claude's window changes).
    var lastRead: Date? { lastScan == .distantPast ? nil : lastScan }
    var nextRead: Date? { pid == 0 ? nil : fallback?.fireDate }
    private(set) var syncIssue: SyncIssue?
    var syncNote: String? { syncIssue?.note }

    init(store: Store) {
        self.store = store
        super.init()
    }

    func start(prompt: Bool) {
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary) { setStatus(.noAccess) }
        attach()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            nc.addObserver(self, selector: #selector(appEvent(_:)), name: n, object: nil)
        }
        fallback = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    private var accessPoll: Timer?
    private func setStatus(_ s: Status) {
        if s != status { status = s; onStatus?() }
        // waiting for Accessibility: look every 2 seconds, so a grant counts at once (not at the next 30 s tick)
        if s == .noAccess {
            if accessPoll == nil {
                accessPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { if AXIsProcessTrusted() { self?.attach() } }
                }
            }
        } else {
            accessPoll?.invalidate(); accessPoll = nil
        }
    }

    func attach() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first
        // no Claude app on this Mac (it's checked again every 30 seconds, so installing it later is picked up)
        if running == nil && NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) == nil {
            detach(); setStatus(.notInstalled); return
        }
        guard AXIsProcessTrusted() else { setStatus(.noAccess); return }
        guard let app = running else {
            detach(); setStatus(.noApp); return
        }
        if observer != nil && pid == app.processIdentifier { return }
        detach()
        var obs: AXObserver?
        guard AXObserverCreate(app.processIdentifier, axObserverCallback, &obs) == .success, let o = obs else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in ["AXValueChanged", "AXTitleChanged", "AXUIElementDestroyed", "AXCreated", "AXLayoutChanged",
                  "AXFocusedUIElementChanged", "AXSelectedChildrenChanged", "AXLiveRegionChanged",
                  "AXRowCountChanged", "AXLoadComplete", "AXMainWindowChanged", "AXElementBusyChanged"] {
            AXObserverAddNotification(o, el, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observer = o
        pid = app.processIdentifier
        // nothing was read for a while: what changed meanwhile may be more than one change
        store.unwatched()
        setStatus(.ok)
        schedule(0.5)
    }

    private func detach() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil
        pid = 0
        // a new Claude starts from nothing: its first (loading) reads mustn't count towards "nothing pinned"
        noPinsSeen = 0
        emptySince = nil
        lastPage = nil
        wasRunning = []
        awaitingMark = [:]
        unknownMark = nil
    }

    /// Claude's own chats by title, as the sidebar is read: a ChatGPT thread or a Claude Code session with the same
    /// title isn't this chat. Real addresses only (a title-only id is its title's anyway, and twins each get theirs);
    /// among them, the one pinned in Claude (a twin with the same title, or one only a notification told of, doesn't
    /// take its row), then the one open in Claude last (a deleted chat never is again), then the most recently active.
    static func addresses(_ chats: [Chat]) -> [String: String] {
        var best: [String: Chat] = [:]
        func rank(_ c: Chat) -> (Int, String, String) { (c.pinned == true ? 1 : 0, c.liveAt ?? "", c.updated_at) }
        for c in chats where !c.outsideClaude && !c.title.isEmpty && !c.id.hasPrefix("n-") {
            if let b = best[c.title], rank(b) >= rank(c) { continue }
            best[c.title] = c
        }
        return best.mapValues(\.id)
    }

    /// Claude's unread marks, checked on every read. `marked`: a row carries one Kikumap knows. `trusted`: a mark's
    /// absence can be taken as "read": every chat that stopped while not open got one (or a "waiting for you" mark)
    /// within half a minute, before the store would take its absence as read.
    func checkMarks(_ links: [AXLink], at now: Date) -> (marked: Bool, trusted: Bool) {
        let rules = store.loadRules()
        let marked = links.contains { Store.matches(rules.unread, $0.flags) }
        var running = Set<String>(), late = false, unknown: String?
        for l in links {
            let open = Store.matches(rules.current, l.flags)
            let statuses = SidebarWatcher.statusLabels(l.flags)
            if let s = statuses.first(where: { !SidebarWatcher.knownStatuses.contains($0.trimmingCharacters(in: .whitespaces)) }) { unknown = s }
            if SidebarWatcher.showsRunning(l.flags, rules.running) {
                // (one running in the open chat may well finish in view: Claude marks nothing then)
                if !open { running.insert(l.id) }
                awaitingMark[l.id] = nil
            } else if open || Store.matches(rules.unread, l.flags) || Store.matches(SidebarWatcher.otherMarks, l.flags) || !statuses.isEmpty {
                awaitingMark[l.id] = nil
            } else if wasRunning.contains(l.id) {
                awaitingMark[l.id] = now
            }
        }
        // (one this read doesn't list can't be told, nor one last seen long before: the Mac slept, it may have been read)
        let listed = Set(links.map(\.id))
        for (id, since) in awaitingMark where !listed.contains(id) || now.timeIntervalSince(since) >= 30 {
            if listed.contains(id) && now.timeIntervalSince(since) < 120 { late = true }
            awaitingMark[id] = nil
        }
        wasRunning = running
        if unknown != unknownMark { unknownMark = unknown; onStatus?() }
        if let u = unknown, u != loggedUnknown {
            loggedUnknown = u
            store.log("\(Clock.iso()) a chat row shows a status Kikumap doesn't know ('\(u)'): that chat isn't taken as read for having no mark\n", file: "app.log")
        }
        if marked { lateMisses = 0 } else if late { lateMisses += 1 }
        let missed = !marked && (lateMisses >= 2 || marksMissed)
        if missed != marksMissed {
            marksMissed = missed
            UserDefaults.standard.set(missed, forKey: "UnreadMarkMissed")
            if missed {
                store.log("\(Clock.iso()) a chat that finished in the background got no unread mark Kikumap knows: until one is seen again, chats without one aren't taken as read\n", file: "app.log")
            }
        }
        return (marked, !missed)
    }

    func changed() { schedule(1.2) }

    @objc private func tick() {
        if status == .noAccess && AXIsProcessTrusted() { attach() }
        if observer == nil { attach() }
        schedule(0)
    }

    @objc private func appEvent(_ n: Notification) {
        guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == claudeBundleID else { return }
        if n.name == NSWorkspace.didTerminateApplicationNotification {
            detach(); setStatus(.noApp)
            onQuit?()
        } else {
            attach(); schedule(0.3)
        }
    }

    /// Opens a chat by clicking its row in the Claude app; `done(false)` if it isn't in the sidebar.
    func press(title: String, done: @escaping @MainActor (Bool) -> Void) {
        guard pid != 0, AXIsProcessTrusted() else { done(false); return }
        let p = pid
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = AXScan.press(pid: p, title: title)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    }

    /// Writes the next scan to logs/claude-sidebar.txt and hands it to `done` (nil when Claude isn't running).
    func diagnose(_ done: @escaping @MainActor (String?) -> Void) {
        dumpNext = true
        attach()
        guard pid != 0 else { done(nil); return }
        dumpDone.append(done)
        schedule(0)
    }
    private var dumpDone: [@MainActor (String?) -> Void] = []

    func schedule(_ delay: Double) {
        if scheduled { return }
        scheduled = true
        // (the clock set back: the last read isn't "just now" for that long)
        let since = Date().timeIntervalSince(lastScan)
        let wait = since < 0 ? delay : max(delay, 2.0 - since)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait)) { [weak self] in
            MainActor.assumeIsolated { self?.run() }
        }
    }

    private func run() {
        scheduled = false
        guard pid != 0 else { return }
        guard !scanning else { rescan = true; return }
        scanning = true
        let started = Date()
        lastScan = started
        let p = pid, dump = dumpNext
        dumpNext = false
        let known = SidebarWatcher.addresses(store.chats), moves = store.idMoves
        let hidden = dump ? Set(store.chats.filter { !$0.outsideClaude }.map(\.title)) : []
        let last = lastPage
        DispatchQueue.global(qos: .utility).async {
            let r = AXScan.scan(pid: p, wantDump: dump, known: known, hidden: hidden, last: last)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.scanning = false
                    defer { if self.rescan { self.rescan = false; self.schedule(0) } }
                    guard self.pid == p else { return }               // Claude quit meanwhile: this read is stale
                    self.lastPage = r.page
                    self.syncIssue = r.issue
                    if r.issue == nil { self.lastSync = Date() }
                    if dump {
                        var head = "# Claude sidebar \(Clock.iso())  links=\(r.links.count)\n"
                        if r.links.isEmpty {
                            head += "# No chats found. Open the Claude app's sidebar (the chat list) and write the log again.\n"
                        }
                        try? (head + r.dump).data(using: .utf8)?.write(to: self.store.logsDir.appendingPathComponent("claude-sidebar.txt"))
                        let waiting = self.dumpDone
                        self.dumpDone = []
                        for f in waiting { f(head + r.dump) }
                    }
                    // a chat's id changed meanwhile (a notification brought its address): this read still has the old one
                    if self.store.idMoves != moves { self.rescan = true; return }
                    self.noPinsSeen = r.noPins ? self.noPinsSeen + 1 : 0
                    // every chat deleted: an empty list, read whole, for a minute (not one still loading)
                    if r.emptyList { if self.emptySince == nil { self.emptySince = started } } else { self.emptySince = nil }
                    let emptyAWhile = self.emptySince.map { started.timeIntervalSince($0) >= 60 } ?? false
                    let marks = self.checkMarks(r.links, at: started)
                    self.onScan?(r.links, self.noPinsSeen >= 2 || emptyAWhile, (r.readKnown || marks.marked) && marks.trusted, started, r.whole)
                }
            }
        }
    }
}
