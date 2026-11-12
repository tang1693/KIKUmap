import Cocoa
import Carbon
import AVFoundation

/// The three things the app needs from macOS, checked live and opened one at a time.
@MainActor
final class Permissions {
    let notifications: NotificationWatcher
    let sidebar: SidebarWatcher
    let usage: UsageMonitor
    let gptUsage: GPTUsageMonitor

    init(notifications: NotificationWatcher, sidebar: SidebarWatcher, usage: UsageMonitor, gptUsage: GPTUsageMonitor) {
        self.notifications = notifications
        self.sidebar = sidebar
        self.usage = usage
        self.gptUsage = gptUsage
    }

    /// Granted (also when the database it opens couldn't be read as expected: that's not a permission problem).
    var fullDisk: Bool { notifications.recheck(); return notifications.status == .ok || notifications.status == .unreadable }
    var accessibility: Bool { AXIsProcessTrusted() }
    /// Accessibility is of use on this Mac: the Claude app or ChatGPT is here (it reads their windows; not the older
    /// ChatGPT app's). Without either, the intro and Settings say it isn't needed, and why.
    var accessNeeded: Bool { sidebar.status != .notInstalled || GPTWatcher.installed }
    var usageOK: Bool { usage.status == .ok }

    static func openPane(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Full Disk Access was opened from here in this run (once switched on, macOS gives it only after a reopen).
    var fullDiskAsked = false

    /// Full Disk Access has no system prompt: say what it's for and what to do, then open the list and show the app in
    /// Finder to drag in.
    func openFullDisk() {
        if fullDiskAsked { reopenForFullDisk(); return }
        let a = NSAlert()
        a.messageText = tr("把 KIKUmap 加进「完全磁盘访问」", "Add KIKUmap to Full Disk Access")
        a.informativeText = Permissions.fullDiskWhy + "\n\n" + Permissions.fullDiskSteps
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
            已经在系统设置里打开了 KIKUmap 的开关？那要退出并重新打开 KIKUmap 才能用上（在 macOS 的提示里选了「以后」就会这样）。

            还没打开？打开系统设置，把 KIKUmap 从访达窗口拖进列表（或点 ＋ 选它），再打开开关。
            """, """
            Already switched KIKUmap on in System Settings? Then KIKUmap has to quit and reopen to get access (this happens if you chose "Later" when macOS asked).

            Not yet? Open System Settings, drag KIKUmap from the Finder window into the list (or click + and choose it), then switch it on.
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

    /// Starts a new KIKUmap, which takes over from this one as an update does (an unfinished intro comes back where it was).
    static func reopen() {
        let c = NSWorkspace.OpenConfiguration()
        c.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: c) { _, error in
            guard let error = error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    alert(tr("没能重新打开 KIKUmap", "Couldn't reopen KIKUmap"), error.localizedDescription + tr("\n\n请退出 KIKUmap，再打开它。", "\n\nQuit KIKUmap and open it again."))
                }
            }
        }
    }

    /// What Full Disk Access gets KIKUmap, said before anything opens (Settings → Access says it in one line).
    static var fullDiskWhy: String {
        tr("有了它，KIKUmap 能读通知中心里 Claude 发的通知（只读，不上传）：Claude 问「允许吗？」、等你回答，或者 Cowork 任务做完时，窗口关着也知道。普通对话回复完，Claude 不发通知。",
           "With it, KIKUmap can read Claude's notifications in Notification Center (read-only, never uploaded): it knows when Claude asks \"Allow this?\", waits for your answer or finishes a Cowork task, even with its window closed. Claude sends no notification when an ordinary chat's reply finishes.")
    }

    /// After "Quit & Reopen" only the first-run intro comes back where it was (from anywhere else the map opens).
    static var fullDiskSteps: String {
        tr("""
            接下来会打开系统设置里的「完全磁盘访问」，还有一个已经选中 KIKUmap 的访达窗口。把 KIKUmap 从访达拖进列表（或点 ＋ 选它），再打开它的开关。

            如果 macOS 问要不要「退出并重新打开」，选它：
            """, """
            System Settings opens at Full Disk Access, along with a Finder window that has KIKUmap selected. Drag KIKUmap into the list (or click + and choose it), then switch it on.

            If macOS offers "Quit & Reopen", choose it:
            """) + (Prefs.onboarded
                ? tr("KIKUmap 会自己重新打开，之后 设置 → 授权 里会显示「✓ 已开启」。", " KIKUmap opens again by itself; Settings → Access then shows ✓ On.")
                : tr("KIKUmap 会自己重新打开，回到介绍的这一步。", " KIKUmap opens again by itself, back at this step of the intro."))
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
            a.informativeText = Permissions.usageSteps(claudeCode: UsageMonitor.claudeCodeInstalled)
            a.addButton(withTitle: tr("继续", "Continue"))
            a.addButton(withTitle: tr("先不用", "Not now"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        UsageMonitor.enabled = true
        usage.reconnect()
        usage.start()
    }

    /// What turning Claude's usage on means, said before anything is read (`claudeCode`: it's on this Mac).
    static func usageSteps(claudeCode: Bool) -> String {
        tr("""
            KIKUmap 可以借用 Claude Code 存在这台 Mac 钥匙串里的登录，查你的套餐用量和计划任务，不用再登录一次。需要 Claude 付费套餐（Pro、Max、Team 或 Enterprise），并在 Claude Code 里登录；免费套餐和 API key 没有用量可看。

            • 只读这份登录，不改、不存
            • 每 10 分钟查一次，只发给 api.anthropic.com，只用来查用量和计划任务
            • Anthropic 不允许第三方应用收集 Claude 的登录信息。KIKUmap 只在本机读、不保存、只查你自己的用量，但这样做仍可能不被允许、被限制。开不开由你决定
            • 随时可以在 设置 → 授权 里关掉

            KIKUmap 读它的方式和 Claude Code 一样，所以 macOS 一般不会问。如果问了，选「允许」。
            """, """
            KIKUmap can look up your plan usage and scheduled tasks with the sign-in Claude Code already keeps in this Mac's Keychain, so you don't sign in again. It needs a paid Claude plan (Pro, Max, Team or Enterprise) signed in to Claude Code. The Free plan and API keys have no usage to show.

            • It only reads the sign-in: it never changes or saves it
            • It's sent only to api.anthropic.com, every 10 minutes, only to look up usage and scheduled tasks
            • Anthropic doesn't allow third-party apps to collect Claude sign-ins. KIKUmap only reads it on this Mac, never saves it and only looks up your own usage, but this may still not be allowed and could be blocked. It's your call
            • You can turn it off any time in Settings → Access

            KIKUmap reads it the same way Claude Code does, so macOS usually doesn't ask. If it does, choose "Allow".
            """) + (claudeCode ? "" : tr("\n\n这台 Mac 上好像还没装 Claude Code。先装好它，在终端运行 claude，再用付费账号 /login，这里才会有用量。",
                                         "\n\nClaude Code doesn't seem to be on this Mac yet. Install it, run claude in Terminal and /login with your paid account; then usage shows here."))
    }

    func disconnectUsage() {
        UsageMonitor.enabled = false
        usage.stop()
    }

    /// ChatGPT's usage straight from OpenAI needs the ChatGPT sign-in Codex keeps on this Mac, so nothing is read
    /// until you agree here (it's a file: macOS asks nothing).
    func connectGPTUsage() {
        if !GPTUsageMonitor.enabled {
            let a = NSAlert()
            a.messageText = tr("直接向 OpenAI 查 ChatGPT 的用量？（试验性）", "Get ChatGPT's usage straight from OpenAI? (experimental)")
            let none = GPTUsageMonitor.readAuth() == nil
                ? tr("\n\n这台 Mac 上的 Codex 好像还没用 ChatGPT 账号登录。先在 ChatGPT 桌面 App 或 Codex 里登录，这里才查得到。",
                     "\n\nCodex on this Mac doesn't seem to be signed in with a ChatGPT account yet. Sign in in the ChatGPT desktop app or in Codex first.")
                : ""
            a.informativeText = Permissions.gptUsageSteps + none
            a.addButton(withTitle: tr("开启", "Turn on"))
            a.addButton(withTitle: tr("先不用", "Not now"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        GPTUsageMonitor.enabled = true
        gptUsage.start()
        // (Read again: even while OpenAI asked to wait, as Claude's; the refresh button waits)
        gptUsage.reconnect()
    }

    /// What turning ChatGPT's usage on means, said before anything is read.
    static var gptUsageSteps: String {
        tr("""
            不开的话，ChatGPT 的用量只在你用 Codex 跑任务时更新（从 Codex 在这台 Mac 上的记录里读）；用量重置后，要等下次用 Codex 才有新数字。

            开了以后，KIKUmap 借用 Codex 存在这台 Mac 上的 ChatGPT 登录（~/.codex/auth.json），像 Codex 自己那样每 10 分钟向 OpenAI 查一次用量，不用再登录一次。

            • 只读这份登录，不改、不存，也不帮它续期（过期了，用一下 Codex 就会续上）
            • 只发给 chatgpt.com，只用来查用量
            • 用的是 OpenAI 没公开的接口，OpenAI 也没说允许别的应用这样用：以后可能失效或被限制，开不开由你决定。失效了，照样显示你用 Codex 时的数字
            • 随时可以在 设置 → 授权 里关掉
            """, """
            Without it, ChatGPT's usage updates only when you run a Codex task (KIKUmap reads it from Codex's own records on this Mac). After a reset, the new numbers show only once you use Codex again.

            With it, KIKUmap uses the ChatGPT sign-in Codex keeps on this Mac (~/.codex/auth.json) to ask OpenAI for your usage every 10 minutes, the way Codex itself does. You don't sign in again.

            • It only reads the sign-in: it never changes, saves or renews it (if it expires, using Codex renews it)
            • It's sent only to chatgpt.com, only to look up usage
            • It uses an interface OpenAI hasn't published, and OpenAI hasn't said other apps may use it. It may stop working or be blocked, so it's your call. If it stops, the numbers from using Codex still show
            • You can turn it off any time in Settings → Access
            """)
    }

    func disconnectGPTUsage() {
        GPTUsageMonitor.enabled = false
        gptUsage.stop()
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
        else if let why = CodeHooks.blockedReason() { Permissions.alert(tr("已连接，但 Claude Code 的设置不让它运行", "Connected, but Claude Code's settings block it"), why) }
    }

    /// The backup is made only the first time (CodeHooks.install keeps the file as it was before KIKUmap).
    static var codeHooksSteps: String {
        tr("""
            KIKUmap 会在 ~/.claude/settings.json 里加几行（Claude Code 管它们叫 hook）。之后 Claude Code 会话每次收到你的消息、做完了、要你批准时，都会往 KIKUmap 的文件夹写一行，这样终端、VS Code 里的会话也会显示「在跑 / 未读」。

            • KIKUmap 第一次改这个文件前，会把原文件备份成 settings.json.before-claude-console（以后不再更新这份备份）
            • 只对之后新开的会话有用，已经开着的要重开
            • 随时可以在 设置 → 授权 里断开
            """, """
            KIKUmap adds a few lines to ~/.claude/settings.json (Claude Code calls them hooks). Then, each time a Claude Code session gets your message, finishes or needs your approval, it writes a line to KIKUmap's folder, so sessions in Terminal or VS Code show running / unread too.

            • Before KIKUmap first changes the file, it backs it up as settings.json.before-claude-console (that copy isn't updated later)
            • Only sessions started from now on report; restart the ones already open
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
            Permissions.alert(tr("没找到 ChatGPT 的数据", "Couldn't find ChatGPT's data"), text)
            return
        }
        onGPT?(true)
    }
    func disconnectGPT() { onGPT?(false) }

    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: tr("好", "OK"))       // (macOS's own would be in English: the app declares no Chinese)
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// Starts the app at login (a LaunchAgent, same as the installer's), shown as KIKUmap in System Settings.
enum LoginItem {
    static let label = "ninja.tang.claudeconsole"
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var id: String { Bundle.main.bundleIdentifier ?? ownBundleID }
    /// KIKUmap by its bundle id, not its path: macOS finds it wherever it was moved or renamed, and with two copies
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
            return tr("KIKUmap 现在是从磁盘映像（或临时位置）打开的，下次登录时就找不到它了。把 KIKUmap 拖进「应用程序」文件夹，从那里打开，再来打开这一项。",
                      "KIKUmap is running from the disk image (or a temporary place), which won't be there at the next login. Drag KIKUmap into Applications, open it from there, then turn this on.")
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
                      "Couldn't write to \(dir) (\(error.localizedDescription)). It may belong to root (installers run with sudo can leave it like that): in Terminal, run sudo chown $(whoami) ~/Library/LaunchAgents, then try again.")
        }
    }

    /// From a click (Settings, the intro, the To-do): saves it as your choice, or says why it couldn't be done.
    @MainActor @discardableResult
    static func choose(_ on: Bool) -> Bool {
        if let why = set(on) {
            Permissions.alert(on ? tr("没能设成登录时自动打开", "Couldn't set KIKUmap to open at login") : tr("没能取消登录时自动打开", "Couldn't stop KIKUmap opening at login"), why)
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
            return Todo(id: "login-move", title: tr("把 KIKUmap 拖进「应用程序」", "Move KIKUmap to Applications"),
                        impact: tr("KIKUmap 现在是从磁盘映像（或临时位置）打开的，重启后就不在了。把它拖进「应用程序」，从那里打开，就能设成登录时自动打开。",
                                   "KIKUmap is running from the disk image (or a temporary place), so it's gone after a restart. Drag it into Applications and open it from there; then it can open when you log in."),
                        action: nil)
        }
        return Todo(id: "login", title: tr("登录 Mac 时自动打开 KIKUmap", "Open KIKUmap when you log in"),
                    impact: tr("不开的话，重启 Mac 后 KIKUmap 不会自己打开。在你打开它之前：没有提醒，Claude App 和 ChatGPT 的对话不记时间，小组件也不更新。随时可以在 设置 → 通用 里改。",
                               "Otherwise KIKUmap doesn't come back after a restart. Until you open it, there are no alerts, chats in the Claude app and ChatGPT don't count time, and the widget doesn't update. Change it any time in Settings → General."),
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
        for g in Tag.groups { group.addItem(withTitle: tr(g.zh, TrKey(g.en))); group.lastItem?.representedObject = g.key }
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
            addItem(withTitle: tr(h.zh, TrKey(h.en)))
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
    /// A combination turned down while recording (KIKUmap's own menus use it; `ownText` says so under the field).
    var onRefused: ((UInt32, UInt32) -> Void)?
    private var recording = false { didSet { refresh(); onRecording?(recording) } }

    /// KIKUmap's own menu keys with two of ⌃ ⌥ ⌘ (the menus in App.swift), by the letter the shortcut's label shows: a
    /// shortcut for every app gets the keys before the menus, so as one of these it would stop that item working here.
    private static var own: [(key: String, mods: UInt32, item: String)] {
        let cc = UInt32(controlKey | cmdKey)
        return [("S", cc, tr("显示 / 隐藏左栏", "Show / Hide Left Column")), ("G", cc, tr("显示 / 隐藏标签", "Show / Hide Tags")),
                ("T", cc, tr("显示 / 隐藏时间轴", "Show / Hide Timeline")), ("H", UInt32(optionKey | cmdKey), tr("隐藏其他", "Hide Others"))]
    }
    /// The KIKUmap menu item this combination belongs to (nil: none).
    static func ownUse(code: UInt32, mods: UInt32) -> String? {
        let key = Prefs.keyName(code)
        return own.first { $0.key == key && $0.mods == mods }?.item
    }
    /// "KIKUmap uses ⌃⌘G (Show / Hide Tags)": why such a combination isn't taken, or isn't active (short: it's one line).
    static func ownText(code: UInt32, mods: UInt32) -> String? {
        ownUse(code: code, mods: mods).map { item in
            let k = Prefs.hotKeyLabel(code: code, mods: mods)
            return tr("KIKUmap 自己用 \(k)（\(item)）", "KIKUmap uses \(k) (\(item))")
        }
    }
    /// The longer why, for the tooltip.
    static func ownWhy(code: UInt32, mods: UInt32) -> String? {
        ownUse(code: code, mods: mods).map { item in
            let k = Prefs.hotKeyLabel(code: code, mods: mods)
            return tr("这个快捷键在任何 App 里都能用，所以它会比 KIKUmap 的菜单先收到按键：设成 \(k) 的话，KIKUmap 里的「\(item)」就按不出来了。换一个组合吧。",
                      "This shortcut works in any app, so it gets the keys before KIKUmap's menus. With \(k), \(item) would stop working in KIKUmap. Pick another combination.")
        }
    }

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
        // one of KIKUmap's own (⌃⌘G…): not taken, still recording, and the line under it says why
        if HotKeyField.ownUse(code: UInt32(e.keyCode), mods: mods) != nil {
            NSSound.beep(); onRefused?(UInt32(e.keyCode), mods); return true
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
    /// Settings → Access: its items, each with what to show now (in the page's order).
    private var permRows: [(row: AccessRowView, state: () -> Perm)] = []
    private var offButtons: [(NSButton, () -> Bool)] = []
    /// Settings → Access (kept: it plays its demos, and its height follows its items).
    private var accessPage: AccessPage?
    /// A row's state: its status text, whether it's working, the button's title (nil: as made) and whether it can
    /// be clicked, and a longer reason on hover. `notNeeded`: Accessibility isn't of use on this Mac (no asterisk then).
    private struct Perm { var text: String; var on: Bool; var button: String? = nil; var enabled: Bool; var why: String? = nil; var notNeeded = false }
    private var tagStack: NSStackView?
    /// The tags as the Tags page shows them, a name saved from its field included (`tagsChanged` fills it again when the
    /// map's differ).
    private var shownTags: [Tag]?
    /// The height of the scroll view the tag rows are in.
    private var tagListHeight: NSLayoutConstraint?
    /// The list is to be filled again once a tag's name is no longer being typed in it.
    private var tagsWaiting = false
    /// The list is being filled: what that sets off (a name field among the old rows ending its editing) doesn't fill it
    /// again inside itself, which would list every tag twice.
    private var fillingTags = false
    private weak var loginBox: NSButton?
    private var lastTab = 0
    private weak var hotKeyField: HotKeyField?
    /// Settings → Shortcuts (kept: it plays its demos and is rebuilt when the shortcut changes).
    private var shortcutsPage: ShortcutsPage?

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
        // tags are made, renamed and deleted on the map and the tag shelf too
        store.observe { [weak self] in self?.tagsChanged() }
    }

    func show(tab: Int? = nil) {
        if window == nil { build() } else { tagsChanged() }
        if let t = tab, let tc = window?.contentViewController as? NSTabViewController { tc.selectedTabViewItemIndex = t }
        Front.activate()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    /// Language changed: rebuild in place.
    /// Closed: built again for the next time, not shown. Open: in the old one's place among the windows (from the
    /// intro, behind it), its statuses filled in at once.
    func rebuild() {
        guard let w = window else { return }
        let shown = w.isVisible, key = w.isKeyWindow
        hotKeyField?.stop()
        w.makeFirstResponder(nil)           // what's being typed is saved first, not lost with the old window
        lastTab = (w.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex ?? 0
        let frame = w.frame
        w.delegate = nil
        window = nil
        build()
        window?.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))
        (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = lastTab
        if shown {
            window?.order(.above, relativeTo: w.windowNumber)
            if key { window?.makeKey() }
            startPolling()
        } else {
            timer?.invalidate(); timer = nil
        }
        w.orderOut(nil)
    }

    /// Closed: what's being typed is saved, as Return would (a tag's name: the Tags list then follows the map again).
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil; hotKeyField?.stop(); window?.makeFirstResponder(nil) }

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
        permRows = []; offButtons = []; accessPage = nil
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
        add(page(colorsPage()), tr("配色", "Colors"), "paintpalette")
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

    private func page(_ content: NSView) -> NSViewController { SettingsPage(content) }

    /// The page showing `v` takes the height its content needs now (a tag added or removed, a note that got longer or
    /// shorter); the window follows.
    private func refit(_ v: NSView) {
        let pages = (window?.contentViewController as? NSTabViewController)?.tabViewItems.compactMap { $0.viewController as? SettingsPage } ?? []
        pages.first { v.isDescendant(of: $0.content) }?.fit()
    }

    /// The width of a grid's second column: the page's 504 less the names' 140 and the 14 between. A label there wraps
    /// at this width; made for a wider one, its height is worked out for room it doesn't get and its last line is lost.
    static let fieldWidth: CGFloat = 350

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
        // the labels' column one width, so the controls start in the same place on every page and in either language
        // (left to itself, the column takes whatever room the controls leave, which differs with the language)
        g.column(at: 0).width = 140
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
        let lang = popup(langs.map { $0 == .system ? tr("跟随系统", "System") : (Lang(rawValue: $0.rawValue)?.name ?? $0.rawValue) },
                         selected: langs.firstIndex(of: Prefs.language) ?? 0) { [weak self] i in
            Prefs.language = langs[i]
            self?.onLanguage?()
        }
        let looks = Prefs.Appearance.allCases
        let look = NSSegmentedControl(labels: [tr("跟随系统", "System"), tr("浅色", "Light"), tr("深色", "Dark")],
                                      trackingMode: .selectOne, target: nil, action: nil)
        let lookHandler = ClosureTarget { [weak look] in if let l = look { Prefs.appearance = looks[l.selectedSegment] } }
        look.target = lookHandler; look.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(look, "h", lookHandler, .OBJC_ASSOCIATION_RETAIN)
        let lookNote = label("", small: true, width: SettingsWindow.fieldWidth)
        // the choice as saved now (the ☾ / ☀︎ button changes it too); a color set that's always dark or light decides
        // instead, so then it can't be made here, and the line under it says why
        func showLook() {
            look.selectedSegment = looks.firstIndex(of: Prefs.appearance) ?? 0
            look.isEnabled = Theme.palette.mode == .both
            lookNote.stringValue = SettingsWindow.lookNote(Theme.palette.mode)
        }
        showLook()

        let login = check(tr("登录时自动打开（只在菜单栏）", "Open at login (menu bar only)"), LoginItem.enabled) { [weak self] on in
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
            [NSGridCell.emptyContentView, lookNote],
            [label(tr("启动", "Startup"), width: 140), login],
            [NSGridCell.emptyContentView, NSStackView(views: [intro, data])],
        ])
        let tokens = [Prefs.appearanceChanged, Theme.paletteChanged].map { name in
            ObserverToken(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { showLook(); self?.refit(lookNote) }
            })
        }
        objc_setAssociatedObject(g, "lookTokens", tokens, .OBJC_ASSOCIATION_RETAIN)
        return g
    }

    /// Under Appearance: the ☾ / ☀︎ button switches too; with a color set that's always dark (or light), that the set
    /// decides, and where to change it.
    static func lookNote(_ mode: Palette.Mode) -> String {
        switch mode {
        case .both: return tr("导图顶栏的 ☾ / ☀︎ 按钮也能随时切换浅色 / 深色。", "The ☾ / ☀︎ button at the top of the map also switches light / dark any time.")
        case .dark: return tr("现在的配色一直是深色，这里和导图顶栏的 ☾ / ☀︎ 按钮都换不了。要切换浅色 / 深色，先在「配色」里换一套。",
                              "The color set in use is always dark, so neither this nor the ☾ / ☀︎ button on the map changes it. To switch, pick another set in Colors.")
        case .light: return tr("现在的配色一直是浅色，这里和导图顶栏的 ☾ / ☀︎ 按钮都换不了。要切换浅色 / 深色，先在「配色」里换一套。",
                               "The color set in use is always light, so neither this nor the ☾ / ☀︎ button on the map changes it. To switch, pick another set in Colors.")
        }
    }
    /// The same, short, under the intro's Appearance (one line).
    static func lookNoteShort(_ mode: Palette.Mode) -> String {
        mode == .light ? tr("现在的配色一直是浅色（设置 → 配色）", "The color set in use is always light (Settings → Colors)")
                       : tr("现在的配色一直是深色（设置 → 配色）", "The color set in use is always dark (Settings → Colors)")
    }

    /// The custom set in the Colors menu: "Custom (from Classic)".
    static var customName: String {
        let base = Palette.preset(Palette.customBase).map { tr($0.zh, TrKey($0.en)) } ?? ""
        return tr("自定义（基于「\(base)」）", "Custom (from \(base))")
    }

    /// Tests answer the question below themselves (nil: Settings asks).
    var answerReplaceCustom: (() -> Bool)?
    /// A color changed in a preset starts a new custom set, which replaces the one saved (only one is kept): asked
    /// first, on Settings. `done(true)`: replace it.
    private func confirmReplaceCustom(_ done: @escaping (Bool) -> Void) {
        if let answer = answerReplaceCustom { done(answer()); return }
        let from = Palette.preset(Theme.paletteKey).map { tr($0.zh, TrKey($0.en)) } ?? ""
        let base = Palette.preset(Palette.customBase).map { tr($0.zh, TrKey($0.en)) } ?? ""
        let a = NSAlert()
        a.messageText = tr("替换存着的自定义配色？", "Replace your saved custom colors?")
        a.informativeText = tr("在「\(from)」里改颜色，会从它新建一套自定义配色，替换掉你存着的那套（基于「\(base)」）：只能存一套。想用回存着的那套：点「取消」，再在「配色」里选「自定义」。",
                               "Changing a color in \(from) starts a new custom set from it. It replaces the custom set you saved (from \(base)), since only one is kept. To use the saved one instead, click Cancel and choose Custom under Color set.")
        a.addButton(withTitle: tr("替换", "Replace")).hasDestructiveAction = true
        a.addButton(withTitle: tr("取消", "Cancel"))
        if let w = window, w.isVisible {
            a.beginSheetModal(for: w) { done($0 == .alertFirstButtonReturn) }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            done(a.runModal() == .alertFirstButtonReturn)
        }
    }

    /// Settings → Colors: a color set, and each of its colors by hand (then it's "Custom").
    private func colorsPage() -> NSView {
        var keys: [String] = [], wells: [(NSColorWell, NSColorWell)] = []
        var lightHead: NSTextField?, darkHead: NSTextField?
        let pop = ClosurePopUp(items: []) { _ in }
        let note = label("", small: true, width: SettingsWindow.fieldWidth)
        let reset = button(tr("恢复预设", "Reset to preset")) {
            guard let pr = Palette.preset(Palette.customBase) else { return }
            Theme.setPalette(pr.palette, key: pr.key)
        }
        func swatches(_ p: Palette) -> NSImage {
            let dark = p.mode == .dark || (p.mode == .both && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let cs = [p.bg, p.ink, p.pick, p.running, p.unread].map { Theme.rgb(dark ? $0.dark : $0.light) }
            return NSImage(size: NSSize(width: 64, height: 12), flipped: false) { _ in
                for (i, c) in cs.enumerated() {
                    let r = NSRect(x: CGFloat(i) * 13 + 0.5, y: 0.5, width: 11, height: 11)
                    c.setFill(); NSBezierPath(ovalIn: r).fill()
                    NSColor.separatorColor.setStroke(); NSBezierPath(ovalIn: r).stroke()
                }
                return true
            }
        }
        // the page as the color set in use says: the menu, the wells, which column applies, the note
        func refresh() {
            let p = Theme.palette, key = Theme.paletteKey
            // the custom set stays in the menu while a preset is tried, to go back to
            let custom = key == "custom" ? p : Palette.savedCustom()
            keys = Palette.presets.map(\.key) + (custom != nil ? ["custom"] : [])
            pop.removeAllItems()
            for k in keys {
                let pr = Palette.preset(k)
                pop.addItem(withTitle: pr.map { tr($0.zh, TrKey($0.en)) } ?? SettingsWindow.customName)
                pop.lastItem?.image = swatches(pr?.palette ?? custom ?? p)
            }
            pop.selectItem(at: keys.firstIndex(of: key) ?? 0)
            // each well shows the color drawn: a set with one look has the same in both columns
            for (i, part) in Palette.parts.enumerated() where i < wells.count {
                let c = p[keyPath: part.key]
                wells[i].0.color = Theme.rgb(p.mode == .dark ? c.dark : c.light); wells[i].0.isEnabled = p.mode != .dark
                wells[i].1.color = Theme.rgb(p.mode == .light ? c.light : c.dark); wells[i].1.isEnabled = p.mode != .light
            }
            lightHead?.textColor = p.mode == .dark ? .tertiaryLabelColor : .secondaryLabelColor
            darkHead?.textColor = p.mode == .light ? .tertiaryLabelColor : .secondaryLabelColor
            note.stringValue = (p.mode == .dark ? tr("这套配色一直是深色，不跟着系统和 ☾ / ☀︎ 按钮变。", "This set is always dark, whatever the Mac or the ☾ / ☀︎ button says.")
                : p.mode == .light ? tr("这套配色一直是浅色，不跟着系统和 ☾ / ☀︎ 按钮变。", "This set is always light, whatever the Mac or the ☾ / ☀︎ button says.")
                : tr("浅色和深色各一套，跟着系统或 ☾ / ☀︎ 按钮切换。", "One look for light, one for dark: it follows the Mac or the ☾ / ☀︎ button."))
                + tr("\n导图窗口、统计、引导页、菜单栏图标和「快捷键」里的演示都用这些颜色；设置的其余部分和桌面小组件不变。改了任何一个颜色，就成了「自定义」。",
                     "\nThe map window, Statistics, the intro, the menu-bar icon and the Shortcuts demos use these colors; the rest of Settings and the desktop widget don't. Change any color and the set becomes Custom.")
            reset.isHidden = key != "custom"
        }
        // a preset (the custom set it came from stays saved, and in the menu), or the custom set again
        pop.onPick = { i in
            guard i < keys.count else { return }
            if let pr = Palette.preset(keys[i]) { Theme.setPalette(pr.palette, key: pr.key) }
            else if Theme.paletteKey != "custom", let c = Palette.savedCustom() { Theme.setPalette(c, key: "custom") }
        }
        // one color changed by hand: the rest of the set stays; the fills follow the background and text. In a preset,
        // it starts a new custom set from it, which replaces the one saved: asked first (only one is kept)
        var asking = false
        let ask: (@escaping (Bool) -> Void) -> Void = { [weak self] done in self?.confirmReplaceCustom(done) }
        func change(_ part: Int, dark: Bool, _ w: NSColorWell) {
            guard !asking else { return }
            func hex() -> UInt32? {
                guard let c = w.color.usingColorSpace(.sRGB) else { return nil }
                return UInt32((c.redComponent * 255).rounded()) << 16 | UInt32((c.greenComponent * 255).rounded()) << 8 | UInt32((c.blueComponent * 255).rounded())
            }
            func apply() {
                guard let h = hex() else { return }
                let p = Theme.palette.with(Palette.parts[part].key, h, dark: dark)
                if Theme.paletteKey != "custom" { Palette.customBase = Theme.paletteKey }
                Theme.setPalette(p, key: "custom")
            }
            guard Theme.paletteKey != "custom", let saved = Palette.savedCustom(), saved != Theme.palette else { apply(); return }
            // (the color panel goes on sending changes while this is asked: the last one counts)
            asking = true
            ask { [weak w] ok in
                asking = false
                // Cancel: the well as it was, and let go of the color panel if it's the one being picked in
                if ok { apply() } else { if w?.isActive == true { w?.deactivate() }; refresh() }
            }
        }
        func well(_ part: Int, dark: Bool) -> NSColorWell {
            let w = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 24))
            w.widthAnchor.constraint(equalToConstant: 44).isActive = true
            w.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let h = ClosureTarget { [weak w] in if let w = w { change(part, dark: dark, w) } }
            w.target = h; w.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(w, "h", h, .OBJC_ASSOCIATION_RETAIN)
            w.setAccessibilityLabel(tr(Palette.parts[part].zh, TrKey(Palette.parts[part].en)) + " · " + (dark ? tr("深色", "Dark") : tr("浅色", "Light")))
            return w
        }
        // a table: one row per part, the light color in one column and the dark one in the next, each under its heading
        func head(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = .systemFont(ofSize: 11.5, weight: .medium); t.textColor = .secondaryLabelColor; t.alignment = .center
            t.setContentCompressionResistancePriority(.required, for: .horizontal)     // a longer word widens its column
            return t
        }
        lightHead = head(tr("浅色", "Light")); darkHead = head(tr("深色", "Dark"))
        var rows: [[NSView]] = [[NSGridCell.emptyContentView, lightHead!, darkHead!]]
        for (i, part) in Palette.parts.enumerated() {
            let pair = (well(i, dark: false), well(i, dark: true))
            wells.append(pair)
            rows.append([label(tr(part.zh, TrKey(part.en)), width: 140), pair.0, pair.1])
        }
        let table = NSGridView(views: rows)
        table.rowSpacing = 10; table.columnSpacing = 14
        table.column(at: 2).leadingPadding = 10        // a little air between the two columns
        table.column(at: 0).xPlacement = .trailing; table.column(at: 0).width = 140
        // as wide as a well: the wells start where the menu above and the note below do
        // (wider only where a language's word for light or dark is longer than a well)
        let colW = max(44, ceil(max(lightHead!.fittingSize.width, darkHead!.fittingSize.width)))
        for c in 1...2 { table.column(at: c).xPlacement = .center; table.column(at: c).width = colW }
        table.rowAlignment = .none
        for r in 0..<table.numberOfRows { table.row(at: r).yPlacement = .center }
        table.row(at: 0).bottomPadding = -2
        table.setContentHuggingPriority(.required, for: .vertical)
        let g = vstack([grid([[label(tr("配色", "Color set"), width: 140), pop]]), table,
                        grid([[NSGridCell.emptyContentView, note], [NSGridCell.emptyContentView, reset]])], spacing: 16)
        refresh()
        // a change from anywhere (a preset, a well, Reset, another window): the page follows, at the height its note needs
        let token = NotificationCenter.default.addObserver(forName: Theme.paletteChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { refresh(); self?.refit(note) }
        }
        objc_setAssociatedObject(g, "paletteToken", ObserverToken(token), .OBJC_ASSOCIATION_RETAIN)
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
        let quietGPT = check(tr("正在看 ChatGPT App 时不响", "Stay quiet while the ChatGPT app is in front"), Prefs.quietWhenGPTFront) { Prefs.quietWhenGPTFront = $0 }

        // the chat's name, read aloud after the sound
        let speak = check(tr("响完再念出是哪个对话", "Then say which chat it was"), Prefs.speak) { Prefs.speak = $0 }
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { v in ["en", "zh", "ja", "ko", "es", "pt", "de", "fr"].contains { v.language.hasPrefix($0) } }
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
        func grade(_ v: AVSpeechSynthesisVoice) -> String {
            switch v.quality { case .premium: return " ★★"; case .enhanced: return " ★"; default: return "" }
        }
        let voicePop = popup([tr("自动（按文字的语言）", "Automatic (matches the language)")] + voices.map { "\($0.name) · \($0.language)\(grade($0))" },
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
            [label(tr("等你确认", "Waiting for you"), width: 140), input],
            [NSGridCell.emptyContentView, quiet],
            [NSGridCell.emptyContentView, quietGPT],
            [NSGridCell.emptyContentView, speak],
            [label(tr("念的内容", "What it says"), width: 140), NSStackView(views: [doneText, label(tr("做完了", "finished"), small: true, width: 120)])],
            [NSGridCell.emptyContentView, NSStackView(views: [inputText, label(tr("等你确认", "waiting for you"), small: true, width: 120)])],
            [label(tr("声音", "Voice"), width: 140), voicePop],
            [label(tr("语速", "Speed"), width: 140), NSStackView(views: [ratePop, test])],
        ])
        let note = label(tr("Claude App 的对话：KIKUmap 从 Claude 窗口里的对话列表看到它们做完，所以 Claude 的窗口要开在你正在用的桌面上。开了「完全磁盘访问」（设置 → 授权）的话，Claude 问「允许吗？」、等你回答、Cowork 任务做完时，窗口关着也会提醒（普通对话回复完，Claude 不发通知）。ChatGPT 的普通对话：从 ChatGPT 窗口里的对话列表看到它们做完，所以窗口要露出一部分。Claude Code 会话：先在 设置 → 授权 里连接 Claude Code。",
                            "Claude app chats: KIKUmap sees them finish in the chat list in Claude's window, so keep that window open on the desktop you're using. With Full Disk Access (Settings → Access), you're also told when Claude asks \"Allow this?\", waits for your answer, or finishes a Cowork task, even with its window closed (Claude sends no notification when an ordinary chat's reply finishes). ChatGPT's ordinary chats: KIKUmap sees them finish in the chat list in ChatGPT's window, so let part of that window show. Claude Code sessions: connect Claude Code in Settings → Access first."), small: true)
        let voiceNote = label(tr("{name} 会换成对话名。名字会念出声，周围的人也听得到。想要更自然的声音：系统设置 → 辅助功能 → 朗读内容 → 系统嗓音 → 管理嗓音，下载一个高质量的嗓音，它在这里会带 ★。",
                                 "{name} becomes the chat's name. It's said out loud, so people nearby hear it too. For a more natural voice: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices, and download a Premium or Enhanced voice; it shows here with ★."), small: true)
        return vstack([g, voiceNote, note], spacing: 18)
    }

    /// The tabs, in order (build() adds them so).
    static let generalTab = 0, colorsTab = 1, notificationsTab = 2, accessTab = 3, shortcutsTab = 4, tagsTab = 5, exportTab = 6, aboutTab = 7
    static let links = (site: "https://tang1693.github.io/KIKUmap/", repo: "https://github.com/tang1693/KIKUmap",
                        issues: "https://github.com/tang1693/KIKUmap/issues", tip: "https://ko-fi.com/vegligi")

    private func about() -> NSView {
        func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let name = NSTextField(labelWithString: "KIKUmap")
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
        let tipNote = label(tr("KIKUmap 是免费的。如果它帮你省了时间，可以请我喝杯咖啡；点个 GitHub ⭐ 或者反馈问题也一样有帮助。",
                               "KIKUmap is free. If it saves you time, you can buy me a coffee; a GitHub star or a bug report helps just as much."), small: true)
        let fine = label(tr("个人独立开源项目，与 Anthropic 和 OpenAI 无关。MIT 协议。", "An independent open-source project, not affiliated with Anthropic or OpenAI. MIT License."), small: true)
        return vstack([top, by, story, links, tip, tipNote, fine], spacing: 14)
    }

    /// The Accessibility row's state on a Mac with neither the Claude app nor ChatGPT (or only the older ChatGPT app,
    /// whose window isn't read: `accessNotNeededOlderGPT`), and the ChatGPT row's when only Codex outside the app is
    /// read (the older ChatGPT app, or none). Short, as a row's state shares a line with its name and button: a longer
    /// one squeezes the name.
    static var accessNotNeeded: String { tr("用不上：这台 Mac 上没有 Claude App，也没有 ChatGPT", "Not needed: no Claude or ChatGPT app on this Mac") }
    static var accessNotNeededOlderGPT: String { tr("用不上：没有 Claude App，也没有新版 ChatGPT", "Not needed: no Claude app or current ChatGPT") }
    /// On hovering that one: why the older ChatGPT app doesn't count.
    static var accessNotNeededOlderGPTWhy: String {
        tr("这台 Mac 上是旧版 ChatGPT App，KIKUmap 不读它的窗口。辅助功能主要用来读 Claude App 和新版 ChatGPT（Codex 内核）的窗口。",
           "This Mac has the older ChatGPT app, whose window KIKUmap doesn't read. Accessibility is mainly for reading the windows of the Claude app and the current ChatGPT app (built on Codex).")
    }
    static func codexOnly(olderApp: Bool) -> String {
        olderApp ? tr("已开启 · 旧版 ChatGPT App：只读编辑器、终端里的 Codex", "On · older ChatGPT app: Codex in editors and terminal only")
                 : tr("已开启 · 没有 ChatGPT App，只读编辑器、终端里的 Codex", "On · no ChatGPT app: Codex in editors and terminal only")
    }

    /// Settings → Access: the items (AccessItem, in its order), each with its state now and what its button does,
    /// on the page that plays what each gets you (AccessPage); then the tip and the buttons that turn things off.
    private func access() -> NSView {
        let p = perms
        let on = tr("✓ 已开启", "✓ On"), off = tr("未开启", "Off")
        // each item's state now, by its id
        let states: [String: () -> Perm] = [
            "accessibility": {
                let trusted = AXIsProcessTrusted()
                if !trusted && !p.accessNeeded {
                    // (only the older ChatGPT app here: that's said, not that there's no ChatGPT)
                    return GPTWatcher.oldAppOnly
                        ? Perm(text: SettingsWindow.accessNotNeededOlderGPT, on: false, enabled: true, why: SettingsWindow.accessNotNeededOlderGPTWhy, notNeeded: true)
                        : Perm(text: SettingsWindow.accessNotNeeded, on: false, enabled: true, notNeeded: true)
                }
                return Perm(text: trusted ? on : off, on: trusted, enabled: !trusted)
            },
            "fullDisk": {
                guard p.fullDisk else {
                    // opened from here already: switched on in System Settings, it only counts once KIKUmap reopens
                    return p.fullDiskAsked ? Perm(text: tr("未开启 · 开了的话要重新打开 KIKUmap", "Off · switched it on? Reopen KIKUmap"), on: false, enabled: true,
                                                  why: tr("「完全磁盘访问」要等 KIKUmap 重新打开才生效。点「打开设置」，可以让它退出并重新打开。", "Full Disk Access only counts once KIKUmap reopens. Click Open Settings to quit and reopen it."))
                                           : Perm(text: off, on: false, enabled: true)
                }
                if p.notifications.status == .unreadable {
                    return Perm(text: tr("已开启 · 读不了通知中心", "On · can't read Notification Center"), on: false, enabled: false,
                                why: tr("读不了 macOS 的通知记录（可能是系统更新改了它）：", "Notification Center's records can't be read (maybe a macOS update changed them): ") + (p.notifications.problem ?? ""))
                }
                return Perm(text: on, on: true, enabled: false)
            },
            "claudeCode": {
                guard p.codeHooks else { return Perm(text: off, on: false, enabled: true) }
                if let why = CodeHooks.blockedReason() { return Perm(text: tr("已连接 · 但被 Claude Code 关掉了", "Connected · turned off in Claude Code"), on: false, enabled: false, why: why) }
                return Perm(text: on, on: true, enabled: false)
            },
            "chatGPT": {
                guard GPTWatcher.enabled else { return Perm(text: off, on: false, enabled: true) }
                guard GPTWatcher.available else { return Perm(text: tr("已开启 · 还没找到它的数据", "On · its data isn't there yet"), on: false, enabled: true) }
                if let e = p.gptError?() { return Perm(text: tr("已开启 · 读不了", "On · can't read it"), on: false, enabled: false, why: e) }
                if !GPTWatcher.installed && GPTWatcher.oldAppOnly {
                    return Perm(text: SettingsWindow.codexOnly(olderApp: true), on: true, enabled: false,
                                why: tr("更新到新版 ChatGPT App（Codex 内核），才能看到在它里面置顶的对话。", "Update to the current ChatGPT app (built on Codex) to see the chats you pin there."))
                }
                if !GPTWatcher.installed { return Perm(text: SettingsWindow.codexOnly(olderApp: false), on: true, enabled: false) }
                return Perm(text: on, on: true, enabled: false)
            },
            "usage": {
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
                    case .limited: short = tr("暂停查询中", "paused for a while")
                    case .locked: short = tr("钥匙串锁着", "Keychain locked")
                    case .refused: short = tr("被拒绝了", "refused")
                    case .offline: short = tr("连不上", "can't reach it")
                    case .keychain: short = tr("钥匙串出错", "Keychain error")
                    default: short = tr("暂时查不到", "can't get it right now")       // (an answer it can't read, as ChatGPT's)
                    }
                    return Perm(text: tr("已开启 · ", "On · ") + short, on: false, button: tr("重新读取", "Read again"), enabled: true, why: p.usage.hint + who)
                }
            },
            "gptUsage": {
                guard GPTUsageMonitor.enabled else { return Perm(text: off, on: false, button: tr("连接", "Connect"), enabled: true) }
                switch p.gptUsage.status {
                case .ok: return Perm(text: on, on: true, button: tr("连接", "Connect"), enabled: false)
                case .unknown: return Perm(text: tr("已开启 · 读取中…", "On · reading…"), on: true, button: tr("连接", "Connect"), enabled: false)
                default:
                    let short: String
                    switch p.gptUsage.status {
                    case .noLogin: short = tr("Codex 未登录", "Codex not signed in")
                    case .expired: short = tr("登录过期了", "sign-in expired")
                    case .limited: short = tr("暂停查询中", "paused for a while")
                    case .refused: short = tr("被拒绝了", "refused")
                    case .offline: short = tr("连不上", "can't reach it")
                    default: short = tr("暂时查不到", "can't get it right now")
                    }
                    return Perm(text: tr("已开启 · ", "On · ") + short, on: false, button: tr("重新读取", "Read again"), enabled: true, why: p.gptUsage.hint)
                }
            },
        ]
        // what each item's button does: each says what it does before anything happens (an alert, or the row itself)
        let runs: [String: () -> Void] = [
            "accessibility": { p.openAccessibility() },
            "fullDisk": { p.openFullDisk() },
            "claudeCode": { p.connectCode() },
            "chatGPT": { [weak self] in p.connectGPT(); self?.refreshPerms() },
            "usage": { p.connectUsage() },
            "gptUsage": { [weak self] in p.connectGPTUsage(); self?.refreshPerms() },
        ]
        let items = AccessItem.all
        let tip = label(tr("这里显示未开启，系统设置里却开着？先退出并重新打开 KIKUmap。还不行（比如重装后）：在系统设置的列表里选中 KIKUmap，点 − 删掉，再加一次。",
                           "Off here but on in System Settings? Quit and reopen KIKUmap. Still off (after reinstalling, say)? Select KIKUmap in that list, click − to remove it, then add it again."),
                        small: true, width: 504)
        let diag = button(tr("诊断报告", "Diagnostic report")) { [weak self] in self?.onDiagnose?() }
        diag.toolTip = tr("写一份 kikumap-check.txt：哪些正常、哪些不行；ChatGPT 开着的话，再写一份 chatgpt-window-时间.txt（它窗口的结构）。它们不该含对话标题、内容和密码；发给帮你看的人之前，可以先打开看一眼。",
                          "Writes kikumap-check.txt: what works and what doesn't; with ChatGPT open, also chatgpt-window-time.txt (how its window is laid out). They're meant to leave out chat titles, messages and passwords; open them to check before you send them to whoever helps.")
        let unhook = button(tr("断开 Claude Code", "Disconnect Claude Code")) { [weak self] in p.disconnectCode(); self?.refreshPerms() }
        let gptOff = button(tr("断开 ChatGPT", "Disconnect ChatGPT")) { [weak self] in p.disconnectGPT(); self?.refreshPerms() }
        let usageOff = button(tr("关闭 Claude 用量", "Turn off Claude usage")) { [weak self] in p.disconnectUsage(); self?.refreshPerms() }
        let gptUsageOff = button(tr("关闭 ChatGPT 用量", "Turn off ChatGPT usage")) { [weak self] in p.disconnectGPTUsage(); self?.refreshPerms() }
        offButtons = [(unhook, { p.codeHooks }), (gptOff, { GPTWatcher.enabled }), (usageOff, { UsageMonitor.enabled }), (gptUsageOff, { GPTUsageMonitor.enabled })]
        // (two lines of buttons, in the items' order: one is too wide for the window)
        let page = AccessPage(items.map { item in (item, runs[item.id] ?? {}) },
                              below: [tip, NSStackView(views: [diag, unhook, gptOff]), NSStackView(views: [usageOff, gptUsageOff])])
        accessPage = page
        permRows = page.rows.map { r in (r, states[r.item.id] ?? { Perm(text: "", on: false, enabled: false) }) }
        return page.view
    }

    private func refreshPerms() {
        var changed = false, notNeeded = false
        for (row, state) in permRows {
            let st = state()
            if row.item.need == .required { notNeeded = st.notNeeded }
            if row.show(st.text, on: st.on, why: st.why, button: st.button, enabled: st.enabled) { changed = true }
        }
        // nothing required on a Mac where Accessibility is of no use: no asterisk, no legend
        if let page = accessPage, page.legend.isHidden != notNeeded { page.setRequired(!notNeeded); changed = true }
        if changed { fitAccess() }
        for (b, on) in offButtons { b.isEnabled = on() }
        // Start at login can change elsewhere too (the intro, the To-do, the installer)
        loginBox?.state = LoginItem.enabled ? .on : .off
    }

    /// Settings → Access as tall as its items need now (a long state takes a line of its own): its tab, and the
    /// window while it shows it, its top left where it was.
    private func fitAccess() {
        guard let page = accessPage, let tc = window?.contentViewController as? NSTabViewController,
              tc.tabViewItems.indices.contains(Self.accessTab), let vc = tc.tabViewItems[Self.accessTab].viewController else { return }
        let h = page.view.fittingSize.height + 46
        guard abs(vc.preferredContentSize.height - h) > 0.5 else { return }
        vc.preferredContentSize = NSSize(width: 560, height: h)
        guard tc.selectedTabViewItemIndex == Self.accessTab, let w = window else { return }
        let top = NSPoint(x: w.frame.minX, y: w.frame.maxY)
        w.setContentSize(NSSize(width: 560, height: h))
        w.setFrameTopLeftPoint(top)
    }

    private func shortcuts() -> NSView {
        let field = HotKeyField()
        hotKeyField = field
        field.setAccessibilityLabel(tr("显示 / 隐藏导图的快捷键", "Shortcut to show or hide the map"))
        // what the shortcut does right now, in one line under it
        let status = label("", small: true, width: 350)
        // two lines where a language needs them (the full text is in its tool tip too)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        status.cell?.truncatesLastVisibleLine = true
        /// `refused`: a combination of KIKUmap's own just pressed while recording.
        func refresh(recording: Bool = false, refused: (code: UInt32, mods: UInt32)? = nil) {
            // the one saved is KIKUmap's own (an older build took it): not active, and why
            let saved = (Prefs.hotKeyCode, Prefs.hotKeyMods)
            let notActive = HotKeyField.ownText(code: saved.0, mods: saved.1).map { tr("没有生效：", "Not active: ") + $0 + tr("。", ".") }
                ?? tr("没有生效：macOS 没接受这个组合，换一个试试。", "Not active: macOS didn't accept it. Try another combination.")
            status.stringValue = refused.flatMap { HotKeyField.ownText(code: $0.code, mods: $0.mods) }.map { $0 + tr("，换一个。", ": press another.") }
                ?? (recording ? tr("录制中：按下新组合（要有 ⌃ ⌥ ⌘ 里的两个），esc 取消。", "Recording: press the new keys (two of ⌃ ⌥ ⌘); esc cancels.")
                : !Prefs.hotKeyEnabled ? tr("已关闭：勾上「启用」就能在任何 App 里用。", "Off: check Enabled to use it from any app.")
                : Prefs.hotKeyError != nil ? notActive
                : tr("在任何 App 里按它，就能显示或隐藏导图。", "Press it in any app to show or hide the map."))
            status.textColor = refused != nil || (Prefs.hotKeyEnabled && Prefs.hotKeyError != nil && !recording) ? .labelColor : .secondaryLabelColor
            if let r = refused { status.toolTip = HotKeyField.ownWhy(code: r.code, mods: r.mods); return }
            status.toolTip = Prefs.hotKeyError.map { e in
                HotKeyField.ownWhy(code: saved.0, mods: saved.1)
                    ?? tr("macOS 没接受这个组合（错误 \(e)）：可能别的 App 或系统快捷键已经在用它。", "macOS didn't accept it (error \(e)); another app or a system shortcut may already use this combination.")
            } ?? status.stringValue
        }
        field.onChange = { [weak self] code, mods in
            Prefs.hotKeyCode = code; Prefs.hotKeyMods = mods
            self?.onHotKey?()
            refresh(); self?.shortcutsPage?.rebuild()
        }
        field.onRecording = { [weak self] on in self?.onSuspendHotKey?(on); refresh(recording: on) }
        field.onRefused = { code, mods in refresh(recording: true, refused: (code, mods)) }
        // (a click on these doesn't take the keys from the field: a shortcut being recorded ends first, or the one
        // registered again here would take the very keys pressed next to record it)
        let on = check(tr("启用", "Enabled"), Prefs.hotKeyEnabled) { [weak self] v in
            field.stop()
            Prefs.hotKeyEnabled = v; self?.onHotKey?()
            refresh(); self?.shortcutsPage?.rebuild()
        }
        let reset = button(tr("恢复 ⌃⌥C", "Reset to ⌃⌥C")) { [weak self] in
            field.stop()
            Prefs.hotKeyCode = UInt32(kVK_ANSI_C); Prefs.hotKeyMods = UInt32(controlKey | optionKey)
            field.refresh(); self?.onHotKey?()
            refresh(); self?.shortcutsPage?.rebuild()
        }
        let g = grid([[label(tr("显示 / 隐藏导图", "Show / hide the map"), width: 140), NSStackView(views: [field, on, reset])],
                      [NSGridCell.emptyContentView, status]])
        g.rowSpacing = 6
        refresh()
        // every shortcut by where it works, with a stage that acts each one out
        let page = ShortcutsPage(top: g)
        shortcutsPage = page
        return page.view
    }

    private func archivePage() -> NSView {
        let intro = label(tr("""
        选几个主题，把里面的 Claude 对话一次导出：每个对话一个文件夹，里面有 memory.md（Claude 写的交接总结）、提示词、完整对话、所有 artifact 和附件。可以设成自动更新。以后可以一键导入另一个 Claude 账号，新对话会带着总结和文件接着做。
        """, """
        Pick topics and export their Claude chats in one go. Each chat gets a folder with memory.md (a hand-off summary written by Claude), the prompts, the whole chat, and every artifact and attachment. Exports can keep themselves up to date. Later you can import them into another Claude account in one go, and the new chats carry on with the summary and files.
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
        let path = label(Archive.folder.path, small: true, width: SettingsWindow.fieldWidth)
        archiveFolderLabel = path
        let status = label("", small: true, width: SettingsWindow.fieldWidth)
        archiveStatus = status
        let tip = label(tr("也可以右键单个对话 →「让 Claude 写总结存档…」，先试一个。", "Or right-click one chat → \"Archive a summary…\" to try one first.")
                        + (Archive.asksNote.map { "\n" + $0 } ?? ""),
                        small: true, width: SettingsWindow.fieldWidth)
        let g = grid([
            [label(tr("导出", "Export"), width: 140), actions],
            [label(tr("文件夹", "Folder"), width: 140), path],
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
            archiveStatus?.stringValue = tr("正在处理：", "Working: ") + a.progress
        } else {
            let last = Archive.lastResult
            archiveStatus?.stringValue = last.isEmpty ? tr("还没导出过。", "Nothing exported yet.") : tr("上次：", "Last: ") + last
        }
        archiveButtons.forEach { $0.isEnabled = !a.busy }
        if let s = archiveStatus { refit(s) }         // a longer status, or folder, takes a line more
    }

    private func tagsPage() -> NSView {
        let stack = vstack([], spacing: 8)
        tagStack = stack
        // the rows scroll once there are more than the screen has room for, so "＋ New tag" stays in sight under them
        let doc = FlippedStack()
        doc.addSubview(stack)
        let list = NSScrollView()
        list.drawsBackground = false; list.borderType = .noBorder
        list.hasVerticalScroller = true; list.autohidesScrollers = true
        list.documentView = doc
        list.widthAnchor.constraint(equalToConstant: 504).isActive = true
        tagListHeight = list.heightAnchor.constraint(equalToConstant: 0)
        tagListHeight?.isActive = true
        fillTags()
        let add = button(tr("＋ 新标签", "＋ New tag")) { [weak self] in
            guard let self = self else { return }
            let map = self.store.map
            if let n = TagPrompt.ask(color: map.nextTagColor(), window: self.window) {
                map.addTag(n.name, color: n.color, icon: n.icon, group: n.group)
                self.store.notify()
            }
        }
        let intro = label(tr("在跑和未读有自己的颜色（在「配色」里设）。其余的颜色留给你：给分支上色（右键主题 → 分支颜色），或者给对话和主题加标签（右键 → 标签），一个可以加好几个。",
                             "Running and unread have colors of their own (set them in Colors). The rest is yours: color a branch (right-click a topic → Branch color) or tag chats and topics (right-click → Tags), as many as you like."), small: true)
        let swatches = NSStackView(views: Theme.highlights.map { h in
            let v = NSImageView(image: Theme.swatch(h.color, size: 16)); v.toolTip = tr(h.zh, TrKey(h.en)); return v
        })
        swatches.spacing = 4
        return vstack([intro, swatches, list, add], spacing: 14)
    }

    /// The map's tags changed (made, renamed or deleted here, on the map or the tag shelf, or a step taken back): the
    /// list shows them as they are now. Not while a tag's name is being typed in it: once that's done.
    private func tagsChanged() {
        guard tagStack != nil, store.map.tags != shownTags else { return }
        guard typingTag else { fillTags(); return }
        guard !tagsWaiting else { return }
        tagsWaiting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.tagsWaiting = false; self?.tagsChanged() }
        }
    }

    /// A tag's name is being typed on the Tags page, not saved yet (filling the list again would throw it away; a
    /// field only clicked into has nothing to lose).
    private var typingTag: Bool {
        guard let stack = tagStack, let editor = window?.firstResponder as? NSText, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.isDescendant(of: stack) else { return false }
        return shownTags?.first { $0.id == field.identifier?.rawValue }?.name != editor.string
    }

    private func fillTags() {
        guard let stack = tagStack, !fillingTags else { return }
        fillingTags = true
        defer { fillingTags = false }
        // a name field among the rows ends its editing as they go (only clicked into: nothing to save); the rows are
        // made after that, once, from the tags as they are then
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let map = store.map
        shownTags = map.tags
        defer { fitTags() }
        if map.tags.isEmpty {
            stack.addArrangedSubview(label(tr("还没有标签。", "No tags yet."), small: true))
            return
        }
        for t in map.tags.sorted(by: { a, b in
            let order = Tag.groups.map(\.key)
            return (order.firstIndex(of: a.category) ?? 2) < (order.firstIndex(of: b.category) ?? 2)
        }) {
            let pop = ColorPopUp(selected: t.color)
            pop.onPick = { [weak self] c in map.updateTag(t.id, color: c); self?.store.notify() }
            weak var field: ClosureField?
            let name = ClosureField(string: t.name) { [weak self] s in
                guard let self = self, let i = self.shownTags?.firstIndex(where: { $0.id == t.id }), let was = self.shownTags?[i].name else { return }
                // as "＋ New tag" takes a name: without spaces round it, and not empty (emptied: the name it has stays)
                let new = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if new.isEmpty || new != s { field?.stringValue = new.isEmpty ? was : new }
                // nothing typed (only clicked into, or the list filled again under it): nothing to save, so a change
                // made elsewhere meanwhile (⌘Z on the map) isn't undone by the name the field still shows
                guard !new.isEmpty, new != was else { return }
                map.updateTag(t.id, name: new)
                // the list shows it already: not filled again for it, unless something else changed meanwhile
                self.shownTags?[i].name = new
                self.store.notify()
            }
            field = name
            name.widthAnchor.constraint(equalToConstant: 150).isActive = true
            name.identifier = NSUserInterfaceItemIdentifier(t.id)
            let group = NSPopUpButton(frame: .zero, pullsDown: false)
            for g in Tag.groups { group.addItem(withTitle: tr(g.zh, TrKey(g.en))); group.lastItem?.representedObject = g.key }
            group.selectItem(at: Tag.groups.firstIndex { $0.key == t.category } ?? 2)
            let pickGroup = ClosureTarget { [weak self, weak group] in
                guard let g = group?.selectedItem?.representedObject as? String else { return }
                map.updateTag(t.id, group: g); self?.store.notify()
            }
            group.target = pickGroup
            group.action = #selector(ClosureTarget.fire)
            objc_setAssociatedObject(group, "target", pickGroup, .OBJC_ASSOCIATION_RETAIN)
            let tint = Theme.highlight(t.color) ?? Theme.muted
            var iconButton: ClosureButton!
            iconButton = ClosureButton(title: "") { [weak self] in
                guard let b = iconButton else { return }
                IconPicker.show(relativeTo: b.bounds, of: b, selected: t.icon, tint: tint,
                                clear: t.icon == nil ? nil : (tr("不要图标", "No icon"), { map.updateTag(t.id, icon: .some(nil)); self?.store.notify() })) { name in
                    map.updateTag(t.id, icon: .some(name)); self?.store.notify()
                }
            }
            iconButton.image = t.icon.map { Icons.image($0, size: 16, color: tint) } ?? Theme.swatch(tint)
            iconButton.imagePosition = .imageOnly
            iconButton.toolTip = tr("换图标", "Change icon")
            iconButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
            let del = button(tr("删除", "Delete")) { [weak self] in
                map.deleteTag(t.id); self?.store.notify()
            }
            let row = NSStackView(views: [iconButton, pop, name, group, del])
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
    }

    /// The rows' scroll view as tall as the rows, up to what the screen has room for beside the rest of the page and
    /// the window's title bar; then the page takes its new height.
    private func fitTags() {
        guard let stack = tagStack, let doc = stack.superview, let list = doc.enclosingScrollView else { return }
        let h = ceil(stack.fittingSize.height)
        stack.frame = NSRect(x: 0, y: 0, width: max(stack.fittingSize.width, 1), height: h)
        doc.frame = stack.frame
        let screen = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        tagListHeight?.constant = min(h, max(160, screen - 320))
        refit(list)
    }
}

/// One Settings tab: its content with room round it. Each tab gets its own height (the window resizes when switching),
/// and `fit()` gives it again when the content changes.
final class SettingsPage: NSViewController {
    let content: NSView

    init(_ content: NSView) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
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
        view = v
        fit()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The height the content needs now (the window takes it while this tab shows, or when it's switched to).
    func fit() {
        let size = NSSize(width: 560, height: content.fittingSize.height + 46)
        if preferredContentSize != size { preferredContentSize = size }
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
    /// What a pick does (can be set after the items are made).
    var onPick: (Int) -> Void = { _ in }
    convenience init(items: [String], _ run: @escaping (Int) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items)
        onPick = run
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { onPick(indexOfSelectedItem) }
}

/// A notification observer that stops when this goes away (kept by the view it updates).
final class ObserverToken: NSObject {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
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
