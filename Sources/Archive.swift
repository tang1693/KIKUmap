import Cocoa
import Carbon
import IOKit.pwr_mgt

/// Export: each chat under the topics you pick gets its own folder —
///   memory.md        a hand-off summary Claude writes inside the chat (copied out through its Copy button)
///   prompts.md, conversation.md, artifacts/, attachments/   from Claude's official data export (a zip)
/// Later the folders can start new chats — in another account, say — that pick up where these left off,
/// with the artifacts attached. The summaries are written by working the Claude app through
/// Accessibility, so its window switches chats while that part runs.
@MainActor
final class Archive {
    struct Record: Codable { var date: String; var messages: Int; var file: String }
    private struct State: Codable {
        var summaries: [String: Record] = [:]
        var imported: [String: String] = [:]          // old chat id → new chat id
        var zipDone: String?                          // the export zip already read ("path|modified")
        /// When the newest zip applied was made: an older one in Downloads is never applied over it by itself.
        var zipDoneAt: Double?
        /// The folder each chat's own files (prompts, conversation, artifacts, attachments) were last put in (a full
        /// path: it says which export folder too). They follow the chat when it's filed elsewhere.
        var files: [String: String] = [:]
        /// Chats whose files couldn't be written from the zip last read (a full disk, a folder still another chat's),
        /// when that was, and how many runs in a row from that zip left some unwritten: they're tried again from it by
        /// themselves an hour on, then each time twice as long after (see fromZip).
        var zipMissed: [String] = []
        var zipTriedAt: Double?
        var zipTries = 0
        /// A zip in Downloads that couldn't be read, or isn't Claude's export after all ("path|modified"): it isn't read
        /// again by itself every few minutes (Export still tries it; a new zip is read as usual).
        var zipUnreadable: String?

