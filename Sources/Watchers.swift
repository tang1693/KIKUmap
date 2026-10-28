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

    /// The Claude app's chat list (the "Sidebar" landmark), if it's open.
    static func sidebar(in web: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(web, 0)]
        var n = 0
        while !queue.isEmpty, n < 400 {
            let (el, d) = queue.removeFirst()
            n += 1
            if str(el, "AXSubrole") == "AXLandmarkComplementary" && str(el, "AXDescription") == "Sidebar" { return el }
            if d < 10 { queue += children(el).map { ($0, d + 1) } }
        }
        return nil
    }

    /// One chat row: its button, title and status flags (never the title text itself, so a chat
    /// called "thinking…" can't look busy).
    struct Row { let button: AXUIElement; let title: String; let flags: String; let pinned: Bool }

    private static let pinnedHeadings: Set<String> = ["Pinned", "已置顶", "置顶", "固定"]

    /// Rows are buttons whose row also holds a "More options for …" menu. Scheduled tasks have a
    /// second label ("Monthly", "One-time") and are left out.
    static func rows(in sidebar: AXUIElement) -> [Row] {
        var headings: [String] = []
        return rows(in: sidebar, headings: &headings)
    }

    static func rows(in sidebar: AXUIElement, headings: inout [String]) -> [Row] {
        var out: [Row] = []
        var stack: [(AXUIElement, Int)] = [(sidebar, 0)]
        var n = 0
        var section = ""            // the last heading passed ("Pinned", "Today", "Oct 23", "Older"…)
        while let (el, d) = stack.popLast(), n < 6000 {
            n += 1
            if str(el, "AXRole") == "AXHeading" { section = str(el, "AXTitle"); headings.append(section); continue }
            let kids = children(el)
            if let button = kids.first(where: { str($0, "AXRole") == "AXButton" }),
               kids.contains(where: { k in children(k).contains { str($0, "AXDescription").hasPrefix("More options for") } }) {
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
                if texts.count == 1 {
                    out.append(Row(button: button, title: texts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                                   flags: flags.joined(separator: " ; "), pinned: pinnedHeadings.contains(section)))
                }
                continue
            }
            if d < 40 { for c in kids.reversed() { stack.append((c, d + 1)) } }
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
    static func scan(pid: pid_t, wantDump: Bool, known: [String: String] = [:]) -> (links: [AXLink], dump: String, note: String?) {
        var note: String?
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3.0)
        let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var dump = ""
        var out: [AXLink] = []
        var seen = Set<String>()
        var allWebs: [AXUIElement] = []
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
                    // only links to chats — a UUID inside some web page a chat cites doesn't count
                    guard url.contains("claude.ai/chat/") || url.contains("claude.ai/code/"),
                          let m = uuidRx.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)) else { continue }
                    let id = ns.substring(with: m.range).lowercased()
                    if seen.contains(id) { continue }
                    seen.insert(id)
                    let path = URL(string: url)?.path ?? ""
                    let title = linkText(l)
                    var flags = describe(l, limit: 40)
                    if let parent = element(attr(l, "AXParent")), children(parent).count <= 6 {
                        flags += " || parent: " + describe(parent, limit: 50)
                    }
                    out.append(AXLink(id: id, path: path, title: title, flags: flags))
                    if wantDump { dump += "LINK \(path)\n  title=\(short(title, 80))\n  flags=\(flags)\n" }
                }
            }
            allWebs.append(contentsOf: webs)
            if webs.isEmpty { allWebs.append(w) }
        }
        if windows.isEmpty {
            note = winErr == .apiDisabled ? tr("辅助功能授权失效，请在系统设置里删掉再加回来", "Accessibility is off for this build — remove and re-add it in System Settings")
                                          : tr("Claude 的窗口没打开", "No Claude window is open")
        }
        // newer Claude apps: the sidebar has no links, read its rows instead
        var foundSidebar = !out.isEmpty
        if out.isEmpty && !windows.isEmpty {
            for web in allWebs {
                guard let sb = sidebar(in: web) else { continue }
                foundSidebar = true
                // the Chat / Code switch at the top of the sidebar
                var codeMode = false
                var q: [(AXUIElement, Int)] = [(sb, 0)]
                while let (el, d) = q.popLast(), !codeMode {
                    if str(el, "AXRole") == "AXRadioButton" && str(el, "AXDescription") == "Code" && str(el, "AXValue") == "1" { codeMode = true }
                    if d < 4 { q += children(el).map { ($0, d + 1) } }
                }
                // the open chat: its address is in the page URL, its title in the page title
                let url = str(web, "AXURL"), ns = url as NSString
                let openID = uuidRx.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
                var openTitle = str(web, "AXTitle")
                if openTitle.hasSuffix(" - Claude") { openTitle = String(openTitle.dropLast(9)) }
                var headings: [String] = []
                let rows = rows(in: sb, headings: &headings)
                if codeMode {
                    note = tr("Claude 在 Code 模式，切回 Chat 才能同步置顶对话", "Claude is in Code mode — switch back to Chat to sync pinned chats")
                } else if headings.contains(where: { pinnedHeadings.contains($0) }) && !rows.contains(where: { $0.pinned }) {
                    note = tr("Claude 的 Pinned 区折叠了，展开才能同步", "Claude's Pinned section is collapsed — expand it to sync")
                }
                if wantDump { dump += "\nSIDEBAR: \(rows.count) rows · open chat '\(short(openTitle, 60))' \(openID ?? "-")\n" }
                for r in rows {
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
        if out.isEmpty && !known.isEmpty {
            for web in allWebs { byTitle(web, known: known, into: &out, seen: &seen) }
            if wantDump {
                dump += "\nBY TITLE: \(out.count) chats found by their title\n"
                for l in out { dump += "TITLE \(short(l.title, 80))\n  flags=\(l.flags)\n" }
            }
        }
        if wantDump {
            for (i, web) in allWebs.enumerated() {
                dump += "\n== OUTLINE \(i) url='\(str(web, "AXURL"))'\n" + outline(web, limit: 700) + "\n"
            }
        }
        if note == nil && !foundSidebar && !windows.isEmpty {
            note = tr("Claude 的侧边栏收起来了，展开才能同步", "Claude's sidebar is hidden — show it to sync")
        }
        if wantDump, let n = note { dump = "# Sync problem: \(n)\n" + dump }
        return (out, dump, note)
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
    var onScan: (([AXLink]) -> Void)?
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
    private(set) var syncNote: String?

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

    /// Writes the next scan to logs/claude-sidebar.txt.
    func diagnose() {
        dumpNext = true
        attach()
        schedule(0)
    }

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
                    self.syncNote = r.note
                    if r.note == nil { self.lastSync = Date() }
                    if dump {
                        var head = "# Claude sidebar \(Clock.iso())  links=\(r.links.count)\n"
                        if r.links.isEmpty {
                            head += "# No chats found. Open the Claude app's sidebar (the chat list) and write the log again.\n"
                        }
                        try? (head + r.dump).data(using: .utf8)?.write(to: self.store.logsDir.appendingPathComponent("claude-sidebar.txt"))
                    }
                    self.onScan?(r.links)
                }
            }
        }
    }
}
