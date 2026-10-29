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

    var fullDisk: Bool { notifications.recheck(); return notifications.status == .ok }
    var accessibility: Bool { AXIsProcessTrusted() }
    var usageOK: Bool { usage.status == .ok }

    static func openPane(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Full Disk Access has no system prompt: open the list and show the app in Finder to drag in.
    func openFullDisk() {
        Permissions.openPane("Privacy_AllFiles")
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        Permissions.openPane("Privacy_Accessibility")
        sidebar.attach()
    }

    /// Usage needs Claude Code's sign-in from the Keychain, so nothing is read until you agree here;
    /// only then does macOS ask. `explained`: the page you clicked on already said all of this.
    func connectUsage(explained: Bool = false) {
        if !explained && !UsageMonitor.enabled {
            let a = NSAlert()
            a.messageText = tr("显示用量和计划任务？", "Show usage and scheduled tasks?")
            a.informativeText = tr("""
                Kikumap 可以借用 Claude Code 存在这台 Mac 钥匙串里的登录，查你的套餐用量和计划任务，不用再登录一次。

                • 只读取，不修改、不保存这份登录
                • 只发给 api.anthropic.com，只用来查用量和计划任务
                • 随时可以在 设置 → 授权 里关掉

                Kikumap 和 Claude Code 用同一种方式读取它，所以 macOS 一般不会问。如果问了，选「始终允许」。
                """, """
                Kikumap can look up your plan usage and scheduled tasks by borrowing the sign-in Claude Code already keeps in this Mac's Keychain — no second login.

                • It only reads it: never changes or saves it
                • It's only sent to api.anthropic.com, to look up usage and scheduled tasks
                • You can turn it off any time in Settings → Access

                Kikumap reads it the same way Claude Code does, so macOS usually doesn't ask. If it does, choose "Always Allow".
                """)
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

    /// Adds the hooks to ~/.claude/settings.json (a backup of the old file is kept next to it).
    func connectCode() {
        if let err = CodeHooks.install() { Permissions.alert(tr("没能连接 Claude Code", "Couldn't connect Claude Code"), err) }
    }

    func disconnectCode() {
        if let err = CodeHooks.uninstall() { Permissions.alert(tr("没能断开 Claude Code", "Couldn't disconnect Claude Code"), err) }
    }

    /// ChatGPT threads (read-only, from ~/.codex): on / off.
    var onGPT: ((Bool) -> Void)?
    var gptOK: Bool { GPTWatcher.enabled && GPTWatcher.available }
    func connectGPT() {
        guard GPTWatcher.available else {
            Permissions.alert(tr("没找到 ChatGPT 的数据", "ChatGPT's data wasn't found"),
                              tr("装上新版 ChatGPT 桌面 App（Codex 内核）并用过一次，再来这里连接。", "Install the current ChatGPT desktop app (the one built on Codex), use it once, then connect here."))
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

/// Starts the app at login (a LaunchAgent, same as the installer's).
enum LoginItem {
    static let label = "ninja.tang.claudeconsole"
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var enabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func set(_ on: Bool) {
        if !on { try? FileManager.default.removeItem(at: url); return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--background"],
            "RunAtLoad": true,
        ]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? d.write(to: url)
        }
    }
}

/// Asks for a tag name and colour.
@MainActor
enum TagPrompt {
    static func ask(name: String = "", color: String, window: NSWindow?) -> (String, String)? {
        let a = NSAlert()
        a.messageText = tr("新标签", "New tag")
        a.informativeText = tr("一个对话或主题可以有多个标签。", "A chat or topic can have several tags.")
        a.addButton(withTitle: tr("好", "OK"))
        a.addButton(withTitle: tr("取消", "Cancel"))
        let field = NSTextField(string: name)
        field.placeholderString = tr("标签名，比如「等客户」", "Tag name, e.g. \"waiting on client\"")
        let pop = ColorPopUp(selected: color)
        let stack = NSStackView(views: [field, pop])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 58)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        a.accessoryView = stack
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let n = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : (n, pop.selectedKey)
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
        if recording { recording = false }
        return super.resignFirstResponder()
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
        // needs ⌃, ⌥ or ⌘ so it doesn't steal plain typing
        guard mods & UInt32(controlKey | optionKey | cmdKey) != 0 else { NSSound.beep(); return true }
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
    private var permRows: [(NSTextField, NSButton, () -> Bool)] = []
    private var tagStack: NSStackView?
    private var lastTab = 0

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
        lastTab = (w.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex ?? 0
        let frame = w.frame
        w.orderOut(nil)
        window = nil
        build()
        window?.setFrameTopLeftPoint(NSPoint(x: frame.minX, y: frame.maxY))
        (window?.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = lastTab
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPerms() }
        }
        refreshPerms()
    }

    // MARK: building

    private func build() {
        permRows = []
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

        let login = check(tr("登录时自动启动（只在菜单栏）", "Start at login (menu bar only)"), LoginItem.enabled) { on in LoginItem.set(on) }
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
        let note = label(tr("Claude App 的对话靠它自己的通知：请在 Claude App → 设置 → 通知 里打开「Response completions」。Claude Code 会话靠 设置 → 授权 里连接的 hook。",
                            "Chats in the Claude app rely on its own notifications: turn on \"Response completions\" in Claude → Settings → Notifications. Claude Code sessions use the hooks connected in Settings → Access."), small: true)
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
        let head = vstack([name, label(tr("Claude 对话导图", "A mind map for your Claude chats") + " · " + tr("版本 ", "version ") + version, small: true, width: 360)], spacing: 4)
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
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 12, weight: .medium)
            let b = button(action, run)
            permRows.append((status, b, ok))
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
        let rows = [
            row(tr("完全磁盘访问", "Full Disk Access"),
                tr("读 macOS 通知中心里 Claude 的通知 → 知道哪个对话做完了、未读。只读，不上传。",
                   "Reads Claude's notifications from Notification Center → knows which chat finished and is unread. Read-only, never uploaded."),
                tr("打开设置", "Open Settings"), { p.fullDisk }, { p.openFullDisk() }),
            row(tr("辅助功能", "Accessibility"),
                tr("读 Claude App 侧边栏 → 知道哪些对话还在跑、你在 Claude 里看过哪个。",
                   "Reads the Claude app's sidebar → knows which chats are still running and which you've read."),
                tr("打开设置", "Open Settings"), { AXIsProcessTrusted() }, { p.openAccessibility() }),
            row(tr("用量", "Usage"),
                tr("可选，默认关闭。开启后借用 Claude Code 在钥匙串里的登录，读取 5 小时 / 每周用量和计划任务；只读，只发给 api.anthropic.com。",
                   "Optional, off by default. When on, it borrows Claude Code's sign-in from the Keychain to read 5-hour / weekly usage and scheduled tasks — read-only, sent only to api.anthropic.com."),
                tr("连接", "Connect"), { p.usageOK }, { p.connectUsage() }),
            row("Claude Code",
                tr("在 ~/.claude/settings.json 里加几个 hook → 终端、VS Code 里的 Claude Code 会话也能显示「进行中 / 未读」。原文件会备份。新开的会话才生效。",
                   "Adds a few hooks to ~/.claude/settings.json → Claude Code sessions in Terminal or VS Code show as running / unread too. The old file is backed up. Applies to sessions started afterwards."),
                tr("连接", "Connect"), { p.codeHooks }, { p.connectCode() }),
            row("ChatGPT",
                tr("读 ChatGPT 桌面 App 存在这台 Mac 上的对话列表、置顶、未读和用量（~/.codex，只读）→ 在 ChatGPT 里置顶的对话也显示「进行中 / 未读」，小组件也能显示 ChatGPT 的用量。不改任何东西，不上传。",
                   "Reads the thread list, pins, unread dots and usage the ChatGPT desktop app keeps on this Mac (~/.codex, read-only) → threads pinned in ChatGPT show as running / unread too, and the widget can show ChatGPT's usage. Changes nothing, uploads nothing."),
                tr("连接", "Connect"), { p.gptOK }, { [weak self] in p.connectGPT(); self?.refreshPerms() }),
        ]
        let tip = label(tr("重装（重新编译）后，如果这里显示未开启、但系统设置里已经勾上：在系统设置里把 Kikumap 删掉（−）再重新加一次。",
                           "After reinstalling, if access shows as off but it's ticked in System Settings: remove Kikumap there (−) and add it again."), small: true)
        let diag = button(tr("诊断报告", "Diagnostic report")) { [weak self] in self?.onDiagnose?() }
        diag.toolTip = tr("写一份 kikumap-check.txt：哪些正常、哪些不行。不含对话标题、内容和密码，可以直接发给帮你看的人。",
                          "Writes kikumap-check.txt: what works and what doesn't. No chat titles, messages or passwords, so you can send it to whoever helps.")
        let unhook = button(tr("断开 Claude Code", "Disconnect Claude Code")) { p.disconnectCode() }
        let usageOff = button(tr("关闭用量", "Turn off usage")) { [weak self] in p.disconnectUsage(); self?.refreshPerms() }
        let gptOff = button(tr("断开 ChatGPT", "Disconnect ChatGPT")) { [weak self] in p.disconnectGPT(); self?.refreshPerms() }
        return vstack(rows + [tip, NSStackView(views: [diag, unhook, usageOff, gptOff])], spacing: 18)
    }

    private func refreshPerms() {
        for (status, b, ok) in permRows {
            let on = ok()
            status.stringValue = on ? tr("✓ 已开启", "✓ On") : tr("未开启", "Off")
            status.textColor = on ? .labelColor : .secondaryLabelColor
            b.isEnabled = !on
        }
    }

    private func shortcuts() -> NSView {
        let field = HotKeyField()
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
            ("⌘↑ ⌘↓", "调整顺序", "move among siblings"),
            ("⌘Z / ⇧⌘Z", "撤销 / 重做", "undo / redo"),
            ("Space", "在 Claude 里打开对话", "open the chat in Claude"),
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
            if let (name, color) = TagPrompt.ask(color: map.nextTagColor(), window: self.window) {
                map.addTag(name, color: color)
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
        for t in map.tags {
            let pop = ColorPopUp(selected: t.color)
            pop.onPick = { [weak self] c in map.updateTag(t.id, color: c); self?.store.notify() }
            let name = ClosureField(string: t.name) { [weak self] s in map.updateTag(t.id, name: s); self?.store.notify() }
            name.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let del = button(tr("删除", "Delete")) { [weak self] in
                map.deleteTag(t.id); self?.store.notify(); self?.fillTags()
            }
            let row = NSStackView(views: [pop, name, del])
            row.spacing = 10
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
