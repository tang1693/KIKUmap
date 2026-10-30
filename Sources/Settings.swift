import Cocoa
import Carbon
import AVFoundation

/// The three things the app needs from macOS, checked live and opened one at a time.
@MainActor
final class Permissions {
    let notifications: NotificationWatcher
    let sidebar: SidebarWatcher
    let usage: UsageMonitor

    init(notifications: NotificationWatcher, sidebar: SidebarWatcher, usage: UsageMonitor) {
        self.notifications = notifications
        self.sidebar = sidebar
        self.usage = usage
    }

    /// Granted (also when the database it opens couldn't be read as expected: that's not a permission problem).
    var fullDisk: Bool { notifications.recheck(); return notifications.status == .ok || notifications.status == .unreadable }
    var accessibility: Bool { AXIsProcessTrusted() }
    var usageOK: Bool { usage.status == .ok }

    static func openPane(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Full Disk Access was opened from here in this run (once switched on, macOS gives it only after a reopen).
    var fullDiskAsked = false

    /// Full Disk Access has no system prompt: say what to do, then open the list and show the app in Finder to drag in.
    func openFullDisk() {
        if fullDiskAsked { reopenForFullDisk(); return }
        let a = NSAlert()
        a.messageText = tr("把 Kikumap 加进「完全磁盘访问」", "Add Kikumap to Full Disk Access")
        a.informativeText = Permissions.fullDiskSteps
        a.addButton(withTitle: tr("打开", "Open"))
        a.addButton(withTitle: tr("先不用", "Not now"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        fullDiskAsked = true
        Permissions.openPane("Privacy_AllFiles")
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Opened before and still off: most likely switched on but not given yet (macOS's "Later", or it didn't ask).
    private func reopenForFullDisk() {
        let a = NSAlert()
        a.messageText = tr("「完全磁盘访问」还没生效", "Full Disk Access isn't on yet")
        a.informativeText = tr("""
            如果已经在系统设置里打开了 Kikumap 的开关：Kikumap 要退出并重新打开才能用上（在 macOS 的提示里选了「以后」就会这样）。

            还没开的话：打开系统设置，把 Kikumap 从访达窗口拖进列表（或点 ＋ 选它），再打开开关。
            """, """
            If you've switched Kikumap on in System Settings, it only gets access once it quits and reopens (that's what choosing "Later" in macOS's prompt means).

            Not yet? Open System Settings, drag Kikumap from the Finder window into the list (or click + and choose it), then switch it on.
            """)
        a.addButton(withTitle: tr("退出并重新打开", "Quit & Reopen"))
        a.addButton(withTitle: tr("打开系统设置", "Open System Settings"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: Permissions.reopen()
        case .alertSecondButtonReturn:
            Permissions.openPane("Privacy_AllFiles")
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        default: break
        }
    }

    /// Starts a new Kikumap, which takes over from this one as an update does (an unfinished intro comes back where it was).
    static func reopen() {
        let c = NSWorkspace.OpenConfiguration()
        c.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: c) { _, error in
            guard let error = error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    alert(tr("没能重新打开 Kikumap", "Couldn't reopen Kikumap"), error.localizedDescription + tr("\n\n请退出 Kikumap，再打开它。", "\n\nQuit Kikumap and open it again."))
                }
            }
        }
    }

    /// After "Quit & Reopen" only the first-run intro comes back where it was (from anywhere else the map opens).
    static var fullDiskSteps: String {
        tr("""
            接下来会打开系统设置和一个访达窗口（Kikumap 已选中）：把 Kikumap 从访达拖进列表（或点 ＋ 选它），再打开它的开关。

            如果 macOS 问要不要「退出并重新打开」，选它就好：
            """, """
            System Settings opens at Full Disk Access, with a Finder window that has Kikumap selected: drag Kikumap into the list (or click + and choose it), then switch it on.

            If macOS offers "Quit & Reopen", choose it:
            """) + (Prefs.onboarded
                ? tr("Kikumap 会自己重新打开，之后 设置 → 授权 里会显示「✓ 已开启」。", " Kikumap opens again by itself; Settings → Access then shows ✓ On.")
                : tr("Kikumap 会自己重新打开，回到介绍的这一步。", " Kikumap opens again by itself, back at this step of the intro."))
    }

    func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Permissions.openPane("Privacy_Accessibility")
        sidebar.attach()
    }

    /// Usage needs Claude Code's sign-in from the Keychain, so nothing is read until you agree here (from anywhere:
    /// Settings, the intro, the menu, the timeline); only then may macOS ask.
    func connectUsage() {
        if !UsageMonitor.enabled {
            let a = NSAlert()
            a.messageText = tr("显示 Claude 的用量和计划任务？", "Show Claude's usage and scheduled tasks?")
            let need = UsageMonitor.claudeCodeInstalled ? "" : tr("\n\n这台 Mac 上好像还没有 Claude Code：先装好 Claude Code，在终端运行 claude 并用付费账号 /login，这里才有用量。",
                                                            "\n\nClaude Code doesn't seem to be on this Mac yet: install it, run claude in Terminal and /login with your paid account, then usage shows here.")
            a.informativeText = tr("""
                Kikumap 可以借用 Claude Code 存在这台 Mac 钥匙串里的登录，查你的套餐用量和计划任务，不用再登录一次。需要 Claude 付费套餐（Pro、Max、Team 或 Enterprise）并在 Claude Code 里登录；免费套餐和 API key 没有用量可看。

                • 只读取，不修改、不保存这份登录
                • 只发给 api.anthropic.com，只用来查用量和计划任务
                • 随时可以在 设置 → 授权 里关掉

                Kikumap 和 Claude Code 用同一种方式读取它，所以 macOS 一般不会问。如果问了，选「允许」。
                """, """
                Kikumap can look up your plan usage and scheduled tasks by borrowing the sign-in Claude Code already keeps in this Mac's Keychain — no second login. It needs a paid Claude plan (Pro, Max, Team or Enterprise) signed in to Claude Code; the Free plan and API keys have no usage to show.

                • It only reads it: never changes or saves it
                • It's only sent to api.anthropic.com, to look up usage and scheduled tasks
                • You can turn it off any time in Settings → Access

                Kikumap reads it the same way Claude Code does, so macOS usually doesn't ask. If it does, choose "Allow".
                """) + need
            a.addButton(withTitle: tr("继续", "Continue"))
            a.addButton(withTitle: tr("先不用", "Not now"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        UsageMonitor.enabled = true
        usage.reconnect()
        usage.start()
    }

    func disconnectUsage() {
        UsageMonitor.enabled = false
        usage.stop()
    }

    var codeHooks: Bool { CodeHooks.installed }

    /// Adds the hooks to ~/.claude/settings.json (a backup of the old file is kept next to it), after saying so.
    func connectCode() {
        if !CodeHooks.installed {
            let a = NSAlert()
            a.messageText = tr("连接 Claude Code？", "Connect Claude Code?")
            a.informativeText = Permissions.codeHooksSteps
            a.addButton(withTitle: tr("连接", "Connect"))
            a.addButton(withTitle: tr("先不用", "Not now"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if let err = CodeHooks.install() { Permissions.alert(tr("没能连接 Claude Code", "Couldn't connect Claude Code"), err) }
        else if let why = CodeHooks.blockedReason() { Permissions.alert(tr("已连接，但 Claude Code 不会运行它们", "Connected, but Claude Code won't run them"), why) }
    }

    /// The backup is made only the first time (CodeHooks.install keeps the file as it was before Kikumap).
    static var codeHooksSteps: String {
        tr("""
            Kikumap 会在 ~/.claude/settings.json 里加几个 hook：Claude Code 会话一开始、做完、要你批准时，各写一行到 Kikumap 的文件夹，这样终端、VS Code 里的会话也会显示「进行中 / 未读」。

            • Kikumap 第一次改它之前，原来的文件会备份成 settings.json.before-claude-console（以后不再更新这份备份）
            • 之后新开的会话才生效，已经开着的要重开
            • 随时可以在 设置 → 授权 里断开
            """, """
            Kikumap adds a few hooks to ~/.claude/settings.json: when a Claude Code session starts a turn, finishes or needs your approval, it writes one line to Kikumap's folder, so sessions in Terminal or VS Code show as running / unread too.

            • Before Kikumap first changes it, your file is backed up as settings.json.before-claude-console (that copy isn't updated later)
            • Sessions started from now on report; ones already open need a restart
            • You can disconnect any time in Settings → Access
            """)
    }

    func disconnectCode() {
        if let err = CodeHooks.uninstall() { Permissions.alert(tr("没能断开 Claude Code", "Couldn't disconnect Claude Code"), err) }
    }

    /// ChatGPT threads (read-only, from ~/.codex): on / off.
    var onGPT: ((Bool) -> Void)?
    var gptOK: Bool { GPTWatcher.enabled && GPTWatcher.available }
    /// Why ChatGPT's data can't be read right now (nil: it can).
    var gptError: (() -> String?)?
    func connectGPT() {
        guard GPTWatcher.available else {
            let text = GPTWatcher.oldAppOnly
                ? tr("这台 Mac 上是旧版 ChatGPT App，它不在本机保存对话。更新到新版 ChatGPT 桌面 App（Codex 内核），用过一次后再来这里连接。",
                     "This Mac has the older ChatGPT app, which keeps nothing on the Mac. Update to the current ChatGPT desktop app (the one built on Codex), use it once, then connect here.")
                : GPTWatcher.installed
                ? tr("ChatGPT 装好了但还没用过：在里面开一个对话，再来这里连接。", "ChatGPT is installed but hasn't been used yet: start a chat in it, then connect here.")
                : tr("装上新版 ChatGPT 桌面 App（Codex 内核）并用过一次，再来这里连接。", "Install the current ChatGPT desktop app (the one built on Codex), use it once, then connect here.")
            Permissions.alert(tr("没找到 ChatGPT 的数据", "ChatGPT's data wasn't found"), text)
            return
        }
        onGPT?(true)
    }
    func disconnectGPT() { onGPT?(false) }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// Starts the app at login (a LaunchAgent, same as the installer's), shown as Kikumap in System Settings.
enum LoginItem {
    static let label = "ninja.tang.claudeconsole"
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var id: String { Bundle.main.bundleIdentifier ?? ownBundleID }
    /// Kikumap by its bundle id, not its path: macOS finds it wherever it was moved or renamed, and with two copies
    /// it takes the one on the startup disk with the newest version. Install.command writes the same.
    static var args: [String] { ["/usr/bin/open", "-b", id, "--args", "--background"] }
    static var plist: [String: Any] { ["Label": label, "ProgramArguments": args, "RunAtLoad": true, "AssociatedBundleIdentifiers": [id]] }

    /// The agent as it is on disk (nil: none, or unreadable).
    static var saved: [String: Any]? {
        FileManager.default.contents(atPath: url.path).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
    }

    /// On: an agent that finds the app (one from before 1.0 names a path, which must still be there).
    static var enabled: Bool {
        guard let a = saved?["ProgramArguments"] as? [String] else { return false }
        if let i = a.firstIndex(of: "-a") { return i + 1 < a.count && FileManager.default.fileExists(atPath: a[i + 1]) }
        return a.contains("-b")
    }

    /// You've had your say (the intro's last page, Settings, the installer, the To-do): no To-do about it then.
    static var chosen: Bool {
        get { UserDefaults.standard.bool(forKey: "LoginOffered") }
        set { UserDefaults.standard.set(newValue, forKey: "LoginOffered") }
    }

    /// This copy runs from somewhere it won't be at the next login: the disk image (read-only), or a quarantined
    /// copy macOS moved aside ("App Translocation"). A copy on another disk is fine.
    static var temporaryPlace: Bool {
        temporary(Bundle.main.bundleURL)
    }
    static func temporary(_ u: URL) -> Bool {
        u.path.contains("/AppTranslocation/") || (try? u.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    /// nil when done; otherwise why not (from the disk image it can't be turned on; the folder may not be writable).
    @discardableResult
    static func set(_ on: Bool) -> String? {
        let fm = FileManager.default
        if on && temporaryPlace {
            return tr("现在是从磁盘映像（或临时位置）运行的，下次登录时它就不在了。把 Kikumap 拖进「应用程序」文件夹，从那里打开，再来开这个。",
                      "It's running from the disk image (or a temporary place), which won't be there at the next login. Drag Kikumap into Applications, open it from there, then turn this on.")
        }
        do {
            if !on {
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                return nil
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
            return nil
        } catch {
            let dir = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return tr("\(dir) 写不进去（\(error.localizedDescription)）。这个文件夹可能属于 root（有些用 sudo 的安装程序会这样）：在「终端」里运行 sudo chown $(whoami) ~/Library/LaunchAgents，再试一次。",
                      "Couldn't write to \(dir) (\(error.localizedDescription)). It may belong to root (some installers run with sudo leave it so): in Terminal, run sudo chown $(whoami) ~/Library/LaunchAgents, then try again.")
        }
    }

    /// From a click (Settings, the intro, the To-do): saves it as your choice, or says why it couldn't be done.
    @MainActor @discardableResult
    static func choose(_ on: Bool) -> Bool {
        if let why = set(on) {
            Permissions.alert(on ? tr("没能打开「登录时自动启动」", "Couldn't turn on Start at login") : tr("没能关掉「登录时自动启动」", "Couldn't turn off Start at login"), why)
            return false
        }
        chosen = true
        return true
    }

    /// At launch: an agent in an older form (it named the app's path, so a moved app stopped starting; System Settings
    /// showed it as "open") is written again in today's form, once.
    static func follow() {
        guard !temporaryPlace, let o = saved,
              o["ProgramArguments"] as? [String] != args || o["AssociatedBundleIdentifiers"] as? [String] != [id] else { return }
        set(true)
    }

    /// For whoever was never asked (the intro closed early, an update from 0.9, a first run from the disk image): one
    /// To-do until it's on or you've chosen (Ignore works as for any To-do). `changed`: after its button.
    @MainActor
    static func todo(_ changed: @escaping () -> Void) -> Todo? {
        guard Prefs.onboarded, !chosen, !enabled else { return nil }
        if temporaryPlace {
            return Todo(id: "login-move", title: tr("把 Kikumap 拖进「应用程序」", "Move Kikumap to Applications"),
                        impact: tr("现在是从磁盘映像（或临时位置）运行的，重启后它就不在了。把它拖进「应用程序」并从那里打开，就可以设成登录时自动打开。",
                                   "It's running from the disk image (or a temporary place), so it's gone after a restart. Drag it into Applications and open it from there; then it can open when you log in."),
                        action: nil)
        }
        return Todo(id: "login", title: tr("登录 Mac 时自动打开 Kikumap", "Open Kikumap when you log in"),
                    impact: tr("不开的话，重启后 Kikumap 不会自己打开：在你打开它之前没有提醒，Claude App 和 ChatGPT 的对话不记时间，小组件也不更新。以后可以在 设置 → 通用 里改。",
                               "Otherwise Kikumap isn't back after a restart: until you open it there are no alerts, chats in the Claude app and ChatGPT don't count time, and the widget doesn't update. Change it any time in Settings → General."),
                    action: (tr("开启", "Turn on"), { if choose(true) { changed() } }))
    }
}

/// Asks for a tag name and colour.
@MainActor
enum TagPrompt {
    static func ask(name: String = "", color: String, window: NSWindow?) -> (name: String, color: String, icon: String?, group: String?)? {
        let a = NSAlert()
        a.messageText = tr("新标签", "New tag")
        a.informativeText = tr("一个对话或主题可以有多个标签。", "A chat or topic can have several tags.")
        a.addButton(withTitle: tr("好", "OK"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        let field = NSTextField(string: name)
        field.placeholderString = tr("标签名，比如「等客户」", "Tag name, e.g. \"waiting on client\"")
        let pop = ColorPopUp(selected: color)
        let group = NSPopUpButton(frame: .zero, pullsDown: false)
        for g in Tag.groups { group.addItem(withTitle: tr(g.zh, g.en)); group.lastItem?.representedObject = g.key }
        group.selectItem(at: Tag.groups.count - 1)
        let grid = IconGridView()
        grid.tint = Theme.highlight(color) ?? Theme.ink
        pop.onPick = { grid.tint = Theme.highlight($0) ?? Theme.ink }
        let scroll = grid.scrolled(height: 190)
        scroll.widthAnchor.constraint(equalToConstant: scroll.frame.width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        let row = NSStackView(views: [pop, group])
        row.spacing = 8
        let stack = NSStackView(views: [field, row, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: scroll.frame.width, height: 258)
        field.widthAnchor.constraint(equalToConstant: scroll.frame.width).isActive = true
        a.accessoryView = stack
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let n = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : (n, pop.selectedKey, grid.selected, group.selectedItem?.representedObject as? String)
    }
}

/// Pop-up of the highlight colours (with swatches).
final class ColorPopUp: NSPopUpButton {
    var onPick: ((String) -> Void)?

    init(selected: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 110, height: 26), pullsDown: false)
        for h in Theme.highlights {
            addItem(withTitle: tr(h.zh, h.en))
            lastItem?.image = Theme.swatch(h.color)
            lastItem?.representedObject = h.key
        }
        if let i = Theme.highlights.firstIndex(where: { $0.key == selected }) { selectItem(at: i) }
        target = self
        action = #selector(picked)
    }
    required init?(coder: NSCoder) { fatalError() }

    var selectedKey: String { selectedItem?.representedObject as? String ?? Theme.highlights[0].key }
    @objc private func picked() { onPick?(selectedKey) }
}

/// Click, then press the new shortcut.
final class HotKeyField: NSButton {
    var onChange: ((UInt32, UInt32) -> Void)?
    var onRecording: ((Bool) -> Void)?
    private var recording = false { didSet { refresh(); onRecording?(recording) } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 28))
        bezelStyle = .rounded
        target = self
        action = #selector(begin)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func refresh() {
        title = recording ? tr("请按下快捷键…", "Press a shortcut…") : Prefs.hotKeyLabel()
    }

    @objc private func begin() {
        recording = true
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    /// Recording ends without a new shortcut (Settings closed or went to the back): the old one works again.
    func stop() { if recording { recording = false } }

    /// Its tab was switched away.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    private func take(_ e: NSEvent) -> Bool {
        guard recording else { return false }
        if e.keyCode == UInt16(kVK_Escape) { recording = false; return true }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.option) { mods |= UInt32(optionKey) }
        if f.contains(.shift) { mods |= UInt32(shiftKey) }
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        // two of ⌃ ⌥ ⌘ (⇧ may come along): a global shortcut with ⌘ alone (⌘C, ⌘W) would take that key from every app
        let strong = [controlKey, optionKey, cmdKey].filter { mods & UInt32($0) != 0 }.count
        guard strong >= 2 else {
            if f.contains(.command) && strong == 1 { recording = false; return false }   // ⌘W, ⌘Q… keep their meaning
            NSSound.beep(); return true
        }
        recording = false
        onChange?(UInt32(e.keyCode), mods)
        refresh()
        return true
    }

    override func keyDown(with e: NSEvent) { if !take(e) { super.keyDown(with: e) } }
    override func performKeyEquivalent(with e: NSEvent) -> Bool { take(e) || super.performKeyEquivalent(with: e) }
}

/// Settings: general, notifications, access, shortcuts, tags.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: Store
    private let perms: Permissions
    private var timer: Timer?
    /// Each access row: its status label, its button, and what to show now.
    private var permRows: [(NSTextField, NSButton, () -> Perm)] = []
    private var offButtons: [(NSButton, () -> Bool)] = []
    /// A row's state: its status text, whether it's working, the button's title (nil: as made) and whether it can
    /// be clicked, and a longer reason on hover.
    private struct Perm { var text: String; var on: Bool; var button: String? = nil; var enabled: Bool; var why: String? = nil }
    private var tagStack: NSStackView?
    private weak var loginBox: NSButton?
    private var lastTab = 0
    private weak var hotKeyField: HotKeyField?

    var onLanguage: (() -> Void)?
    var onHotKey: (() -> Void)?
    var onSuspendHotKey: ((Bool) -> Void)?
    var onIntro: (() -> Void)?
    var onDiagnose: (() -> Void)?
    var onArchiveAll: (() -> Void)?
    var onImport: (() -> Void)?
    var archive: Archive?
    var sounds: Sounds?
    private var archiveStatus: NSTextField?
    private var archiveFolderLabel: NSTextField?
    private var archiveButtons: [NSButton] = []

    init(store: Store, perms: Permissions) {
        self.store = store
        self.perms = perms
        super.init()
    }

    func show(tab: Int? = nil) {
        if window == nil { build() }
        if let t = tab, let tc = window?.contentViewController as? NSTabViewController { tc.selectedTabViewItemIndex = t }
        Front.activate()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    /// Language changed: rebuild in place.
    func rebuild() {
        guard let w = window else { return }
        hotKeyField?.stop()
        lastTab = (w.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex ?? 0
        let frame = w.frame
        w.orderOut(nil)
        window = nil
        build()
        window?.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))
        (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = lastTab
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; hotKeyField?.stop() }

    /// A shortcut being recorded ends when Settings goes to the back, so the shortcut is never left switched off.
    func windowDidResignKey(_ notification: Notification) { hotKeyField?.stop() }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPerms() }
        }
        refreshPerms()
    }

    // MARK: building

    private func build() {
        permRows = []; offButtons = []
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func add(_ vc: NSViewController, _ title: String, _ symbol: String) {
            vc.title = title            // the tab controller puts this in the window title ("Untitled" otherwise)
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add(page(general()), tr("通用", "General"), "gearshape")
        add(page(notifications()), tr("通知", "Notifications"), "bell")
        add(page(access()), tr("授权", "Access"), "lock.shield")
        add(page(shortcuts()), tr("快捷键", "Shortcuts"), "keyboard")
        add(page(tagsPage()), tr("标签", "Tags"), "tag")
        add(page(archivePage()), tr("导出", "Export"), "square.and.arrow.up")
        add(page(about()), tr("关于", "About"), "info.circle")
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.title = tr("设置", "Settings")
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
    }

    private func page(_ content: NSView) -> NSViewController {
        let vc = NSViewController()
        let v = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: v.topAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor, constant: -24),
            v.widthAnchor.constraint(equalToConstant: 560),
        ])
        vc.view = v
        // each tab gets its own height (the window resizes when switching)
        vc.preferredContentSize = NSSize(width: 560, height: content.fittingSize.height + 46)
        return vc
    }

    private func label(_ s: String, bold: Bool = false, small: Bool = false, width: CGFloat = 500) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = small ? .systemFont(ofSize: 11.5) : .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
        l.textColor = small ? .secondaryLabelColor : .labelColor
        l.preferredMaxLayoutWidth = width
        l.setContentCompressionResistancePriority(.required, for: .vertical)
        return l
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 14
        g.columnSpacing = 14
        g.column(at: 0).xPlacement = .trailing
        g.rowAlignment = .firstBaseline
        g.setContentHuggingPriority(.required, for: .vertical)
        return g
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 14) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.setContentHuggingPriority(.required, for: .vertical)
        return s
    }

    private func popup(_ items: [String], selected: Int, _ f: @escaping (Int) -> Void) -> NSPopUpButton {
        let p = ClosurePopUp(items: items, f)
        p.selectItem(at: selected)
        return p
    }

    private func check(_ title: String, _ on: Bool, _ f: @escaping (Bool) -> Void) -> NSButton {
        ClosureCheck(title: title, on: on, f)
    }

    private func button(_ title: String, _ f: @escaping () -> Void) -> NSButton { ClosureButton(title: title, f) }

    // MARK: pages

    private func general() -> NSView {
        let langs = Prefs.Language.allCases
        let lang = popup([tr("跟随系统", "System"), "中文", "English"], selected: langs.firstIndex(of: Prefs.language) ?? 0) { [weak self] i in
            Prefs.language = langs[i]
            self?.onLanguage?()
        }
        let looks = Prefs.Appearance.allCases
        let look = NSSegmentedControl(labels: [tr("跟随系统", "System"), tr("浅色", "Light"), tr("深色", "Dark")],
                                      trackingMode: .selectOne, target: nil, action: nil)
        look.selectedSegment = looks.firstIndex(of: Prefs.appearance) ?? 0
        let lookHandler = ClosureTarget { Prefs.appearance = looks[look.selectedSegment] }
        look.target = lookHandler; look.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(look, "h", lookHandler, .OBJC_ASSOCIATION_RETAIN)

        let login = check(tr("登录时自动启动（只在菜单栏）", "Start at login (menu bar only)"), LoginItem.enabled) { [weak self] on in
            LoginItem.choose(on)
            self?.loginBox?.state = LoginItem.enabled ? .on : .off      // what's really there, also when it couldn't be done
        }
        loginBox = login
        let intro = button(tr("再看一次介绍", "Show the intro again")) { [weak self] in self?.onIntro?() }
        let data = button(tr("打开数据文件夹", "Open data folder")) { [weak self] in
            guard let self = self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.store.dir.appendingPathComponent("data")])
        }
        let g = grid([
            [label(tr("语言", "Language"), width: 140), lang],
            [label(tr("外观", "Appearance"), width: 140), look],
            [NSGridCell.emptyContentView, label(tr("导图顶栏的 ☾ / ☀︎ 按钮可以随时开关灯。", "The ☾ / ☀︎ button in the map's top bar flips it any time."), small: true, width: 360)],
            [label(tr("启动", "Startup"), width: 140), login],
            [NSGridCell.emptyContentView, NSStackView(views: [intro, data])],
        ])
        return g
    }

    private func notifications() -> NSView {
        // a system sound, your own file, or none
        func soundPop(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> NSPopUpButton {
            var keys: [String] = []
            weak var p: NSPopUpButton?          // weak: the pop-up holds this closure
            func fill() {
                guard let p = p else { return }
                let cur = get()
                keys = Sounds.choices + (cur.hasPrefix("/") ? [cur] : []) + ["other", "off"]
                p.removeAllItems()
                p.addItems(withTitles: keys.map { k in
                    k == "off" ? tr("不响", "None")
                        : k == "other" ? tr("其他声音文件…", "Other sound file…")
                        : k.hasPrefix("/") ? "♪ " + URL(fileURLWithPath: k).deletingPathExtension().lastPathComponent : k
                })
                p.selectItem(at: keys.firstIndex(of: cur) ?? 0)
            }
            let pop = popup([], selected: 0) { i in
                guard i < keys.count else { return }
                if keys[i] == "other" {
                    if let path = Sounds.importFile() { set(path) }
                    fill()
                } else {
                    set(keys[i])
                }
                Sounds.sound(get())?.play()
            }
            p = pop
            fill()
            return pop
        }
        let done = soundPop({ Prefs.soundDone }) { Prefs.soundDone = $0 }
        let input = soundPop({ Prefs.soundInput }) { Prefs.soundInput = $0 }
        let quiet = check(tr("正在看 Claude App 时不响", "Stay quiet while the Claude app is in front"), Prefs.quietWhenClaudeFront) { Prefs.quietWhenClaudeFront = $0 }

        // the chat's name, read aloud after the sound
        let speak = check(tr("响完再念出是哪个对话", "Then say which chat it was"), Prefs.speak) { Prefs.speak = $0 }
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") || $0.language.hasPrefix("zh") }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
        func grade(_ v: AVSpeechSynthesisVoice) -> String {
            switch v.quality { case .premium: return " ★★"; case .enhanced: return " ★"; default: return "" }
        }
        let voicePop = popup([tr("自动（跟着文字的语言）", "Automatic (matches the language)")] + voices.map { "\($0.name) · \($0.language)\(grade($0))" },
                             selected: (voices.firstIndex { $0.identifier == Prefs.speakVoice }).map { $0 + 1 } ?? 0) { i in
            Prefs.speakVoice = i == 0 ? nil : voices[i - 1].identifier
        }
        let rates = Prefs.speakRates
        let ratePop = popup([tr("慢", "Slow"), tr("正常", "Normal"), tr("快", "Fast"), tr("更快", "Faster")],
                            selected: rates.firstIndex { abs($0 - Prefs.speakRate) < 0.01 } ?? 1) { i in Prefs.speakRate = rates[i] }
        let doneText = ClosureField(string: Prefs.speakDone) { Prefs.speakDone = $0.isEmpty ? "{name}" : $0 }
        let inputText = ClosureField(string: Prefs.speakInput) { Prefs.speakInput = $0.isEmpty ? "{name}" : $0 }
        for f in [doneText, inputText] { f.widthAnchor.constraint(equalToConstant: 220).isActive = true }
        let test = button(tr("试听", "Test")) { [weak self] in self?.window?.makeFirstResponder(nil); self?.sounds?.test() }

        let g = grid([
            [label(tr("做完了", "Finished"), width: 140), done],
            [label(tr("需要你操作", "Needs your input"), width: 140), input],
            [NSGridCell.emptyContentView, quiet],
            [NSGridCell.emptyContentView, speak],
            [label(tr("念的内容", "What it says"), width: 140), NSStackView(views: [doneText, label(tr("做完了", "finished"), small: true, width: 120)])],
            [NSGridCell.emptyContentView, NSStackView(views: [inputText, label(tr("在等你", "waiting for you"), small: true, width: 120)])],
            [label(tr("声音", "Voice"), width: 140), voicePop],
            [label(tr("语速", "Speed"), width: 140), NSStackView(views: [ratePop, test])],
        ])
        let note = label(tr("Claude App 的对话：Kikumap 从 Claude 窗口的侧边栏看到它们做完，所以窗口要开在你用的桌面上。开了「完全磁盘访问」（设置 → 授权），Claude 问「允许吗？」或等你回答时、Cowork 任务做完时，窗口关着也会提醒（普通对话回复完 Claude 不发通知）。Claude Code 会话靠 设置 → 授权 里连接的 hook。",
                            "Claude app chats: Kikumap sees them finish in Claude's sidebar, so keep its window open on the desktop you use. With Full Disk Access (Settings → Access) you're also told, even with the window closed, when Claude asks \"Allow this?\" or waits for an answer, and when a Cowork task finishes (Claude sends no notification when an ordinary chat's reply finishes). Claude Code sessions use the hooks connected in Settings → Access."), small: true)
        let voiceNote = label(tr("{name} 会换成对话名。名字会念出声，周围的人也听得到。想要更自然的声音：系统设置 → 辅助功能 → 朗读内容 → 系统声音 → 管理声音，下载带 ★ 的高质量声音。",
                                 "{name} becomes the chat's name. It's said out loud, so people nearby hear it too. For a more natural voice: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, and download a Premium or Enhanced one (★)."), small: true)
        return vstack([g, voiceNote, note], spacing: 18)
    }

    static let aboutTab = 6
    static let links = (site: "https://tang1693.github.io/KIKUmap/", repo: "https://github.com/tang1693/KIKUmap",
                        issues: "https://github.com/tang1693/KIKUmap/issues", tip: "https://ko-fi.com/vegligi")

    private func about() -> NSView {
        func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = NSTextField(labelWithString: "Kikumap")
        name.font = .systemFont(ofSize: 22, weight: .bold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let head = vstack([name, label(tr("Claude 和 ChatGPT 对话导图", "A mind map for your Claude and ChatGPT chats") + " · " + tr("版本 ", "version ") + version, small: true, width: 360)], spacing: 4)
        let top = NSStackView(views: [icon, head])
        top.spacing = 16
        top.alignment = .centerY
        let by = label(tr("作者：Yang Tang（GitHub @tang1693）", "Made by Yang Tang (GitHub @tang1693)"), bold: true)
        let story = label(tr("我自己同时开着一堆 Claude 对话，总是忘了哪个做完了、哪个在等我，就做了这个小工具。免费、开源，所有数据都留在你的 Mac 上。",
                             "I keep a lot of Claude chats open at once and kept losing track of which one had finished or was waiting for me, so I built this. It's free and open source, and everything stays on your Mac."))
        let links = NSStackView(views: [
            button(tr("网站", "Website")) { open(SettingsWindow.links.site) },
            button("GitHub") { open(SettingsWindow.links.repo) },
            button(tr("反馈问题", "Report an issue")) { open(SettingsWindow.links.issues) },
        ])
        links.spacing = 8
        let tip = button(tr("☕ 请我喝杯咖啡（Ko-fi）", "☕ Buy me a coffee on Ko-fi")) { open(SettingsWindow.links.tip) }
        let tipNote = label(tr("Kikumap 是免费的。如果它帮你省了时间，可以请我喝杯咖啡；点个 GitHub ⭐ 或者反馈问题也一样有帮助。",
                               "Kikumap is free. If it saves you time, you can buy me a coffee; a GitHub star or a bug report helps just as much."), small: true)
        let fine = label(tr("个人独立开源项目，与 Anthropic 无关。MIT 协议。", "An independent open-source project, not affiliated with Anthropic. MIT License."), small: true)
        return vstack([top, by, story, links, tip, tipNote, fine], spacing: 14)
    }

    private func access() -> NSView {
        func row(_ title: String, _ why: String, _ action: String, _ ok: @escaping () -> Bool, _ run: @escaping () -> Void) -> NSView {
            row(title, why, action, { let on = ok(); return Perm(text: on ? tr("✓ 已开启", "✓ On") : tr("未开启", "Off"), on: on, enabled: !on) }, run)
        }
        func row(_ title: String, _ why: String, _ action: String, _ state: @escaping () -> Perm, _ run: @escaping () -> Void) -> NSView {
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 12, weight: .medium)
            status.lineBreakMode = .byTruncatingTail
            let b = button(action, run)
            permRows.append((status, b, state))
            let head = NSStackView(views: [label(title, bold: true), status])
            head.spacing = 10
            let text = vstack([head, label(why, small: true, width: 380)], spacing: 4)
            let line = NSStackView(views: [text, b])
            line.alignment = .centerY
            line.distribution = .fill
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            b.setContentHuggingPriority(.required, for: .horizontal)
            line.widthAnchor.constraint(equalToConstant: 500).isActive = true
            return line
        }
        let p = perms
        let on = tr("✓ 已开启", "✓ On"), off = tr("未开启", "Off")
        let rows = [
            row(tr("完全磁盘访问", "Full Disk Access"),
                tr("可选。读 macOS 通知中心里 Claude 的通知 → Claude 问「允许吗？」或等你回答时提醒你；Claude App 里的 Cowork 任务做完时，窗口关着也知道（普通对话回复完 Claude 不发通知）。只读，不上传。",
                   "Optional. Reads Claude's notifications from Notification Center → tells you when Claude asks \"Allow this?\" or waits for your answer, and knows when a Cowork task in the Claude app finishes, even with its window closed (Claude sends no notification when an ordinary chat's reply finishes). Read-only, never uploaded."),
                tr("打开设置", "Open Settings"), {
                    guard p.fullDisk else {
                        // opened from here already: switched on in System Settings, it only counts once Kikumap reopens
                        return p.fullDiskAsked ? Perm(text: tr("未开启 · 开了的话要重新打开 Kikumap", "Off · switched it on? Reopen Kikumap"), on: false, enabled: true,
                                                      why: tr("「完全磁盘访问」要等 Kikumap 重新打开才生效。点「打开设置」可以退出并重新打开。", "Full Disk Access only counts once Kikumap reopens. Click Open Settings to quit and reopen it."))
                                               : Perm(text: off, on: false, enabled: true)
                    }
                    if p.notifications.status == .unreadable {
                        return Perm(text: tr("已开启 · 读不了通知数据库", "On · can't read Notification Center"), on: false, enabled: false,
                                    why: tr("macOS 的通知数据库读不了（系统更新改了它？）：", "Notification Center's database can't be read (changed by a macOS update?): ") + (p.notifications.problem ?? ""))
                    }
                    return Perm(text: on, on: true, enabled: false)
                }, { p.openFullDisk() }),
            row(tr("辅助功能", "Accessibility"),
                tr("读 Claude App 侧边栏 → 知道哪些对话还在跑、你在 Claude 里看过哪个。",
                   "Reads the Claude app's sidebar → knows which chats are still running and which you've read."),
                tr("打开设置", "Open Settings"), {
                    let trusted = AXIsProcessTrusted()
                    if !trusted && p.sidebar.status == .notInstalled {
                        return Perm(text: tr("用不上：这台 Mac 上没有 Claude App", "Not needed: no Claude app on this Mac"), on: false, enabled: true)
                    }
                    return Perm(text: trusted ? on : off, on: trusted, enabled: !trusted)
                }, { p.openAccessibility() }),
            row(tr("用量", "Usage"),
                tr("可选，默认关闭。需要 Claude 付费套餐（Pro、Max、Team 或 Enterprise），并在这台 Mac 的 Claude Code 里登录（免费套餐和 API key 没有用量可看）。开启后借用 Claude Code 在钥匙串里的登录，读取 5 小时 / 每周用量和计划任务；只读，只发给 api.anthropic.com。",
                   "Optional, off by default. Needs a paid Claude plan (Pro, Max, Team or Enterprise) signed in to Claude Code on this Mac (the Free plan and API keys have no usage to show). When on, it borrows Claude Code's sign-in from the Keychain to read 5-hour / weekly usage and scheduled tasks — read-only, sent only to api.anthropic.com."),
                tr("连接", "Connect"), {
                    guard UsageMonitor.enabled else { return Perm(text: off, on: false, button: tr("连接", "Connect"), enabled: true) }
                    let who = p.usage.account.map { tr("\n账号：", "\nAccount: ") + $0 } ?? ""
                    switch p.usage.status {
                    case .ok: return Perm(text: on, on: true, button: tr("连接", "Connect"), enabled: false, why: tr("Claude Code 的账号", "Claude Code's account") + who)
                    case .unknown: return Perm(text: tr("已开启 · 读取中…", "On · reading…"), on: true, button: tr("连接", "Connect"), enabled: false)
                    default:
                        let short: String
                        switch p.usage.status {
                        case .noLogin: short = tr("Claude Code 未登录", "Claude Code not signed in")
                        case .expired: short = tr("登录过期了", "sign-in expired")
                        case .noScope: short = tr("要重新 /login", "needs /login again")
                        case .denied: short = tr("读不到登录", "can't read the sign-in")
                        case .limited: short = tr("暂停查询中", "waiting a while")
                        case .locked: short = tr("钥匙串锁着", "keychain locked")
                        default: short = tr("暂时读不到", "can't reach it right now")
                        }
                        return Perm(text: tr("已开启 · ", "On · ") + short, on: false, button: tr("重新读取", "Read again"), enabled: true, why: p.usage.hint + who)
                    }
                }, { p.connectUsage() }),
            row("Claude Code",
                tr("在 ~/.claude/settings.json 里加几个 hook → 终端、VS Code 里的 Claude Code 会话也能显示「进行中 / 未读」。原文件会备份。新开的会话才生效。",
                   "Adds a few hooks to ~/.claude/settings.json → Claude Code sessions in Terminal or VS Code show as running / unread too. The old file is backed up. Applies to sessions started afterwards."),
                tr("连接", "Connect"), {
                    guard p.codeHooks else { return Perm(text: off, on: false, enabled: true) }
                    if let why = CodeHooks.blockedReason() { return Perm(text: tr("已连接 · 但 hook 被关掉了", "Connected · but hooks are off"), on: false, enabled: false, why: why) }
                    return Perm(text: on, on: true, enabled: false)
                }, { p.connectCode() }),
            row("ChatGPT",
                tr("读 ChatGPT 桌面 App 存在这台 Mac 上的 Codex 对话（含 VS Code、终端里的 Codex）：列表、置顶、未读和用量（~/.codex，只读）→ 在 ChatGPT 里置顶的对话也显示「进行中 / 未读」，小组件也能显示 ChatGPT 的用量。普通 ChatGPT 聊天存在云端，不在这里。不改任何东西，不上传。",
                   "Reads the Codex chats the ChatGPT desktop app keeps on this Mac (and Codex in VS Code or the terminal): list, pins, unread dots and usage (~/.codex, read-only) → those pinned in ChatGPT show as running / unread too, and the widget can show ChatGPT's usage. Ordinary ChatGPT chats live online and aren't here. Changes nothing, uploads nothing."),
                tr("连接", "Connect"), {
                    guard GPTWatcher.enabled else { return Perm(text: off, on: false, enabled: true) }
                    guard GPTWatcher.available else { return Perm(text: tr("已开启 · 还没找到它的数据", "On · its data isn't there yet"), on: false, enabled: true) }
                    if let e = p.gptError?() { return Perm(text: tr("已开启 · 读不了", "On · can't read it"), on: false, enabled: false, why: e) }
                    if !GPTWatcher.installed && GPTWatcher.oldAppOnly {
                        return Perm(text: tr("已开启 · 旧版 ChatGPT App：只读编辑器、终端里的 Codex", "On · older ChatGPT app: Codex in editors and the terminal only"), on: true, enabled: false,
                                    why: tr("更新到新版 ChatGPT App（Codex 内核），才能看到在它里面置顶的对话。", "Update to the current ChatGPT app (built on Codex) to see the chats you pin there."))
                    }
                    if !GPTWatcher.installed { return Perm(text: tr("已开启 · 没有 ChatGPT App，只读编辑器、终端里的 Codex", "On · no ChatGPT app: Codex in editors and the terminal only"), on: true, enabled: false) }
                    return Perm(text: on, on: true, enabled: false)
                }, { [weak self] in p.connectGPT(); self?.refreshPerms() }),
        ]
        let tip = label(tr("如果这里显示未开启、但系统设置里已经勾上：先退出并重新打开 Kikumap；还是不行（比如重装之后），在系统设置里把 Kikumap 删掉（−）再重新加一次。",
                           "If access shows as off here but it's ticked in System Settings: quit and reopen Kikumap first; if it's still off (after reinstalling, say), remove Kikumap there (−) and add it again."), small: true)
        let diag = button(tr("诊断报告", "Diagnostic report")) { [weak self] in self?.onDiagnose?() }
        diag.toolTip = tr("写一份 kikumap-check.txt：哪些正常、哪些不行。不含对话标题、内容和密码，可以直接发给帮你看的人。",
                          "Writes kikumap-check.txt: what works and what doesn't. No chat titles, messages or passwords, so you can send it to whoever helps.")
        let unhook = button(tr("断开 Claude Code", "Disconnect Claude Code")) { [weak self] in p.disconnectCode(); self?.refreshPerms() }
        let usageOff = button(tr("关闭用量", "Turn off usage")) { [weak self] in p.disconnectUsage(); self?.refreshPerms() }
        let gptOff = button(tr("断开 ChatGPT", "Disconnect ChatGPT")) { [weak self] in p.disconnectGPT(); self?.refreshPerms() }
        offButtons = [(unhook, { p.codeHooks }), (usageOff, { UsageMonitor.enabled }), (gptOff, { GPTWatcher.enabled })]
        return vstack(rows + [tip, NSStackView(views: [diag, unhook, usageOff, gptOff])], spacing: 18)
    }

    private func refreshPerms() {
        for (status, b, state) in permRows {
            let st = state()
            status.stringValue = st.text
            status.textColor = st.on ? .labelColor : .secondaryLabelColor
            status.toolTip = st.why
            if let t = st.button, b.title != t { b.title = t }
            b.isEnabled = st.enabled
        }
        for (b, on) in offButtons { b.isEnabled = on() }
        // Start at login can change elsewhere too (the intro, the To-do, the installer)
        loginBox?.state = LoginItem.enabled ? .on : .off
    }

    private func shortcuts() -> NSView {
        let field = HotKeyField()
        hotKeyField = field
        field.onChange = { [weak self] code, mods in
            Prefs.hotKeyCode = code; Prefs.hotKeyMods = mods
            self?.onHotKey?()
        }
        field.onRecording = { [weak self] on in self?.onSuspendHotKey?(on) }
        let on = check(tr("启用", "Enabled"), Prefs.hotKeyEnabled) { [weak self] v in Prefs.hotKeyEnabled = v; self?.onHotKey?() }
        let reset = button(tr("恢复 ⌃⌥C", "Reset to ⌃⌥C")) { [weak self] in
            Prefs.hotKeyCode = UInt32(kVK_ANSI_C); Prefs.hotKeyMods = UInt32(controlKey | optionKey)
            field.refresh(); self?.onHotKey?()
        }
        let g = grid([[label(tr("调出 / 收起导图", "Show / hide the map"), width: 140), NSStackView(views: [field, on, reset])]])
        let keys: [(String, String, String)] = [
            ("⇥ / ⌥⇥", "新子主题 / 新父主题", "new child / parent topic"),
            ("⏎ / ⌥⏎ / ⇧⏎", "下方同级 / 上方同级 / 新主主题", "sibling below / above / new main topic"),
            ("⌘⏎ · F2 · 双击", "改名（对话名只在本地）", "rename (chat names stay local)"),
            ("⌫ / ⌥⌫", "删除（连同 / 不连同下面的）", "delete (with / without children)"),
            ("⌥.", "折叠 / 展开", "fold / unfold"),
            ("⌥↑ ⌥↓", "调整顺序", "move among siblings"),
            ("⌘Z / ⇧⌘Z", "撤销 / 重做", "undo / redo"),
            ("⌘↓ · Space", "在它的 App 里打开对话", "open the chat in its app"),
            ("⌘= ⌘- ⌘0", "放大 / 缩小 / 适应窗口", "zoom in / out / fit"),
        ]
        let rows: [[NSView]] = keys.map { k in
            let a = NSTextField(labelWithString: k.0)
            a.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            return [a, label(tr(k.1, k.2))]
        }
        let list = NSGridView(views: rows)
        list.rowSpacing = 6
        list.columnSpacing = 18
        list.column(at: 0).xPlacement = .trailing
        return vstack([g, label(tr("导图里的按键（和 MindNode 一样）", "Keys in the map (same as MindNode)"), bold: true), list], spacing: 18)
    }

    private func archivePage() -> NSView {
        let intro = label(tr("""
        选主题，把下面的对话一次性导出：每个对话一个文件夹，里面有 memory.md（Claude 写的交接总结）、提示词、完整对话、全部 artifacts 和附件。可以设成自动更新。以后能一键导入到新的 Claude 账号，新对话带着总结和文件接着做。
        """, """
        Pick topics and export their chats in one go: one folder per chat with memory.md (a hand-off summary by Claude), the prompts, the whole conversation, every artifact and attachment. It can keep itself updated. Later, import into another Claude account in one go and the new chats carry on with the summary and files.
        """), small: true)
        let open = button(tr("导出…", "Export…")) { [weak self] in self?.onArchiveAll?() }
        let imp = button(tr("导入到当前账号…", "Import into this account…")) { [weak self] in self?.onImport?() }
        let show = button(tr("在访达中显示", "Show in Finder")) {
            Archive.settleFolder()
            try? FileManager.default.createDirectory(at: Archive.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([Archive.folder])
        }
        archiveButtons = [open, imp]
        let actions = NSStackView(views: [open, imp, show])
        actions.spacing = 8
        let path = label(Archive.folder.path, small: true, width: 380)
        archiveFolderLabel = path
        let status = label("", small: true, width: 380)
        archiveStatus = status
        let tip = label(tr("也可以右键单个对话 →「让 Claude 写总结存档…」，先试一个。", "Or right-click one chat → \"Archive a summary…\" to try one first.")
                        + (ClaudeExport.canLookInDownloads ? "" : tr("\n第一次存到「文稿」「桌面」或「下载」里时，macOS 会问一次是否允许。",
                                                                    "\nThe first time it saves into Documents, Desktop or Downloads, macOS asks once whether that's OK.")),
                        small: true, width: 380)
        let g = grid([
            [label(tr("导出", "Export"), width: 140), actions],
            [label(tr("存在", "Folder"), width: 140), path],
            [NSGridCell.emptyContentView, status],
            [NSGridCell.emptyContentView, tip],
        ])
        refreshArchive()
        return vstack([intro, g], spacing: 18)
    }

    /// Progress / last result, and whether the buttons can be used.
    func refreshArchive() {
        guard let a = archive else { return }
        archiveFolderLabel?.stringValue = Archive.folder.path
        if a.busy {
            archiveStatus?.stringValue = tr("正在运行：", "Running: ") + a.progress
        } else {
            let last = Archive.lastResult
            archiveStatus?.stringValue = last.isEmpty ? tr("还没存过。", "Nothing archived yet.") : tr("上次：", "Last: ") + last
        }
        archiveButtons.forEach { $0.isEnabled = !a.busy }
    }

    private func tagsPage() -> NSView {
        let stack = vstack([], spacing: 8)
        tagStack = stack
        fillTags()
        let add = button(tr("＋ 新标签", "＋ New tag")) { [weak self] in
            guard let self = self else { return }
            let map = self.store.map
            if let n = TagPrompt.ask(color: map.nextTagColor(), window: self.window) {
                map.addTag(n.name, color: n.color, icon: n.icon, group: n.group)
                self.store.notify()
                self.fillTags()
            }
        }
        let intro = label(tr("界面本身是灰阶的；颜色只留给你：给分支上色（右键主题 → 分支颜色），或者给对话 / 主题加标签（右键 → 标签），一个可以有多个。",
                             "The interface itself is greyscale; colour is yours: colour a branch (right-click a topic → Branch colour) or tag chats and topics (right-click → Tags), as many as you like."), small: true)
        let swatches = NSStackView(views: Theme.highlights.map { h in
            let v = NSImageView(image: Theme.swatch(h.color, size: 16)); v.toolTip = tr(h.zh, h.en); return v
        })
        swatches.spacing = 4
        return vstack([intro, swatches, stack, add], spacing: 14)
    }

    private func fillTags() {
        guard let stack = tagStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let map = store.map
        if map.tags.isEmpty {
            stack.addArrangedSubview(label(tr("还没有标签。", "No tags yet."), small: true))
            return
        }
        for t in map.tags.sorted(by: { a, b in
            let order = Tag.groups.map(\.key)
            return (order.firstIndex(of: a.category) ?? 2) < (order.firstIndex(of: b.category) ?? 2)
        }) {
            let pop = ColorPopUp(selected: t.color)
            pop.onPick = { [weak self] c in map.updateTag(t.id, color: c); self?.store.notify(); self?.fillTags() }
            let name = ClosureField(string: t.name) { [weak self] s in map.updateTag(t.id, name: s); self?.store.notify() }
            name.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let group = NSPopUpButton(frame: .zero, pullsDown: false)
            for g in Tag.groups { group.addItem(withTitle: tr(g.zh, g.en)); group.lastItem?.representedObject = g.key }
            group.selectItem(at: Tag.groups.firstIndex { $0.key == t.category } ?? 2)
            let pickGroup = ClosureTarget { [weak self, weak group] in
                guard let g = group?.selectedItem?.representedObject as? String else { return }
                map.updateTag(t.id, group: g); self?.store.notify(); self?.fillTags()
            }
            group.target = pickGroup
            group.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(group, "target", pickGroup, .OBJC_ASSOCIATION_RETAIN)
            let tint = Theme.highlight(t.color) ?? Theme.muted
            var iconButton: ClosureButton!
            iconButton = ClosureButton(title: "") { [weak self] in
                guard let b = iconButton else { return }
                IconPicker.show(relativeTo: b.bounds, of: b, selected: t.icon, tint: tint,
                                clear: t.icon == nil ? nil : (tr("不要图标", "No icon"), { map.updateTag(t.id, icon: .some(nil)); self?.store.notify(); self?.fillTags() })) { name in
                    map.updateTag(t.id, icon: .some(name)); self?.store.notify(); self?.fillTags()
                }
            }
            iconButton.image = t.icon.map { Icons.image($0, size: 16, color: tint) } ?? Theme.swatch(tint)
            iconButton.imagePosition = .imageOnly
            iconButton.toolTip = tr("换图标", "Change the icon")
            iconButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
            let del = button(tr("删除", "Delete")) { [weak self] in
                map.deleteTag(t.id); self?.store.notify(); self?.fillTags()
            }
            let row = NSStackView(views: [iconButton, pop, name, group, del])
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
    }
}

// MARK: - closure-based controls (keeps the settings code short)

final class ClosureTarget: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}

final class ClosureButton: NSButton {
    private var run: () -> Void = {}
    convenience init(title: String, _ run: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.run = run
        bezelStyle = .rounded
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { run() }
}

final class ClosureCheck: NSButton {
    private var run: (Bool) -> Void = { _ in }
    convenience init(title: String, on: Bool, _ run: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        self.state = on ? .on : .off
        self.run = run
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { run(state == .on) }
}

final class ClosurePopUp: NSPopUpButton {
    private var run: (Int) -> Void = { _ in }
    convenience init(items: [String], _ run: @escaping (Int) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items)
        self.run = run
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { run(indexOfSelectedItem) }
}

final class ClosureField: NSTextField, NSTextFieldDelegate {
    private var run: (String) -> Void = { _ in }
    convenience init(string: String, _ run: @escaping (String) -> Void) {
        self.init(frame: .zero)
        stringValue = string
        self.run = run
        delegate = self
    }
    func controlTextDidEndEditing(_ obj: Notification) { run(stringValue) }
}
