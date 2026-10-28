import Cocoa

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
    }
    /// One chat to export and the folder it goes in.
    struct Item { let id: String; let title: String; let dir: URL; let isCode: Bool }

    let store: Store
    var pid: () -> pid_t = { 0 }
    var onChange: (() -> Void)?
    private var state = State()
    private let stop = StopFlag()

    private(set) var busy = false
    private(set) var progress = ""                    // "3/12 · title"

    private var stateURL: URL { store.dir.appendingPathComponent("data/archive.json") }

    init(store: Store) {
        self.store = store
        if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: d) { state = s }
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
        set { d.set(newValue.path, forKey: "ArchiveFolder") }
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
        let map = store.map
        var out: [Item] = []
        var seen = Set<String>()
        var usedDirs = Set<String>()
        func add(_ id: String, _ path: [String]) {
            guard !seen.contains(id), let c = store.chat(id) else { return }
            seen.insert(id)
            var dir = path.reduce(Archive.folder) { $0.appendingPathComponent(ClaudeExport.safeName($1)) }
                .appendingPathComponent(ClaudeExport.safeName(store.name(id)))
            if usedDirs.contains(dir.path) { dir = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + " " + String(id.suffix(6))) }
            usedDirs.insert(dir.path)
            out.append(Item(id: id, title: c.title, dir: dir, isCode: c.isCode))
        }
        func walk(_ n: MapNode, _ path: [String], _ on: Bool) {
            for ch in n.children {
                switch ch {
                case .chat(let id): if on { add(id, path) }
                case .node(let s): walk(s, path + [s.title.isEmpty ? tr("新主题", "New topic") : s.title], on || topics?.contains(s.id) ?? true)
                }
            }
        }
        walk(map.root, [], topics == nil || topics!.contains(map.root.id))
        if unplaced {
            let placed = map.placedChats()
            for c in store.pinnedList() where !placed.contains(c.id) { add(c.id, [tr("未归类", "Unfiled")]) }
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
            Item(id: id, title: $0.title, dir: Archive.folder.appendingPathComponent(tr("未归类", "Unfiled")).appendingPathComponent(ClaudeExport.safeName(store.name(id))), isCode: $0.isCode)
        }) else { return }
        export([it], memory: true, zip: nil, force: true, scheduled: false)
    }

    func cancel() { stop.set(true) }

    /// Every few minutes. With automatic updates on: a new Claude export zip in Downloads updates the
    /// files right away; the summaries are brought up to date when they're due and the Mac is idle.
    func tick() {
        guard Archive.auto, !busy else { return }
        if Archive.withFiles, let z = ClaudeExport.newestZip(), zipKey(z) != state.zipDone {
            export(items(topics: Archive.topics, unplaced: Archive.withUnplaced), memory: false, zip: z, force: false, scheduled: true)
            return
        }
        guard Archive.withMemory, pid() != 0, AXIsProcessTrusted() else { return }
        let due = (Archive.lastRun.map { Date().timeIntervalSince($0) } ?? .infinity) >= Double(Archive.everyDays) * 86400 - 600
        guard due, Archive.idleSeconds() >= 600 else { return }
        exportSaved(scheduled: true, memory: true)
    }

    private func zipKey(_ z: URL) -> String { z.path + "|" + String(Int(ClaudeExport.modified(z).timeIntervalSince1970)) }

    nonisolated static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    func export(_ list: [Item], memory: Bool, zip: URL?, force: Bool, scheduled: Bool) {
        guard !busy else { return }
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
                    for it in list where !it.isCode {
                        guard let c = all[it.id.lowercased()] ?? byName[it.title] else { r.notInZip += 1; continue }
                        do { try ClaudeExport.write(c, title: it.title, to: it.dir); r.files += 1; r.artifacts += c.artifacts.count }
                        catch { log("  \(it.title): \(error.localizedDescription)") }
                    }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.markZip(z) } }
                } else {
                    r.zipFailed = true
                    log("  导出包读不了：\(z.path)")
                }
            }
            // 2. the hand-off summaries, written by Claude in each chat
            if memory && canDrive {
                let d = ClaudeDriver(pid: p, stop: stop, log: log)
                let clip = d.saveClipboard()
                let back = d.pageTitle()
                let todo = list.filter { !$0.isCode }
                for (n, it) in todo.enumerated() {
                    if stop.isSet || (scheduled && Archive.idleSeconds() < 3 && n > 0) { break }
                    if skip.contains(it.id) { r.skipped += 1; continue }
                    // nothing new since the last summary (the app saw no activity)
                    if !force, let when = done[it.id], let u = updated[it.id], !u.isEmpty, u <= when { r.skipped += 1; continue }
                    say("\(n + 1)/\(todo.count) · \(it.title)")
                    log("— \(it.title)")
                    switch d.summarize(id: it.id, title: it.title, prompt: prompt, lastCount: force ? nil : counts[it.id]) {
                    case .done(let text, let count):
                        let ok = DispatchQueue.main.sync { MainActor.assumeIsolated { self?.saveMemory(it, text: text, messages: count) ?? false } }
                        if ok { r.memory += 1 } else { r.failed += 1 }
                    case .unchanged: r.skipped += 1; log("  没有新内容，跳过")
                    case .failed(let why): r.failed += 1; log("  失败：\(why)")
                    }
                }
                if !back.isEmpty && !stop.isSet { _ = d.open(title: back) }
                d.restoreClipboard(clip)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(r, list: list) } }
        }
    }

    private struct Report {
        var files = 0, artifacts = 0, notInZip = 0, memory = 0, skipped = 0, failed = 0
        var zipFailed = false
    }

    private func markZip(_ z: URL) { state.zipDone = zipKey(z); saveState() }

    private func finish(_ r: Report, list: [Item]) {
        busy = false
        progress = ""
        Archive.lastRun = Date()
        var parts: [String] = []
        if r.files > 0 { parts.append(tr("\(r.files) 个对话的提示词和全文，\(r.artifacts) 个 artifact", "\(r.files) chats' prompts and text, \(r.artifacts) artifacts")) }
        if r.memory > 0 { parts.append(tr("\(r.memory) 份总结", "\(r.memory) summaries")) }
        if r.skipped > 0 { parts.append(tr("\(r.skipped) 个跳过（没变化、未读或在跑）", "\(r.skipped) skipped (unchanged, unread or running)")) }
        if r.notInZip > 0 { parts.append(tr("\(r.notInZip) 个不在导出包里（导出包比对话旧？）", "\(r.notInZip) not in the export zip (older than the chat?)")) }
        if r.failed > 0 { parts.append(tr("\(r.failed) 个失败（看 logs/archive.log）", "\(r.failed) failed (see logs/archive.log)")) }
        if r.zipFailed { parts.append(tr("导出包读不了", "couldn't read the export zip")) }
        if stop.isSet { parts.append(tr("中途停止", "stopped")) }
        let s = Clock.format(Date(), "M/d HH:mm", "MMM d HH:mm") + " · " + (parts.isEmpty ? tr("没有要更新的", "nothing to update") : parts.joined(separator: " · "))
        Archive.lastResult = s
        log("\(Clock.iso()) end · \(s)")
        writeIndex(list)
        onChange?()
    }

    // MARK: files

    private func saveMemory(_ it: Item, text: String, messages: Int) -> Bool {
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
        do {
            try FileManager.default.createDirectory(at: it.dir, withIntermediateDirectories: true)
            try (head + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log("  写文件失败：\(error.localizedDescription)")
            return false
        }
        let rel = String(url.path.dropFirst(Archive.folder.path.count + 1))
        state.summaries[it.id] = Record(date: Clock.iso(), messages: messages, file: rel)
        saveState()
        log("  已存：\(rel)")
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
        try? s.write(to: root.appendingPathComponent(tr("索引.md", "Index.md")), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: root.appendingPathComponent("map.json"))
        try? fm.copyItem(at: store.map.url, to: root.appendingPathComponent("map.json"))
    }

    private func saveState() {
        if let d = try? JSONEncoder().encode(state) { try? d.write(to: stateURL, options: .atomic) }
    }

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

    struct Note { let url: URL; let id: String; let title: String; let body: String; let files: [URL] }

    /// The summaries under a folder (memory.md files, or older single .md files with front matter that
    /// has an id), each with the artifacts next to it.
    nonisolated static func notes(in folder: URL) -> [Note] {
        let fm = FileManager.default
        let all = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return all.filter { $0.pathExtension == "md" && !["prompts.md", "conversation.md"].contains($0.lastPathComponent) }.compactMap { url in
            guard let s = try? String(contentsOf: url, encoding: .utf8), s.hasPrefix("---\n"),
                  let end = s.range(of: "\n---\n", range: s.index(s.startIndex, offsetBy: 4)..<s.endIndex) else { return nil }
            var id = "", title = ""
            for line in s[s.index(s.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                if parts[0] == "id" { id = parts[1] }
                if parts[0] == "title" {
                    var t = parts[1]
                    if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"") }
                    title = t
                }
            }
            guard !id.isEmpty, !title.isEmpty else { return nil }
            var files: [URL] = []
            if url.lastPathComponent == "memory.md" {
                let arts = url.deletingLastPathComponent().appendingPathComponent("artifacts")
                files = ((try? fm.contentsOfDirectory(at: arts, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                    .filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < 5_000_000 }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                files = Array(files.prefix(20))
            }
            return Note(url: url, id: id, title: title, body: String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), files: files)
        }.sorted { $0.title < $1.title }
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
            for (n, note) in notes.enumerated() {
                if stop.isSet { break }
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self?.progress = tr("导入 ", "Import ") + "\(n + 1)/\(notes.count) · \(note.title)"
                    self?.onChange?()
                } }
                d.log("— \(note.title)")
                let text = tr("【接续之前的对话】下面是我之前一个对话的交接总结（原标题：\(note.title)）\(note.files.isEmpty ? "" : "，附件是那个对话里做出的文件")。请先读完，用两三句话确认你理解的目标、进度和下一步，然后等我继续。从现在起就当作是同一个对话。",
                              "[Continuing an earlier chat] Below is the hand-off summary of a previous conversation (titled \"\(note.title)\")\(note.files.isEmpty ? "" : "; the attachments are the files made in it"). Read it, confirm in two or three sentences the goal, where things stand and the next step, then wait for me. From now on, treat this as the same conversation.")
                    + "\n\n" + note.body
                if let newID = d.startChat(with: text, files: note.files, title: note.title) {
                    done += 1
                    DispatchQueue.main.sync { MainActor.assumeIsolated { self?.adopt(old: note.id, new: newID, title: note.title) } }
                } else {
                    failed.append(note.title)
                }
            }
            d.restoreClipboard(clip)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self = self else { return }
                self.busy = false
                self.progress = ""
                var s = tr("导入了 \(done) 个", "\(done) imported")
                if !failed.isEmpty { s += tr(" · \(failed.count) 个失败（看 logs/archive.log）", " · \(failed.count) failed (see logs/archive.log)") }
                if stop.isSet { s += tr(" · 中途停止", " · stopped") }
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

