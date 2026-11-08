import Cocoa

/// A view that fills itself with a (dynamic) colour.
/// Fills `bounds`, never `dirtyRect`: since macOS 14 views don't clip, and the dirty rect can be
/// the whole window — a thin divider would paint over everything drawn before it.
final class ColorView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

/// Flat button: hairline outline, or a solid "do this" variant.
final class FlatButton: NSButton {
    var warn = false { didSet { needsDisplay = true } }
    /// A Lucide icon before the title.
    var iconName: String?

    convenience init(_ title: String, warn: Bool = false, icon: String? = nil, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.warn = warn
        self.iconName = icon
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
    }

    override var intrinsicContentSize: NSSize {
        let s = title.size(Theme.ui(12, .medium))
        return NSSize(width: ceil(s.width) + 22 + (iconName == nil ? 0 : 19), height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        let down = isHighlighted
        if warn {
            Theme.ink.withAlphaComponent(down ? 0.8 : 1).setFill(); p.fill()
        } else {
            (down ? Theme.hover : Theme.paper).setFill(); p.fill()
            Theme.line.setStroke(); p.lineWidth = 1; p.stroke()
        }
        let f = Theme.ui(12, .medium)
        let c: NSColor = warn ? Theme.bg : Theme.ink
        let s = title.size(f)
        let iconW: CGFloat = iconName == nil ? 0 : 19
        let x = bounds.midX - (s.width + iconW) / 2
        if let i = iconName { Icons.draw(i, in: NSRect(x: x, y: bounds.midY - 7, width: 14, height: 14), color: c, weight: 2) }
        (title as NSString).draw(at: NSPoint(x: x + iconW, y: bounds.midY - s.height / 2),
                                 withAttributes: [.font: f, .foregroundColor: c])
    }
}

/// A borderless SF Symbol button.
final class IconButton: NSButton {
    private let run: () -> Void
    /// VoiceOver reads what the tooltip says (the symbol alone has no useful name).
    override var toolTip: String? { didSet { setAccessibilityLabel(toolTip) } }
    init(_ symbol: String, tip: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 26))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setSymbol(symbol)
        toolTip = tip
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        contentTintColor = Theme.ink
    }
    @objc private func fire() { run() }

    private var spinner: Timer?
    /// Turns its picture round once or twice, slowing down: something happened. (With Reduce Motion, a tick for a moment.)
    func spin(_ symbol: String, seconds: Double = 0.9) {
        spinner?.invalidate()
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setSymbol("checkmark")
            spinner = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.setSymbol(symbol) } }
            return
        }
        let began = Date()
        spinner = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let f = min(1, Date().timeIntervalSince(began) / seconds)
                if f >= 1 { t.invalidate(); self.setSymbol(symbol); return }
                let eased = 1 - pow(1 - f, 3)
                let box = max(base.size.width, base.size.height) + 2
                let turned = NSImage(size: NSSize(width: box, height: box), flipped: false) { r in
                    var a = AffineTransform(translationByX: r.midX, byY: r.midY)
                    a.rotate(byDegrees: -720 * eased)
                    a.translate(x: -r.midX, y: -r.midY)
                    (a as NSAffineTransform).concat()
                    base.draw(in: NSRect(x: r.midX - base.size.width / 2, y: r.midY - base.size.height / 2, width: base.size.width, height: base.size.height))
                    Theme.ink.set(); r.fill(using: .sourceAtop)
                    return true
                }
                self.image = turned
            }
        }
    }
}

/// Top bar: mark, the two counts, usage, permission fixes, buttons.
@MainActor
final class HeaderView: NSView {
    var running = 0, unread = 0
    /// Of those unread, how many wait for you (to approve or answer, or stopped on an error): "!" before the red
    /// count, as in the menu bar ("!1").
    var needs = 0
    /// Some of those running are out of KIKUmap's sight (shown "2?").
    var runningUnsure = false
    /// Of those running, the ones KIKUmap sees run now: while there are any, the ring round the count turns.
    var runningSeen = 0 { didSet { if (runningSeen > 0) != (oldValue > 0) { turnRing() } } }
    private var ringTimer: Timer?
    private var ringPhase: CGFloat = 0
    private var ringRect = NSRect.zero

