import Cocoa
import Carbon

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData else { return OSStatus(noErr) }
    let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { app.toggleMap() }
    return OSStatus(noErr)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var store = Store()
    lazy var sounds = Sounds()
    lazy var usage = UsageMonitor()
    lazy var notifications = NotificationWatcher(store: store)
    lazy var sidebar = SidebarWatcher(store: store)
    lazy var code = CodeWatcher()
    lazy var perms = Permissions(notifications: notifications, sidebar: sidebar, usage: usage)
    lazy var statusBar = StatusBar(store: store, usage: usage, sounds: sounds)
    lazy var main = MainWindow(store: store, usage: usage)
    lazy var settings = SettingsWindow(store: store, perms: perms)
    lazy var intro = Onboarding(perms: perms)
    lazy var archive = Archive(store: store)
    lazy var exportWin = ExportWindow(store: store, archive: archive)
    private var archiveTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Prefs.applyAppearance()
        buildMainMenu()

        main.map.onOpen = { [weak self] id in self?.open(id) }
        main.map.onHide = { [weak self] in self?.main.hide() }
        main.map.onManageTags = { [weak self] in self?.settings.show(tab: 4) }
        main.tags.onManage = { [weak self] in self?.settings.show(tab: 4) }
        main.sidebar.onOpen = { [weak self] id in self?.open(id) }
        main.sidebar.onArchive = { [weak self] id in self?.archiveOne(id) }
        main.map.onArchive = { [weak self] id in self?.archiveOne(id) }
        main.sidebar.onOpenRoutines = { AppDelegate.openRoutines() }
        main.timeline.onOpenChat = { [weak self] id in self?.open(id) }
        main.timeline.onOpenRoutines = { AppDelegate.openRoutines() }
        main.timeline.onTurnOnUsage = { [weak self] in self?.perms.connectUsage(); self?.refreshUI() }
        main.header.onSettings = { [weak self] in self?.settings.show() }
        main.header.onLights = { Prefs.toggleLights() }
        statusBar.openRoutines = { AppDelegate.openRoutines() }

        statusBar.openChat = { [weak self] id in self?.open(id) }
        statusBar.showMap = { [weak self] in self?.main.show() }
        statusBar.diagnose = { [weak self] in self?.diagnose() }
        statusBar.enableUsage = { [weak self] in self?.perms.connectUsage(); self?.refreshUI() }
        statusBar.openSettings = { [weak self] in self?.settings.show() }
        statusBar.openAbout = { [weak self] in self?.settings.show(tab: SettingsWindow.aboutTab) }
        statusBar.permissionsNeeded = { [weak self] in
            guard let s = self else { return false }
            return s.notifications.status != .ok || s.sidebar.status == .noAccess
        }
        statusBar.openPermissions = { [weak self] in self?.settings.show(tab: 2) }
        statusBar.syncNote = { [weak self] in self?.sidebar.syncNote }
        statusBar.syncHelp = { [weak self] in self?.sidebar.syncIssue?.help }

        settings.onLanguage = { [weak self] in self?.relabelAll() }
        settings.onHotKey = { [weak self] in self?.registerHotKey(); self?.relabelAll(rebuildSettings: false) }
        settings.onSuspendHotKey = { [weak self] on in if on { self?.unregisterHotKey() } else { self?.registerHotKey() } }
        settings.onIntro = { [weak self] in self?.intro.show() }
        settings.onDiagnose = { [weak self] in self?.diagnose() }
        settings.archive = archive
        settings.sounds = sounds
        sounds.nameOf = { [weak self] id in self?.store.mapLabel(id) ?? "" }
        Sounds.folder = store.dir.appendingPathComponent("data/sounds")
        settings.onArchiveAll = { [weak self] in self?.archiveAll() }
        settings.onImport = { [weak self] in self?.importArchive() }
        exportWin.onImport = { [weak self] in self?.importArchive() }
        exportWin.confirmMemory = { [weak self] n in self?.confirmArchive(n) ?? false }
        archive.pid = { [weak self] in self?.sidebar.claudePID ?? 0 }
        archive.onChange = { [weak self] in self?.refreshUI(); self?.settings.refreshArchive() }
        intro.onLanguage = { [weak self] in self?.relabelAll() }
        intro.onFinish = { [weak self] in
            guard let self = self else { return }
            self.usage.start()
            self.sidebar.attach()
            self.main.show()
        }

        store.observe { [weak self] in self?.refreshUI() }
        notifications.onNotes = { [weak self] notes in
            guard let self = self else { return }
            let ev = self.store.apply(notes)
            if !self.archive.busy { self.sounds.play(ev) }
            self.sidebar.schedule(0.3)
        }
        notifications.onStatus = { [weak self] in self?.refreshUI() }
        sidebar.onScan = { [weak self] links in
            guard let self = self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
            let ev = self.store.apply(scan: links, claudeFront: front)
            if !self.archive.busy { self.sounds.play(ev) }       // the archive's own replies stay quiet
            self.refreshUI()                 // the "synced · just now" line
        }
        sidebar.onQuit = { [weak self] in self?.store.clearRunning() }
        code.onEvents = { [weak self] evs in
            guard let self = self else { return }
            let sounds = self.store.apply(code: evs) { id, transcript in
                // the session's own name (and whether it's linked to the Claude app), read off the main thread
                DispatchQueue.global(qos: .utility).async {
                    let info = CodeHooks.info(transcript: transcript)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.store.setCodeInfo(id, title: info.title, linked: info.linked) }
                    }
                }
            }
            self.sounds.play(sounds)
        }
        sidebar.onStatus = { [weak self] in self?.refreshUI() }
        usage.onChange = { [weak self] in self?.refreshUI() }
        usage.log = { [weak self] t in self?.store.log(Clock.iso() + " " + t + "\n", file: "usage.log") }

        notifications.start()
        code.start()
        // never pop system prompts on launch — the intro asks for each permission on its own page
        sidebar.start(prompt: false)
        registerHotKey()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.archive.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        refreshUI()
        if !Prefs.onboarded {
            intro.show()
        } else {
            usage.start()
            // started at login → stay in the menu bar; started by hand → show the map
            if !CommandLine.arguments.contains("--background") { main.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        main.show()
        return true
    }

    @objc private func didWake() {
        notifications.check()
        sidebar.schedule(1)
        usage.refresh()
    }

    func refreshUI() {
        statusBar.update()
        let h = main.header
        h.running = store.runningChats.count
        h.unread = store.unreadChats.count
        if usage.session != nil || usage.weekly != nil {
            h.meters = [(tr("会话", "Session"), usage.session?.percent, Clock.resets(usage.session?.resets)),
                        (tr("本周", "Week"), usage.weekly?.percent, Clock.resets(usage.weekly?.resets))]
        } else {
            h.meters = []
        }
        h.usageHint = h.meters.isEmpty ? usage.hint : ""
        h.liveText = archive.busy ? tr("正在存档 ", "Archiving ") + archive.progress + tr(" · 请先别动 Claude 窗口", " · leave the Claude window alone") : syncText()
        h.liveHelp = archive.busy
            ? tr("Kikumap 正在让 Claude 给每个对话写交接总结，所以会自己在 Claude 窗口里切换对话。\n等它做完再用 Claude 窗口；想停下就点右边的「停止存档」。",
                 "Kikumap is asking Claude to write a hand-off summary in each chat, so it switches chats in Claude's window by itself.\nLeave that window alone until it's done, or click \"Stop archiving\".")
            : syncHelp()
        main.sidebar.emptyNote = store.pinsKnown ? nil : pinsNote()
        var actions: [(String, Bool, () -> Void)] = []
        if notifications.status == .noAccess || sidebar.status == .noAccess {
            actions.append((tr("开启权限", "Grant access"), true, { [weak self] in self?.settings.show(tab: 2) }))
        }
        if UsageMonitor.enabled && (usage.status == .denied || usage.status == .error) {
            actions.append((tr("重新读取用量", "Read usage again"), false, { [weak self] in self?.usage.reconnect() }))
        }
        if archive.busy {
            actions.append((tr("停止存档", "Stop archiving"), true, { [weak self] in self?.archive.cancel() }))
        }
        actions.append((tr("导出…", "Export…"), false, { [weak self] in self?.exportWin.show() }))
        actions.append((tr("＋ 主题", "＋ Topic"), false, { [weak self] in self?.main.map.addTopicUnderRoot() }))
        actions.append((tr("全部已读", "Mark all read"), false, { [weak self] in self?.store.markAllSeen() }))
        let sig = actions.map { $0.0 }
        if sig != h.actions.map({ $0.0 }) { h.actions = actions }
        h.needsDisplay = true
        if main.window.isVisible { main.reload() }
    }

    /// How fresh the Claude-app data is — or exactly what's stopping it.
    private func syncText() -> String {
        switch sidebar.status {
        case .noAccess: return ""                                   // the "Grant access" button says it
        case .noApp: return tr("Claude App 没打开 · 只有通知和 Claude Code", "Claude app closed · notifications and Claude Code only")
        default:
            if let n = sidebar.syncNote { return "⚠︎ " + n }
            guard let d = sidebar.lastSync else { return tr("同步中…", "Syncing…") }
            return tr("已同步 · ", "Synced · ") + Clock.ago(Clock.iso(d))
        }
    }

    /// On hovering the status: what it means, what it holds up, what to do.
    private func syncHelp() -> String {
        switch sidebar.status {
        case .noAccess: return ""
        case .noApp:
            return tr("Claude 桌面 App 没在运行。\n不受影响：Claude Code 会话、导图上已有的内容。\n暂停：Claude App 里对话的进行中、做完、未读和置顶同步。\n怎么办：打开 Claude App，会自动接上。",
                      "The Claude desktop app isn't running.\nStill works: Claude Code sessions and everything already on your map.\nPaused: running, finished, unread and pins for chats in the Claude app.\nFix: open Claude; Kikumap picks it up by itself.")
        default:
            if let i = sidebar.syncIssue { return i.help }
            guard sidebar.lastSync != nil else {
                return tr("正在第一次读取 Claude 的侧边栏…", "Reading Claude's sidebar for the first time…")
            }
            return tr("一切正常：Kikumap 刚读过 Claude 的侧边栏，Claude 一有变化就会再读。不需要做什么。",
                      "All good: Kikumap just read Claude's sidebar and reads it again whenever Claude changes. Nothing to do.")
        }
    }

    // MARK: archive

    /// Before every run: say what's about to happen.
    private func confirmArchive(_ count: Int) -> Bool {
        let a = NSAlert()
        a.messageText = tr("让 Claude 写交接总结（memory）", "Have Claude write hand-off summaries (memory)")
        a.informativeText = tr("""
        会在 Claude App 里依次打开\(count == 1 ? "这个对话" : "这 \(count) 个对话")，发一条消息请 Claude 写交接总结，再把总结存成 memory.md（\(Archive.folder.path)）。

        · 每个对话会多一轮问答，用掉一点额度
        · 运行时 Claude 窗口会自己切换对话，先别动它（顶栏可以随时停止）
        · 正在跑、未读、没有新内容的对话会跳过
        """, """
        The Claude app will open \(count == 1 ? "this chat" : "these \(count) chats") in turn, send a message asking Claude for a hand-off summary, and save the reply as memory.md (\(Archive.folder.path)).

        · Each chat gets one more exchange, which uses a little of your quota
        · The Claude window switches chats while this runs — leave it alone (you can stop from the top bar)
        · Chats that are running, unread or unchanged are skipped
        """) + (ClaudeExport.canLookInDownloads ? "" : tr("\n\n第一次存到「文稿」「桌面」或「下载」里时，macOS 会问一次是否允许 Kikumap 存到这里。",
                                                         "\n\nThe first time it saves into Documents, Desktop or Downloads, macOS asks once whether Kikumap may save there."))
        a.addButton(withTitle: tr("开始", "Start"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    func archiveOne(_ id: String) {
        guard !archive.busy, confirmArchive(1) else { return }
        archive.runOne(id)
    }

    func archiveAll() { exportWin.show() }

    func importArchive() {
        guard !archive.busy else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = Archive.folder
        p.message = tr("选存档文件夹", "Choose the archive folder")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let dir = p.url else { return }
        let all = Archive.notes(in: dir)
        let todo = all.filter { !archive.alreadyImported($0) }
        let a = NSAlert()
        if todo.isEmpty {
            a.messageText = all.isEmpty ? tr("这个文件夹里没有存档", "No archived chats in this folder")
                                        : tr("这些都已经导入过了", "These were all imported already")
            a.runModal()
            return
        }
        a.messageText = tr("导入 \(todo.count) 个对话到现在登录的 Claude 账号？", "Import \(todo.count) chats into the Claude account that's signed in now?")
        a.informativeText = tr("""
        每个存档会在 Claude App 里开一个新对话，把总结发进去让 Claude 接上，然后置顶、改回原来的名字。导图上会接到原来的位置。

        · 先在 Claude App 里登录要导入的账号
        · 运行时先别动 Claude 窗口
        · 图片、视频等大文件带不过去，总结里会列出它们
        """, """
        Each one starts a new chat in the Claude app with the summary sent in so Claude can pick up, then pins it and gives it the old name. On the map it takes the old chat's place.

        · Sign in to the target account in the Claude app first
        · Leave the Claude window alone while it runs
        · Images, videos and other big files don't come along — the summary lists them
        """)
        a.addButton(withTitle: tr("导入", "Import"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        archive.importNotes(todo)
    }

    /// Claude's pins haven't been read yet: what's in the way.
    private func pinsNote() -> String {
        switch sidebar.status {
        case .noAccess: return tr("要先开「辅助功能」权限，才能读到 Claude 的置顶对话（右上角「开启权限」）",
                                  "Turn on Accessibility first to read Claude's pinned chats (\"Grant access\", top right)")
        case .noApp: return tr("打开 Claude App，就能读到置顶对话", "Open the Claude app to read your pinned chats")
        default:
            if let n = sidebar.syncNote { return n }
            return tr("正在读取 Claude 的置顶对话…", "Reading Claude's pinned chats…")
        }
    }

    /// Language or shortcut changed: refresh every fixed label.
    func relabelAll(rebuildSettings: Bool = true) {
        store.map.relabelPresetTags()
        buildMainMenu()
        statusBar.relabel()
        main.relabel()
        if rebuildSettings { settings.rebuild() }
        refreshUI()
    }

    func toggleMap() {
        if main.isShown { main.hide() } else { main.show() }
    }

    func open(_ id: String) {
        // a Claude Code session: bring up the app it runs in (VS Code opens its folder)
        if let c = store.chat(id), c.isCode {
            store.markSeen([id])
            openCode(c)
            return
        }
        // address not known yet: click its row in the Claude app's sidebar
        if id.hasPrefix("n-"),
           let title = store.chat(id)?.title, !title.isEmpty {
            store.markSeen([id])
            sidebar.press(title: title) { [weak self] ok in
                if ok {
                    NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first?.activate()
                    self?.sidebar.schedule(1)
                } else {
                    self?.openURL(id)
                }
            }
            return
        }
        openURL(id)
    }

    private func openCode(_ c: Chat) {
        let terms = ["vscode": "com.microsoft.VSCode", "Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2"]
        let raw = c.app ?? ""
        let bundle = terms[raw] ?? raw
        let folder = c.cwd.map { URL(fileURLWithPath: $0) }
        if !bundle.isEmpty, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            if let f = folder, bundle.lowercased().contains("vscode") || bundle.lowercased().contains("cursor") {
                NSWorkspace.shared.open([f], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
        } else if let f = folder {
            NSWorkspace.shared.activateFileViewerSelecting([f])
        }
    }

    private func openURL(_ id: String) {
        var path = "/chat/"
        if let c = store.chat(id), let p = c.path, !p.isEmpty {
            path = p
        } else if !id.hasPrefix("n-") {
            path = "/chat/" + String(id.filter { $0.isHexDigit || $0 == "-" })
        }
        store.markSeen([id])
        if let u = URL(string: "claude://claude.ai\(path)"), NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
            NSWorkspace.shared.open(u)
        } else if let u = URL(string: "https://claude.ai\(path == "/chat/" ? "/recents" : path)") {
            NSWorkspace.shared.open(u)
        }
    }

    static func openRoutines() {
        if let u = URL(string: "https://claude.ai/code/routines") { NSWorkspace.shared.open(u) }
    }

    func diagnose() {
        sidebar.diagnose()
        NSWorkspace.shared.activateFileViewerSelecting([store.logsDir])
    }

    @objc private func showSettings() { settings.show() }
    @objc private func showAbout() { settings.show(tab: SettingsWindow.aboutTab) }
    @objc private func toggleSide() { main.toggleSidebar() }
    @objc private func toggleTimeline() { main.toggleTimeline() }
    @objc private func bigger() { main.scaleUI(by: 1) }
    @objc private func smaller() { main.scaleUI(by: -1) }
    @objc private func defaultSize() { main.scaleUI(by: 0) }
    @objc private func findInMap() { main.showSearch() }
    @objc private func exportPDF() { main.show(); main.map.exportPDF() }
    @objc private func showExport() { exportWin.show() }
    @objc private func showMap() { main.show() }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("关于 Kikumap", "About Kikumap"), action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("设置…", "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: tr("导出对话…", "Export chats…"), action: #selector(showExport), keyEquivalent: "E")
        appMenu.addItem(withTitle: tr("导出导图 PDF…", "Export map as PDF…"), action: #selector(exportPDF), keyEquivalent: "e")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("收起窗口", "Close window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: tr("退出", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: tr("搜索导图", "Find in map"), action: #selector(findInMap), keyEquivalent: "f")
        editItem.submenu = edit
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: tr("显示", "View"))
        let side = view.addItem(withTitle: tr("显示 / 隐藏左栏", "Show / Hide Left Column"), action: #selector(toggleSide), keyEquivalent: "s")
        side.keyEquivalentModifierMask = [.control, .command]
        let tl = view.addItem(withTitle: tr("显示 / 隐藏时间线", "Show / Hide Timeline"), action: #selector(toggleTimeline), keyEquivalent: "t")
        tl.keyEquivalentModifierMask = [.control, .command]
        view.addItem(.separator())
        view.addItem(withTitle: tr("放大", "Bigger"), action: #selector(bigger), keyEquivalent: "+")
        view.addItem(withTitle: tr("缩小", "Smaller"), action: #selector(smaller), keyEquivalent: "-")
        view.addItem(withTitle: tr("默认大小", "Default Size"), action: #selector(defaultSize), keyEquivalent: "")
        viewItem.submenu = view
        NSApp.mainMenu = main
    }

    private func unregisterHotKey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r) }
        hotKeyRef = nil
    }

    private func registerHotKey() {
        unregisterHotKey()
        if !hotKeyHandlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, me, nil)
            hotKeyHandlerInstalled = true
        }
        guard Prefs.hotKeyEnabled else { return }
        let hkID = EventHotKeyID(signature: OSType(0x4343_4F4E), id: 1)
        RegisterEventHotKey(Prefs.hotKeyCode, Prefs.hotKeyMods, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

@main
enum ClaudeConsoleMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--make-icns"), i + 1 < args.count {
            Logo.writeICNS(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count {
            Logo.writeIconset(to: args[i + 1])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
