import Cocoa

/// Export: pick topics (every chat under them, pinned or not), pick what to include, export them all
/// at once — and optionally keep the export up to date on its own.
@MainActor
final class ExportWindow: NSObject, NSWindowDelegate {
    let store: Store
    let archive: Archive
    var onImport: (() -> Void)?
    /// Asks before Claude is made to write in the chats; false = cancelled.
    var confirmMemory: ((Int) -> Bool)?

    private var window: NSWindow?
    private var checks: [(NSButton, String)] = []
    private var unplaced: NSButton?
    private var memory: NSButton?
    private var files: NSButton?
    private var zipLabel: NSTextField?
    private var folderLabel: NSTextField?
    private var zip: URL?

    init(store: Store, archive: Archive) {
        self.store = store
        self.archive = archive
        super.init()
    }

    func show() {
        window?.orderOut(nil)
        build()
        NSApp.activate(ignoringOtherApps: true)
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
        let map = store.map
        let chosen = Archive.topics
        // the topics, indented, each with how many chats sit under it
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        func count(_ n: MapNode) -> Int {
            var c = 0
            map.walkChats(n) { if self.store.chat($0) != nil { c += 1 } }
            return c
        }
        func add(_ n: MapNode, _ depth: Int) {
            for ch in n.children {
                guard let s = ch.node else { continue }
                let b = check((s.title.isEmpty ? tr("新主题", "New topic") : s.title) + "  ·  \(count(s))", chosen == nil || chosen!.contains(s.id))
                let wrap = NSStackView(views: [b])
                wrap.edgeInsets = NSEdgeInsets(top: 0, left: CGFloat(depth) * 20, bottom: 0, right: 0)
                list.addArrangedSubview(wrap)
                checks.append((b, s.id))
                add(s, depth + 1)
            }
        }
        add(map.root, 0)
        let placed = map.placedChats()
        let loose = store.pinnedList().filter { !placed.contains($0.id) }.count
        let un = check(tr("没放进导图的置顶对话", "Pinned chats not on the map") + "  ·  \(loose)", Archive.withUnplaced)
        unplaced = un
        list.addArrangedSubview(un)
        if checks.isEmpty {
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
        let mem = check(tr("memory.md：让 Claude 写一份交接总结", "memory.md — a hand-off summary Claude writes"), Archive.withMemory)
        memory = mem
        let memNote = label(tr("会在每个对话里多一轮问答（用一点额度）；运行时 Claude 窗口会自己切换对话。没变化、未读、正在跑的会跳过。",
                               "Adds one exchange to each chat (uses a little quota); the Claude window switches chats while it runs. Unchanged, unread and running chats are skipped."), small: true, width: 470)
        let fil = check(tr("提示词、完整对话、全部 artifacts 和附件", "Prompts, the whole conversation, every artifact and attachment"), Archive.withFiles)
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
                              tr("在 Claude 里：设置 → 隐私 → 导出数据。几分钟后邮件里有下载链接。下载后点「选择 zip…」选它；开了完全磁盘访问的话，放在「下载」文件夹里就会自动找到。\n\n提示词、完整对话和 artifact 的内容只有这个导出包里是全的；开了完全磁盘访问和自动更新的话，以后每次下载新的导出包，文件会自己更新。",
                                 "In Claude: Settings → Privacy → Export data. A few minutes later an email has the download link. Then click \"Choose zip…\" and pick it; with Full Disk Access, a zip left in Downloads is found by itself.\n\nOnly this export has the complete prompts, conversations and artifact contents; with Full Disk Access and automatic updates on, every new export you download updates the files by itself."))
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
            p.directoryURL = Archive.folder.deletingLastPathComponent()
            guard p.runModal() == .OK, let u = p.url else { return }
            Archive.folder = u
            self?.folderLabel?.stringValue = u.path
        }
        change.controlSize = .small
        // without Full Disk Access, macOS asks before an app may write into Documents, Desktop or Downloads
        let folderNote = label(tr("第一次导出到「文稿」「桌面」或「下载」里时，macOS 会问一次是否允许 Kikumap 存到这里。",
                                  "The first export into Documents, Desktop or Downloads, macOS asks once whether Kikumap may save there."), small: true, width: 470)
        folderNote.isHidden = ClaudeExport.canLookInDownloads
        let auto = ClosureCheck(title: tr("自动更新", "Keep it updated"), on: Archive.auto) { Archive.auto = $0 }
        let days = Archive.everyChoices
        let every = ClosurePopUp(items: [tr("每天", "daily"), tr("每周", "weekly"), tr("每月", "monthly")]) { Archive.everyDays = days[$0] }
        every.selectItem(at: days.firstIndex(of: Archive.everyDays) ?? 1)
        every.controlSize = .small
        let autoNote = label(tr("开了完全磁盘访问时，「下载」里有新的导出包就马上更新文件；总结按这个频率、在电脑闲置 10 分钟以上时更新。",
                                "With Full Disk Access, a new export zip in Downloads updates the files right away; summaries follow this schedule, while the Mac has been idle for 10 minutes."), small: true, width: 470)

