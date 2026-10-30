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

        init() {}
        /// A part that's missing (an older or newer file) reads as empty; one that's there but unreadable fails the file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            summaries = try c.decodeIfPresent([String: Record].self, forKey: .summaries) ?? [:]
            imported = try c.decodeIfPresent([String: String].self, forKey: .imported) ?? [:]
            zipDone = try c.decodeIfPresent(String.self, forKey: .zipDone)
            zipDoneAt = try c.decodeIfPresent(Double.self, forKey: .zipDoneAt)
            files = try c.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
        }
    }
    /// One chat to export and the folder it goes in.
    struct Item { let id: String; let title: String; let dir: URL; let outsideClaude: Bool }

    let store: Store
    var pid: () -> pid_t = { 0 }
    var onChange: (() -> Void)?
    private var state = State()
    private let stop = StopFlag()

    private(set) var busy = false
    /// What the run under way is: an import (else an export).
    private(set) var importing = false
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

    /// There but unreadable (damaged, or from a newer Kikumap): moved to data/backups before anything can write over
    /// it (what was imported and summarized is in it), and listed in the To-do.
    private func keepAside(_ error: Error) {
        let fm = FileManager.default, dir = stateURL.deletingLastPathComponent().appendingPathComponent("backups")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let to = dir.appendingPathComponent("archive-unreadable-" + MapModel.stamp("yyyyMMdd-HHmmss") + ".json")
        if (try? fm.moveItem(at: stateURL, to: to)) != nil { unreadable = "data/backups/" + to.lastPathComponent } else {
            readOnly = true
            unreadable = "data/archive.json" + tr("（没法移开；现在导入和总结的记录不会保存）",
                                                  " (it couldn't be moved aside; what's imported or summarized now isn't recorded)")
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
                guard url.lastPathComponent == "memory.md", let s = try? String(contentsOf: url, encoding: .utf8), s.hasPrefix("---\n"),
                      let end = s.range(of: "\n---\n") else { continue }
                var id = "", when = ""
                for line in s[..<end.lowerBound].split(separator: "\n") {
                    if line.hasPrefix("id: ") { id = String(line.dropFirst(4)) }
                    if line.hasPrefix("summarized: ") { when = String(line.dropFirst(12)) }
                }
                if !id.isEmpty, when > (found[id]?.date ?? "") {
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
                .appendingPathComponent(tr("Claude 导出", "Claude Export"))
        }
        set {
            if folder.path != newValue.path { d.set(folder.path, forKey: "ArchivePreviousFolder") }
            d.set(newValue.path, forKey: "ArchiveFolder")
        }
    }
    /// The folder exports went to before the last change (summaries there are brought along, not written again).
    static var previousFolder: URL? { d.string(forKey: "ArchivePreviousFolder").map { URL(fileURLWithPath: $0) } }
    /// It can be written in now (made if need be): not on a disk that isn't connected.
    static func reachable(_ root: URL) -> Bool {
        let fm = FileManager.default
        return (try? fm.createDirectory(at: root, withIntermediateDirectories: true)) != nil && fm.isWritableFile(atPath: root.path)
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
    /// A folder Kikumap names in its language: the one already in `dir` in the other language, if there is one.
    static func named(_ zh: String, _ en: String, in dir: URL) -> String {
        let fm = FileManager.default, mine = tr(zh, en), other = mine == zh ? en : zh
        return !fm.fileExists(atPath: dir.appendingPathComponent(mine).path) && fm.fileExists(atPath: dir.appendingPathComponent(other).path) ? other : mine
    }
    /// Topic ids picked in the export window (nil = everything).
    static var topics: Set<String>? {
        get { (d.array(forKey: "ExportTopics") as? [String]).map(Set.init) }
        set { d.set(newValue.map(Array.init), forKey: "ExportTopics") }
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
    func items(topics: Set<String>?, unplaced: Bool) -> [Item] {
        Archive.settleFolder()
        let map = store.map
        var out: [Item] = []
        var seen = Set<String>()
        var usedDirs = Set<String>()
        // a chat Import started from an earlier one gets a folder of its own beside that one's, which stays as it was
        // (one started from that one again: "(continued 2)", and so on)
        let continues = Dictionary(state.imported.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        func depth(_ id: String) -> Int { var d = 0, x = id; while let o = continues[x], d < 9 { d += 1; x = o }; return d }
        func add(_ id: String, _ path: [String]) {
            guard !seen.contains(id), let c = store.chat(id) else { return }
            seen.insert(id)
            var dir = path.reduce(Archive.folder) { $0.appendingPathComponent(ClaudeExport.safeName($1)) }
                .appendingPathComponent(ClaudeExport.safeName(store.name(id) + { d in d == 0 ? "" : tr("（续\(d > 1 ? "\(d)" : "")）", " (continued\(d > 1 ? " \(d)" : ""))") }(depth(id))))
            // the Mac's disk ignores case ("Plan" and "plan" are one folder): two chats never share a folder
            if usedDirs.contains(dir.path.lowercased()) { dir = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + " " + String(id.suffix(6))) }
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
                    walk(s, path + [s.title.isEmpty ? Archive.named("新主题", "New topic", in: parent) : s.title], inherited || topics?.contains(s.id) ?? true)
                }
            }
        }
        walk(map.root, [], topics == nil || topics!.contains(map.root.id))
        if unplaced {
            let placed = map.placedChats()
            let unfiled = Archive.named("未归类", "Unfiled", in: Archive.folder)
            for c in store.pinnedList() where !placed.contains(c.id) { add(c.id, [unfiled]) }
        }
        return out
    }

    // MARK: running

    /// Export with the settings saved in the export window.
    func exportSaved(scheduled: Bool, memory: Bool? = nil) {
        let zip = Archive.withFiles ? ClaudeExport.newestZip() : nil
        export(items(topics: Archive.topics, unplaced: Archive.withUnplaced), memory: memory ?? Archive.withMemory,
               zip: zip, force: false, scheduled: scheduled)
    }

    /// Right-click → archive one chat: just its summary, always.
    func runOne(_ id: String) {
        guard let it = items(topics: nil, unplaced: true).first(where: { $0.id == id }) ?? store.chat(id).map({
            Item(id: id, title: $0.title, dir: Archive.folder.appendingPathComponent(Archive.named("未归类", "Unfiled", in: Archive.folder)).appendingPathComponent(ClaudeExport.safeName(store.name(id))), outsideClaude: $0.outsideClaude)
        }) else { return }
        export([it], memory: true, zip: nil, force: true, scheduled: false)
    }

    func cancel() { stop.set(true) }

    /// Every few minutes. With automatic updates on: a new Claude export zip in Downloads updates the
    /// files right away; the summaries are brought up to date when they're due and the Mac is idle.
    func tick() {
        retrySave()
        guard Archive.auto, !busy, !recovering else { return }
        if Archive.withFiles, let z = ClaudeExport.newestZip(), zipKey(z) != state.zipDone,
           ClaudeExport.modified(z).timeIntervalSince1970 > (state.zipDoneAt ?? 0) {
            export(items(topics: Archive.topics, unplaced: Archive.withUnplaced), memory: false, zip: z, force: false, scheduled: true)
            return
        }
        guard Archive.withMemory, pid() != 0, AXIsProcessTrusted() else { return }
        let due = (Archive.lastRun.map { Date().timeIntervalSince($0) } ?? .infinity) >= Double(Archive.everyDays) * 86400 - 600
        // away: no input for 10 minutes, and nothing keeping the screen on (a video, a call, a presentation)
        guard due, Archive.idleSeconds() >= 600, !Archive.screenKeptOn() else { return }
        exportSaved(scheduled: true, memory: true)
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
        // an external or network disk that isn't connected: nothing is asked of Claude (and it's tried again later)
        guard Archive.reachable(Archive.folder) else {
            let why = tr("导出文件夹现在打不开（外接盘或网络盘没接上？）", "The export folder can't be reached (a disk not connected?)")
            Archive.lastResult = Clock.format(Date(), "M/d HH:mm", "MMM d HH:mm") + " · " + why
            log("\(Clock.iso()) not run · the folder can't be reached: \(Archive.folder.path)")
            if !scheduled { Permissions.alert(why, Archive.folder.path) }
            onChange?()
            return
        }
        let p = pid()
        let canDrive = p != 0 && AXIsProcessTrusted()
        if memory && !canDrive && zip == nil {
            Permissions.alert(tr("没法写总结", "Can't write summaries"),
                              tr("要先打开 Claude App，并开启「辅助功能」权限。", "Open the Claude app and turn on Accessibility first."))
            return
        }
        busy = true
        stop.set(false)
        progress = ""
        onChange?()
        // (a chat whose new folder another chat still has things in: nothing is written there this time)
        let blocked = Set(follow(list).map(\.id))
        // decided up front, on the main thread
        let skip = Set(list.filter { !force && (store.isRunning($0.id) || store.chat($0.id).map(store.isUnread) == true) }.map { $0.id })
        let counts = state.summaries.mapValues { $0.messages }
        let updated = Dictionary(uniqueKeysWithValues: list.map { ($0.id, store.chat($0.id)?.updated_at ?? "") })
        let done = state.summaries.mapValues { $0.date }
        let prompt = Archive.summaryPrompt
        let stop = self.stop
        log("\(Clock.iso()) export · \(list.count) chats · memory \(memory) · zip \(zip?.lastPathComponent ?? "-")\(scheduled ? " · scheduled" : "")")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            func say(_ s: String) { DispatchQueue.main.async { MainActor.assumeIsolated { self?.progress = s; self?.onChange?() } } }
            func log(_ s: String) { DispatchQueue.main.async { MainActor.assumeIsolated { self?.log(s) } } }
            var r = Report()
            // 1. prompts, conversation and artifacts from Claude's export
            if let z = zip {
                say(tr("读取 Claude 导出包…", "Reading the Claude export…"))
                if let all = ClaudeExport.load(z) {
                    let byName = Dictionary(all.values.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                    var wrote: [Item] = []
                    for it in list where !it.outsideClaude {
                        if blocked.contains(it.id) { log("  \(it.title): " + tr("文件夹里还有另一个同名对话的东西，这次没写", "its folder still holds another chat's things (same name): not written this time")); continue }
                        // by address; by name only for a chat known by its title alone (another may share it)
                        guard let c = all[it.id.lowercased()] ?? (Archive.isAddress(it.id) ? nil : byName[it.title]) else { r.notInZip += 1; continue }
                        do { try ClaudeExport.write(c, title: it.title, to: it.dir); r.files += 1; r.artifacts += c.artifacts.count; wrote.append(it) }
                        catch { log("  \(it.title): \(error.localizedDescription)") }
                    }
                    let written = wrote
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.markZip(z, wrote: written) } }
                } else {
                    r.zipFailed = true
                    log(tr("  导出包读不了：", "  can't read the export: ") + z.path)
                }
            }
            // 2. the hand-off summaries, written by Claude in each chat
            if memory && canDrive {
                let d = ClaudeDriver(pid: p, stop: stop, log: log)
                let clip = d.saveClipboard()
                let back = d.pageTitle(), backID = d.chatID()
                let todo = list.filter { !$0.outsideClaude }
                var misses = 0
                // a run over the chosen topics restarts the schedule; one chat archived by right-click leaves it as it was
                r.summariesRan = !force
                chats: for (n, it) in todo.enumerated() {
                    if stop.isSet || (scheduled && Archive.idleSeconds() < 3 && n > 0) { r.cutShort = scheduled && !stop.isSet; break }
                    if skip.contains(it.id) { r.skipped += 1; continue }
                    // its folder still holds another chat's things: a summary couldn't be saved there, so none is asked
                    if blocked.contains(it.id) { r.skipped += 1; log(tr("  文件夹里还有另一个同名对话的东西，这次跳过", "  its folder still holds another chat's things (same name): skipped this time")); continue }
                    // nothing new since the last summary (the app saw no activity)
                    if !force, let when = done[it.id], let u = updated[it.id], !u.isEmpty, u <= when {
                        DispatchQueue.main.sync { MainActor.assumeIsolated { self?.bringSummary(it) } }
                        r.skipped += 1; continue
                    }
                    say("\(n + 1)/\(todo.count) · \(it.title)")
                    log("— \(it.title)")
                    switch d.summarize(id: it.id, title: it.title, prompt: prompt, lastCount: force ? nil : counts[it.id]) {
                    case .done(let text, let count):
                        misses = 0
                        let ok = DispatchQueue.main.sync { MainActor.assumeIsolated { self?.saveMemory(it, text: text, messages: count) ?? false } }
                        if ok { r.memory += 1 } else { r.failed += 1 }
                    case .unchanged:
                        misses = 0; r.skipped += 1; log(tr("  没有新内容，跳过", "  nothing new, skipped"))
                        DispatchQueue.main.sync { MainActor.assumeIsolated { self?.bringSummary(it) } }
                    case .failed(let why): misses = 0; r.failed += 1; log(tr("  失败：", "  failed: ") + why)
                    case .unreadable(let why):
                        r.failed += 1; log(tr("  失败：", "  failed: ") + why)
                        // twice in a row: it's Claude's page, not this chat; the rest would only fail the same way
                        misses += 1
                        if misses >= 2 { r.unreadable = true; break chats }
                    }
                }
                if !stop.isSet { if let b = backID { _ = d.open(id: b, title: back) } else if !back.isEmpty { _ = d.open(title: back) } }
                d.restoreClipboard(clip)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(r, list: list) } }
        }
    }

    private struct Report {
        var files = 0, artifacts = 0, notInZip = 0, memory = 0, skipped = 0, failed = 0
        var zipFailed = false, unreadable = false, summariesRan = false
        /// A scheduled run that stopped because you came back: it carries on when the Mac is idle again.
        var cutShort = false
    }

    private func markZip(_ z: URL, wrote: [Item]) {
        state.zipDone = zipKey(z)
        state.zipDoneAt = max(state.zipDoneAt ?? 0, ClaudeExport.modified(z).timeIntervalSince1970)
        for it in wrote.map(current) { state.files[it.id] = it.dir.path }
        saveState()
    }

    private func relative(_ url: URL) -> String { String(url.path.dropFirst(Archive.folder.path.count + 1)) }

    /// Each chat's folder follows the chat (filed under another topic since, a topic renamed, another export folder):
    /// first those whose new folder is free, then those that waited for another chat to move out of it (two chats of
    /// one name that swapped places).
    @discardableResult
    private func follow(_ list: [Item]) -> [Item] {
        // a summary or files recorded under a chat's title-only id that no chat has any more (it got its address since,
        // in this run or an older Kikumap): they're this chat's
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
        var id = it.id, hops = 0
        while let n = movedIDs[id], hops < 8 { id = n; hops += 1 }
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
        func same(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased() }
        // where its things are: its summary (a copy with its id in it), and the files Claude's export put there
        var from: [URL] = []
        if let rec = state.summaries[it.id], let f = [root, Archive.previousFolder].compactMap({ $0?.appendingPathComponent(rec.file) })
            .first(where: { Archive.summaryID($0) == it.id }) { from.append(f.deletingLastPathComponent()) }
        if let f = state.files[it.id] { from.append(URL(fileURLWithPath: f)) }
        let away = from.filter { !same($0, it.dir) && fm.fileExists(atPath: $0.path) }
        guard !away.isEmpty else { return true }
        if taken(it.dir, by: it.id) { return false }
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
        log(tr("  文件夹跟过去了：", "  its folder followed it: ") + relative(it.dir))
        return true
    }

    /// Another chat's things are still in this folder (two chats of one name that swapped places): its summary, or
    /// export files recorded as its.
    private func taken(_ dir: URL, by id: String) -> Bool {
        if let other = Archive.summaryID(dir.appendingPathComponent("memory.md")), other != id { return true }
        let p = dir.standardizedFileURL.path.lowercased()
        return Archive.hasRest(dir) && state.files.contains { $0.key != id && URL(fileURLWithPath: $0.value).standardizedFileURL.path.lowercased() == p }
    }

    /// Whose summary this is: the id in its front matter (nil: not one of Kikumap's, or not there).
    nonisolated static func summaryID(_ memory: URL) -> String? {
        guard let s = try? String(contentsOf: memory, encoding: .utf8), s.hasPrefix("---\n"), let end = s.range(of: "\n---\n") else { return nil }
        return s[..<end.lowerBound].split(separator: "\n").first { $0.hasPrefix("id: ") }.map { String($0.dropFirst(4)) }
    }

    private func finish(_ r: Report, list: [Item]) {
        busy = false
        progress = ""
        // (a run that only read Claude's export zip, or was cut short, leaves the summaries' schedule as it was)
        if !r.cutShort && r.summariesRan { Archive.lastRun = Date() }
        var parts: [String] = []
        if r.files > 0 { parts.append(tr("\(r.files) 个对话的提示词和全文，\(r.artifacts) 个 artifact", "\(r.files) chats' prompts and text, \(r.artifacts) artifacts")) }
        if r.memory > 0 { parts.append(tr("\(r.memory) 份总结", "\(r.memory) summaries")) }
        if r.skipped > 0 { parts.append(tr("\(r.skipped) 个跳过（没变化、未读或在跑）", "\(r.skipped) skipped (unchanged, unread or running)")) }
        if r.notInZip > 0 { parts.append(tr("\(r.notInZip) 个不在导出包里（导出包比对话旧？）", "\(r.notInZip) not in the export zip (older than the chat?)")) }
        if r.failed > 0 { parts.append(tr("\(r.failed) 个失败（看 logs/archive.log）", "\(r.failed) failed (see logs/archive.log)")) }
        if r.zipFailed { parts.append(tr("导出包读不了", "couldn't read the export zip")) }
        if r.unreadable { parts.append(tr("认不出 Claude 的对话页面，已停下（Claude 更新了？）", "stopped: Claude's chat page couldn't be read (Claude updated?)")) }
        if r.cutShort { parts.append(tr("你回来了，先停下；Mac 再空闲时接着做", "paused as you came back; carries on when the Mac is idle again")) }
        if stop.isSet { parts.append(tr("中途停止", "stopped")) }
        let s = Clock.format(Date(), "M/d HH:mm", "MMM d HH:mm") + " · " + (parts.isEmpty ? tr("没有要更新的", "nothing to update") : parts.joined(separator: " · "))
        Archive.lastResult = s
        log("\(Clock.iso()) end · \(s)")
        writeIndex(list)
        onChange?()
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
            log(tr("  总结已带到：", "  summary brought along to: ") + String(to.path.dropFirst(root.path.count + 1)))
        } catch {
            log(tr("  总结没能带过去：", "  couldn't bring its summary along: ") + error.localizedDescription)
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
            log(tr("  这个文件夹里还是另一个同名对话的总结，没写：", "  this folder still holds another chat's summary (same name), not written: ") + relative(url))
            return false
        }
        do {
            try FileManager.default.createDirectory(at: it.dir, withIntermediateDirectories: true)
            try (head + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log(tr("  写文件失败：", "  couldn't write the file: ") + error.localizedDescription)
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
        log(tr("  已存：", "  saved: ") + rel)
        return true
    }

    /// 索引.md / Index.md: every exported chat by topic, with what its folder holds; plus a copy of the map.
    private func writeIndex(_ list: [Item]) {
        let root = Archive.folder
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        let all = items(topics: nil, unplaced: true).filter { fm.fileExists(atPath: $0.dir.path) }
        guard !all.isEmpty else { return }
        var s = "# " + tr("Claude 导出", "Claude Export") + "\n\n"
        s += tr("更新于 ", "Updated ") + Clock.format(Date(), "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm")
        s += tr(" · \(all.count) 个对话", " · \(all.count) chats") + "\n"
        var group = ""
        for it in all {
            let rel = String(it.dir.path.dropFirst(root.path.count + 1))
            let g = (rel as NSString).deletingLastPathComponent
            if g != group { group = g; s += "\n## " + (g.isEmpty ? "—" : g.replacingOccurrences(of: "/", with: " / ")) + "\n\n" }
            var has: [String] = []
            if fm.fileExists(atPath: it.dir.appendingPathComponent("memory.md").path) { has.append("memory") }
            if fm.fileExists(atPath: it.dir.appendingPathComponent("prompts.md").path) { has.append(tr("提示词", "prompts")) }
            let arts = (try? fm.contentsOfDirectory(atPath: it.dir.appendingPathComponent("artifacts").path))?.count ?? 0
            if arts > 0 { has.append("\(arts) artifacts") }
            s += "- [\(store.name(it.id))](<\(rel)/>) · " + has.joined(separator: " · ") + "\n"
        }
        // only files Kikumap wrote are written over: someone's own Index.md or map.json in that folder stays
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
        let indexURL = ours(index, isIndex) ? index : root.appendingPathComponent(tr("Kikumap 索引.md", "Kikumap Index.md"))
        if ours(indexURL, isIndex) { try? (mark + s).write(to: indexURL, atomically: true, encoding: .utf8) }
        let mapCopy = root.appendingPathComponent("map.json")
        let isMap: (Data) -> Bool = { (try? JSONDecoder().decode(MapDoc.self, from: $0)) != nil }
        let mapURL = ours(mapCopy, isMap) ? mapCopy : root.appendingPathComponent("kikumap-map.json")
        if ours(mapURL, isMap), let d = fm.contents(atPath: store.map.url.path) { try? d.write(to: mapURL, options: .atomic) }
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

    /// The summaries under a folder (memory.md files, or older single .md files with front matter that
    /// has an id), each with the artifacts next to it.
    nonisolated static func notes(in folder: URL) -> [Note] {
        let fm = FileManager.default
        let all = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let found = all.filter { $0.pathExtension == "md" && !["prompts.md", "conversation.md"].contains($0.lastPathComponent) }.compactMap { url -> (note: Note, at: String)? in
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
            guard !id.isEmpty, !title.isEmpty else { return nil }
            var files: [URL] = [], left = 0
            if url.lastPathComponent == "memory.md" {
                // Claude takes 20 files with a message: the summary and 19 of the chat's (under 5 MB); the rest are said
                let arts = url.deletingLastPathComponent().appendingPathComponent("artifacts")
                let all = (try? fm.contentsOfDirectory(at: arts, includingPropertiesForKeys: [.fileSizeKey])) ?? []
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

    /// For each note: a new chat in the account that's signed in now, with the artifacts attached and
    /// the summary sent in, then pinned and given the old name. On the map it takes the old chat's place.
    func importNotes(_ notes: [Note]) {
        guard !busy, !notes.isEmpty else { return }
        let p = pid()
        guard p != 0, AXIsProcessTrusted() else {
            Permissions.alert(tr("没法导入", "Can't import"),
                              tr("要先打开 Claude App，并开启「辅助功能」权限。", "Open the Claude app and turn on Accessibility first."))
            return
        }
        busy = true
        importing = true
        stop.set(false)
        onChange?()
        let stop = self.stop
        log("\(Clock.iso()) import · \(notes.count) notes")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let d = ClaudeDriver(pid: p, stop: stop) { line in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.log(line) } }
            }
            let clip = d.saveClipboard()
            var done = 0
            var failed: [String] = []
            var halted: String?
            for (n, note) in notes.enumerated() {
                if stop.isSet { break }
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self?.progress = "\(n + 1)/\(notes.count) · \(note.title)"
                    self?.onChange?()
                } }
                d.log("— \(note.title)")
                // the summary goes as a file (Claude reads it whole; pasted, a long one would become an attachment
                // anyway), the files made in that chat beside it, and a short message saying what they are
                let name = note.url.lastPathComponent
                // Claude takes at most 20 files with a message: the summary and 19 of the chat's files; the rest are said
                let files = Array(note.files.prefix(19)), left = note.left + note.files.count - files.count
                let rest = left > 0 ? tr("（另有 \(left) 个文件没附上，在导出文件夹里）", " (\(left) more files weren't attached; they're in the export folder)") : ""
                let text = tr("【接续之前的对话】附件「\(name)」是我之前一个对话的交接总结（原标题：\(note.title)）\(files.isEmpty ? "" : "；其他附件是那个对话里做出的文件")\(rest)。请先读完，用两三句话确认你理解的目标、进度和下一步，然后等我继续。从现在起就当作是同一个对话。",
                              "[Continuing an earlier chat] The attached \(name) is the hand-off summary of a previous conversation (titled \"\(note.title)\")\(files.isEmpty ? "" : "; the other attachments are the files made in it")\(rest). Read it, confirm in two or three sentences the goal, where things stand and the next step, then wait for me. From now on, treat this as the same conversation.")
                switch d.startChat(with: text, files: [note.url] + files, title: note.title) {
                case .made(let newID):
                    done += 1
                    DispatchQueue.main.sync { MainActor.assumeIsolated { self?.adopt(old: note.id, new: newID, title: note.title) } }
                case .failed:
                    failed.append(note.title)
                case .leftOver:
                    // what was put in Claude's message box may still be there: the next chat would send it along
                    failed.append(note.title)
                    halted = tr("已停下：Claude 的输入框里可能还留着「\(note.title)」的总结和文件，清掉再导入", "stopped: Claude's message box may still hold \"\(note.title)\"'s summary and files; clear it, then import again")
                case .notEmpty:
                    halted = tr("没开始：Claude 新对话的输入框里有东西（草稿？），清掉再导入", "not started: Claude's new-chat box isn't empty (a draft?); clear it, then import again")
                }
                if halted != nil { break }
            }
            d.restoreClipboard(clip)
            let why = halted
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self = self else { return }
                self.busy = false; self.importing = false
                self.progress = ""
                var s = tr("导入了 \(done) 个", "\(done) imported")
                if !failed.isEmpty { s += tr(" · \(failed.count) 个失败（看 logs/archive.log）", " · \(failed.count) failed (see logs/archive.log)") }
                if stop.isSet { s += tr(" · 中途停止", " · stopped") }
                if let w = why {
                    s += " · " + w
                    Permissions.alert(tr("导入停下了", "Import stopped"), w)
                }
                Archive.lastResult = Clock.format(Date(), "M/d HH:mm", "MMM d HH:mm") + " · " + s
                self.log("\(Clock.iso()) import end · \(s)")
                self.onChange?()
            } }
        }
    }

    private func adopt(old: String, new: String, title: String) {
        state.imported[old] = new
        if let r = state.summaries[old] { state.summaries[new] = r }
        saveState()
        store.addImported(id: new, title: title)
        if store.map.placedChats().contains(old) { store.map.renameChat(old, to: new) }
        store.notify()
    }
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
/// reply. Every call blocks — run it off the main thread.
final class ClaudeDriver: @unchecked Sendable {
    /// `unreadable`: Claude's chat page isn't one the driver knows how to read (no use trying the next chat).
    enum Result { case done(String, Int), unchanged, failed(String), unreadable(String) }

