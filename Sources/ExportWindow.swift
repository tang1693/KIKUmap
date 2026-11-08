import Cocoa

/// Export: pick topics (every chat under them, pinned or not), pick what to include, export them all
/// at once — and optionally keep the export up to date on its own.
@MainActor
final class ExportWindow: NSObject, NSWindowDelegate {
    let store: Store
    let archive: Archive
    var onImport: (() -> Void)?
    /// Asks before Claude is made to write in the chats: how many, and whether it's to do so again on the schedule,
    /// while you're away. False = cancelled (not set: nothing is asked of Claude).
    var confirmMemory: ((Int, Bool) -> Bool)?
    /// Asks whether to export just the files while Claude can't write summaries (a test stands in for the alert).
    var confirmFilesOnly: (() -> Bool)?

    private var window: NSWindow?
    private var checks: [(NSButton, String)] = []
    private var unplaced: NSButton?
    private var memory: NSButton?
    private var files: NSButton?
    private var auto: NSButton?
    private var every: NSPopUpButton?
    private var autoNote: NSTextField?
    private var zipLabel: NSTextField?
    private var folderLabel: NSTextField?
    private var zip: URL?
    /// A folder picked with Change…, kept with the other choices when the export starts.
    private var folder: URL?

    init(store: Store, archive: Archive) {
        self.store = store
        self.archive = archive
        super.init()
    }

