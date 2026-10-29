import Cocoa
import AVFoundation
import UniformTypeIdentifiers

/// Attention sounds (a macOS system sound or your own file, chosen in Settings) and, if you like,
/// the chat's name read aloud right after.
@MainActor
final class Sounds {
    static let choices = ["Glass", "Hero", "Ping", "Submarine", "Funk", "Purr", "Pop"]
    /// Your own sound files are copied here (data/sounds), so they still play if the original moves.
    static var folder: URL?
    /// The name to say for a chat.
    var nameOf: ((String) -> String)?
    private var last = Date.distantPast
    private var said: [String: Date] = [:]
    private let voice = AVSpeechSynthesizer()

    func play(_ events: [Store.Event]) {
        guard !events.isEmpty else { return }
        if Prefs.quietWhenClaudeFront && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID { return }
        let needsInput = events.contains { if case .needsInput = $0 { return true }; return false }
        var rang = false
        if Date().timeIntervalSince(last) > 3 {
            let s = needsInput ? Prefs.soundInput : Prefs.soundDone
            preview(s)
            rang = s != "off"
        }
        guard Prefs.speak, let nameOf = nameOf else { return }
        for e in events.prefix(3) {
            let (id, waiting): (String, Bool)
            switch e { case .finished(let i): (id, waiting) = (i, false); case .needsInput(let i): (id, waiting) = (i, true) }
            // the same news about the same chat is said once
            let key = id + (waiting ? "?" : ".")
            if let t = said[key], Date().timeIntervalSince(t) < 30 { continue }
            said[key] = Date()
            say((waiting ? Prefs.speakInput : Prefs.speakDone).replacingOccurrences(of: "{name}", with: nameOf(id)),
                after: rang ? 0.7 : 0)
            rang = false
        }
    }

    func preview(_ name: String) {
        guard name != "off" else { return }
        last = Date()
        Sounds.sound(name)?.play()
    }

    func say(_ text: String, after delay: Double = 0) {
        let u = AVSpeechUtterance(string: text)
        u.rate = Prefs.speakRate
        u.preUtteranceDelay = delay
        u.voice = Prefs.speakVoice.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? AVSpeechSynthesisVoice(language: text.range(of: "\\p{Han}", options: .regularExpression) != nil ? "zh-CN" : "en-US")
        voice.speak(u)
    }

    /// Settings → Test: the "finished" sound, then the sentence with a made-up chat.
    func test() {
        last = .distantPast
        preview(Prefs.soundDone)
        if Prefs.speak {
            say(Prefs.speakDone.replacingOccurrences(of: "{name}", with: tr("实验计划", "Experiment plan")), after: Prefs.soundDone == "off" ? 0 : 0.7)
        }
    }

    /// A system sound by name, or one of your own files (a path).
    static func sound(_ name: String) -> NSSound? {
        name.hasPrefix("/") ? NSSound(contentsOf: URL(fileURLWithPath: name), byReference: true) : NSSound(named: NSSound.Name(name))
    }

    /// Picks an audio file and keeps a copy with your data. Returns its path.
    static func importFile() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.message = tr("选一个声音文件，几秒钟的短音最合适", "Pick a sound file; a short one works best")
        guard p.runModal() == .OK, let src = p.url, let dir = folder else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        if dst.standardizedFileURL != src.standardizedFileURL {
            try? FileManager.default.removeItem(at: dst)
            guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return nil }
        }
        return dst.path
    }
}