    private func turnRing() {
        ringTimer?.invalidate(); ringTimer = nil
        guard runningSeen > 0 else { needsDisplay = true; return }
        ringTimer = Timer.scheduledTimer(withTimeInterval: Theme.turnFrame, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.window?.isVisible == true, self.window?.occlusionState.contains(.visible) == true else { return }
                self.ringPhase = Theme.turn()
                self.setNeedsDisplay(self.ringRect.insetBy(dx: -2, dy: -2))
            }
        }
    }
    /// (label, percent, "今天 18:40 重置") — drawn as stacked bars like claude.ai's Usage page (a third while the Sonnet-only week holds you back).
    var meters: [(String, Double?, String)] = []
    /// ChatGPT's, drawn as a column of their own next to Claude's (each marked when both are there).
    var gptMeters: [(String, Double?, String)] = []
    var usageHint = ""
    var liveText = "" { didSet { if liveText != oldValue { needsLayout = true } } }      // (buttons may make room for it)
    /// The status says something's off (not synced, Claude closed, archiving): it keeps its room before the meters.
    var liveImportant = false
    /// Shorter ways to say `liveText`, in order, for a narrow window: an important status is shortened rather than
    /// left out. The first still says all that matters (without the chat's title; the problems without "Synced ·
    /// 12m ago"); the rest leave something out, so the counts' words go first.
    var liveShort: [String] = []
    private var liveRoom: CGFloat { liveImportant && !liveText.isEmpty ? ceil(liveText.size(Theme.ui(12)).width) + 24 : 0 }
    /// Shown on hovering `liveText`: what the status means, what it holds up, what to do.
    var liveHelp = ""
    private var liveTip: (rect: NSRect, help: NSString, tag: NSView.ToolTipTag)?   // the string is kept: tool tips don't retain it
    private var buttons: [FlatButton] = []
    var actions: [(String, Bool, () -> Void, String?)] = [] { didSet { rebuildButtons() } }
    var onSettings: (() -> Void)?
    var onLights: (() -> Void)?
    var onToggleSide: (() -> Void)?
    var onToggleTimeline: (() -> Void)?
    var onToggleTags: (() -> Void)?
    var onStats: (() -> Void)?
    /// The ▸ To-do button was clicked (it's the anchor for the list).
    var onTodo: ((NSView) -> Void)?
    /// Open to-dos (nil: none at all, so no button; 0: all ignored, a muted ▸).
    var todoCount: Int? { didSet { if todoCount != oldValue { todoBtn.isHidden = todoCount == nil; todoBtn.count = todoCount ?? 0; needsLayout = true; needsDisplay = true } } }
    private lazy var todoBtn: TodoButton = { let b = TodoButton(target: self, action: #selector(openTodo)); b.isHidden = true; return b }()
    // made with the tips `relabel` gives them (with their shortcuts; VoiceOver reads the same), so they say it from launch
    private lazy var gear = IconButton("gearshape", tip: HeaderView.gearTip()) { [weak self] in self?.onSettings?() }
    private lazy var lights = IconButton("moon", tip: HeaderView.lightsTip()) { [weak self] in self?.onLights?() }
    private lazy var sideBtn = IconButton("sidebar.left", tip: HeaderView.sideTip()) { [weak self] in self?.onToggleSide?() }
    private lazy var timelineBtn = IconButton("rectangle.bottomthird.inset.filled", tip: HeaderView.timelineTip()) { [weak self] in self?.onToggleTimeline?() }
    private lazy var tagsBtn = IconButton("tag", tip: self.tagsTip) { [weak self] in self?.onToggleTags?() }
    private lazy var statsBtn = IconButton("chart.bar.xaxis", tip: HeaderView.statsTip()) { [weak self] in self?.onStats?() }
    /// No room for the tag shelf at this size: the tag button says why (pressing it only beeps).
    var tagsNoRoom = false { didSet { if tagsNoRoom != oldValue { tagsBtn.toolTip = tagsTip } } }
    private var tagsTip: String { tr("显示 / 隐藏标签  ⌃⌘G", "Show / hide the tags  ⌃⌘G") + (tagsNoRoom ? "\n" + MainWindow.noRoomText() : "") }
    private static func gearTip() -> String { tr("设置", "Settings") }
    private static func lightsTip() -> String { tr("切换浅色 / 深色", "Switch light / dark") }
    private static func sideTip() -> String { tr("显示 / 隐藏左栏  ⌃⌘S", "Show / hide the left column  ⌃⌘S") }
    private static func timelineTip() -> String { tr("显示 / 隐藏时间轴  ⌃⌘T", "Show / hide the timeline  ⌃⌘T") }
    private static func statsTip() -> String { tr("统计  ⌘Y", "Statistics  ⌘Y") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if gear.superview == nil { [sideBtn, tagsBtn, timelineBtn, statsBtn, lights, gear, todoBtn].forEach(addSubview) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        lights.setSymbol(dark ? "sun.max" : "moon")
        gear.setSymbol("gearshape")
        sideBtn.setSymbol("sidebar.left")
        timelineBtn.setSymbol("rectangle.bottomthird.inset.filled")
        tagsBtn.setSymbol("tag")
        statsBtn.setSymbol("chart.bar.xaxis")
        needsDisplay = true
    }

    func relabel() {
        gear.toolTip = HeaderView.gearTip()
        lights.toolTip = HeaderView.lightsTip()
        sideBtn.toolTip = HeaderView.sideTip()
        timelineBtn.toolTip = HeaderView.timelineTip()
        tagsBtn.toolTip = tagsTip
        statsBtn.toolTip = HeaderView.statsTip()
        todoBtn.toolTip = TodoButton.tip()
        // its VoiceOver name is set when its count changes (Todo.swift): changed and back, it's said in the new language
        let n = todoBtn.count; todoBtn.count = n + 1; todoBtn.count = n
        todoBtn.needsDisplay = true
    }

    @objc private func openTodo() { onTodo?(todoBtn) }

    private func rebuildButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.enumerated().map { i, a in
            let b = FlatButton(a.0, warn: a.1, icon: a.3, target: self, action: #selector(tap(_:)))
            b.tag = i
            addSubview(b)
            return b
        }
        needsLayout = true
    }

    @objc private func tap(_ sender: NSButton) {
        guard sender.tag < actions.count else { return }
        actions[sender.tag].2()
    }

    override func layout() {
        super.layout()
        let midY = (bounds.height - 1) / 2
        var x = bounds.width - 14
        for b in [gear, lights, statsBtn, timelineBtn, tagsBtn, sideBtn] {
            x -= 28
            b.frame = NSRect(x: x, y: midY - 13, width: 28, height: 26)
        }
        x -= 10
        // too little room left of them for the counts (a narrow or zoomed window, archiving): the leftmost buttons that
        // are also somewhere else go first (Export… is in the menu and ⇧⌘E, ＋ Topic is ⏎ / ⇥ / a double-click, Mark all
        // read is in the menu); one that stops something stays
        // (room for the usage meters too, at their narrowest: what they say isn't anywhere else on screen)
        let need = countsEnd() + 12 + (meters.isEmpty && gptMeters.isEmpty ? 0 : 160) + liveRoom, todoW = todoBtn.isHidden ? 0 : todoBtn.intrinsicContentSize.width + 8
        var shown = buttons.map { _ in true }
        func used() -> CGFloat { zip(buttons, shown).filter(\.1).reduce(todoW) { $0 + $1.0.intrinsicContentSize.width + 8 } }
        for i in buttons.indices where i < actions.count && !actions[i].1 && x - used() < need { shown[i] = false }
        for (i, b) in buttons.enumerated().reversed() {
            b.isHidden = !shown[i]
            guard shown[i] else { continue }
            let s = b.intrinsicContentSize
            x -= s.width
            b.frame = NSRect(x: x, y: midY - s.height / 2, width: s.width, height: s.height)
            x -= 8
        }
        if !todoBtn.isHidden {
            let s = todoBtn.intrinsicContentSize
            x -= s.width
            todoBtn.frame = NSRect(x: x, y: midY - s.height / 2, width: s.width, height: s.height)
        }
    }

    /// What the menu bar and the top bar count, from the store (the same numbers in both).
    func show(counts c: (run: Int, sure: Int, unread: Int, needs: Int)) {
        running = c.run
        runningUnsure = c.sure < c.run
        runningSeen = c.sure
        unread = c.unread
        needs = c.needs
    }

    /// The red count as it's drawn: "!" first while one of them waits for you, as in the menu bar.
    var unreadText: String { (needs > 0 ? "!" : "") + String(unread) }

    /// Where the logo, the name and the two counts with their words (or the pills alone) end, as `draw` lays them out.
    private func countsEnd(words: Bool = true) -> CGFloat {
        var x: CGFloat = 48 + ceil("KIKUmap".size(Theme.ui(15, .semibold)).width) + 22
        let f = Theme.mono(12.5, .bold)
        for (n, label) in [(running, tr("在跑", "Running")), (unread, tr("未读", "Unread"))] {
            let w = label == tr("未读", "Unread") ? max(24, ceil(unreadText.size(f).width) + 14)
                : max(24, ceil((n > 99 ? "99+" : String(n)).size(f).width) + 10) + (runningUnsure ? 2 + ceil("?".size(f).width) : 0)
            x += words ? w + 6 + ceil(label.size(Theme.ui(12.5, .medium)).width) + 16 : w + 10
        }
        return x - (words ? 16 : 10)
    }

    /// The first of `texts` that fits in `width`; else the last one, cut short with "…".
    static func fit(_ texts: [String], _ font: NSFont, _ width: CGFloat) -> String {
        func w(_ t: String) -> CGFloat { ceil(t.size(font).width) }
        if let t = texts.first(where: { w($0) <= width }) { return t }
        guard let last = texts.last else { return "" }
        var n = last.count
        while n > 1 && w(String(last.prefix(n)) + "…") > width { n -= 1 }
        return String(last.prefix(n)) + "…"
    }

    /// A count pill: outlined (running) or solid (unread; `bang`: "!" first, one of them waits for you).
    static func drawCount(_ n: Int, solid: Bool, at x: CGFloat, midY: CGFloat, font: NSFont, unsure: Bool = false, bang: Bool = false) -> CGFloat {
        let s = (bang ? "!" : "") + String(n) + (unsure ? "?" : "")
        let w = max(24, ceil(s.size(font).width) + 14)
        let r = NSRect(x: x, y: midY - 11, width: w, height: 22)
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 10.25, yRadius: 10.25)
        // waiting for you uses the same red badge as the menu bar (only when there is something)
        let red = solid && n > 0
        if solid { (red ? Theme.unread : Theme.ink).setFill(); p.fill() } else { Theme.ink.setStroke(); p.lineWidth = 1.5; p.stroke() }
        let ns = s.size(font)
        (s as NSString).draw(at: NSPoint(x: r.midX - ns.width / 2, y: r.midY - ns.height / 2),
                             withAttributes: [.font: font, .foregroundColor: red ? NSColor.white : (solid ? Theme.bg : Theme.ink)])
        return w
    }

    override func draw(_ dirtyRect: NSRect) { drawBar(wordsAllowed: true) }

    /// The bar, the counts' words beside their pills where there's room for them (`wordsAllowed` false: never).
    private func drawBar(wordsAllowed: Bool) {
        Theme.bg.setFill(); bounds.fill()
        Theme.faint.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let mid = (bounds.height - 1) / 2
        Logo.draw(in: NSRect(x: 16, y: mid - 12, width: 24, height: 24))
        var x: CGFloat = 48
        let tf = Theme.ui(15, .semibold)
        let title = "KIKUmap"
        let ts = title.size(tf)
        (title as NSString).draw(at: NSPoint(x: x, y: mid - ts.height / 2), withAttributes: [.font: tf, .foregroundColor: Theme.ink])
        x += ts.width + 22
        let small = Theme.ui(12)
        let limit = (todoBtn.isHidden ? (buttons.first(where: { !$0.isHidden })?.frame.minX ?? sideBtn.frame.minX) : todoBtn.frame.minX) - 12
        // an important status (archiving, a sync problem) goes before the meters, and before the counts' words: beside
        // the words, whole or in its first fewer words (that still say everything that matters); else beside the pills
        // alone, shorter still or cut short if it must be, never left out
        var live = ""
        if liveImportant && !liveText.isEmpty {
            let texts = [liveText] + liveShort
            live = texts.prefix(2).first { ceil($0.size(small).width) <= limit - countsEnd() - 12 }
                ?? HeaderView.fit(texts, small, limit - countsEnd(words: false) - 12)
        }
        let liveW: CGFloat = live.isEmpty ? 0 : ceil(live.size(small).width) + 16
        // still no room for the words beside the counts: the pills alone (their shapes say which is which)
        let words = wordsAllowed && countsEnd() + (live.isEmpty ? 0 : 12 + liveW) <= limit
        for (n, label, solid) in [(running, tr("在跑", "Running"), false), (unread, tr("未读", "Unread"), true)] {
            var w: CGFloat
            if solid {
                w = HeaderView.drawCount(n, solid: true, at: x, midY: mid, font: Theme.mono(12.5, .bold), bang: needs > 0)
            } else {
                // running: the number in a ring, as in the menu bar ("?" after it for some out of sight)
                let f = Theme.mono(12.5, .bold), s = n > 99 ? "99+" : String(n)
                let d = max(24, ceil(s.size(f).width) + 10)
                ringRect = NSRect(x: x, y: mid - d / 2, width: d, height: d)
                Theme.drawRunCount(s, in: ringRect, ink: Theme.ink, arc: Theme.running, font: f, phase: runningSeen > 0 ? ringPhase : nil)
                w = d
                if runningUnsure {
                    let qs = "?".size(f)
                    ("?" as NSString).draw(at: NSPoint(x: x + d + 2, y: mid - qs.height / 2), withAttributes: [.font: f, .foregroundColor: Theme.ink])
                    w += 2 + ceil(qs.width)
                }
            }
            guard words else { x += w + 10; continue }
            let lf = Theme.ui(12.5, .medium)
            let ls = label.size(lf)
            (label as NSString).draw(at: NSPoint(x: x + w + 6, y: mid - ls.height / 2), withAttributes: [.font: lf, .foregroundColor: Theme.ink])
            x += w + 6 + ls.width + 16
        }
        // Claude's usage, then ChatGPT's beside it; with ChatGPT's there, every row carries its service's mark (as in
        // the widget). A narrower window gets shorter bars and reset times, then none (the tool tip has them all),
        // then one column with each service's fullest meter, as the small widget does.
        typealias Row = (m: (String, Double?, String), gpt: Bool)
        let all: [[Row]] = [meters.map { ($0, false) }, gptMeters.map { ($0, true) }].filter { !$0.isEmpty }
        let fullest: [[Row]] = all.isEmpty ? [] : [all.compactMap { c in c.max { ($0.m.1 ?? -1) < ($1.m.1 ?? -1) } }]
        let marked = !gptMeters.isEmpty
        let lf = Theme.ui(11, .medium), pf = Theme.mono(11, .medium), bf = Theme.mono(11, .bold)
        let markW: CGFloat = marked ? ceil(max(Theme.claudeTag(Theme.muted, height: 10).size.width, GPTWatcher.mark(Theme.muted, height: 10).size.width)) + 5 : 0
        func value(_ m: (String, Double?, String), _ when: Int) -> String {
            let p = m.1.map { "\(Int($0.rounded()))%" } ?? "–"
            // (numbers from an earlier read never pass for current ones: "as of …", or where that won't fit "old",
            // and they're drawn dimmed)
            let t = when == 0 ? m.2 : when == 1 ? HeaderView.shortWhen(m.2) : HeaderView.isAsOf(m.2) ? tr("旧数据", "old") : ""
            return t.isEmpty ? p : p + "  " + t
        }
        typealias Fit = (columns: [[Row]], bar: CGFloat, when: Int, labels: Bool)
        func labelW(_ rs: [Row], _ f: Fit) -> CGFloat { f.labels ? ceil(rs.map { $0.m.0.size(lf).width }.max() ?? 0) + 8 : 0 }
        func width(_ rs: [Row], _ f: Fit) -> CGFloat {
            markW + labelW(rs, f) + f.bar + 8 + ceil(rs.map { value($0.m, f.when).size(bf).width }.max() ?? 0)
        }
        func total(_ f: Fit) -> CGFloat { f.columns.enumerated().reduce(0) { $0 + width($1.element, f) + ($1.offset > 0 ? 18 : 0) } }
        let fits: [Fit] = [(all, 90, 0, true), (all, 64, 1, true), (all, 48, 2, true), (fullest, 48, 2, true), (fullest, 40, 2, false)]
        let fitted = fits.first { total($0) <= limit - liveW - x }
        // the meters come before the counts' words (what they say isn't anywhere else on screen): with no room for
        // them beside the words but room beside the pills alone, the bar is drawn again without the words
        if fitted == nil, words, !all.isEmpty, fits.contains(where: { total($0) <= limit - liveW - countsEnd(words: false) - 10 }) {
            return drawBar(wordsAllowed: false)
        }
        let fit = fitted ?? ([], 0, 2, false)
        let meterStart = x
        for rs in fit.columns {
            let lw = labelW(rs, fit)
            var maxW: CGFloat = 0
            for (i, row) in rs.enumerated() {
                let (m, gpt) = row
                let cy = rs.count == 1 ? mid : rs.count == 2 ? mid + (i == 0 ? -8 : 8) : mid + CGFloat(i - 1) * 12
                if marked {
                    let img = gpt ? GPTWatcher.mark(Theme.muted, height: 10) : Theme.claudeTag(Theme.muted, height: 10)
                    img.draw(in: NSRect(x: x, y: cy - 5, width: img.size.width, height: 10))
                }
                let lx = x + markW
                if fit.labels {
                    let ls = m.0.size(lf)
                    (m.0 as NSString).draw(at: NSPoint(x: lx, y: cy - ls.height / 2), withAttributes: [.font: lf, .foregroundColor: Theme.muted])
                }
                let bx = lx + lw
                let track = NSRect(x: bx, y: cy - 2, width: fit.bar, height: 4)
                Theme.faint.setFill(); NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
                let old = HeaderView.isAsOf(m.2)
                let high = (m.1 ?? 0) >= 90 && !old
                if let p = m.1 {
                    let f = CGFloat(min(max(p, 0), 100) / 100)
                    (old ? Theme.muted : Theme.ink).setFill()
                    NSBezierPath(roundedRect: NSRect(x: bx, y: track.minY, width: max(4, fit.bar * f), height: 4), xRadius: 2, yRadius: 2).fill()
                }
                let t = value(m, fit.when)
                let font = high ? bf : pf
                let ts = t.size(font)
                (t as NSString).draw(at: NSPoint(x: bx + fit.bar + 8, y: cy - ts.height / 2),
                                     withAttributes: [.font: font, .foregroundColor: high ? Theme.ink : Theme.muted])
                maxW = max(maxW, markW + lw + fit.bar + 8 + ts.width)
            }
            x += maxW + 18
        }
        // no room for any meter at all: their tip goes on the counts, so the usage is still a hover away
        let countsStart = 48 + ts.width + 22
        let countsRect = NSRect(x: countsStart, y: 4, width: max(0, countsEnd(words: words) - countsStart), height: bounds.height - 9)
        setMetersTip(fit.columns.isEmpty ? countsRect : NSRect(x: meterStart, y: 4, width: x - 18 - meterStart, height: bounds.height - 9))
        if !fit.columns.isEmpty { x += 4 }
        var liveRect: NSRect?
        for text in [usageHint, live.isEmpty ? liveText : live] where !text.isEmpty {
            let s = text.size(small)
            guard x + s.width <= limit + 1 || text == live else { break }
            let warn = text.hasPrefix("⚠︎")
            (text as NSString).draw(at: NSPoint(x: x, y: mid - s.height / 2), withAttributes: [.font: small, .foregroundColor: warn ? Theme.ink : Theme.muted])
            if text == liveText || text == live { liveRect = NSRect(x: x, y: mid - s.height / 2, width: s.width, height: s.height) }
            x += s.width + 16
        }
        setLiveTip(liveRect)
    }

    static func isAsOf(_ s: String) -> Bool { s.hasPrefix("as of ") || s.hasSuffix(" 时的数据") }

    /// "resets Tue 23:59" → "Tue 23:59" (an "as of" stays as it is: it says the numbers are old).
    static func shortWhen(_ s: String) -> String {
        if s.hasPrefix("resets ") { return String(s.dropFirst(7)) }
        if s.hasSuffix(" 重置") { return String(s.dropLast(3)) }
        return s
    }

    /// Every meter in full, by service: what a narrow window leaves out, and whose each row is.
    private var metersHelp: String {
        func lines(_ name: String, _ ms: [(String, Double?, String)]) -> [String] {
            ms.isEmpty ? [] : [name] + ms.map { "  " + $0.0 + "  " + ($0.1.map { "\(Int($0.rounded()))%" } ?? "–") + ($0.2.isEmpty ? "" : " · " + $0.2) }
        }
        return (lines("Claude", meters) + lines("ChatGPT", gptMeters)).joined(separator: "\n")
    }
    private var metersTip: (rect: NSRect, help: NSString, tag: NSView.ToolTipTag)?
    private func setMetersTip(_ r: NSRect?) {
        let help = metersHelp
        if let t = metersTip, t.rect == r, t.help as String == help { return }
        if let t = metersTip { removeToolTip(t.tag) }
        metersTip = nil
        guard let r = r, !help.isEmpty else { return }
        let s = help as NSString
        metersTip = (r, s, addToolTip(r, owner: s, userData: nil))
    }

    private func setLiveTip(_ r: NSRect?) {
        if let t = liveTip, t.rect == r, t.help as String == liveHelp { return }
        if let t = liveTip { removeToolTip(t.tag) }
        liveTip = nil
        guard let r = r, !liveHelp.isEmpty else { return }
        let help = liveHelp as NSString
        liveTip = (r, help, addToolTip(r.insetBy(dx: -4, dy: -8), owner: help, userData: nil))
    }
}

/// Left column: chats that aren't on the map yet. Drag them onto a topic.
@MainActor
final class SidebarView: NSView, NSDraggingSource {
    let store: Store
    let usage: UsageMonitor
    var onOpen: ((String) -> Void)?
    var onArchive: ((String) -> Void)?
    var onOpenRoutines: (() -> Void)?
    /// Read Claude and ChatGPT again now (the button by the heading, ⌘R).
    var onRefresh: (() -> Void)?
    private var rows: [Chat] = []
    /// How many there are in all (`rows` is narrowed to what the search field holds).
    private var allCount = 0
    /// Every chat the list has, in its order, searched away or not.
    private var listed: [String] = []
    private var query = ""
    private lazy var search: NSSearchField = {
        let f = NSSearchField()
        f.controlSize = .small
        f.font = Theme.ui(12)
        f.sendsSearchStringImmediately = true
        f.target = self
        f.action = #selector(searched(_:))
        return f
    }()
    private lazy var refresh = IconButton("arrow.clockwise", tip: "") { [weak self] in self?.onRefresh?() }
    private var sched: [(Routine, Date)] = []
    /// No scheduled-task list to go by, and it can't be read now: said where the tasks would be, with why.
    private var schedNote: String?
    private var placed = Set<String>()
    private let schedRowH: CGFloat = 42
    /// The row the keys move from (⏎ opens it, ⇧ ranges from it); with several picked, one of them.
    private var sel: String? { didSet { if let s = sel { noteOrder([s]) } } }
    /// Several rows picked at once (⌘-click, ⇧-click); dragging one of them takes them all to the map. A row only
    /// searched away stays picked, for when the search is cleared (as it stays selected on the map).
    private var picked = Set<String>()
    /// The order rows were picked in, the latest last (the lead goes there whenever it's set): when the lead is
    /// taken out of the pick, the keys go to the one picked most recently of those left, as on the map.
    private var pickOrder: [String] = []
    private func noteOrder(_ ids: [String]) { pickOrder.removeAll { ids.contains($0) }; pickOrder.append(contentsOf: ids) }
    /// Of the rows picked, the one picked last (the first in the list's order if none of them is known).
    private func latestPicked() -> String? { pickOrder.last { picked.contains($0) } ?? listed.first { picked.contains($0) } }
    /// The rows picked by hand changed: their chats (in the order they were picked, the latest last) and the one the
    /// keys move from, so the map selects the same.
    var onPick: (([String], String?) -> Void)?
    private var pickedIDs: [String] {
        guard !picked.isEmpty else { return sel.map { [$0] } ?? [] }
        let known = pickOrder.filter { picked.contains($0) }
        return listed.filter { picked.contains($0) && !known.contains($0) } + known
    }
    private func pickedChanged() { onPick?(pickedIDs, sel) }
    /// What's picked now: the chats, and the one the keys move from.
    var pick: (ids: [String], lead: String?) { (pickedIDs, sel) }

    /// Picks the rows of these chats (the map selected them, `ids` in the order it did, the latest last), without
    /// telling the map back; the lead one comes into view. Chats this list doesn't have (not pinned) aren't picked;
    /// ones only searched away are, for when the search is cleared.
    func show(picked ids: [String], lead: String?) {
        let have = Set(listed)
        let shown = ids.filter { have.contains($0) }
        let newSel = lead.flatMap { have.contains($0) ? $0 : nil } ?? shown.last
        let newPicked: Set<String> = shown.count > 1 ? Set(shown) : []
        noteOrder(shown)
        guard newSel != sel || newPicked != picked else { return }
        sel = newSel
        picked = newPicked
        if let s = sel, let n = rows.firstIndex(where: { $0.id == s }) {
            scrollToVisible(NSRect(x: 0, y: top + CGFloat(n) * rowH - 8, width: bounds.width, height: rowH + 16))
        }
        needsDisplay = true
    }
    /// A plain click on one of the picked rows picks just it — unless the click turns into a drag.
    private var narrowOnUp: String?
    /// A plain click tells the map on mouse-up, unless it turned into a drag.
    private var syncOnUp = false
    private var pressed: (id: String, at: NSPoint)?
    private var dropOn = false
    private let rowH: CGFloat = 34
    private let top: CGFloat = 94
    /// Spinner phase for running chats (0…1), driven by the map's animation timer.
    var phase: CGFloat = 0
    /// What's being read, when it was and when it will be next (a heading and a line per app): shown in full
    /// while the list is empty, and on hovering the heading.
    var status: (() -> (title: String, lines: [String]))?
    private var statusTick: Timer?
    private var runTick: Timer?

    /// Just the running rows are redrawn, and only while the window can be seen.
    private func moveRunning() {
        guard window?.isVisible == true, window?.occlusionState.contains(.visible) == true else { return }
        for (i, c) in rows.enumerated() where store.isRunning(c.id) && !store.outOfSight(c.id) {
            setNeedsDisplay(NSRect(x: 6, y: top + CGFloat(i) * rowH - 4, width: bounds.width - 12, height: rowH + 4))
        }
    }

    init(store: Store, usage: UsageMonitor) {
        self.store = store
        self.usage = usage
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 600))
        registerForDraggedTypes([dragType])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func reload() {
        let all = store.pinnedList()
        allCount = all.count
        listed = all.map(\.id)
        rows = query.isEmpty ? all : all.filter { c in
            [store.name(c.id), c.title].contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        }
        // while the list is empty its status counts down to the next read, so it redraws every second (and when that
        // makes it a line longer or shorter, what's under it moves with it)
        if all.isEmpty, statusTick == nil {
            statusTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if self?.window?.isVisible == true { self?.statusTicked() } }
            }
        } else if !all.isEmpty {
            statusTick?.invalidate(); statusTick = nil
        }
        // a row seen running has an orange stretch going round it, as on the map: redrawn every frame while one does
        let moving = rows.contains { store.isRunning($0.id) && !store.outOfSight($0.id) }
        if moving, runTick == nil {
            runTick = Timer.scheduledTimer(withTimeInterval: Theme.turnFrame, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.moveRunning() }
            }
        } else if !moving {
            runTick?.invalidate(); runTick = nil
        }
        if search.superview == nil { addSubview(search); addSubview(refresh) }
        search.placeholderString = tr("搜索左栏", "Search the list")
        refresh.toolTip = tr("马上刷新：重新看一遍 Claude 和 ChatGPT  ⌘R", "Refresh now: check Claude and ChatGPT again  ⌘R")
        // a picked chat that isn't listed at all any more (unpinned, ChatGPT switched off) isn't picked; one only
        // searched away stays picked for when the search is cleared (the lead, and the others picked with it)
        let have = Set(listed)
        if let s = sel, !have.contains(s) { sel = nil }
        picked.formIntersection(have)
        pickOrder.removeAll { !have.contains($0) }
        if sel == nil, !picked.isEmpty { sel = latestPicked() }
        placed = store.map.placedChats()
        sched = TimelineView.upcoming(usage.routines)
        schedNote = usage.routinesUnknown.map { tr("没同步：", "Not synced: ") + $0 }
        let visible = enclosingScrollView?.contentView.bounds.size ?? NSSize(width: 270, height: 0)
        // (with nothing pinned, the Scheduled section goes below the status, however many lines it wraps to)
        statusH = statusHeight(visible.width)
        let content = schedTop + (sched.isEmpty && schedNote == nil ? 0 : 30 + CGFloat(sched.count) * schedRowH + schedNoteHeight(visible.width)) + 20
        setFrameSize(NSSize(width: visible.width, height: max(content, visible.height)))
        // hovering the heading: what's being read and when; a row whose name or status is cut short: both in full
        removeAllToolTips()
        addToolTip(NSRect(x: 0, y: 0, width: bounds.width - 44, height: 54), owner: self, userData: nil)
        for (i, c) in rows.enumerated() where rowLayout(c, in: rowRect(i)).cut { addToolTip(rowRect(i), owner: self, userData: nil) }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        refresh.frame = NSRect(x: bounds.width - 40, y: 9, width: 28, height: 26)
        search.frame = NSRect(x: 12, y: 60, width: bounds.width - 24, height: 22)
    }

    /// Reading again now: the button says so.
    func spinRefresh() { refresh.spin("arrow.clockwise") }

    @objc private func searched(_ f: NSSearchField) {
        let q = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard q != query else { return }
        query = q
        reload()
    }

    override func draw(_ dirtyRect: NSRect) {
        (dropOn ? Theme.faint : Theme.paper).setFill()
        bounds.fill()
        let hf = Theme.ui(14, .semibold)
        let head = tr("置顶对话", "Pinned")
        (head as NSString).draw(at: NSPoint(x: 16, y: 14), withAttributes: [.font: hf, .foregroundColor: Theme.ink])
        let n = query.isEmpty ? String(rows.count) : "\(rows.count)/\(allCount)"
        (n as NSString).draw(at: NSPoint(x: 16 + head.size(hf).width + 8, y: 15), withAttributes: [.font: Theme.mono(12.5, .medium), .foregroundColor: Theme.muted])
        (tr("置顶对话和会话 · 拖到导图上", "Pins and sessions · drag to the map") as NSString).draw(at: NSPoint(x: 16, y: 37), withAttributes: [.font: Theme.ui(11.5), .foregroundColor: Theme.muted])
        if allCount > 0 && rows.isEmpty {
            let a: [NSAttributedString.Key: Any] = [.font: Theme.ui(12), .foregroundColor: Theme.muted]
            let q = query.count > 14 ? String(query.prefix(14)) + "…" : query
            let line = tr("没有名字里带「\(q)」的", "Nothing here has “\(q)” in its name")
            (line as NSString).draw(with: NSRect(x: 18, y: top + 6, width: bounds.width - 36, height: 54), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
        } else if rows.isEmpty {
            for line in statusLayout(bounds.width) {
                (line.text as NSString).draw(with: line.rect, options: .usesLineFragmentOrigin, attributes: line.attrs)
            }
        }
        for (i, c) in rows.enumerated() {
            let r = rowRect(i)
            // a row's picked ring and red dot reach past it into the gap between rows, which a neighbour's redraw
            // (a running row's turning stretch, many times a second) clears: drawn again whenever they're touched
            guard r.insetBy(dx: -8, dy: -8).intersects(dirtyRect) else { continue }
            let selected = sel == c.id || picked.contains(c.id)
            if selected {
                let b = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: 0), xRadius: 6, yRadius: 6)
                Theme.hover.setFill(); b.fill()
            }
            // filed on the map: a short bar in its branch colour
            if placed.contains(c.id) {
                (store.branchColor(c.id) ?? Theme.line).setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX - 6, y: r.minY + 7, width: 2.5, height: r.height - 14), xRadius: 1.2, yRadius: 1.2).fill()
            }
            let state = store.isRunning(c.id) ? 2 : (store.isUnread(c) ? 1 : 0)
            // as on the map: running, an outline with an orange stretch going round it while it's seen running;
            // finished and unread, solid with a red dot on its corner
            var ink = Theme.ink, faded = Theme.muted
            if state > 0 {
                let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: r.height / 2, yRadius: r.height / 2)
                if state == 1 {
                    Theme.ink.setFill(); pill.fill()
                    ink = Theme.bg; faded = Theme.bg.withAlphaComponent(0.75)
                } else {
                    let seen = !store.outOfSight(c.id)
                    Theme.paper.setFill(); pill.fill()
                    (seen ? Theme.ink.withAlphaComponent(0.35) : Theme.ink).setStroke(); pill.lineWidth = 1.5; pill.stroke()
                    if seen {
                        let b = r.insetBy(dx: 0.75, dy: 0.75)
                        Theme.drawSnake(pill, perimeter: 2 * (b.width - b.height) + .pi * b.height, color: Theme.running, lineWidth: 2)
                    }
                }
            }
            // picked: the blue ring the map uses too (paler while the list isn't what the keys go to)
            if selected {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: (r.height + 4) / 2, yRadius: (r.height + 4) / 2)
                Theme.pickRing(focused: window?.isKeyWindow == true && window?.firstResponder === self).setStroke()
                ring.lineWidth = 2; ring.stroke()
            }
            // where it lives, before the name: Claude's mark, a terminal for Claude Code, "GPT" for ChatGPT
            // (a session in an editor or a terminal: a terminal first; then whose AI it is, for every chat)
            let lay = rowLayout(c, in: r)
            if c.isCode || c.isCodexSession, let img = SidebarView.terminal(faded) {
                img.draw(in: NSRect(x: r.minX + 12, y: r.midY - 6, width: 14, height: 12))
            }
            let tag = c.isGPT ? GPTWatcher.mark(faded, height: 12) : Theme.claudeTag(faded, height: 12)
            tag.draw(in: NSRect(x: lay.nameX - 5 - tag.size.width, y: r.midY - 6, width: tag.size.width, height: 12))
            // the name, then the status at the right end: never over the name or the marks (cut short instead)
            let tf = lay.font
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
            let th = ceil(tf.ascender - tf.descender + tf.leading)
            (lay.name as NSString).draw(with: NSRect(x: lay.nameX, y: r.midY - th / 2, width: lay.nameW, height: th),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: tf, .foregroundColor: ink, .paragraphStyle: p])
            let tc: NSColor = state > 0 ? ink : faded
            let ts = lay.status.size(SidebarView.statusFont)
            (lay.status as NSString).draw(at: NSPoint(x: r.maxX - 12 - ceil(ts.width), y: r.midY - ts.height / 2),
                                          withAttributes: [.font: SidebarView.statusFont, .foregroundColor: tc])
            if state == 1 {
                // a red dot on its top corner, like the menu bar's badge
                let d = NSPoint(x: r.maxX - 3, y: r.minY + 2)
                Theme.paper.setFill(); NSBezierPath(ovalIn: NSRect(x: d.x - 6.5, y: d.y - 6.5, width: 13, height: 13)).fill()
                Theme.unread.setFill(); NSBezierPath(ovalIn: NSRect(x: d.x - 5, y: d.y - 5, width: 10, height: 10)).fill()
            }

        }
        drawSchedule(dirtyRect)
    }

    /// Scheduled tasks follow the inbox (with nothing pinned, the status in its place, however many lines it takes).
    private var schedTop: CGFloat { top + max(CGFloat(max(rows.isEmpty ? 4 : 1, rows.count)) * rowH, statusH) + 22 }

    /// How far down from the list's top the status reaches while nothing is pinned (0 otherwise): measured as the
    /// list is laid out, and again whenever its countdown makes it longer or shorter.
    private var statusH: CGFloat = 0

    /// While nothing is pinned: the status (what's being read and when, a heading and a line per app), each line
    /// where it goes in a column this wide (they wrap).
    private func statusLayout(_ width: CGFloat) -> [(text: String, attrs: [NSAttributedString.Key: Any], rect: NSRect)] {
        guard allCount == 0, let st = status?() else { return [] }
        var y = top + 6
        let w = width - 36
        return ([st.title] + st.lines).enumerated().map { i, line in
            let a: [NSAttributedString.Key: Any] = [.font: i == 0 ? Theme.ui(13, .semibold) : Theme.ui(11.5),
                                                    .foregroundColor: i == 0 ? Theme.ink : Theme.muted]
            let h = ceil((line as NSString).boundingRect(with: NSSize(width: w, height: 2000), options: .usesLineFragmentOrigin, attributes: a).height)
            defer { y += h + (i == 0 ? 8 : 5) }
            return (line, a, NSRect(x: 18, y: y, width: w, height: h))
        }
    }
    private func statusHeight(_ width: CGFloat) -> CGFloat { statusLayout(width).last.map { $0.rect.maxY + 2 - top } ?? 0 }
    /// A second on, while nothing is pinned: the status redrawn (it counts down); a line longer or shorter, what's
    /// under it moves with it.
    private func statusTicked() { if statusHeight(bounds.width) != statusH { reload() } else { needsDisplay = true } }

    private func rowRect(_ i: Int) -> NSRect { NSRect(x: 10, y: top + CGFloat(i) * rowH, width: bounds.width - 20, height: rowH - 4) }

    static let statusFont = Theme.ui(11.5)
    static let statusGap: CGFloat = 6
    /// A status this wide or less is short: a time, "running", "not synced", "stopped" (the widest, "not synced" and
    /// "2025/12/31", take 61 pt). It's never cut: cut, it reads wrong ("2025/1…" reads as January).
    static let shortStatus: CGFloat = 64

    /// A row: where its name starts (after its marks), the name's font, and how the name and the status share the
    /// room up to the row's right end; `full` is the status in full, `cut` says either doesn't show whole.
    private func rowLayout(_ c: Chat, in r: NSRect) -> (nameX: CGFloat, font: NSFont, name: String, nameW: CGFloat, status: String, full: String, cut: Bool) {
        let state = store.isRunning(c.id) ? 2 : (store.isUnread(c) ? 1 : 0)
        let font = Theme.ui(13, state > 0 ? .semibold : .regular)
        let tag = c.isGPT ? GPTWatcher.mark(Theme.muted, height: 12) : Theme.claudeTag(Theme.muted, height: 12)
        let nameX = r.minX + 12 + (c.isCode || c.isCodexSession ? 19 : 0) + tag.size.width + 5
        let name = store.name(c.id), full = store.timeLabel(c)
        var shorter = SidebarView.shorter(full)
        // stopped on an error, said in Claude's words (Claude Code's after "stopped:"): "stopped" where they don't fit
        if let n = c.last_note, n.hasPrefix(Store.stopMark) {
            let t = Store.stopText(n)
            if full == t || full == String(t.prefix(33)) + "…" { shorter = [tr("出错停下", "stopped")] }
        }
        let s = SidebarView.share(name: name, font, status: full, shorter: shorter, room: r.maxX - 12 - nameX)
        return (nameX, font, name, s.nameW, s.status, full, s.cut)
    }

    /// How a row's name and status share `room`: both whole if they fit, or the name whole beside a shorter way to
    /// say the status; else the status gets 45 % of the room at most, said a shorter way (so a long one, Claude's
    /// words, an error or a wait, never pushes the name out or runs over the marks before it), and the name is cut
    /// short in the rest. A short status (`shortStatus`, or half the room) is never cut: where even its shortest way
    /// doesn't fit that 45 %, it shows whole and the name has the rest. Only a long one with no short way to say it
    /// would be cut with "…". `cut`: either one doesn't show whole (the row's tooltip then has both).
    static func share(name: String, _ nameFont: NSFont, status: String, shorter: [String], room: CGFloat) -> (status: String, nameW: CGFloat, cut: Bool) {
        func w(_ s: String) -> CGFloat { ceil(s.size(statusFont).width) }
        let nw = ceil(name.size(nameFont).width), forms = [status] + shorter
        if let s = forms.first(where: { nw + statusGap + w($0) <= room }) { return (s, room - statusGap - w(s), s != status) }
        let cap = max(floor(room * 0.45), 48)
        let s = forms.first(where: { w($0) <= cap })
            ?? forms.last.flatMap { w($0) <= max(shortStatus, floor(room / 2)) ? $0 : nil }
            ?? HeaderView.fit(forms, statusFont, cap)
        return (s, max(0, room - statusGap - w(s)), true)
    }

    /// Shorter ways to say a status (`Store.timeLabel`), for a row with little room (an error stop's: see `rowLayout`);
    /// the others are short (a time, "running", "not synced") and show whole. The "?" stays: unsure, as in "running?".
    static func shorter(_ status: String) -> [String] {
        switch status {
        case tr("可能在等你", "maybe waiting for you"): return [tr("等你？", "maybe waiting"), tr("等你？", "waiting?")]
        case tr("等你确认", "waiting for you"): return [tr("等你", "waiting")]
        default:
            // a Codex task gone quiet: that it has, without since when
            return status.hasPrefix("quiet since ") || status.hasSuffix(" 起没动静") ? [tr("没动静", "quiet")] : []
        }
    }

    /// The not-synced note's height in a column this wide (it wraps).
    private func schedNoteHeight(_ width: CGFloat) -> CGFloat {
        guard let n = schedNote else { return 0 }
        return ceil((n as NSString).boundingRect(with: NSSize(width: width - 32, height: 200), options: .usesLineFragmentOrigin,
                                                 attributes: [.font: Theme.ui(11.5)]).height) + 4
    }

    private func drawSchedule(_ dirtyRect: NSRect) {
        guard !sched.isEmpty || schedNote != nil else { return }
        let y0 = schedTop
        Theme.faint.setFill(); NSRect(x: 16, y: y0 - 12, width: bounds.width - 32, height: 1).fill()
        let hf = Theme.ui(14, .semibold)
        let head = tr("计划任务", "Scheduled")
        (head as NSString).draw(at: NSPoint(x: 16, y: y0), withAttributes: [.font: hf, .foregroundColor: Theme.ink])
        if let n = schedNote {
            // no list to go by: not known, and why (no count)
            (n as NSString).draw(with: NSRect(x: 16, y: y0 + 26, width: bounds.width - 32, height: schedNoteHeight(bounds.width)),
                                 options: .usesLineFragmentOrigin, attributes: [.font: Theme.ui(11.5), .foregroundColor: Theme.muted])
            return
        }
        let count = String(sched.count), cf = Theme.mono(12.5, .medium), cx = 16 + head.size(hf).width + 8
        (count as NSString).draw(at: NSPoint(x: cx, y: y0 + 1), withAttributes: [.font: cf, .foregroundColor: Theme.muted])
        // a list from an earlier read: as of when (a task changed since isn't known), as the timeline says it
        if let at = usage.routinesAsOf {
            let s = tr("· \(UsageMonitor.stamp(at)) 时的列表", "· as of \(UsageMonitor.stamp(at))")
            (s as NSString).draw(at: NSPoint(x: cx + count.size(cf).width + 6, y: y0 + 2),
                                 withAttributes: [.font: Theme.ui(11.5), .foregroundColor: Theme.muted])
        }
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        for (i, (r, d)) in sched.enumerated() {
            let rr = NSRect(x: 10, y: y0 + 30 + CGFloat(i) * schedRowH, width: bounds.width - 20, height: schedRowH - 4)
            guard rr.intersects(dirtyRect) else { continue }
            // diamond, like on the timeline
            let mx = rr.minX + 5, my = rr.minY + 11
            let dp = NSBezierPath()
            dp.move(to: NSPoint(x: mx, y: my - 5)); dp.line(to: NSPoint(x: mx + 5, y: my))
            dp.line(to: NSPoint(x: mx, y: my + 5)); dp.line(to: NSPoint(x: mx - 5, y: my)); dp.close()
            (i == 0 ? Theme.ink : Theme.muted).setFill(); dp.fill()
            let tf = Theme.ui(13, i == 0 ? .semibold : .regular)
            (r.name as NSString).draw(with: NSRect(x: rr.minX + 16, y: rr.minY + 2, width: rr.width - 20, height: 18),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: tf, .foregroundColor: Theme.ink, .paragraphStyle: p])
            let when = TimelineView.dayHM(d) + " · " + Clock.countdown(d)
            (when as NSString).draw(at: NSPoint(x: rr.minX + 16, y: rr.minY + 20),
                                    withAttributes: [.font: Theme.ui(11.5), .foregroundColor: Theme.muted])
        }
    }

    private func schedRow(at p: NSPoint) -> Int? {
        let i = Int(floor((p.y - schedTop - 30) / schedRowH))
        return p.y >= schedTop + 30 && i >= 0 && i < sched.count ? i : nil
    }

    private func row(at p: NSPoint) -> Chat? {
        let i = Int(floor((p.y - top) / rowH))
        return p.y >= top && i >= 0 && i < rows.count ? rows[i] : nil
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        if schedRow(at: p) != nil { onOpenRoutines?(); return }
        guard let c = row(at: p) else { sel = nil; picked = []; pickOrder = []; needsDisplay = true; pickedChanged(); return }
        narrowOnUp = nil
        let f = e.modifierFlags
        if f.contains(.command) {
            if picked.isEmpty, let s = sel { picked = [s] }
            if picked.contains(c.id) {
                picked.remove(c.id)
                // the lead taken out: the keys go to the one picked most recently of those left (another row
                // taken out leaves the lead as it is)
                if !(sel.map(picked.contains) ?? false) { sel = latestPicked() }
            } else {
                picked.insert(c.id)
                sel = c.id
            }
        } else if f.contains(.shift), let s = sel, let a = rows.firstIndex(where: { $0.id == s }),
                  let b = rows.firstIndex(where: { $0.id == c.id }) {
            let range = rows[min(a, b)...max(a, b)].map(\.id)
            picked = Set(range)                                       // the first click stays the anchor
            noteOrder((a <= b ? range : range.reversed()).filter { $0 != s })      // (picked after it, out to this row)
        } else if picked.count > 1 && picked.contains(c.id) {
            narrowOnUp = c.id
        } else {
            pickOrder = []
            sel = c.id
            picked = []
            syncOnUp = true
        }
        needsDisplay = true
        if !syncOnUp && narrowOnUp == nil { pickedChanged() }      // ⌘- and ⇧-clicks: at once
        if e.clickCount == 2 { onOpen?(c.id); return }
        pressed = (c.id, p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let pr = pressed else { return }
        let p = convert(e.locationInWindow, from: nil)
        if hypot(p.x - pr.at.x, p.y - pr.at.y) < 5 { return }
        let ids = dragBegan(pr.id)
        let item = NSPasteboardItem()
        item.setString("side|" + ids.map { "c:" + $0 }.joined(separator: "\n"), forType: dragType)
        let di = NSDraggingItem(pasteboardWriter: item)
        let img = MapView.dragImage(ids.count == 1 ? store.name(pr.id) : tr("\(ids.count) 个对话", "\(ids.count) chats"))
        di.setDraggingFrame(NSRect(x: p.x - 20, y: p.y - img.size.height / 2, width: img.size.width, height: img.size.height), contents: img)
        beginDraggingSession(with: [di], event: e, source: self)
    }

    /// A press on row `id` became a drag: the chats it carries (the picked rows shown, in the list's order, when it's
    /// one of them). The click it began as tells the map nothing yet: a drop on the map selects them there, anything
    /// else tells it when the drag ends.
    private func dragBegan(_ id: String) -> [String] {
        pressed = nil
        narrowOnUp = nil
        tellAfterDrag = syncOnUp
        syncOnUp = false
        return picked.count > 1 && picked.contains(id) ? rows.map(\.id).filter { picked.contains($0) } : [id]
    }
    /// The drag began as a plain click, which picked its row here: the map is told of it once the drag ends.
    private var tellAfterDrag = false

    override func mouseUp(with e: NSEvent) {
        if let id = narrowOnUp { pickOrder = []; sel = id; picked = []; needsDisplay = true; pickedChanged() }
        else if syncOnUp { pickedChanged() }
        narrowOnUp = nil
        syncOnUp = false
        pressed = nil
    }

    private static func terminal(_ color: NSColor) -> NSImage? {          // built each time: follows light / dark
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let i = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude Code")?.withSymbolConfiguration(cfg) else { return nil }
        let tinted = NSImage(size: i.size, flipped: false) { r in
            i.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
        }
        return tinted
    }

    /// Claude Code sessions can be kept in the list here, so they stay after the 12 hours (a script's run: after it
    /// stops); Claude chats can be archived.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let c = row(at: convert(event.locationInWindow, from: nil)) else { return nil }
        let m = NSMenu()
        if c.isGPT {                                  // pinned or not is up to ChatGPT
            m.addItem(MenuAction(title: GPTWatcher.openLabel(c)) { [weak self] in self?.onOpen?(c.id) })
            return m
        }
        guard c.isCode else {
            m.addItem(MenuAction(title: tr("打开", "Open")) { [weak self] in self?.onOpen?(c.id) })
            m.addItem(MenuAction(title: tr("让 Claude 写总结存档…", "Archive a summary…")) { [weak self] in self?.onArchive?(c.id) })
            return m
        }
        let on = c.pinned == true
        let title = SidebarView.keepTitle(kept: on, onMap: store.map.placedChats().contains(c.id), script: c.headless == true, running: store.isRunning(c.id))
        m.addItem(MenuAction(title: title) { [weak self] in
            self?.store.setPinned(c.id, !on)
        })
        m.addItem(MenuAction(title: tr("打开", "Open")) { [weak self] in self?.onOpen?(c.id) })
        return m
    }

    /// "Keep in the list", saying what happens otherwise, as `Store.isShown` lists a session: one filed on the map stays
    /// while it's there; a script's run (`claude -p`, the SDK) leaves when it stops; the rest leave 12 hours after
    /// they're done. `kept`: it is now (the item stops keeping it).
    nonisolated static func keepTitle(kept: Bool, onMap: Bool, script: Bool, running: Bool) -> String {
        if onMap {
            return kept ? tr("不再一直留着（在导图上时仍会留着）", "Stop keeping it (it stays while it's on the map)")
                        : tr("一直留在左栏（在导图上时本来就会留着）", "Keep in the list (it stays anyway while it's on the map)")
        }
        if script {
            return kept ? running ? tr("不再一直留着（停下后就消失）", "Stop keeping it (it leaves when it stops)")
                                  : tr("不再一直留着（马上就会消失）", "Stop keeping it (it leaves right away)")
                        : tr("一直留在左栏（不然停下后就消失）", "Keep in the list (otherwise it leaves when it stops)")
        }
        return kept ? tr("不再一直留着（做完 12 小时后消失）", "Stop keeping it (it leaves 12 hours after it's done)")
                    : tr("一直留在左栏（不然做完 12 小时后会消失）", "Keep in the list (otherwise it leaves 12 hours after it's done)")
    }

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 125 where cmd: if let s = sel { onOpen?(s) }           // ⌘↓ as in Finder: open it
        case 125, 126: step(e.keyCode == 125 ? 1 : -1)              // ↓ ↑: the next row, the one before
        case 49, 36, 76:                                            // space, Return, Enter: open it
            if let s = sel { onOpen?(s) } else { super.keyDown(with: e) }
        case 53 where !picked.isEmpty: picked = []; pickOrder = sel.map { [$0] } ?? []; needsDisplay = true; pickedChanged()
        default: super.keyDown(with: e)
        }
    }

    /// The row `d` below (or above) the one picked, brought into view; the first (or last) when none is.
    private func step(_ d: Int) {
        guard !rows.isEmpty else { return }
        let i = sel.flatMap { s in rows.firstIndex { $0.id == s } }
        let n = i.map { max(0, min(rows.count - 1, $0 + d)) } ?? (d > 0 ? 0 : rows.count - 1)
        pickOrder = []
        sel = rows[n].id
        picked = []
        scrollToVisible(NSRect(x: 0, y: top + CGFloat(n) * rowH - 8, width: bounds.width, height: rowH + 16))
        needsDisplay = true
        pickedChanged()
    }

    // the picked row's ring is grey while the keys go elsewhere (another view, another window)
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let nc = NotificationCenter.default
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            nc.removeObserver(self, name: n, object: nil)
            if let w = window { nc.addObserver(self, selector: #selector(keyChanged), name: n, object: w) }
        }
    }
    @objc private func keyChanged() { needsDisplay = true }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// The drag is over without putting the rows on the map (let go over the column or the timeline, Esc): the row
    /// its click picked is picked on the map too now, as a click's mouse-up would have done.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if tellAfterDrag && operation.isEmpty { pickedChanged() }
        tellAfterDrag = false
    }

    /// The map drags by hand, so it lights this up itself when a chat would come off the map here.
    func highlightDrop(_ on: Bool) { if on != dropOn { dropOn = on; needsDisplay = true } }

    // drop a chat from the map here → take it off the map
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = sender.draggingPasteboard.string(forType: dragType)?.hasPrefix("map|c:") == true
        if ok != dropOn { dropOn = ok; needsDisplay = true }
        return ok ? .move : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropOn = false; needsDisplay = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOn = false
        guard let s = sender.draggingPasteboard.string(forType: dragType), s.hasPrefix("map|c:") else { return false }
        _ = store.map.remove(String(s.dropFirst(4)), keepChildren: false)
        store.notify()
        return true
    }
}

