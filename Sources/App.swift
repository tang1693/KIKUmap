import Cocoa
import Carbon

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData else { return OSStatus(noErr) }
    let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { app.toggleMap() }
    return OSStatus(noErr)
}

/// While one of Kikumap's windows is open it's a regular app — the menu bar is its own, and it's in the Dock and
/// ⌘-Tab; with all of them closed it lives in the menu bar only again.
@MainActor
enum Front {
    /// Comes forward to show a window.
    static func activate() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A window closed or went away: back to the menu bar only if none is left.
    static func settle() {
        let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        if !open && NSApp.activationPolicy() == .regular { NSApp.setActivationPolicy(.accessory) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var store = Store()
    lazy var sounds = Sounds()
    lazy var usage = UsageMonitor()
    lazy var notifications = NotificationWatcher(store: store)
    lazy var sidebar = SidebarWatcher(store: store)
    lazy var code = CodeWatcher()
    lazy var gpt = GPTWatcher()
    lazy var perms = Permissions(notifications: notifications, sidebar: sidebar, usage: usage)
    lazy var statusBar = StatusBar(store: store, usage: usage, sounds: sounds)
    lazy var main = MainWindow(store: store, usage: usage)
    lazy var settings = SettingsWindow(store: store, perms: perms)
    lazy var intro = Onboarding(perms: perms)
    lazy var archive = Archive(store: store)
    lazy var exportWin = ExportWindow(store: store, archive: archive)
    lazy var stats = StatsWindow(store: store)
    lazy var widget = WidgetFeed(store: store, usage: usage, gpt: gpt)
    private let todoList = TodoPopover()
    private var widgetTimer: Timer?
    private var archiveTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Prefs.applyAppearance()
        buildMainMenu()
        for n in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { Front.settle() } }
            }
        }

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
        main.header.onStats = { [weak self] in self?.stats.show() }
        main.header.onRefresh = { [weak self] in self?.refreshAll() }
        main.sidebar.status = { [weak self] in self?.pinStatus() ?? ("", []) }
        main.header.onTodo = { [weak self] anchor in
            guard let self = self else { return }
            self.todoList.show(self.todos(), from: anchor) { [weak self] in self?.refreshUI() }
        }
        statusBar.openRoutines = { AppDelegate.openRoutines() }
        perms.onGPT = { [weak self] on in
            guard let self = self else { return }
            GPTWatcher.enabled = on
            if on { self.gpt.start() } else { self.gpt.stop(); self.store.clearGPT() }
        }

        statusBar.openChat = { [weak self] id in self?.open(id) }
        statusBar.showMap = { [weak self] in self?.main.show() }
        statusBar.diagnose = { [weak self] in self?.diagnose() }
        statusBar.enableUsage = { [weak self] in self?.perms.connectUsage(); self?.refreshUI() }
        statusBar.openSettings = { [weak self] in self?.settings.show() }
        statusBar.openAbout = { [weak self] in self?.settings.show(tab: SettingsWindow.aboutTab) }
        statusBar.openStats = { [weak self] in self?.stats.show() }
        stats.onOpen = { [weak self] id in self?.open(id) }
        statusBar.refreshAll = { [weak self] in self?.refreshAll() }
        statusBar.todos = { [weak self] in self?.todos() ?? [] }
        statusBar.todosChanged = { [weak self] in self?.refreshUI() }

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
        sidebar.onScan = { [weak self] links, noPins in
            guard let self = self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
            let ev = self.store.apply(scan: links, claudeFront: front, noPins: noPins)
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
        gpt.onThreads = { [weak self] threads, unread, pinsRead in
            guard let self = self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == GPTWatcher.bundleID
            let ev = self.store.apply(gpt: threads, unread: unread, pinsRead: pinsRead, front: front)
            self.sounds.play(ev)
            self.widget.update()                                   // ChatGPT's usage may have moved
        }
        sidebar.onStatus = { [weak self] in self?.refreshUI() }
        usage.onChange = { [weak self] in self?.refreshUI() }
        usage.log = { [weak self] t in self?.store.log(Clock.iso() + " " + t + "\n", file: "usage.log") }

        notifications.start()
        code.start()
        gpt.start()
        // never pop system prompts on launch — the intro asks for each permission on its own page
        sidebar.start(prompt: false)
        registerHotKey()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.archive.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        refreshUI()
        // the desktop widget's chart moves on while chats run
        widgetTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.widget.update() }
        }
        if !Prefs.onboarded {
            intro.show()
        } else {
            usage.start()
            // started at login → stay in the menu bar; started by hand → show the map
            if !CommandLine.arguments.contains("--background") { main.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { widget.closing() }

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
        h.usageHint = ""
        let all = todos()
        h.todoCount = all.isEmpty ? nil : Todos.open(all).count
        h.liveText = archive.busy ? tr("正在存档 ", "Archiving ") + archive.progress + tr(" · 请先别动 Claude 窗口", " · leave the Claude window alone") : syncText()
        h.liveHelp = archive.busy
            ? tr("Kikumap 正在让 Claude 给每个对话写交接总结，所以会自己在 Claude 窗口里切换对话。\n等它做完再用 Claude 窗口；想停下就点右边的「停止存档」。",
                 "Kikumap is asking Claude to write a hand-off summary in each chat, so it switches chats in Claude's window by itself.\nLeave that window alone until it's done, or click \"Stop archiving\".")
            : syncHelp()
        var actions: [(String, Bool, () -> Void)] = []
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
        stats.refresh()
        widget.update()
    }

    /// How fresh the Claude-app data is — or exactly what's stopping it.
    private func syncText() -> String {
        switch sidebar.status {
        case .noAccess: return ""                                   // the "Grant access" button says it
        case .noApp: return tr("Claude App 没打开", "Claude app closed")
        default:
            if sidebar.syncIssue != nil { return tr("同步暂停", "Sync paused") }
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

    /// What the left column is reading, when it last did and when it will next: a heading and a line per app.
    private func pinStatus() -> (title: String, lines: [String]) {
        let now = Date()
        func ago(_ d: Date) -> String {
            let s = Int(now.timeIntervalSince(d))
            return s < 5 ? tr("刚刚读过", "read just now") : s < 60 ? tr("\(s) 秒前读过", "read \(s)s ago") : tr("\(s / 60) 分钟前读过", "read \(s / 60) min ago")
        }
        func next(_ d: Date?) -> String {
            guard let d = d else { return "" }
            return tr("，\(max(0, Int(d.timeIntervalSince(now)))) 秒后再读（有变化会马上读）", " · next read in \(max(0, Int(d.timeIntervalSince(now))))s (sooner if something changes)")
        }
        var reading = false
        var lines: [String] = []
        let claudePins = store.chats.filter { !$0.outsideClaude && $0.pinned == true }.count
        switch sidebar.status {
        case .noAccess: lines.append(tr("Claude：要先开「辅助功能」权限才能读（见顶部「待办」）", "Claude: can't read it until Accessibility is on (see To-do at the top)"))
        case .noApp: lines.append(tr("Claude：App 没打开，打开后会自动开始读", "Claude: the app is closed; reading starts when it opens"))
        case .starting:
            reading = true
            lines.append(tr("Claude：正在连接…", "Claude: connecting…"))
        case .ok:
            if let i = sidebar.syncIssue {
                lines.append(tr("Claude：暂停，", "Claude: paused, ") + i.note)
            } else if let d = sidebar.lastSync {
                lines.append(tr("Claude：置顶 \(claudePins) 个，", "Claude: \(claudePins) pinned · ") + ago(d) + next(sidebar.nextRead))
            } else {
                reading = true
                lines.append(tr("Claude：正在读侧边栏…", "Claude: reading the sidebar…"))
            }
        }
        if !GPTWatcher.enabled {
            lines.append(tr("ChatGPT：已关闭（设置 → 授权）", "ChatGPT: off (Settings → Access)"))
        } else if !GPTWatcher.available {
            lines.append(tr("ChatGPT：这台 Mac 上没找到 ChatGPT 桌面 App", "ChatGPT: the desktop app isn't on this Mac"))
        } else if let d = gpt.lastRead {
            let n = store.chats.filter { $0.isGPT && $0.pinned == true }.count
            lines.append(tr("ChatGPT：置顶 \(n) 个，", "ChatGPT: \(n) pinned · ") + ago(d) + next(gpt.nextRead))
        } else {
            reading = true
            lines.append(tr("ChatGPT：正在读…", "ChatGPT: reading…"))
        }
        let gptOn = GPTWatcher.enabled && GPTWatcher.available
        let title = reading ? tr("正在读取置顶…", "Reading your pins…")
            : tr("没有找到置顶对话", "No pinned chats found")
        if !reading && store.pinnedList().isEmpty {
            lines.append(gptOn ? tr("在 Claude 或 ChatGPT 里置顶一个对话，它就会出现在这里。", "Pin a chat in Claude or ChatGPT and it shows up here.")
                               : tr("在 Claude 里置顶一个对话，它就会出现在这里。", "Pin a chat in Claude and it shows up here."))
        }
        return (title, lines)
    }

    /// Reads everything again now (⟳ in the top bar, ⌘R): Claude's sidebar and notifications, ChatGPT, usage.
    func refreshAll() {
        notifications.check()
        sidebar.attach()
        sidebar.schedule(0)
        if GPTWatcher.enabled { gpt.read() }
        usage.refreshNow()
        widget.update()
        refreshUI()
    }

    /// What's left to do, each with what it affects until it's done (the ▸ To-do in the top bar and the menu).
    func todos() -> [Todo] {
        var out: [Todo] = []
        let access: () -> Void = { [weak self] in self?.settings.show(tab: 2) }
        if sidebar.status == .noAccess {
            out.append(Todo(id: "accessibility", title: tr("给 Kikumap 开「辅助功能」权限", "Turn on Accessibility for Kikumap"),
                            impact: tr("在那之前读不到 Claude App 里的置顶、进行中和未读。ChatGPT 和 Claude Code 不受影响。",
                                       "Until then, Claude app chats have no pins, running or unread. ChatGPT and Claude Code aren't affected."),
                            action: (tr("去开启", "Turn on"), access)))
        }
        if notifications.status == .noAccess {
            out.append(Todo(id: "full-disk", title: tr("给 Kikumap 开「完全磁盘访问」权限", "Turn on Full Disk Access for Kikumap"),
                            impact: tr("在那之前，Claude App 里的对话做完或等你批准时没有提示音和提醒。其他都正常。",
                                       "Until then, no sound or alert when a Claude app chat finishes or needs you. Everything else works."),
                            action: (tr("去开启", "Turn on"), access)))
        }
        if sidebar.status == .noApp {
            out.append(Todo(id: "claude-closed", title: tr("打开 Claude App", "Open the Claude app"),
                            impact: tr("关着时，Claude App 里对话的进行中、未读和置顶都停在上次读到的样子。ChatGPT 和 Claude Code 不受影响。",
                                       "While it's closed, running, unread and pins for Claude app chats stay as last read. ChatGPT and Claude Code aren't affected."),
                            action: (tr("打开 Claude", "Open Claude"), {
                                if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
                                    NSWorkspace.shared.openApplication(at: u, configuration: .init())
                                }
                            })))
        } else if sidebar.status == .ok, let i = sidebar.syncIssue {
            out.append(Todo(id: "sync-\(i)", title: i.note, impact: i.help, action: nil))
        }
        if UsageMonitor.enabled {
            let none = tr("在那之前，菜单、窗口和小组件里没有 Claude 的用量。", "Until then, no Claude usage in the menu, the window or the widget.")
            let again: (String, () -> Void) = (tr("重新读取", "Read again"), { [weak self] in self?.usage.reconnect() })
            switch usage.status {
            case .noLogin:
                out.append(Todo(id: "usage-login", title: tr("用量要 Claude Code 登录", "Usage needs Claude Code signed in"),
                                impact: tr("用量来自 Claude Pro 或 Max 套餐：在终端运行 claude，输入 /login 登录。免费套餐没有用量可看，忽略这条就好。\n",
                                           "Usage comes with a Claude Pro or Max plan: run claude in Terminal and type /login. The Free plan has no usage to show, so just ignore this.\n") + none,
                                action: again))
            case .noScope:
                out.append(Todo(id: "usage-scope", title: usage.hint,
                                impact: tr("在终端运行 claude，输入 /login 重新登录一次。\n", "Run claude in Terminal and type /login again.\n") + none, action: again))
            case .expired:
                out.append(Todo(id: "usage-expired", title: usage.hint, impact: none, action: again))
            case .denied:
                out.append(Todo(id: "usage-denied", title: usage.hint,
                                impact: tr("点「重新读取」，macOS 问的时候选「始终允许」。\n", "Click Read again and choose Always Allow when macOS asks.\n") + none, action: again))
            default: break
            }
        }
        return out
    }

    /// Language or shortcut changed: refresh every fixed label.
    func relabelAll(rebuildSettings: Bool = true) {
        store.map.relabelPresetTags()
        buildMainMenu()
        statusBar.relabel()
        main.relabel()
        stats.relabel()
        widget.update(force: true)
        if rebuildSettings { settings.rebuild() }
        refreshUI()
    }

    func toggleMap() {
        if main.isShown { main.hide() } else { main.show() }
    }

    func open(_ id: String) {
        if let c = store.chat(id), c.isGPT {
            store.markSeen([id])
            GPTWatcher.open(String(id.dropFirst(4)))
            return
        }
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

    /// Writes logs/kikumap-check.txt: what works and what doesn't, then how the Claude sidebar reads. It holds
    /// no chat titles, messages or keys, so it can be sent to whoever helps.
    func diagnose() {
        guard !checking else { return }
        checking = true
        let write: @MainActor (String?) -> Void = { [weak self] dump in
            guard let self, self.checking else { return }
            self.checking = false
            let url = self.store.logsDir.appendingPathComponent("kikumap-check.txt")
            let sidebarPart = dump ?? "# Claude isn't running, or didn't answer in time: no sidebar to read.\n"
            try? (self.checkReport() + "\n--- Claude sidebar (chat titles shown as ‹title›) ---\n" + sidebarPart)
                .data(using: .utf8)?.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        sidebar.diagnose { write($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { MainActor.assumeIsolated { write(nil) } }
    }
    private var checking = false

    /// What Kikumap can see on this Mac, without anything personal.
    private func checkReport() -> String {
        func version(_ id: String) -> String {
            guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return "not installed" }
            return "version " + (Bundle(url: u)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        }
        func ago(_ d: Date?) -> String { d.map { "\(Int(-$0.timeIntervalSinceNow))s ago" } ?? "never" }
        let home = NSHomeDirectory()
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple silicon"
        #else
        let arch = "Intel"
        #endif
        let claude = store.chats.filter { !$0.outsideClaude }, codeChats = store.chats.filter(\.isCode), gptChats = store.chats.filter(\.isGPT)
        let widget = Bundle.main.builtInPlugInsURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("KikumapWidget.appex").path) } ?? false
        return """
            # Kikumap check \(Clock.iso())
            # Send this file when something doesn't work. It has no chat titles, messages or keys.

            Kikumap \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch) · languages \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))
            App at \(Bundle.main.bundlePath.replacingOccurrences(of: home, with: "~")) · data in \(store.dir.path.replacingOccurrences(of: home, with: "~"))

            Claude app: \(version(claudeBundleID)) · \(sidebar.claudePID != 0 ? "running" : "not running")
            Accessibility: \(AXIsProcessTrusted() ? "on" : "off")
            Sidebar: \(sidebar.status) · last read \(ago(sidebar.lastSync)) · \(sidebar.syncNote ?? "no problem")
            Chats: Claude \(claude.count) (pinned \(claude.filter { $0.pinned == true }.count)) · Claude Code \(codeChats.count) · ChatGPT \(gptChats.count) (pinned \(gptChats.filter { $0.pinned == true }.count)) · in the sidebar \(store.pinnedList().count)

            Claude Code: ~/.claude \(FileManager.default.fileExists(atPath: home + "/.claude") ? "found" : "missing")
            Usage: \(UsageMonitor.enabled ? "on" : "off") · \(usage.status) · updated \(ago(usage.updated))

            ChatGPT app: \(version(GPTWatcher.bundleID)) · its data \(GPTWatcher.available ? "found" : "missing") · reading \(GPTWatcher.enabled ? "on" : "off") · usage \(gpt.usage == nil ? "none yet" : "found")

            Widget: \(widget ? "in the app" : "missing") · \(os.majorVersion >= 14 ? "macOS supports it" : "needs macOS 14")

            """
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
    @objc private func showStats() { stats.show() }
    @objc private func refreshFromMenu() { refreshAll() }

    /// kikumap://chat/<id>, kikumap://map, kikumap://stats (the desktop widget's links).
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "kikumap" {
            switch u.host {
            case "chat": if let id = u.pathComponents.dropFirst().first { open(id) }
            case "stats": stats.show()
            default: main.show()
            }
        }
    }

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
        view.addItem(withTitle: tr("统计…", "Statistics…"), action: #selector(showStats), keyEquivalent: "y")
        view.addItem(withTitle: tr("刷新", "Refresh"), action: #selector(refreshFromMenu), keyEquivalent: "r")
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