        init() {}
        /// A part that's missing (an older or newer file) reads as empty; one that's there but unreadable fails the file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summaries = try c.decodeIfPresent([String: Record].self, forKey: .summaries) ?? [:]
            imported = try c.decodeIfPresent([String: String].self, forKey: .imported) ?? [:]
            zipDone = try c.decodeIfPresent(String.self, forKey: .zipDone)
            zipDoneAt = try c.decodeIfPresent(Double.self, forKey: .zipDoneAt)
            files = try c.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
            zipMissed = try c.decodeIfPresent([String].self, forKey: .zipMissed) ?? []
            zipTriedAt = try c.decodeIfPresent(Double.self, forKey: .zipTriedAt)
            zipTries = try c.decodeIfPresent(Int.self, forKey: .zipTries) ?? 0
            zipUnreadable = try c.decodeIfPresent(String.self, forKey: .zipUnreadable)
        }
    }
    /// One chat to export and the folder it goes in.
    struct Item { let id: String; let title: String; let dir: URL; let outsideClaude: Bool }

    let store: Store
    var pid: () -> pid_t = { 0 }
    /// Accessibility is on (a test stands in for it).
    var trusted: () -> Bool = { AXIsProcessTrusted() }
    /// Seconds since your last keyboard or mouse input (a test stands in for it).
    var idle: () -> Double = { Archive.idleSeconds() }
    /// What Claude replies when asked for one chat's summary (a test stands in for Claude's window; nil: Claude's own,
    /// through Accessibility).
    var askSummary: ((Item) -> ClaudeDriver.Result)?
    /// Claude's window can be worked now: the app is open and Accessibility is on.
    var canDrive: Bool { pid() != 0 && trusted() }
    var onChange: (() -> Void)?
    private var state = State()
    private let stop = StopFlag()

    private(set) var busy = false
    /// What the run under way is: an import (else an export).
    private(set) var importing = false
    /// The run under way works Claude's window: summaries (once the export zip, if any, is read) or an import. One that
    /// only writes the files from Claude's export zip never touches it: Claude's own finishes are heard as usual then.
    var drivesClaude: Bool { busy && (importing || summarizing) }
    /// The export under way asks Claude for summaries (decided as it starts: asked for, and Claude can be worked).
    private var summarizing = false

    /// Why Export, Import or Archive a summary… can't start now: a run is under way, and nothing else starts until
    /// it's done (nil: none is). Said before anything is asked or saved.
    var busyNote: (title: String, text: String)? {
        guard busy else { return nil }
        return (importing ? tr("导入还没做完", "An import is still running") : tr("存档还没做完", "An export is still running"),
                tr("等它做完再试：顶栏会显示进度，也可以点那里的「停止」。", "Try again once it's done. The top bar shows its progress, and its Stop button ends it."))
    }

    /// An alert of KIKUmap's own (a test stands in for it).
    static var say: (_ title: String, _ text: String) -> Void = { Permissions.alert($0, $1) }
    private(set) var progress = ""                    // "3/12 · title"
    /// archive.json couldn't be read at launch: where it was kept (nil: it was read, or there was none yet).
    private(set) var unreadable: String?
    /// Why archive.json can't be saved right now (nil: it can).
    private(set) var saveError: String?
    /// archive.json couldn't be read or moved aside: it's left as it is this session.
    private var readOnly = false
    /// Reading back when each chat was last summarized, after archive.json was lost: the automatic run waits.
    private var recovering = false

    private var stateURL: URL { store.dir.appendingPathComponent("data/archive.json") }

    init(store: Store) {
        self.store = store
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) } catch {
            keepAside(error)
            recoverSummaries()
        }
    }

    /// There but unreadable (damaged, or from a newer KIKUmap): moved to data/backups before anything can write over
    /// it (what was imported and summarized is in it), and listed in the To-do.
    private func keepAside(_ error: Error) {
        let fm = FileManager.default, dir = stateURL.deletingLastPathComponent().appendingPathComponent("backups")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent("archive-unreadable-" + MapModel.stamp("yyyyMMdd-HHmmss") + ".json")
        if (try? fm.moveItem(at: stateURL, to: to)) != nil { unreadable = "data/backups/" + to.lastPathComponent } else {
            readOnly = true
            unreadable = "data/archive.json" + tr("（没法移开；现在导入和总结的记录不会保存）",
                                                  " (it couldn't be moved aside; imports and summaries made now aren't recorded)")
        }
        store.log("\(Clock.iso()) couldn't read archive.json (\(error.localizedDescription)); kept as \(unreadable ?? "-")\n", file: "app.log")
    }

    /// When each chat was last summarized is read back from its memory.md (`id:` and `summarized:` up top), so the
    /// next run doesn't summarize every chat again.
    private func recoverSummaries() {
        recovering = true
        let root = Archive.folder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [String: Record] = [:]
            let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = all?.nextObject() as? URL {
                // (an artifact called memory.md, among a chat's own files, isn't a summary: Import leaves it too)
                guard url.lastPathComponent == "memory.md", !Archive.inChatFiles(url, under: root), let s = try? String(contentsOf: url, encoding: .utf8), s.hasPrefix("---\n"),
                      let end = s.range(of: "\n---\n") else { continue }
                var id = "", when = ""
                for line in s[..<end.lowerBound].split(separator: "\n") {
                    if line.hasPrefix("id: ") { id = String(line.dropFirst(4)) }
                    if line.hasPrefix("summarized: ") { when = String(line.dropFirst(12)) }
                }
                if Archive.isChatID(id), when > (found[id]?.date ?? "") {
                    found[id] = Record(date: when, messages: 0, file: String(url.path.dropFirst(root.path.count + 1)))
                }
            }
            let back = found
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self = self else { return }
                for (id, r) in back where r.date > (self.state.summaries[id]?.date ?? "") { self.state.summaries[id] = r }
                self.recovering = false
                if !back.isEmpty { self.saveState() }
            } }
        }
    }

    // MARK: settings

    private static var d: UserDefaults { .standard }
    static var auto: Bool {
        get { d.bool(forKey: "ArchiveAuto") }
        set { d.set(newValue, forKey: "ArchiveAuto") }
    }
    static let everyChoices = [1, 7, 30]
    static var everyDays: Int {
        get { let v = d.integer(forKey: "ArchiveEveryDays"); return everyChoices.contains(v) ? v : 7 }
        set { d.set(newValue, forKey: "ArchiveEveryDays") }
    }
    static var folder: URL {
        get {
            if let p = d.string(forKey: "ArchiveFolder"), !p.isEmpty { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Prefs.lang.isChinese ? "Claude 导出" : "Claude Export")   // (Chinese or English only, as `named`)
        }
        set {
            if folder.path != newValue.path { d.set(folder.path, forKey: "ArchivePreviousFolder") }
            d.set(newValue.path, forKey: "ArchiveFolder")
        }
    }
    /// The folder exports went to before the last change (summaries there are brought along, not written again).
    static var previousFolder: URL? { d.string(forKey: "ArchivePreviousFolder").map { URL(fileURLWithPath: $0) } }
    /// Why the export folder can't take files now (made if need be), as a title and what to do; nil: it can. Tried with a
    /// file of a summary's size, written and taken away again: macOS lets KIKUmap in, the disk is there, writable, with
    /// room. In Documents, Desktop or Downloads, or on an external or network disk macOS keeps KIKUmap off, it's macOS
    /// saying no (after a "Don't Allow" it doesn't ask again), not a disk that isn't connected.
    static func unreachable(_ root: URL) -> (title: String, text: String)? {
        let fm = FileManager.default
        var failure: NSError?
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let probe = root.appendingPathComponent(".kikumap-check")
            defer { try? fm.removeItem(at: probe) }
            try Data(count: 64 * 1024).write(to: probe)
        } catch { failure = error as NSError }
        guard let failure else { return nil }
        let posix = (failure.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
            ?? (failure.domain == NSPOSIXErrorDomain ? Int32(failure.code) : nil)
        let denied = [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(failure.code) || [EPERM, EACCES].contains(posix ?? 0)
        let other = tr("在「导出对话」窗口点「更改…」，换一个文件夹。", "Click Change… in the Export chats window to pick another folder.")
        // (an external or network disk that isn't there: making its folder in /Volumes is refused too)
        let parts = root.standardizedFileURL.pathComponents
        let away = parts.count > 2 && parts[1] == "Volumes" && !fm.fileExists(atPath: "/Volumes/" + parts[2])
        // (on an external or network disk, macOS's no is "not permitted"; "permission denied" is the disk's own owners)
        if let place = (denied ? protectedFolder(root) : nil) ?? (!away && posix == EPERM ? protectedVolume(root) : nil) {
            return (tr("macOS 不让 KIKUmap 存到导出文件夹", "macOS won't let KIKUmap save to the export folder"),
                    root.path + "\n\n" + tr("怎么办：系统设置 → 隐私与安全性 → 文件与文件夹，给 KIKUmap 打开\(Archive.placeName(place))。或者在「导出对话」窗口点「更改…」，换一个文件夹。",
                                            "Fix: System Settings → Privacy & Security → Files and Folders: turn on \(Archive.placeName(place)) for KIKUmap. Or click Change… in the Export chats window to pick another folder."))
        }
        if !away && (failure.code == NSFileWriteVolumeReadOnlyError || posix == EROFS) {
            return (tr("导出文件夹所在的磁盘是只读的", "The export folder's disk is read-only"), root.path + "\n\n" + other)
        }
        if !away && (failure.code == NSFileWriteOutOfSpaceError || posix == ENOSPC || posix == EDQUOT) {
            return (tr("导出文件夹所在的磁盘满了", "The export folder's disk is full"),
                    root.path + "\n\n" + tr("怎么办：在这个磁盘上腾出一些空间；或者在「导出对话」窗口点「更改…」，换一个文件夹。",
                                            "Fix: free up some space on that disk, or click Change… in the Export chats window to pick another folder."))
        }
        if !away && denied { return (tr("没有权限存到导出文件夹", "No permission to save to the export folder"), root.path + "\n\n" + other) }
        return (tr("导出文件夹现在打不开（外接盘或网络盘没接上？）", "The export folder can't be reached (is its disk connected?)"), root.path)
    }

    /// The external or network disk `url` is on, by the name System Settings gives it under Files and Folders (nil: the
    /// Mac's own disk). A test stands in for it.
    static var protectedVolume: (URL) -> (zh: String, en: String)? = { url in
        // (the folder may not be made yet: the nearest one above it that's there)
        var u = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: u.path) && u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        guard let v = try? u.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey]) else { return nil }
        if v.volumeIsLocal == false { return ("「网络宗卷」", "Network Volumes") }
        return v.volumeIsInternal == false ? ("「可移除的宗卷」", "Removable Volumes") : nil
    }

    /// Said before macOS can ask whether KIKUmap may save in the export folder (nil with Full Disk Access: then it never
    /// asks). It asks once for Documents, Desktop and Downloads, and for external and network disks. For a folder picked
    /// with Change… the open panel lets KIKUmap in until it quits, so macOS may ask only after it starts again (when a
    /// scheduled export first saves there, say).
    static var asksNote: String? {
        guard !ClaudeExport.canLookInDownloads else { return nil }
        return tr("第一次存到「文稿」「桌面」「下载」或外接盘、网络盘里时，macOS 会问一次是否允许 KIKUmap 存到这里。用「更改…」选的文件夹，可能要等 KIKUmap 重新打开后、再存进去时才问。",
                  "The first time KIKUmap saves into Documents, Desktop or Downloads, or onto an external or network disk, macOS asks once whether it may. For a folder picked with Change…, it may ask only later, the first time KIKUmap saves there after it restarts.")
    }

    /// The folders macOS asks about before an app may save in them, by the names System Settings gives them under
    /// Files and Folders (a test points them elsewhere).
    static var askedFolders: [(dir: URL, zh: String, en: String)] = {
        let fm = FileManager.default
        return [(FileManager.SearchPathDirectory.documentDirectory, "「文稿」文件夹", "Documents Folder"),
                (.desktopDirectory, "「桌面」文件夹", "Desktop Folder"), (.downloadsDirectory, "「下载」文件夹", "Downloads Folder")]
            .compactMap { d, zh, en in fm.urls(for: d, in: .userDomainMask).first.map { ($0, zh, en) } }
    }()

    /// A place's name as System Settings shows it, in the app's language.
    nonisolated static func placeName(_ p: (zh: String, en: String)) -> String {
        switch p.en {
        case "Documents Folder": return tr("「文稿」文件夹", "Documents Folder")
        case "Desktop Folder": return tr("「桌面」文件夹", "Desktop Folder")
        case "Downloads Folder": return tr("「下载」文件夹", "Downloads Folder")
        case "Network Volumes": return tr("「网络宗卷」", "Network Volumes")
        case "Removable Volumes": return tr("「可移除的宗卷」", "Removable Volumes")
        default: return tr(p.zh, TrKey(p.en))
        }
    }

    /// Which of those `url` is in.
    static func protectedFolder(_ url: URL) -> (zh: String, en: String)? {
        let path = url.standardizedFileURL.path.lowercased() + "/"
        return askedFolders.first { path.hasPrefix($0.dir.standardizedFileURL.path.lowercased() + "/") }.map { ($0.zh, $0.en) }
    }

    /// A Claude chat's address (not a title-only "n-…" id).
    nonisolated static func isAddress(_ id: String) -> Bool { id.range(of: "^[0-9a-f-]{36}$", options: .regularExpression) != nil }
    /// The default folder keeps the name it was first given: when an export starts (Documents is opened then anyway),
    /// one already there in either language is used, and remembered, so a language switch doesn't start a second archive.
    static func settleFolder() {
        guard (d.string(forKey: "ArchiveFolder") ?? "").isEmpty else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let names = Prefs.english ? ["Claude Export", "Claude 导出"] : ["Claude 导出", "Claude Export"]
        folder = names.map { docs.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) } ?? folder
    }
    /// A folder KIKUmap names in its language: the one already in `dir` in the other language, if there is one.
    static func named(_ zh: String, _ en: String, in dir: URL) -> String {
        // (a folder's name stays Chinese or English, whatever the language: a switch never starts a second folder)
        let fm = FileManager.default, mine = Prefs.lang.isChinese ? zh : en, other = mine == zh ? en : zh
        return !fm.fileExists(atPath: dir.appendingPathComponent(mine).path) && fm.fileExists(atPath: dir.appendingPathComponent(other).path) ? other : mine
    }
    /// Topic ids picked in the export window (nil = everything).
    static var topics: Set<String>? {
        get { (d.array(forKey: "ExportTopics") as? [String]).map(Set.init) }
        set { d.set(newValue.map(Array.init), forKey: "ExportTopics") }
    }
    /// Every topic the export window showed when the choice was saved (a newer one wasn't asked about).
    static var knownTopics: Set<String>? {
        get { (d.array(forKey: "ExportKnownTopics") as? [String]).map(Set.init) }
        set { d.set(newValue.map(Array.init), forKey: "ExportKnownTopics") }
    }
    static var withUnplaced: Bool {
        get { d.object(forKey: "ExportUnplaced") == nil ? true : d.bool(forKey: "ExportUnplaced") }
        set { d.set(newValue, forKey: "ExportUnplaced") }
    }
    static var withMemory: Bool {
        get { d.object(forKey: "ExportMemory") == nil ? true : d.bool(forKey: "ExportMemory") }
        set { d.set(newValue, forKey: "ExportMemory") }
    }
    static var withFiles: Bool {
        get { d.object(forKey: "ExportFiles") == nil ? true : d.bool(forKey: "ExportFiles") }
        set { d.set(newValue, forKey: "ExportFiles") }
    }
    /// You said yes to Claude writing the summaries on the schedule too, while you're away (asked when an export starts
    /// with automatic updates on): without it the schedule brings only the files up to date. Unticking "Keep it
    /// updated" or memory takes it back at once.
    static var autoMemoryAgreed: Bool {
        get { d.bool(forKey: "ArchiveAutoMemoryAgreed") }
        set { d.set(newValue, forKey: "ArchiveAutoMemoryAgreed") }
    }
    /// What the export window saves when an export starts, as it's saved now: put back when the export isn't started
    /// after all. ("Keep it updated" isn't one: it's on or off as soon as it's ticked.)
    private static let choiceKeys = ["ExportTopics", "ExportKnownTopics", "ExportUnplaced", "ExportMemory", "ExportFiles",
                                     "ArchiveEveryDays", "ArchiveFolder", "ArchivePreviousFolder"]
    static func savedChoices() -> [String: Any] {
        var out: [String: Any] = [:]
        for k in choiceKeys { if let v = d.object(forKey: k) { out[k] = v } }
        return out
    }
    static func restoreChoices(_ saved: [String: Any]) {
        for k in choiceKeys { if let v = saved[k] { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
    }
    static var lastRun: Date? {
        get { let t = d.double(forKey: "ArchiveLastRun"); return t > 0 ? Date(timeIntervalSince1970: t) : nil }
        set { d.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "ArchiveLastRun") }
    }
    static var lastResult: String {
        get { d.string(forKey: "ArchiveLastResult") ?? "" }
        set { d.set(newValue, forKey: "ArchiveLastResult") }
    }

    func summarized(_ id: String) -> Record? { state.summaries[id] }

    // MARK: what to export

    /// Every chat on the map under the chosen topics — pinned or not — plus, if asked, pinned chats
    /// that aren't on the map. Each gets a folder named after its topics.
    func items(topics: Set<String>?, unplaced: Bool) -> [Item] { chosen(topics: topics, unplaced: unplaced).items }

    /// The Claude-app chats the choice holds, each with its folder, and how many others it holds: ChatGPT chats and
    /// Claude Code or Codex sessions, which aren't exported, so they're neither counted nor given a folder name (a Claude
    /// chat of the same name keeps its plain one).
    func chosen(topics: Set<String>?, unplaced: Bool) -> (items: [Item], others: Int) {
        Archive.settleFolder()
        let map = store.map
        var out: [Item] = [], others = 0
        var seen = Set<String>()
        var usedDirs = Set<String>()
        // a chat Import started from an earlier one gets a folder of its own beside that one's, which stays as it was
        // (one started from that one again: "(continued 2)", and so on)
        let continues = Dictionary(state.imported.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        func depth(_ id: String) -> Int { var d = 0, x = id; while let o = continues[x], d < 9 { d += 1; x = o }; return d }
        // a folder another chat left, one that isn't listed any more (unpinned, deleted): it stays that chat's
        let onMap = map.placedChats()
        func leftBy(_ dir: URL, _ c: Chat) -> Bool {
            let path = dir.path.lowercased()
            let holder = Archive.summaryID(dir.appendingPathComponent("memory.md")) ?? state.files.first { $0.key != c.id && $0.value.lowercased() == path }?.key
            guard let h = holder, h != c.id, !(h == "n-" + Store.fnv(c.title) && store.chat(h) == nil) else { return false }
            return !onMap.contains(h) && store.chat(h)?.pinned != true
        }
        func add(_ id: String, _ path: [String]) {
            guard !seen.contains(id), let c = store.chat(id) else { return }
            seen.insert(id)
            if c.outsideClaude { others += 1; return }
            var dir = path.reduce(Archive.folder) { $0.appendingPathComponent(ClaudeExport.safeName($1)) }
                .appendingPathComponent(ClaudeExport.safeName(store.name(id) + { d in d == 0 ? "" : Prefs.lang.isChinese ? "（续\(d > 1 ? "\(d)" : "")）" : " (continued\(d > 1 ? " \(d)" : ""))" }(depth(id))))
            // the Mac's disk ignores case ("Plan" and "plan" are one folder): two chats never share a folder
            if usedDirs.contains(dir.path.lowercased()) || leftBy(dir, c) { dir = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + " " + String(id.suffix(6))) }
            usedDirs.insert(dir.path.lowercased())
            out.append(Item(id: id, title: c.title, dir: dir, outsideClaude: c.outsideClaude))
        }
        func walk(_ n: MapNode, _ path: [String], _ on: Bool) {
            for ch in n.children {
                switch ch {
                case .chat(let id): if on { add(id, path) }
                case .node(let s):
                    // chats right on the map have a box of their own: it doesn't take the topics along
                    let inherited = n === map.root ? false : on
                    let parent = path.reduce(Archive.folder) { $0.appendingPathComponent(ClaudeExport.safeName($1)) }
                    // a box unticked counts, whatever its parent's; a topic added since the choice was saved follows its parent
                    let ticked = topics?.contains(s.id) ?? true
                    let decided = topics != nil && Archive.knownTopics?.contains(s.id) == true
                    walk(s, path + [s.title.isEmpty ? Archive.named("新主题", "New topic", in: parent) : s.title], decided ? ticked : inherited || ticked)
                }
            }
        }
        walk(map.root, [], topics == nil || topics!.contains(map.root.id))
        if unplaced {
            let placed = map.placedChats()
            let unfiled = Archive.named("未归类", "Unfiled", in: Archive.folder)
            for c in store.pinnedList() where !placed.contains(c.id) { add(c.id, [unfiled]) }
        }
        return (out, others)
    }

    // MARK: running

    /// Export with the settings saved in the export window.
    func exportSaved(scheduled: Bool, memory: Bool? = nil) {
        // (not one older than the newest read: that's never put over it by itself; nor one that couldn't be read)
        let zip = Archive.withFiles ? ClaudeExport.newestZip().flatMap { z in
            ClaudeExport.modified(z).timeIntervalSince1970 >= (state.zipDoneAt ?? 0) && zipKey(z) != state.zipUnreadable ? z : nil
        } : nil
        export(items(topics: Archive.topics, unplaced: Archive.withUnplaced), memory: memory ?? Archive.withMemory,
               zip: zip, force: false, scheduled: scheduled)
    }

    /// Right-click → archive one chat: just its summary, asked whatever the chat shows (unread, nothing new since the
    /// last one). Not one that's running, which isn't opened at all (`notNow` says why): false, nothing done.
    @discardableResult
    func runOne(_ id: String) -> Bool {
        guard notNow(id) == nil else { return false }
        guard let it = items(topics: nil, unplaced: true).first(where: { $0.id == id }) ?? store.chat(id).map({
            Item(id: id, title: $0.title, dir: Archive.folder.appendingPathComponent(Archive.named("未归类", "Unfiled", in: Archive.folder)).appendingPathComponent(ClaudeExport.safeName(store.name(id))), outsideClaude: $0.outsideClaude)
        }) else { return false }
        export([it], memory: true, zip: nil, force: true, scheduled: false)
        return true
    }

    /// Why one chat can't be archived by right-click now: it's running (or was, when KIKUmap last saw it), and asking
    /// in it would mean opening it while Claude may still be replying. Nil: it can be.
    func notNow(_ id: String) -> (title: String, text: String)? {
        guard store.isRunning(id) else { return nil }
        if store.outOfSight(id) {
            return (tr("这个对话可能还在跑", "This chat may still be running"),
                    tr("KIKUmap 上次看到它时，它还在跑；现在做完没有，还不知道。等它做完、KIKUmap 又能看到 Claude 的对话列表时再存档。",
                       "It was running when KIKUmap last saw it. Whether it has finished isn't known yet. Archive it once it's done and KIKUmap can see Claude's chat list again."))
        }
        return (tr("这个对话还在跑", "This chat is still running"),
                tr("等它做完再存档。Claude 还在回复时，KIKUmap 不会打开它。", "Archive it once it's done. KIKUmap doesn't open a chat while Claude is still replying in it."))
    }

    func cancel() { stop.set(true) }

    /// Every few minutes. With automatic updates on: a new Claude export zip in Downloads updates the
    /// files right away; the summaries are brought up to date when they're due and the Mac is idle.
    func tick() {
        retrySave()
        guard Archive.auto, !busy, !recovering else { return }
        if Archive.withFiles, let z = ClaudeExport.newestZip(), let todo = fromZip(z) {
            export(todo, memory: false, zip: z, force: false, scheduled: true)
            return
        }
        // Claude writes in your chats on the schedule only with the yes you gave for that when the export started
        guard Archive.withMemory, Archive.autoMemoryAgreed, canDrive else { return }
        let due = (Archive.lastRun.map { Date().timeIntervalSince($0) } ?? .infinity) >= Double(Archive.everyDays) * 86400 - 600
        // away: no input for 10 minutes, and nothing keeping the screen on (a video, a call, a presentation)
        guard due, idle() >= 600, !Archive.screenKeptOn() else { return }
        exportSaved(scheduled: true, memory: true)
    }

    /// The zip whose being Claude's was last looked into (once is enough).
    private var checkedDone: String?

    /// How many times the chats a zip couldn't write are tried again from it by themselves.
    static let zipRetries = 5

    /// What Claude's export zip in Downloads brings now: every chat when it's a new one; a while after a run that
    /// couldn't write some chats' files from it (an hour, then twice as long each time, five times), those chats again;
    /// else nothing (nil).
    private func fromZip(_ z: URL) -> [Item]? {
        // one that couldn't be read (a format KIKUmap doesn't know, a zip cut short) would fail the same way every few
        // minutes, each time a run of its own: once is enough (a new zip, or Export, reads it again)
        if zipKey(z) == state.zipUnreadable { return nil }
        let at = ClaudeExport.modified(z).timeIntervalSince1970
        // an older KIKUmap took another app's export (ChatGPT's) for Claude's: that's forgotten, so Claude's own applies
        if at < (state.zipDoneAt ?? 0), let done = state.zipDone, done != checkedDone, let bar = done.range(of: "|", options: .backwards) {
            checkedDone = done
            let other = URL(fileURLWithPath: String(done[..<bar.lowerBound]))
            if FileManager.default.fileExists(atPath: other.path), !ClaudeExport.isClaude(other) {
                state.zipDone = nil; state.zipDoneAt = nil; state.zipMissed = []; state.zipTries = 0
                saveState()
            }
        }
        if zipKey(z) != state.zipDone {
            return at > (state.zipDoneAt ?? 0) ? items(topics: Archive.topics, unplaced: Archive.withUnplaced) : nil
        }
        // one that can never be written (a file where its folder goes, a name the disk refuses) doesn't have the whole
        // zip read again every hour for ever: an hour, then 2, 4, 8 and 16 after each run that still left it, and that's
        // all (they're still counted, and tried, by the next export that reads this zip, or by a new zip)
        let tries = max(state.zipTries, 1)
        guard !state.zipMissed.isEmpty, tries <= Archive.zipRetries,
              Date().timeIntervalSince1970 - (state.zipTriedAt ?? 0) >= 3600 * Double(1 << (tries - 1)) else { return nil }
        let again = items(topics: Archive.topics, unplaced: Archive.withUnplaced).filter { state.zipMissed.contains($0.id) }
        // (none of them is among the chosen chats any more)
        if again.isEmpty { state.zipMissed = []; saveState(); return nil }
        // the zip is read again only when one may get through now: one whose folder is still another chat's wouldn't
        return again.contains { !taken($0.dir, by: $0.id) } ? again : nil
    }

    private func zipKey(_ z: URL) -> String { z.path + "|" + String(Int(ClaudeExport.modified(z).timeIntervalSince1970)) }

    /// Something keeps the display awake on purpose (a video playing, a call, a presentation): you're there, typing
    /// or not.
    nonisolated static func screenKeptOn() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess, let d = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (d[kIOPMAssertionTypePreventUserIdleDisplaySleep] ?? 0) > 0
    }

    nonisolated static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    func export(_ list: [Item], memory: Bool, zip: URL?, force: Bool, scheduled: Bool) {
        guard !busy else { return }
        // when the run began (a scheduled one: just after tick() saw 10 minutes without input), so any input from here
        // on is yours, while the zip is read too, before Claude's window is touched
        let began = Date()
        // (the folder can't change while a run is under way: Export says one is, before anything is saved)
        let root = Archive.folder
        // an external or network disk that isn't connected, a full disk, or macOS saying no: nothing is asked of Claude
        // (and it's tried again later)
        if let why = Archive.unreachable(root) {
            Archive.lastResult = Clock.format(Date(), "M/d HH:mm", "MMM d HH:mm") + " · " + why.title
            log("\(Clock.iso()) not run · the folder can't be reached: \(root.path)")
            if !scheduled { Archive.say(why.title, why.text) }
            onChange?()
            return
        }
        let p = pid()
        let canDrive = self.canDrive
        if memory && !canDrive && zip == nil {
            Archive.say(tr("没法写总结", "Can't write summaries"),
                        tr("要先打开 Claude App，并开启「辅助功能」权限。", "Open the Claude app and turn on Accessibility first."))
            return
        }
        busy = true
        // (only the files, from Claude's export zip: Claude's window isn't touched, and the top bar says so)
        summarizing = memory && canDrive
        stop.set(false)
        progress = ""
        onChange?()
        // (a chat whose new folder another chat still has things in: nothing is written there this time)
        let blocked = Set(follow(list).map(\.id))
        // a chat known by its title alone that another Claude chat shares: which sidebar row or zip entry it is can't be
        // told, so nothing is written for it until its address is known
        let twins = Set(Dictionary(grouping: store.chats.filter { !$0.outsideClaude }, by: \.title).filter { $0.value.count > 1 }.keys)
        let ambiguous = Set(list.filter { !$0.outsideClaude && !Archive.isAddress($0.id) && twins.contains($0.title) }.map(\.id))
        // decided up front, on the main thread
        let skip = Set(list.filter { !force && (store.isRunning($0.id) || store.chat($0.id).map(store.isUnread) == true) }.map { $0.id })
        let counts = state.summaries.mapValues { $0.messages }
        let updated = Dictionary(uniqueKeysWithValues: list.map { ($0.id, store.chat($0.id)?.updated_at ?? "") })
        let done = state.summaries.mapValues { $0.date }
        let prompt = Archive.summaryPrompt
        let stop = self.stop
        let idle = self.idle, standIn = askSummary
        // the summaries are pasted and copied through the clipboard: a quit puts what you had copied back
        let clip = memory && canDrive ? RunClipboard(board()) : nil
        clipboard = clip
        let make = driver
        log("\(Clock.iso()) export · \(list.count) chats · memory \(memory) · zip \(zip?.lastPathComponent ?? "-")\(scheduled ? " · scheduled" : "")")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func say(_ s: String) { DispatchQueue.main.async { MainActor.assumeIsolated { self?.progress = s; self?.onChange?() } } }
            // (chats by id: their titles, and folders named after them, stay out of the log)
            func log(_ s: String) { DispatchQueue.main.async { MainActor.assumeIsolated { self?.log(s) } } }
            var r = Report()
            // summaries asked for, but Claude can't be worked now (closed, or Accessibility off): said in the result
            r.noClaude = memory && !canDrive
            /// Why the export folder can't take files anymore (its disk full, unplugged or read-only, macOS saying no),
            /// after something couldn't be saved; nil: it still can, and that was the chat's own (a name the disk refuses).
            func cantSave() -> (title: String, text: String)? {
                DispatchQueue.main.sync { MainActor.assumeIsolated { Archive.unreachable(root) } }
            }
            // 1. prompts, conversation and artifacts from Claude's export
            if let z = zip {
                say(tr("正在读 Claude 的导出包…", "Reading Claude's data export…"))
                let loaded = ClaudeExport.load(z)
                if let all = loaded, all.claude {
                    r.zipRead = true
                    // (a name two chats in the zip share matches neither)
                    let byName = Dictionary(grouping: all.chats.values, by: \.name).compactMapValues { $0.count == 1 ? $0[0] : nil }
                    // (those not written are tried again from this zip later)
                    var wrote: [Item] = [], missed: [Item] = []
                    let todo = list.filter { !$0.outsideClaude }
                    for (n, it) in todo.enumerated() {
                        // Stopped: what's written stays; the rest waits for the next export that reads this zip
                        if stop.isSet { break }
                        if blocked.contains(it.id) {
                            r.blocked.insert(it.id); missed.append(it)
                            log("  \(it.id): " + tr("文件夹里还有另一个同名对话的东西，这次没写", "its folder still holds another chat's things (same name): not written this time"))
                            continue
                        }
                        if ambiguous.contains(it.id) {
                            r.ambiguous.insert(it.id); missed.append(it)
                            log("  \(it.id): " + tr("和别的对话同名，地址还不知道：没写", "same name as another chat, address unknown: not written"))
                            continue
                        }
                        // by address; by name only for a chat known by its title alone (another may share it)
                        guard let c = all.chats[it.id.lowercased()] ?? (Archive.isAddress(it.id) ? nil : byName[it.title]) else { r.notInZip += 1; continue }
                        do { try ClaudeExport.write(c, title: it.title, to: it.dir); r.files += 1; r.artifacts += c.artifacts.count; wrote.append(it) }
                        catch {
                            r.filesFailed += 1; missed.append(it); log("  \(it.id): " + tr("文件没写成：", "files not written: ") + Archive.reason(error))
                            // the folder can't take files anymore: the rest would fail the same way (they're tried again
                            // from this zip later), and no summary could be saved either
                            if let why = cantSave() {
                                r.halted = why
                                missed += todo[(n + 1)...]
                                log(tr("  导出文件夹存不进文件了，停下：", "  the export folder can't take files anymore, stopped: ") + why.title)
                                break
                            }
                        }
                    }
                    let written = wrote, left = missed
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.markZip(z, wrote: written, missed: left) } }
                } else {
                    // another app's export (ChatGPT's has a conversations.json too): not used, and not taken as read; nor
                    // one that can't be read. Either way it isn't read again by itself every few minutes
                    if loaded != nil { r.notClaude = true; log(tr("  不是 Claude 的导出包：", "  not Claude's export: ") + z.lastPathComponent) }
                    else { r.zipFailed = true; log(tr("  导出包读不了：", "  can't read the export: ") + z.path) }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.markUnreadable(z) } }
                }
                // (it may have taken a minute: a disk unplugged meanwhile is found before Claude is asked anything)
                if memory && canDrive && r.halted == nil && !stop.isSet, let why = cantSave() { r.halted = why }
            }
            // stopped while the zip was read: the summaries aren't started (that's this time's run, as a stop among them is)
            if memory && canDrive && r.halted == nil && stop.isSet { r.summariesRan = !force }
            // 2. the hand-off summaries, written by Claude in each chat
            summaries: if memory && canDrive && r.halted == nil && !stop.isSet, let clip {
                let d = make(p, stop, log, began, clip)
                // a scheduled run goes while you're away: once you're back (any input since it began) it works Claude's
                // window no more
                d.whileAway = scheduled
                d.idle = idle
                // back already, while the zip was read, say: Claude's window and the clipboard aren't touched at all
                if d.youCameBack() { r.cutShort = true; break summaries }
                let back = d.pageTitle(), backID = d.chatID()
                let todo = list.filter { !$0.outsideClaude }
                var misses = 0
                // a run over the chosen topics restarts the schedule; one chat archived by right-click leaves it as it was
                r.summariesRan = !force
                chats: for (n, it) in todo.enumerated() {
                    if stop.isSet || d.youCameBack() { r.cutShort = !stop.isSet; break }
                    if skip.contains(it.id) { r.skipped += 1; continue }
                    // its folder still holds another chat's things: a summary couldn't be saved there, so none is asked
                    if blocked.contains(it.id) { r.blocked.insert(it.id); log("  \(it.id): " + tr("文件夹里还有另一个同名对话的东西，这次跳过", "its folder still holds another chat's things (same name): skipped this time")); continue }
                    if ambiguous.contains(it.id) { r.ambiguous.insert(it.id); log("  \(it.id): " + tr("和别的对话同名，地址还不知道：跳过", "same name as another chat, address unknown: skipped")); continue }
                    // nothing new since the last summary (the app saw no activity)
                    if !force, let when = done[it.id], let u = updated[it.id], !u.isEmpty, u <= when {
                        DispatchQueue.main.sync { MainActor.assumeIsolated { self?.bringSummary(it) } }
                        r.skipped += 1; continue
                    }
                    say("\(n + 1)/\(todo.count) · \(it.title)")
                    log("— \(it.id)")
                    switch standIn?(it) ?? d.summarize(id: it.id, title: it.title, prompt: prompt, lastCount: force ? nil : counts[it.id]) {
                    case .done(let text, let count):
                        misses = 0
                        let ok = DispatchQueue.main.sync { MainActor.assumeIsolated { self?.saveMemory(it, text: text, messages: count) ?? false } }
                        if ok { r.memory += 1 } else {
                            r.failed += 1
                            // the folder can't take files anymore (its disk full or unplugged, say): each chat left would
                            // get one more exchange with Claude, and quota used, for a reply that couldn't be saved
                            if let why = cantSave() {
                                r.halted = why
                                log(tr("  导出文件夹存不进文件了，总结停下：", "  the export folder can't take files anymore, summaries stopped: ") + why.title)
                                break chats
                            }
                        }
                    case .unchanged:
                        misses = 0; r.skipped += 1; log(tr("  没有新内容，跳过", "  nothing new, skipped"))
                        DispatchQueue.main.sync { MainActor.assumeIsolated { self?.bringSummary(it) } }
                    case .failed(let why): misses = 0; r.failed += 1; log(tr("  失败：", "  failed: ") + why)
                    case .unreadable(let why):
                        r.failed += 1; log(tr("  失败：", "  failed: ") + why)
                        // twice in a row: it's Claude's page, not this chat; the rest would only fail the same way
                        misses += 1
                        if misses >= 2 { r.unreadable = true; break chats }
                    case .away:
                        // nothing was sent there: it's done when the Mac is idle again
                        r.cutShort = true; break chats
                    case .unsent:
                        // stopped between pasting the request and sending it: it may be left in that chat's message box
                        // (said in the result, by name; not in the log)
                        r.unsent = it.title
                        log(tr("  停在发送前：可能留在了输入框里", "  stopped before sending: may be left in the message box"))
                    }
                }
                if !stop.isSet { if let b = backID { _ = d.open(id: b, title: back) } else if !back.isEmpty { _ = d.open(title: back) } }
                // (what you had copied is back after each paste and each copy already; this is for one that didn't land,
                // read by Claude first if it was sent a moment ago)
                clip.close()
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(r, list: list, scheduled: scheduled) } }
        }
    }

    private struct Report {
        /// Why the run stopped part-way: the export folder couldn't take files anymore (its disk full, unplugged or
        /// read-only, macOS saying no). The schedule stays as it was: the next run starts once the folder takes files.
        var halted: (title: String, text: String)?
        var files = 0, artifacts = 0, notInZip = 0, memory = 0, skipped = 0, failed = 0
        /// Chats whose files couldn't be written from the zip (a full disk, a name the disk refuses).
        var filesFailed = 0
        /// Chats whose folder still holds another chat's things (counted once, files and summary alike).
        var blocked = Set<String>()
        /// Chats known by title alone whose title another chat shares: skipped (which one is meant can't be told).
        var ambiguous = Set<String>()
        var zipFailed = false, unreadable = false, summariesRan = false
        /// The zip is another app's export, not Claude's.
        var notClaude = false
        /// Summaries were asked for, but Claude couldn't be worked (closed, or Accessibility off).
        var noClaude = false
        /// A scheduled run that stopped because you came back: it carries on when the Mac is idle again.
        var cutShort = false
        /// Stopped between pasting the request for a summary and sending it: that chat's title (the request may be left
        /// in its message box).
        var unsent: String?
        /// Claude's export zip was read (its chats' files written, or tried).
        var zipRead = false
    }

    private func markZip(_ z: URL, wrote: [Item], missed: [Item]) {
        // runs in a row from this zip that left some chats unwritten (each retry waits twice as long as the one before)
        state.zipTries = missed.isEmpty ? 0 : (state.zipDone == zipKey(z) ? state.zipTries : 0) + 1
        state.zipDone = zipKey(z)
        state.zipDoneAt = max(state.zipDoneAt ?? 0, ClaudeExport.modified(z).timeIntervalSince1970)
        state.zipMissed = missed.map { current($0).id }
        state.zipTriedAt = Date().timeIntervalSince1970
        if state.zipUnreadable == zipKey(z) { state.zipUnreadable = nil }
        for it in wrote.map(current) { state.files[it.id] = it.dir.path }
        saveState()
    }

    /// A zip that couldn't be read, or isn't Claude's export: not read again by itself (see fromZip).
    private func markUnreadable(_ z: URL) {
        state.zipUnreadable = zipKey(z)
        saveState()
    }

    private func relative(_ url: URL) -> String { String(url.path.dropFirst(Archive.folder.path.count + 1)) }

    /// Each chat's folder follows the chat (filed under another topic since, a topic renamed, another export folder):
    /// first those whose new folder is free, then those that waited for another chat to move out of it (two chats of
    /// one name that swapped places).
    @discardableResult
    private func follow(_ list: [Item]) -> [Item] {
        // a summary or files recorded under a chat's title-only id that no chat has any more (it got its address since,
        // in this run or an older KIKUmap): they're this chat's
        for it in list where Archive.isAddress(it.id) {
            let n = "n-" + Store.fnv(it.title)
            if state.summaries[n] != nil || state.files[n] != nil, store.chat(n) == nil { moved(n, to: it.id) }
        }
        var waiting = list
        for _ in 0..<3 where !waiting.isEmpty { waiting = waiting.filter { !follow($0) } }
        return waiting
    }

    /// Ids that changed (old → new), so a run's item made before the change is saved under the id it has now.
    private var movedIDs: [String: String] = [:]

    /// The item as it stands now (its chat may have got its address since the run began).
    private func current(_ it: Item) -> Item {
        // (not once a new chat has that id again: a new chat known by the same title alone)
        var id = it.id, hops = 0
        while let n = movedIDs[id], store.chat(id) == nil, hops < 8 { id = n; hops += 1 }
        return id == it.id ? it : Item(id: id, title: it.title, dir: it.dir, outsideClaude: it.outsideClaude)
    }

    /// A chat's id changed (its address became known): what's recorded of it goes along, and its summary's id line
    /// too, so the summary is still known as this chat's.
    func moved(_ old: String, to new: String) {
        guard old != new else { return }
        movedIDs[old] = new
        var changed = false
        if let v = state.imported.removeValue(forKey: old) { state.imported[new] = v; changed = true }
        if let r = state.summaries.removeValue(forKey: old) {
            if state.summaries[new] == nil { state.summaries[new] = r }
            Archive.retag(Archive.folder.appendingPathComponent(r.file), from: old, to: new)
            changed = true
        }
        if let f = state.files.removeValue(forKey: old) { if state.files[new] == nil { state.files[new] = f }; changed = true }
        if let i = state.zipMissed.firstIndex(of: old) { state.zipMissed[i] = new; changed = true }
        for (k, v) in state.imported where v == old { state.imported[k] = new; changed = true }
        if changed { saveState() }
    }

    /// The `id:` line of a summary, from one id to another.
    nonisolated static func retag(_ memory: URL, from old: String, to new: String) {
        guard var s = try? String(contentsOf: memory, encoding: .utf8), s.hasPrefix("---\n"), let end = s.range(of: "\n---\n"),
              let r = s.range(of: "\nid: \(old)\n", range: s.startIndex..<end.upperBound) else { return }
        s.replaceSubrange(r, with: "\nid: \(new)\n")
        let url = memory
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Everything of the chat's in the folder it was last put in, its summary and Claude's export files, goes to its
    /// folder now, together (Import reads the files beside memory.md). Within the export folder it's moved; from the
    /// one used before, copied (that one is left as it was). Never into a folder another chat still has things in:
    /// false, it waits.
    private func follow(_ it: Item) -> Bool {
        let fm = FileManager.default, root = Archive.folder
        // its own summary from when it had only a title-only id (with no record of it, a folder copied here, say)
        let own = "n-" + Store.fnv(it.title), here = it.dir.appendingPathComponent("memory.md")
        if Archive.isAddress(it.id), Archive.summaryID(here) == own, store.chat(own) == nil { Archive.retag(here, from: own, to: it.id) }
        func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased() }
        // where its things are: its summary (a copy with its id in it), and the files Claude's export put there
        var from: [URL] = []
        if let rec = state.summaries[it.id], let f = [root, Archive.previousFolder].compactMap({ $0?.appendingPathComponent(rec.file) })
            .first(where: { Archive.summaryID($0) == it.id }) { from.append(f.deletingLastPathComponent()) }
        if let f = state.files[it.id] { from.append(URL(fileURLWithPath: f)) }
        let away = from.filter { !same($0, it.dir) && fm.fileExists(atPath: $0.path) }
        if taken(it.dir, by: it.id) { return false }
        guard !away.isEmpty else { return true }
        let mine = it.dir.appendingPathComponent("memory.md")
        for src in away {
            let inside = src.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
            let memory = src.appendingPathComponent("memory.md")
            if Archive.summaryID(memory) == it.id && !fm.fileExists(atPath: mine.path) {
                try? fm.createDirectory(at: it.dir, withIntermediateDirectories: true)
                if inside { try? fm.moveItem(at: memory, to: mine) } else { try? fm.copyItem(at: memory, to: mine) }
            }
            Archive.bringRest(from: src, to: it.dir, copy: !inside)
        }
        if Archive.summaryID(mine) == it.id { state.summaries[it.id]?.file = relative(mine) }
        if Archive.hasRest(it.dir) { state.files[it.id] = it.dir.path }
        saveState()
        log("  \(it.id): " + tr("文件夹跟过去了", "its folder followed it"))
        return true
    }

    /// Another chat's things are still in this folder (two chats of one name that swapped places): its summary, or
    /// export files recorded as its.
    private func taken(_ dir: URL, by id: String) -> Bool {
        if let other = Archive.summaryID(dir.appendingPathComponent("memory.md")), other != id { return true }
        let p = dir.standardizedFileURL.path.lowercased()
        return Archive.hasRest(dir) && state.files.contains { $0.key != id && URL(fileURLWithPath: $0.value).standardizedFileURL.path.lowercased() == p }
    }

    /// Whose summary this is: the id in its front matter (nil: not one of KIKUmap's, or not there).
    nonisolated static func summaryID(_ memory: URL) -> String? {
        guard let s = try? String(contentsOf: memory, encoding: .utf8), s.hasPrefix("---\n"), let end = s.range(of: "\n---\n") else { return nil }
        return s[..<end.lowerBound].split(separator: "\n").first { $0.hasPrefix("id: ") }.map { String($0.dropFirst(4)) }
    }

    private func finish(_ r: Report, list: [Item], scheduled: Bool) {
        busy = false
        summarizing = false
        progress = ""
        clipboard = nil
        // (a run that only read Claude's export zip, was cut short, or stopped as the folder couldn't take files anymore
        // leaves the summaries' schedule as it was)
        if !r.cutShort && r.summariesRan && r.halted == nil { Archive.lastRun = Date() }
        var parts: [String] = []
        // (English: "1 chat", "2 chats")
        func n(_ k: Int, _ one: String, _ many: String) -> String { L10n.count(k, one, many) }
        if r.files > 0 { parts.append(tr("\(r.files) 个对话的提示词和全文，\(r.artifacts) 个 artifact", "prompts and full text of \(n(r.files, "chat", "chats")), \(n(r.artifacts, "artifact", "artifacts"))")) }
        if r.filesFailed > 0 { parts.append(tr("\(r.filesFailed) 个对话的文件没写成（看 logs/archive.log）", "files of \(n(r.filesFailed, "chat", "chats")) couldn't be saved (see logs/archive.log)")) }
        if r.memory > 0 { parts.append(tr("\(r.memory) 份总结", TrKey(n(r.memory, "summary", "summaries")))) }
        if r.noClaude { parts.append(tr("总结没写：Claude App 没打开，或「辅助功能」关着", "summaries not written: the Claude app isn't open, or Accessibility is off")) }
        if r.skipped > 0 { parts.append(tr("\(r.skipped) 个跳过（没变化、未读或在跑）", "\(r.skipped) skipped (unchanged, unread or running)")) }
        if !r.blocked.isEmpty { parts.append(tr("\(r.blocked.count) 个没写（文件夹里还有另一个同名对话的东西）", "\(r.blocked.count) not written (their folder still holds another chat's things)")) }
        if !r.ambiguous.isEmpty { parts.append(tr("\(r.ambiguous.count) 个和别的对话同名，跳过了：在 Claude 里各打开一次，再导出一次", "skipped \(n(r.ambiguous.count, "chat", "chats")) sharing a name with another: open each once in Claude, then export again")) }
        // (the last retry from this zip still left them: as they aren't tried on their own again, that's said too)
        if r.zipRead && (r.filesFailed > 0 || !r.blocked.isEmpty) && state.zipTries > Archive.zipRetries {
            parts.append(tr("这些不再单独重试；下次导出或有新的导出包时再试", "these aren't retried on their own any more: the next export, or a new export zip, tries them again"))
        }
        if r.notInZip > 0 { parts.append(tr("\(r.notInZip) 个不在导出包里（导出包比对话旧？）", "\(r.notInZip) not in the export zip (is the zip older than the chat?)")) }
        if r.failed > 0 { parts.append(tr("\(r.failed) 个失败（看 logs/archive.log）", "\(r.failed) failed (see logs/archive.log)")) }
        if r.zipFailed { parts.append(tr("导出包读不了（不会自己再试；点「导出」再试，或下载新的导出包）", "couldn't read the export zip (it isn't tried again by itself: click Export to try again, or download a new export)")) }
        if r.notClaude { parts.append(tr("这个 zip 不是 Claude 的官方导出包，没用它", "that zip isn't Claude's data export, so it wasn't used")) }
        if r.unreadable { parts.append(tr("认不出 Claude 的对话页面，已停下（Claude 更新了？）", "stopped: Claude's chat page couldn't be read (was Claude updated?)")) }
        if let h = r.halted { parts.append(tr(h.title + "，已停下", "stopped: \(Prefs.lang == .en ? h.title.prefix(1).lowercased() + h.title.dropFirst() : h.title)")) }
        if r.cutShort { parts.append(tr("你回来了，先停下；Mac 再空闲时接着做", "paused as you came back; it goes on when the Mac is idle again")) }
        if stop.isSet { parts.append(tr("中途停止", "stopped")) }
        let s = Clock.format(Date(), "M/d HH:mm", "MMM d HH:mm") + " · " + (parts.isEmpty ? tr("没有要更新的", "nothing to update") : parts.joined(separator: " · "))
        // (a request left in a chat's message box: said to you by the chat's name, which stays out of the log)
        Archive.lastResult = s + (r.unsent.map { " · " + tr("「\($0)」的输入框里可能还留着没发出的总结请求，在 Claude 里清掉它",
                                                         "the request for a summary may still be in the message box of \"\($0)\", unsent: clear it in Claude") } ?? "")
        log("\(Clock.iso()) end · \(s)")
        writeIndex(list)
        onChange?()
        // (one you started: said, with what to do; a scheduled one says it in its result)
        if let h = r.halted, !scheduled {
            Archive.say(h.title, h.text + "\n\n" + tr("导出到这里停下了，剩下的这次没有做。", "The export stopped there: what was left wasn't done this time."))
        }
    }

    // MARK: files

    /// A chat unchanged since its summary whose folder moved (another topic, another export folder): its memory.md
    /// is copied there from where it was, rather than asked of Claude again.
    private func bringSummary(_ given: Item) {
        let it = current(given)
        guard let rec = state.summaries[it.id] else { return }
        let fm = FileManager.default, root = Archive.folder, to = it.dir.appendingPathComponent("memory.md")
        guard !fm.fileExists(atPath: to.path),
              let from = [root, Archive.previousFolder].compactMap({ $0?.appendingPathComponent(rec.file) }).first(where: { Archive.summaryID($0) == it.id }),
              !taken(it.dir, by: it.id)
        else { return }
        do {
            try fm.createDirectory(at: it.dir, withIntermediateDirectories: true)
            // from the folder used before: copied, that one is left as it was. Moved within this folder (another
            // topic): the chat's whole folder goes along (its artifacts too, which Import reads beside memory.md),
            // one copy only, or Import would start it twice
            let fromPrevious = Archive.previousFolder.map { from.path.hasPrefix($0.path + "/") } ?? false
            if fromPrevious || !from.path.hasPrefix(root.path + "/") {
                try fm.copyItem(at: from, to: to)
                Archive.bringRest(from: from.deletingLastPathComponent(), to: it.dir, copy: true)
            } else {
                try fm.moveItem(at: from, to: to)
                Archive.bringRest(from: from.deletingLastPathComponent(), to: it.dir)
            }
            state.summaries[it.id]?.file = String(to.path.dropFirst(root.path.count + 1))
            if Archive.hasRest(it.dir) { state.files[it.id] = it.dir.path }
            saveState()
            log("  \(it.id): " + tr("总结已带到它现在的文件夹", "summary brought along to its folder now"))
        } catch {
            log("  \(it.id): " + tr("总结没能带过去：", "couldn't bring its summary along: ") + Archive.reason(error))
        }
    }

    /// A chat's own files besides memory.md (Claude's export: its prompts, the conversation, artifacts and attachments,
    /// which Import reads beside memory.md), moved from where the chat was filed to where it is now; the old folder goes
    /// if that leaves it empty. Only these: a topic's folder inside it, with other chats, stays where it is. With
    /// `copy` (from the export folder used before) they're copied, and that folder is left as it was.
    nonisolated static let rest = ["prompts.md", "conversation.md", "artifacts", "attachments"]
    nonisolated static func hasRest(_ dir: URL) -> Bool { rest.contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) } }

    nonisolated static func bringRest(from old: URL, to new: URL, copy: Bool = false) {
        let fm = FileManager.default
        guard old.standardizedFileURL.path.lowercased() != new.standardizedFileURL.path.lowercased() else { return }
        for name in rest
        where fm.fileExists(atPath: old.appendingPathComponent(name).path) && !fm.fileExists(atPath: new.appendingPathComponent(name).path) {
            try? fm.createDirectory(at: new, withIntermediateDirectories: true)
            if copy { try? fm.copyItem(at: old.appendingPathComponent(name), to: new.appendingPathComponent(name)) }
            else { try? fm.moveItem(at: old.appendingPathComponent(name), to: new.appendingPathComponent(name)) }
        }
        if !copy, ((try? fm.contentsOfDirectory(atPath: old.path)) ?? ["?"]).filter({ $0 != ".DS_Store" }).isEmpty { try? fm.removeItem(at: old) }
    }

    private func saveMemory(_ given: Item, text: String, messages: Int) -> Bool {
        let it = current(given)
        let path = store.map.topicPath(ofChat: it.id).joined(separator: " / ")
        let tags = store.map.tags(of: "c:" + it.id).map { $0.name }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var head = "---\n"
        head += "title: \(q(it.title))\n"
        head += "id: \(it.id)\n"
        if let p = store.chat(it.id)?.path, !p.isEmpty { head += "chat: https://claude.ai\(p)\n" }
        if !path.isEmpty { head += "topic: \(q(path))\n" }
        if !tags.isEmpty { head += "tags: [\(tags.map(q).joined(separator: ", "))]\n" }
        head += "summarized: \(Clock.iso())\n"
        head += "---\n\n"
        let url = it.dir.appendingPathComponent("memory.md")
        // another chat's summary is still in this folder (two chats of one name): it isn't written over
        if let other = Archive.summaryID(url), other != it.id {
            log("  \(it.id): " + tr("这个文件夹里还是另一个同名对话的总结，没写", "this folder still holds another chat's summary (same name), not written"))
            return false
        }
        do {
            try FileManager.default.createDirectory(at: it.dir, withIntermediateDirectories: true)
            try (head + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log("  \(it.id): " + tr("写文件失败：", "couldn't write the file: ") + Archive.reason(error))
            return false
        }
        let rel = String(url.path.dropFirst(Archive.folder.path.count + 1))
        // its summary was somewhere else in this folder (the chat moved since): that one goes, so there's one per chat
        if let old = state.summaries[it.id]?.file, old.lowercased() != rel.lowercased() {      // (a Mac's disk ignores case)
            let o = Archive.folder.appendingPathComponent(old)
            if let s = try? String(contentsOf: o, encoding: .utf8), s.hasPrefix("---\n"), s.contains("\nid: \(it.id)\n") {
                try? FileManager.default.removeItem(at: o)
                Archive.bringRest(from: o.deletingLastPathComponent(), to: it.dir)
            }
        }
        state.summaries[it.id] = Record(date: Clock.iso(), messages: messages, file: rel)
        if Archive.hasRest(it.dir) { state.files[it.id] = it.dir.path }
        saveState()
        log("  \(it.id): " + tr("已存 memory.md", "memory.md saved"))
        return true
    }

    /// 索引.md / Index.md: every exported chat by topic, with what its folder holds.
    private func writeIndex(_ list: [Item]) {
        let root = Archive.folder
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let all = items(topics: nil, unplaced: true).filter { fm.fileExists(atPath: $0.dir.path) }
        guard !all.isEmpty else { return }
        var s = "# " + tr("Claude 导出", "Claude Export") + "\n\n"
        s += tr("更新于 ", "Updated ") + Clock.format(Date(), "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm")
        s += tr(" · \(all.count) 个对话", all.count == 1 ? " · 1 chat" : " · \(all.count) chats") + "\n"
        var group = ""
        for it in all {
            let rel = String(it.dir.path.dropFirst(root.path.count + 1))
            let g = (rel as NSString).deletingLastPathComponent
            if g != group { group = g; s += "\n## " + (g.isEmpty ? "—" : g.replacingOccurrences(of: "/", with: " / ")) + "\n\n" }
            var has: [String] = []
            if fm.fileExists(atPath: it.dir.appendingPathComponent("memory.md").path) { has.append("memory") }
            if fm.fileExists(atPath: it.dir.appendingPathComponent("prompts.md").path) { has.append(tr("提示词", "prompts")) }
            let arts = (try? fm.contentsOfDirectory(atPath: it.dir.appendingPathComponent("artifacts").path))?.count ?? 0
            if arts > 0 { has.append(tr("\(arts) 个 artifact", arts == 1 ? "1 artifact" : "\(arts) artifacts")) }
            s += "- [\(store.name(it.id))](<\(rel)/>) · " + has.joined(separator: " · ") + "\n"
        }
        // only an index KIKUmap wrote is written over: someone's own Index.md in that folder stays
        let mark = "<!-- kikumap-index -->\n"
        func ours(_ url: URL, _ test: (Data) -> Bool) -> Bool {
            guard let d = fm.contents(atPath: url.path) else { return !fm.fileExists(atPath: url.path) }
            return test(d)
        }
        let index = root.appendingPathComponent(Archive.named("索引.md", "Index.md", in: root))
        let isIndex: (Data) -> Bool = { d in
            let t = String(decoding: d.prefix(200), as: UTF8.self)
            return t.hasPrefix(mark) || t.hasPrefix("# Claude Export\n\nUpdated ") || t.hasPrefix("# Claude 导出\n\n更新于 ")
        }
        let indexURL = ours(index, isIndex) ? index : root.appendingPathComponent(tr("KIKUmap 索引.md", "KIKUmap Index.md"))
        if ours(indexURL, isIndex) { try? (mark + s).write(to: indexURL, atomically: true, encoding: .utf8) }
    }

    /// Written whole (atomic), the folder made again if it went missing; a failure is logged once and shown in the
    /// To-do until a later save works.
    private func saveState() {
        guard !readOnly, let d = try? JSONEncoder().encode(state) else { return }
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: stateURL, options: .atomic)
            if saveError != nil { saveError = nil; onChange?() }
        } catch {
            let first = saveError == nil
            saveError = error.localizedDescription
            if first { store.log("\(Clock.iso()) couldn't save archive.json: \(error.localizedDescription)\n", file: "app.log"); onChange?() }
        }
    }

    /// The last save failed (a full disk, a folder that can't be written): try again, with no change needed.
    func retrySave() { if saveError != nil { saveState() } }

    private func log(_ line: String) { store.log(line + "\n", file: "archive.log") }

    /// A file error in fixed words: its own text names the file and its folder (chat and topic names), which stay out
    /// of the log.
    nonisolated static func reason(_ error: Error) -> String {
        let e = error as NSError
        let words: [Int: String] = [
            NSFileWriteOutOfSpaceError: tr("磁盘满了", "the disk is full"), NSFileWriteVolumeReadOnlyError: tr("磁盘只读", "the disk is read-only"),
            NSFileWriteNoPermissionError: tr("没有写入权限", "no permission to write there"),
            NSFileWriteInvalidFileNameError: tr("磁盘不接受这个名字", "a name the disk refuses"),
            NSFileWriteFileExistsError: tr("那里已经有别的东西", "something else is in the way"),
            NSFileNoSuchFileError: tr("文件夹不在了", "the folder isn't there"),
        ]
        let said: String = e.domain == NSCocoaErrorDomain ? words[e.code].map { $0 + " · " } ?? "" : ""
        let under: String = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { " · \($0.domain) \($0.code)" } ?? ""
        return said + "\(e.domain) \(e.code)" + under
    }

    static var summaryPrompt: String {
        tr("""
        【对话存档】请把这个对话到目前为止的内容整理成一份交接总结，用 Markdown 写。以后我会把它放进一个新对话里接着做，新的 Claude 只能看到这份总结（和附上的 artifact 文件）。只写总结本身，不要调用工具，不要改任何文件。

        包括：
        1. 目标：这个对话要做成什么
        2. 现在的进度和状态
        3. 已经做出的关键决定，以及理由
        4. 重要的事实、数字、名字、链接
        5. 产出的文件和 artifact：每个的名字、用途、最新版本是哪个
        6. 还没做完的事，和下一步
        7. 我的偏好和要求（语气、格式、限制）

        写得紧凑，让新的 Claude 只看这份总结就能无缝接着做。
        """, """
        [Chat archive] Please write a hand-off summary of this conversation so far, in Markdown. I'll paste it into a new chat to carry on, and the new Claude will only see this summary (and the artifact files attached). Write just the summary — don't use tools or change any files.

        Include:
        1. Goal: what this conversation is trying to get done
        2. Where things stand now
        3. Key decisions made, and why
        4. Important facts, numbers, names, links
        5. Files and artifacts produced: each one's name, purpose, and which version is the latest
        6. What's left, and the next step
        7. My preferences and requirements (tone, format, constraints)

        Keep it tight, so a new Claude can pick up seamlessly from this summary alone.
        """)
    }

    // MARK: import

    struct Note { let url: URL; let id: String; let title: String; let body: String; let files: [URL]; var left = 0 }

    /// An id of the shape KIKUmap gives Claude's chats: an address, or a title-only "n-…" one.
    nonisolated static func isChatID(_ id: String) -> Bool { isAddress(id) || id.range(of: "^n-[0-9a-f]{8}$", options: .regularExpression) != nil }

    /// A file among a chat's own files from Claude's export, its artifacts or attachments (a Markdown artifact may have
    /// front matter of its own, a Docusaurus page's or a note's): never a summary. Looked for from the file up to `root`,
    /// the folder picked (itself a chat's artifacts folder, maybe). A topic that happens to be called "artifacts" holds
    /// chats' folders, not a chat's files.
    nonisolated static func inChatFiles(_ url: URL, under root: URL) -> Bool {
        let fm = FileManager.default, top = root.resolvingSymlinksInPath().path
        let inside = top.hasSuffix("/") ? top : top + "/"
        var dir = url.deletingLastPathComponent().resolvingSymlinksInPath()
        while dir.path == top || dir.path.hasPrefix(inside) {
            let parent = dir.deletingLastPathComponent()
            if ["artifacts", "attachments"].contains(dir.lastPathComponent),
               ["memory.md", "prompts.md", "conversation.md"].contains(where: { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }) { return true }
            if dir.path == top { break }
            dir = parent
        }
        return false
    }

    /// The summaries under a folder: memory.md files, or the single .md files older versions wrote in their place, each
    /// with the artifacts next to it. Only KIKUmap's own: front matter with a chat's id of KIKUmap's shape, a title and
    /// when it was summarized, and not among a chat's artifacts or attachments.
    nonisolated static func notes(in folder: URL) -> [Note] {
        let fm = FileManager.default
        let all = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let found = all.filter { $0.pathExtension == "md" && !["prompts.md", "conversation.md"].contains($0.lastPathComponent) && !inChatFiles($0, under: folder) }.compactMap { url -> (note: Note, at: String)? in
            guard let s = try? String(contentsOf: url, encoding: .utf8), s.hasPrefix("---\n"),
                  let end = s.range(of: "\n---\n", range: s.index(s.startIndex, offsetBy: 4)..<s.endIndex) else { return nil }
            var id = "", title = "", at = ""
            for line in s[s.index(s.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "id" { id = parts[1] }
                if parts[0] == "summarized" { at = parts[1] }
                if parts[0] == "title" {
                    var t = parts[1]
                    if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"") }
                    title = t
                }
            }
            guard isChatID(id), !title.isEmpty, !at.isEmpty else { return nil }
            var files: [URL] = [], left = 0
            if url.lastPathComponent == "memory.md" {
                // Claude takes 20 files with a message: the summary and 19 of the chat's (under 5 MB); the rest are said
                let arts = url.deletingLastPathComponent().appendingPathComponent("artifacts")
                let all = (try? fm.contentsOfDirectory(at: arts, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
                files = all.filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 5_000_000 }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                files = Array(files.prefix(19))
                left = all.count - files.count
            }
            return (Note(url: url, id: id, title: title, body: String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), files: files, left: left), at)
        }
        // one note per chat (an older version may have left a copy where the chat was filed before): the newest
        var best: [String: (note: Note, at: String)] = [:]
        for n in found where (best[n.note.id]?.at ?? "") <= n.at { best[n.note.id] = n }
        return best.values.map(\.note).sorted { $0.title < $1.title }
    }

    func alreadyImported(_ n: Note) -> Bool { state.imported[n.id] != nil }

    /// Starts one chat in Claude for Import (a test stands in for it: there's no Claude to work here).
    var starter: (ClaudeDriver, String, [URL], String) -> ClaudeDriver.Start = { d, text, files, title in d.startChat(with: text, files: files, title: title) }
    /// What a run works Claude's window through: pid, Stop, log, when the run began, the clipboard (a test stands in for
    /// Claude's window).
    var driver: (pid_t, StopFlag, @escaping (String) -> Void, Date, RunClipboard) -> ClaudeDriver = {
        ClaudeDriver(pid: $0, stop: $1, log: $2, since: $3, clip: $4)
    }
    /// What an import tells you at its end (a test stands in for the alert).
    var tell: (String, String) -> Void = { Permissions.alert($0, $1) }
    /// The clipboard a run pastes and copies through (a test stands in for the Mac's: the checks run with none).
    var board: () -> RunBoard = { SystemBoard() }

    /// The message a chat Import starts is sent with: what the attached summary and files are, and how many of the
    /// chat's files stayed behind (`left`).
    nonisolated static func importMessage(file name: String, title: String, withFiles: Bool, left: Int) -> String {
        let rest = left <= 0 ? "" : tr("（另有 \(left) 个文件没附上，在导出文件夹里）",
                                       left == 1 ? " (1 more file wasn't attached; it's in the export folder)" : " (\(left) more files weren't attached; they're in the export folder)")
        let also = withFiles ? tr("；其他附件是那个对话里做出的文件", "; the other attachments are the files made in it") : ""
        return tr("【接续之前的对话】附件「\(name)」是我之前一个对话的交接总结（原标题：\(title)）\(also)\(rest)。请先读完，用两三句话确认你理解的目标、进度和下一步，然后等我继续。从现在起就当作是同一个对话。",
                  "[Continuing an earlier chat] The attached \(name) is the hand-off summary of a previous conversation (titled \"\(title)\")\(also)\(rest). Read it, confirm in two or three sentences the goal, where things stand and the next step, then wait for me. From now on, treat this as the same conversation.")
    }

    /// For each note: a new chat in the account that's signed in now, with the artifacts attached and
    /// the summary sent in, then pinned and given the old name. On the map it takes the old chat's place.
    func importNotes(_ notes: [Note]) {
        guard !busy, !notes.isEmpty else { return }
        let p = pid()
        guard p != 0, trusted() else {
            tell(tr("没法导入", "Can't import"), tr("要先打开 Claude App，并开启「辅助功能」权限。", "Open the Claude app and turn on Accessibility first."))
            return
        }
        busy = true
        importing = true
        stop.set(false)
        let clip = RunClipboard(board())
        clipboard = clip
        onChange?()
        let stop = self.stop, start = starter, make = driver, began = Date()
        log("\(Clock.iso()) import · \(notes.count) notes")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let d = make(p, stop, { line in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.log(line) } }
            }, began, clip)
            var done = 0
            var failed: [String] = []
            var halted: String?
            // made, but not pinned or renamed (no reply in time, stopped, Claude's menu not found): yours to finish
            var byHand: [(title: String, made: ClaudeDriver.Made)] = []
            for (n, note) in notes.enumerated() {
                if stop.isSet { break }
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self?.progress = "\(n + 1)/\(notes.count) · \(note.title)"
                    self?.onChange?()
                } }
                d.log("— \(note.id)")
                // the summary goes as a file (Claude reads it whole; pasted, a long one would become an attachment
                // anyway), the files made in that chat beside it, and a short message saying what they are
                // Claude takes at most 20 files with a message: the summary and 19 of the chat's files; the rest are said
                let files = Array(note.files.prefix(19)), left = note.left + note.files.count - files.count
                let text = Archive.importMessage(file: note.url.lastPathComponent, title: note.title, withFiles: !files.isEmpty, left: left)
                switch start(d, text, [note.url] + files, note.title) {
                case .made(let m):
                    done += 1
                    if !(m.pinned && m.renamed) { byHand.append((note.title, m)) }
                    DispatchQueue.main.sync { MainActor.assumeIsolated { self?.adopt(old: note.id, made: m, title: note.title) } }
                case .failed:
                    failed.append(note.title)
                case .leftOver:
                    // what was put in Claude's message box may still be there, unsent: the next chat would send it
                    // along (stopped: that's why, nothing failed)
                    if !stop.isSet { failed.append(note.title) }
                    halted = tr("已停下：Claude 的输入框里可能还留着「\(note.title)」的总结和文件，清空后再导入", "stopped: Claude's message box may still hold the summary and files of \"\(note.title)\"; clear it, then import again")
                case .notEmpty:
                    halted = tr("没开始：Claude 新对话的输入框里有东西（草稿？），清空后再导入", "not started: the message box of Claude's new chat isn't empty (a draft?); clear it, then import again")
                case .unconfirmed:
                    // sent, but which chat it made isn't known: not recorded, so importing it again could make it twice
                    halted = tr("已停下：「\(note.title)」已经点了发送，但没看到新对话，所以没记成已导入；重新导入前，先在 Claude 里找找它",
                                "stopped: Send was pressed for \"\(note.title)\", but its new chat wasn't seen, so it isn't recorded as imported; look for it in Claude before importing again")
                case .stopped:
                    // (nothing was put in Claude's message box: the loop ends here)
                    break
                }
                if halted != nil { break }
            }
            // (a paste sent a moment ago, before a stop, is read by Claude before what you had goes back)
            clip.close()
            let said = Archive.importResult(done: done, failed: failed.count, byHand: byHand, stopped: stop.isSet, halted: halted)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self = self else { return }
                self.busy = false; self.importing = false
                self.progress = ""
                self.clipboard = nil
                // (the chats it names are said to you; the log has the step that failed, by id, above)
                self.log("\(Clock.iso()) import end · \(said.log)")
                Archive.lastResult = Clock.format(Date(), "M/d HH:mm", "MMM d HH:mm") + " · " + said.result
                self.onChange?()
                // (quitting: it's in the result, said in Settings → Export next time)
                if let a = said.alert, !self.quitting { self.tell(a.title, a.text) }
            } }
        }
    }

    /// What an import says at its end: in the log (no chat titles), as its result, and in an alert when something needs
    /// you (something may be left in Claude's message box, a chat sent but not seen, or chats to pin or rename by hand).
    nonisolated static func importResult(done: Int, failed: Int, byHand: [(title: String, made: ClaudeDriver.Made)], stopped: Bool,
                                         halted: String?) -> (log: String, result: String, alert: (title: String, text: String)?) {
        var s = tr("导入了 \(done) 个", "\(done) imported")
        if !byHand.isEmpty { s += tr(" · \(byHand.count) 个要在 Claude 里手动置顶或改名", " · \(byHand.count) to pin or rename in Claude by hand") }
        if failed > 0 { s += tr(" · \(failed) 个失败（看 logs/archive.log）", " · \(failed) failed (see logs/archive.log)") }
        let stop = stopped ? tr(" · 中途停止", " · stopped") : ""
        let log = s + stop + (halted == nil ? "" : tr(" · 停下了", " · halted"))
        let lines = byHand.map { e -> String in
            let t = e.title, m = e.made
            let what = !m.replied ? tr("没等到回复，没置顶、没改名", "no reply yet, so not pinned or renamed")
                : !m.pinned && !m.renamed ? tr("没置顶、没改名", "not pinned or renamed") : !m.pinned ? tr("没置顶", "not pinned") : tr("没改名", "not renamed")
            // the name Claude shows it by, to find it there (none yet: Claude names a chat after its first reply)
            let shown = m.renamed || m.shown.isEmpty || m.shown == t || ClaudeWords.untitled.contains(m.shown) ? ""
                : tr("（在 Claude 里叫「\(m.shown)」）", " (in Claude as \"\(m.shown)\")")
            return tr("「\(t)」：", "\"\(t)\": ") + what + shown
        }
        // (a halt says it stopped, and why)
        let result = s + (halted.map { " · " + $0 } ?? stop) + lines.map { " · " + $0 }.joined()
        var parts: [String] = []
        if let h = halted { parts.append(h) }
        if !lines.isEmpty {
            parts.append(tr("这些对话已经在 Claude 里开好，总结也发进去了，但 KIKUmap 没能做完（Claude 没及时回复、导入被停下，或找不到 Claude 的菜单）。请在 Claude 里手动补上：",
                            "These chats were started in Claude and their summaries sent, but KIKUmap couldn't finish them (Claude didn't reply in time, the import was stopped, or Claude's menu wasn't found). Finish them in Claude by hand:")
                         + "\n\n" + lines.joined(separator: "\n"))
        }
        let alert = parts.isEmpty ? nil : (title: halted != nil ? tr("导入停下了", "Import stopped") : tr("有对话要手动置顶或改名", "Pin or rename by hand"),
                                           text: parts.joined(separator: "\n\n"))
        return (log, result, alert)
    }

    /// The new chat takes the old one's place, as Claude shows it: pinned only if pinning worked, and with the old name
    /// only if renaming did (else Claude's own, until Claude has named it).
    private func adopt(old: String, made m: ClaudeDriver.Made, title: String) {
        state.imported[old] = m.id
        if let r = state.summaries[old] { state.summaries[m.id] = r }
        saveState()
        let named = !m.renamed && !m.shown.isEmpty && !ClaudeWords.untitled.contains(m.shown)
        store.addImported(id: m.id, title: named ? m.shown : title, pinned: m.pinned)
        if store.map.placedChats().contains(old) { store.map.renameChat(old, to: m.id) }
        store.notify()
    }

    // MARK: quitting during a run

    /// The run under way pastes and copies through this (summaries, or an import): a quit puts what you had copied back.
    private(set) var clipboard: RunClipboard?
    /// KIKUmap is quitting: a run's alerts wait (its result is kept, and shown in Settings → Export).
    private(set) var quitting = false
    private var quitDone: [() -> Void] = []
    /// How long a quit waits for the run to stop by itself, before what you had copied is put back from here.
    static var quitWait: TimeInterval = 3

    /// A run that may have your clipboard (summaries, or an import): the quit waits for it.
    var holdsClipboard: Bool { busy && clipboard != nil }

    /// Quitting while a run pastes through the clipboard: it's stopped, and `done` once what you had copied is back (it
    /// puts that back itself when it ends; one stuck in a step has it put back from here after a few seconds, and pastes
    /// nothing more).
    func stopForQuit(_ done: @escaping () -> Void) {
        quitting = true
        stop.set(true)
        quitDone.append(done)
        // (asked again while it waits: one wait answers both)
        guard quitDone.count == 1 else { return }
        let until = Date().addingTimeInterval(Archive.quitWait)
        func check() {
            guard !busy || Date() >= until else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { check() } }
                return
            }
            closeClipboard()
            let all = quitDone
            quitDone = []
            all.forEach { $0() }
        }
        check()
    }

    /// What you had copied, back on the clipboard, and nothing more pasted by the run (KIKUmap is quitting).
    func closeClipboard() { clipboard?.close() }
}