/// Bottom of the left column: your tags. Drag one onto an item to add it; click one to light up
/// everything that has it (click again to clear).
@MainActor
final class TagShelfView: NSView, NSDraggingSource {
    let store: Store
    var onHighlight: ((String?) -> Void)?
    var onManage: (() -> Void)?
    /// The ⌄ by the heading: tuck the shelf away (the column's foot, View → Show Tags or ⌃⌘G bring it back).
    var onHide: (() -> Void)?
    private(set) var selected: String?
    /// Nothing lit up any more (the shelf is being tucked away: no highlight left that can't be cleared).
    func clearHighlight() {
        guard selected != nil else { return }
        selected = nil
        onHighlight?(nil)
        needsDisplay = true
    }
    private lazy var hideBtn = IconButton("chevron.down", tip: tr("收起标签（拖动上边可以调高度）  ⌃⌘G", "Hide tags (drag the edge above to resize)  ⌃⌘G")) { [weak self] in self?.onHide?() }
    private var chips: [(NSRect, String?)] = []       // nil id = the "＋" chip
    private var heads: [(NSRect, String)] = []        // each category's heading (click to fold)
    private static let foldedKey = "TagShelfFolded"
    private var folded: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.foldedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.foldedKey) }
    }
    private var pressed: (id: String?, at: NSPoint)?
    private let top: CGFloat = 38, chipH: CGFloat = 20, gap: CGFloat = 4
    private let chipF = Theme.ui(11.5, .medium)

    init(store: Store) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 80))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// How far the chips are scrolled: the heading (title, hint, ⌄) is drawn there, so it stays put.
    private var stick: CGFloat { enclosingScrollView?.contentView.bounds.minY ?? 0 }

    override func layout() {
        super.layout()
        if hideBtn.superview == nil { addSubview(hideBtn) }
        hideBtn.frame = NSRect(x: bounds.width - 38, y: stick + 7, width: 28, height: 26)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = superview as? NSClipView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }
    @objc private func scrolled() { needsLayout = true; needsDisplay = true }

    private func chipW(_ t: Tag) -> CGFloat { ceil(t.name.size(chipF).width) + (t.icon == nil ? 24 : 30) }

    /// Lays out each category (a heading you can fold, then its chips) for `width`, then "＋"; returns the height needed.
    @discardableResult
    func layout(width: CGFloat) -> CGFloat {
        chips = []
        heads = []
        var x: CGFloat = 16, y = top
        func place(_ w: CGFloat, _ id: String?) {
            if x + w > width - 14 && x > 16 { x = 16; y += chipH + gap }
            chips.append((NSRect(x: x, y: y, width: w, height: chipH), id))
            x += w + gap
        }
        let hidden = folded
        for g in Tag.groups {
            let list = store.map.tags.filter { $0.category == g.key }
            guard !list.isEmpty else { continue }
            if x > 16 { x = 16; y += chipH + gap + 2 }
            heads.append((NSRect(x: 12, y: y, width: width - 24, height: 18), g.key))
            y += 20
            if hidden.contains(g.key) { continue }
            for t in list { place(min(chipW(t), width - 30), t.id) }
        }
        if x > 16 { x = 16; y += chipH + gap + 2 }
        place(26, nil)
        return y + chipH + 12
    }

    func reload() {
        if let s = selected, !store.map.tags.contains(where: { $0.id == s }) { selected = nil; onHighlight?(nil) }
        layout(width: bounds.width)
        hideBtn.toolTip = tr("收起标签（拖动上边可以调高度）  ⌃⌘G", "Hide tags (drag the edge above to resize)  ⌃⌘G")
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paper.setFill(); bounds.fill()
        defer { drawHeading() }                 // last: over any chips scrolled under it
        let tags = store.map.tags
        let f = chipF
        let hidden = folded
        for (r, key) in heads {
            guard let g = Tag.groups.first(where: { $0.key == key }) else { continue }
            let closed = hidden.contains(key)
            Icons.draw(closed ? "chevron-right" : "chevron-down", in: NSRect(x: r.minX + 3, y: r.midY - 5.5, width: 11, height: 11), color: Theme.muted, weight: 2.4)
            let n = tags.filter { $0.category == key }.count
            let s = tr(g.zh, g.en) + (closed ? " · \(n)" : "")
            let hf = Theme.ui(11, .semibold)
            (s as NSString).draw(at: NSPoint(x: r.minX + 18, y: r.midY - s.size(hf).height / 2), withAttributes: [.font: hf, .foregroundColor: Theme.muted])
        }
        for (r, id) in chips {
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
            guard let id = id, let t = tags.first(where: { $0.id == id }) else {
                Theme.line.setStroke(); p.lineWidth = 1; p.stroke()
                let plus = "＋"
                let ps = plus.size(f)
                (plus as NSString).draw(at: NSPoint(x: r.midX - ps.width / 2, y: r.midY - ps.height / 2), withAttributes: [.font: f, .foregroundColor: Theme.muted])
                continue
            }
            let c = Theme.highlight(t.color) ?? Theme.muted
            let on = selected == id
            if on { Theme.ink.setFill(); p.fill() } else { Theme.line.setStroke(); p.lineWidth = 1; p.stroke() }
            let textX: CGFloat
            if let i = t.icon {
                Icons.draw(i, in: NSRect(x: r.minX + 7, y: r.midY - 6.5, width: 13, height: 13), color: c, weight: 2.1)
                textX = r.minX + 24
            } else {
                c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 8, y: r.midY - 3.5, width: 7, height: 7)).fill()
                textX = r.minX + 18
            }
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            let th = ceil(f.ascender - f.descender + f.leading)
            (t.name as NSString).draw(with: NSRect(x: textX, y: r.midY - th / 2, width: r.maxX - textX - 6, height: th),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: f, .foregroundColor: on ? Theme.paper : Theme.ink, .paragraphStyle: para])
        }
    }

    /// The heading band (divider, title, hint) where the shelf is scrolled to, so it never scrolls away.
    private func drawHeading() {
        let y0 = stick
        Theme.paper.setFill(); NSRect(x: 0, y: y0, width: bounds.width, height: top - 4).fill()
        Theme.faint.setFill(); NSRect(x: 16, y: y0, width: bounds.width - 32, height: 1).fill()
        let hf = Theme.ui(14, .semibold)
        let head = tr("标签", "Tags")
        (head as NSString).draw(at: NSPoint(x: 16, y: y0 + 12), withAttributes: [.font: hf, .foregroundColor: Theme.ink])
        let hint = selected == nil ? tr("拖到条目上 · 点击高亮", "Drag to tag · click to highlight")
                                   : tr("再点一下取消", "Click again to clear")
        let hx = 16 + head.size(hf).width + 8
        let hp = NSMutableParagraphStyle(); hp.lineBreakMode = .byTruncatingTail
        (hint as NSString).draw(with: NSRect(x: hx, y: y0 + 14.5, width: max(0, bounds.width - 44 - hx), height: 16),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: Theme.ui(11), .foregroundColor: Theme.muted, .paragraphStyle: hp])
    }

    private func chip(at p: NSPoint) -> (NSRect, String?)? { chips.first { $0.0.contains(p) } }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if p.y < stick + top - 4 { return }                 // the heading band (its ⌄ is a button of its own)
        if let h = heads.first(where: { $0.0.contains(p) }) {
            var f = folded
            if f.remove(h.1) == nil { f.insert(h.1) }
            folded = f
            store.notify()                                  // (the shelf's height changes)
            return
        }
        guard let c = chip(at: p) else { return }
        pressed = (c.1, p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let pr = pressed, let id = pr.id, let t = store.map.tags.first(where: { $0.id == id }) else { return }
        let p = convert(e.locationInWindow, from: nil)
        if hypot(p.x - pr.at.x, p.y - pr.at.y) < 5 { return }
        pressed = nil
        let item = NSPasteboardItem()
        item.setString("tag|" + id, forType: dragType)
        let di = NSDraggingItem(pasteboardWriter: item)
        let img = MapView.dragImage("● " + t.name)
        di.setDraggingFrame(NSRect(x: p.x - 20, y: p.y - img.size.height / 2, width: img.size.width, height: img.size.height), contents: img)
        beginDraggingSession(with: [di], event: e, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        defer { pressed = nil }
        guard let pr = pressed else { return }
        guard let id = pr.id else {
            // "＋": a new tag
            if let n = TagPrompt.ask(color: store.map.nextTagColor(), window: window) {
                _ = store.map.addTag(n.name, color: n.color, icon: n.icon, group: n.group)
                store.notify()
            }
            return
        }
        selected = selected == id ? nil : id
        onHighlight?(selected)
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(MenuAction(title: tr("管理标签…", "Manage tags…")) { [weak self] in self?.onManage?() })
        m.addItem(MenuAction(title: tr("收起标签  ⌃⌘G", "Hide tags  ⌃⌘G")) { [weak self] in self?.onHide?() })
        return m
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}

/// The edge of the left column or the timeline: drag it to resize, or past a point to tuck the pane
/// away (drag it back out to bring it back). Double-click shows or hides it.
final class PaneDivider: NSView {
    let sideways: Bool
    var onDrag: ((CGFloat) -> Void)?        // the pointer in the window's content view
    var onToggle: (() -> Void)?
    var onBegin: (() -> Void)?

    init(sideways: Bool) {
        self.sideways = sideways
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: sideways ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { onToggle?() } else { onBegin?() } }
    override func mouseDragged(with e: NSEvent) {
        guard let s = superview else { return }
        let p = s.convert(e.locationInWindow, from: nil)
        onDrag?(sideways ? p.x : p.y)
    }
}

/// The map window: header, sidebar, map.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    let window: NSWindow
    let header = HeaderView()
    let sidebar: SidebarView
    let map: MapView
    let timeline: TimelineView
    let tags: TagShelfView
    private let mapScroll = NSScrollView()
    private let sideScroll = NSScrollView()
    private let store: Store
    private let hint = NSTextField(labelWithString: "")
    private let keysButton = NSButton(title: "", target: nil, action: nil)
    private let search = NSSearchField()
    private let searchCount = NSTextField(labelWithString: "")
    private let line = ColorView(Theme.faint)
    private let sideEdge = PaneDivider(sideways: true)
    private let timelineEdge = PaneDivider(sideways: false)
    /// The tag shelf scrolls when it's dragged shorter than its tags; its top edge drags (to resize, or down to tuck
    /// it away, up from the column's foot to bring it back).
    private let tagScroll = NSScrollView()
    private let tagsEdge = PaneDivider(sideways: false)
    /// The shelf's height when a drag of its edge began: a drag that ends tucking it away leaves that to come back to.
    private var tagsHeightBefore: CGFloat = 0
    /// No room for the tag shelf at this size (a short window, zoomed in): it steps aside, and showing it, tucking it
    /// away or dragging its edge only beeps (whether it's shown, and its height, stay as they were until there's room);
    /// the strip at the column's foot and the header's tag button say why.
    private(set) var tagsNoRoom = false
    /// A drag of the shelf's edge while there's no room beeps once.
    private var tagsDragBeeped = false
    static func noRoomText() -> String { tr("放不下标签：把窗口拉高，或按 ⌘- 缩小", "No room for the tags at this size: make the window taller or press ⌘-") }

    /// The few that matter most; the rest are one click away (`keysButton`).
    static func hintText() -> String {
        tr("拖动空白处框选 · 按住空格移动导图 · ⇥ 子主题 · ⏎ 同级 · ⌘F 搜索 · 右键改颜色和标签",
           "Drag empty space to select · hold space to move the map · ⇥ subtopic · ⏎ sibling · ⌘F search · right-click for colors and tags")
    }

    /// The button under the map: the map's own shortcuts (the popover), not all of them (its last button opens those).
    static func keysName() -> String { tr("导图快捷键", "Map shortcuts") }
    static func keysTitle() -> NSAttributedString {
        NSAttributedString(string: keysName(), attributes: [.font: Theme.ui(11 * Prefs.uiScale, .semibold), .foregroundColor: Theme.ink])
    }
    static func keysTip() -> String {
        tr("导图上的按键和鼠标操作；全部快捷键和演示在「设置 → 快捷键」", "The map's keys and mouse moves; all shortcuts, with demos, are in Settings → Shortcuts")
    }

    /// Settings → Shortcuts, opened from the popover's button.
    var onShowShortcuts: (() -> Void)?
    private weak var keysPopover: NSPopover?

    /// The map's shortcuts in a popover under the button: the same rows (and keycaps) as Settings → Shortcuts, which
    /// has the rest, with demos, one click away.
    @objc private func showKeys(_ sender: NSButton) {
        let stack = keysList()
        let vc = NSViewController()
        vc.view = NSView()
        vc.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -16),
        ])
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        keysPopover = pop
    }

    /// What the popover holds: the map's rows (keys, then mouse), and the button to all of them.
    private func keysList() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        let places = [ShortcutPlace.mapKeys, .mapMouse]
        let rows = ShortcutTable.all().filter { places.contains($0.place) }
        let keysW = min(200, rows.map { Keycaps.width($0.parts, .list) }.max() ?? 160)
        for place in places {
            let head = NSTextField(labelWithString: place.title)
            head.font = Theme.ui(11, .semibold)
            head.textColor = Theme.muted
            stack.addArrangedSubview(head)
            stack.setCustomSpacing(6, after: head)
            for r in rows where r.place == place {
                let keys = KeyComboView(r.parts)
                keys.translatesAutoresizingMaskIntoConstraints = false
                keys.widthAnchor.constraint(equalToConstant: keysW).isActive = true
                keys.heightAnchor.constraint(equalToConstant: 22).isActive = true
                let text = NSTextField(labelWithString: r.label)
                text.font = Theme.ui(12)
                text.textColor = Theme.ink
                let line = NSStackView(views: [keys, text])
                line.spacing = 12
                line.toolTip = r.note
                line.setAccessibilityElement(true)
                line.setAccessibilityLabel(r.label + tr("，", ", ") + Keycaps.spoken(r.parts))
                stack.addArrangedSubview(line)
            }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(12, after: last) }
        }
        let more = NSButton(title: tr("全部快捷键和演示…", "All shortcuts, with demos…"), target: self, action: #selector(openShortcuts))
        more.bezelStyle = .rounded
        stack.addArrangedSubview(more)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
    @objc private func openShortcuts() { keysPopover?.close(); onShowShortcuts?() }

    /// The button's name, hover text and what VoiceOver reads, in the app's language.
    private func relabelKeys() {
        keysButton.attributedTitle = MainWindow.keysTitle()
        keysButton.toolTip = MainWindow.keysTip()
        keysButton.setAccessibilityLabel(MainWindow.keysName())
    }

    /// The ⌘F field's hint over the map.
    static func searchHint() -> String { tr("搜索主题、对话、标签", "Search topics, chats, tags") }

    /// Language changed: refresh every fixed label.
    func relabel() {
        hint.stringValue = MainWindow.hintText()
        search.placeholderString = MainWindow.searchHint()
        relabelKeys()
        window.title = "KIKUmap"
        layoutPanes()                   // the button and the hint are sized to the new words
        header.relabel()
        reload()
    }

    init(store: Store, usage: UsageMonitor) {
        self.store = store
        sidebar = SidebarView(store: store, usage: usage)
        map = MapView(store: store)
        timeline = TimelineView(store: store, usage: usage)
        tags = TagShelfView(store: store)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "KIKUmap"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.bg
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 480)
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self

        let root = ColorView(Theme.bg)
        root.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.contentView = root
        let W: CGFloat = 1280, H: CGFloat = 800, headH: CGFloat = 56, sideW: CGFloat = 270, tlH: CGFloat = 130

        header.frame = NSRect(x: 0, y: H - headH, width: W, height: headH)
        header.autoresizingMask = [.width, .minYMargin]
        root.addSubview(header)

        sideScroll.frame = NSRect(x: 0, y: tlH, width: sideW, height: H - headH - tlH)
        sideScroll.autoresizingMask = [.height]
        sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers = true
        sideScroll.drawsBackground = false
        sideScroll.documentView = sidebar
        root.addSubview(sideScroll)

        tagScroll.frame = NSRect(x: 0, y: tlH, width: sideW, height: 80)
        tagScroll.hasVerticalScroller = true
        tagScroll.autohidesScrollers = true
        tagScroll.drawsBackground = false
        tagScroll.documentView = tags
        root.addSubview(tagScroll)
        tags.onHighlight = { [weak self] id in self?.map.highlightTag = id }
        tags.onHide = { [weak self] in self?.toggleTags() }
        // one selection across both: rows picked in the left column select their chats on the map, and the other way
        sidebar.onPick = { [weak self] ids, lead in self?.map.selectChats(ids, lead: lead) }
        map.onChatsSelected = { [weak self] ids, lead in self?.sidebar.show(picked: ids, lead: lead) }
        map.columnPick = { [weak self] in self?.sidebar.pick ?? ([], nil) }
        timeline.onHeightChange = { [weak self] in self?.layoutPanes() }
        map.onScale = { [weak self] step in self?.scaleUI(by: step) }

        line.frame = NSRect(x: sideW, y: tlH, width: 1, height: H - headH - tlH)
        line.autoresizingMask = [.height]
        root.addSubview(line)

        mapScroll.frame = NSRect(x: sideW + 1, y: tlH, width: W - sideW - 1, height: H - headH - tlH)
        mapScroll.autoresizingMask = [.width, .height]
        mapScroll.hasVerticalScroller = true
        mapScroll.hasHorizontalScroller = true
        mapScroll.autohidesScrollers = true
        mapScroll.allowsMagnification = true
        mapScroll.minMagnification = 0.4
        mapScroll.maxMagnification = 2
        mapScroll.backgroundColor = Theme.bg
        mapScroll.drawsBackground = true
        mapScroll.documentView = map
        root.addSubview(mapScroll)
        mapScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: mapScroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.map.saveViewport() }
        }

        // ⌘F: a search field over the top-right of the map
        search.frame = NSRect(x: W - 16 - 240, y: H - headH - 40, width: 240, height: 26)
        search.autoresizingMask = [.minXMargin, .minYMargin]
        search.placeholderString = MainWindow.searchHint()
        search.delegate = self
        search.isHidden = true
        searchCount.font = Theme.ui(11.5, .medium)
        searchCount.textColor = Theme.muted
        searchCount.alignment = .right
        searchCount.frame = NSRect(x: W - 16 - 240 - 90, y: H - headH - 36, width: 82, height: 16)
        searchCount.autoresizingMask = [.minXMargin, .minYMargin]
        searchCount.isHidden = true
        root.addSubview(searchCount)
        root.addSubview(search)
        map.overSidebar = { [weak self] p, isChat in
            guard let self = self else { return false }
            let inside = self.sideScroll.bounds.contains(self.sideScroll.convert(p, from: nil))
            self.sidebar.highlightDrop(inside && isChat)
            return inside
        }
        map.onMatches = { [weak self] cur, total in
            guard let self = self else { return }
            self.searchCount.stringValue = self.search.stringValue.isEmpty ? "" : (total == 0 ? tr("没有结果", "No matches") : "\(max(cur, 0)) / \(total)")
        }

        hint.stringValue = MainWindow.hintText()
        hint.font = Theme.ui(11)
        hint.textColor = Theme.muted
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: sideW + 16, y: tlH + 6, width: W - sideW - 32, height: 16)
        hint.autoresizingMask = [.width, .maxYMargin]
        keysButton.isBordered = false
        keysButton.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        keysButton.imagePosition = .imageLeading
        keysButton.contentTintColor = Theme.ink
        relabelKeys()
        keysButton.target = self
        keysButton.action = #selector(showKeys(_:))
        root.addSubview(hint)
        root.addSubview(keysButton)

        timeline.frame = NSRect(x: 0, y: 0, width: W, height: tlH)
        timeline.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(timeline)

        // the column's and the timeline's edges: drag to resize or tuck away
        sideEdge.onDrag = { [weak self] x in
            // (the width is kept as it is at 100 %: ⌘+ / ⌘- scale it with everything else)
            let s = Prefs.uiScale
            if x < 120 * s {
                if !Prefs.sideHidden { self?.tags.clearHighlight() }
                Prefs.sideHidden = true
            } else { Prefs.sideHidden = false; Prefs.sideWidth = min(440, max(200, x / s)) }
            self?.layoutPanes()
        }
        sideEdge.onToggle = { [weak self] in self?.toggleSidebar() }
        timelineEdge.onDrag = { [weak self] y in
            Prefs.timelineHidden = y < 60
            self?.layoutPanes()
        }
        timelineEdge.onToggle = { [weak self] in self?.toggleTimeline() }
        tagsEdge.onBegin = { [weak self] in
            guard let self else { return }
            self.tagsDragBeeped = false
            self.tagsHeightBefore = Prefs.tagsHidden ? Prefs.tagsHeight : self.tagScroll.frame.height / Prefs.uiScale
        }
        tagsEdge.onDrag = { [weak self] y in
            guard let self else { return }
            // no room for the shelf at this size: a drag changes nothing (it would only lose the height it was given)
            if self.tagsNoRoom {
                if !self.tagsDragBeeped { self.tagsDragBeeped = true; NSSound.beep() }
                return
            }
            let h = y - self.timeline.frame.maxY, s = Prefs.uiScale
            if h < 40 * s {
                if !Prefs.tagsHidden { self.tags.clearHighlight() }
                Prefs.tagsHidden = true
                Prefs.tagsHeight = self.tagsHeightBefore          // brought back, it comes at the height it had
                self.layoutPanes()
            } else {
                Prefs.tagsHidden = false
                Prefs.tagsHeight = h / s
                self.layoutPanes()
                // what's shown (it can't grow past its tags); never 0 (the room gone mid-drag: a timeline row more)
                if self.tagScroll.frame.height > 0 { Prefs.tagsHeight = self.tagScroll.frame.height / s }
            }
        }
        tagsEdge.onToggle = { [weak self] in self?.toggleTags() }
        root.addSubview(sideEdge)
        root.addSubview(timelineEdge)
        root.addSubview(tagsEdge)            // over the timeline's edge where they meet, in the column
        header.onToggleSide = { [weak self] in self?.toggleSidebar() }
        header.onToggleTimeline = { [weak self] in self?.toggleTimeline() }
        header.onToggleTags = { [weak self] in self?.toggleTags() }
        layoutPanes()

        window.center()
        window.setFrameAutosaveName("ClaudeConsoleMain")
    }

    /// Where the panes go, from the window size and whether the left column and the timeline are shown.
    func layoutPanes() {
        guard let root = window.contentView else { return }
        let W = root.bounds.width, H = root.bounds.height, s = Prefs.uiScale
        // the header, the timeline and the column draw at their usual size and are scaled by s
        let headH = 56 * s
        header.frame = NSRect(x: 0, y: H - headH, width: W, height: headH)
        header.bounds = NSRect(x: 0, y: 0, width: W / s, height: 56)
        header.needsLayout = true
        let sideW = Prefs.sideHidden ? 0 : MainWindow.columnWidth(Prefs.sideWidth, scale: s, window: W)
        let tlH: CGFloat = Prefs.timelineHidden ? 0 : timeline.preferredHeight * s
        timeline.frame = NSRect(x: 0, y: 0, width: W, height: tlH)
        if tlH > 0 { timeline.bounds = NSRect(x: 0, y: 0, width: W / s, height: timeline.preferredHeight) }
        timeline.isHidden = tlH == 0
        sideScroll.allowsMagnification = true
        // pinned at s (min may never pass max, so the order depends on the direction)
        if s > sideScroll.maxMagnification {
            sideScroll.maxMagnification = s; sideScroll.minMagnification = s
        } else {
            sideScroll.minMagnification = s; sideScroll.maxMagnification = s
        }
        sideScroll.magnification = s
        let midH = H - headH - tlH
        [sideScroll, line].forEach { $0.isHidden = sideW == 0 }
        // (with the column tucked away, showing the tags brings it back: that works whatever the room)
        if sideW == 0 { tagScroll.isHidden = true; tagsEdge.isHidden = true; tagsNoRoom = false; header.tagsNoRoom = false }
        line.frame = NSRect(x: sideW, y: tlH, width: 1, height: midH)
        sideScroll.frame = NSRect(x: 0, y: tlH, width: sideW, height: midH)
        let mapX = sideW == 0 ? 0 : sideW + 1
        mapScroll.frame = NSRect(x: mapX, y: tlH, width: W - mapX, height: midH)
        hint.font = Theme.ui(11 * s)
        keysButton.attributedTitle = MainWindow.keysTitle()
        let kw = ceil(keysButton.attributedTitle.size().width) + 26 * s
        keysButton.frame = NSRect(x: W - 16 - kw, y: tlH + 4 * s, width: kw, height: 20 * s)
        hint.frame = NSRect(x: mapX + 16, y: tlH + 6 * s, width: max(0, W - mapX - 32 - kw - 12), height: 16 * s)
        sideEdge.frame = NSRect(x: max(0, sideW - 3), y: tlH, width: 6, height: midH)
        timelineEdge.frame = NSRect(x: 0, y: max(0, tlH - 3), width: W, height: 6)
        window.invalidateCursorRects(for: sideEdge)
        window.invalidateCursorRects(for: timelineEdge)
        if sideW > 0 {
            layoutLeft()
            sidebar.reload()            // the list is laid out for the column's width and height
            tags.needsDisplay = true
        }
    }

    /// The left column's width in the window: the width it's set to (dragging its edge sets it as at 100 %), scaled by
    /// ⌘+ / ⌘- with everything else, so its rows keep their room for a chat's name and status. Zoomed in, it never
    /// takes more than half the window (nor less than it's set to), so the map keeps its room.
    static func columnWidth(_ set: CGFloat, scale s: CGFloat, window W: CGFloat) -> CGFloat {
        s > 1 ? min(set * s, max(set, W / 2)) : set * s
    }

    /// ⌘+ / ⌘- (+1 / -1, 0 back to normal): everything in the window, 80–160 %, the map along with it.
    func scaleUI(by step: Int) {
        let old = Prefs.uiScale
        let new = step == 0 ? 1 : min(1.6, max(0.8, ((old * 10).rounded() + CGFloat(step)) / 10))
        guard new != old else { return }
        Prefs.uiScale = new
        map.zoom(new / old)
        layoutPanes()
        sideScroll.contentView.scroll(to: .zero)        // the list starts at its top again
        sideScroll.reflectScrolledClipView(sideScroll.contentView)
    }

    func toggleSidebar() {
        Prefs.sideHidden.toggle()
        if Prefs.sideHidden { tags.clearHighlight() }      // the tags go with the column: nothing left lit up by them
        layoutPanes()
        if Prefs.sideHidden { window.makeFirstResponder(map) }
    }
    func toggleTimeline() { Prefs.timelineHidden.toggle(); layoutPanes() }
    /// Tucks the tag shelf away or brings it back (with the column, if that was tucked away too). Tucked away, nothing
    /// stays lit up by a tag you could no longer click off. No room for it at this size: nothing to show or tuck away,
    /// so only a beep (whether it's shown stays as it was; the strip and the header's tag button say why).
    func toggleTags() {
        if tagsNoRoom && !Prefs.sideHidden { NSSound.beep(); return }
        if Prefs.tagsHidden || Prefs.sideHidden {
            Prefs.tagsHidden = false
            Prefs.sideHidden = false
        } else {
            tags.clearHighlight()
            Prefs.tagsHidden = true
        }
        layoutPanes()
    }

    /// The tag shelf: as tall as its tags need (up to about half the column), or as tall as it was dragged (scrolling
    /// when its tags need more), or tucked away; the pinned list takes the rest of the column.
    private func layoutLeft() {
        let sideW = sideScroll.frame.width, bottom = timeline.frame.maxY, s = Prefs.uiScale, top = header.frame.minY
        let room = top - bottom
        let need = tags.layout(width: sideW / s) * s
        let wanted = Prefs.tagsHeight > 0 ? Prefs.tagsHeight * s : min(need, max(320 * s, room * 0.55))
        // never taller than its tags, nor than leaves the list its heading and a row; never shorter than its heading
        let shelf = max(min(wanted, need, room - 128 * s), min(need, 44 * s))
        // a short window, zoomed in, has no room for its heading and 60 points of the list: no shelf then, rather than
        // the list pushed up over the header (and no tag left lit up that can't be clicked off). Shown or tucked away,
        // it stays set as it was until there's room; the strip and the tag button say why.
        tagsNoRoom = shelf > room - 60
        let h: CGFloat = Prefs.tagsHidden || tagsNoRoom ? 0 : shelf
        if tagsNoRoom && !Prefs.tagsHidden { tags.clearHighlight() }
        header.tagsNoRoom = tagsNoRoom
        tagsEdge.toolTip = tagsNoRoom ? MainWindow.noRoomText() : nil
        tagScroll.isHidden = h == 0
        tagScroll.frame = NSRect(x: 0, y: bottom, width: sideW, height: h)
        if h > 0 {
            tagScroll.allowsMagnification = true
            if s > tagScroll.maxMagnification { tagScroll.maxMagnification = s; tagScroll.minMagnification = s }
            else { tagScroll.minMagnification = s; tagScroll.maxMagnification = s }
            tagScroll.magnification = s
            // laid out for the width the chips really get: a scroll bar that comes (or goes) changes it once
            func fit() {
                let vis = tagScroll.contentView.bounds.size
                tags.frame = NSRect(x: 0, y: 0, width: vis.width, height: max(tags.layout(width: vis.width), vis.height))
            }
            fit(); tagScroll.tile(); fit()
            tags.reload()
        }
        sideScroll.frame = NSRect(x: 0, y: bottom + h, width: sideW, height: max(0, room - h))
        tagsEdge.isHidden = false
        // tucked away, a strip just above the timeline's edge brings it back (that edge keeps working below it)
        tagsEdge.frame = h > 0 ? NSRect(x: 0, y: bottom + h - 3, width: sideW, height: 6)
                               : NSRect(x: 0, y: max(bottom + 3, timelineEdge.frame.maxY), width: sideW, height: 5)
        window.invalidateCursorRects(for: tagsEdge)
    }

    func windowDidResize(_ notification: Notification) { layoutPanes() }

    func reload() {
        sidebar.phase = map.spinPhase
        if !Prefs.sideHidden { layoutLeft() }
        tags.reload()
        sidebar.reload()
        map.reload()
        timeline.reload()
        header.needsDisplay = true
    }

    var isShown: Bool { window.isVisible && window.isKeyWindow && NSApp.isActive }

    func show() {
        Front.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        reload()
        window.makeFirstResponder(map)
        if map.sel == nil { map.select(store.map.root.id, notify: false) }     // the window's own choice: the column keeps its pick
    }

    func hide() { window.orderOut(nil) }

    func showSearch() {
        show()
        search.isHidden = false
        searchCount.isHidden = false
        window.makeFirstResponder(search)
    }

    private func closeSearch() {
        search.stringValue = ""
        map.searchQuery = ""
        search.isHidden = true
        searchCount.isHidden = true
        window.makeFirstResponder(map)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === search else { return }
        map.searchQuery = search.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === search else { return false }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            map.nextMatch(back: NSEvent.modifierFlags.contains(.shift))
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { closeSearch(); return true }
        return false
    }
}

extension SidebarView: NSViewToolTipOwner {
    /// Hovering the heading: what's being read and when. Hovering a row cut short: its name and status in full.
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { rowTip(at: point) ?? status?().lines.joined(separator: "\n") ?? "" }
    }

    /// A row's name and status in full (nil off the rows).
    func rowTip(at p: NSPoint) -> String? {
        guard let c = row(at: p), let i = rows.firstIndex(where: { $0.id == c.id }) else { return nil }
        let lay = rowLayout(c, in: rowRect(i))
        return lay.name + "\n" + lay.full
    }
}
