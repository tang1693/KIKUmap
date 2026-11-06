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
    private lazy var gear = IconButton("gearshape", tip: tr("设置", "Settings")) { [weak self] in self?.onSettings?() }
    private lazy var lights = IconButton("moon", tip: tr("开关灯", "Lights")) { [weak self] in self?.onLights?() }
    private lazy var sideBtn = IconButton("sidebar.left", tip: tr("显示 / 隐藏左栏", "Show / hide the left column")) { [weak self] in self?.onToggleSide?() }
    private lazy var timelineBtn = IconButton("rectangle.bottomthird.inset.filled", tip: tr("显示 / 隐藏时间线", "Show / hide the timeline")) { [weak self] in self?.onToggleTimeline?() }
    private lazy var tagsBtn = IconButton("tag", tip: tr("显示 / 隐藏标签", "Show / hide the tags")) { [weak self] in self?.onToggleTags?() }
    private lazy var statsBtn = IconButton("chart.bar.xaxis", tip: tr("统计", "Statistics")) { [weak self] in self?.onStats?() }
    /// No room for the tag shelf at this size: the tag button says why (pressing it only beeps).
    var tagsNoRoom = false { didSet { if tagsNoRoom != oldValue { tagsBtn.toolTip = tagsTip } } }
    private var tagsTip: String { tr("显示 / 隐藏标签  ⌃⌘G", "Show / hide the tags  ⌃⌘G") + (tagsNoRoom ? "\n" + MainWindow.noRoomText() : "") }

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
        gear.toolTip = tr("设置", "Settings")
        lights.toolTip = tr("开关灯（浅色 / 深色）", "Lights (light / dark)")
        sideBtn.toolTip = tr("显示 / 隐藏左栏  ⌃⌘S", "Show / hide the left column  ⌃⌘S")
        timelineBtn.toolTip = tr("显示 / 隐藏时间线  ⌃⌘T", "Show / hide the timeline  ⌃⌘T")
        tagsBtn.toolTip = tagsTip
        statsBtn.toolTip = tr("统计  ⌘Y", "Statistics  ⌘Y")
        todoBtn.toolTip = tr("哪些事还没做，没做会影响什么；做不做由你决定", "What's left to do and what it affects; up to you whether to do it")
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

    /// Where the logo, the name and the two counts with their words (or the pills alone) end, as `draw` lays them out.
    private func countsEnd(words: Bool = true) -> CGFloat {
        var x: CGFloat = 48 + ceil("KIKUmap".size(Theme.ui(15, .semibold)).width) + 22
        let f = Theme.mono(12.5, .bold)
        for (n, label) in [(running, tr("进行中", "Running")), (unread, tr("未读", "Unread"))] {
            let w = label == tr("未读", "Unread") ? max(24, ceil(String(n).size(f).width) + 14)
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

    /// A count pill: outlined (running) or solid (waiting for you).
    static func drawCount(_ n: Int, solid: Bool, at x: CGFloat, midY: CGFloat, font: NSFont, unsure: Bool = false) -> CGFloat {
        let s = String(n) + (unsure ? "?" : "")
        let w = max(24, ceil(s.size(font).width) + 14)
        let r = NSRect(x: x, y: midY - 11, width: w, height: 22)
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 10.25, yRadius: 10.25)
        // waiting for you uses the same red badge as the menu bar (only when there is something)
        let red = solid && n > 0
        if solid { (red ? NSColor.systemRed : Theme.ink).setFill(); p.fill() } else { Theme.ink.setStroke(); p.lineWidth = 1.5; p.stroke() }
        let ns = s.size(font)
        (s as NSString).draw(at: NSPoint(x: r.midX - ns.width / 2, y: r.midY - ns.height / 2),
                             withAttributes: [.font: font, .foregroundColor: red ? NSColor.white : (solid ? Theme.bg : Theme.ink)])
        return w
    }

    override func draw(_ dirtyRect: NSRect) {
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
        let words = countsEnd() + (live.isEmpty ? 0 : 12 + liveW) <= limit
        for (n, label, solid) in [(running, tr("进行中", "Running"), false), (unread, tr("未读", "Unread"), true)] {
            var w: CGFloat
            if solid {
                w = HeaderView.drawCount(n, solid: true, at: x, midY: mid, font: Theme.mono(12.5, .bold))
            } else {
                // running: the number in a ring, as in the menu bar ("?" after it for some out of sight)
                let f = Theme.mono(12.5, .bold), s = n > 99 ? "99+" : String(n)
                let d = max(24, ceil(s.size(f).width) + 10)
                ringRect = NSRect(x: x, y: mid - d / 2, width: d, height: d)
                Theme.drawRunCount(s, in: ringRect, ink: Theme.ink, arc: Logo.orange, font: f, phase: runningSeen > 0 ? ringPhase : nil)
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
        let fit = fits.first { total($0) <= limit - liveW - x } ?? ([], 0, 2, false)
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
        setMetersTip(fit.columns.isEmpty ? nil : NSRect(x: meterStart, y: 4, width: x - 18 - meterStart, height: bounds.height - 9))
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
    private var sel: String?
    /// Several rows picked at once (⌘-click, ⇧-click); dragging one of them takes them all to the map.
    private var picked = Set<String>()
    /// The rows picked by hand changed: their chats (in the list's order) and the one the keys move from, so the map
    /// selects the same.
    var onPick: (([String], String?) -> Void)?
    private var pickedIDs: [String] { picked.isEmpty ? (sel.map { [$0] } ?? []) : rows.map(\.id).filter { picked.contains($0) } }
    private func pickedChanged() { onPick?(pickedIDs, sel) }
    /// What's picked now: the chats, and the one the keys move from.
    var pick: (ids: [String], lead: String?) { (pickedIDs, sel) }

    /// Picks the rows of these chats (the map selected them), without telling the map back; the lead one comes into
    /// view. Chats this list doesn't show (not pinned, or searched away) aren't picked.
    func show(picked ids: [String], lead: String?) {
        let listed = Set(rows.map(\.id))
        let shown = ids.filter { listed.contains($0) }
        let newSel = lead.flatMap { listed.contains($0) ? $0 : nil } ?? rows.first { shown.contains($0.id) }?.id
        let newPicked: Set<String> = shown.count > 1 ? Set(shown) : []
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
        rows = query.isEmpty ? all : all.filter { c in
            [store.name(c.id), c.title].contains { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        }
        // while the list is empty its status counts down to the next read, so it redraws every second
        if all.isEmpty, statusTick == nil {
            statusTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if self?.window?.isVisible == true { self?.needsDisplay = true } }
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
        search.placeholderString = tr("搜索置顶对话", "Search pinned chats")
        refresh.toolTip = tr("同步：马上重新读 Claude 和 ChatGPT  ⌘R", "Sync: read Claude and ChatGPT again now  ⌘R")
        removeAllToolTips()
        addToolTip(NSRect(x: 0, y: 0, width: bounds.width - 44, height: 54), owner: self, userData: nil)
        // a picked chat that isn't listed at all any more (unpinned, ChatGPT switched off) isn't picked; one only
        // searched away stays picked for when the search is cleared
        if let s = sel, !all.contains(where: { $0.id == s }) { sel = nil }
        picked.formIntersection(rows.map(\.id))
        placed = store.map.placedChats()
        sched = TimelineView.upcoming(usage.routines)
        schedNote = usage.routinesUnknown.map { tr("没同步：", "Not synced: ") + $0 }
        let visible = enclosingScrollView?.contentView.bounds.size ?? NSSize(width: 270, height: 0)
        let content = schedTop + (sched.isEmpty && schedNote == nil ? 0 : 30 + CGFloat(sched.count) * schedRowH + schedNoteHeight(visible.width)) + 20
        setFrameSize(NSSize(width: visible.width, height: max(content, visible.height)))
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
        (tr("置顶对话 + 编辑器里的会话 · 拖到画布上", "Pins + editor sessions · drag to canvas") as NSString).draw(at: NSPoint(x: 16, y: 37), withAttributes: [.font: Theme.ui(11.5), .foregroundColor: Theme.muted])
        if allCount > 0 && rows.isEmpty {
            let a: [NSAttributedString.Key: Any] = [.font: Theme.ui(12), .foregroundColor: Theme.muted]
            let q = query.count > 14 ? String(query.prefix(14)) + "…" : query
            let line = tr("没有名字里带「\(q)」的置顶对话", "No pinned chat has “\(q)” in its name")
            (line as NSString).draw(with: NSRect(x: 18, y: top + 6, width: bounds.width - 36, height: 54), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
        } else if rows.isEmpty, let st = status?() {
            var y = top + 6
            let w = bounds.width - 36
            for (i, line) in ([st.title] + st.lines).enumerated() {
                let a: [NSAttributedString.Key: Any] = [.font: i == 0 ? Theme.ui(13, .semibold) : Theme.ui(11.5),
                                                        .foregroundColor: i == 0 ? Theme.ink : Theme.muted]
                let h = ceil((line as NSString).boundingRect(with: NSSize(width: w, height: 200), options: .usesLineFragmentOrigin, attributes: a).height)
                (line as NSString).draw(with: NSRect(x: 18, y: y, width: w, height: h), options: .usesLineFragmentOrigin, attributes: a)
                y += h + (i == 0 ? 8 : 5)
            }
        }
        for (i, c) in rows.enumerated() {
            let r = NSRect(x: 10, y: top + CGFloat(i) * rowH, width: bounds.width - 20, height: rowH - 4)
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
                        Theme.drawSnake(pill, perimeter: 2 * (b.width - b.height) + .pi * b.height, color: Logo.orange, lineWidth: 2)
                    }
                }
            }
            // picked: the blue ring the map uses too (paler while the list isn't what the keys go to)
            if selected {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: (r.height + 4) / 2, yRadius: (r.height + 4) / 2)
                Theme.pickRing(focused: window?.isKeyWindow == true && window?.firstResponder === self).setStroke()
                ring.lineWidth = 2; ring.stroke()
            }
            let tf = Theme.ui(13, state > 0 ? .semibold : .regular)
            // where it lives, before the name: Claude's mark, a terminal for Claude Code, "GPT" for ChatGPT
            var nameX = r.minX + 12
            // a session in an editor or a terminal: a terminal first; then whose AI it is, for every chat
            if c.isCode || c.isCodexSession, let img = SidebarView.terminal(faded) {
                img.draw(in: NSRect(x: nameX, y: r.midY - 6, width: 14, height: 12))
                nameX += 19
            }
            let tag = c.isGPT ? GPTWatcher.mark(faded, height: 12) : Theme.claudeTag(faded, height: 12)
            tag.draw(in: NSRect(x: nameX, y: r.midY - 6, width: tag.size.width, height: 12))
            nameX += tag.size.width + 5
            let time = store.timeLabel(c)
            let timeF = Theme.ui(11.5)
            let tw = ceil(time.size(timeF).width)
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
            let th = ceil(tf.ascender - tf.descender + tf.leading)
            (store.name(c.id) as NSString).draw(with: NSRect(x: nameX, y: r.midY - th / 2, width: r.maxX - nameX - tw - 14, height: th),
                                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                attributes: [.font: tf, .foregroundColor: ink, .paragraphStyle: p])
            let tc: NSColor = state > 0 ? ink : faded
            let ts = time.size(timeF)
            (time as NSString).draw(at: NSPoint(x: r.maxX - 12 - tw, y: r.midY - ts.height / 2), withAttributes: [.font: timeF, .foregroundColor: tc])
            if state == 1 {
                // a red dot on its top corner, like the menu bar's badge
                let d = NSPoint(x: r.maxX - 3, y: r.minY + 2)
                Theme.paper.setFill(); NSBezierPath(ovalIn: NSRect(x: d.x - 6.5, y: d.y - 6.5, width: 13, height: 13)).fill()
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: d.x - 5, y: d.y - 5, width: 10, height: 10)).fill()
            }

        }
        drawSchedule(dirtyRect)
    }

    /// Scheduled tasks follow the inbox.
    private var schedTop: CGFloat { top + CGFloat(max(rows.isEmpty ? 4 : 1, rows.count)) * rowH + 22 }

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
        guard let c = row(at: p) else { sel = nil; picked = []; needsDisplay = true; pickedChanged(); return }
        narrowOnUp = nil
        let f = e.modifierFlags
        if f.contains(.command) {
            if picked.isEmpty, let s = sel { picked = [s] }
            if picked.contains(c.id) {
                picked.remove(c.id)
                sel = picked.first
            } else {
                picked.insert(c.id)
                sel = c.id
            }
        } else if f.contains(.shift), let s = sel, let a = rows.firstIndex(where: { $0.id == s }),
                  let b = rows.firstIndex(where: { $0.id == c.id }) {
            picked = Set(rows[min(a, b)...max(a, b)].map(\.id))       // the first click stays the anchor
        } else if picked.count > 1 && picked.contains(c.id) {
            narrowOnUp = c.id
        } else {
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
        pressed = nil
        narrowOnUp = nil
        syncOnUp = false
        let ids = picked.count > 1 && picked.contains(pr.id) ? rows.map(\.id).filter { picked.contains($0) } : [pr.id]
        let item = NSPasteboardItem()
        item.setString("side|" + ids.map { "c:" + $0 }.joined(separator: "\n"), forType: dragType)
        let di = NSDraggingItem(pasteboardWriter: item)
        let img = MapView.dragImage(ids.count == 1 ? store.name(pr.id) : tr("\(ids.count) 个对话", "\(ids.count) chats"))
        di.setDraggingFrame(NSRect(x: p.x - 20, y: p.y - img.size.height / 2, width: img.size.width, height: img.size.height), contents: img)
        beginDraggingSession(with: [di], event: e, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        if let id = narrowOnUp { sel = id; picked = []; needsDisplay = true; pickedChanged() }
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

    /// Claude Code sessions can be pinned here, so they stay after the 12 hours; Claude chats can be archived.
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
        m.addItem(MenuAction(title: on ? tr("取消置顶", "Unpin") : tr("在 KIKUmap 置顶", "Pin in KIKUmap")) { [weak self] in
            self?.store.setPinned(c.id, !on)
        })
        m.addItem(MenuAction(title: tr("打开", "Open")) { [weak self] in self?.onOpen?(c.id) })
        return m
    }

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 125 where cmd: if let s = sel { onOpen?(s) }           // ⌘↓ as in Finder: open it
        case 125, 126: step(e.keyCode == 125 ? 1 : -1)              // ↓ ↑: the next row, the one before
        case 49, 36, 76:                                            // space, Return, Enter: open it
            if let s = sel { onOpen?(s) } else { super.keyDown(with: e) }
        case 53 where !picked.isEmpty: picked = []; needsDisplay = true; pickedChanged()
        default: super.keyDown(with: e)
        }
    }

    /// The row `d` below (or above) the one picked, brought into view; the first (or last) when none is.
    private func step(_ d: Int) {
        guard !rows.isEmpty else { return }
        let i = sel.flatMap { s in rows.firstIndex { $0.id == s } }
        let n = i.map { max(0, min(rows.count - 1, $0 + d)) } ?? (d > 0 ? 0 : rows.count - 1)
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
        let hint = selected == nil ? tr("拖到条目上 · 点击高亮", "Drag onto an item · click to highlight")
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
        m.addItem(MenuAction(title: tr("收起标签  ⌃⌘G", "Hide Tags  ⌃⌘G")) { [weak self] in self?.onHide?() })
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
           "drag empty space to select · hold space to move the map · ⇥ subtopic · ⏎ sibling · ⌘F search · right-click for colours and tags")
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

    /// Language changed: refresh every fixed label.
    func relabel() {
        hint.stringValue = MainWindow.hintText()
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
        search.placeholderString = tr("搜索主题、对话、标签", "Search topics, chats, tags")
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
            if x < 120 {
                if !Prefs.sideHidden { self?.tags.clearHighlight() }
                Prefs.sideHidden = true
            } else { Prefs.sideHidden = false; Prefs.sideWidth = min(440, max(200, x)) }
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
        let sideW = Prefs.sideHidden ? 0 : Prefs.sideWidth
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
    /// Hovering the heading: what's being read and when.
    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { status?().lines.joined(separator: "\n") ?? "" }
    }
}