/// logs/archive.log as versions up to 1.0.8 left it: they named chats in it, and the folders named after them and
/// their topics. Once, at launch, archive.log and archive.1.log keep only the lines in a shape KIKUmap writes now (ids,
/// counts and fixed words, the export folder and a zip's name); every other line goes, and a last line says how many.
enum ArchiveLog {
    static let doneKey = "ArchiveLogClean"

    static func forgetOld(in logs: URL) {
        let d = UserDefaults.standard, fm = FileManager.default
        guard !d.bool(forKey: doneKey) else { return }
        var done = true
        for f in ["archive.log", "archive.1.log"] {
            let url = logs.appendingPathComponent(f)
            guard fm.fileExists(atPath: url.path) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                // (not text: nothing in it can be told apart, so it all goes)
                if (try? fm.removeItem(at: url)) == nil { done = false }
                continue
            }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let kept = lines.filter { $0.isEmpty || clean($0) }
            guard kept.count < lines.count else { continue }
            let n = lines.count - kept.count
            let note = "\(Clock.iso()) cleanup · \(n) earlier line\(n == 1 ? "" : "s") removed (they could name chats)"
            do { try (kept + [note]).map { $0 + "\n" }.joined().write(to: url, atomically: true, encoding: .utf8) } catch { done = false }
        }
        if done { d.set(true, forKey: doneKey) }
    }

    /// A line in a shape KIKUmap writes to this log now.
    static func clean(_ line: String) -> Bool {
        let ns = line as NSString
        if lineRx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil { return true }
        // the end of a run: its result, part by part
        guard let m = endRx.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return false }
        return ns.substring(with: m.range(at: 1)).components(separatedBy: " · ").allSatisfy { p in
            partRx.firstMatch(in: p, range: NSRange(location: 0, length: (p as NSString).length)) != nil
        }
    }

    /// `§N§` a count, `§ID§` a chat's id, `§T§` when, and so on; the rest is the fixed words, in either language.
    private static func pattern(_ shapes: [String]) -> NSRegularExpression {
        let slots: [(String, String)] = [
            ("§T§", #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#),
            ("§ID§", #"(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|n-[0-9a-f]{8})"#),
            ("§N§", #"\d+"#), ("§S§", "s?"), ("§B§", "(?:true|false)"), ("§L§", "[A-Z]"),
            // the day and time a result was dated ("10/5 14:03", "Oct 5 14:03")
            ("§W§", #"(?:\d{1,2}/\d{1,2}|[A-Z][a-z]{2} \d{1,2}) \d{2}:\d{2}"#),
            // a zip's name; a zip's path; the export folder's path (none of these named after a chat)
            ("§ZIP§", #"[^/\n]+(?i:\.zip)"#), ("§ZIPPATH§", #"/[^\n]*(?i:\.zip)"#), ("§PATH§", #"/[^\n]*"#),
            // a file error in fixed words (see Archive.reason)
            ("§R§", "(?:" + alt(["the disk is full", "the disk is read-only", "no permission to write there", "a name the disk refuses",
                                 "something else is in the way", "the folder isn't there", "磁盘满了", "磁盘只读", "没有写入权限",
                                 "磁盘不接受这个名字", "那里已经有别的东西", "文件夹不在了"]) + " · )?"
                    + #"[A-Za-z][\w.]* -?\d+(?: · [A-Za-z][\w.]* -?\d+)?"#),
            // why a chat's summary wasn't written (see ClaudeDriver.summarize)
            ("§F§", alt(["couldn't open the chat", "the chat isn't available (deleted, or in another account?)", "the chat didn't load",
                         "couldn't find the messages (Claude's window changed?)", "still running: next time",
                         "there's an unsent draft in the message box: left alone", "another chat is open now", "couldn't find the message box",
                         "couldn't send", "stopped", "no reply in time", "couldn't copy the reply",
                         "打不开这个对话", "这个对话打不开了（删了，或在别的账号里？）", "对话内容没加载出来", "找不到对话内容（Claude 的界面变了？）",
                         "正在跑，下次再存", "输入框里有你还没发的草稿，没动它", "打开的已经不是这个对话", "找不到输入框", "发不出去", "停止了",
                         "等回复超时", "复制不到回复"])),
        ]
        let rx = "^(?:" + shapes.map { s -> String in
            var p = NSRegularExpression.escapedPattern(for: s)
            for (slot, sub) in slots { p = p.replacingOccurrences(of: slot, with: sub) }
            return p
        }.joined(separator: "|") + ")$"
        return try! NSRegularExpression(pattern: rx)
    }

    private static func alt(_ words: [String]) -> String { "(?:" + words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")" }

    private static let lineRx = pattern([
        "§T§ not run · the folder can't be reached: §PATH§",
        "§T§ export · §N§ chats · memory §B§ · zip -", "§T§ export · §N§ chats · memory §B§ · zip §ZIP§",
        "§T§ export · §N§ chats · memory §B§ · zip - · scheduled", "§T§ export · §N§ chats · memory §B§ · zip §ZIP§ · scheduled",
        "§T§ import · §N§ notes",
        "§T§ cleanup · §N§ earlier line§S§ removed (they could name chats)",
        "— §ID§",
        "  §ID§: its folder still holds another chat's things (same name): not written this time",
        "  §ID§: its folder still holds another chat's things (same name): skipped this time",
        "  §ID§: its folder followed it", "  §ID§: summary brought along to its folder now",
        "  §ID§: this folder still holds another chat's summary (same name), not written", "  §ID§: memory.md saved",
        "  §ID§: files not written: §R§", "  §ID§: couldn't bring its summary along: §R§", "  §ID§: couldn't write the file: §R§",
        "  §ID§: 文件夹里还有另一个同名对话的东西，这次没写", "  §ID§: 文件夹里还有另一个同名对话的东西，这次跳过", "  §ID§: 文件夹跟过去了",
        "  §ID§: 总结已带到它现在的文件夹", "  §ID§: 这个文件夹里还是另一个同名对话的总结，没写", "  §ID§: 已存 memory.md",
        "  §ID§: 文件没写成：§R§", "  §ID§: 总结没能带过去：§R§", "  §ID§: 写文件失败：§R§",
        "  nothing new, skipped", "  couldn't start a new chat", "  the new chat's box isn't empty", "  the files weren't attached",
        "  attached §N§ file§S§", "  couldn't find the message box", "  couldn't send", "  the new chat has no address",
        "  no reply in time (the chat was made: §ID§)", "  stopped before Claude replied (the chat was made: §ID§)",
        "  stopped before sending: may be left in the message box", "  couldn't pin it", "  couldn't rename it: it keeps the name Claude gave it",
        "  imported → §ID§", "  the Copy button did nothing: plain text instead", "  couldn't read the keyboard layout: ⌘§L§ not pressed",
        "  failed: §F§", "  not Claude's export: §ZIP§", "  can't read the export: §ZIPPATH§",
        "  没有新内容，跳过", "  开不了新对话", "  新对话的输入框里有东西", "  文件没附上", "  附上 §N§ 个文件", "  找不到输入框", "  发不出去",
        "  新对话没有地址", "  等回复超时（对话已建好：§ID§）", "  停下了，Claude 还没回复（对话已建好：§ID§）", "  停在发送前：可能留在了输入框里",
        "  置顶失败", "  改名失败，还是 Claude 起的名字", "  已导入 → §ID§",
        "  Copy 按钮没反应，改用纯文本", "  键盘布局读不了，没按 ⌘§L§", "  失败：§F§", "  不是 Claude 的导出包：§ZIP§", "  导出包读不了：§ZIPPATH§",
    ])
    /// A run's last line: an export's ("end · <when> · …"), an import's ("import end · …").
    private static let endRx = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z (?:import )?end · (.+)$"#)
    private static let partRx = pattern([
        "§W§", "nothing to update", "没有要更新的",
        "prompts and full text of §N§ chat§S§, §N§ artifact§S§", "§N§ 个对话的提示词和全文，§N§ 个 artifact",
        "files of §N§ chat§S§ couldn't be saved (see logs/archive.log)", "§N§ 个对话的文件没写成（看 logs/archive.log）",
        "§N§ summary", "§N§ summaries", "§N§ 份总结",
        "summaries not written: the Claude app isn't open, or Accessibility is off", "总结没写：Claude App 没打开，或「辅助功能」关着",
        "§N§ skipped (unchanged, unread or running)", "§N§ 个跳过（没变化、未读或在跑）",
        "§N§ not written (their folder still holds another chat's things)", "§N§ 个没写（文件夹里还有另一个同名对话的东西）",
        "these aren't retried on their own any more: the next export, or a new export zip, tries them again", "这些不再单独重试；下次导出或有新的导出包时再试",
        "§N§ not in the export zip (is the zip older than the chat?)", "§N§ 个不在导出包里（导出包比对话旧？）",
        "§N§ failed (see logs/archive.log)", "§N§ 个失败（看 logs/archive.log）",
        "couldn't read the export zip", "导出包读不了", "that zip isn't Claude's data export, so it wasn't used", "这个 zip 不是 Claude 的官方导出包，没用它",
        "stopped: Claude's chat page couldn't be read (was Claude updated?)", "认不出 Claude 的对话页面，已停下（Claude 更新了？）",
        "paused as you came back; it goes on when the Mac is idle again", "你回来了，先停下；Mac 再空闲时接着做",
        "stopped", "中途停止", "§N§ imported", "导入了 §N§ 个", "halted", "停下了",
        "§N§ to pin or rename in Claude by hand", "§N§ 个要在 Claude 里手动置顶或改名",
    ])
}

/// A stop button the background run can check.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ on: Bool) { lock.lock(); v = on; lock.unlock() }
}

/// Claude's own words for what the driver looks for, in each language Claude speaks (from its message catalogs).
enum ClaudeWords {
    static let messages: Set<String> = ["Chat messages", "Chat-Nachrichten", "Mensajes del chat", "Messages de la conversation", "चैट संदेश",
                                        "Pesan chat", "Messaggi della chat", "チャットメッセージ", "채팅 메시지", "Mensagens do chat"]
    /// The sidebar's new-chat buttons ("New chat", or "New" on the top row).
    static let newChat: Set<String> = ["New chat", "New", "新对话", "新聊天", "新建", "Neuer Chat", "Neu", "Chat nuevo", "Nuevo chat", "Crear",
                                       "Nuevo", "Nouvelle conversation", "Créer", "नई चैट", "नया बनाएं", "Chat baru", "Buat baru", "Nuova chat",
                                       "Nuovo", "新規チャット", "新規作成", "새 채팅", "새로 만들기", "Nova conversa", "Criar"]
    /// A new chat's title until Claude names it.
    static let untitled: Set<String> = ["Claude", "New chat", "Neuer Chat", "Nuevo chat", "Chat nuevo", "Nouvelle conversation", "नई चैट",
                                        "Chat baru", "Nuova chat", "新規チャット", "新しいチャット", "새 채팅", "Nova conversa", "Novo bate-papo"]
    static let send = ["Send", "Nachricht senden", "Enviar mensaje", "Envoyer le message", "संदेश भेजें", "Kirim pesan", "Invia messaggio",
                       "メッセージを送信", "메시지 보내기", "Enviar mensagem"]
    static let stop = ["Stop", "Antwort stoppen", "Detener respuesta", "Arrêter la réponse", "जवाब को रोकें", "Hentikan respons",
                       "Interrompi la risposta", "応答を停止", "응답 중지", "Interromper resposta"]
    static let copy: Set<String> = ["Copy", "Kopieren", "Copiar", "Copier", "कॉपी करें", "Salin", "Copia", "コピー", "복사"]
    /// The heading over your own message ("You said: …").
    static let youSaid = ["You said", "Du hast geschrieben", "Du hast gesagt", "Dijiste", "Escribiste", "Has escrito", "Has dicho",
                          "Vous avez écrit", "Vous avez dit", "आपने लिखा", "आपने कहा", "Anda menulis", "Anda berkata", "Hai scritto",
                          "Hai detto", "あなたのメッセージ", "あなたの入力", "보낸 메시지", "사용자 메시지", "입력 내용", "Você enviou", "Você disse"]
    static let pin: Set<String> = ["Pin", "Pin chat", "置顶", "Anpinnen", "Fijar", "Épingler", "पिन करें", "Sematkan", "Fissa", "ピン留め", "고정", "Fixar"]
    static let rename: Set<String> = ["Rename", "重命名", "Umbenennen", "Cambiar nombre", "Renommer", "नाम बदलें", "Ganti nama", "Rinomina",
                                      "名前を変更", "이름 변경", "Mudar o nome"]
    static let save = ["Save", "保存", "Speichern", "Guardar", "Enregistrer", "सेव करें", "Simpan", "Salva", "저장", "Salvar"]
}

/// Works the Claude app's chat page through Accessibility: open a chat, type, send, wait, copy the
/// reply. Every call blocks — run it off the main thread. Once stopped (Stop, or KIKUmap quitting) it pastes and sends
/// nothing more. (Not final: a test stands in for Claude's window.)
class ClaudeDriver: @unchecked Sendable {
    /// `unreadable`: Claude's chat page isn't one the driver knows how to read (no use trying the next chat).
    /// `away`: you came back during a run while you're away, so nothing was sent.
    /// `unsent`: stopped after the request was pasted, before it was sent: it may be left in the chat's message box.
    enum Result { case done(String, Int), unchanged, failed(String), unreadable(String), away, unsent }

    let pid: pid_t
    let stop: StopFlag
    let log: (String) -> Void
    /// What it pastes and copies through: what you had copied goes back as soon as each has landed.
    let clip: RunClipboard
    private let app: AXUIElement
    /// A run while you're away (the scheduled one): once you've touched the keyboard or mouse, it opens, brings
    /// forward and pastes nothing more.
    var whileAway = false
    /// Seconds since your last keyboard or mouse input.
    var idle: () -> Double = { Archive.idleSeconds() }
    private(set) var cameBack = false
    /// When its own last keys went (any input after that is yours); before its first, when the run began.
    private var lastStep: Date
    /// Something was pasted into the message box for the chat under way (summarize, startChat): stopped before Send, it
    /// may be left there.
    private(set) var pasted = false

    /// `since`: when the run began, so input before the driver's first step (while the zip was read) counts too.
    init(pid: pid_t, stop: StopFlag, log: @escaping (String) -> Void, since: Date = Date(), clip: RunClipboard = RunClipboard()) {
        self.pid = pid
        self.stop = stop
        self.log = log
        self.clip = clip
        lastStep = since
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3.0)
    }

    /// A run while you're away: you've touched the keyboard or mouse since its own last step (and once back, it stays
    /// so). Asked right before each step that opens a chat, brings Claude forward or pastes.
    func youCameBack() -> Bool {
        if whileAway && !cameBack && idle() < Date().timeIntervalSince(lastStep) { cameBack = true }
        return cameBack
    }

    // MARK: one chat

    func summarize(id: String, title: String, prompt: String, lastCount: Int?) -> Result {
        pasted = false
        let stopped = Result.failed(tr("停止了", "stopped"))
        guard open(id: id, title: title) else { return cameBack ? .away : stop.isSet ? stopped : .failed(tr("打不开这个对话", "couldn't open the chat")) }
        guard wait(12, { self.lastMessage() != nil }) else {
            if stop.isSet { return stopped }
            // (Claude moved on to a new chat: this one isn't there any more, or is in another account)
            if Archive.isAddress(id) && chatID() != id { return .failed(tr("这个对话打不开了（删了，或在别的账号里？）", "the chat isn't available (deleted, or in another account?)")) }
            return messagesFound() ? .failed(tr("对话内容没加载出来", "the chat didn't load"))
                                   : .unreadable(tr("找不到对话内容（Claude 的界面变了？）", "couldn't find the messages (Claude's window changed?)"))
        }
        pause(1.2)
        if busy() { return .failed(tr("正在跑，下次再存", "still running: next time")) }
        let before = messageCount()
        if let c = lastCount, c == before { return .unchanged }
        if hasDraft() { return .failed(tr("输入框里有你还没发的草稿，没动它", "there's an unsent draft in the message box: left alone")) }
        // still this chat (another may have been opened meanwhile): the message goes nowhere else
        if Archive.isAddress(id) && chatID() != id { return .failed(tr("打开的已经不是这个对话", "another chat is open now")) }
        // stopped: nothing more is pasted, nor sent (a request already pasted may stay in the box: that's said)
        guard !stop.isSet, type(prompt) else { return cameBack ? .away : stop.isSet ? (pasted ? .unsent : stopped) : .failed(tr("找不到输入框", "couldn't find the message box")) }
        guard !stop.isSet else { return .unsent }
        guard send() else { return .failed(tr("发不出去", "couldn't send")) }
        guard waitReply(after: before) else { return stop.isSet ? stopped : .failed(tr("等回复超时", "no reply in time")) }
        // still this chat (you may have opened another meanwhile): another chat's reply isn't this one's summary
        if Archive.isAddress(id) && chatID() != id { return .failed(tr("打开的已经不是这个对话", "another chat is open now")) }
        guard let text = copyLast() else { return .failed(tr("复制不到回复", "couldn't copy the reply")) }
        return .done(text, messageCount())
    }

    /// What became of a chat Import started. `leftOver`: what was put in Claude's message box may still be there, unsent;
    /// `stopped`: stopped before anything was put there; `unconfirmed`: Send was pressed, but the chat it made wasn't seen
    /// (no address), so it isn't known.
    enum Start { case made(Made), failed, leftOver, notEmpty, stopped, unconfirmed }
    /// A chat Import made (its summary sent): whether Claude replied, and whether pinning and renaming it worked;
    /// `shown`, its name in Claude's window as it was left.
    struct Made { var id: String; var replied = false; var pinned = false; var renamed = false; var shown = "" }

    /// A new chat whose first message is `text`, with `files` attached; once Claude has replied, pinned and renamed to
    /// `title`. Stopped (Stop, or KIKUmap quitting), it pastes and sends nothing more: what's in the box stays there
    /// (said), and a chat already sent is still read for its address (so it's recorded), but left to pin and rename by hand.
    func startChat(with text: String, files: [URL], title: String) -> Start {
        pasted = false
        // stopped before Send: anything pasted may be left in the box (said), else nothing was put there
        func halt() -> Start {
            guard pasted else { return .stopped }
            log(tr("  停在发送前：可能留在了输入框里", "  stopped before sending: may be left in the message box"))
            return .leftOver
        }
        guard newChat() else {
            if stop.isSet { return .stopped }
            log(tr("  开不了新对话", "  couldn't start a new chat")); return .failed
        }
        // the box must start empty: anything there (a draft of yours) would be sent along
        guard !hasDraft(), !canSend() else { log(tr("  新对话的输入框里有东西", "  the new chat's box isn't empty")); return .notEmpty }
        if !files.isEmpty {
            // landed: the files make Send usable (it waits while they upload); what you had copied goes back then
            guard !stop.isSet, attach(files), wait(20, { self.canSend() }) else {
                if stop.isSet { return halt() }
                log(tr("  文件没附上", "  the files weren't attached")); return .leftOver
            }
            clip.putBack()
            log(tr("  附上 \(files.count) 个文件", files.count == 1 ? "  attached 1 file" : "  attached \(files.count) files"))
        }
        guard !stop.isSet, type(text) else {
            if stop.isSet { return halt() }
            log(tr("  找不到输入框", "  couldn't find the message box")); return files.isEmpty ? .failed : .leftOver
        }
        // stopped now: not sent
        guard !stop.isSet else { return halt() }
        guard send() else { log(tr("  发不出去", "  couldn't send")); return .leftOver }
        // sent: the chat is made, stopped or not. Its address is looked for a moment more once stopped, to record it
        var id = wait(30) { self.chatID() != nil } ? chatID() : nil
        if id == nil && stop.isSet { id = soon { self.chatID() } }
        guard let id else { log(tr("  新对话没有地址", "  the new chat has no address")); return .unconfirmed }
        var made = Made(id: id)
        guard waitReply(after: 0) else {
            log(stop.isSet ? tr("  停下了，Claude 还没回复（对话已建好：\(id)）", "  stopped before Claude replied (the chat was made: \(id))")
                           : tr("  等回复超时（对话已建好：\(id)）", "  no reply in time (the chat was made: \(id))"))
            made.shown = pageTitle()
            return .made(made)
        }
        made.replied = true
        // Claude names the chat after the first reply
        _ = wait(20) { let t = self.pageTitle(); return !t.isEmpty && !ClaudeWords.untitled.contains(t) }
        let auto = pageTitle()
        // (not the name Claude gave it: chat titles stay out of the log. Stopped: left as it is, yours to finish)
        if !stop.isSet {
            made.pinned = pin(rowTitle: auto)
            if !made.pinned { log(tr("  置顶失败", "  couldn't pin it")) }
        }
        if !stop.isSet {
            pause(1)
            made.renamed = rename(rowTitle: auto, to: title)
            if !made.renamed { log(tr("  改名失败，还是 Claude 起的名字", "  couldn't rename it: it keeps the name Claude gave it")) }
        }
        made.shown = made.renamed ? title : pageTitle()
        log(tr("  已导入 → ", "  imported → ") + id)
        return .made(made)
    }

    // MARK: steps

    func open(title: String) -> Bool {
        if pageTitle() == title { return true }
        guard !youCameBack(), AXScan.press(pid: pid, title: title) else { return false }
        return wait(15) { self.pageTitle() == title }
    }

    /// By its address (exact: another chat may have the same title); one known only by its title, by its row in the
    /// sidebar.
    func open(id: String, title: String) -> Bool {
        guard Archive.isAddress(id) else { return open(title: title) }
        if chatID() == id { return true }
        guard !youCameBack(), let u = URL(string: "claude://claude.ai/chat/" + id) else { return false }
        DispatchQueue.main.sync { _ = NSWorkspace.shared.open(u) }
        return wait(20) { self.chatID() == id }
    }

    /// Pastes files into the message box as attachments (what you had copied goes back once they've landed: see
    /// startChat). Not once stopped.
    func attach(_ files: [URL]) -> Bool {
        guard let w = web(), let box = composer(w), activate() else { return false }
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pause(0.4)
        guard !stop.isSet, !youCameBack(), let v = keyCode("v"), clip.put(files: files) else { return false }
        guard !stop.isSet, !youCameBack(), clip.paste({ key(v, cmd: true) }) else { clip.putBack(); return false }    // ⌘V
        pasted = true
        // let them upload (not once stopped: nothing is sent then)
        nap(2.5 + 0.4 * Double(files.count))
        return true
    }

    /// Pastes `text` into the message box (not once stopped): true once it's there.
    func type(_ text: String) -> Bool {
        guard let w = web(), let box = composer(w), activate() else { return false }
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pause(0.4)
        let sendable = canSend()
        // (you came back while Claude was brought forward: your typing isn't mixed with this)
        guard !stop.isSet, !youCameBack(), let v = keyCode("v"), clip.put(text: text) else { return false }
        guard !stop.isSet, !youCameBack(), clip.paste({ key(v, cmd: true) }) else { clip.putBack(); return false }    // ⌘V
        pasted = true
        pause(1.2)
        // it landed (else nothing is sent, rather than an empty message waited on for minutes): in the box, or, for a
        // long text, as the "Pasted text" attachment Claude makes of it, which makes Send usable
        let start = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        let landed = wait(3) { self.boxHolds(start) || (!sendable && self.canSend()) }
        // Claude has read it: what you had copied goes back now (one that didn't land: when the run ends, in case
        // Claude reads it late)
        if landed { clip.putBack() }
        return landed
    }

    /// The message box holds `text`.
    func boxHolds(_ text: String) -> Bool { web().flatMap { composer($0) }.map { AXScan.str($0, "AXValue").contains(text) } ?? false }

    /// Claude's Send button is there and usable (something is in the message box, typed or attached).
    private func canSend() -> Bool {
        guard let w = web(), let b = button(w, prefixes: ClaudeWords.send) else { return false }
        return AXScan.str(b, "AXEnabled") != "0"
    }

    /// Something you typed and haven't sent yet.
    func hasDraft() -> Bool {
        guard let w = web(), let box = composer(w) else { return false }
        return !AXScan.str(box, "AXValue").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() -> Bool {
        if let w = web(), let b = button(w, prefixes: ClaudeWords.send), AXScan.str(b, "AXEnabled") != "0" {
            return AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
        }
        key(36)                                                   // Return
        return true
    }

    /// Done when the newest message is Claude's, nothing is generating, and it stays that way.
    func waitReply(after before: Int) -> Bool {
        let start = Date()
        var steady = 0
        while Date().timeIntervalSince(start) < 600 {
            if stop.isSet { return false }
            nap(2)
            if stop.isSet { return false }
            if messageCount() < before + 2 || busy() { steady = 0; continue }
            guard let m = lastMessage(), isClaude(m), copyButton(m) != nil else { steady = 0; continue }
            steady += 1
            if steady >= 2 { return true }
        }
        return false
    }

    /// The newest reply as Markdown (through its Copy button), or its plain text (also when you've come back during a
    /// run while you're away: Claude isn't brought forward for the button). The copy is read at once, and what you had
    /// copied goes back: the summary isn't left on the clipboard.
    func copyLast() -> String? {
        guard let w = web(), let m = lastMessage(in: w), isClaude(m) else { return nil }
        if let b = copyButton(m), activate(), let before = clip.willCopy() {
            AXUIElementPerformAction(b, kAXPressAction as CFString)
            // (waited for even once stopped: a copy that lands after would be left on the clipboard)
            var landed = clip.copied(since: before)
            for _ in 0..<16 where !landed { pause(0.25); landed = clip.copied(since: before) }
            // (one written in more than one step settles first: what you had goes back over all of it)
            var count = clip.changeCount
            for _ in 0..<4 where landed {
                pause(0.3)
                if clip.changeCount == count { break }
                count = clip.changeCount
            }
            if landed, let s = clip.takeCopy(), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            clip.putBack()
            log(tr("  Copy 按钮没反应，改用纯文本", "  the Copy button did nothing: plain text instead"))
        }
        let t = plainText(m)
        return t.isEmpty ? nil : t
    }

    func newChat() -> Bool {
        guard let w = web(), let sb = AXScan.sidebar(in: w) else { return false }
        let names = ClaudeWords.newChat
        guard let b = find(sb, first: true, skipSidebar: false, { el in
            AXScan.str(el, "AXRole") == "AXButton" && (names.contains(AXScan.str(el, "AXTitle")) || names.contains(AXScan.str(el, "AXDescription")))
        }).first else { return false }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
        return wait(10) { self.chatID() == nil && self.web().flatMap { self.composer($0) } != nil }
    }

    func pin(rowTitle: String) -> Bool { menu(rowTitle: rowTitle, items: ClaudeWords.pin) }

    func rename(rowTitle: String, to title: String) -> Bool {
        if rowTitle == title { return true }
        guard menu(rowTitle: rowTitle, items: ClaudeWords.rename) else { return false }
        pause(0.8)
        // (nothing to paste, or stopped: Esc leaves the name as it was)
        guard !stop.isSet, let a = keyCode("a"), let v = keyCode("v"), clip.put(text: title) else { key(53); return false }
        key(a, cmd: true)                                         // ⌘A
        guard !stop.isSet, clip.paste({ key(v, cmd: true) }) else { clip.putBack(); key(53); return false }          // ⌘V
        pause(0.4)
        if let w = web(), let save = button(w, prefixes: ClaudeWords.save, anywhere: true) {
            AXUIElementPerformAction(save, kAXPressAction as CFString)
        } else {
            key(36)
        }
        let ok = wait(8) { self.pageTitle() == title }
        // (saved or not, the paste was read long since)
        clip.putBack()
        return ok
    }

    /// Opens the "More options for …" menu of a sidebar row and picks an item.
    private func menu(rowTitle: String, items: Set<String>) -> Bool {
        guard let w = web(), let sb = AXScan.sidebar(in: w),
              let more = find(sb, first: true, skipSidebar: false, { el in
                  AXScan.str(el, "AXRole") == "AXPopUpButton" && AXScan.knownMenus.contains { $0.replacingOccurrences(of: "{label}", with: rowTitle) == AXScan.str(el, "AXDescription") }
              }).first, activate() else { return false }
        AXUIElementPerformAction(more, kAXPressAction as CFString)
        pause(0.7)
        let found = find(w, first: true, skipSidebar: true, { el in
            AXScan.str(el, "AXRole") == "AXMenuItem" && items.contains(AXScan.str(el, "AXTitle").trimmingCharacters(in: .whitespaces))
        }).first
        guard let it = found else { key(53); return false }        // Esc closes the menu
        return AXUIElementPerformAction(it, kAXPressAction as CFString) == .success
    }

    // MARK: reading the page

    func web() -> AXUIElement? {
        for win in AXScan.list(AXScan.attr(app, "AXWindows")) {
            if let w = find(win, first: true, skipSidebar: true, limit: 3000, { el in
                AXScan.str(el, "AXRole") == "AXWebArea" && AXScan.str(el, "AXURL").contains("claude.ai")
            }).first { return w }
        }
        return nil
    }

    func pageTitle() -> String {
        guard let w = web() else { return "" }
        var t = AXScan.str(w, "AXTitle")
        if t.hasSuffix(" - Claude") { t = String(t.dropLast(9)) }
        return t
    }

    /// The message feed is there (else Claude's window isn't one KIKUmap knows how to read).
    func messagesFound() -> Bool { web().flatMap { messagesGroup($0) } != nil }

    func chatID() -> String? {
        guard let w = web() else { return nil }
        let url = AXScan.str(w, "AXURL"), ns = url as NSString
        guard url.contains("/chat/") else { return nil }
        return AXScan.uuidRx.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
    }

    private func messagesGroup(_ w: AXUIElement) -> AXUIElement? {
        find(w, first: true, skipSidebar: true, { el in
            AXScan.str(el, "AXSubrole") == "AXApplicationGroup" && ClaudeWords.messages.contains(AXScan.str(el, "AXDescription"))
        }).first
    }

    private func messages(_ w: AXUIElement) -> [AXUIElement] {
        guard let g = messagesGroup(w) else { return [] }
        return find(g, skipSidebar: false, descend: false, { el in AXScan.str(el, "AXSubrole") == "AXDocumentArticle" })
    }

    func lastMessage(in w: AXUIElement? = nil) -> AXUIElement? { (w ?? web()).flatMap { messages($0).last } }

    /// "Message 26 of 32" → 32 (or how many are on the page).
    func messageCount() -> Int {
        guard let w = web() else { return 0 }
        let ms = messages(w)
        // (the page itself holds only the messages near what's on screen)
        return ms.last.flatMap { ClaudeDriver.total(in: AXScan.str($0, "AXDescription")) } ?? ms.count
    }

    /// How many messages the chat has, from a message's label: "Message 26 of 32", "Nachricht 26 von 32",
    /// "32件中26件目のメッセージ"… In every language Claude speaks the total is the larger number.
    nonisolated static func total(in label: String) -> Int? {
        let ns = label.split(whereSeparator: { !($0.isASCII && $0.isNumber) }).compactMap { Int($0) }
        return ns.count >= 2 ? ns.max() : nil
    }

    func isClaude(_ m: AXUIElement) -> Bool {
        let h = find(m, first: true, skipSidebar: false, limit: 50, { AXScan.str($0, "AXRole") == "AXHeading" }).first
        let said = h.map { AXScan.str($0, "AXTitle") } ?? ""
        return !ClaudeWords.youSaid.contains { said.hasPrefix($0) }
    }

    private func copyButton(_ m: AXUIElement) -> AXUIElement? {
        find(m, first: true, skipSidebar: false, backwards: true, { el in
            AXScan.str(el, "AXRole") == "AXButton" && ClaudeWords.copy.contains(AXScan.str(el, "AXDescription"))
        }).first
    }

    private func plainText(_ m: AXUIElement) -> String {
        var out: [String] = []
        for el in find(m, skipSidebar: false, limit: 30000, { AXScan.str($0, "AXRole") == "AXStaticText" }) {
            let v = AXScan.str(el, "AXValue")
            if !v.isEmpty && !v.hasPrefix("Claude responded:") { out.append(v) }
        }
        return out.joined(separator: "\n")
    }

    /// Claude is still writing: a "Stop" button shows.
    func busy() -> Bool {
        guard let w = web() else { return false }
        return button(w, prefixes: ClaudeWords.stop) != nil
    }

    /// The message box: a text area, best one described as the prompt.
    private func composer(_ w: AXUIElement) -> AXUIElement? {
        let boxes = find(w, skipSidebar: true, skipMessages: true, { el in
            let r = AXScan.str(el, "AXRole")
            return r == "AXTextArea" || (r == "AXTextField" && AXScan.str(el, "AXDescription").range(of: "prompt|Claude|Reply|message", options: [.regularExpression, .caseInsensitive]) != nil)
        })
        return boxes.first { AXScan.str($0, "AXDescription").range(of: "prompt|Claude|Reply", options: [.regularExpression, .caseInsensitive]) != nil } ?? boxes.last
    }

    private func button(_ w: AXUIElement, prefixes: [String], anywhere: Bool = false) -> AXUIElement? {
        find(w, first: true, skipSidebar: true, skipMessages: !anywhere, { el in
            guard AXScan.str(el, "AXRole") == "AXButton" else { return false }
            let d = AXScan.str(el, "AXDescription"), t = AXScan.str(el, "AXTitle")
            return prefixes.contains { d.hasPrefix($0) || t.hasPrefix($0) }
        }).first
    }

    /// Elements under `root` that match, in page order (or from the end). Skips the sidebar and, if
    /// asked, the messages; doesn't look inside a match unless `descend`.
    private func find(_ root: AXUIElement, first: Bool = false, skipSidebar: Bool, skipMessages: Bool = false,
                      descend: Bool = true, backwards: Bool = false, limit: Int = 15000,
                      _ match: (AXUIElement) -> Bool) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var n = 0
        while let (el, d) = stack.popLast(), n < limit {
            n += 1
            if d > 0 && (skipSidebar || skipMessages) {
                let sub = AXScan.str(el, "AXSubrole")
                if skipSidebar && sub == "AXLandmarkComplementary" { continue }
                if skipMessages && sub == "AXApplicationGroup" && ClaudeWords.messages.contains(AXScan.str(el, "AXDescription")) { continue }
            }
            if match(el) {
                out.append(el)
                if first { break }
                if !descend { continue }
            }
            if d < 60 {
                let kids = AXScan.children(el)
                for c in (backwards ? kids : kids.reversed()) { stack.append((c, d + 1)) }
            }
        }
        return out
    }

    // MARK: input

    /// Claude in front (false: you've come back during a run while you're away, and it's left where it is).
    private func activate() -> Bool {
        guard !youCameBack() else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
            pause(0.6)
        }
        return true
    }

    /// The key that types `letter` with ⌘ in the keyboard layout in use (on a French keyboard the US "A" position is
    /// "Q": ⌘Q would quit Claude). Not found: nil, and nothing is pressed. (Looked up before a paste, not during it:
    /// the paste holds the clipboard, which a quit on the main thread waits for.)
    private func keyCode(_ letter: Character) -> CGKeyCode? {
        guard let code = DispatchQueue.main.sync(execute: { ClaudeDriver.keyCode(typing: letter) }) else {
            log(tr("  键盘布局读不了，没按 ⌘\(letter.uppercased())", "  couldn't read the keyboard layout: ⌘\(letter.uppercased()) not pressed"))
            return nil
        }
        return code
    }

    /// `layout`: a keyboard layout's id ("com.apple.keylayout.French"); nil: the one in use.
    @MainActor static func keyCode(typing letter: Character, layout id: String? = nil) -> CGKeyCode? {
        let source: TISInputSource? = id.map { id in
            (TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource])?.first
        } ?? TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let src = source, let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(letter).lowercased()
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0, length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let ok = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), UInt32((cmdKey >> 8) & 0xFF), UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
                if ok == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == target { return CGKeyCode(code) }
            }
            return nil
        }
    }

    private func key(_ code: CGKeyCode, cmd: Bool = false) {
        // (input of yours before these keys is noted first; any after them is yours too, even if these count as input)
        _ = youCameBack()
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            if cmd { e.flags = .maskCommand }
            e.postToPid(pid)
            pause(0.04)
        }
        lastStep = Date()
    }

    func wait(_ secs: Double, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(secs)
        while Date() < end {
            if ok() { return true }
            if stop.isSet { return false }
            pause(0.5)
        }
        return ok()
    }

    /// `ok`'s answer, looked for a moment even once stopped: what has already gone to Claude (a message sent), seen
    /// through.
    func soon<T>(_ ok: () -> T?) -> T? {
        for i in 0..<6 {
            if let v = ok() { return v }
            if i < 5 { pause(0.25) }
        }
        return nil
    }

    private func pause(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }

    /// A pause of up to `s` seconds that ends once stopped (a quit waits only a few seconds for the run to stop).
    private func nap(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while !stop.isSet, Date() < end { pause(min(0.1, max(0, end.timeIntervalSinceNow))) }
    }
}

