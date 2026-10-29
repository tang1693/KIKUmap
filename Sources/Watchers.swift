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
}

/// Watches macOS Notification Center's database; reports Claude's new notifications.
@MainActor
final class NotificationWatcher: NSObject {
    enum Status { case starting, ok, noAccess, noDB }
    private(set) var status = Status.starting
    var onNotes: (([Notif]) -> Void)?
    var onStatus: (() -> Void)?
    private let store: Store
    private var watcher: FileWatcher?
    private var retry: Timer?
    private var known: [Int64: String] = [:]
    private let lastKey = "LastNotifRecId"

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
        check()
        watcher?.stop()
        watcher = nil
        if let p = dbPath {
            watcher = FileWatcher(paths: [(p as NSString).deletingLastPathComponent], latency: 0.2) { [weak self] in self?.check() }
        }
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
        guard let path = dbPath else { status = .noDB; return }
        guard FileHandle(forReadingAtPath: path) != nil else { status = .noAccess; return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); status = .noAccess; return
        }
        defer { sqlite3_close(db) }
        let maxId = scalar(db, "SELECT IFNULL(MAX(rec_id),0) FROM record")
        guard maxId >= 0 else { status = .noAccess; return }
        status = .ok
        trackRemovals(db)
        let d = UserDefaults.standard
        if d.object(forKey: lastKey) == nil {
            writeLog(Array(query(db, after: max(0, maxId - 400)).suffix(10)), "first run")
            d.set(maxId, forKey: lastKey)
            return
        }
        let last = Int64(d.integer(forKey: lastKey))
        guard maxId > last else { return }
        let fresh = query(db, after: last)
        d.set(maxId, forKey: lastKey)
        if !fresh.isEmpty {
            writeLog(fresh, "new")
            onNotes?(fresh)
        }
    }

    private func scalar(_ db: OpaquePointer?, _ sql: String) -> Int64 {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int64(st, 0) : -1
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

    private func query(_ db: OpaquePointer?, after: Int64) -> [Notif] {
        let sql = """
        SELECT r.rec_id, a.identifier, r.data, r.delivered_date FROM record r JOIN app a ON a.app_id = r.app_id
        WHERE r.rec_id > ? AND (lower(a.identifier) LIKE '%anthropic%' OR lower(a.identifier) LIKE '%claude%')
        ORDER BY r.rec_id
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, after)
        var out: [Notif] = []
        let chatRx = try! NSRegularExpression(pattern: "/chat/([0-9a-fA-F-]{36})")
        while sqlite3_step(st) == SQLITE_ROW {
            let bundle = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            if bundle == ownBundleID { continue }
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
            out.append(Notif(recId: sqlite3_column_int64(st, 0),
                             title: (req["titl"] as? String) ?? "",
                             body: (req["body"] as? String) ?? "",
                             date: when > 0 ? Date(timeIntervalSinceReferenceDate: when) : Date(),
                             chatId: chatId, detail: detail))
        }
        return out
    }

    /// Logs when Claude notifications disappear (clicked / cleared) — helps tune "read" detection.
    private func trackRemovals(_ db: OpaquePointer?) {
        let sql = "SELECT r.rec_id, r.data FROM record r JOIN app a ON a.app_id = r.app_id WHERE a.identifier = ?"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, claudeBundleID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var now: [Int64: String] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            let rec = sqlite3_column_int64(st, 0)
            if let t = known[rec] { now[rec] = t; continue }
            now[rec] = (NotificationWatcher.plist(st, 1)["req"] as? [String: Any])?["titl"] as? String ?? ""
        }
        if !known.isEmpty {
            let gone = known.keys.filter { now[$0] == nil }.sorted()
            if !gone.isEmpty {
                store.log(gone.map { "\(Clock.iso()) [removed] rec=\($0) title=\(known[$0] ?? "")\n" }.joined(), file: "notifications.log")
            }
        }
        known = now
    }

    private func writeLog(_ notes: [Notif], _ note: String) {
        var text = ""
        for n in notes {
            text += "\(Clock.iso()) [\(note)] rec=\(n.recId) at=\(Clock.iso(n.date)) chat=\(n.chatId ?? "-")\n"
            text += "  title=\(n.title)\n  body=\(n.body.prefix(160))\n  detail=\(n.detail.prefix(600))\n"
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
    case accessOff, noWindow, codeMode, pinsCollapsed, sidebarHidden

    var note: String {
        switch self {
        case .accessOff: return tr("辅助功能授权失效，请在系统设置里删掉再加回来", "Accessibility is off for this build — remove and re-add it in System Settings")
        case .noWindow: return tr("Claude 窗口关着：做完的提醒照常，「进行中」等窗口打开再更新",
                                  "Claude's window is closed: finish alerts still come, live status resumes when it's open")
        case .codeMode: return tr("Claude 在 Code 模式，切回 Chat 才能同步置顶对话", "Claude is in Code mode — switch back to Chat to sync pinned chats")
        case .pinsCollapsed: return tr("Claude 的 Pinned 区折叠了，展开才能同步", "Claude's Pinned section is collapsed — expand it to sync")
        case .sidebarHidden: return tr("Claude 的侧边栏收起来了，展开才能同步", "Claude's sidebar is hidden — show it to sync")
        }
    }

    /// What it means, what it affects, what to do.
    var help: String {
        switch self {
        case .accessOff:
            return tr("macOS 关掉了 Kikumap 的「辅助功能」权限（重新安装或更新后常见）。\n受影响：进行中状态、置顶对话、侧边栏里的未读。\n不受影响：做完的提醒和提示音、Claude Code。\n怎么办：系统设置 → 隐私与安全性 → 辅助功能，把 Kikumap 删掉（−）再加回来。",
                      "macOS switched off Kikumap's Accessibility access (common after reinstalling or updating).\nAffected: running status, pinned chats, unread from Claude's sidebar.\nStill works: finished alerts and sounds, Claude Code.\nFix: System Settings → Privacy & Security → Accessibility: remove Kikumap (−) and add it again.")
        case .noWindow:
            return tr("Claude 的窗口关着（⌘W 只是把它藏起来，Claude 还在运行）。\n不受影响：做完的提醒、提示音、未读标记、Claude Code 会话。\n暂停：「进行中」的转圈和置顶对话的同步，窗口回来就自动恢复。\n怎么办：不用管；想看实时状态就点程序坞里的 Claude，或 ⌘Tab 切过去。",
                      "Claude's window is closed (⌘W only hides it; Claude keeps running).\nStill works: finished alerts, sounds, unread, Claude Code sessions.\nPaused: the live \"running\" spinner and pin syncing; both come back with the window.\nFix: nothing needed. For live status, click Claude in the Dock or ⌘Tab to it.")
        case .codeMode:
            return tr("Claude 的侧边栏现在显示的是 Code，不是 Chat，里面没有你的置顶对话。\n暂停：置顶对话同步、对话的进行中状态。\n不受影响：做完的提醒、Claude Code。\n怎么办：在 Claude 侧边栏顶部切回 Chat。",
                      "Claude's sidebar is showing Code instead of Chat, so your pinned chats aren't in it.\nPaused: syncing pins and the running status of chats.\nStill works: finished alerts, Claude Code.\nFix: switch Claude back to Chat at the top of its sidebar.")
        case .pinsCollapsed:
            return tr("Claude 侧边栏里的 Pinned 区折叠起来了，Kikumap 看不到哪些对话被置顶。\n暂停：置顶列表同步（左栏不会更新）。\n不受影响：做完的提醒、进行中状态、Claude Code。\n怎么办：在 Claude 侧边栏里点一下 Pinned，把它展开。",
                      "The Pinned section in Claude's sidebar is folded, so Kikumap can't see which chats are pinned.\nPaused: syncing your pins (the left column won't update).\nStill works: finished alerts, running status, Claude Code.\nFix: click \"Pinned\" in Claude's sidebar to unfold it.")
        case .sidebarHidden:
            return tr("Claude 的侧边栏收起来了，Kikumap 没有东西可读。\n暂停：进行中状态、置顶对话、侧边栏里的未读。\n不受影响：做完的提醒和提示音、Claude Code。\n怎么办：在 Claude 窗口左上角把侧边栏打开。",
                      "Claude's sidebar is hidden, so there's nothing for Kikumap to read.\nPaused: running status, pinned chats, unread from the sidebar.\nStill works: finished alerts and sounds, Claude Code.\nFix: show the sidebar in Claude's window (top left).")
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
            for (k, label) in [("AXTitle", "t"), ("AXDescription", "d"), ("AXValue", "v"), ("AXURL", "u")] {
                let v = str(el, k); if !v.isEmpty { p += " \(label)='\(short(v, 60))'" }
            }
            if str(el, "AXSelected") == "1" { p += " sel=1" }
            if str(el, "AXElementBusy") == "1" { p += " busy=1" }
            lines.append(String(repeating: "  ", count: min(d, 30)) + p)
            if d < 60 { for c in children(el).reversed() { stack.append((c, d + 1)) } }
        }
        return lines.joined(separator: "\n")
    }

    private static let itemRoles: Set<String> = ["AXLink", "AXButton", "AXRow", "AXCell", "AXMenuItem", "AXRadioButton"]

    /// The Claude app's chat list (the "Sidebar" landmark), if it's open. In another language the landmark
    /// has another name: then the first side landmark that holds chats, or the first one.
    static func sidebar(in web: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(web, 0)]
        var n = 0
        var others: [AXUIElement] = []
        while !queue.isEmpty, n < 400 {
            let (el, d) = queue.removeFirst()
            n += 1
            if str(el, "AXSubrole") == "AXLandmarkComplementary" {
                if str(el, "AXDescription") == "Sidebar" { return el }
                others.append(el)
            }
            if d < 10 { queue += children(el).map { ($0, d + 1) } }
        }
        return others.first { !rows(in: $0).isEmpty } ?? others.first
    }

    /// One chat row: its button, title and status flags (never the title text itself, so a chat
    /// called "thinking…" can't look busy), and the heading it's under.
    struct Row { let button: AXUIElement; let title: String; let flags: String; var section = Section(); var pinned = false }

    /// A heading in the sidebar: its text, its level and how deep it sits, and which one it is (in order).
    struct Section: Equatable { var title = ""; var level = ""; var depth = -1; var order = -1 }

    /// "Pinned" in the languages Claude speaks (where a word is missing, `markPinned` goes by the layout).
    static let pinnedHeadings: Set<String> = ["Pinned", "已置顶", "置顶", "固定", "已固定", "ピン留め", "ピン留め済み", "고정됨",
                                              "Épinglés", "Épinglées", "Angeheftet", "Fijados", "Fijadas", "Fissati", "Fissate",
                                              "Fixados", "Fixadas", "Disematkan"]

    /// Which rows are pinned: the ones under a "Pinned" heading. In a language without a word above, the
    /// section above the date groups (Today, Yesterday…): those sit one level deeper in the sidebar, under
    /// headings of the same rank. Without that layout, none (nothing is shown rather than the wrong chats).
    static func markPinned(_ rows: [Row]) -> [Row] {
        var out = rows
        if rows.contains(where: { pinnedHeadings.contains($0.section.title) }) {
            for i in out.indices { out[i].pinned = pinnedHeadings.contains(out[i].section.title) }
            return out
        }
        guard let deepest = rows.map(\.section.depth).max(),
              let dates = rows.first(where: { $0.section.depth == deepest })?.section else { return out }
        for i in out.indices {
            let s = out[i].section
            out[i].pinned = s.depth >= 0 && s.depth < deepest && !s.level.isEmpty && s.level == dates.level && s.order < dates.order
        }
        return out
    }

    /// Rows are buttons whose row also holds a menu, "More options for …" (in another language other
    /// words, still with the chat's title in them). Scheduled tasks have a second label ("Monthly",
    /// "One-time") and are left out.
    static func rows(in sidebar: AXUIElement) -> [Row] {
        var headings: [String] = []
        return rows(in: sidebar, headings: &headings)
    }

    static func rows(in sidebar: AXUIElement, headings: inout [String]) -> [Row] {
        var out: [Row] = []
        var stack: [(AXUIElement, Int)] = [(sidebar, 0)]
        var n = 0
        var section = Section()     // the last heading passed ("Pinned", "Today", "Oct 23", "Older"…)
        while let (el, d) = stack.popLast(), n < 6000 {
            n += 1
            if str(el, "AXRole") == "AXHeading" {
                section = Section(title: str(el, "AXTitle"), level: str(el, "AXValue"), depth: d, order: headings.count)
                headings.append(section.title)
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
                if str(button, "AXSelected") == "1" || str(el, "AXSelected") == "1" { flags.append("sel=1") }
                let cur = str(button, "AXARIACurrent"); if !cur.isEmpty && cur != "0" && cur != "false" { flags.append("cur=\(cur)") }
                let title = texts.count == 1 ? texts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let label = str(menu, "AXDescription"), english = label.hasPrefix("More options for")
                if !title.isEmpty, english || (title.count >= 2 && label.count > title.count && label.contains(title)) {
                    out.append(Row(button: button, title: title, flags: flags.joined(separator: " ; "), section: section))
                    continue
                }
                if english { continue }     // a row, but not a chat (a scheduled task)
            }
            if d < 40 { for c in kids.reversed() { stack.append((c, d + 1)) } }
        }
        return markPinned(out)
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

    /// Chats whose title shows up as text — for when the sidebar has no /chat/ links (newer Claude apps).
    static func byTitle(_ root: AXUIElement, known: [String: String], into out: inout [AXLink], seen: inout Set<String>) {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var n = 0
        while let (el, d) = stack.popLast(), n < 15000 {
            n += 1
            var text = str(el, "AXValue")
            if text.isEmpty { text = str(el, "AXTitle") }
            if text.isEmpty { text = str(el, "AXDescription") }
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, let id = known[key], !seen.contains(id) {
                // climb to the row that holds the title (its flags carry spinners, selection…)
                var item = el
                for _ in 0..<4 {
                    if itemRoles.contains(str(item, "AXRole")) { break }
                    guard let up = element(attr(item, "AXParent")) else { break }
                    item = up
                }
                seen.insert(id)
                var flags = describe(item, limit: 40)
                if let parent = element(attr(item, "AXParent")), children(parent).count <= 6 {
                    flags += " || parent: " + describe(parent, limit: 50)
                }
                out.append(AXLink(id: id, path: "", title: key, flags: flags))
                continue
            }
            if d < 60 { for c in children(el) { stack.append((c, d + 1)) } }
        }
    }

    /// Every link to a chat in the Claude app's windows.
    /// Every chat in the Claude app's sidebar. `note` says why syncing can't work right now (nil = fine).
    /// `noPins`: the chat list was read whole and has no Pinned section (the last pin was removed, or every chat
    /// deleted), so nothing is pinned any more.
    static func scan(pid: pid_t, wantDump: Bool, known: [String: String] = [:]) -> (links: [AXLink], dump: String, issue: SyncIssue?, noPins: Bool) {
        var issue: SyncIssue?
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3.0)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var dump = ""
        var out: [AXLink] = []
        var seen = Set<String>()
        var allWebs: [AXUIElement] = [], sidebars: [AXUIElement] = []
        // links to chats anywhere in the window: older Claude apps listed chats this way; now only a fallback
        var linkOut: [AXLink] = [], linkSeen = Set<String>()
        var noPins: Bool?
        var titles = Set(known.keys)            // left out of the log
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
                    linkOut.append(AXLink(id: id, path: path, title: title, flags: flags))
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
                var headings: [String] = []
                let rows = rows(in: sb, headings: &headings)
                if codeMode {
                    issue = .codeMode
                } else if headings.contains(where: { pinnedHeadings.contains($0) }) && !rows.contains(where: { $0.pinned }) {
                    issue = .pinsCollapsed
                }
                // no "Pinned" heading, and the chats all under headings of one depth (the date groups): no pins
                let none = !codeMode && !headings.contains(where: { pinnedHeadings.contains($0) }) && !rows.contains(where: { $0.pinned })
                    && Set(rows.map(\.section.depth)).count <= 1
                noPins = (noPins ?? true) && none
                if wantDump { dump += "\nSIDEBAR: \(rows.count) rows · open chat '\(short(openTitle, 60))' \(openID ?? "-")\n" }
                for r in rows {
                    titles.insert(r.title)
                    var id = known[r.title] ?? "n-" + Store.fnv(r.title)
                    var path = ""
                    var flags = r.flags
                    if let o = openID, r.title == openTitle { id = o; path = "/chat/" + o; flags += " ; cur=1" }
                    if seen.contains(id) { continue }
                    seen.insert(id)
                    out.append(AXLink(id: id, path: path, title: r.title, flags: flags, pinned: r.pinned))
                    if wantDump { dump += "ROW \(r.pinned ? "📌 " : "")\(short(r.title, 70))  →  \(id)\n  flags=\(flags)\n" }
                }
            }
        }
        // no chat list to read: chat links (older Claude apps), then known titles
        if out.isEmpty && !linkOut.isEmpty {
            out = linkOut
            seen = linkSeen
            foundSidebar = true
        }
        if out.isEmpty && !known.isEmpty {
            for web in allWebs { byTitle(web, known: known, into: &out, seen: &seen) }
            if wantDump {
                dump += "\nBY TITLE: \(out.count) chats found by their title\n"
                for l in out { dump += "TITLE \(short(l.title, 80))\n  flags=\(l.flags)\n" }
            }
        }
        if wantDump {
            // the chat list only: the rest of the window is the conversation itself (without a chat list,
            // the window with its longer texts left out)
            for (i, root) in (sidebars.isEmpty ? allWebs : sidebars).enumerated() {
                let o = outline(root, limit: 700)
                dump += "\n== OUTLINE \(i) \(sidebars.isEmpty ? "window" : "sidebar")\n" + (sidebars.isEmpty ? maskLong(o) : o) + "\n"
            }
        }
        if issue == nil && !foundSidebar && !windows.isEmpty { issue = .sidebarHidden }
        if wantDump, let n = issue { dump = "# Sync problem: \(n.note)\n" + dump }
        if wantDump { dump = redact(dump, titles: titles) }
        return (out, dump, issue, issue == nil && noPins == true)
    }

    /// The log without chat titles (each becomes ‹title›), so it can be sent to someone.
    static func redact(_ text: String, titles: Set<String>) -> String {
        var t = text
        for title in titles.sorted(by: { $0.count > $1.count }) {
            let key = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
            guard key.count >= 3 else { continue }
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
    enum Status { case starting, ok, noAccess, noApp }
    private(set) var status = Status.starting
    /// The chats read, and whether nothing is pinned any more (seen twice in a row, so a list still loading
    /// doesn't count).
    var onScan: (([AXLink], Bool) -> Void)?
    private var noPinsSeen = 0
    var onQuit: (() -> Void)?
    var onStatus: (() -> Void)?
    private let store: Store
    private var observer: AXObserver?
    private var pid: pid_t = 0
    /// The Claude app's process (0 when it isn't running).
    var claudePID: pid_t { pid }
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

    private func setStatus(_ s: Status) {
        if s != status { status = s; onStatus?() }
    }

    func attach() {
        guard AXIsProcessTrusted() else { setStatus(.noAccess); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first else {
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
        setStatus(.ok)
        schedule(0.5)
    }

    private func detach() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil
        pid = 0
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
        let wait = max(delay, 2.0 - Date().timeIntervalSince(lastScan))
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, wait)) { [weak self] in
            MainActor.assumeIsolated { self?.run() }
        }
    }

    private func run() {
        scheduled = false
        guard pid != 0, !scanning else { return }
        scanning = true
        lastScan = Date()
        let p = pid, dump = dumpNext
        dumpNext = false
        var known: [String: String] = [:]
        for c in store.chats where !c.title.isEmpty && (known[c.title] == nil || !c.id.hasPrefix("n-")) { known[c.title] = c.id }
        DispatchQueue.global(qos: .utility).async {
            let r = AXScan.scan(pid: p, wantDump: dump, known: known)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.scanning = false
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
                    self.noPinsSeen = r.noPins ? self.noPinsSeen + 1 : 0
                    self.onScan?(r.links, self.noPinsSeen >= 2)
                }
            }
        }
    }
}
