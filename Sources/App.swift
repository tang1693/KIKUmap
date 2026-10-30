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
    private var shownGPTUsage: GPTUsage?
    /// A newer copy of Kikumap asked this one to quit.
    private var handingOver = false
    /// In takeOver(), before anything is loaded.
    private var takingOver = false
    /// Watches for Kikumaps too old to ask for the handover; the ones stopped so far.
    private var launches: NSKeyValueObservation?
    private var stopped = Set<pid_t>()
    /// Kikumaps that asked for the handover, and ones whose build can't be read being watched (see `watchLaunches`).
    private var askers = Set<pid_t>()
    private var watched = Set<pid_t>()
    private let launched = Date()
    private var widgetTimer: Timer?
    private var archiveTimer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false
    /// Sessions whose name is being read from their transcript (one read each at a time).
    private var titlesQueued = Set<String>()
    /// What the usage meters showed last (they change by themselves when a window resets).
    private var metersShown = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        takeOver()
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
        perms.gptError = { [weak self] in self?.gpt.readError }
        main.header.onSettings = { [weak self] in self?.settings.show() }
        main.header.onLights = { Prefs.toggleLights() }
        main.header.onStats = { [weak self] in self?.stats.show() }
        main.sidebar.onRefresh = { [weak self] in self?.refreshAll() }
        main.sidebar.status = { [weak self] in self?.pinStatus() ?? ("", []) }
        main.header.onTodo = { [weak self] anchor in
            guard let self = self else { return }
            self.todoList.show(self.todos(), from: anchor) { [weak self] in self?.refreshUI() }
        }
        statusBar.openRoutines = { AppDelegate.openRoutines() }
        perms.onGPT = { [weak self] on in
            guard let self = self else { return }
            GPTWatcher.enabled = on
            self.shownGPTUsage = nil
            if on { self.gpt.start() } else { self.gpt.stop(); self.store.clearGPT() }
            // the left column, counts, meters and badge follow the switch now, not at the next read
            self.refreshUI()
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
        statusBar.gptUsage = { [weak self] in self?.gptUsageRows() ?? [] }
        statusBar.claudeNote = { [weak self] in self?.claudeNote() }
        store.openChatID = { [weak self] in self?.sidebar.openChat }
        widget.claudeNote = { [weak self] in
            guard let self = self, let n = self.claudeNote() else { return nil }
            return (n, self.claudeNoteUnreadOnly())
        }
        statusBar.claudeUnreadOnly = { [weak self] in self?.claudeNoteUnreadOnly() ?? false }
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
        store.onIDMove = { [weak self] old, new in self?.archive.moved(old, to: new) }
        store.frontApp = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let b = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.store.appCameToFront(b) }
        }
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
            let ev = self.store.apply(notes, quietBefore: self.launched)
            if !self.archive.busy { self.sounds.play(ev) }
            self.sidebar.schedule(0.3)
        }
        notifications.onStatus = { [weak self] in
            SyncIssue.alerts = self?.notifications.status == .ok
            self?.refreshUI()
        }
        sidebar.onScan = { [weak self] links, noPins, readKnown, started, whole in
            guard let self = self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
            let ev = self.store.apply(scan: links, claudeFront: front, noPins: noPins, readKnown: readKnown, startedAt: started, whole: whole)
            if !self.archive.busy { self.sounds.play(ev) }       // the archive's own replies stay quiet
            self.refreshUI()                 // the "synced · just now" line
        }
        sidebar.onQuit = { [weak self] in self?.store.clearRunning() }
        code.onEvents = { [weak self] evs in
            guard let self = self else { return }
            // lines written while Kikumap wasn't running update the sessions quietly
            let sounds = self.store.apply(code: evs, quietBefore: self.launched) { id, transcript in
                // the session's own name (and whether it's linked to the Claude app), read off the main thread, one
                // read at a time (a read already waiting will see the newest lines anyway)
                guard !self.titlesQueued.contains(id) else { return }
                self.titlesQueued.insert(id)
                TranscriptReader.shared.queue.async {
                    let info = TranscriptReader.shared.info(transcript)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.titlesQueued.remove(id)
                            self.store.setCodeInfo(id, title: info.title, linked: info.linked)
                        }
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
            if self.gpt.usage != self.shownGPTUsage { self.shownGPTUsage = self.gpt.usage; self.refreshUI() }
        }
        sidebar.onStatus = { [weak self] in
            guard let self = self else { return }
            // Claude can't be read now (Accessibility off, the app closed or gone): its running chats' time waits
            if self.sidebar.status != .ok { self.store.pause(self.store.running) }
            self.refreshUI()
        }
        usage.onChange = { [weak self] in self?.refreshUI() }
        usage.log = { [weak self] t in self?.store.log(Clock.iso() + " " + t + "\n", file: "usage.log") }

        notifications.start()
        SyncIssue.alerts = notifications.status == .ok
        CodeHooks.upgradeIfNeeded()          // connected by an older version: its hooks brought up to date
        LoginItem.follow()                   // a login item left pointing at a moved or older copy points here
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        refreshUI()
        widget.update(force: true)          // the widget may still say "not running" from the last quit
        // the desktop widget's chart moves on while chats run; and a note of when Kikumap was last alive,
        // so runs left open by a crash end there
        widgetTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                UserDefaults.standard.set(Clock.iso(), forKey: "AliveAt")
                // a Claude Code turn ended without a word (Esc, a closed terminal) stops counting
                self.store.expireCode()
                // Claude closed for hours: its runs last seen then are no longer said to run
                self.store.forgetUnseenRuns()
                // files that couldn't be saved (a full disk, a folder that can't be written) are tried again
                self.retrySaves()
                // a usage window reset (or its numbers aged): the meters change by themselves
                if self.meterSignature() != self.metersShown { self.refreshUI() }
                self.widget.update()
            }
        }
        // nothing until usage was turned on; then it reads during a resumed intro too (relaunched by Quit & Reopen)
        usage.start()
        if !Prefs.onboarded {
            intro.show(resume: true)
        } else {
            // started at login → stay in the menu bar; started by hand → show the map
            if !CommandLine.arguments.contains("--background") { main.show() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.closeRuns(at: Date())
        retrySaves()
        // handing over to a newer copy: it fills the widget in; don't tell it Kikumap stopped
        if !handingOver { widget.closing() }
    }

    /// One Kikumap at a time: a copy opened while another runs (an update, a second install) takes over, and
    /// the older one quits quietly. It waits a moment for that, so the two never write the same files at once.
    /// The newer build always stays: an older copy opened later shows the running one's map and leaves (or, when
    /// it asks to take over, is stopped). An older copy that doesn't know the handover is asked to quit the
    /// ordinary way, and one opened later is stopped as it starts.
    private func takeOver() {
        takingOver = true
        defer { takingOver = false }
        let name = Notification.Name("ninja.tang.claudeconsole.takeover")
        let id = Bundle.main.bundleIdentifier ?? ownBundleID
        let me = getpid()
        let mine = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
        // builds 13 and 14 send only their process number; later ones their build too
        func post() {
            DistributedNotificationCenter.default().postNotificationName(name, object: String(me), userInfo: ["build": String(mine)], deliverImmediately: true)
        }
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
            guard let s = n.object as? String, let other = Int32(s), other != me else { return }
            let theirs = (n.userInfo?["build"] as? String).flatMap { Int($0) }
            MainActor.assumeIsolated {
                self?.askers.insert(other)
                guard let self, let app = NSRunningApplication(processIdentifier: other), app.bundleIdentifier == id else { return }
                switch AppDelegate.handover(mine: mine, theirs: theirs, me: me, other: other, starting: self.takingOver) {
                case .quit:
                    self.handingOver = true
                    NSApp.terminate(nil)
                case .stay:
                    post()          // it may have started listening only after this copy asked: ask again
                case .stop:
                    // an older copy is starting and wants to take over: nothing of it is loaded yet, so it's stopped,
                    // and the map it would have shown comes from this one
                    app.forceTerminate()
                    if !self.takingOver { self.main.show() }
                }
            }
        }
        watchLaunches(id)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        let builds = others.map { AppDelegate.build(of: $0.bundleURL) }
        if let i = builds.firstIndex(where: { ($0 ?? 0) > mine }), let url = others[i].bundleURL {
            // a newer Kikumap is running: it stays, and shows its map once the reopen has reached it (not when this
            // copy was started at login); this one leaves untouched
            if !CommandLine.arguments.contains("--background") {
                let sent = DispatchSemaphore(value: 0)
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in sent.signal() }
                _ = sent.wait(timeout: .now() + 3)
            }
            exit(0)
        }
        post()
        func wait(_ s: Double) {
            let until = Date().addingTimeInterval(s)
            while Date() < until && others.contains(where: { !$0.isTerminated }) { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        // copies from before the handover (0.9.5 build 12 and older) can't hear it: no use waiting for them
        if !builds.allSatisfy(AppDelegate.unaware) { wait(4) }
        // one that didn't answer is asked to quit the ordinary way, then made to
        for o in others where !o.isTerminated { o.terminate() }
        wait(3)
        for o in others where !o.isTerminated { o.forceTerminate() }
        wait(1)
    }

    /// What this Kikumap does when another (build `theirs`; nil: 0.9.5 builds 13 and 14, which don't say) asks it
    /// to quit: the newer build stays, and the older one quits (`.quit`) or, while it starts, is stopped (`.stop`).
    /// Of the same build the copy already running gives way; of two starting at once the higher process number
    /// stays and asks again (`.stay`), in case the other wasn't listening yet when it first asked.
    enum Handover { case quit, stay, stop }
    static func handover(mine: Int, theirs: Int?, me: Int32, other: Int32, starting: Bool) -> Handover {
        let t = theirs ?? 0
        if t != mine { return t > mine ? .quit : .stop }
        return starting && other < me ? .stay : .quit
    }

    /// A Kikumap's build, read from its bundle each time (nil: unreadable, or somewhere macOS would first ask
    /// whether Kikumap may look: Desktop, Documents, Downloads, iCloud Drive, a disk image or another volume).
    static func build(of url: URL?) -> Int? {
        guard let url else { return nil }
        let p = url.standardizedFileURL.path, home = NSHomeDirectory()
        if p.hasPrefix("/Volumes/") || ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].contains(where: { p.hasPrefix(home + "/" + $0 + "/") }) {
            return nil
        }
        guard let d = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let o = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { return nil }
        return (o["CFBundleVersion"] as? String).flatMap { Int($0) }
    }

    /// Builds before 13 don't know the handover: they neither ask nor listen.
    static func unaware(_ build: Int?) -> Bool { (build ?? .max) < 13 }

    /// Kikumaps from before the handover never ask: one opened while this one runs is stopped as it starts, and
    /// the map it would have shown comes from this one. One whose build can't be read (opened from Downloads or a
    /// disk image, say) is stopped once it has started without asking: every build that knows the handover asks as
    /// it starts (or leaves, when it's the older one).
    private func watchLaunches(_ id: String) {
        launches = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
                        $0.processIdentifier != getpid() && !self.stopped.contains($0.processIdentifier)
                    }
                    for o in others where !self.watched.contains(o.processIdentifier) && AppDelegate.build(of: o.bundleURL) == nil {
                        self.watched.insert(o.processIdentifier)
                        self.stopIfSilent(o, tries: 0)
                    }
                    let old = others.filter { AppDelegate.unaware(AppDelegate.build(of: $0.bundleURL)) }
                    guard !old.isEmpty else { return }
                    for o in old { self.stopped.insert(o.processIdentifier); o.forceTerminate() }
                    self.afterStopping()
                }
            }
        }
    }

    /// A copy whose build can't be read: still running without having asked, some seconds after it finished
    /// starting, it's from before the handover.
    private func stopIfSilent(_ app: NSRunningApplication, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !app.isTerminated, !self.askers.contains(app.processIdentifier), !self.stopped.contains(app.processIdentifier) else { return }
                guard app.isFinishedLaunching else {
                    if tries < 20 { self.stopIfSilent(app, tries: tries + 1) }
                    return
                }
                self.stopped.insert(app.processIdentifier)
                app.forceTerminate()
                self.store.log("\(Clock.iso()) stopped an older Kikumap that didn't ask to take over (\(app.bundleURL?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "?"))\n", file: "app.log")
                self.afterStopping()
            }
        }
    }

    /// Whatever a stopped copy wrote while starting (its map, the widget's feed) is written again from here.
    private func afterStopping() {
        guard !takingOver else { return }       // nothing loaded yet: what it wrote is simply read
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                self.store.saveAll()
                self.store.map.save()
                self.widget.update(force: true)
                self.main.show()
            }
        }
    }

    @objc private func willSleep() {
        store.closeRuns(at: Date())
        retrySaves()
    }

    /// Data files whose last save failed are written again.
    private func retrySaves() { store.retrySaves(); store.map.retrySave(); archive.retrySave() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        main.show()
        return true
    }

    @objc private func didWake() {
        store.resumeRuns(at: Date())
        notifications.check()
        sidebar.schedule(1)
        if GPTWatcher.enabled { gpt.read() }
        // the network usually needs a few seconds after waking
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in MainActor.assumeIsolated { self?.usage.refresh() } }
        widget.update(force: true)
    }

    /// Claude's meters as they'd be shown now (session, week, and the Sonnet-only week while it's the one that
    /// holds you back): name, percent, under-text.
    private func claudeMeters() -> [(String, Double?, String)] {
        guard usage.session != nil || usage.weekly != nil else { return [] }
        let asOf = usage.asOfText
        var m = [(tr("会话", "Session"), usage.shownSession?.percent, asOf ?? Clock.resets(usage.shownSession?.resets)),
                 (tr("本周", "Week"), usage.shownWeekly?.percent, asOf ?? Clock.resets(usage.shownWeekly?.resets))]
        if let s = usage.bindingSonnet { m.append(("Sonnet", s.percent, asOf ?? Clock.resets(s.resets))) }
        return m
    }

    private func meterSignature() -> String {
        (claudeMeters().map { "\($0.0)\($0.1 ?? -1)\($0.2)" } + gptUsageRows().map { "\($0.label)\($0.window?.percent ?? -1)\($0.window?.resets?.timeIntervalSince1970 ?? 0)\($0.note ?? "")" })
            .joined(separator: "|")
    }

    func refreshUI() {
        statusBar.update()
        let h = main.header
        h.running = store.runningChats.count
        h.runningUnsure = store.seenRunningChats.count < store.runningChats.count
        h.unread = store.unreadChats.count
        h.meters = UsageMonitor.enabled ? claudeMeters() : []
        h.usageHint = ""
        metersShown = meterSignature()
        h.gptMeters = gptUsageRows().map { ($0.label, $0.window?.percent, $0.note ?? Clock.resets($0.window?.resets)) }
        let all = todos()
        h.todoCount = all.isEmpty ? nil : Todos.open(all).count
        // ("3/12 · title" while it goes chat by chat; a step of its own, such as reading the export, said as it is)
        let doing = archive.importing ? tr("正在导入", "Importing") : tr("正在存档", "Archiving")
        let step = archive.progress.isEmpty ? doing : archive.progress.first?.isNumber == true ? doing + " " + archive.progress : doing + " · " + archive.progress
        h.liveText = archive.busy ? step + tr(" · 请先别动 Claude 窗口", " · leave the Claude window alone") : syncText()
        h.liveImportant = archive.busy || sidebar.syncIssue != nil || sidebar.status == .noApp || sidebar.status == .noAccess || unreadUnsynced || gptUnsynced
        // shorter, for a narrow window: without the chat's title; the problems alone
        let count = archive.progress.first?.isNumber == true ? " " + (archive.progress.components(separatedBy: " · ").first ?? "") : ""
        h.liveShort = archive.busy ? [doing + count + tr(" · 请先别动 Claude 窗口", " · leave the Claude window alone"), doing + count] : syncShort()
        h.liveHelp = archive.busy
            ? (archive.importing
               ? tr("Kikumap 正在把导出的对话一个个开成新对话，所以会自己在 Claude 窗口里操作。\n等它做完再用 Claude 窗口；想停下就点右边的「停止」。",
                    "Kikumap is starting a new chat in Claude for each exported one, so it works in Claude's window by itself.\nLeave that window alone until it's done, or click \"Stop\".")
               : tr("Kikumap 正在让 Claude 给每个对话写交接总结，所以会自己在 Claude 窗口里切换对话。\n等它做完再用 Claude 窗口；想停下就点右边的「停止」。",
                    "Kikumap is asking Claude to write a hand-off summary in each chat, so it switches chats in Claude's window by itself.\nLeave that window alone until it's done, or click \"Stop\"."))
            : syncHelp()
        var actions: [(String, Bool, () -> Void, String?)] = []
        if archive.busy {
            actions.append((tr("停止", "Stop"), true, { [weak self] in self?.archive.cancel() }, "square"))
        }
        actions.append((tr("导出", "Export"), false, { [weak self] in self?.exportWin.show() }, "upload"))
        actions.append((tr("主题", "Topic"), false, { [weak self] in self?.main.map.addTopicUnderRoot() }, "plus"))
        actions.append((tr("全部已读", "Mark all read"), false, { [weak self] in self?.store.markAllSeen() }, "check-check"))
        let sig = actions.map { $0.0 }
        if sig != h.actions.map({ $0.0 }) { h.actions = actions }
        h.needsDisplay = true
        if main.window.isVisible { main.reload() }
        stats.refresh()
        widget.update()
    }

    /// How fresh the Claude-app data is — or exactly what's stopping it.
    private func syncText() -> String {
        let gptNote = gptUnsynced ? tr(" · ChatGPT 没同步", " · ChatGPT not synced") : ""
        switch sidebar.status {
        case .notInstalled: return gptUnsynced ? tr("ChatGPT 没同步", "ChatGPT not synced") : ""     // nothing to say of Claude
        case .noAccess: return tr("Claude 没同步：辅助功能关着", "Claude not synced: Accessibility off") + gptNote
        case .noApp: return tr("Claude App 没打开", "Claude app closed") + gptNote
        default:
            if sidebar.syncIssue != nil { return tr("同步暂停", "Sync paused") + gptNote }
            guard let d = sidebar.lastSync else { return tr("同步中…", "Syncing…") }
            return tr("已同步 · ", "Synced · ") + Clock.ago(Clock.iso(d)) + (unreadUnsynced ? tr(" · 未读没同步", " · unread not synced") : "") + gptNote
        }
    }

    /// What `claudeNote` says is about Claude's unread marks alone: its chat list is read as usual.
    func claudeNoteUnreadOnly() -> Bool { sidebar.status == .ok && sidebar.syncIssue == nil }

    /// `syncText` in fewer words: what's wrong, without "Synced · 12m ago".
    private func syncShort() -> [String] {
        let gpt = gptUnsynced ? [tr("ChatGPT 没同步", "ChatGPT not synced")] : []
        let claude: [String]
        switch sidebar.status {
        case .noAccess: claude = [tr("Claude 没同步", "Claude not synced")]
        case .noApp: claude = [tr("Claude App 没打开", "Claude app closed")]
        case .notInstalled: claude = []
        default: claude = sidebar.syncIssue != nil ? [tr("同步暂停", "Sync paused")] : unreadUnsynced ? [tr("未读没同步", "unread not synced")] : []
        }
        let all = (claude + gpt).joined(separator: " · ")
        return all.isEmpty ? [] : [all] + (claude.isEmpty ? [] : [claude[0]])
    }

    /// What's off with reading Claude right now, said where Kikumap is glanced at (the menu-bar icon, the widget): nil
    /// when it reads fine, isn't installed, or is closed (nothing of it runs then).
    func claudeNote() -> String? {
        switch sidebar.status {
        case .noAccess: return tr("Claude 没同步：辅助功能关着", "Claude not synced: Accessibility off")
        case .ok:
            if sidebar.syncIssue != nil { return tr("Claude 没同步", "Claude not synced") }
            return unreadUnsynced ? tr("Claude 的未读没同步", "Claude's unread not synced") : nil
        default: return nil
        }
    }

    /// Claude's unread marks can't be read right now (a status Kikumap doesn't know, or a finish without a mark it
    /// knows): which Claude chats you've read in Claude isn't mirrored, and the window says so.
    private var unreadUnsynced: Bool { sidebar.marksMissed }
    /// ChatGPT's files can't be read right now (the left column says why): what it shows of ChatGPT is as last read.
    private var gptUnsynced: Bool { GPTWatcher.enabled && GPTWatcher.available && gpt.readError != nil }
    private var unreadUnsyncedHelp: String {
        let what = tr("有对话在后台做完了，Claude 却没给它们 Kikumap 认得的未读标记（Claude 可能改了说法）", "Chats finished in the background without an unread mark Kikumap knows (Claude may have reworded it)")
        return what + tr("，所以分不清哪些对话你已经在 Claude 里看过了。\n现在：Claude 对话的未读点不跟 Claude 同步，在这里打开或标为已读才会消失。\n怎么办：更新 Kikumap；或者写一份诊断报告（设置 → 授权）发给开发者。Kikumap 一认出 Claude 的未读标记，就会自动恢复同步。",
                         ", so Kikumap can't tell which chats you've read in Claude.\nMeanwhile: unread dots for Claude chats aren't synced with Claude; they clear when you open a chat here or mark it read.\nFix: update Kikumap, or write a diagnostic report (Settings → Access) and send it. Syncing resumes by itself as soon as Kikumap recognises Claude's unread marks again.")
    }

    /// On hovering the status: what it means, what it holds up, what to do.
    private func syncHelp() -> String {
        switch sidebar.status {
        case .notInstalled: return ""
        case .noAccess:
            return tr("Kikumap 读不了 Claude 的对话列表：辅助功能关着。Claude 里的对话（进行中、未读、置顶）都没同步，看到的是上次读到的样子。\n怎么办：设置 → 授权 → 辅助功能。",
                      "Kikumap can't read Claude's chat list: Accessibility is off. Claude's chats (running, unread, pinned) aren't synced; what you see is as last read.\nFix: Settings → Access → Accessibility.")
        case .noApp:
            return tr("Claude 桌面 App 没在运行。\n不受影响：Claude Code 会话、导图上已有的内容。\n暂停：Claude App 里对话的进行中、做完、未读和置顶同步。\n怎么办：打开 Claude App，会自动接上。",
                      "The Claude desktop app isn't running.\nStill works: Claude Code sessions and everything already on your map.\nPaused: running, finished, unread and pins for chats in the Claude app.\nFix: open Claude; Kikumap picks it up by itself.")
        default:
            if let i = sidebar.syncIssue { return i.help }
            guard sidebar.lastSync != nil else {
                return tr("正在第一次读取 Claude 的侧边栏…", "Reading Claude's sidebar for the first time…")
            }
            if unreadUnsynced { return unreadUnsyncedHelp }
            if gptUnsynced, let e = gpt.readError {
                return tr("ChatGPT 的数据读不了（\(e)），它的对话停在上次读到的样子。Kikumap 每分钟会再试，读到了就自动恢复。", "ChatGPT's data can't be read (\(e)): its threads stay as last read. Kikumap tries again every minute and picks up by itself.")
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

    /// ChatGPT's usage, as its latest answer on this Mac reported it (Codex used elsewhere draws on the same limits):
    /// older than a quarter of an hour it says as of when, as Claude's do; a window that has reset since is unknown
    /// ("–"), not 0%.
    func gptUsageRows() -> [(label: String, window: UsageMonitor.Window?, note: String?)] {
        guard GPTWatcher.enabled && GPTWatcher.available, let u = gpt.usage else { return [] }
        let asOf = Date().timeIntervalSince(u.at) > 900 ? tr("\(UsageMonitor.stamp(u.at)) 时的数据", "as of \(UsageMonitor.stamp(u.at))") : nil
        return u.windows.map { w in
            let label = GPTWatcher.windowLabel(w.minutes)
            if let r = w.resets, r < Date() {
                return (label, nil, tr("\(UsageMonitor.stamp(r)) 已重置", "reset \(UsageMonitor.stamp(r))"))
            }
            return (label, UsageMonitor.Window(percent: w.percent, resets: w.resets), asOf)
        }
    }

    /// Facts that take a file read or a Launch Services lookup, looked up at most every 20 seconds (the left column
    /// redraws every second while it's empty).
    private struct Facts { var hooks = false; var blocked: String?; var claudeCode = false; var claudeFolder = false; var gptOld = false; var gptInstalled = false }
    private var factsCache: (at: Date, facts: Facts)?
    private var facts: Facts {
        if let c = factsCache, Date().timeIntervalSince(c.at) < 20 { return c.facts }
        let f = Facts(hooks: CodeHooks.installed, blocked: CodeHooks.blockedReason(), claudeCode: UsageMonitor.claudeCodeInstalled,
                      claudeFolder: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude"),
                      gptOld: GPTWatcher.oldAppOnly, gptInstalled: GPTWatcher.installed)
        factsCache = (Date(), f)
        return f
    }

    /// What the left column is reading, when it last did and when it will next: a heading and a line per app.
    private func pinStatus() -> (title: String, lines: [String]) {
        let fx = facts
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
        // can Claude's pins be seen at all right now? (only then "pin one and it shows up" is true)
        var claudeReadable = false
        let claudePins = store.chats.filter { !$0.outsideClaude && $0.pinned == true }.count
        switch sidebar.status {
        case .notInstalled: lines.append(tr("Claude：这台 Mac 上没有 Claude App", "Claude: no Claude app on this Mac"))
        case .noAccess: lines.append(tr("Claude：要先开「辅助功能」权限才能读（见顶部「待办」）", "Claude: can't read it until Accessibility is on (see To-do at the top)"))
        case .noApp: lines.append(tr("Claude：App 没打开，打开后会自动开始读", "Claude: the app is closed; reading starts when it opens"))
        case .starting:
            reading = true
            lines.append(tr("Claude：正在连接…", "Claude: connecting…"))
        case .ok:
            if let i = sidebar.syncIssue {
                lines.append(tr("Claude：暂停，", "Claude: paused, ") + i.note)
            } else if let d = sidebar.lastSync {
                claudeReadable = true
                lines.append(tr("Claude：置顶 \(claudePins) 个，", "Claude: \(claudePins) pinned · ") + ago(d) + next(sidebar.nextRead))
            } else {
                reading = true
                lines.append(tr("Claude：正在读侧边栏…", "Claude: reading the sidebar…"))
            }
        }
        var gptReadable = false
        if !GPTWatcher.enabled {
            lines.append(tr("ChatGPT：已关闭（设置 → 授权）", "ChatGPT: off (Settings → Access)"))
        } else if !GPTWatcher.available {
            lines.append(fx.gptOld
                ? tr("ChatGPT：这是旧版 App，更新到新版（Codex 内核）才能读", "ChatGPT: this is the older app; update to the current one (built on Codex) to read it")
                : fx.gptInstalled
                ? tr("ChatGPT：装好了，用过一次后开始读", "ChatGPT: installed; reading starts once you've used it")
                : tr("ChatGPT：这台 Mac 上没找到 ChatGPT 桌面 App", "ChatGPT: the desktop app isn't on this Mac"))
        } else if let e = gpt.readError {
            lines.append(tr("ChatGPT：读不了（", "ChatGPT: can't read it (") + e + tr("），一会儿再试", "); trying again"))
        } else if !fx.gptInstalled && fx.gptOld, let d = gpt.lastRead {
            // the older ChatGPT app keeps no chats here: only Codex in editors and the terminal shows until it's updated
            lines.append(tr("ChatGPT：这是旧版 App，Kikumap 读不到它的对话（更新到新版、Codex 内核的才行）；现在只显示编辑器、终端里的 Codex 会话，",
                            "ChatGPT: this is the older app, whose chats Kikumap can't see (update to the current one, built on Codex); for now only Codex sessions from editors and the terminal show · ") + ago(d) + next(gpt.nextRead))
        } else if !fx.gptInstalled, let d = gpt.lastRead {
            // the app is gone (or never was) but ~/.codex is there: only Codex in editors and the terminal shows
            lines.append(tr("ChatGPT：这台 Mac 上没有 ChatGPT App，只显示编辑器、终端里的 Codex 会话，", "ChatGPT: no ChatGPT app on this Mac, so only Codex sessions from editors and the terminal show · ") + ago(d) + next(gpt.nextRead))
        } else if let d = gpt.lastRead {
            gptReadable = true
            let n = store.chats.filter { $0.isGPT && $0.pinned == true }.count
            lines.append(tr("ChatGPT：置顶 \(n) 个，", "ChatGPT: \(n) pinned · ") + ago(d) + next(gpt.nextRead))
        } else {
            reading = true
            lines.append(tr("ChatGPT：正在读…", "ChatGPT: reading…"))
        }
        let shownList = store.pinnedList()
        let sessions = shownList.filter { $0.isCode || $0.isCodexSession }.count
        var sessionLine = tr("编辑器里的 Claude Code、Codex 会话：显示 \(sessions) 个（运行中、未读，或做完后 12 小时内）",
                             "Claude Code and Codex sessions in editors: \(sessions) shown (while running or unread, and for 12 hours after)")
        if !fx.hooks && (fx.claudeCode || fx.claudeFolder) {
            sessionLine += tr("。Claude Code 还没连接（设置 → 授权）", ". Claude Code isn't connected (Settings → Access)")
        } else if fx.hooks, let why = fx.blocked {
            sessionLine += tr("。注意：", ". Note: ") + why
        }
        lines.append(sessionLine)
        let title = reading ? tr("正在读取置顶…", "Reading your pins…")
            : sidebar.status == .noAccess && !gptReadable ? tr("先开「辅助功能」才能看到 Claude 的置顶", "Turn on Accessibility to see Claude's pins")
            : tr("没有找到置顶对话", "No pinned chats found")
        if !reading && shownList.isEmpty {
            // only promise what's true: "pin it and it shows up" for the apps actually being read
            if claudeReadable && gptReadable {
                lines.append(tr("在 Claude 里置顶对话，或在 ChatGPT 里置顶 Codex 对话，它就会出现在这里。", "Pin a chat in Claude, or a Codex chat in ChatGPT, and it shows up here."))
            } else if claudeReadable {
                lines.append(tr("在 Claude 里置顶一个对话，它就会出现在这里。", "Pin a chat in Claude and it shows up here."))
            } else if gptReadable {
                lines.append(tr("在 ChatGPT 里置顶一个 Codex 对话，它就会出现在这里。", "Pin a Codex chat in ChatGPT and it shows up here."))
            }
        }
        return (title, lines)
    }

    /// Reads everything again now (⟳ in the left column, ⌘R): Claude's sidebar and notifications, ChatGPT, usage.
    func refreshAll() {
        main.sidebar.spinRefresh()
        factsCache = nil
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
        let fx = facts
        if sidebar.status == .noAccess {
            out.append(Todo(id: "accessibility", title: tr("给 Kikumap 开「辅助功能」权限", "Turn on Accessibility for Kikumap"),
                            impact: tr("在那之前读不到 Claude App 里的置顶、进行中和未读。ChatGPT 和 Claude Code 不受影响。",
                                       "Until then, Claude app chats have no pins, running or unread. ChatGPT and Claude Code aren't affected."),
                            action: (tr("去开启", "Turn on"), { [weak self] in self?.perms.openAccessibility() })))
        }
        if sidebar.status == .ok, let i = sidebar.syncIssue {
            out.append(Todo(id: "sync-\(i)", title: i.note, impact: i.help, action: nil))
        }
        if UsageMonitor.enabled {
            let stale = tr("在那之前用量不会更新（显示的是上次读到的数）。", "Until then, usage doesn't update (what's shown is from the last read).")
            let none = tr("在那之前，菜单、窗口和小组件里没有 Claude 的用量。", "Until then, no Claude usage in the menu, the window or the widget.")
            // older numbers are on screen only while they're marked "as of" (set() clears them for .noScope and .denied)
            let until = usage.asOf != nil ? stale : none
            let again: (String, () -> Void) = (tr("重新读取", "Read again"), { [weak self] in self?.usage.reconnect() })
            let off: (String, () -> Void) = (tr("关闭用量", "Turn off usage"), { [weak self] in self?.perms.disconnectUsage(); self?.refreshUI() })
            switch usage.status {
            case .noLogin where !fx.claudeCode:
                out.append(Todo(id: "usage-login", title: tr("Claude 用量需要 Claude Code", "Claude usage needs Claude Code"),
                                impact: tr("用量通过这台 Mac 上 Claude Code 的登录读取：安装 Claude Code，在终端运行 claude，输入 /login，用你的付费 Claude 账号（Pro、Max、Team 或 Enterprise）登录。免费套餐和 API key 没有用量可看，那就关掉用量。",
                                           "Usage is read through Claude Code's sign-in on this Mac: install Claude Code, run claude in Terminal, type /login and sign in with your paid Claude account (Pro, Max, Team or Enterprise). The Free plan and API keys have no usage to show: then just turn usage off."),
                                action: off))
            case .noLogin:
                out.append(Todo(id: "usage-login", title: tr("用量要 Claude Code 登录", "Usage needs Claude Code signed in"),
                                impact: tr("在终端运行 claude（或在 VS Code、Cursor 的 Claude Code 面板里），输入 /login，选 Claude 付费账号（Pro、Max、Team 或 Enterprise）。如果这里的 Claude Code 用的是 API key，这会把 Claude Code 本身换成你的套餐计费；想保留 API key 就关掉用量。免费套餐，以及通过 Bedrock、Vertex 或网关用的 Claude Code，都没有用量可看。",
                                           "Run claude in Terminal (or open the Claude Code panel in VS Code or Cursor), type /login and choose your paid Claude account (Pro, Max, Team or Enterprise). If Claude Code here uses an API key, this switches Claude Code itself to your plan; to keep the key, turn usage off. The Free plan, and Claude Code through Bedrock, Vertex or a gateway, have no usage to show."),
                                action: again))
            case .noScope:
                out.append(Todo(id: "usage-scope", title: usage.hint,
                                impact: tr("在终端运行 claude（或在编辑器的 Claude Code 面板里），输入 /login 重新登录一次。\n", "Run claude in Terminal (or the Claude Code panel in your editor) and type /login again.\n") + until, action: again))
            case .expired:
                out.append(Todo(id: "usage-expired", title: usage.hint, impact: until, action: again))
            case .denied:
                out.append(Todo(id: "usage-denied", title: usage.hint,
                                impact: tr("点「重新读取」，macOS 问的时候选「允许」（Claude Code 续登录后它可能会再问）。\n", "Click Read again and choose Allow when macOS asks (it may ask again after Claude Code renews its sign-in).\n") + until,
                                action: again))
            case .error where (usage.updated.map { Date().timeIntervalSince($0) > 900 } ?? true):
                out.append(Todo(id: "usage-error", title: usage.hint,
                                impact: tr("Kikumap 每 5 分钟会自动再试；看看网络是否正常。", "Kikumap tries again every 5 minutes by itself; check that the Mac is online."),
                                action: (tr("现在再试", "Try now"), { [weak self] in self?.usage.refreshNow() })))
            default: break
            }
        }
        if fx.hooks, let why = fx.blocked {
            out.append(Todo(id: "code-blocked", title: tr("Claude Code 不运行 Kikumap 的 hook", "Claude Code won't run Kikumap's hooks"),
                            impact: why + tr("。在那之前终端、VS Code 里的会话不显示进行中和未读。", ". Until then, sessions in Terminal or VS Code don't show running or unread."),
                            action: nil))
        }
        // never asked about starting at login (the intro closed early, an update from 0.9, a first run from the disk image)
        if let t = LoginItem.todo({ [weak self] in self?.refreshUI() }) { out.append(t) }
        // data that couldn't be read or saved: what happened, and where the file is
        if let a = store.approvalAsked, Date().timeIntervalSince(a) < 1800 {
            let t = Clock.format(a, "HH:mm", "HH:mm")
            // (one id per request: ignoring one doesn't silence the next)
            out.append(Todo(id: "claude-approval-\(Int(a.timeIntervalSince1970))", title: tr("Claude 在等你批准", "Claude is waiting for your approval"),
                            impact: tr("\(t) Claude 问了一次「允许吗？」，但它的通知没说是哪个对话，Kikumap 又看不到 Claude 的窗口（关了，或在别的桌面）。打开 Claude 看看。",
                                       "At \(t) Claude asked for an approval, but its notification doesn't say in which chat, and Kikumap can't see Claude's window (closed, or on another desktop). Open Claude to answer."),
                            action: (tr("打开 Claude", "Open Claude"), {
                                if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
                                    NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration())
                                }
                            })))
        }
        if unreadUnsynced && sidebar.status == .ok {
            out.append(Todo(id: "unread-unsynced", title: tr("Claude 的未读标记认不出来", "Claude's unread marks aren't recognised"),
                            impact: unreadUnsyncedHelp,
                            action: (tr("诊断报告", "Diagnostic report"), { [weak self] in self?.diagnose() })))
        }
        let unreadable = store.unreadable + [archive.unreadable].compactMap { $0 }
        if !unreadable.isEmpty {
            out.append(Todo(id: "data-unreadable", title: tr("有数据文件读不了，已另存", "A data file couldn't be read and was kept aside"),
                            impact: tr("读不了的文件已原样留在 ", "The unreadable file was kept as it was in ") + unreadable.joined(separator: ", ")
                                + tr("。Kikumap 从空白开始记，没有覆盖它。", ". Kikumap started that part afresh without writing over it."),
                            action: (tr("打开数据文件夹", "Open data folder"), { [weak self] in
                                guard let self = self else { return }
                                NSWorkspace.shared.activateFileViewerSelecting([self.store.dir.appendingPathComponent("data")])
                            })))
        }
        if let why = store.map.saveError {
            out.append(Todo(id: "map-unsaved", title: tr("导图存不进去", "The map can't be saved"),
                            impact: tr("map.json 存不了：\(why)。磁盘满了，或者数据文件夹没有写入权限？腾出空间后会自动再存。",
                                       "map.json can't be saved: \(why). Is the disk full, or the data folder not writable? It saves again by itself once there's room."),
                            action: nil))
        }
        if let (file, why) = store.failed.first.map({ ($0.key, $0.value) }) ?? archive.saveError.map({ ("archive.json", $0) }) {
            out.append(Todo(id: "data-unsaved", title: tr("有改动存不进去", "Changes can't be saved"),
                            impact: tr("\(file) 存不了：\(why)。磁盘满了，或者数据文件夹没有写入权限？腾出空间后会自动再存。",
                                       "\(file) can't be saved: \(why). Is the disk full, or the data folder not writable? It saves again by itself once there's room."),
                            action: nil))
        }
        if let p = store.rulesProblem {
            out.append(Todo(id: "rules", title: tr("rules.json 有错，先用内置规则", "rules.json has a mistake; using the built-in rules"),
                            impact: p + tr("。改好 data/rules.json，或者删掉它恢复默认。", ". Fix data/rules.json, or delete it to get the defaults back."), action: nil))
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
        // a Claude Code session or a ChatGPT thread with no record left has nowhere to open (not even in Claude)
        guard store.canOpen(id) else { NSSound.beep(); return }
        if let c = store.chat(id), c.isGPT {
            store.markSeen([id])
            // a Codex session from VS Code opens its folder there, like a Claude Code session
            if c.isCodexSession { openCode(c) } else { GPTWatcher.open(String(id.dropFirst(4))) }
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
        let unreadable = store.unreadable + [archive.unreadable].compactMap { $0 }
        let unsaved = store.failed.keys.sorted() + (store.map.saveError == nil ? [] : ["map.json"]) + (archive.saveError == nil ? [] : ["archive.json"])
        return """
            # Kikumap check \(Clock.iso())
            # Send this file when something doesn't work. It has no chat titles, messages or keys.

            Kikumap \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch) · languages \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))
            App at \(Bundle.main.bundlePath.replacingOccurrences(of: home, with: "~")) · data in \(store.dir.path.replacingOccurrences(of: home, with: "~"))

            Claude app: \(version(claudeBundleID)) · \(sidebar.claudePID != 0 ? "running" : "not running")
            Accessibility: \(AXIsProcessTrusted() ? "on" : "off")
            Sidebar: \(sidebar.status) · last read \(ago(sidebar.lastSync)) · \(sidebar.syncNote ?? "no problem")\(sidebar.marksMissed ? " · Claude's unread marks not recognised lately (unread not synced)" : "")\(sidebar.unknownMark.map { " · unknown row status: '\($0)'" } ?? "")
            Chats: Claude \(claude.count) (pinned \(claude.filter { $0.pinned == true }.count)) · Claude Code \(codeChats.count) · ChatGPT \(gptChats.count) (pinned \(gptChats.filter { $0.pinned == true }.count)) · in the sidebar \(store.pinnedList().count)

            Notifications (Full Disk Access): \(notifications.status)\(notifications.problem.map { " · " + $0 } ?? "")

            Claude Code: ~/.claude \(FileManager.default.fileExists(atPath: home + "/.claude") ? "found" : "missing") · hooks \(CodeHooks.installed ? "connected" : "not connected")\(CodeHooks.blockedReason().map { " · blocked: " + $0 } ?? "")
            Usage: \(UsageMonitor.enabled ? "on" : "off") · \(usage.status) · updated \(ago(usage.updated))

            ChatGPT app: \(version(GPTWatcher.bundleID))\(GPTWatcher.oldAppOnly ? " (only the older app is installed)" : "") · its data \(GPTWatcher.available ? "found" : "missing") · reading \(GPTWatcher.enabled ? "on" : "off") · usage \(gpt.usage == nil ? "none yet" : "found")\(gpt.readError.map { " · error: " + $0 } ?? "")

            Data: \(unreadable.isEmpty ? "all read" : "kept aside: " + unreadable.joined(separator: ", "))\(unsaved.isEmpty ? "" : " · can't save: " + unsaved.joined(separator: ", "))\(store.rulesProblem.map { " · rules: " + $0 } ?? "")
            Start at login: \(LoginItem.enabled ? "on" : "off")

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
        let edit = NSMenu(title: tr("编辑", "Edit"))
        edit.addItem(withTitle: tr("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: tr("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: tr("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: tr("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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

    func registerHotKey() {
        unregisterHotKey()
        if !hotKeyHandlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, me, nil)
            hotKeyHandlerInstalled = true
        }
        // a shortcut from before the two-modifier rule (⌘ alone would take that key from every app): back to ⌃⌥C,
        // also while it's off, so Settings shows the one that switching it on registers
        let strong = [controlKey, optionKey, cmdKey].filter { Prefs.hotKeyMods & UInt32($0) != 0 }.count
        if strong < 2 { Prefs.hotKeyCode = UInt32(kVK_ANSI_C); Prefs.hotKeyMods = UInt32(controlKey | optionKey) }
        guard Prefs.hotKeyEnabled else { return }
        let hkID = EventHotKeyID(signature: OSType(0x4343_4F4E), id: 1)
        let status = RegisterEventHotKey(Prefs.hotKeyCode, Prefs.hotKeyMods, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil; store.log("\(Clock.iso()) shortcut \(Prefs.hotKeyLabel()) couldn't be registered (\(status))\n", file: "app.log") }
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