// MARK: the clipboard while a run pastes through it

/// The pasteboard as a run uses it: the Mac's, or a test's stand-in (the checks run where there's no pasteboard server).
protocol RunBoard: AnyObject {
    var changeCount: Int { get }
    /// Every item, with each kind of data it holds.
    func read() -> [[NSPasteboard.PasteboardType: Data]]
    /// Replaces what's there. `localOnly`: kept off your other devices (Universal Clipboard).
    func write(_ items: [[NSPasteboard.PasteboardType: Data]], localOnly: Bool)
    /// Files, as a paste of them, kept off your other devices; the first item carries `marks` too.
    func write(files: [URL], marks: [NSPasteboard.PasteboardType])
    func string() -> String?
}

/// The Mac's clipboard (reached only when a run uses it).
final class SystemBoard: RunBoard {
    private var pb: NSPasteboard { .general }
    var changeCount: Int { pb.changeCount }
    func read() -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
    }
    func write(_ items: [[NSPasteboard.PasteboardType: Data]], localOnly: Bool) {
        _ = localOnly ? pb.prepareForNewContents(with: .currentHostOnly) : pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { d in
            let it = NSPasteboardItem()
            for (t, v) in d { it.setData(v, forType: t) }
            return it
        })
    }
    func write(files: [URL], marks: [NSPasteboard.PasteboardType]) {
        _ = pb.prepareForNewContents(with: .currentHostOnly)
        pb.writeObjects(files as [NSURL])
        for m in marks { pb.setData(Data(), forType: m) }
    }
    func string() -> String? { pb.string(forType: .string) }
}

