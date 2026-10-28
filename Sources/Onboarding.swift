import Cocoa

/// A view that redraws itself every frame; `painter` gets the bounds and seconds since `restart()`.
final class AnimView: NSView {
    var painter: ((NSRect, CGFloat) -> Void)?
    private var start = Date()
    private var timer: Timer?

    override var isFlipped: Bool { true }

    func restart() {
        start = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.needsDisplay = true }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        needsDisplay = true
    }

    func stop() { timer?.invalidate(); timer = nil }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill(); bounds.fill()
        painter?(bounds, CGFloat(Date().timeIntervalSince(start)))
    }
}

/// First launch: what the app does, then each permission on its own page.
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    enum Page: CaseIterable { case welcome, menubar, map, timeline, colors, fullDisk, accessibility, usage, code, claude, done }

    private let perms: Permissions
    private var window: NSWindow!
    private let art = AnimView()
    private let titleL = NSTextField(labelWithString: "")
    private let bodyL = NSTextField(wrappingLabelWithString: "")
    private let extra = NSView()
    private let back = NSButton()
    private let next = NSButton()
    private let skip = NSButton()
    private let dots = DotsView()
    private var index = 0
    private var poll: Timer?
    private var granted = false
    private var grantedAt: Date?
    private var statusL: NSTextField?
    var onLanguage: (() -> Void)?
    var onFinish: (() -> Void)?

    private var page: Page { Page.allCases[index] }

    init(perms: Permissions) {
        self.perms = perms
        super.init()
    }

    func show() {
        if window == nil { build() }
        index = 0
        render()
        window.center()
        Front.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        art.stop(); poll?.invalidate()
        Prefs.onboarded = true
        onFinish?()
    }

    // MARK: layout

    private func build() {
        let W: CGFloat = 720, H: CGFloat = 580
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = ColorView(Theme.bg)
        root.frame = NSRect(x: 0, y: 0, width: W, height: H)
        window.contentView = root

        art.frame = NSRect(x: 0, y: H - 320, width: W, height: 320)
        root.addSubview(art)

        titleL.font = .systemFont(ofSize: 24, weight: .semibold)
        titleL.textColor = Theme.ink
        titleL.alignment = .center
        titleL.frame = NSRect(x: 40, y: 212, width: W - 80, height: 32)
        root.addSubview(titleL)

        bodyL.font = .systemFont(ofSize: 13.5)
        bodyL.textColor = Theme.muted
        bodyL.alignment = .center
        bodyL.frame = NSRect(x: 90, y: 126, width: W - 180, height: 80)
        root.addSubview(bodyL)

        extra.frame = NSRect(x: 40, y: 76, width: W - 80, height: 44)
        root.addSubview(extra)

        Theme.ink.setStroke()
        let line = ColorView(Theme.faint)
        line.frame = NSRect(x: 0, y: 60, width: W, height: 1)
        root.addSubview(line)

        dots.frame = NSRect(x: W / 2 - 100, y: 22, width: 200, height: 16)
        root.addSubview(dots)

        for (b, sel) in [(back, #selector(goBack)), (next, #selector(goNext)), (skip, #selector(goSkip))] {
            b.bezelStyle = .rounded
            b.target = self
            b.action = sel
            root.addSubview(b)
        }
        next.keyEquivalent = "\r"
        skip.isBordered = false
        skip.contentTintColor = Theme.muted
    }

    private func layoutButtons() {
        let W = window.contentView!.bounds.width
        next.sizeToFit(); back.sizeToFit(); skip.sizeToFit()
        next.frame = NSRect(x: W - 24 - max(110, next.frame.width), y: 16, width: max(110, next.frame.width), height: 30)
        back.frame = NSRect(x: next.frame.minX - 8 - max(90, back.frame.width), y: 16, width: max(90, back.frame.width), height: 30)
        skip.frame = NSRect(x: 20, y: 18, width: skip.frame.width + 8, height: 26)
    }

    // MARK: pages

    private func render() {
        poll?.invalidate(); poll = nil
        statusL = nil
        grantedAt = nil
        extra.subviews.forEach { $0.removeFromSuperview() }
        let p = page
        dots.count = Page.allCases.count
        dots.current = index
        back.title = tr("上一步", "Back")
        back.isHidden = index == 0
        skip.title = tr("跳过介绍", "Skip intro")
        skip.isHidden = index >= Page.allCases.firstIndex(of: .fullDisk)!
        next.title = p == .done ? tr("开始使用", "Get started") : tr("下一步", "Next")

        switch p {
        case .welcome:
            titleL.stringValue = "Kikumap"
            bodyL.stringValue = tr("同时开着很多 Claude 对话？这个小工具住在菜单栏里，告诉你哪个还在跑、哪个做完了还没看（未读），还能把对话整理成一张导图。",
                                   "Many Claude chats going at once? This little menu-bar app tells you which are still running and which finished and are still unread — and lets you sort them into a mind map.")
            let seg = NSSegmentedControl(labels: ["中文", "English"], trackingMode: .selectOne, target: self, action: #selector(pickLanguage(_:)))
            seg.selectedSegment = Prefs.english ? 1 : 0
            center(seg)
            art.painter = { r, t in Onboarding.paintWelcome(r, t) }
        case .menubar:
            titleL.stringValue = tr("菜单栏一眼看完", "Everything at a glance")
            bodyL.stringValue = tr("菜单栏里只占一个图标：红色数字 = 未读，做完了还没看（带 ! 表示要你批准），橙色小菊花在转 = 还在跑。点开是列表和用量，点一下直接跳到那个对话。",
                                   "One icon in the menu bar: a red number = unread, finished but not yet seen (with ! when it needs your approval); the orange burst turning = still running. Click for the list and your usage; click a chat to jump to it.")
            art.painter = { r, t in Onboarding.paintMenuBar(r, t) }
        case .map:
            titleL.stringValue = tr("导图：把对话归好类", "A map for your chats")
            bodyL.stringValue = tr("按 \(Prefs.hotKeyLabel()) 打开导图。新对话先进左边的收件栏，拖到主题上就归好了。键盘操作和 MindNode 一样。",
                                   "Press \(Prefs.hotKeyLabel()) for the map. New chats wait in the inbox on the left; drag them onto a topic. Keys work like MindNode.")
            art.painter = { r, t in Onboarding.paintMap(r, t) }
        case .timeline:
            titleL.stringValue = tr("时间线", "Timeline")
            bodyL.stringValue = tr("导图下方是时间线：Claude 什么时候在忙哪个对话、计划任务什么时候跑（带倒计时）。鼠标停在上面能看到名字。",
                                   "Below the map: when Claude worked on which chat and when scheduled tasks run (with countdowns). Hover for names.")
            art.painter = { r, t in Onboarding.paintTimeline(r, t) }
        case .colors:
            titleL.stringValue = tr("颜色只留给你", "Colour is yours")
            bodyL.stringValue = tr("界面本身是灰阶的，状态用形状区分（空心环 = 在跑，实心点 = 未读）。颜色只用来做你自己的标记：给分支上色，给对话和主题加任意多个标签。",
                                   "The interface is greyscale; status is shown by shape (ring = running, dot = unread). Colour is only for your own marks: colour branches, and give chats and topics as many tags as you like.")
            art.painter = { r, t in Onboarding.paintColors(r, t) }
        case .fullDisk:
            permissionPage(step: 1, symbol: "externaldrive",
                           title: tr("第 1 步：完全磁盘访问", "Step 1: Full Disk Access"),
                           body: tr("用来读 macOS 通知中心里 Claude 的通知，这样才知道哪个对话做完了。只读，不会上传任何东西。\n点下面的按钮 → 在列表里打开 Kikumap（没有的话点 ＋，从刚弹出的 Finder 窗口里选它）。",
                                    "Lets the app read Claude's notifications in Notification Center, so it knows when a chat finishes. Read-only; nothing is uploaded.\nClick below → switch on Kikumap in the list (if it's missing, click ＋ and pick it from the Finder window that just opened)."),
                           action: tr("打开系统设置", "Open System Settings"),
                           check: { [perms] in perms.fullDisk }, run: { [perms] in perms.openFullDisk() })
        case .accessibility:
            permissionPage(step: 2, symbol: "accessibility",
                           title: tr("第 2 步：辅助功能", "Step 2: Accessibility"),
                           body: tr("用来读 Claude App 的侧边栏，这样才知道哪些对话还在跑、你在 Claude 里看过哪个。\n点下面的按钮 → 在列表里打开 Kikumap。",
                                    "Lets the app read the Claude app's sidebar, so it knows which chats are still running and which you've already read.\nClick below → switch on Kikumap in the list."),
                           action: tr("打开系统设置", "Open System Settings"),
                           check: { AXIsProcessTrusted() }, run: { [perms] in perms.openAccessibility() })
        case .usage:
            permissionPage(step: 3, symbol: "gauge.with.dots.needle.50percent",
                           title: tr("第 3 步：用量（可选）", "Step 3: Usage (optional)"),
                           body: tr("想在菜单里看到套餐用量和计划任务，可以借用 Claude Code 存在钥匙串里的登录：只读取，不修改、不保存，只发给 api.anthropic.com。\nKikumap 和 Claude Code 用同一种方式读取，macOS 一般不会问；如果问了，请选「始终允许」。不需要就直接下一步，以后也能在设置里开。",
                                    "To see your plan usage and scheduled tasks in the menu, Kikumap can borrow the sign-in Claude Code keeps in the Keychain: read-only, never saved, sent only to api.anthropic.com.\nIt's read the same way Claude Code reads it, so macOS usually doesn't ask; if it does, choose \"Always Allow\". Don't need it? Just go on; you can turn it on later in Settings."),
                           action: tr("连接", "Connect"),
                           check: { [perms] in perms.usageOK }, run: { [perms] in perms.connectUsage(explained: true) })
        case .code:
            permissionPage(step: 4, symbol: "terminal",
                           title: tr("第 4 步：Claude Code", "Step 4: Claude Code"),
                           body: tr("如果你在终端或 VS Code 里用 Claude Code，点「连接」：会在 ~/.claude/settings.json 里加几个 hook，会话一开始跑、做完、等你批准，这里马上知道。原文件会备份，随时可以在设置里断开。\n只对之后新开的会话生效。不用 Claude Code 可以跳过。",
                                    "If you use Claude Code in Terminal or VS Code, click Connect: a few hooks go into ~/.claude/settings.json, so this app knows the moment a session starts, finishes or waits for your approval. The old file is backed up; disconnect any time in Settings.\nApplies to sessions started afterwards. Don't use Claude Code? Skip this."),
                           action: tr("连接", "Connect"),
                           check: { [perms] in perms.codeHooks }, run: { [perms] in perms.connectCode() })
        case .claude:
            titleL.stringValue = tr("最后：打开 Claude 的通知", "Last: Claude's notifications")
            bodyL.stringValue = tr("在 Claude App → 设置 → 通知 里打开「Response completions」。做完和需要你操作的提醒都靠它。\n另外请让 Claude App 的侧边栏（对话列表）保持展开。",
                                   "In the Claude app → Settings → Notifications, turn on \"Response completions\". Finished / needs-input alerts depend on it.\nAlso keep the Claude app's sidebar (chat list) open.")
            let b = ClosureButton(title: tr("打开 Claude", "Open Claude")) {
                if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
                    NSWorkspace.shared.openApplication(at: u, configuration: .init())
                }
            }
            center(b)
            art.painter = { r, t in Onboarding.paintSymbol(r, t, "bell.badge", granted: nil) }
        case .done:
            titleL.stringValue = tr("准备好了", "You're set")
            bodyL.stringValue = tr("Kikumap 在菜单栏右上角。随时可以在「设置」里改语言、外观、通知、授权和快捷键。",
                                   "The console lives in the menu bar. Change language, appearance, notifications, access and shortcuts any time in Settings.")
            let looks = Prefs.Appearance.allCases
            let seg = NSSegmentedControl(labels: [tr("跟随系统", "System"), tr("浅色", "Light"), tr("深色", "Dark")],
                                         trackingMode: .selectOne, target: self, action: #selector(pickLook(_:)))
            seg.selectedSegment = looks.firstIndex(of: Prefs.appearance) ?? 0
            center(seg)
            art.painter = { r, t in Onboarding.paintDone(r, t) }
        }
        layoutButtons()
        art.restart()
    }

    private func center(_ v: NSView) {
        (v as? NSControl)?.sizeToFit()
        let s = v.fittingSize
        v.frame = NSRect(x: (extra.bounds.width - s.width) / 2, y: (extra.bounds.height - s.height) / 2, width: s.width, height: s.height)
        extra.addSubview(v)
    }

    private func permissionPage(step: Int, symbol: String, title: String, body: String, action: String,
                                check: @escaping () -> Bool, run: @escaping () -> Void) {
        titleL.stringValue = title
        bodyL.stringValue = body
        granted = check()
        let b = ClosureButton(title: action, run)
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12.5, weight: .medium)
        statusL = status
        let row = NSStackView(views: [b, status])
        row.spacing = 12
        center(row)
        let update = { [weak self] in
            guard let self = self else { return }
            status.stringValue = self.granted ? tr("✓ 已开启", "✓ Granted") : tr("还没开启 · 可以先跳过", "Not yet · you can skip for now")
            status.textColor = self.granted ? Theme.ink : Theme.muted
            b.isEnabled = !self.granted
            row.layoutSubtreeIfNeeded()
            let s = row.fittingSize
            row.frame = NSRect(x: (self.extra.bounds.width - s.width) / 2, y: (self.extra.bounds.height - s.height) / 2, width: s.width, height: s.height)
        }
        update()
        next.title = granted ? tr("下一步", "Next") : tr("稍后再说", "Later")
        let pageIndex = index
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.index == pageIndex else { return }
                let now = check()
                guard now != self.granted else { return }
                self.granted = now
                update()
                self.next.title = now ? tr("下一步", "Next") : tr("稍后再说", "Later")
                if now {
                    // just granted: show the tick, then move on by itself
                    self.grantedAt = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        MainActor.assumeIsolated { if self?.index == pageIndex { self?.goNext() } }
                    }
                }
            }
        }
        art.painter = { [weak self] r, t in
            let since = self?.grantedAt.map { CGFloat(Date().timeIntervalSince($0)) }
            Onboarding.paintSymbol(r, t, symbol, granted: (self?.granted ?? false) ? (since ?? 10) : nil, step: step)
        }
    }

    // MARK: actions

    @objc private func goNext() {
        if index + 1 >= Page.allCases.count { window.close(); return }
        index += 1
        render()
    }

    @objc private func goBack() {
        guard index > 0 else { return }
        index -= 1
        render()
    }

    @objc private func goSkip() {
        index = Page.allCases.firstIndex(of: .fullDisk)!
        render()
    }

    @objc private func pickLanguage(_ s: NSSegmentedControl) {
        Prefs.language = s.selectedSegment == 1 ? .en : .zh
        onLanguage?()
        render()
    }

    @objc private func pickLook(_ s: NSSegmentedControl) {
        Prefs.appearance = Prefs.Appearance.allCases[s.selectedSegment]
    }

    // MARK: illustrations (flipped coordinates, t = seconds on this page)

    private static func ease(_ x: CGFloat) -> CGFloat { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }

    private static func text(_ s: String, _ f: NSFont, _ c: NSColor, _ p: NSPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: c])
    }

    private static func card(_ r: NSRect, radius: CGFloat = 10) {
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.12)
        sh.shadowBlurRadius = 14
        sh.shadowOffset = NSSize(width: 0, height: -3)
        sh.set()
        Theme.paper.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.faint.setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        p.lineWidth = 1; p.stroke()
    }

    static func paintWelcome(_ r: NSRect, _ t: CGFloat) {
        let s: CGFloat = 170
        let box = NSRect(x: r.midX - s / 2, y: r.midY - s / 2 + 10, width: s, height: s)
        Logo.draw(in: box, progress: t / 1.8, spin: t > 1.8 ? (t - 1.8) * 0.6 : 0)
    }

    static func paintMenuBar(_ r: NSRect, _ t: CGFloat) {
        let bar = NSRect(x: 60, y: 30, width: r.width - 120, height: 30)
        Theme.paper.setFill(); NSBezierPath(roundedRect: bar, xRadius: 8, yRadius: 8).fill()
        Theme.faint.setStroke(); let bp = NSBezierPath(roundedRect: bar.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8); bp.stroke()
        text(tr("周三 9:41", "Wed 9:41"), .systemFont(ofSize: 12, weight: .medium), Theme.ink, NSPoint(x: bar.maxX - 80, y: bar.minY + 7))
        let c = t.truncatingRemainder(dividingBy: 6)
        let switched = c >= 2
        let run = switched ? 1 : 2, wait = switched ? 2 : 1
        // the app's single menu-bar icon (as StatusBar.image draws it)
        let icon = StatusBar.image(run: run, unread: wait, needs: switched ? 1 : 0, phase: (t * 0.8).truncatingRemainder(dividingBy: 1), ink: Theme.ink)
        let waitX: CGFloat = bar.minX + 380
        let ww = icon.size.width
        icon.draw(in: NSRect(x: waitX, y: bar.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
        // a chat just finished: ripple around the solid number
        if c >= 2 && c < 3 {
            let k = (c - 2)
            let rr = NSRect(x: waitX, y: bar.midY - 11, width: ww, height: 22).insetBy(dx: -k * 14, dy: -k * 14)
            Theme.ink.withAlphaComponent(0.5 * (1 - k)).setStroke()
            let p = NSBezierPath(roundedRect: rr, xRadius: 11 + k * 14, yRadius: 11 + k * 14); p.lineWidth = 1.5; p.stroke()
        }
        // the drop-down
        let menu = NSRect(x: bar.minX + 340, y: 72, width: 270, height: 182)
        card(menu)
        let hf = NSFont.systemFont(ofSize: 11, weight: .semibold), rf = NSFont.systemFont(ofSize: 13)
        let running = switched ? [tr("论文 Video", "Paper video")] : [tr("论文 Video", "Paper video"), "Mac mini"]
        let waiting = switched ? ["Mac mini", tr("设计稿", "Design draft")] : [tr("设计稿", "Design draft")]
        var y = menu.minY + 10
        func header(_ s: String) { text(s, hf, Theme.muted, NSPoint(x: menu.minX + 14, y: y)); y += 20 }
        func row(_ s: String, _ state: Int) {
            Theme.drawStatus(state, in: NSRect(x: menu.minX + 14, y: y + 3, width: 12, height: 12), phase: t)
            text(s, rf, Theme.ink, NSPoint(x: menu.minX + 34, y: y)); y += 22
        }
        header(tr("进行中 · \(running.count)", "Running · \(running.count)"))
        running.forEach { row($0, 2) }
        y += 6
        header(tr("未读 · \(waiting.count)", "Unread · \(waiting.count)"))
        waiting.forEach { row($0, 1) }
        y += 6
        header(tr("用量", "Usage"))
        text(tr("当前会话  42%", "Session  42%"), rf, Theme.ink, NSPoint(x: menu.minX + 14, y: y))
    }

    static func paintMap(_ r: NSRect, _ t: CGFloat) {
        let side = NSRect(x: 40, y: 24, width: 170, height: 270)
        card(side)
        text(tr("新对话", "Inbox"), .systemFont(ofSize: 12.5, weight: .semibold), Theme.ink, NSPoint(x: side.minX + 14, y: side.minY + 12))
        let c = t.truncatingRemainder(dividingBy: 5)
        let move = ease((c - 1.2) / 1.2)
        let chips = [tr("报税问题", "Tax question"), tr("周报草稿", "Weekly report"), tr("旅行计划", "Trip plan")]
        for (i, s) in chips.enumerated() where !(i == 0 && move > 0) {
            let y = side.minY + 44 + CGFloat(i) * 30
            Theme.line.setFill(); NSRect(x: side.minX + 14, y: y + 20, width: 130, height: 1).fill()
            text(s, .systemFont(ofSize: 12.5), Theme.ink, NSPoint(x: side.minX + 14, y: y + 2))
        }
        let root = NSPoint(x: 320, y: 150)
        let topics = [tr("工作", "Work"), tr("个人", "Personal"), tr("学习", "Learning")]
        let ys: [CGFloat] = [70, 150, 230]
        for (i, name) in topics.enumerated() {
            let a = ease((t - 0.25 * CGFloat(i)) / 0.5)
            guard a > 0 else { continue }
            let box = NSRect(x: 420, y: ys[i] - 17, width: 120, height: 34)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: root.x + 30, y: root.y))
            let end = NSPoint(x: root.x + 30 + (box.minX - root.x - 30) * a, y: root.y + (ys[i] - root.y) * a)
            let mx = (root.x + 30 + end.x) / 2
            p.curve(to: end, controlPoint1: NSPoint(x: mx, y: root.y), controlPoint2: NSPoint(x: mx, y: end.y))
            p.lineWidth = 2.5; Theme.line.setStroke(); p.stroke()
            if a >= 1 {
                Theme.paper.setFill()
                let bp = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7); bp.fill()
                Theme.line.setStroke(); bp.lineWidth = 1.5; bp.stroke()
                text(name, .systemFont(ofSize: 14, weight: .bold), Theme.ink, NSPoint(x: box.minX + 14, y: box.minY + 8))
            }
        }
        Theme.ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: root.x - 34, y: root.y - 34, width: 68, height: 68)).fill()
        let rs = "Claude".size(.systemFont(ofSize: 14, weight: .semibold))
        text("Claude", .systemFont(ofSize: 14, weight: .semibold), Theme.bg, NSPoint(x: root.x - rs.width / 2, y: root.y - rs.height / 2))
        // a chat is dragged from the inbox onto "Personal"
        if move > 0 {
            let from = NSPoint(x: side.minX + 14, y: side.minY + 46), to = NSPoint(x: 572, y: 140)
            let p = NSPoint(x: from.x + (to.x - from.x) * move, y: from.y + (to.y - from.y) * move - sin(move * .pi) * 30)
            if move >= 1 {
                let l = NSBezierPath(); l.move(to: NSPoint(x: 540, y: 150)); l.curve(to: NSPoint(x: 572, y: 160), controlPoint1: NSPoint(x: 556, y: 150), controlPoint2: NSPoint(x: 556, y: 160))
                l.lineWidth = 1.75; Theme.line.setStroke(); l.stroke()
                Theme.line.setFill(); NSRect(x: 572, y: 159, width: 100, height: 1.5).fill()
                text(chips[0], .systemFont(ofSize: 12.5), Theme.ink, NSPoint(x: 574, y: 141))
            } else {
                let s = chips[0].size(.systemFont(ofSize: 12.5, weight: .semibold))
                let chip = NSRect(x: p.x, y: p.y, width: s.width + 18, height: 24)
                Theme.ink.setFill(); NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
                text(chips[0], .systemFont(ofSize: 12.5, weight: .semibold), Theme.bg, NSPoint(x: chip.minX + 9, y: chip.minY + 4))
            }
        }
    }

    static func paintTimeline(_ r: NSRect, _ t: CGFloat) {
        let panel = NSRect(x: 50, y: 30, width: r.width - 100, height: 250)
        card(panel)
        let lanes = [tr("进行中", "Running"), tr("计划任务", "Scheduled")]
        let left = panel.minX + 80, right = panel.maxX - 16
        for (i, l) in lanes.enumerated() {
            let y = panel.minY + 30 + CGFloat(i) * 52
            Theme.faint.setFill(); NSRect(x: panel.minX, y: y, width: panel.width, height: 1).fill()
            text(l, .systemFont(ofSize: 11.5), Theme.muted, NSPoint(x: panel.minX + 14, y: y + 8))
        }
        let nowX = left + (right - left) * 0.62
        let y0 = panel.minY + 42
        let spans: [(CGFloat, CGFloat, NSColor)] = [(0.02, 0.14, Theme.muted), (0.2, 0.33, Theme.highlights[5].color),
                                                     (0.36, 0.44, Theme.muted), (0.48, 0.55, Theme.highlights[0].color)]
        for (a, b, c) in spans {
            c.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: left + (right - left) * a, y: y0, width: (right - left) * (b - a), height: 24), xRadius: 3, yRadius: 3).fill()
        }
        // live block grows up to "now"
        let liveStart = left + (right - left) * 0.57
        let grow = ease(t / 2.5)
        let live = NSRect(x: liveStart, y: y0, width: max(4, (nowX - liveStart) * grow), height: 24)
        Theme.highlights[3].color.setFill(); NSBezierPath(roundedRect: live, xRadius: 3, yRadius: 3).fill()
        Theme.ink.setStroke(); let lo = NSBezierPath(roundedRect: live.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3); lo.stroke()
        // scheduled runs ahead
        let y1 = panel.minY + 82 + 13
        for (i, k) in [0.7, 0.97].enumerated() {
            let mx = left + (right - left) * CGFloat(k)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: mx, y: y1 - 7)); p.line(to: NSPoint(x: mx + 7, y: y1)); p.line(to: NSPoint(x: mx, y: y1 + 7)); p.line(to: NSPoint(x: mx - 7, y: y1)); p.close()
            (i == 0 ? Theme.ink : Theme.muted).setFill(); p.fill()
            if i == 0 {
                let mins = max(0, 134 - Int(t * 7))
                text(tr("日报 · \(mins / 60)小时\(mins % 60)分后", "Daily digest · in \(mins / 60)h \(mins % 60)m"),
                     .systemFont(ofSize: 11.5, weight: .semibold), Theme.ink, NSPoint(x: mx + 11, y: y1 - 8))
            }
        }
        // now line
        Theme.ink.setFill(); NSRect(x: nowX - 0.75, y: panel.minY + 24, width: 1.5, height: 170).fill()
        // hover cursor drifting
        let hx = left + (right - left) * (0.3 + 0.25 * (1 + sin(t * 0.9)) / 2)
        let d = NSBezierPath(); d.move(to: NSPoint(x: hx, y: panel.minY + 30)); d.line(to: NSPoint(x: hx, y: panel.minY + 186))
        d.setLineDash([3, 3], count: 2, phase: 0); Theme.muted.setStroke(); d.stroke()
        // day strip
        let dy = panel.minY + 200
        Theme.ink.setFill(); NSRect(x: left, y: dy, width: right - left, height: 1).fill()
        for h in 0..<13 {
            let x = left + (right - left) * CGFloat(h) / 12
            Theme.muted.setFill(); NSRect(x: x, y: dy, width: 1, height: h % 6 == 0 ? 8 : 4).fill()
        }
        let today = NSRect(x: left + 1, y: dy + 16, width: right - left - 2, height: 20)
        Theme.ink.setFill(); today.fill()
        text(tr("今天", "Today"), .systemFont(ofSize: 11, weight: .semibold), Theme.paper, NSPoint(x: today.minX + 6, y: today.minY + 3))
    }

    static func paintColors(_ r: NSRect, _ t: CGFloat) {
        let panel = NSRect(x: 80, y: 24, width: r.width - 160, height: 196)
        card(panel)
        let root = NSPoint(x: panel.minX + 90, y: panel.midY)
        let rows: [(String, CGFloat, Int?, [Int])] = [
            (tr("工作", "Work"), panel.minY + 44, 5, [0]),
            (tr("个人", "Personal"), panel.midY, nil, [3, 7]),
            (tr("副业", "Side project"), panel.maxY - 44, 0, []),
        ]
        let colourIn = ease((t - 1.6) / 0.8)
        for (i, (name, y, color, tags)) in rows.enumerated() {
            let lineC: NSColor = color.map { blend(Theme.line, Theme.highlights[$0].color, colourIn) } ?? Theme.line
            let p = NSBezierPath()
            p.move(to: NSPoint(x: root.x + 28, y: root.y))
            p.curve(to: NSPoint(x: panel.minX + 200, y: y), controlPoint1: NSPoint(x: root.x + 80, y: root.y), controlPoint2: NSPoint(x: root.x + 80, y: y))
            p.lineWidth = 2.5; lineC.setStroke(); p.stroke()
            let box = NSRect(x: panel.minX + 200, y: y - 16, width: 110, height: 32)
            Theme.paper.setFill(); let bp = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7); bp.fill()
            lineC.setStroke(); bp.lineWidth = 1.5; bp.stroke()
            text(name, .systemFont(ofSize: 13.5, weight: .bold), Theme.ink, NSPoint(x: box.minX + 12, y: box.minY + 7))
            // a chat under each topic, with tags popping in
            let cx = box.maxX + 40
            let l = NSBezierPath(); l.move(to: NSPoint(x: box.maxX, y: y)); l.line(to: NSPoint(x: cx, y: y + 8))
            l.lineWidth = 1.5; lineC.setStroke(); l.stroke()
            lineC.setFill(); NSRect(x: cx, y: y + 8, width: 130, height: 1.5).fill()
            text(tr("对话 \(i + 1)", "Chat \(i + 1)"), .systemFont(ofSize: 12.5), Theme.ink, NSPoint(x: cx + 2, y: y - 9))
            for (k, tag) in tags.enumerated() {
                let a = ease((t - 2.6 - 0.25 * CGFloat(k + i)) / 0.3)
                guard a > 0 else { continue }
                let d = 7 * a
                Theme.highlights[tag].color.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx + 70 + CGFloat(k) * 11 + (7 - d) / 2, y: y - 3 - d / 2 + 3.5, width: d, height: d)).fill()
            }
        }
        Theme.ink.setFill(); NSBezierPath(ovalIn: NSRect(x: root.x - 28, y: root.y - 28, width: 56, height: 56)).fill()
        // the palette
        let n = Theme.highlights.count
        let size: CGFloat = 22, gap: CGFloat = 12
        let total = CGFloat(n) * size + CGFloat(n - 1) * gap
        for (i, h) in Theme.highlights.enumerated() {
            let a = ease((t - 0.15 * CGFloat(i)) / 0.35)
            guard a > 0 else { continue }
            let d = size * a
            let cx = r.midX - total / 2 + CGFloat(i) * (size + gap) + size / 2
            h.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: 262 - d / 2, width: d, height: d)).fill()
        }
    }

    private static func blend(_ a: NSColor, _ b: NSColor, _ k: CGFloat) -> NSColor {
        a.usingColorSpace(.sRGB)?.blended(withFraction: k, of: b.usingColorSpace(.sRGB) ?? b) ?? b
    }

    /// Permission pages: a big symbol, the step, and a tick that pops in once granted.
    static func paintSymbol(_ r: NSRect, _ t: CGFloat, _ name: String, granted: CGFloat?, step: Int? = nil) {
        let box = NSRect(x: r.midX - 70, y: r.midY - 70, width: 140, height: 140)
        let bob = sin(t * 2) * 3
        card(box.offsetBy(dx: 0, dy: bob), radius: 32)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 60, weight: .light)) {
            let s = img.size
            let rect = NSRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2 + bob, width: s.width, height: s.height)
            let tinted = NSImage(size: s, flipped: false) { rr in
                img.draw(in: rr)
                Theme.ink.set()
                rr.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let g = granted {
            let k = ease(g / 0.35)
            let pop = k + sin(min(g, 0.6) / 0.6 * .pi) * 0.15
            let d = 44 * pop
            let c = NSPoint(x: box.maxX - 6, y: box.maxY - 6 + bob)
            Theme.bg.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - d / 2 - 4, y: c.y - d / 2 - 4, width: d + 8, height: d + 8)).fill()
            Theme.ink.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
            if k > 0.5 {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: c.x - 9 * pop, y: c.y))
                p.line(to: NSPoint(x: c.x - 3 * pop, y: c.y + 7 * pop))
                p.line(to: NSPoint(x: c.x + 10 * pop, y: c.y - 7 * pop))
                p.lineWidth = 3.5; p.lineCapStyle = .round; p.lineJoinStyle = .round
                Theme.bg.setStroke(); p.stroke()
            }
        }
        if let s = step {
            for i in 1...4 {
                let x = r.midX - 45 + CGFloat(i - 1) * 30
                let rr = NSRect(x: x - 5, y: 26, width: 10, height: 10)
                if i <= s { Theme.ink.setFill(); NSBezierPath(ovalIn: rr).fill() } else {
                    Theme.line.setStroke(); let p = NSBezierPath(ovalIn: rr.insetBy(dx: 0.75, dy: 0.75)); p.lineWidth = 1.5; p.stroke()
                }
                if i < 3 { Theme.line.setFill(); NSRect(x: x + 8, y: 30.5, width: 14, height: 1).fill() }
            }
        }
    }

    static func paintDone(_ r: NSRect, _ t: CGFloat) {
        let s: CGFloat = 150
        Logo.draw(in: NSRect(x: r.midX - s / 2, y: r.midY - s / 2 + 10, width: s, height: s), progress: 1, spin: t * 0.6)
    }
}

/// Page dots.
final class DotsView: NSView {
    var count = 0 { didSet { needsDisplay = true } }
    var current = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 14
        let total = CGFloat(max(0, count - 1)) * gap
        for i in 0..<count {
            let x = bounds.midX - total / 2 + CGFloat(i) * gap
            let on = i == current
            let d: CGFloat = on ? 8 : 6
            (on ? Theme.ink : Theme.line).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
        }
    }
}
