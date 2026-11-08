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
    /// When each kind of news last rang: "done" (false) and "waiting for you" (true). More of the same kind within 3 s
    /// (several chats finishing at once) rings once; the other kind still rings right after it.
    private var last: [Bool: Date] = [:]
    /// Plays a sound (a system sound's name or a file's path).
    var ring: (String) -> Void = { Sounds.sound($0)?.play() }
    private var said: [String: Date] = [:]
    private let voice = AVSpeechSynthesizer()

    /// `claudeFront`, `gptFront`: whether Claude or ChatGPT counts as in front for these, when not as of now (what a
    /// read of its window or files found finished: in front at some point since the read before, or since the finish,
    /// as the read judged them).
    func play(_ events: [Store.Event], claudeFront: Bool? = nil, gptFront: Bool? = nil) {
        guard !events.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if Prefs.quietWhenClaudeFront && (claudeFront ?? (front == claudeBundleID)) { return }
        if Prefs.quietWhenGPTFront && (gptFront ?? (front == GPTWatcher.bundleID)) { return }
        let needsInput = events.contains { if case .needsInput = $0 { return true }; return false }
        var rang = false
        let s = needsInput ? Prefs.soundInput : Prefs.soundDone
        // (a clock set back doesn't silence it)
        if s != "off" && !(0...3).contains(Date().timeIntervalSince(last[needsInput] ?? .distantPast)) {
            last[needsInput] = Date()
            preview(s)
            rang = true
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
        ring(name)
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
    /// ChatGPT's plan ("Pro"), while its usage is shown.
    var gptPlan: (() -> String?)?
    /// What's wrong with ChatGPT's usage lookup from OpenAI (nil: it's off or reads fine), said under the usage rows.
    var gptUsageNote: (() -> String?)?
    /// What's off with reading Claude right now (nil: nothing).
    var claudeNote: (() -> String?)?
    /// What `claudeNote` says is about Claude's unread marks alone (what's running is read as usual).
    var claudeUnreadOnly: (() -> Bool)?
    /// What's off with reading ChatGPT right now (nil: nothing): what runs or is unread there may be more than shown.
    var gptNote: (() -> String?)?
    /// Both notes come from Accessibility being off: said once, for both.
    var accessOffForBoth: (() -> Bool)?
    /// Why ChatGPT's window can't be read now (nil: it reads fine), for an ordinary chat's row out of sight.
    var gptWindowIssue: (() -> GPTSidebarIssue?)?
    /// Claude or ChatGPT had a note at the last `update`: the icon's "?" (it's drawn many times a second while something
    /// runs, so they aren't asked each time).
    private var blind = false
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

    private var counts: (run: Int, sure: Int, unread: Int, needs: Int) { StatusBar.counts(store) }

    /// What the icon counts, as the window's top bar counts it too. `sure`: of those running, the ones KIKUmap can see
    /// run now (the ring turns only for them; the others are "?"). `needs`: of those unread, the ones waiting for you
    /// (the red count's "!").
    static func counts(_ store: Store) -> (run: Int, sure: Int, unread: Int, needs: Int) {
        let unread = store.unreadChats
        return (store.runningChats.count, store.seenRunningChats.count, unread.count, unread.filter(store.needsInput).count)
    }

    func update() {
        let c = counts
        let notes = StatusBar.notes(claude: claudeNote?(), gpt: gptNote?(), accessOff: accessOffForBoth?() == true)
        let lines = StatusBar.noteLines(notes, claudeUnreadOnly: claudeUnreadOnly?() == true)
        blind = notes.claude != nil || notes.gpt != nil
        draw()
        // the ring's arc goes round while something runs (as far as KIKUmap can see)
        if c.sure > 0, spin == nil {
            spin = Timer.scheduledTimer(withTimeInterval: Theme.turnFrame, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.phase = Theme.turn()
                    self.draw()
                }
            }
        } else if c.sure == 0 {
            spin?.invalidate(); spin = nil
        }
        // (each with the count it's about, before the lines on what can't be read)
        let words = StatusBar.countsText(run: c.run, sure: c.sure, unread: c.unread, needs: c.needs)
        var tip = words.tip
        tip += lines.tip
        tip += tr("\n红色数字 = 未读（做完了，还没看） · ! = 在等你（要你确认或回答，或者出错停下了） · 圈里的数字 = 在跑几个（外圈在转：现在在跑）", "\nRed number = unread (done, not looked at yet) · ! = waiting for you (to approve or answer, or it stopped on an error) · number in a ring = how many are running (arc turning: running now)")
        item.button?.toolTip = tip + StatusBar.usageTip(usage)
        // VoiceOver: the app's name and what it's showing (the icon alone says nothing)
        item.button?.setAccessibilityLabel(words.said + lines.said)
    }

    /// The icon's tooltip line for its counts, and VoiceOver's words for them: the ones out of sight are said right
    /// after the running count (they're of those), the ones waiting for you after the unread count.
    static func countsText(run: Int, sure: Int, unread: Int, needs: Int) -> (tip: String, said: String) {
        var tip = tr("在跑 \(run)", "Running \(run)"), said = tr("KIKUmap，在跑 \(run) 个", "KIKUmap, \(run) running")
        if run > sure {
            tip += tr("（其中 \(run - sure) 个现在看不到，可能还在跑，标着 ?）", " (\(run - sure) out of sight, maybe still running: marked ?)")
            said += tr("，其中 \(run - sure) 个现在看不到", ", \(run - sure) of them out of sight")
        }
        tip += tr(" · 未读 \(unread)", " · Unread \(unread)")
        said += tr("，未读 \(unread) 个", ", \(unread) unread")
        if needs > 0 {
            tip += tr("（其中 \(needs) 个在等你）", " (\(needs) waiting for you)")
            said += tr("，其中 \(needs) 个在等你", ", \(needs) of them waiting for you")
        }
        return (tip, said)
    }

    /// Claude's note and ChatGPT's (what can't be read now), as the menu bar says them: one for both when both come
    /// from Accessibility being off (`accessOff`), as the window's help says it once; else each its own.
    static func notes(claude: String?, gpt: String?, accessOff: Bool) -> (claude: String?, gpt: String?, both: Bool) {
        guard accessOff, claude != nil, gpt != nil else { return (claude, gpt, false) }
        return (tr("Claude 和 ChatGPT 没同步：辅助功能关着", "Claude and ChatGPT not synced: Accessibility off"), nil, true)
    }

    /// The icon's tooltip lines for those notes ("? …", each with what it may leave out), and VoiceOver's words for them.
    /// (A note may already have a colon in it, "Claude not synced: Accessibility off": what follows is a sentence of its own.)
    static func noteLines(_ n: (claude: String?, gpt: String?, both: Bool), claudeUnreadOnly: Bool) -> (tip: String, said: String) {
        var tip = ""
        if let c = n.claude {
            tip += "\n? " + c + (n.both
                ? tr("。Claude 和 ChatGPT 里在跑的、未读的可能比这里多，打开 KIKUmap 看怎么解决", ". There may be more running or unread in Claude and ChatGPT than shown; open KIKUmap to see how to fix it")
                : claudeUnreadOnly
                ? tr("。你在 Claude 里看过哪些，这里可能没跟上，打开 KIKUmap 看怎么解决", ". Which chats you've read in Claude may not show here; open KIKUmap to see how to fix it")
                : tr("。Claude 里在跑的、未读的可能比这里多，打开 KIKUmap 看怎么解决", ". There may be more running or unread in Claude than shown; open KIKUmap to see how to fix it"))
        }
        if let g = n.gpt {
            tip += "\n? " + g + tr("。ChatGPT 里在跑的、未读的可能比这里多，打开 KIKUmap 看怎么解决", ". There may be more running or unread in ChatGPT than shown; open KIKUmap to see how to fix it")
        }
        return (tip, [n.claude, n.gpt].compactMap { $0 }.map { tr("，", ", ") + $0 }.joined())
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
        if let o = usage.bindingSonnet { tip += tr("\n本周（仅 \(usage.modelName)）已用 ", "\nWeek (\(usage.modelName) only) ") + "\(Int(o.percent.rounded()))%  \(Clock.resets(o.resets))" + asOf }
        if let a = usage.account, !tip.isEmpty { tip += tr("\nClaude Code 的账号：", "\nClaude Code's account: ") + a + (usage.plan.map { " · " + $0 } ?? "") }
        return tip
    }

    /// The drop-down's lines over its two lists: "? …" for what can't be read now (Claude's, then ChatGPT's, as `notes`
    /// gives them), then each count, with "?" when some may be missing ("Not known" under it while it's 0). What's
    /// running is read as usual when only Claude's unread marks can't be (`claudeUnreadOnly`); `unseen`: some running
    /// are out of sight; `needs`: of the unread, how many wait for you ("!" first, as on the icon).
    static func heads(run: Int, unread: Int, unseen: Bool, needs: Int = 0, claude: String?, claudeUnreadOnly: Bool, gpt: String?)
        -> (notes: [String], run: [String], unread: [String]) {
        let runBlind = (claude != nil && !claudeUnreadOnly) || gpt != nil, unreadBlind = claude != nil || gpt != nil
        func count(_ title: String, _ n: Int, _ unsure: Bool, _ blind: Bool, bang: Bool = false) -> [String] {
            [title + (bang ? "!" : "") + "\(n)" + (unsure ? "?" : "")] + (n == 0 && blind ? [tr("　不知道", "　Not known")] : [])
        }
        return ([claude, gpt].compactMap { $0.map { "? " + $0 } },
                count(tr("在跑 · ", "Running · "), run, runBlind || unseen, runBlind),
                count(tr("未读 · ", "Unread · "), unread, unreadBlind, unreadBlind, bang: needs > 0))
    }

    /// A chat's line in the drop-down: its name (cut short past 46 characters), then "?" while it runs out of KIKUmap's
    /// sight, or "!" while it waits for you, as the icon marks them.
    static func chatTitle(_ name: String, unseen: Bool, waits: Bool) -> String {
        (name.count > 46 ? String(name.prefix(46)) + "…" : name) + (unseen ? "  ?" : waits ? "  !" : "")
    }

    /// A chat's row's reason for its "?" (below): since when `store` last saw it running, and a Codex session's app.
    static func unseenWhy(_ c: Chat, in store: Store, gpt: GPTSidebarIssue?) -> String {
        let at = store.lastSeenRunning(c.id).map { UsageMonitor.stamp($0) } ?? "?"
        return unseenWhy(c.id, at: at, gpt: gpt, session: c.isCodexSession ? c.app : nil)
    }
    /// Why a chat last seen running at `at` is out of KIKUmap's sight now (its row's "?"), on hovering the row and to
    /// VoiceOver. A Codex task: its log has gone quiet; a Codex session's (`session`: its app, "vscode" or another
    /// editor's or a terminal's) waits for you there, not in ChatGPT. An ordinary ChatGPT chat: why ChatGPT's window
    /// can't be read (`gpt`), as the "ChatGPT not synced" line above says it, with its fix; nil: the window was read,
    /// but not this chat's row. A chat in the Claude app: its chat list can't be seen.
    static func unseenWhy(_ id: String, at: String, gpt: GPTSidebarIssue?, session: String? = nil) -> String {
        if Store.codexThread(id), let app = session {
            return app == "vscode"
                ? tr("它的任务记录 \(at) 起没再动：可能在 VS Code 里等你确认，可能有一步做得久，也可能 Codex 退出了。从那时起的时长是估算的（≈）。到 VS Code 里看看。",
                     "Its task log hasn't moved since \(at): it may be waiting for your approval in VS Code, a long step may be running, or Codex quit. Its time from then is estimated (≈). Look in VS Code to see.")
                : tr("它的任务记录 \(at) 起没再动：可能在它的终端或编辑器里等你确认，可能有一步做得久，也可能 Codex 退出了。从那时起的时长是估算的（≈）。到那里看看。",
                     "Its task log hasn't moved since \(at): it may be waiting for your approval in its terminal or editor, a long step may be running, or Codex quit. Its time from then is estimated (≈). Look there to see.")
        }
        if Store.codexThread(id) {
            return tr("它的任务记录 \(at) 起没再动：可能在等你确认，可能有一步做得久，也可能 ChatGPT 停了。从那时起的时长是估算的（≈）。在 ChatGPT 里打开看看。",
                      "Its task log hasn't moved since \(at): it may be waiting for you to approve, a long step may be running, or ChatGPT stopped. Its time from then is estimated (≈). Open it in ChatGPT to see.")
        }
        if id.hasPrefix("gpt-chat-") {
            let since = tr("\(at) 时它还在跑，现在做完没有还不知道，从那时起的时长是估算的（≈）。",
                           "It was running at \(at); whether it has finished isn't known yet, and its time from then is estimated (≈). ")
            // (its row isn't found by its name: two pinned chats share it, or it was renamed a moment ago)
            guard let i = gpt else {
                return tr("ChatGPT 的侧边栏里按名字找不到这个对话（刚改了名，或者另一个置顶对话和它同名）。", "ChatGPT's sidebar doesn't show this chat by its name (renamed just now, or another pinned chat has the same name). ")
                    + since + tr("怎么办：两个置顶对话同名的话，在 ChatGPT 里给其中一个改个名。", "Fix: if two pinned chats share its name, rename one of them in ChatGPT.")
            }
            return tr("ChatGPT 没同步：", "ChatGPT not synced: ") + i.note + tr("。", ". ") + since + i.fix
        }
        return tr("KIKUmap 现在看不到 Claude 的对话列表（窗口关了或在别的桌面、侧边栏收起或折叠、在 Code 模式、Claude 退出了，或辅助功能关了）：\(at) 时它还在跑，现在做完没有还不知道，从那时起的时长是估算的（≈）。窗口顶部的同步状态写着怎么解决。",
                  "KIKUmap can't see Claude's chat list right now (window closed or on another desktop, sidebar hidden or folded, Code mode, Claude quit, or Accessibility off): it was running at \(at); whether it has finished isn't known yet, and its time from then is estimated (≈). The sync status at the top of the window says how to fix it.")
    }

    /// The drop-down's heading over the scheduled tasks to come (`any`): "as of" when the list is from an earlier read;
    /// "not synced" when there's none to go by and it can't be read now; nil: nothing to show.
    static func scheduleHead(_ usage: UsageMonitor, any: Bool) -> String? {
        if usage.routinesUnknown != nil { return tr("计划任务 · 没同步", "Scheduled tasks · not synced") }
        guard any else { return nil }
        return tr("计划任务", "Scheduled tasks") + (usage.routinesAsOf.map { tr(" · \(UsageMonitor.stamp($0)) 时的列表", " · as of \(UsageMonitor.stamp($0))") } ?? "")
    }

    /// The drop-down's lines under the usage rows: what's wrong with reading Claude's (or that it's being read, while
    /// it's on), then with ChatGPT's lookup from OpenAI (`gpt`, nil while it's off or reads fine); each points to To-do
    /// only when that actually lists it (an ignored one isn't pointed to).
    static func usageLines(_ usage: UsageMonitor, gpt: String?, todo: [Todo]) -> [String] {
        let see = tr("（见「待办」）", " (see To-do)")
        var lines: [String] = []
        if UsageMonitor.enabled {
            switch usage.status {
            case .unknown: lines.append(tr("　读取中…", "　Reading…"))
            case .ok where usage.session == nil && usage.weekly == nil:
                lines.append(tr("　这个套餐没有 5 小时 / 每周额度可看", "　No 5-hour or weekly limit on this plan"))
            case .ok: break
            default: lines.append("　" + usage.hint + (todo.contains { $0.id.hasPrefix("usage-") } ? see : ""))
            }
        }
        if let g = gpt, !g.isEmpty { lines.append("　" + g + (todo.contains { $0.id.hasPrefix("gpt-usage-") } ? see : "")) }
        return lines
    }

    /// The drop-down's Usage section under its heading, in order: the rows (Claude's, then ChatGPT's), the lines on
    /// what's wrong with reading either (`usageLines`) right under them, and last, while Claude's usage is off, the item
    /// that turns it on: ChatGPT's line stays with ChatGPT's rows, not under that item.
    enum UsagePart: Equatable { case rows, line(String), turnOn }
    static func usageParts(_ usage: UsageMonitor, rows: Bool, gpt: String?, todo: [Todo]) -> [UsagePart] {
        (rows ? [.rows] : []) + usageLines(usage, gpt: gpt, todo: todo).map { .line($0) } + (UsageMonitor.enabled ? [] : [.turnOn])
    }

    /// The Today submenu's last line when it lists only the first `shown` chats: how many more, and their time ("≈" when
    /// a minute or more of it is estimated, `est` by chat, as each row says it).
    static func moreLine(_ day: [(id: String, secs: Double)], after shown: Int, est: [String: Double] = [:]) -> String? {
        guard day.count > shown else { return nil }
        let rest = day.dropFirst(shown)
        let guessed = rest.reduce(0) { $0 + (est[$1.id] ?? 0) }
        return tr("　还有 \(rest.count) 个 · ", "　\(rest.count) more · ") + (guessed >= 60 ? "≈" : "") + Clock.duration(rest.reduce(0) { $0 + $1.secs })
    }

    private func draw() {
        guard let button = item.button else { return }
        let c = counts
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = StatusBar.image(run: c.run, unread: c.unread, needs: c.needs, phase: c.sure > 0 ? phase : nil,
                                       ink: dark ? .white : .black, unsure: c.run > c.sure, unknown: blind)
        button.imagePosition = .imageOnly
    }

    /// Running: how many, in a ring with an orange arc going round while KIKUmap sees them run ("?" after it when
    /// some are out of its sight; the ring stands still when none can be seen). Waiting for you: a red badge with
    /// the count ("!" first when one needs you). Nothing at all: the burst.
    /// `unknown`: Claude or ChatGPT can't be read now, so what the icon shows may not be all there is: a "?" at its end.
    static func image(run: Int, unread: Int, needs: Int = 0, phase: CGFloat? = nil, ink: NSColor = .black, unsure: Bool = false, unknown: Bool = false) -> NSImage {
        let H: CGFloat = 18, pillH: CGFloat = 16, ringD: CGFloat = 17
        let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let badgeText = (needs > 0 ? "!" : "") + (unread > 99 ? "99+" : "\(unread)")
        let badge = NSAttributedString(string: badgeText, attributes: [.font: f, .foregroundColor: NSColor.white])
        let pillW = unread > 0 ? max(pillH, ceil(badge.size().width) + 9) : 0
        let q = NSAttributedString(string: "?", attributes: [.font: f, .foregroundColor: ink])
        let qw = ceil(q.size().width)
        let ringW: CGFloat = run > 0 ? ringD + (unsure ? 1 + qw : 0) + (unread > 0 ? 1.5 : 0) : 0
        let qW: CGFloat = unknown ? qw + 3 : 0
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
                Theme.drawRunCount(run > 99 ? "99+" : "\(run)", in: NSRect(x: 0, y: (H - ringD) / 2, width: ringD, height: ringD),
                                   ink: ink, arc: Theme.running, font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
                                   phase: phase, lineWidth: 1.7)
                x = ringD
                if unsure {
                    let ts = q.size()
                    q.draw(at: NSPoint(x: x + 1, y: (H - ts.height) / 2))
                    x += 1 + qw
                }
                x += 1.5
            }
            if unread > 0 {
                let r = NSRect(x: x, y: (H - pillH) / 2, width: pillW, height: pillH)
                Theme.unread.setFill()
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

    /// The menu's Today line: chats and sessions counted apart (as the left column names them), the time, and how much
    /// of it is estimated.
    static func todayTitle(_ n: (chats: Int, sessions: Int), total: Double, estimated: Double) -> String {
        guard n.chats + n.sessions > 0 else { return tr("今日回顾 · 还没有", "Today · nothing yet") }
        let est = estimated >= 60 ? tr("（含估算 ≈\(Clock.duration(estimated))）", " (≈ \(Clock.duration(estimated)) estimated)") : ""
        return tr("今日回顾 · ", "Today · ") + ChatCount.both(n) + " · " + Clock.duration(total) + est
    }

    /// What Today's ≈ is: time KIKUmap couldn't see (a window out of sight, a quiet Codex task, a request you may have
    /// answered where it can't see), and how each is counted.
    static var estimateTip: String {
        tr("Claude 或 ChatGPT 的窗口看不到时（关了、在别的桌面、退出了），或者 Codex 任务没动静时，KIKUmap 不知道对话还在不在跑，这段时间是估算的：两次看到它在跑之间，或者到确定做完的时刻（Claude 的通知、任务记录），整段都算；其余按你一次运行的常见时长算，最多算到看到它做完的时候。你可能已经回答了的请求（在终端或编辑器里批准了，或者它的通知被清掉了）也是估算的：算到 KIKUmap 听到那一步结束，最多按你一次运行的常见时长算。",
           "While Claude's or ChatGPT's window can't be seen (closed, on another desktop, the app quit), or a Codex task is quiet, KIKUmap can't tell whether a chat is still running, so that time is estimated: in full between two sightings, or up to a known finish (Claude's notification, the task's log); otherwise your typical run's length, never past when it was seen finished. A request you may have answered (approved in its terminal or editor, or its notification cleared) is estimated too: counted up to when KIKUmap hears that step end, at most your typical run.")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult func header(_ t: String) -> NSMenuItem {
            let h = menu.addItem(withTitle: t, action: nil, keyEquivalent: "")
            h.isEnabled = false
            return h
        }
        func chatItems(_ list: [Chat], _ state: Int) {
            for c in list.prefix(15) {
                let unseen = state == 2 && store.outOfSight(c.id), waits = state == 1 && store.needsInput(c)
                let it = menu.addItem(withTitle: StatusBar.chatTitle(store.name(c.id), unseen: unseen, waits: waits),
                                      action: #selector(openItem(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = c.id
                it.image = StatusBar.mark(state, store.branchColor(c.id))
                it.toolTip = store.timeLabel(c)
                // (what it waits for: on hovering it, and to VoiceOver)
                if waits { it.setAccessibilityHelp(it.toolTip) }
                if unseen {
                    // (VoiceOver gives the same reason as hovering)
                    it.toolTip = StatusBar.unseenWhy(c, in: store, gpt: gptWindowIssue?())
                    it.setAccessibilityHelp(it.toolTip)
                }
            }
            if list.count > 15 { header(tr("　还有 \(list.count - 15) 个…", "　\(list.count - 15) more…")) }
        }
        // first, the map
        let open = menu.addItem(withTitle: tr("打开导图", "Open map") + (Prefs.hotKeyWorks ? "   " + Prefs.hotKeyLabel() : ""),
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
        let notes = StatusBar.notes(claude: claudeNote?(), gpt: gptNote?(), accessOff: accessOffForBoth?() == true)
        let heads = StatusBar.heads(run: run.count, unread: unread.count, unseen: run.contains { store.outOfSight($0.id) },
                                    needs: unread.filter(store.needsInput).count,
                                    claude: notes.claude, claudeUnreadOnly: !notes.both && claudeUnreadOnly?() == true, gpt: notes.gpt)
        for t in heads.notes + heads.run { header(t) }
        chatItems(run, 2)
        menu.addItem(.separator())
        for t in heads.unread { header(t) }
        chatItems(unread, 1)
        menu.addItem(.separator())

        // today so far, in a submenu
        let day = store.today()
        let total = day.reduce(0) { $0 + $1.secs }
        // (time KIKUmap didn't see is estimated: said, with how much)
        let guessed = store.todayEstimated()
        let todayItem = menu.addItem(withTitle: StatusBar.todayTitle(store.chatCount(day.map(\.id)), total: total, estimated: guessed),
                                     action: nil, keyEquivalent: "")
        if guessed >= 60 { todayItem.toolTip = StatusBar.estimateTip }
        if !day.isEmpty {
            let sub = NSMenu()
            // (not one waiting for you)
            let done = day.filter { !store.isRunning($0.id) && !store.isQuiet($0.id) && !store.maybeWaiting($0.id) && store.chat($0.id).map(store.needsInput) != true }.count
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
            if let t = StatusBar.moreLine(day, after: 20, est: estToday) {
                let more = sub.addItem(withTitle: t, action: nil, keyEquivalent: "")
                let rest = NSMenu(), tail = Array(day.dropFirst(20))
                for (id, secs) in tail.prefix(200) { add(rest, id, secs) }
                if let t = StatusBar.moreLine(tail, after: 200, est: estToday) { rest.addItem(withTitle: t, action: nil, keyEquivalent: "").isEnabled = false }
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
        if let head = StatusBar.scheduleHead(usage, any: !next.isEmpty) {
            header(head).toolTip = usage.routinesWhy.map { tr("没同步：", "Not synced: ") + $0 }
            // (why it isn't known, unless it's usage's own trouble, which Usage below says)
            if let why = usage.routinesUnknown, usage.status == .ok { header("　" + why) }
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
            // (a plan without the 5-hour limit has no session row)
            if usage.session != nil { rows.append((tr("当前会话", "Current session"), usage.shownSession, asOf)) }
            if usage.weekly != nil {
                rows.append((usage.sonnet != nil ? tr("本周（所有模型）", "This week (all models)") : tr("本周", "This week"), usage.shownWeekly, asOf))
            }
            if usage.sonnet != nil { rows.append((tr("本周（仅 \(usage.modelName)）", "This week (\(usage.modelName) only)"), usage.shownSonnet, asOf)) }
            // whose it is: the account Claude Code is signed in with, which may not be the Claude app's
            who = usage.account.map { tr("Claude 的用量来自 Claude Code 登录的账号：", "Claude's usage is for the account Claude Code is signed in with: ") + $0 }
        }
        usageHead.toolTip = who
        let gptRows = gptUsage?() ?? []
        rows += gptRows.map { ("ChatGPT · " + $0.label, $0.window, $0.note) }
        // whose plans these are, as Claude Code and Codex name them: "Usage · Claude Max 20x · ChatGPT Pro"
        var plans: [String] = []
        if UsageMonitor.enabled && (usage.session != nil || usage.weekly != nil), let p = usage.plan { plans.append("Claude " + p) }
        if !gptRows.isEmpty, let p = gptPlan?() { plans.append("ChatGPT " + p) }
        if !plans.isEmpty { usageHead.title = ([tr("用量", "Usage")] + plans).joined(separator: " · ") }
        for part in StatusBar.usageParts(usage, rows: !rows.isEmpty, gpt: gptUsageNote?(), todo: todo) {
            switch part {
            case .rows:
                let it = NSMenuItem()
                it.view = UsageMenuView(rows: rows)
                it.view?.toolTip = who
                menu.addItem(it)
            case .line(let t): header(t)
            case .turnOn:
                let on = menu.addItem(withTitle: tr("显示 Claude 的用量和计划任务（付费套餐）…", "Show Claude's usage and scheduled tasks (paid plans)…"), action: #selector(turnOnUsage), keyEquivalent: "")
                on.target = self
            }
        }
        menu.addItem(.separator())

        let all = menu.addItem(withTitle: tr("全部标为已读", "Mark all as read"), action: #selector(markAll), keyEquivalent: "")
        all.target = self
        // (not for chats Claude shows waiting for you alone: they stay unread while it does)
        all.isEnabled = unread.contains { store.markable($0.id) }
        let st = menu.addItem(withTitle: tr("设置…", "Settings…"), action: #selector(settings), keyEquivalent: ",")
        st.target = self
        let ab = menu.addItem(withTitle: tr("关于 KIKUmap", "About KIKUmap"), action: #selector(about), keyEquivalent: "")
        ab.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("退出 KIKUmap", "Quit KIKUmap"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        setAccessibilityLabel(UsageMenuView.spoken(rows))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// A row's number on the right ("45% used"); nil: not known (drawn "—").
    static func used(_ w: UsageMonitor.Window?) -> String? { w.map { "\(Int($0.percent.rounded()))%" + tr(" 已用", " used") } }
    /// The line under a row's title: its note ("as of 14:05", "reset 14:00"), else when it resets.
    static func under(_ row: (String, UsageMonitor.Window?, String?)) -> String { row.2 ?? Clock.resets(row.1?.resets) }

    /// VoiceOver's words for the panel: each row as it's drawn, with the line under it, so numbers from an earlier read
    /// are heard as such and a window that has reset since says when.
    static func spoken(_ rows: [(String, UsageMonitor.Window?, String?)]) -> String {
        rows.map { row in
            let sub = under(row)
            return row.0 + tr("：", ": ") + (used(row.1) ?? tr("不知道", "not known")) + (sub.isEmpty ? "" : tr("，", ", ") + sub)
        }.joined(separator: tr("；", "; "))
    }

    override func draw(_ dirtyRect: NSRect) {
        let titleF = UsageMenuView.titleF
        let subF = NSFont.systemFont(ofSize: 11)
        let pctF = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        for (i, row) in rows.enumerated() {
            let y = 4 + CGFloat(i) * 46
            (row.0 as NSString).draw(at: NSPoint(x: 20, y: y + 4),
                                     withAttributes: [.font: titleF, .foregroundColor: NSColor.labelColor])
            let sub = UsageMenuView.under(row)
            (sub as NSString).draw(at: NSPoint(x: 20, y: y + 22),
                                   withAttributes: [.font: subF, .foregroundColor: NSColor.secondaryLabelColor])
            let pct = UsageMenuView.used(row.1) ?? "—"
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
