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
        if !(0...3).contains(Date().timeIntervalSince(last)) {           // (a clock set back doesn't silence it)
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
            if let t = said[key], (0..<30).contains(Date().timeIntervalSince(t)) { continue }
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
            say(Prefs.speakDone.replacingOccurrences(of: "{name}", with: tr("定价方案", "Pricing plan")), after: Prefs.soundDone == "off" ? 0 : 0.7)
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
    /// ChatGPT's usage windows, shown under Claude's.
    var gptUsage: (() -> [(label: String, window: UsageMonitor.Window?, note: String?)])?
    /// What's off with reading Claude right now (nil: nothing).
    var claudeNote: (() -> String?)?
    /// What `claudeNote` says is about Claude's unread marks alone (what's running is read as usual).
    var claudeUnreadOnly: (() -> Bool)?
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

    /// `sure`: of those running, the ones Kikumap can see run now (the burst turns only for them; the others are "?").
    private var counts: (run: Int, sure: Int, unread: Int, needs: Int) {
        let unread = store.unreadChats
        return (store.runningChats.count, store.seenRunningChats.count, unread.count, unread.filter(store.needsInput).count)
    }

    func update() {
        let c = counts
        draw()
        // the burst turns while something runs (as far as Kikumap can see)
        if c.sure > 0, spin == nil {
            spin = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.phase = (self.phase + 1 / CGFloat(Logo.rayCount)).truncatingRemainder(dividingBy: 1)
                    self.draw()
                }
            }
        } else if c.sure == 0 {
            spin?.invalidate(); spin = nil
        }
        var tip = tr("进行中 \(c.run) · 未读 \(c.unread)", "Running \(c.run) · Unread \(c.unread)")
        if c.run > c.sure {
            tip += tr("（其中 \(c.run - c.sure) 个现在看不到，不知道还在不在跑：带 ?）", " (\(c.run - c.sure) out of Kikumap's sight, not known if still running: marked ?)")
        }
        let note = claudeNote?()
        if let n = note {
            tip += "\n? " + n + (claudeUnreadOnly?() == true
                ? tr("：Claude 里哪些看过了，这里可能没跟上，打开 Kikumap 看怎么恢复", ": which chats you've read in Claude may not show here; open Kikumap to see how to fix it")
                : tr("：Claude 里在跑和未读的可能不止这些，打开 Kikumap 看怎么恢复", ": there may be more running or unread in Claude than shown; open Kikumap to see how to fix it"))
        }
        if c.needs > 0 { tip += tr("（其中 \(c.needs) 个要你批准）", " (\(c.needs) need your approval)") }
        tip += tr("\n红色 = 未读（做完了还没看） · ! = 要你批准 · 小菊花在转 = 还在跑", "\nRed = unread (finished, not yet seen) · ! = needs your approval · turning burst = still running")
        item.button?.toolTip = tip + StatusBar.usageTip(usage)
        // VoiceOver: the app's name and what it's showing (the icon alone says nothing)
        var said = tr("Kikumap，进行中 \(c.run) 个，未读 \(c.unread) 个", "Kikumap, \(c.run) running, \(c.unread) unread")
        if c.run > c.sure { said += tr("，其中 \(c.run - c.sure) 个不确定", ", \(c.run - c.sure) of them not confirmed") }
        if let n = note { said += "，" + n }
        if c.needs > 0 { said += tr("，\(c.needs) 个要你批准", ", \(c.needs) need your approval") }
        item.button?.setAccessibilityLabel(said)
    }

    /// The tooltip's usage lines: Claude's session and week, and the Sonnet-only week while it's what holds you back;
    /// numbers from an earlier read say when they're from, and whose they are.
    static func usageTip(_ usage: UsageMonitor) -> String {
        var tip = ""
        let asOf = usage.asOfText.map { tr("（\($0)）", " (\($0))") } ?? ""
        // (a window that has reset since an earlier read: "–", what's used since isn't known)
        func used(_ w: UsageMonitor.Window?) -> String { w.map { tr("已用 ", "") + "\(Int($0.percent.rounded()))%  \(Clock.resets($0.resets))" } ?? "–" }
        if usage.session != nil { tip += tr("\n当前会话 ", "\nSession ") + used(usage.shownSession) + asOf }
        if usage.weekly != nil { tip += tr("\n本周 ", "\nWeek ") + used(usage.shownWeekly) + asOf }
        if let o = usage.bindingSonnet { tip += tr("\n本周（仅 Sonnet）已用 ", "\nWeek (Sonnet only) ") + "\(Int(o.percent.rounded()))%  \(Clock.resets(o.resets))" + asOf }
        if let a = usage.account, !tip.isEmpty { tip += tr("\nClaude Code 的账号：", "\nClaude Code's account: ") + a }
        return tip
    }

    /// The Today submenu's last line when it lists only the first `shown` chats: how many more, and their time.
    static func moreLine(_ day: [(id: String, secs: Double)], after shown: Int) -> String? {
        guard day.count > shown else { return nil }
        let rest = day.dropFirst(shown)
        return tr("　还有 \(rest.count) 个 · ", "　\(rest.count) more · ") + Clock.duration(rest.reduce(0) { $0 + $1.secs })
    }

    private func draw() {
        guard let button = item.button else { return }
        let c = counts
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = StatusBar.image(run: c.run, unread: c.unread, needs: c.needs, phase: c.sure > 0 ? phase : 0,
                                       ink: dark ? .white : .black, unsure: c.run > c.sure, unknown: claudeNote?() != nil)
        button.imagePosition = .imageOnly
    }

    /// Waiting for you: a red badge with the count ("!" first when one needs your approval).
    /// Running: the orange burst turning — with the count when nothing is waiting. Nothing at all: the burst.
    /// `unknown`: Claude can't be read now, so what the icon shows may not be all there is: a "?" at its end.
    static func image(run: Int, unread: Int, needs: Int = 0, phase: CGFloat = 0, ink: NSColor = .black, unsure: Bool = false, unknown: Bool = false) -> NSImage {
        let H: CGFloat = 18, pillH: CGFloat = 16, ringD: CGFloat = 15
        let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let badgeText = (needs > 0 ? "!" : "") + (unread > 99 ? "99+" : "\(unread)")
        let badge = NSAttributedString(string: badgeText, attributes: [.font: f, .foregroundColor: NSColor.white])
        let runText = NSAttributedString(string: (run > 99 ? "99+" : "\(run)") + (unsure ? "?" : ""), attributes: [.font: f, .foregroundColor: ink])
        let pillW = unread > 0 ? max(pillH, ceil(badge.size().width) + 9) : 0
        let ringW: CGFloat = run > 0 ? ringD + (unread > 0 ? 3 : 3 + ceil(runText.size().width)) : 0
        let q = NSAttributedString(string: "?", attributes: [.font: f, .foregroundColor: ink])
        let qW: CGFloat = unknown ? ceil(q.size().width) + 3 : 0
        let width = (run == 0 && unread == 0 ? 18 : ringW + pillW) + qW
        let img = NSImage(size: NSSize(width: width, height: H), flipped: true) { _ in
            if unknown {
                let ts = q.size()
                q.draw(at: NSPoint(x: width - ts.width, y: (H - ts.height) / 2))
            }
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
        @discardableResult func header(_ t: String) -> NSMenuItem {
            let h = menu.addItem(withTitle: t, action: nil, keyEquivalent: "")
            h.isEnabled = false
            return h
        }
        func chatItems(_ list: [Chat], _ state: Int) {
            for c in list.prefix(15) {
                var t = store.name(c.id)
                if t.count > 46 { t = String(t.prefix(46)) + "…" }
                let unseen = state == 2 && store.outOfSight(c.id)
                let it = menu.addItem(withTitle: t + (unseen ? "  ?" : ""), action: #selector(openItem(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = c.id
                it.image = StatusBar.mark(state, store.branchColor(c.id))
                it.toolTip = store.timeLabel(c)
                if unseen {
                    let at = store.lastSeenRunning(c.id).map { UsageMonitor.stamp($0) } ?? "?"
                    it.toolTip = c.isGPT
                        ? tr("它的任务记录 \(at) 起没再动：可能在等你批准、一步做得久，或者 ChatGPT 停了。从那时起的时长是估算的（≈）。在 ChatGPT 里打开它看看。",
                             "Its task log hasn't moved since \(at): it may be waiting for your approval, a long step may be running, or ChatGPT stopped. Its time from then is estimated (≈). Open it in ChatGPT to see.")
                        : tr("Kikumap 现在看不到 Claude 的对话列表（窗口关了或在别的桌面、侧边栏收起或折叠、在 Code 模式、Claude 退出了，或辅助功能关了）：\(at) 时它还在跑，现在做完没有还不知道，从那时起的时长是估算的（≈）。看看窗口顶部的同步状态怎么恢复。",
                             "Kikumap can't see Claude's chat list right now (window closed or on another desktop, sidebar hidden or folded, Code mode, Claude quit, or Accessibility off): it was running at \(at); whether it has finished isn't known yet, and its time from then is estimated (≈). The sync status at the top of the window says how to fix it.")
                }
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
        // Claude can't be read now: what's listed may not be all there is (for unread alone, when only its marks can't be)
        let blind = claudeNote?(), unreadOnly = claudeUnreadOnly?() ?? false
        let runBlind = blind != nil && !unreadOnly
        if let n = blind { header("? " + n) }
        header(tr("进行中 · ", "Running · ") + "\(run.count)" + (runBlind || run.contains { store.outOfSight($0.id) } ? "?" : ""))
        if run.isEmpty && runBlind { header(tr("　不知道", "　Not known")) }
        chatItems(run, 2)
        menu.addItem(.separator())
        header(tr("未读 · ", "Unread · ") + "\(unread.count)" + (blind != nil ? "?" : ""))
        if unread.isEmpty && blind != nil { header(tr("　不知道", "　Not known")) }
        chatItems(unread, 1)
        menu.addItem(.separator())

        // today so far, in a submenu
        let day = store.today()
        let total = day.reduce(0) { $0 + $1.secs }
        // (time Kikumap didn't see is estimated: said, with how much)
        let guessed = store.todayEstimated()
        let est = guessed >= 60 ? tr("（含估算 ≈\(Clock.duration(guessed))）", " (≈ \(Clock.duration(guessed)) estimated)") : ""
        let todayItem = menu.addItem(withTitle: day.isEmpty ? tr("今日回顾 · 还没有", "Today · nothing yet")
                                                             : tr("今日回顾 · \(day.count) 个对话 · \(Clock.duration(total))", "Today · \(day.count) chats · \(Clock.duration(total))") + est,
                                     action: nil, keyEquivalent: "")
        if guessed >= 60 {
            todayItem.toolTip = tr("Claude 的窗口看不到时（关了、在别的桌面、Claude 退出了），或 Codex 任务没动静时，Kikumap 看不到它们在不在跑。这段时间按你一次运行的常见时长估算，不超过它被看到做完的时候。",
                                   "While Claude's window can't be seen (closed, on another desktop, Claude quit), or a Codex task is quiet, Kikumap can't see whether it's still running. That time is estimated at your typical run, never past when it was seen finished.")
        }
        if !day.isEmpty {
            let sub = NSMenu()
            // (not one waiting for you)
            let done = day.filter { !store.isRunning($0.id) && !store.isQuiet($0.id) && store.chat($0.id).map(store.needsInput) != true }.count
            // (a time with estimated minutes in it says "≈")
            let estToday = store.estimated([Calendar.current.startOfDay(for: Date()), Date()])[0]
            func dur(_ secs: Double, _ est: Double) -> String { (est >= 60 ? "≈" : "") + Clock.duration(secs) }
            let h = sub.addItem(withTitle: tr("今天 \(GPTWatcher.who) 干活 \(dur(total, guessed)) · 做完 \(done) 个", "\(GPTWatcher.who) worked \(dur(total, guessed)) today · \(done) done"),
                                action: nil, keyEquivalent: "")
            h.isEnabled = false
            sub.addItem(.separator())
            func add(_ m: NSMenu, _ id: String, _ secs: Double) {
                var t = store.name(id)
                if t.count > 40 { t = String(t.prefix(40)) + "…" }
                let it = m.addItem(withTitle: t + "  ·  " + dur(secs, estToday[id] ?? 0), action: #selector(openItem(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = id
                it.image = StatusBar.mark(store.state(id), store.branchColor(id))
            }
            for (id, secs) in day.prefix(20) { add(sub, id, secs) }
            // the rest in one line, so the rows add up to the total above; it opens onto them
            if let t = StatusBar.moreLine(day, after: 20) {
                let more = sub.addItem(withTitle: t, action: nil, keyEquivalent: "")
                let rest = NSMenu(), tail = Array(day.dropFirst(20))
                for (id, secs) in tail.prefix(200) { add(rest, id, secs) }
                if let t = StatusBar.moreLine(tail, after: 200) { rest.addItem(withTitle: t, action: nil, keyEquivalent: "").isEnabled = false }
                more.submenu = rest
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

        let usageHead = header(tr("用量", "Usage"))
        // Claude's, then ChatGPT's, in one list; numbers from an earlier read say when they're from
        var rows: [(String, UsageMonitor.Window?, String?)] = []
        let asOf = usage.asOfText
        var who: String?
        if UsageMonitor.enabled && (usage.session != nil || usage.weekly != nil) {
            rows += [(tr("当前会话", "Current session"), usage.shownSession, asOf),
                     (usage.sonnet != nil ? tr("本周（所有模型）", "This week (all models)") : tr("本周", "This week"), usage.shownWeekly, asOf)]
            if usage.sonnet != nil { rows.append((tr("本周（仅 Sonnet）", "This week (Sonnet only)"), usage.shownSonnet, asOf)) }
            // whose it is: the account Claude Code is signed in with, which may not be the Claude app's
            who = usage.account.map { tr("Claude 的用量来自 Claude Code 登录的账号：", "Claude's usage is for the account Claude Code is signed in with: ") + $0 }
        }
        usageHead.toolTip = who
        rows += (gptUsage?() ?? []).map { ("ChatGPT · " + $0.label, $0.window, $0.note) }
        if !rows.isEmpty {
            let it = NSMenuItem()
            it.view = UsageMenuView(rows: rows)
            it.view?.toolTip = who
            menu.addItem(it)
        }
        if !UsageMonitor.enabled {
            let on = menu.addItem(withTitle: tr("显示 Claude 的用量和计划任务（付费套餐）…", "Show Claude's usage and scheduled tasks (paid plans)…"), action: #selector(turnOnUsage), keyEquivalent: "")
            on.target = self
        } else {
            // say what's wrong; point to To-do only when it actually lists it (an ignored one isn't pointed to)
            let listed = todo.contains { $0.id.hasPrefix("usage-") }
            switch usage.status {
            case .unknown: header(tr("　读取中…", "　Reading…"))
            case .ok where usage.session == nil && usage.weekly == nil:
                header(tr("　这个套餐没有 5 小时 / 每周额度可看", "　No 5-hour or weekly limit on this plan"))
            case .ok: break
            default: header("　" + usage.hint + (listed ? tr("（见「待办」）", " (see To-do)") : ""))
            }
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

/// The usage panel inside the drop-down, laid out like claude.ai → Settings → Usage. The bars start after the
/// longest title, so a long one ("ChatGPT · Session") never runs into them.
final class UsageMenuView: NSView {
    private let rows: [(String, UsageMonitor.Window?, String?)]
    private static let titleF = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let bx: CGFloat

    /// Each row: its title, its window (nil: unknown, "—"), and a line under it instead of the reset time.
    init(rows: [(String, UsageMonitor.Window?, String?)]) {
        self.rows = rows
        let lw = ceil(rows.map { $0.0.size(UsageMenuView.titleF).width }.max() ?? 0)
        bx = max(124, 20 + lw + 12)
        super.init(frame: NSRect(x: 0, y: 0, width: max(330, bx + 100 + 70 + 18), height: CGFloat(rows.count) * 46 + 8))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(rows.map { "\($0.0): " + ($0.1.map { "\(Int($0.percent.rounded()))%" } ?? "—") }.joined(separator: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let titleF = UsageMenuView.titleF
        let subF = NSFont.systemFont(ofSize: 11)
        let pctF = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        for (i, row) in rows.enumerated() {
            let y = 4 + CGFloat(i) * 46
            (row.0 as NSString).draw(at: NSPoint(x: 20, y: y + 4),
                                     withAttributes: [.font: titleF, .foregroundColor: NSColor.labelColor])
            let sub = row.2 ?? Clock.resets(row.1?.resets)
            (sub as NSString).draw(at: NSPoint(x: 20, y: y + 22),
                                   withAttributes: [.font: subF, .foregroundColor: NSColor.secondaryLabelColor])
            let pct = row.1.map { "\(Int($0.percent.rounded()))%" + tr(" 已用", " used") } ?? "—"
            let ps = pct.size(pctF)
            (pct as NSString).draw(at: NSPoint(x: bounds.width - 18 - ps.width, y: y + 15 - ps.height / 2 + 3),
                                   withAttributes: [.font: pctF, .foregroundColor: NSColor.secondaryLabelColor])
            let bw = bounds.width - 18 - 70 - bx
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