    let pid: pid_t
    let stop: StopFlag
    let log: (String) -> Void
    private let app: AXUIElement

    init(pid: pid_t, stop: StopFlag, log: @escaping (String) -> Void) {
        self.pid = pid
        self.stop = stop
        self.log = log
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3.0)
    }

    // MARK: one chat

    func summarize(id: String, title: String, prompt: String, lastCount: Int?) -> Result {
        guard open(id: id, title: title) else { return .failed(tr("打不开这个对话", "couldn't open the chat")) }
        guard wait(12, { self.lastMessage() != nil }) else {
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
        guard type(prompt) else { return .failed(tr("找不到输入框", "couldn't find the message box")) }
        guard send() else { return .failed(tr("发不出去", "couldn't send")) }
        guard waitReply(after: before) else { return .failed(stop.isSet ? tr("停止了", "stopped") : tr("等回复超时", "no reply in time")) }
        guard let text = copyLast() else { return .failed(tr("复制不到回复", "couldn't copy the reply")) }
        return .done(text, messageCount())
    }

    /// A new chat with `files` attached and `text` as its first message; pinned and renamed to `title`.
    /// Returns its id.
    /// What became of a chat Import started.
    enum Start { case made(String), failed, leftOver, notEmpty }

    /// A new chat whose first message is `text`, with `files` attached.
    func startChat(with text: String, files: [URL], title: String) -> Start {
        guard newChat() else { log(tr("  开不了新对话", "  couldn't start a new chat")); return .failed }
        // the box must start empty: anything there (a draft of yours) would be sent along
        guard !hasDraft(), !canSend() else { log(tr("  新对话的输入框里有东西", "  the new chat's box isn't empty")); return .notEmpty }
        if !files.isEmpty {
            // landed: the files make Send usable (it waits while they upload)
            guard attach(files), wait(20, { self.canSend() }) else { log(tr("  文件没附上", "  the files weren't attached")); return .leftOver }
            log(tr("  附上 \(files.count) 个文件", "  attached \(files.count) files"))
        }
        guard type(text) else { log(tr("  找不到输入框", "  couldn't find the message box")); return files.isEmpty ? .failed : .leftOver }
        guard send() else { log(tr("  发不出去", "  couldn't send")); return .leftOver }
        guard wait(30, { self.chatID() != nil }), let id = chatID() else { log(tr("  新对话没有地址", "  the new chat has no address")); return .leftOver }
        guard waitReply(after: 0) else { log(tr("  等回复超时（对话已建好：\(id)）", "  no reply in time (the chat was made: \(id))")); return .made(id) }
        // Claude names the chat after the first reply
        _ = wait(20) { let t = self.pageTitle(); return !t.isEmpty && !ClaudeWords.untitled.contains(t) }
        let auto = pageTitle()
        if !pin(rowTitle: auto) { log(tr("  置顶失败（\(auto)）", "  couldn't pin it (\(auto))")) }
        pause(1)
        if !rename(rowTitle: auto, to: title) { log(tr("  改名失败，现在叫「\(auto)」", "  couldn't rename it: it's called \"\(auto)\"")) }
        log(tr("  已导入 → ", "  imported → ") + id)
        return .made(id)
    }

    // MARK: steps

    func open(title: String) -> Bool {
        if pageTitle() == title { return true }
        guard AXScan.press(pid: pid, title: title) else { return false }
        return wait(15) { self.pageTitle() == title }
    }

    /// By its address (exact: another chat may have the same title); one known only by its title, by its row in the
    /// sidebar.
    func open(id: String, title: String) -> Bool {
        guard Archive.isAddress(id) else { return open(title: title) }
        if chatID() == id { return true }
        guard let u = URL(string: "claude://claude.ai/chat/" + id) else { return false }
        DispatchQueue.main.sync { _ = NSWorkspace.shared.open(u) }
        return wait(20) { self.chatID() == id }
    }

    /// Pastes files into the message box as attachments.
    func attach(_ files: [URL]) -> Bool {
        guard let w = web(), let box = composer(w) else { return false }
        activate()
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pause(0.4)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(files as [NSURL])
        ownChange = pb.changeCount
        command("v")                                              // ⌘V
        pause(2.5 + 0.4 * Double(files.count))                    // let them upload
        return true
    }

    func type(_ text: String) -> Bool {
        guard let w = web(), let box = composer(w) else { return false }
        activate()
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pause(0.4)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ownChange = pb.changeCount
        let sendable = canSend()
        command("v")                                              // ⌘V
        pause(1.2)
        // it landed (else nothing is sent, rather than an empty message waited on for minutes): in the box, or, for a
        // long text, as the "Pasted text" attachment Claude makes of it, which makes Send usable
        let start = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        return wait(3) { (self.web().flatMap { self.composer($0) }.map { AXScan.str($0, "AXValue").contains(start) } ?? false) || (!sendable && self.canSend()) }
    }

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
            pause(2)
            if messageCount() < before + 2 || busy() { steady = 0; continue }
            guard let m = lastMessage(), isClaude(m), copyButton(m) != nil else { steady = 0; continue }
            steady += 1
            if steady >= 2 { return true }
        }
        return false
    }

    /// The newest reply as Markdown (through its Copy button), or its plain text.
    func copyLast() -> String? {
        guard let w = web(), let m = lastMessage(in: w), isClaude(m) else { return nil }
        let pb = NSPasteboard.general
        if let b = copyButton(m) {
            activate()
            let before = pb.changeCount
            AXUIElementPerformAction(b, kAXPressAction as CFString)
            if wait(4, { pb.changeCount != before }), let s = pb.string(forType: .string),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ownChange = pb.changeCount; return s }
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
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(title, forType: .string)
        ownChange = pb.changeCount
        command("a")                                              // ⌘A
        command("v")                                              // ⌘V
        pause(0.4)
        if let w = web(), let save = button(w, prefixes: ClaudeWords.save, anywhere: true) {
            AXUIElementPerformAction(save, kAXPressAction as CFString)
        } else {
            key(36)
        }
        return wait(8) { self.pageTitle() == title }
    }

    /// Opens the "More options for …" menu of a sidebar row and picks an item.
    private func menu(rowTitle: String, items: Set<String>) -> Bool {
        guard let w = web(), let sb = AXScan.sidebar(in: w),
              let more = find(sb, first: true, skipSidebar: false, { el in
                  AXScan.str(el, "AXRole") == "AXPopUpButton" && AXScan.knownMenus.contains { $0.replacingOccurrences(of: "{label}", with: rowTitle) == AXScan.str(el, "AXDescription") }
              }).first else { return false }
        activate()
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

    /// The message feed is there (else Claude's window isn't one Kikumap knows how to read).
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

    private func activate() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
            pause(0.6)
        }
    }

    /// ⌘ and a letter, on whichever key types that letter with ⌘ in the keyboard layout in use (on a French
    /// keyboard the US "A" position is "Q": ⌘Q would quit Claude). Not found: nothing is pressed.
    private func command(_ letter: Character) {
        guard let code = DispatchQueue.main.sync(execute: { ClaudeDriver.keyCode(typing: letter) }) else {
            log(tr("  键盘布局读不了，没按 ⌘\(letter.uppercased())", "  couldn't read the keyboard layout: ⌘\(letter.uppercased()) not pressed"))
            return
        }
        key(code, cmd: true)
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
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            if cmd { e.flags = .maskCommand }
            e.postToPid(pid)
            pause(0.04)
        }
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

    private func pause(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }

    // MARK: clipboard (put back when done)

    func saveClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
    }

    /// The clipboard as Kikumap last left it: put back only if it's still that (whatever you copied meanwhile stays).
    private var ownChange: Int?

    func restoreClipboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        guard let own = ownChange, pb.changeCount == own else { return }
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { d in
            let it = NSPasteboardItem()
            for (t, v) in d { it.setData(v, forType: t) }
            return it
        })
    }
}