/// The clipboard while a run (summaries, or an import) pastes and copies through it. What you had copied is kept, and
/// put back as soon as each paste has landed and each copy has been read (and at the run's end, and when KIKUmap
/// quits). What KIKUmap puts there is marked for clipboard history apps to skip (the nspasteboard.org types) and kept
/// off your other devices. Claude's own Copy button, which brings each summary, can't be marked: that copy is read at
/// once and what you had goes back.
final class RunClipboard: @unchecked Sendable {
    /// KIKUmap's own pastes: passing, private, not copied by you.
    static let marks = ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType", "org.nspasteboard.AutoGeneratedType"]
        .map { NSPasteboard.PasteboardType($0) }
    /// What you had, put back: not a new copy of yours either.
    static let backMarks = ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"].map { NSPasteboard.PasteboardType($0) }
    /// A quit waits this long after the last ⌘V before putting what you had back (Claude may not have read the paste
    /// yet: it would paste what you had instead).
    static var settle: TimeInterval = 1.5

    let board: RunBoard
    private let lock = NSLock()
    /// What you had copied, while the clipboard holds KIKUmap's paste (or Claude's copy) instead.
    private var saved: [[NSPasteboard.PasteboardType: Data]]?
    /// The clipboard as KIKUmap last left it: what you had goes back only while it's still that (what you copy
    /// meanwhile stays).
    private var own: Int?
    private var pastedAt: Date?
    /// KIKUmap is quitting: nothing more is put there or pasted.
    private(set) var closed = false

