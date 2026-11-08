import Cocoa
import Carbon

private func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData = userData else { return OSStatus(noErr) }
    let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { app.toggleMap() }
    return OSStatus(noErr)
}

/// While one of KIKUmap's windows is open it's a regular app — the menu bar is its own, and it's in the Dock and
/// ⌘-Tab; with all of them closed it lives in the menu bar only again.
@MainActor
enum Front {
    /// Comes forward to show a window.
    static func activate() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if NSApp.isHidden { NSApp.unhide(nil) }            // hidden with ⌘H: its windows come back too
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
    /// ChatGPT's window, for its pinned ordinary chats' status.
    lazy var gptChats = GPTSidebarWatcher()
    lazy var gptUsage = GPTUsageMonitor()
    lazy var perms = Permissions(notifications: notifications, sidebar: sidebar, usage: usage, gptUsage: gptUsage)
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
    /// A newer copy of KIKUmap asked this one to quit.
    private var handingOver = false
    /// In takeOver(), before anything is loaded.
    private var takingOver = false
    /// Watches for KIKUmaps too old to ask for the handover; the ones stopped so far.
    private var launches: NSKeyValueObservation?
    private var stopped = Set<pid_t>()
    /// KIKUmaps that asked for the handover, and ones whose build can't be read being watched (see `watchLaunches`).
    private var askers = Set<pid_t>()
    private var watched = Set<pid_t>()
    private let launched = Date()
    private var widgetTimer: Timer?
    private var archiveTimer: Timer?
    /// SIGTERM, heard as Quit (see `quitOnTerm`).
    private var termSource: DispatchSourceSignal?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false
    /// Sessions whose name is being read from their transcript (one read each at a time).
    private var titlesQueued = Set<String>()
    /// What the usage meters showed last (they change by themselves when a window resets).
    private var metersShown = ""
    /// What was said last of ChatGPT's sync and of the scheduled tasks' list (these change with nothing to redraw them
    /// too: ChatGPT's files stop being read, or start again, without a word; the list ages).
    private var notesShown = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        takeOver()
        termSource = AppDelegate.quitOnTerm { NSApp.terminate(nil) }
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
        main.map.onManageTags = { [weak self] in self?.settings.show(tab: SettingsWindow.tagsTab) }
        main.onShowShortcuts = { [weak self] in self?.settings.show(tab: SettingsWindow.shortcutsTab) }
        main.tags.onManage = { [weak self] in self?.settings.show(tab: SettingsWindow.tagsTab) }
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
        // a new color set: the menu-bar icon draws again too (the windows already do)
        NotificationCenter.default.addObserver(forName: Theme.paletteChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusBar.update() }
        }
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
        statusBar.gptPlan = { [weak self] in self?.gpt.plan }
        statusBar.gptUsageNote = { [weak self] in self?.gptUsageNote() }
        statusBar.claudeNote = { [weak self] in self?.claudeNote() }
        statusBar.gptNote = { [weak self] in self?.gptNote() }
        statusBar.accessOffForBoth = { [weak self] in self?.accessOffForBoth() ?? false }
        statusBar.gptWindowIssue = { [weak self] in GPTWatcher.enabled ? self?.gptChats.issue : nil }
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
        // chat titles that versions up to 1.0.8 wrote in logs/archive.log go, once (nothing writes there this early)
        let logs = store.logsDir
        DispatchQueue.global(qos: .utility).async { ArchiveLog.forgetOld(in: logs) }
        settings.onArchiveAll = { [weak self] in self?.archiveAll() }
        settings.onImport = { [weak self] in self?.importArchive() }
        exportWin.onImport = { [weak self] in self?.importArchive() }
        exportWin.confirmMemory = { [weak self] n, again in self?.confirmArchive(n, every: again ? Archive.everyDays : nil) ?? false }
        archive.pid = { [weak self] in self?.sidebar.claudePID ?? 0 }
        archive.onChange = { [weak self] in self?.refreshUI(); self?.settings.refreshArchive() }
        store.onIDMove = { [weak self] old, new in self?.archive.moved(old, to: new) }
        store.frontApp = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        store.frontWindowTitle = {
            guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.0)
            var w: CFTypeRef?, t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success,
                  let win = w, CFGetTypeID(win) == AXUIElementGetTypeID(),
                  AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success else { return nil }
            return t as? String
        }
        store.otherWindowTitles = {
            AppDelegate.otherWindowTitles(tabs: !Store.titledByProject(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""))
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let b = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.store.appCameToFront(b) }
        }
        // Claude or ChatGPT left the front: a reply that finished there a moment before is still one you watched
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let b = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if b == claudeBundleID { self?.store.claudeLeftFront() }
                if b == GPTWatcher.bundleID { self?.store.gptLeftFront() }
            }
        }
        // KIKUmap in front: the widget's redraws are free then, so a widget left behind catches up
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.widget.caughtUp() }
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
            // (quiet only while KIKUmap works Claude's window itself: an export of just the files leaves it alone)
            if !self.archive.drivesClaude { self.sounds.play(ev) }
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
            // the archive's own replies stay quiet (a run of just the files has none); "Claude in front" as the read
            // judged its finishes, not as of now
            if !self.archive.drivesClaude { self.sounds.play(ev, claudeFront: self.store.claudeWasFront) }
            self.refreshUI()                 // the "synced · just now" line
        }
        sidebar.onQuit = { [weak self] in self?.store.clearRunning() }
        code.onEvents = { [weak self] evs in
            guard let self = self else { return }
            // lines written while KIKUmap wasn't running update the sessions quietly
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
            self.store.readCodeInFront()          // finished while you're looking at it in its app
        }
        gpt.onThreads = { [weak self] threads, unread, pinsRead in
            guard let self = self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == GPTWatcher.bundleID
            let ev = self.store.apply(gpt: threads, unread: unread, pinsRead: pinsRead, front: front)
            self.sounds.play(ev, gptFront: self.store.gptWasFront)     // (in front since they finished, not as of now)
            self.store.readCodeInFront()          // a Codex session finished while you're looking at it in VS Code
            self.widget.update()                                   // ChatGPT's usage may have moved
            if self.gpt.usage != self.shownGPTUsage { self.shownGPTUsage = self.gpt.usage; self.refreshUI() }
        }
        gptChats.names = { [weak self] in self?.store.gptChatNames ?? [] }
        gptChats.anyRunning = { [weak self] in self?.store.gptChatRunning ?? false }
        gptChats.onRead = { [weak self] rows, open in
            guard let self = self else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == GPTWatcher.bundleID
            let ev = self.store.apply(gptWindow: rows, open: open, front: front)
            self.sounds.play(ev, gptFront: self.store.gptWasFront)     // (as the read judged its finishes, not as of now)
        }
        gptChats.onIssue = { [weak self] in self?.refreshUI() }
        sidebar.onStatus = { [weak self] in
            guard let self = self else { return }
            // Claude can't be read now (Accessibility off, the app closed or gone): its running chats' time waits
            if self.sidebar.status != .ok { self.store.pause(self.store.running) }
            self.refreshUI()
        }
        usage.onChange = { [weak self] in self?.refreshUI() }
        usage.log = { [weak self] t in self?.store.log(Clock.iso() + " " + t + "\n", file: "usage.log") }
        // ChatGPT's usage straight from OpenAI, when allowed: the newer of it and Codex's logs is shown
        gptUsage.onChange = { [weak self] in
            guard let self = self else { return }
            self.gpt.fetchedUsage = self.gptUsage.usage
            self.widget.update()
            self.refreshUI()
        }
        gptUsage.log = { [weak self] t in self?.store.log(Clock.iso() + " " + t + "\n", file: "usage.log") }

        notifications.start()
        SyncIssue.alerts = notifications.status == .ok
        CodeHooks.upgradeIfNeeded()          // connected by an older version: its hooks brought up to date
        LoginItem.follow()                   // a login item left pointing at a moved or older copy points here
        code.start()
        gpt.start()
        gptChats.start()
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
        // the screens on again: should the wake notice ever not come, the runs going on count again from here
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.screensWoke() }
        }
        refreshUI()
        widget.update(force: true)          // the widget may still say "not running" from the last quit
        // the desktop widget's chart moves on while chats run; and a note of when KIKUmap was last alive,
        // so runs left open by a crash end there
        widgetTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                UserDefaults.standard.set(Clock.iso(), forKey: "AliveAt")
                // a Claude Code turn ended without a word (Esc, a closed terminal) stops counting
                self.store.expireCode()
                // a finished Claude Code session's window came to the front within its app (no app switch to hear)
                self.store.readCodeInFront()
                // Claude closed for hours: its runs last seen then are no longer said to run
                self.store.forgetUnseenRuns()
                // files that couldn't be saved (a full disk, a folder that can't be written) are tried again
                self.retrySaves()
                // a usage window reset (or its numbers aged): the meters change by themselves; so do the notes
                if self.meterSignature() != self.metersShown || self.noteSignature() != self.notesShown { self.refreshUI() }
                self.widget.update()
            }
        }
        // nothing until usage was turned on; then it reads during a resumed intro too (relaunched by Quit & Reopen)
        usage.start()
        gptUsage.start()
        if !Prefs.onboarded {
            intro.show(resume: true)
        } else {
            // started at login → stay in the menu bar; started by hand → show the map
            if !CommandLine.arguments.contains("--background") { main.show() }
        }
    }

    /// A run that pastes and copies through the clipboard (summaries, or an import) is stopped first: the quit waits, a
    /// few seconds at most, until what you had copied is back on the clipboard. A newer copy taking over waits the same
    /// way; a run that only reads Claude's export zip doesn't hold it up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard archive.holdsClipboard else { return .terminateNow }
        archive.stopForQuit { self.replyToQuit(true) }
        return .terminateLater
    }
    /// (a test stands in for it)
    var replyToQuit: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    func applicationWillTerminate(_ notification: Notification) {
        // (in case a run still has the clipboard: what you had copied goes back, and nothing more is pasted)
        archive.closeClipboard()
        store.closeRuns(at: Date(), quitting: true)
        retrySaves()
        // handing over to a newer copy: it fills the widget in; don't tell it KIKUmap stopped
        if !handingOver { widget.closing() }
    }

    /// SIGTERM (a plain `kill`; Install.command replacing KIKUmap) quits the ordinary way, as Quit does, so the step above
    /// runs: the runs being timed end as they should, and what's in memory is saved. Left to itself it would just stop the app.
    static func quitOnTerm(_ quit: @escaping @MainActor () -> Void) -> DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)                  // (heard by the source below instead)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { MainActor.assumeIsolated { quit() } }
        s.resume()
        return s
    }

    /// One KIKUmap at a time: a copy opened while another runs (an update, a second install) takes over, and
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
            // a newer KIKUmap is running: it stays, and shows its map once the reopen has reached it (not when this
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

    /// What this KIKUmap does when another (build `theirs`; nil: 0.9.5 builds 13 and 14, which don't say) asks it
    /// to quit: the newer build stays, and the older one quits (`.quit`) or, while it starts, is stopped (`.stop`).
    /// Of the same build the copy already running gives way; of two starting at once the higher process number
    /// stays and asks again (`.stay`), in case the other wasn't listening yet when it first asked.
    enum Handover { case quit, stay, stop }
    static func handover(mine: Int, theirs: Int?, me: Int32, other: Int32, starting: Bool) -> Handover {
        let t = theirs ?? 0
        if t != mine { return t > mine ? .quit : .stop }
        return starting && other < me ? .stay : .quit
    }

    /// A KIKUmap's build, read from its bundle each time (nil: unreadable, or somewhere macOS would first ask
    /// whether KIKUmap may look: Desktop, Documents, Downloads, iCloud Drive, a disk image or another volume).
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

    /// KIKUmaps from before the handover never ask: one opened while this one runs is stopped as it starts, and
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
                self.store.log("\(Clock.iso()) stopped an older KIKUmap that didn't ask to take over (\(app.bundleURL?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "?"))\n", file: "app.log")
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
        widget.woke()           // (its redraw paced: wakes come often)
    }

    /// Claude's meters as they'd be shown now (the 5-hour session where the plan has it, the week, and a one-model
    /// week while it's the one that holds you back): name, percent, under-text.
    private func claudeMeters() -> [(String, Double?, String)] {
        guard usage.session != nil || usage.weekly != nil else { return [] }
        let asOf = usage.asOfText
        var m: [(String, Double?, String)] = []
        if usage.session != nil { m.append((tr("会话", "Session"), usage.shownSession?.percent, asOf ?? Clock.resets(usage.shownSession?.resets))) }
        if usage.weekly != nil { m.append((tr("本周", "Week"), usage.shownWeekly?.percent, asOf ?? Clock.resets(usage.shownWeekly?.resets))) }
        if let s = usage.bindingSonnet { m.append((usage.modelName, s.percent, asOf ?? Clock.resets(s.resets))) }
        return m
    }

    private func meterSignature() -> String {
        (claudeMeters().map { "\($0.0)\($0.1 ?? -1)\($0.2)" } + gptUsageRows().map { "\($0.label)\($0.window?.percent ?? -1)\($0.window?.resets?.timeIntervalSince1970 ?? 0)\($0.note ?? "")" })
            .joined(separator: "|")
    }

    private func noteSignature() -> String {
        (gptNote() ?? "") + "|" + (usage.routinesAsOf.map { "\($0.timeIntervalSince1970)" } ?? "") + "|" + (usage.routinesUnknown ?? "")
    }

    func refreshUI() {
        statusBar.update()
        let h = main.header
        // (what the menu-bar icon counts: its "?" after the ring, its "!" before the red count)
        h.show(counts: StatusBar.counts(store))
        h.meters = UsageMonitor.enabled ? claudeMeters() : []
        h.usageHint = ""
        metersShown = meterSignature()
        notesShown = noteSignature()
        h.gptMeters = gptUsageRows().map { ($0.label, $0.window?.percent, $0.note ?? Clock.resets($0.window?.resets)) }
        let all = todos()
        h.todoCount = all.isEmpty ? nil : Todos.open(all).count
        let run = archiveStatus()
        h.liveText = run?.text ?? syncText()
        h.liveImportant = run != nil || sidebar.syncIssue != nil || sidebar.status == .noApp || sidebar.status == .noAccess || unreadUnsynced || gptUnsynced
        h.liveShort = run?.short ?? syncShort()
        h.liveHelp = run?.help ?? syncHelp()
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

    /// What the top bar says while an export or import runs (nil: none is), in fewer words for a narrow window too, and
    /// on hovering it. Claude's window is to be left alone only while KIKUmap works it: not while an export only writes
    /// the files from Claude's export zip.
    func archiveStatus() -> (text: String, short: [String], help: String)? {
        guard archive.busy else { return nil }
        // ("3/12 · title" while it goes chat by chat; a step of its own, such as reading the export, said as it is)
        let doing = archive.importing ? tr("正在导入", "Importing") : tr("正在存档", "Archiving")
        let step = archive.progress.isEmpty ? doing : archive.progress.first?.isNumber == true ? doing + " " + archive.progress : doing + " · " + archive.progress
        let hands = archive.drivesClaude ? tr(" · 请先别动 Claude 窗口", " · leave the Claude window alone") : ""
        // shorter, for a narrow window: without the chat's title
        let count = archive.progress.first?.isNumber == true ? " " + (archive.progress.components(separatedBy: " · ").first ?? "") : ""
        let help = archive.importing
            ? tr("KIKUmap 正在把导出的对话一个个开成新对话，所以会自己在 Claude 窗口里操作。\n等它做完再用 Claude 窗口；想停下就点右边的「停止」。",
                 "KIKUmap is starting a new chat in Claude for each exported one, so it works in Claude's window by itself.\nLeave that window alone until it's done, or click \"Stop\".")
            : archive.drivesClaude
            ? tr("KIKUmap 正在让 Claude 给每个对话写交接总结，所以会自己在 Claude 窗口里切换对话。\n等它做完再用 Claude 窗口；想停下就点右边的「停止」。",
                 "KIKUmap is asking Claude to write a hand-off summary in each chat, so it switches chats in Claude's window by itself.\nLeave that window alone until it's done, or click \"Stop\".")
            : tr("KIKUmap 正在用 Claude 的官方导出包写每个对话的文件（提示词、完整对话、artifacts 和附件），不碰 Claude 窗口。\n想停下就点右边的「停止」。",
                 "KIKUmap is writing each chat's files from Claude's data export (prompts, the whole conversation, artifacts and attachments). It doesn't touch Claude's window.\nTo stop, click \"Stop\".")
        return (step + hands, hands.isEmpty ? [doing + count] : [doing + count + hands, doing + count], help)
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

    /// What's off with reading Claude right now, said where KIKUmap is glanced at (the menu-bar icon, the widget): nil
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

    /// What's off with reading ChatGPT right now, said in the window ("ChatGPT not synced") and, as Claude's is, where
    /// KIKUmap is glanced at (the menu-bar icon); nil: nothing. Its files can't be read (the left column says why): what
    /// it shows of ChatGPT is as last read. Or its window can't be read for the ordinary chats: always said when
    /// something's in the way (Accessibility, the sidebar hidden, the chats not found), and while a chat that was running
    /// is out of sight when the window is just covered or ChatGPT closed (that's often, and nothing else is held up then).
    func gptNote() -> String? {
        if gptDataUnreadable { return tr("ChatGPT 没同步：它的数据读不了", "ChatGPT not synced: its data can't be read") }
        return gptWindowIssue.map { tr("ChatGPT 没同步：", "ChatGPT not synced: ") + $0.note }
    }

    /// ChatGPT's files can't be read (whether they're there at all is looked up only once reading them has failed).
    private var gptDataUnreadable: Bool { gpt.readError != nil && GPTWatcher.enabled && GPTWatcher.available }

    /// What `claudeNote` and `gptNote` say both comes from Accessibility being off: the menu bar says it once, for both,
    /// as the header's help does (any other cause gets a line of its own).
    func accessOffForBoth() -> Bool { sidebar.status == .noAccess && !gptDataUnreadable && gptWindowIssue == .noAccess }

    /// Claude's unread marks can't be read right now (a status KIKUmap doesn't know, or a finish without a mark it
    /// knows): which Claude chats you've read in Claude isn't mirrored, and the window says so.
    private var unreadUnsynced: Bool { sidebar.marksMissed }
    /// ChatGPT can't be read right now (see `gptNote`: the window and the menu bar go by the same).
    private var gptUnsynced: Bool { gptNote() != nil }
    private var gptWindowIssue: GPTSidebarIssue? {
        guard GPTWatcher.enabled, let i = gptChats.issue else { return nil }
        return !i.passing || store.gptChatUnseen ? i : nil
    }
    private var unreadUnsyncedHelp: String {
        tr("有对话在后台做完了，Claude 的对话列表里却没出现 KIKUmap 认得的未读标记。可能是 Claude 自己的问题（它最近更新后，也有别人发现列表上的状态点不见了），也可能是 Claude 换了标记的样子。\n现在：Claude 对话的未读点不跟 Claude 同步，在这里打开或标为已读才会消失。\n不用做什么：Claude 一恢复标未读，KIKUmap 就会自己恢复同步，这条也会消失。一直不好的话，可以写一份诊断报告（设置 → 授权）发给开发者。",
           "Chats finished in the background, but Claude's chat list showed no unread mark KIKUmap knows. Claude may have stopped showing it (since its recent update, others see the status dots missing from its list too), or changed how it looks.\nMeanwhile: unread dots for Claude chats aren't synced with Claude; they clear when you open a chat here or mark it read.\nNothing to do: once Claude marks unread chats again, syncing comes back by itself and this goes away. If it stays, write a diagnostic report (Settings → Access) and send it to the developer.")
    }

    /// On hovering the status: what it means, what it holds up, what to do.
    private func syncHelp() -> String {
        // what's off with ChatGPT, after what's off with Claude (Accessibility off is said once, for both)
        let both = sidebar.status == .noAccess && gptWindowIssue == .noAccess
        let g = both && gpt.readError == nil ? nil : gptHelp
        let also = g.map { "\n\n" + $0 } ?? ""
        switch sidebar.status {
        case .notInstalled: return g ?? ""
        case .noAccess:
            return (both ? tr("KIKUmap 读不了 Claude 的对话列表和 ChatGPT 的窗口：辅助功能关着。", "KIKUmap can't read Claude's chat list or ChatGPT's window: Accessibility is off. ")
                         : tr("KIKUmap 读不了 Claude 的对话列表：辅助功能关着。", "KIKUmap can't read Claude's chat list: Accessibility is off. "))
                + tr("Claude 里的对话（在跑、未读、置顶）都没同步，看到的是上次读到的样子。\n", "Claude's chats (running, unread, pinned) aren't synced; what you see is as last read.\n")
                + (both ? GPTSidebarIssue.paused : "")
                + tr("怎么办：设置 → 授权 → 辅助功能。", "Fix: Settings → Access → Accessibility.") + also
        case .noApp:
            return tr("Claude 桌面 App 没在运行。\n不受影响：Claude Code 会话、导图上已有的内容。\n暂停：Claude App 里对话的在跑、做完、未读和置顶。\n怎么办：打开 Claude App，会自动接上。",
                      "The Claude desktop app isn't running.\nStill works: Claude Code sessions and everything already on your map.\nPaused: running, finished, unread and pins for chats in the Claude app.\nFix: open Claude; KIKUmap picks it up by itself.") + also
        default:
            if let i = sidebar.syncIssue { return i.help + also }
            guard sidebar.lastSync != nil else {
                return tr("正在第一次读取 Claude 的侧边栏…", "Reading Claude's sidebar for the first time…")
            }
            if unreadUnsynced { return unreadUnsyncedHelp + also }
            if let g { return g }
            return tr("一切正常：KIKUmap 刚读过 Claude 的侧边栏，Claude 一有变化就会再读。不需要做什么。",
                      "All good: KIKUmap just read Claude's sidebar and reads it again whenever Claude changes. Nothing to do.")
        }
    }

    /// What's off with reading ChatGPT, if anything: its files, or its window for the ordinary chats.
    private var gptHelp: String? {
        if GPTWatcher.enabled && GPTWatcher.available, let e = gpt.readError {
            return tr("ChatGPT 的数据读不了（\(e)），它的对话停在上次读到的样子。KIKUmap 每分钟会再试，读到了就自动恢复。", "ChatGPT's data can't be read (\(e)): its chats stay as last read. KIKUmap tries again every minute and picks up by itself.")
        }
        return gptWindowIssue?.help
    }

    // MARK: archive

    /// Before every run: say what's about to happen. `every`: automatic updates are on, so it happens again on its
    /// own every so many days, while you're away; this yes is what lets it. `one`: a chat archived by right-click.
    private func confirmArchive(_ count: Int, every days: Int? = nil, one: Bool = false) -> Bool {
        let said = AppDelegate.archiveDialog(count, every: days, one: one)
        let a = NSAlert()
        a.messageText = said.title
        a.informativeText = said.text
        a.addButton(withTitle: tr("开始", "Start"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    /// What that dialog says. A run over chosen chats skips those running, unread or unchanged; one chat by right-click
    /// (`one`) is asked whatever it shows, so that's said instead (one that's running never gets this far).
    static func archiveDialog(_ count: Int, every days: Int?, one: Bool) -> (title: String, text: String) {
        var again = ""
        if let d = days {
            let zh = d == 1 ? "每天" : d == 30 ? "每月" : "每周", en = d == 1 ? "every day" : d == 30 ? "every month" : "every week"
            again = tr("\n· 开着「自动更新」：以后\(zh)会自己再这样做一遍，在 Mac 闲置 10 分钟以上、你不在的时候（Claude App 要开着）；你一回来就停下",
                       "\n· With \"Keep it updated\" on, this happens again on its own \(en), once the Mac has been idle for 10 minutes, while you're away (with the Claude app open); it stops as soon as you're back")
        }
        let downloads = Archive.asksNote.map { "\n\n" + $0 } ?? ""
        let clipboard = AppDelegate.summaryClipboard
        if one {
            return (tr("让 Claude 写交接总结（memory）", "Have Claude write a hand-off summary (memory)"), tr("""
            会在 Claude App 里打开这个对话，发一条消息请 Claude 写交接总结，再把总结存成 memory.md（\(Archive.folder.path)）。

            · 就算上次总结后没有新内容，也会再问一次：多一轮问答，用掉一点额度
            · 在 Claude 里打开后，Claude 会把它当作已读
            · 运行时 Claude 窗口会自己切到这个对话，先别动它（顶栏可以随时停止）
            · \(clipboard.zh)
            """, """
            The Claude app will open this chat, send a message asking Claude for a hand-off summary, and save the reply as memory.md (\(Archive.folder.path)).

            · It's asked even if nothing changed since the last summary: one more exchange, which uses a little of your quota
            · Once it's open in Claude, Claude treats it as read
            · The Claude window switches to this chat while this runs — leave it alone (you can stop from the top bar)
            · \(clipboard.en)
            """) + downloads)
        }
        return (tr("让 Claude 写交接总结（memory）", "Have Claude write hand-off summaries (memory)"), tr("""
        会在 Claude App 里依次打开\(count == 1 ? "这个对话" : "这 \(count) 个对话")，发一条消息请 Claude 写交接总结，再把总结存成 memory.md（\(Archive.folder.path)）。

        · 每个对话会多一轮问答，用掉一点额度
        · 运行时 Claude 窗口会自己切换对话，先别动它（顶栏可以随时停止）
        · 正在跑、未读、没有新内容的对话会跳过
        · \(clipboard.zh)
        """, """
        The Claude app will open \(count == 1 ? "this chat" : "these \(count) chats") in turn, send a message asking Claude for a hand-off summary, and save the reply as memory.md (\(Archive.folder.path)).

        · Each chat gets one more exchange, which uses a little of your quota
        · The Claude window switches chats while this runs — leave it alone (you can stop from the top bar)
        · Chats that are running, unread or unchanged are skipped
        · \(clipboard.en)
        """) + again + downloads)
    }

    /// How a summary run uses the clipboard (the export window's note says it too): Claude's Copy button can't be told to
    /// keep the summary out of clipboard history apps; what you had copied goes back right after.
    static let summaryClipboard = (zh: "每份总结要经过 Claude 的复制按钮，剪贴板历史类 App 可能会存下它；之后马上放回你原来的剪贴板",
                                   en: "Each summary comes through Claude's Copy button, so a clipboard history app may keep it; your clipboard is put back right after")

    /// Right-click → Archive a summary…: a chat that's running isn't opened at all, so that's said and nothing is
    /// asked (nor once you've said yes, if it started meanwhile).
    func archiveOne(_ id: String) {
        // (while an export or import runs nothing else starts: said, not left to do nothing)
        if let why = archive.busyNote { Archive.say(why.title, why.text); return }
        if let why = archive.notNow(id) { Permissions.alert(why.title, why.text); return }
        guard confirmArchive(1, one: true) else { return }
        if !archive.runOne(id), let why = archive.notNow(id) { Permissions.alert(why.title, why.text) }
    }

    func archiveAll() { exportWin.show() }

    func importArchive() {
        if let why = archive.busyNote { Archive.say(why.title, why.text); return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = Archive.folder
        p.message = tr("选存档文件夹", "Choose the archive folder")
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let dir = p.url else { return }
        importFolder(dir)
    }

    /// Runs an alert, and says which button was clicked (a test stands in for it).
    var ask: (NSAlert) -> NSApplication.ModalResponse = { a in
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal()
    }

    /// The folder picked for Import: nothing new in it is said; else what Import does is asked first.
    func importFolder(_ dir: URL) {
        let all = Archive.notes(in: dir)
        let todo = all.filter { !archive.alreadyImported($0) }
        if todo.isEmpty { _ = ask(AppDelegate.nothingToImport(found: !all.isEmpty)); return }
        guard ask(AppDelegate.importDialog(todo.count)) == .alertFirstButtonReturn else { return }
        archive.importNotes(todo)
    }

    /// Nothing new to import from that folder: said with KIKUmap's own button, as Permissions.alert does (macOS's own
    /// would be in English: the app declares no Chinese).
    static func nothingToImport(found: Bool) -> NSAlert {
        let a = NSAlert()
        a.messageText = found ? tr("这些都已经导入过了", "These were all imported already") : tr("这个文件夹里没有存档", "No archived chats in this folder")
        a.informativeText = found ? tr("每个存档只会导入一次。", "Each archived chat is imported only once.")
            : tr("导入找的是导出时写的 memory.md 总结。选导出文件夹，或者里面的主题、对话文件夹。",
                 "Import looks for the memory.md summaries an export writes. Pick the export folder, or a topic's or chat's folder in it.")
        a.addButton(withTitle: tr("好", "OK"))
        return a
    }

    /// What Import does, asked before it starts: each chat is an exchange with Claude (quota), what goes along, and the
    /// clipboard it pastes through.
    static func importDialog(_ count: Int) -> NSAlert {
        let a = NSAlert()
        a.messageText = tr("导入 \(count) 个对话到现在登录的 Claude 账号？", "Import \(count) \(count == 1 ? "chat" : "chats") into the Claude account that's signed in now?")
        a.informativeText = tr("""
        每个存档会在 Claude App 里开一个新对话，发进总结和最多 19 个 artifact（每个小于 5 MB）让 Claude 接上，然后置顶、改回原来的名字。导图上会接到原来的位置。

        · 每个对话是和 Claude 的一轮问答，会用掉一些额度（文件多或大时更多）
        · 先在 Claude App 里登录要导入的账号
        · 运行时先别动 Claude 窗口
        · 更大的和第 19 个之后的 artifact 留在导出文件夹里，会告诉 Claude 有几个
        · 会借用剪贴板粘贴，并标记让剪贴板历史类 App 跳过；每次粘贴后放回你原来的内容
        """, """
        Each one starts a new chat in the Claude app, sends in the summary with up to 19 of the chat's artifacts (under 5 MB each) so Claude can pick up, then pins the chat and gives it the old name. On the map it takes the old chat's place.

        · Each chat is one exchange with Claude, which uses some of your quota (more with many or large files)
        · Sign in to the target account in the Claude app first
        · Leave the Claude window alone while it runs
        · Larger artifacts, and any past 19, stay in the export folder; Claude is told how many
        · It pastes through the clipboard, marked for clipboard history apps to skip, and puts yours back after each paste
        """)
        a.addButton(withTitle: tr("导入", "Import"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        return a
    }

    /// What's wrong with ChatGPT's usage lookup from OpenAI, in a line for the menu under the usage rows, as Claude's is
    /// said there (nil: it's off, reads fine, or its first answer is on its way; or ChatGPT is disconnected, when
    /// nothing shows ChatGPT's usage, as gptUsageRows and the widget have none then).
    func gptUsageNote() -> String? {
        guard GPTUsageMonitor.enabled, GPTWatcher.enabled, !gptUsage.brief.isEmpty else { return nil }
        return gptUsage.brief
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
            lines.append(tr("ChatGPT：这是旧版 App，KIKUmap 读不到它的对话（更新到新版、Codex 内核的才行）；现在只显示编辑器、终端里的 Codex 会话，",
                            "ChatGPT: this is the older app, whose chats KIKUmap can't see (update to the current one, built on Codex); for now only Codex sessions from editors and the terminal show · ") + ago(d) + next(gpt.nextRead))
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
        // (as Store.isShown lists them: a script's run only while it runs; one kept or on the map for good)
        var sessionLine = tr("终端和编辑器里的 Claude Code、Codex 会话：显示 \(sessions) 个（在跑、未读，或做完后 12 小时内；脚本启动的只在跑的时候；一直留着的、在导图上的一直显示）",
                             "Claude Code and Codex sessions in terminals and editors: \(sessions) shown (while running or unread, and for 12 hours after; ones a script started only while running; kept or on the map: always)")
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
                lines.append(tr("在 Claude 或 ChatGPT 里置顶对话，它就会出现在这里。", "Pin a chat in Claude or ChatGPT and it shows up here."))
            } else if claudeReadable {
                lines.append(tr("在 Claude 里置顶一个对话，它就会出现在这里。", "Pin a chat in Claude and it shows up here."))
            } else if gptReadable {
                lines.append(tr("在 ChatGPT 里置顶一个对话，它就会出现在这里。", "Pin a chat in ChatGPT and it shows up here."))
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
        refreshUsage()
        widget.update()
        refreshUI()
    }

    /// Usage, from the refresh button: Claude's and ChatGPT's alike, now but not twice a minute, and not while Anthropic
    /// or OpenAI asked to wait (only Settings' Read again asks then).
    func refreshUsage() {
        usage.refreshNow()
        gptUsage.refreshNow()
    }

    /// What waits for Accessibility, for the apps it's off for: Claude's sidebar, ChatGPT's window (its ordinary chats).
    static func accessImpact(claude: Bool, gpt: Bool) -> String {
        let what = claude && gpt
            ? tr("在那之前，Claude App 的对话看不到置顶、在跑和未读；ChatGPT 置顶的普通对话也看不出在不在跑、有没有未读。",
                 "Until then, Claude app chats show no pins, running or unread, and ChatGPT's pinned ordinary chats show no running or unread.")
            : gpt
            ? tr("在那之前，ChatGPT 置顶的普通对话看不出在不在跑、有没有未读。", "Until then, ChatGPT's pinned ordinary chats show no running or unread.")
            : tr("在那之前，Claude App 的对话看不到置顶、在跑和未读。", "Until then, Claude app chats show no pins, running or unread.")
        return what + (GPTWatcher.enabled ? tr("Codex 对话和 Claude Code 不受影响。", " Codex chats and Claude Code aren't affected.")
                                          : tr("Claude Code 不受影响。", " Claude Code isn't affected."))
    }

    /// Why KIKUmap can't tell which chat Claude's "needs your approval" is about (its notification names none), as its
    /// To-do says: what's in the way of reading Claude's chats now; with nothing in the way, what ran when it asked
    /// (chats in plain sight aren't guessed at: until a read of Claude's sidebar shows the one that waits, it's unknown).
    func approvalWhy() -> String {
        switch sidebar.status {
        case .noAccess: return tr("KIKUmap 又读不了 Claude 的窗口（辅助功能关着）", "KIKUmap can't read Claude's window (Accessibility is off)")
        case .noApp: return tr("而 Claude 后来退出了", "Claude has quit since")
        default: break
        }
        switch sidebar.status == .ok ? sidebar.syncIssue : nil {
        case .accessOff?: return tr("KIKUmap 又读不了 Claude 的窗口（辅助功能权限失效了）", "KIKUmap can't read Claude's window (Accessibility stopped working)")
        case .noWindow?: return tr("KIKUmap 又看不到 Claude 的窗口（关了，或在别的桌面）", "KIKUmap can't see Claude's window (closed, or on another desktop)")
        case .codeMode?: return tr("Claude 又停在 Code 模式，看不到你的对话", "Claude is in Code mode, which doesn't show your chats")
        case .pinsCollapsed?: return tr("Claude 的 Pinned 区又折叠着", "Claude's Pinned section is folded")
        case .sidebarHidden?: return tr("Claude 的侧边栏又收起来了", "Claude's sidebar is hidden")
        case .noChatsShown?: return tr("Claude 的侧边栏里又一个对话也没显示", "Claude's sidebar shows no chats")
        case nil:
            switch store.approvalNoChat {
            case .beforeLaunch: return tr("当时 KIKUmap 又没在运行", "KIKUmap wasn't running then")
            case .inSight: return tr("Claude 的侧边栏里又还看不出是哪个", "Claude's sidebar doesn't show which one yet")
            case .several: return tr("当时在跑的对话又不止一个", "more than one chat was running then")
            case .noneRunning: return tr("当时 KIKUmap 看得到的对话又都没在跑", "none of the chats KIKUmap sees was running then")
            }
        }
    }

    /// What's left to do, each with what it affects until it's done (the ▸ To-do in the top bar and the menu).
    func todos() -> [Todo] {
        var out: [Todo] = []
        let fx = facts
        // ChatGPT's ordinary chats are read off its window with it too: needed with ChatGPT here even without the
        // Claude app, as the intro asks for it
        let claudeOff = sidebar.status == .noAccess
        let gptOff = GPTWatcher.enabled && fx.gptInstalled && (claudeOff || (sidebar.status == .notInstalled && !AXIsProcessTrusted()))
        if claudeOff || gptOff {
            out.append(Todo(id: "accessibility", title: tr("给 KIKUmap 开「辅助功能」权限", "Turn on Accessibility for KIKUmap"),
                            impact: AppDelegate.accessImpact(claude: claudeOff, gpt: gptOff),
                            action: (tr("去开启", "Turn on"), { [weak self] in self?.perms.openAccessibility() })))
        }
        if sidebar.status == .ok, let i = sidebar.syncIssue {
            out.append(Todo(id: "sync-\(i)", title: i.note, impact: i.help, action: nil))
        }
        if UsageMonitor.enabled {
            let stale = tr("在那之前用量不会更新，显示的是上次读到的数字。", "Until then, usage doesn't update (what's shown is from the last read).")
            let none = tr("在那之前，菜单、窗口和小组件里没有 Claude 的用量。", "Until then, no Claude usage in the menu, the window or the widget.")
            // older numbers are on screen only while they're marked "as of" (set() clears them for .noScope and .denied)
            let until = usage.asOf != nil ? stale : none
            let again: (String, () -> Void) = (tr("重新读取", "Read again"), { [weak self] in self?.usage.reconnect() })
            let off: (String, () -> Void) = (tr("关闭用量", "Turn off usage"), { [weak self] in self?.perms.disconnectUsage(); self?.refreshUI() })
            let tryNow: (String, () -> Void) = (tr("现在再试", "Try now"), { [weak self] in self?.usage.refreshNow() })
            // (no answer, an answer it can't read, the Keychain: said once the numbers shown are a quarter of an hour
            // old, or there are none, each with its own cause and when it tries again)
            let aged = usage.updated.map { Date().timeIntervalSince($0) > 900 } ?? true
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
            case .offline where aged:
                out.append(Todo(id: "usage-offline", title: usage.hint,
                                impact: tr("可能是 Mac 没联网，也可能是 Anthropic 那边出了问题。KIKUmap 隔十来分钟会自己再试。",
                                           "The Mac may be offline, or there's trouble on Anthropic's side. KIKUmap tries again by itself every 10 minutes or so."),
                                action: tryNow))
            case .error where aged:
                out.append(Todo(id: "usage-error", title: usage.hint,
                                impact: tr("查用量的接口没有公开，可能改了。KIKUmap 隔十来分钟会自己再试。",
                                           "The usage interface isn't public and may have changed. KIKUmap tries again by itself every 10 minutes or so."),
                                action: tryNow))
            case .keychain where aged:
                out.append(Todo(id: "usage-keychain", title: usage.hint,
                                impact: tr("是 macOS 的钥匙串报的错，不是网络的问题。KIKUmap 隔 15 分钟左右会自己再读一次。",
                                           "The error comes from macOS's Keychain, not the network. KIKUmap reads the sign-in again by itself every 15 minutes or so."),
                                action: tryNow))
            case .refused:
                out.append(Todo(id: "usage-refused", title: usage.hint,
                                impact: tr("KIKUmap 隔十来分钟会再试。一直这样的话，可能是网络、代理或公司的设置拦下了它；用不上用量就关掉它。\n",
                                           "KIKUmap tries again every 10 minutes or so. If it keeps happening, your network, a proxy or your organization may be blocking it; if you don't need usage, turn it off.\n") + until,
                                action: off))
            default: break
            }
        }
        // ChatGPT's usage from OpenAI, when it's on: what Claude's gets when its lookup fails (not while OpenAI only
        // asked to wait; no answer, once its tries in a minute are over). Not while ChatGPT is disconnected: then
        // nothing shows its usage, even after a Codex task (gptUsageRows and the widget have none).
        if GPTUsageMonitor.enabled && GPTWatcher.enabled {
            let g = gptUsage
            let until = tr("在那之前，ChatGPT 的用量只在你用 Codex 跑任务时更新。", "Until then, ChatGPT's usage updates only when you run a Codex task.")
            let again: (String, () -> Void) = (tr("重新读取", "Read again"), { [weak self] in self?.gptUsage.reconnect() })
            let off: (String, () -> Void) = (tr("关闭 ChatGPT 用量", "Turn off ChatGPT usage"), { [weak self] in self?.perms.disconnectGPTUsage(); self?.refreshUI() })
            let tryNow: (String, () -> Void) = (tr("现在再试", "Try now"), { [weak self] in self?.gptUsage.refreshNow() })
            let aged = g.usage.map { Date().timeIntervalSince($0.at) > 900 } ?? true
            switch g.status {
            case .noLogin:
                out.append(Todo(id: "gpt-usage-login", title: g.brief,
                                impact: tr("在 ChatGPT 桌面 App 或 Codex 里用 ChatGPT 账号登录，再点「重新读取」。Codex 用的是 API key 的话，没有 ChatGPT 用量可查，那就关掉 ChatGPT 用量。\n",
                                           "Sign in with your ChatGPT account in the ChatGPT desktop app or in Codex, then click Read again. If Codex uses an API key, there's no ChatGPT usage to look up: then turn ChatGPT usage off.\n") + until,
                                action: again))
            case .expired:
                out.append(Todo(id: "gpt-usage-expired", title: g.brief, impact: until, action: again))
            case .refused:
                out.append(Todo(id: "gpt-usage-refused", title: g.brief,
                                impact: tr("KIKUmap 隔十来分钟会再试。一直这样的话，可能是网络、代理或公司的设置拦下了它；用不上就关掉 ChatGPT 用量。\n",
                                           "KIKUmap tries again every 10 minutes or so. If it keeps happening, your network, a proxy or your organization may be blocking it; if you don't need it, turn ChatGPT usage off.\n") + until,
                                action: off))
            case .offline where aged && g.failures >= 3:
                out.append(Todo(id: "gpt-usage-offline", title: g.brief,
                                impact: tr("可能是 Mac 没联网，也可能是 OpenAI 那边出了问题。KIKUmap 隔十来分钟会自己再试。\n",
                                           "The Mac may be offline, or there's trouble on OpenAI's side. KIKUmap tries again by itself every 10 minutes or so.\n") + until,
                                action: tryNow))
            case .error where aged:
                out.append(Todo(id: "gpt-usage-error", title: g.brief,
                                impact: tr("这个接口没有公开，可能改了。KIKUmap 隔十来分钟会自己再试。\n",
                                           "The interface isn't public and may have changed. KIKUmap tries again by itself every 10 minutes or so.\n") + until,
                                action: tryNow))
            default: break
            }
        }
        if fx.hooks, let why = fx.blocked {
            out.append(Todo(id: "code-blocked", title: tr("Claude Code 的会话报不到 KIKUmap", "Claude Code sessions can't report to KIKUmap"),
                            impact: why + tr("。在那之前，终端、VS Code 里的会话不显示在跑和未读。", ". Until then, sessions in Terminal or VS Code don't show running or unread."),
                            action: nil))
        }
        // never asked about starting at login (the intro closed early, an update from 0.9, a first run from the disk image)
        if let t = LoginItem.todo({ [weak self] in self?.refreshUI() }) { out.append(t) }
        // an approval Claude asked for in a chat KIKUmap couldn't tell: until a read of Claude's chats settles it, for half
        // an hour at most; unsure once its notification has left Notification Center (as a chat's request is)
        if let a = store.approvalAsked, Date().timeIntervalSince(a) < Store.approvalShown {
            let t = Clock.format(a, "HH:mm", "HH:mm")
            let open: (String, () -> Void) = (tr("打开 Claude", "Open Claude"), {
                if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
                    NSWorkspace.shared.openApplication(at: u, configuration: NSWorkspace.OpenConfiguration())
                }
            })
            // (one id per request: ignoring one doesn't silence the next)
            let id = "claude-approval-\(Int(a.timeIntervalSince1970))"
            if store.approvalUnsure {
                out.append(Todo(id: id, title: tr("Claude 可能还在等你确认", "Claude may still be waiting for you to approve"),
                                impact: tr("\(t) Claude 问了一次「允许吗？」，它的通知没说是哪个对话。这条通知后来不见了：可能已经确认过了，也可能只是被清掉了。打开 Claude 看看。",
                                           "At \(t) Claude asked for an approval in a chat its notification doesn't name. That notification has gone since: it may have been answered, or only cleared. Open Claude to check."),
                                action: open))
            } else {
                out.append(Todo(id: id, title: tr("Claude 在等你确认", "Claude is waiting for you to approve"),
                                impact: tr("\(t) Claude 问了一次「允许吗？」，但它的通知没说是哪个对话，", "At \(t) Claude asked for an approval, but its notification doesn't say in which chat, and ")
                                    + approvalWhy() + tr("。打开 Claude 去确认。", ". Open Claude to answer."),
                                action: open))
            }
        }
        if unreadUnsynced && sidebar.status == .ok {
            out.append(Todo(id: "unread-unsynced", title: tr("看不到 Claude 的未读标记", "Can't see Claude's unread marks"),
                            impact: unreadUnsyncedHelp,
                            action: (tr("诊断报告", "Diagnostic report"), { [weak self] in self?.diagnose() })))
        }
        // data that couldn't be read or saved: what happened, and where the file is
        let unreadable = store.unreadable + [archive.unreadable].compactMap { $0 }
        if !unreadable.isEmpty {
            out.append(Todo(id: "data-unreadable", title: tr("有数据文件读不了，已另存", "A data file couldn't be read and was kept aside"),
                            impact: tr("读不了的文件已原样留在 ", "The unreadable file was kept as it was in ") + unreadable.joined(separator: ", ")
                                + tr("。KIKUmap 从空白开始记，没有覆盖它。", ". KIKUmap started that part afresh without writing over it."),
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
        let raw = c.app ?? ""
        let bundle = Store.appBundles[raw] ?? raw
        let folder = c.cwd.map { URL(fileURLWithPath: $0) }
        if !bundle.isEmpty, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            if let f = folder, bundle.lowercased().contains("vscode") || bundle.lowercased().contains("cursor") {
                // a window with the session's folder (or one it's in) already open comes to the front; only without one
                // is the folder opened (the editor opens a new window for a folder no window has)
                if AppDelegate.raiseWindow(of: bundle, showing: f.path) { return }
                NSWorkspace.shared.open([f], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
        } else if let f = folder {
            NSWorkspace.shared.activateFileViewerSelecting([f])
        }
    }

    /// Brings to the front the window of the running app `bundle` whose title names `folder` (or else a folder it's
    /// in), read with Accessibility. false: the app isn't running, no window shows it, or no Accessibility.
    private static func raiseWindow(of bundle: String, showing folder: String) -> Bool {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 1.0)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success, let wins = v as? [AXUIElement] else { return false }
        let shown = wins.compactMap { w -> (AXUIElement, String)? in
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success, let title = t as? String,
                  Store.window(title, shows: folder) else { return nil }
            return (w, title)
        }
        let name = (folder as NSString).lastPathComponent
        guard let w = (shown.first { $0.1.contains(name) } ?? shown.first)?.0 else { return false }
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        app.activate()
        return true
    }

    /// The titles of the front app's windows but its focused one, and with `tabs` of their tabs (a tab group's buttons,
    /// among a window's children or theirs) but the one shown in its focused window, read with Accessibility: what else
    /// in that app could show a session's folder. (An editor's tabs are its files: not asked.) nil: they can't be read
    /// (no Accessibility, the app doesn't answer, or there's too much of it to go through on the main thread).
    static func otherWindowTitles(tabs: Bool) -> [String]? {
        guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        var stuck = false, asks = 0
        func value(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
            asks += 1
            if asks > 800 { stuck = true }
            guard !stuck else { return nil }
            var v: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(e, a as CFString, &v)
            if r == .cannotComplete { stuck = true }               // it doesn't answer: the rest wouldn't either
            return r == .success ? v : nil
        }
        func kids(_ e: AXUIElement) -> [AXUIElement] {
            let all = value(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if all.count > 100 { stuck = true }                    // (not all of them looked at: what's left isn't known)
            return Array(all.prefix(100))
        }
        guard let f = value(app, kAXFocusedWindowAttribute), CFGetTypeID(f) == AXUIElementGetTypeID(),
              let wins = value(app, kAXWindowsAttribute) as? [AXUIElement], wins.count <= 60 else { return nil }
        let focused = f as! AXUIElement
        var out: [String] = []
        for w in wins {
            let front = CFEqual(w, focused)
            if !front, let t = value(w, kAXTitleAttribute) as? String { out.append(t) }
            guard tabs else { continue }
            let near = kids(w)
            for g in near + near.flatMap(kids) where value(g, kAXRoleAttribute) as? String == kAXTabGroupRole {
                for tab in kids(g) where value(tab, kAXRoleAttribute) as? String == kAXRadioButtonRole {
                    if front && (value(tab, kAXValueAttribute) as? NSNumber)?.intValue == 1 { continue }   // the one shown
                    if let t = value(tab, kAXTitleAttribute) as? String { out.append(t) }
                }
            }
        }
        return stuck ? nil : out
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
        AppDelegate.forgetOldReports(in: store.logsDir)
        // ChatGPT's window too, in a file of its own named by the time (what its sidebar shows a working chat by); every
        // ordinary chat KIKUmap knows, pinned or no longer, is named only by its number
        let pins = store.chats.filter { $0.isGPTChat }.map(\.title), logs = store.logsDir
        if AXIsProcessTrusted(), let pid = NSRunningApplication.runningApplications(withBundleIdentifier: GPTWatcher.bundleID).first?.processIdentifier {
            DispatchQueue.global(qos: .userInitiated).async {
                let text = GPTWindow.layout(pid: pid, pinned: pins)
                let f = DateFormatter(); f.dateFormat = "HHmmss"
                try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                try? text.data(using: .utf8)?.write(to: logs.appendingPathComponent("chatgpt-window-\(f.string(from: Date())).txt"))
            }
        }
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

    /// Earlier versions' window files kept pieces of what was open (ChatGPT's: of the links in a chat, then words found
    /// in its messages and chat titles; Claude's, with no chat list found: its short texts). Those copies go, once for
    /// each, so they aren't sent along with the next report.
    static func forgetOldReports(in logs: URL) {
        let d = UserDefaults.standard, fm = FileManager.default
        for (key, old) in [("ReportLogClean", { (f: String) in f.hasPrefix("chatgpt-window-") || f == "claude-sidebar.txt" }),
                           ("ReportLogClean2", { (f: String) in f.hasPrefix("chatgpt-window-") })] where !d.bool(forKey: key) {
            for f in (try? fm.contentsOfDirectory(atPath: logs.path)) ?? [] where old(f) {
                try? fm.removeItem(at: logs.appendingPathComponent(f))
            }
            d.set(true, forKey: key)
        }
    }

    /// What KIKUmap can see on this Mac, without anything personal.
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
            # KIKUmap check \(Clock.iso())
            # Send this file when something doesn't work. It has no chat titles, messages or keys.

            KIKUmap \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch) · languages \(Locale.preferredLanguages.prefix(3).joined(separator: ", "))
            App at \(Bundle.main.bundlePath.replacingOccurrences(of: home, with: "~")) · data in \(store.dir.path.replacingOccurrences(of: home, with: "~"))

            Claude app: \(version(claudeBundleID)) · \(sidebar.claudePID != 0 ? "running" : "not running")
            Accessibility: \(AXIsProcessTrusted() ? "on" : "off")
            Sidebar: \(sidebar.status) · last read \(ago(sidebar.lastSync)) · \(sidebar.syncNote ?? "no problem")\(sidebar.marksMissed ? " · Claude's unread marks not recognized lately (unread not synced)" : "")\(sidebar.unknownMark.map { " · unknown row status: '\($0)'" } ?? "")
            Chats: Claude \(claude.count) (pinned \(claude.filter { $0.pinned == true }.count)) · Claude Code \(codeChats.count) · ChatGPT \(gptChats.count) (pinned \(gptChats.filter { $0.pinned == true }.count)) · in the sidebar \(store.pinnedList().count)

            Notifications (Full Disk Access): \(notifications.status)\(notifications.problem.map { " · " + $0 } ?? "")

            Claude Code: ~/.claude \(FileManager.default.fileExists(atPath: home + "/.claude") ? "found" : "missing") · hooks \(CodeHooks.installed ? "connected" : "not connected")\(CodeHooks.blockedReason().map { " · blocked: " + $0 } ?? "")
            Usage: \(UsageMonitor.enabled ? "on" : "off") · \(usage.status) · updated \(ago(usage.updated))

            ChatGPT app: \(version(GPTWatcher.bundleID))\(GPTWatcher.oldAppOnly ? " (only the older app is installed)" : "") · its data \(GPTWatcher.available ? "found" : "missing") · reading \(GPTWatcher.enabled ? "on" : "off") · usage \(gpt.usage == nil ? "none yet" : "found")\(gpt.readError.map { " · error: " + $0 } ?? "")
            ChatGPT usage from OpenAI: \(GPTUsageMonitor.enabled ? "on" : "off") · \(gptUsage.status) · updated \(ago(gptUsage.usage?.at))
            ChatGPT window (ordinary chats): \(store.gptChatNames.count) pinned · \(store.gptChatsRead.count) read · window last read \(ago(self.gptChats.lastRead)) · \(self.gptChats.issue.map { "\($0)" } ?? "no problem")\(self.gptChats.otherStatus.map { " · a row's status not taken for working: '\(AXScan.short($0, 40))'" } ?? "")

            Data: \(unreadable.isEmpty ? "all read" : "kept aside: " + unreadable.joined(separator: ", "))\(unsaved.isEmpty ? "" : " · can't save: " + unsaved.joined(separator: ", "))\(store.rulesProblem.map { " · rules: " + $0 } ?? "")
            Start at login: \(LoginItem.enabled ? "on" : "off")

            Widget: \(widget ? "in the app" : "missing") · \(os.majorVersion >= 14 ? "macOS supports it" : "needs macOS 14")

            """
    }

    @objc private func showSettings() { settings.show() }
    @objc private func showAbout() { settings.show(tab: SettingsWindow.aboutTab) }
    @objc private func toggleSide() { main.toggleSidebar() }
    @objc private func toggleTimeline() { main.toggleTimeline() }
    @objc private func toggleTags() { main.toggleTags() }
    @objc private func bigger() { main.scaleUI(by: 1) }
    @objc private func smaller() { main.scaleUI(by: -1) }
    @objc private func defaultSize() { main.scaleUI(by: 0) }
    @objc private func findInMap() { main.showSearch() }
    @objc private func exportPDF() { main.show(); main.map.exportPDF() }
    @objc private func showExport() { exportWin.show() }
    @objc private func showMap() { main.show() }
    @objc private func showStats() { stats.show() }
    @objc private func refreshFromMenu() { refreshAll() }
    @objc private func undoFromMenu() { undoStep(redo: false) }
    @objc private func redoFromMenu() { undoStep(redo: true) }

    /// Edit → Undo / Redo (⌘Z ⇧⌘Z): in a text field (a name on the map, a search, a setting), its typing; anywhere else
    /// in the map's window, the left column too, the map's own steps (the map takes the keys itself first when it has
    /// them); nothing in the other windows. Not AppKit's `undo:`: that renames the item in the system's language.
    /// `run` false: only whether there's a step (the item is greyed out without one). `window`: the one in front unless given.
    @discardableResult
    private func undoStep(redo: Bool, run: Bool = true, in window: NSWindow? = nil) -> Bool {
        let w = window ?? NSApp.keyWindow
        if let typing = (w?.firstResponder as? NSTextView)?.undoManager {
            guard redo ? typing.canRedo : typing.canUndo else { return false }
            if run { redo ? typing.redo() : typing.undo() }
            return true
        }
        guard let w, w === main.window, redo ? store.map.canRedo : store.map.canUndo else { return false }
        if run { main.map.undoStep(redo: redo) }
        return true
    }

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
        appMenu.addItem(withTitle: tr("关于 KIKUmap", "About KIKUmap"), action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("设置…", "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: tr("导出对话…", "Export chats…"), action: #selector(showExport), keyEquivalent: "E")
        appMenu.addItem(withTitle: tr("导出导图 PDF…", "Export map as PDF…"), action: #selector(exportPDF), keyEquivalent: "e")
        appMenu.addItem(.separator())
        // the standard three every Mac app has (⌘H, ⌥⌘H)
        appMenu.addItem(withTitle: tr("隐藏 KIKUmap", "Hide KIKUmap"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: tr("隐藏其他", "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: tr("全部显示", "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("收起窗口", "Close window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: tr("退出", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: tr("编辑", "Edit"))
        edit.addItem(withTitle: tr("撤销", "Undo"), action: #selector(undoFromMenu), keyEquivalent: "z")
        edit.addItem(withTitle: tr("重做", "Redo"), action: #selector(redoFromMenu), keyEquivalent: "Z")
        edit.addItem(.separator())
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
        let tl = view.addItem(withTitle: tr("显示 / 隐藏时间轴", "Show / Hide Timeline"), action: #selector(toggleTimeline), keyEquivalent: "t")
        tl.keyEquivalentModifierMask = [.control, .command]
        let tg = view.addItem(withTitle: tr("显示 / 隐藏标签", "Show / Hide Tags"), action: #selector(toggleTags), keyEquivalent: "g")
        tg.keyEquivalentModifierMask = [.control, .command]
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
        Prefs.hotKeyError = nil
        guard Prefs.hotKeyEnabled else { return }
        // one of KIKUmap's own menu keys (⌃⌘G…, saved by an older build) would take that key from the menu: not
        // registered, and every place that offers it says it isn't active (Settings says why)
        if HotKeyField.ownUse(code: Prefs.hotKeyCode, mods: Prefs.hotKeyMods) != nil { Prefs.hotKeyError = OSStatus(eventHotKeyExistsErr); return }
        let hkID = EventHotKeyID(signature: OSType(0x4343_4F4E), id: 1)
        let status = RegisterEventHotKey(Prefs.hotKeyCode, Prefs.hotKeyMods, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // refused (taken by another app or the system): every place that offers it says so instead
            hotKeyRef = nil
            Prefs.hotKeyError = status
            store.log("\(Clock.iso()) shortcut \(Prefs.hotKeyLabel()) couldn't be registered (\(status))\n", file: "app.log")
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Undo / Redo are greyed out with nothing to take back or do again; the other items stay as they are.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoFromMenu): return undoStep(redo: false, run: false)
        case #selector(redoFromMenu): return undoStep(redo: true, run: false)
        default: return true
        }
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