/// Menu-bar readout, about one icon wide (see `image`); usage is in the tooltip and the drop-down.
/// The one colour is the system's red badge for "waiting for you" — none of the highlight colours.
@MainActor
final class StatusBar: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu: NSMenu
    private let store: Store
    private let usage: UsageMonitor
    private let sounds: Sounds
    var openChat: ((String) -> Void)?
    var showMap: (() -> Void)?
    var diagnose: (() -> Void)?
    /// Usage is off until you say yes: this explains it and asks.
    var enableUsage: (() -> Void)?
    var openRoutines: (() -> Void)?
    var openSettings: (() -> Void)?
    var openAbout: (() -> Void)?
    var openStats: (() -> Void)?
    var refreshAll: (() -> Void)?
    /// What's left to do (the menu lists the ones not ignored); `todosChanged` after one is ignored.
    var todos: (() -> [Todo])?
    var todosChanged: (() -> Void)?
    private var spin: Timer?
    private var phase: CGFloat = 0
    private var appearanceWatch: NSKeyValueObservation?

    init(store: Store, usage: UsageMonitor, sounds: Sounds) {
        self.store = store
        self.usage = usage
        self.sounds = sounds
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        // light / dark menu bar: redraw in its colours
        appearanceWatch = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.draw() }
        }
        update()
    }

    private var counts: (run: Int, unread: Int, needs: Int) {
        let unread = store.unreadChats
        return (store.runningChats.count, unread.count, unread.filter(store.needsInput).count)
    }

    func update() {
        let c = counts
        draw()
        // the burst turns while something runs
        if c.run > 0, spin == nil {
            spin = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.phase = (self.phase + 1 / CGFloat(Logo.rayCount)).truncatingRemainder(dividingBy: 1)
                    self.draw()
                }
            }
        } else if c.run == 0 {
            spin?.invalidate(); spin = nil
        }
        var tip = tr("进行中 \(c.run) · 未读 \(c.unread)", "Running \(c.run) · Unread \(c.unread)")
        if c.needs > 0 { tip += tr("（其中 \(c.needs) 个要你批准）", " (\(c.needs) need your approval)") }
        tip += tr("\n红色 = 未读（做完了还没看） · ! = 要你批准 · 小菊花在转 = 还在跑", "\nRed = unread (finished, not yet seen) · ! = needs your approval · turning burst = still running")
        if let s = usage.session { tip += tr("\n当前会话 已用 ", "\nSession ") + "\(Int(s.percent.rounded()))%  \(Clock.resets(s.resets))" }
        if let w = usage.weekly { tip += tr("\n本周 已用 ", "\nWeek ") + "\(Int(w.percent.rounded()))%  \(Clock.resets(w.resets))" }
        item.button?.toolTip = tip
    }

    private func draw() {
        guard let button = item.button else { return }
        let c = counts
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = StatusBar.image(run: c.run, unread: c.unread, needs: c.needs, phase: phase,
                                       ink: dark ? .white : .black)
        button.imagePosition = .imageOnly
    }

    /// Waiting for you: a red badge with the count ("!" first when one needs your approval).
    /// Running: the orange burst turning — with the count when nothing is waiting. Nothing at all: the burst.
    static func image(run: Int, unread: Int, needs: Int = 0, phase: CGFloat = 0, ink: NSColor = .black) -> NSImage {
        let H: CGFloat = 18, pillH: CGFloat = 16, ringD: CGFloat = 15
        let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let badgeText = (needs > 0 ? "!" : "") + (unread > 99 ? "99+" : "\(unread)")
        let badge = NSAttributedString(string: badgeText, attributes: [.font: f, .foregroundColor: NSColor.white])
        let runText = NSAttributedString(string: run > 99 ? "99+" : "\(run)", attributes: [.font: f, .foregroundColor: ink])
        let pillW = unread > 0 ? max(pillH, ceil(badge.size().width) + 9) : 0
        let ringW: CGFloat = run > 0 ? ringD + (unread > 0 ? 3 : 3 + ceil(runText.size().width)) : 0
        let width = run == 0 && unread == 0 ? 18 : ringW + pillW
        let img = NSImage(size: NSSize(width: width, height: H), flipped: true) { _ in
            if run == 0 && unread == 0 {
                Logo.draw(in: NSRect(x: 1, y: 1, width: 16, height: 16))
                return true
            }
            var x: CGFloat = 0
            if run > 0 {
                Logo.draw(in: NSRect(x: 0, y: (H - ringD) / 2, width: ringD, height: ringD), spin: phase == 0 ? 0.001 : phase)
                x = ringD + 3
                if unread == 0 {
                    let ts = runText.size()
                    runText.draw(at: NSPoint(x: x, y: (H - ts.height) / 2))
                }
            }
            if unread > 0 {
                let r = NSRect(x: x, y: (H - pillH) / 2, width: pillW, height: pillH)
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: r, xRadius: pillH / 2, yRadius: pillH / 2).fill()
                let ts = badge.size()
                badge.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Ring (running) or dot (waiting), in the chat's branch colour when it has one.
    private static func mark(_ state: Int, _ c: NSColor?) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            Theme.drawStatus(state, in: r.insetBy(dx: 0.5, dy: 0.5), color: c ?? .black)
            return true
        }
        img.isTemplate = c == nil
        return img
    }

    // MARK: the drop-down list

    func menuWillOpen(_ menu: NSMenu) { usage.refreshIfStale() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func header(_ t: String) {
            let h = menu.addItem(withTitle: t, action: nil, keyEquivalent: "")
            h.isEnabled = false
        }
        func chatItems(_ list: [Chat], _ state: Int) {
            for c in list.prefix(15) {
                var t = store.name(c.id)
                if t.count > 46 { t = String(t.prefix(46)) + "…" }
                let it = menu.addItem(withTitle: t, action: #selector(openItem(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = c.id
                it.image = StatusBar.mark(state, store.branchColor(c.id))
                it.toolTip = store.timeLabel(c)
            }
            if list.count > 15 { header(tr("　还有 \(list.count - 15) 个…", "　\(list.count - 15) more…")) }
        }
        // first, the map
        let open = menu.addItem(withTitle: tr("打开导图", "Open map") + (Prefs.hotKeyEnabled ? "   " + Prefs.hotKeyLabel() : ""),
                                action: #selector(openMap), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        let todo = Todos.open(todos?() ?? [])
        if !todo.isEmpty {
            // one line; each to-do opens to what it affects, a button that does it, and Ignore
            let t = menu.addItem(withTitle: "▸ " + tr("待办 · \(todo.count)", "To-do · \(todo.count)"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for d in todo {
                let m = NSMenu()
                let note = NSTextField(wrappingLabelWithString: d.impact)
                note.font = Theme.ui(11.5)
                note.textColor = .secondaryLabelColor
                note.preferredMaxLayoutWidth = 300
                note.setFrameSize(NSSize(width: 300, height: note.fittingSize.height))
                let box = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: note.frame.height + 8))
                note.setFrameOrigin(NSPoint(x: 15, y: 4))
                box.addSubview(note)
                let info = NSMenuItem()
                info.view = box
                m.addItem(info)
                m.addItem(.separator())
                if let a = d.action { m.addItem(MenuAction(title: a.title) { a.run() }) }
                m.addItem(MenuAction(title: tr("忽略（可在窗口顶部的「待办」里恢复）", "Ignore (bring it back from To-do at the top of the window)")) { [weak self] in
                    Todos.ignore(d.id, true); self?.todosChanged?()
                })
                sub.addItem(withTitle: d.title, action: nil, keyEquivalent: "").submenu = m
            }
            t.submenu = sub
            menu.addItem(.separator())
        }
        let run = store.runningChats, unread = store.unreadChats
        header(tr("进行中 · ", "Running · ") + "\(run.count)")
        chatItems(run, 2)
        menu.addItem(.separator())
        header(tr("未读 · ", "Unread · ") + "\(unread.count)")
        chatItems(unread, 1)
        menu.addItem(.separator())

        // today so far, in a submenu
        let day = store.today()
        let total = day.reduce(0) { $0 + $1.secs }
        let todayItem = menu.addItem(withTitle: day.isEmpty ? tr("今日回顾 · 还没有", "Today · nothing yet")
                                                             : tr("今日回顾 · \(day.count) 个对话 · \(Clock.duration(total))",
                                                                  "Today · \(day.count) chats · \(Clock.duration(total))"),
                                     action: nil, keyEquivalent: "")
        if !day.isEmpty {
            let sub = NSMenu()
            let done = day.filter { !store.isRunning($0.id) }.count
            let h = sub.addItem(withTitle: tr("今天 \(GPTWatcher.who) 干活 \(Clock.duration(total)) · 做完 \(done) 个", "\(GPTWatcher.who) worked \(Clock.duration(total)) today · \(done) done"),
                                action: nil, keyEquivalent: "")
            h.isEnabled = false
            sub.addItem(.separator())
            for (id, secs) in day.prefix(20) {
                var t = store.name(id)
                if t.count > 40 { t = String(t.prefix(40)) + "…" }
                let it = sub.addItem(withTitle: t + "  ·  " + Clock.duration(secs), action: #selector(openItem(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = id
                it.image = StatusBar.mark(store.state(id), store.branchColor(id))
            }
            todayItem.submenu = sub
        } else {
            todayItem.isEnabled = false
        }
        let statsItem = menu.addItem(withTitle: tr("统计…", "Statistics…"), action: #selector(stats), keyEquivalent: "")
        statsItem.target = self
        let refresh = menu.addItem(withTitle: tr("刷新", "Refresh"), action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.toolTip = tr("马上重新读 Claude、ChatGPT 和用量", "Read Claude, ChatGPT and usage again now")
        menu.addItem(.separator())

        let next = TimelineView.upcoming(usage.routines)
        if !next.isEmpty {
            header(tr("计划任务", "Scheduled tasks"))
            for (r, d) in next.prefix(4) {
                var t = r.name
                if t.count > 34 { t = String(t.prefix(34)) + "…" }
                let it = menu.addItem(withTitle: "\(t) · \(Clock.countdown(d))", action: #selector(routines), keyEquivalent: "")
                it.target = self
                it.image = StatusBar.diamond()
            }
            menu.addItem(.separator())
        }

        header(tr("用量", "Usage"))
        if !UsageMonitor.enabled {
            let on = menu.addItem(withTitle: tr("显示用量和计划任务（Pro / Max）…", "Show usage and scheduled tasks (Pro / Max)…"), action: #selector(turnOnUsage), keyEquivalent: "")
            on.target = self
        } else if usage.session != nil || usage.weekly != nil {
            let v = UsageMenuView(rows: [(tr("当前会话", "Current session"), usage.session), (tr("本周", "This week"), usage.weekly)])
            let it = NSMenuItem()
            it.view = v
            menu.addItem(it)
        }
        if usage.status != .ok && usage.status != .unknown {
            header(tr("　没有用量数据（见「待办」）", "　No usage to show (see To-do)"))
        } else if usage.status == .unknown && UsageMonitor.enabled {
            header(tr("　读取中…", "　Reading…"))
        }
        menu.addItem(.separator())

        let all = menu.addItem(withTitle: tr("全部标为已读", "Mark all as read"), action: #selector(markAll), keyEquivalent: "")
        all.target = self
        all.isEnabled = !unread.isEmpty
        let st = menu.addItem(withTitle: tr("设置…", "Settings…"), action: #selector(settings), keyEquivalent: ",")
        st.target = self
        let ab = menu.addItem(withTitle: tr("关于 Kikumap", "About Kikumap"), action: #selector(about), keyEquivalent: "")
        ab.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("退出 Kikumap", "Quit Kikumap"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func settings() { openSettings?() }
    @objc private func about() { openAbout?() }
    @objc private func stats() { openStats?() }
    @objc private func refreshNow() { refreshAll?() }

    @objc private func openItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        openChat?(id)
    }
    @objc private func openMap() { showMap?() }
    @objc private func routines() { openRoutines?() }

    private static func diamond() -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.midX, y: r.maxY - 0.5)); p.line(to: NSPoint(x: r.maxX - 0.5, y: r.midY))
            p.line(to: NSPoint(x: r.midX, y: r.minY + 0.5)); p.line(to: NSPoint(x: r.minX + 0.5, y: r.midY)); p.close()
            NSColor.labelColor.setFill(); p.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
    @objc private func markAll() { store.markAllSeen() }
    @objc private func turnOnUsage() { enableUsage?() }
    @objc private func diag() { diagnose?() }
    func relabel() { update() }
}

/// The usage panel inside the drop-down, laid out like claude.ai → Settings → Usage.
final class UsageMenuView: NSView {
    private let rows: [(String, UsageMonitor.Window?)]

    init(rows: [(String, UsageMonitor.Window?)]) {
        self.rows = rows
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: CGFloat(rows.count) * 46 + 8))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let titleF = NSFont.systemFont(ofSize: 13, weight: .medium)
        let subF = NSFont.systemFont(ofSize: 11)
        let pctF = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        for (i, row) in rows.enumerated() {
            let y = 4 + CGFloat(i) * 46
            (row.0 as NSString).draw(at: NSPoint(x: 20, y: y + 4),
                                     withAttributes: [.font: titleF, .foregroundColor: NSColor.labelColor])
            let sub = Clock.resets(row.1?.resets)
            (sub as NSString).draw(at: NSPoint(x: 20, y: y + 22),
                                   withAttributes: [.font: subF, .foregroundColor: NSColor.secondaryLabelColor])
            let pct = row.1.map { "\(Int($0.percent.rounded()))%" + tr(" 已用", " used") } ?? "—"
            let ps = pct.size(pctF)
            (pct as NSString).draw(at: NSPoint(x: bounds.width - 18 - ps.width, y: y + 15 - ps.height / 2 + 3),
                                   withAttributes: [.font: pctF, .foregroundColor: NSColor.secondaryLabelColor])
            let bx: CGFloat = 124, bw = bounds.width - 18 - 70 - bx
            let track = NSRect(x: bx, y: y + 16, width: bw, height: 5)
            NSColor.labelColor.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            if let p = row.1?.percent {
                let f = CGFloat(min(max(p, 0), 100) / 100)
                NSColor.labelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: bx, y: track.minY, width: max(5, bw * f), height: 5),
                             xRadius: 2.5, yRadius: 2.5).fill()
            }
        }
    }
}