/// Works the Claude app's chat page through Accessibility: open a chat, type, send, wait, copy the
/// reply. Every call blocks — run it off the main thread.
final class ClaudeDriver: @unchecked Sendable {
    enum Result { case done(String, Int), unchanged, failed(String) }

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
        guard open(id: id, title: title) else { return .failed("打不开这个对话") }
        guard wait(12, { self.lastMessage() != nil }) else { return .failed("对话内容没加载出来") }
        pause(1.2)
        if busy() { return .failed("正在跑，下次再存") }
        let before = messageCount()
        if let c = lastCount, c == before { return .unchanged }
        if hasDraft() { return .failed("输入框里有你还没发的草稿，没动它") }
        guard type(prompt) else { return .failed("找不到输入框") }
        guard send() else { return .failed("发不出去") }
        guard waitReply(after: before) else { return .failed(stop.isSet ? "停止了" : "等回复超时") }
        guard let text = copyLast() else { return .failed("复制不到回复") }
        return .done(text, messageCount())
    }

    /// A new chat with `files` attached and `text` as its first message; pinned and renamed to `title`.
    /// Returns its id.
    func startChat(with text: String, files: [URL], title: String) -> String? {
        guard newChat() else { log("  开不了新对话"); return nil }
        if !files.isEmpty {
            if attach(files) { log("  附上 \(files.count) 个文件") } else { log("  文件没附上") }
        }
        guard type(text) else { log("  找不到输入框"); return nil }
        guard send() else { log("  发不出去"); return nil }
        guard wait(30, { self.chatID() != nil }) else { log("  新对话没有地址"); return nil }
        let id = chatID()!
        guard waitReply(after: 0) else { log("  等回复超时（对话已建好：\(id)）"); return id }
        // Claude names the chat after the first reply
        _ = wait(20) { let t = self.pageTitle(); return !t.isEmpty && t != "Claude" && t != "New chat" }
        let auto = pageTitle()
        if !pin(rowTitle: auto) { log("  置顶失败（\(auto)）") }
        pause(1)
        if !rename(rowTitle: auto, to: title) { log("  改名失败，现在叫「\(auto)」") }
        log("  已导入 → \(id)")
        return id
    }

    // MARK: steps

    func open(title: String) -> Bool {
        if pageTitle() == title { return true }
        guard AXScan.press(pid: pid, title: title) else { return false }
        return wait(15) { self.pageTitle() == title }
    }

    /// By its row in the sidebar, or — for a chat that isn't there (not pinned, not recent) — by its address.
    func open(id: String, title: String) -> Bool {
        let uuid = id.range(of: "^[0-9a-f-]{36}$", options: .regularExpression) != nil
        if (uuid && chatID() == id) || pageTitle() == title { return true }
        if AXScan.press(pid: pid, title: title) { return wait(15) { self.pageTitle() == title || (uuid && self.chatID() == id) } }
        guard uuid, let u = URL(string: "claude://claude.ai/chat/" + id) else { return false }
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
        key(9, cmd: true)                                         // ⌘V
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
        key(9, cmd: true)                                         // ⌘V
        pause(1.2)
        return true
    }

    /// Something you typed and haven't sent yet.
    func hasDraft() -> Bool {
        guard let w = web(), let box = composer(w) else { return false }
        return !AXScan.str(box, "AXValue").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() -> Bool {
        if let w = web(), let b = button(w, prefixes: ["Send"]), AXScan.str(b, "AXEnabled") != "0" {
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
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            log("  Copy 按钮没反应，改用纯文本")
        }
        let t = plainText(m)
        return t.isEmpty ? nil : t
    }

    func newChat() -> Bool {
        guard let w = web(), let sb = AXScan.sidebar(in: w) else { return false }
        let names: Set<String> = ["New chat", "New", "新对话", "新聊天", "新建"]
        guard let b = find(sb, first: true, skipSidebar: false, { el in
            AXScan.str(el, "AXRole") == "AXButton" && (names.contains(AXScan.str(el, "AXTitle")) || names.contains(AXScan.str(el, "AXDescription")))
        }).first else { return false }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
        return wait(10) { self.chatID() == nil && self.web().flatMap { self.composer($0) } != nil }
    }

    func pin(rowTitle: String) -> Bool { menu(rowTitle: rowTitle, items: ["Pin", "Pin chat", "置顶"]) }

    func rename(rowTitle: String, to title: String) -> Bool {
        if rowTitle == title { return true }
        guard menu(rowTitle: rowTitle, items: ["Rename", "重命名"]) else { return false }
        pause(0.8)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(title, forType: .string)
        key(0, cmd: true)                                         // ⌘A
        key(9, cmd: true)                                         // ⌘V
        pause(0.4)
        if let w = web(), let save = button(w, prefixes: ["Save", "保存"], anywhere: true) {
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
                  AXScan.str(el, "AXRole") == "AXPopUpButton" && AXScan.str(el, "AXDescription") == "More options for " + rowTitle
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

    func chatID() -> String? {
        guard let w = web() else { return nil }
        let url = AXScan.str(w, "AXURL"), ns = url as NSString
        guard url.contains("/chat/") else { return nil }
        return AXScan.uuidRx.firstMatch(in: url, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
    }

    private func messagesGroup(_ w: AXUIElement) -> AXUIElement? {
        find(w, first: true, skipSidebar: true, { el in
            AXScan.str(el, "AXSubrole") == "AXApplicationGroup" && AXScan.str(el, "AXDescription") == "Chat messages"
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
        if let d = ms.last.map({ AXScan.str($0, "AXDescription") }),
           let r = d.range(of: #"of (\d+)"#, options: .regularExpression),
           let n = Int(d[r].dropFirst(3)) { return n }
        return ms.count
    }

    func isClaude(_ m: AXUIElement) -> Bool {
        let h = find(m, first: true, skipSidebar: false, limit: 50, { AXScan.str($0, "AXRole") == "AXHeading" }).first
        return !(h.map { AXScan.str($0, "AXTitle") } ?? "").hasPrefix("You said")
    }

    private func copyButton(_ m: AXUIElement) -> AXUIElement? {
        find(m, first: true, skipSidebar: false, backwards: true, { el in
            AXScan.str(el, "AXRole") == "AXButton" && AXScan.str(el, "AXDescription") == "Copy"
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
        return button(w, prefixes: ["Stop"]) != nil
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
                if skipMessages && sub == "AXApplicationGroup" && AXScan.str(el, "AXDescription") == "Chat messages" { continue }
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

    func restoreClipboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { d in
            let it = NSPasteboardItem()
            for (t, v) in d { it.setData(v, forType: t) }
            return it
        })
    }
}