    init(_ board: RunBoard = SystemBoard()) { self.board = board }

    private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

    /// What's there now is kept, unless it's still KIKUmap's own.
    private func keep() { if own == nil || own != board.changeCount { saved = board.read() } }

    /// `text` there, for a paste. False: KIKUmap is quitting.
    func put(text: String) -> Bool {
        locked {
            guard !closed else { return false }
            keep()
            var item: [NSPasteboard.PasteboardType: Data] = [.string: Data(text.utf8)]
            for m in RunClipboard.marks { item[m] = Data() }
            board.write([item], localOnly: true)
            own = board.changeCount
            return true
        }
    }

    /// `files` there, for a paste. False: KIKUmap is quitting.
    func put(files: [URL]) -> Bool {
        locked {
            guard !closed else { return false }
            keep()
            board.write(files: files, marks: RunClipboard.marks)
            own = board.changeCount
            return true
        }
    }

    /// ⌘V (`keys`), only while the clipboard still holds what KIKUmap put there: not something you copied meanwhile,
    /// and not once KIKUmap is quitting.
    func paste(_ keys: () -> Void) -> Bool {
        locked {
            guard !closed, let o = own, o == board.changeCount else { return false }
            keys()
            pastedAt = Date()
            return true
        }
    }

    /// Before Claude's Copy button is pressed: what you have is kept. The clipboard's count, to see the copy land
    /// (nil: KIKUmap is quitting).
    func willCopy() -> Int? {
        locked {
            guard !closed else { return nil }
            keep()
            return board.changeCount
        }
    }

    func copied(since count: Int) -> Bool { locked { board.changeCount != count } }
    var changeCount: Int { locked { board.changeCount } }

    /// Claude's copy, read; what you had goes back at once.
    func takeCopy() -> String? {
        locked {
            own = board.changeCount
            let s = board.string()
            restore()
            return s
        }
    }

    /// What you had, back (if the clipboard is still as KIKUmap left it).
    func putBack() { locked { restore() } }

    private func restore() {
        if let o = own, o == board.changeCount {
            board.write((saved ?? []).map { item in
                var d = item
                for m in RunClipboard.backMarks where d[m] == nil { d[m] = Data() }
                return d
            }, localOnly: false)
        }
        own = nil
        saved = nil
        pastedAt = nil
    }

    /// The run is over, or KIKUmap is quitting: nothing more is put there or pasted, and what you had goes back, once a
    /// paste sent a moment ago has had time to be read.
    func close() {
        let last: Date? = locked { closed = true; return pastedAt }
        if let t = last {
            let left = RunClipboard.settle - Date().timeIntervalSince(t)
            if left > 0 { usleep(useconds_t(left * 1_000_000)) }
        }
        putBack()
    }
}