    /// (While an export or import runs, nothing else can start: that's said instead, as Settings greys its buttons.)
    func show() {
        if let why = archive.busyNote { Archive.say(why.title, why.text); return }
        window?.orderOut(nil)
        build()
        Front.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ s: String, small: Bool = false, bold: Bool = false, width: CGFloat = 500) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = bold ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: small ? 11.5 : 13)
        l.textColor = small ? .secondaryLabelColor : .labelColor
        l.preferredMaxLayoutWidth = width
        return l
    }

    private func check(_ title: String, _ on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        return b
    }

    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = .firstBaseline
        return s
    }

    private func build() {
        checks = []
        folder = nil
        let map = store.map
        let chosen = Archive.topics
        // the topics, indented, each with how many chats sit under it
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        // (only Claude chats are exported: ChatGPT chats and Claude Code or Codex sessions aren't counted)
        func claude(_ id: String) -> Bool { store.chat(id)?.outsideClaude == false }
        func count(_ n: MapNode) -> Int {
            var c = 0
            map.walkChats(n) { if claude($0) { c += 1 } }
            return c
        }
        let known = Archive.knownTopics
        func add(_ n: MapNode, _ depth: Int, parentOn: Bool = false) {
            for ch in n.children {
                guard let s = ch.node else { continue }
                // (a topic added since the choice was saved follows its parent, as the export does)
                let on = chosen == nil || chosen!.contains(s.id) || (known?.contains(s.id) != true && parentOn)
                let b = check((s.title.isEmpty ? tr("新主题", "New topic") : s.title) + "  ·  \(count(s))", on)
                let wrap = NSStackView(views: [b])
                wrap.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(depth) * 20, bottom: 0, right: 0)
                list.addArrangedSubview(wrap)
                checks.append((b, s.id))
                add(s, depth + 1, parentOn: on)
            }
        }
        add(map.root, 0)
        // chats dropped right on the map, not in a topic: a box of their own
        let onMap = map.root.children.compactMap { $0.chatId }.filter(claude).count
        if onMap > 0 {
            let b = check(tr("直接放在导图上的对话（不在主题里）", "Chats right on the map (not in a topic)") + "  ·  \(onMap)", chosen == nil || chosen!.contains(map.root.id))
            list.addArrangedSubview(b)
            checks.append((b, map.root.id))
        }
        let placed = map.placedChats()
        let loose = store.pinnedList().filter { !placed.contains($0.id) && !$0.outsideClaude }.count
        // there are some of those others, on the map or pinned: said under the list's heading
        let others = placed.contains { store.chat($0)?.outsideClaude == true } || store.pinnedList().contains(where: \.outsideClaude)
        let un = check(tr("没放进导图的置顶对话", "Pinned chats not on the map") + "  ·  \(loose)", Archive.withUnplaced)
        unplaced = un
        list.addArrangedSubview(un)
        if !map.root.children.contains(where: { $0.node != nil }) {
            list.addArrangedSubview(label(tr("导图上还没有主题。", "No topics on the map yet."), small: true))
        }
        let doc = FlippedStack(frame: .zero)
        doc.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),
            doc.widthAnchor.constraint(equalToConstant: 470),
        ])
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        let all = ClosureButton(title: tr("全选", "All")) { [weak self] in self?.checks.forEach { $0.0.state = .on }; self?.unplaced?.state = .on }
        let none = ClosureButton(title: tr("全不选", "None")) { [weak self] in self?.checks.forEach { $0.0.state = .off }; self?.unplaced?.state = .off }
        [all, none].forEach { $0.controlSize = .small; $0.bezelStyle = .rounded }

        // what goes in each chat's folder
        // (unticked, it's off at once, Cancel or not, and Claude writes no more summaries on the schedule: stopping needs
        // no yes. Ticked, it waits for Export, and for your yes to Claude writing them)
        let mem = ClosureCheck(title: tr("memory.md：让 Claude 写一份交接总结", "memory.md — a hand-off summary Claude writes"), on: Archive.withMemory) { [weak self] on in
            if !on { Archive.withMemory = false; Archive.autoMemoryAgreed = false }
            self?.updateAutoNote()
        }
        memory = mem
        let memNote = label(tr("每个对话会多一轮问答，用掉一点额度。运行时 Claude 窗口会自己切换对话。没变化、未读、在跑的对话会跳过。",
                               "Each chat gets one more exchange, which uses a little quota. The Claude window switches chats while it runs. Unchanged, unread and running chats are skipped.")
                            + "\n" + tr(AppDelegate.summaryClipboard.zh + "。", AppDelegate.summaryClipboard.en + "."), small: true, width: 470)
        // (kept when the export starts, like the topics; the note under "Keep it updated" follows it at once)
        let fil = ClosureCheck(title: tr("提示词、完整对话、全部 artifacts 和附件", "Prompts, the whole conversation, every artifact and attachment"), on: Archive.withFiles) { [weak self] _ in
            self?.updateAutoNote()
        }
        files = fil
        zip = ClaudeExport.newestZip()
        let zl = label("", small: true, width: 470)
        zipLabel = zl
        updateZip()
        let pick = ClosureButton(title: tr("选择 zip…", "Choose zip…")) { [weak self] in
            let p = NSOpenPanel()
            p.allowedContentTypes = [.zip]
            p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            guard p.runModal() == .OK, let u = p.url else { return }
            self?.zip = u
            self?.updateZip()
        }
        pick.controlSize = .small
        let how = ClosureButton(title: tr("怎么拿到？", "How do I get it?")) {
            Permissions.alert(tr("Claude 官方导出包", "Claude's data export"),
                              tr("在 Claude 里：设置 → 隐私 → 导出数据。几分钟后，你会收到一封带下载链接的邮件。下载后点「选择 zip…」选它。KIKUmap 有完全磁盘访问的话，放在「下载」里就会自己找到。\n\n完整的提示词、对话和 artifact 只有这个导出包里有。开了完全磁盘访问和「自动更新」后，以后每次下载新的导出包，文件都会自己更新。",
                                 "In Claude: Settings → Privacy → Export data. A few minutes later you get an email with a download link. Download the zip, then click \"Choose zip…\" and pick it. If KIKUmap has Full Disk Access, a zip in Downloads is found by itself.\n\nOnly this export has the full prompts, conversations and artifacts. With Full Disk Access and \"Keep it updated\" on, each new export you download updates the files by itself."))
        }
        how.controlSize = .small

        // where, and how often
        let fl = label(Archive.folder.path, small: true, width: 360)
        folderLabel = fl
        let change = ClosureButton(title: tr("更改…", "Change…")) { [weak self] in
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.canCreateDirectories = true
            p.directoryURL = (self?.folder ?? Archive.folder).deletingLastPathComponent()
            guard p.runModal() == .OK, let u = p.url else { return }
            self?.folder = u
            self?.folderLabel?.stringValue = u.path
        }
        change.controlSize = .small
        // without Full Disk Access, macOS asks before an app may write into Documents, Desktop or Downloads, or onto an
        // external or network disk (for a folder picked here, maybe only after KIKUmap restarts)
        let folderNote = label(Archive.asksNote ?? "", small: true, width: 470)
        folderNote.isHidden = Archive.asksNote == nil
        // on or off at once, Cancel or not. On, it keeps the files up to date by itself (no Claude, so no yes needed;
        // summaries on the schedule wait for Export and your yes). Off, it stops, and that yes goes with it
        let auto = ClosureCheck(title: tr("自动更新", "Keep it updated"), on: Archive.auto) { [weak self] on in
            Archive.auto = on
            if !on { Archive.autoMemoryAgreed = false }
            self?.updateAutoNote()
        }
        self.auto = auto
        // (how often is kept when the export starts, like the other choices: it's part of what you say yes to)
        let every = NSPopUpButton(frame: .zero, pullsDown: false)
        every.addItems(withTitles: [tr("每天", "daily"), tr("每周", "weekly"), tr("每月", "monthly")])
        every.selectItem(at: Archive.everyChoices.firstIndex(of: Archive.everyDays) ?? 1)
        every.controlSize = .small
        self.every = every
        let autoNote = label("", small: true, width: 470)
        self.autoNote = autoNote
        updateAutoNote()

        let imp = ClosureButton(title: tr("导入到当前账号…", "Import into this account…")) { [weak self] in
            // (a run under way: said, and this window stays as it is)
            if let why = self?.archive.busyNote { Archive.say(why.title, why.text); return }
            self?.window?.close(); self?.onImport?()
        }
        let cancel = ClosureButton(title: tr("取消", "Cancel")) { [weak self] in self?.window?.close() }
        cancel.keyEquivalent = "\u{1b}"
        let go = ClosureButton(title: tr("导出", "Export")) { [weak self] in self?.start() }
        go.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [imp, spacer, cancel, go])
        bottom.orientation = .horizontal
        bottom.widthAnchor.constraint(equalToConstant: 500).isActive = true

        let indent = { (v: NSView) -> NSView in
            let s = NSStackView(views: [v]); s.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0); return s
        }
        let stack = NSStackView(views: [
            label(tr("选主题：主题下的 Claude 对话都会导出，置顶的和没置顶的都算。每个对话一个文件夹。", "Pick topics. Every Claude chat under them is exported, pinned or not, each in a folder of its own.")
                  + (others ? tr("ChatGPT 对话和 Claude Code、Codex 会话不导出，数字里也不算。", " ChatGPT chats and Claude Code or Codex sessions aren't exported or counted.") : ""), width: 500),
            scroll, row([all, none]),
            label(tr("每个文件夹里放", "Each folder holds"), bold: true),
            mem, indent(memNote),
            fil, indent(zl), indent(row([pick, how])),
            label(tr("存到", "Save to"), bold: true),
            row([fl, change]), indent(folderNote),
            row([auto, every]), indent(autoNote),
            bottom,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[2])
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[8])
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[13])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // (the window grows and shrinks with the note under "Keep it updated", which changes as it's ticked)
        stack.setHuggingPriority(NSLayoutConstraint.Priority(rawValue: 501), for: .vertical)

        let vc = NSViewController()
        vc.view = NSView()
        vc.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: vc.view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
            vc.view.widthAnchor.constraint(equalToConstant: 548),
        ])
        let w = NSWindow(contentViewController: vc)
        w.styleMask = [.titled, .closable]
        w.title = tr("导出对话", "Export chats")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
    }

    /// The note under "Keep it updated": what it keeps up to date, as the boxes above are checked now (unchecked, that
    /// isn't updated), and when; on, with summaries checked, but no yes yet for Claude writing them while you're away
    /// (just checked, or Claude was closed at the last export) — only the files for now.
    private func updateAutoNote() {
        let withFiles = files?.state == .on, withMemory = memory?.state == .on
        let notYet = auto?.state == .on && withMemory && !Archive.autoMemoryAgreed
        var said: [String] = []
        if withFiles { said.append(tr("开了完全磁盘访问的话，「下载」里一有新的导出包，文件就马上更新。", "With Full Disk Access, a new export zip in Downloads updates the files right away.")) }
        // (when they're due, Claude must be open, with Accessibility on: else they wait until it is)
        if withMemory { said.append(tr("总结按选的频率更新：要 Mac 闲置 10 分钟以上，而且 Claude App 开着、「辅助功能」也开着时才写。",
                                       "Summaries are updated on this schedule, once the Mac has been idle for 10 minutes, with the Claude app open and Accessibility on.")) }
        if said.isEmpty { said.append(tr("上面两项都没勾，没有要更新的。", "Nothing to keep up to date: neither box above is checked.")) }
        autoNote?.stringValue = said.joined(separator: tr("", " "))
            + (notYet ? tr("\n按计划写总结还没开始：点「导出」并在提示里同意后才开始。",
                           "\nSummaries aren't written on the schedule yet: that starts once you click Export and agree.") : "")
    }

    private func updateZip() {
        if let z = zip {
            // (a zip picked by hand may be another app's: ChatGPT's export has a conversations.json too)
            let whose = ClaudeExport.isClaude(z) ? tr("来自 Claude 官方导出包：", "From Claude's data export: ")
                                                 : tr("这个看起来不是 Claude 的官方导出包：", "This doesn't look like Claude's data export: ")
            zipLabel?.stringValue = whose + z.lastPathComponent + "（" + Clock.format(ClaudeExport.modified(z), "M/d HH:mm", "MMM d HH:mm") + "）"
        } else {
            zipLabel?.stringValue = ClaudeExport.canLookInDownloads
                ? tr("来自 Claude 官方导出包 —「下载」里还没有。在 Claude 里：设置 → 隐私 → 导出数据。",
                     "From Claude's data export — none in Downloads yet. In Claude: Settings → Privacy → Export data.")
                : tr("来自 Claude 官方导出包 — 点「选择 zip…」选它。（开了完全磁盘访问的话，会自己在「下载」里找。）",
                     "From Claude's data export — click \"Choose zip…\" to pick it. (With Full Disk Access, it's found in Downloads by itself.)")
        }
    }

    private func start() {
        // a run under way (one on the schedule may have started while this window was open): nothing more can start,
        // and nothing here is saved yet, the folder least of all (that run is still saving to the one it began with)
        if let why = archive.busyNote { Archive.say(why.title, why.text); return }
        let topics = Set(checks.filter { $0.0.state == .on }.map { $0.1 })
        // the choices are saved for the run (the items and the question below read them), and put back as they were
        // unless it starts: Cancel, or a "no" here, changes nothing. ("Keep it updated", and memory unticked, took
        // effect already: a "no" never turns back on what you stopped)
        let before = Archive.savedChoices()
        var started = false
        defer { if !started { Archive.restoreChoices(before) } }
        // everything ticked = "all", so topics added later come along too
        Archive.topics = topics.count == checks.count ? nil : topics
        Archive.knownTopics = Set(checks.map { $0.1 })
        Archive.withUnplaced = unplaced?.state == .on
        Archive.withMemory = memory?.state == .on
        Archive.withFiles = files?.state == .on
        if let i = every?.indexOfSelectedItem, Archive.everyChoices.indices.contains(i) { Archive.everyDays = Archive.everyChoices[i] }
        if let f = folder { Archive.folder = f }
        // the same choice the scheduled export uses (nothing ticked: only what's ticked, i.e. nothing on the map)
        let chosen = archive.chosen(topics: checks.isEmpty ? nil : Archive.topics, unplaced: Archive.withUnplaced)
        let items = chosen.items
        // only ChatGPT chats and Claude Code or Codex sessions there: as good as nothing (none of them is exported)
        if items.isEmpty && chosen.others > 0 {
            Archive.say(tr("没有要导出的对话", "Nothing to export"),
                        tr("选的部分里只有 ChatGPT 对话和 Claude Code、Codex 会话，这些不导出：只导出 Claude 对话。",
                           "What you picked holds only ChatGPT chats and Claude Code or Codex sessions. Those aren't exported: only Claude chats are."))
            return
        }
        guard !items.isEmpty else {
            Permissions.alert(tr("没有要导出的对话", "Nothing to export"), tr("勾选的部分里还没有对话。", "What you checked has no chats yet."))
            return
        }
        let withFiles = Archive.withFiles && zip != nil
        var withMemory = Archive.withMemory
        guard withFiles || withMemory else {
            Permissions.alert(tr("没选要导出的内容", "Nothing chosen to export"),
                              tr("勾上 memory.md；或者勾上「提示词、完整对话…」，并选好 Claude 的官方导出包。", "Check memory.md, or check \"Prompts, the whole conversation…\" and choose Claude's data export."))
            return
        }
        // summaries need the Claude app open, with Accessibility on: said before anything starts, not left out quietly
        if withMemory && !archive.canDrive {
            guard withFiles else {
                Permissions.alert(tr("没法写总结", "Can't write summaries"),
                                  tr("要先打开 Claude App，并开启「辅助功能」权限。", "Open the Claude app and turn on Accessibility first."))
                return
            }
            guard confirmFilesOnly?() ?? askFilesOnly(scheduled: Archive.auto) else { return }
            withMemory = false
        }
        if withMemory {
            guard let ok = confirmMemory, ok(items.count, Archive.auto) else { return }
        }
        // (a run can't have started during the questions above, as they wait for you; were one going, nothing's kept)
        if let why = archive.busyNote { Archive.say(why.title, why.text); return }
        // Claude writes summaries on the schedule only with this yes, given just now with automatic updates on
        Archive.autoMemoryAgreed = withMemory && Archive.auto
        started = true
        window?.close()
        try? FileManager.default.createDirectory(at: Archive.folder, withIntermediateDirectories: true)
        archive.export(items, memory: withMemory, zip: withFiles ? zip : nil, force: false, scheduled: false)
        NSWorkspace.shared.activateFileViewerSelecting([Archive.folder])
    }

    /// Claude can't write the summaries now, but the files can be written: export just them? (`scheduled`: automatic
    /// updates are on, and they don't write summaries either until you've said yes to that.)
    private func askFilesOnly(scheduled: Bool) -> Bool {
        let a = NSAlert()
        a.messageText = tr("现在没法写总结", "Summaries can't be written now")
        a.informativeText = tr("要写总结，得先打开 Claude App，并开启「辅助功能」权限。\n\n先只导出文件（提示词、完整对话、artifacts 和附件）吗？总结这次不写。",
                               "For the summaries, open the Claude app and turn on Accessibility first.\n\nExport just the files for now (prompts, the whole conversation, artifacts and attachments)? No summaries are written this time.")
            + (scheduled ? tr("之后按计划也不写，直到你在 Claude 打开时再点「导出」并同意。", " They aren't written on the schedule either, until you export again with Claude open and agree.") : "")
        a.addButton(withTitle: tr("只导出文件", "Export files only"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
}

/// A plain flipped view, so the topic list starts at the top of its scroll view.
final class FlippedStack: NSView {
    override var isFlipped: Bool { true }
}