        let imp = ClosureButton(title: tr("导入到当前账号…", "Import into this account…")) { [weak self] in self?.window?.close(); self?.onImport?() }
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
            label(tr("选主题：它下面的对话（置顶的、没置顶的）都会导出，每个对话一个文件夹。", "Pick topics: every chat under them, pinned or not, is exported — one folder per chat."), width: 500),
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

    private func updateZip() {
        if let z = zip {
            zipLabel?.stringValue = tr("来自 Claude 官方导出包：", "From Claude's data export: ") + z.lastPathComponent + "（" + Clock.format(ClaudeExport.modified(z), "M/d HH:mm", "MMM d HH:mm") + "）"
        } else {
            zipLabel?.stringValue = ClaudeExport.canLookInDownloads
                ? tr("来自 Claude 官方导出包 —「下载」里还没有。在 Claude 里：设置 → 隐私 → 导出数据。",
                     "From Claude's data export — none in Downloads yet. In Claude: Settings → Privacy → Export data.")
                : tr("来自 Claude 官方导出包 — 点「选择 zip…」选它。（开了完全磁盘访问的话，会自己在「下载」里找。）",
                     "From Claude's data export — click \"Choose zip…\" to pick it. (With Full Disk Access, it's found in Downloads by itself.)")
        }
    }

    private func start() {
        let topics = Set(checks.filter { $0.0.state == .on }.map { $0.1 })
        // everything ticked = "all", so topics added later come along too
        Archive.topics = topics.count == checks.count ? nil : topics
        Archive.withUnplaced = unplaced?.state == .on
        Archive.withMemory = memory?.state == .on
        Archive.withFiles = files?.state == .on
        let items = archive.items(topics: Archive.topics ?? (checks.isEmpty ? [] : nil), unplaced: Archive.withUnplaced)
        guard !items.isEmpty else {
            Permissions.alert(tr("没有要导出的对话", "Nothing to export"), tr("勾选的主题下面还没有对话。", "The topics you picked have no chats yet."))
            return
        }
        let withFiles = Archive.withFiles && zip != nil
        let withMemory = Archive.withMemory
        guard withFiles || withMemory else {
            Permissions.alert(tr("没有可导出的内容", "Nothing to include"),
                              tr("勾上 memory，或者先下载 Claude 的官方导出包。", "Tick memory, or download Claude's data export first."))
            return
        }
        if withMemory, let ok = confirmMemory, !ok(items.filter { !$0.outsideClaude }.count) { return }
        window?.close()
        try? FileManager.default.createDirectory(at: Archive.folder, withIntermediateDirectories: true)
        archive.export(items, memory: withMemory, zip: withFiles ? zip : nil, force: false, scheduled: false)
        NSWorkspace.shared.activateFileViewerSelecting([Archive.folder])
    }
}

/// A plain flipped view, so the topic list starts at the top of its scroll view.
final class FlippedStack: NSView {
    override var isFlipped: Bool { true }
}
