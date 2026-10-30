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

    convenience init(_ title: String, warn: Bool = false, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.warn = warn
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
    }

    override var intrinsicContentSize: NSSize {
        let s = title.size(Theme.ui(12, .medium))
        return NSSize(width: ceil(s.width) + 22, height: 26)
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
        (title as NSString).draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2),
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
}

/// Top bar: mark, the two counts, usage, permission fixes, buttons.
@MainActor
final class HeaderView: NSView {
    var running = 0, unread = 0
    /// Some of those running are out of Kikumap's sight (shown "2?").
    var runningUnsure = false
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
    var actions: [(String, Bool, () -> Void)] = [] { didSet { rebuildButtons() } }
    var onSettings: (() -> Void)?
    var onLights: (() -> Void)?
    var onToggleSide: (() -> Void)?
    var onToggleTimeline: (() -> Void)?
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
    private lazy var statsBtn = IconButton("chart.bar.xaxis", tip: tr("统计", "Statistics")) { [weak self] in self?.onStats?() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if gear.superview == nil { [sideBtn, timelineBtn, statsBtn, lights, gear, todoBtn].forEach(addSubview) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        lights.setSymbol(dark ? "sun.max" : "moon")
        gear.setSymbol("gearshape")
        sideBtn.setSymbol("sidebar.left")
        timelineBtn.setSymbol("rectangle.bottomthird.inset.filled")
        statsBtn.setSymbol("chart.bar.xaxis")
        needsDisplay = true
    }

    func relabel() {
        gear.toolTip = tr("设置", "Settings")
        lights.toolTip = tr("开关灯（浅色 / 深色）", "Lights (light / dark)")
        sideBtn.toolTip = tr("显示 / 隐藏左栏  ⌃⌘S", "Show / hide the left column  ⌃⌘S")
        timelineBtn.toolTip = tr("显示 / 隐藏时间线  ⌃⌘T", "Show / hide the timeline  ⌃⌘T")
        statsBtn.toolTip = tr("统计  ⌘Y", "Statistics  ⌘Y")
        todoBtn.toolTip = tr("哪些事还没做，没做会影响什么；做不做由你决定", "What's left to do and what it affects; up to you whether to do it")
        todoBtn.needsDisplay = true
    }

    @objc private func openTodo() { onTodo?(todoBtn) }

    private func rebuildButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.enumerated().map { i, a in
            let b = FlatButton(a.0, warn: a.1, target: self, action: #selector(tap(_:)))
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
        for b in [gear, lights, statsBtn, timelineBtn, sideBtn] {
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
        var x: CGFloat = 48 + ceil("Kikumap".size(Theme.ui(15, .semibold)).width) + 22
        for (n, label) in [(running, tr("进行中", "Running")), (unread, tr("未读", "Unread"))] {
            let w = max(24, ceil((String(n) + "?").size(Theme.mono(12.5, .bold)).width) + 14)
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
        let title = "Kikumap"
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
            let w = HeaderView.drawCount(n, solid: solid, at: x, midY: mid, font: Theme.mono(12.5, .bold), unsure: !solid && runningUnsure)
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
        let markW: CGFloat = marked ? 27 : 0
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
                    if gpt {
                        let img = GPTWatcher.mark(Theme.muted, height: 10)
                        img.draw(in: NSRect(x: x, y: cy - 5, width: img.size.width, height: 10))
                    } else {
                        Logo.draw(in: NSRect(x: x + 1, y: cy - 5, width: 10, height: 10), color: Theme.muted)
                    }
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
    private var placed = Set<String>()
    private let schedRowH: CGFloat = 42
    private var sel: String?
    /// Several rows picked at once (⌘-click, ⇧-click); dragging one of them takes them all to the map.
    private var picked = Set<String>()
    /// A plain click on one of the picked rows picks just it — unless the click turns into a drag.
    private var narrowOnUp: String?
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
        if search.superview == nil { addSubview(search); addSubview(refresh) }
        search.placeholderString = tr("搜索置顶对话", "Search pinned chats")
        refresh.toolTip = tr("同步：马上重新读 Claude 和 ChatGPT  ⌘R", "Sync: read Claude and ChatGPT again now  ⌘R")
        removeAllToolTips()
        addToolTip(NSRect(x: 0, y: 0, width: bounds.width - 44, height: 54), owner: self, userData: nil)
        picked.formIntersection(rows.map(\.id))
        placed = store.map.placedChats()
        sched = TimelineView.upcoming(usage.routines)
        let content = schedTop + (sched.isEmpty ? 0 : 30 + CGFloat(sched.count) * schedRowH) + 20
        let visible = enclosingScrollView?.contentView.bounds.size ?? NSSize(width: 270, height: 0)
        setFrameSize(NSSize(width: visible.width, height: max(content, visible.height)))
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        refresh.frame = NSRect(x: bounds.width - 40, y: 9, width: 28, height: 26)
        search.frame = NSRect(x: 12, y: 60, width: bounds.width - 24, height: 22)
    }

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
            guard r.intersects(dirtyRect) else { continue }
            if sel == c.id || picked.contains(c.id) {
                let b = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: 0), xRadius: 6, yRadius: 6)
                Theme.hover.setFill(); b.fill()
            }
            // filed on the map: a short bar in its branch colour
            if placed.contains(c.id) {
                (store.branchColor(c.id) ?? Theme.line).setFill()
                NSBezierPath(roundedRect: NSRect(x: r.minX - 6, y: r.minY + 7, width: 2.5, height: r.height - 14), xRadius: 1.2, yRadius: 1.2).fill()
            }
            let state = store.isRunning(c.id) ? 2 : (store.isUnread(c) ? 1 : 0)
            if state > 0 { Theme.drawStatus(state, in: NSRect(x: r.minX, y: r.midY - 5, width: 10, height: 10), phase: phase) }
            let tf = Theme.ui(13, state > 0 ? .semibold : .regular)
            // where it lives, before the name: Claude's mark, a terminal for Claude Code, "GPT" for ChatGPT
            var nameX = r.minX + 16
            if c.isCode, let img = SidebarView.terminal {
                img.draw(in: NSRect(x: nameX, y: r.midY - 6, width: 14, height: 12))
                nameX += 19
            } else if c.isGPT {
                let img = GPTWatcher.mark(Theme.muted, height: 12)
                img.draw(in: NSRect(x: nameX, y: r.midY - 6, width: img.size.width, height: 12))
                nameX += img.size.width + 5
            } else {
                Logo.draw(in: NSRect(x: nameX + 0.5, y: r.midY - 6.5, width: 13, height: 13), color: Theme.muted)
                nameX += 19
            }
            let time = store.timeLabel(c)
            let timeF = Theme.ui(11.5)
            let tw = ceil(time.size(timeF).width)
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
            let th = ceil(tf.ascender - tf.descender + tf.leading)
            (store.name(c.id) as NSString).draw(with: NSRect(x: nameX, y: r.midY - th / 2, width: r.maxX - nameX - tw - 14, height: th),
                                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                attributes: [.font: tf, .foregroundColor: Theme.ink, .paragraphStyle: p])
            let tc: NSColor = state > 0 ? Theme.ink : Theme.muted
            let ts = time.size(timeF)
            (time as NSString).draw(at: NSPoint(x: r.maxX - 8 - tw, y: r.midY - ts.height / 2), withAttributes: [.font: timeF, .foregroundColor: tc])

        }
        drawSchedule(dirtyRect)
    }

    /// Scheduled tasks follow the inbox.
    private var schedTop: CGFloat { top + CGFloat(max(rows.isEmpty ? 4 : 1, rows.count)) * rowH + 22 }

    private func drawSchedule(_ dirtyRect: NSRect) {
        guard !sched.isEmpty else { return }
        let y0 = schedTop
        Theme.faint.setFill(); NSRect(x: 16, y: y0 - 12, width: bounds.width - 32, height: 1).fill()
        let hf = Theme.ui(14, .semibold)
        let head = tr("计划任务", "Scheduled")
        (head as NSString).draw(at: NSPoint(x: 16, y: y0), withAttributes: [.font: hf, .foregroundColor: Theme.ink])
        (String(sched.count) as NSString).draw(at: NSPoint(x: 16 + head.size(hf).width + 8, y: y0 + 1),
                                               withAttributes: [.font: Theme.mono(12.5, .medium), .foregroundColor: Theme.muted])
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
        guard let c = row(at: p) else { sel = nil; picked = []; needsDisplay = true; return }
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
        }
        needsDisplay = true
        if e.clickCount == 2 { onOpen?(c.id); return }
        pressed = (c.id, p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let pr = pressed else { return }
        let p = convert(e.locationInWindow, from: nil)
        if hypot(p.x - pr.at.x, p.y - pr.at.y) < 5 { return }
        pressed = nil
        narrowOnUp = nil
        let ids = picked.count > 1 && picked.contains(pr.id) ? rows.map(\.id).filter { picked.contains($0) } : [pr.id]
        let item = NSPasteboardItem()
        item.setString("side|" + ids.map { "c:" + $0 }.joined(separator: "\n"), forType: dragType)
        let di = NSDraggingItem(pasteboardWriter: item)
        let img = MapView.dragImage(ids.count == 1 ? store.name(pr.id) : tr("\(ids.count) 个对话", "\(ids.count) chats"))
        di.setDraggingFrame(NSRect(x: p.x - 20, y: p.y - img.size.height / 2, width: img.size.width, height: img.size.height), contents: img)
        beginDraggingSession(with: [di], event: e, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        if let id = narrowOnUp { sel = id; picked = []; needsDisplay = true }
        narrowOnUp = nil
        pressed = nil
    }

    private static var terminal: NSImage? {          // built each time: follows light / dark
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let i = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Claude Code")?.withSymbolConfiguration(cfg) else { return nil }
        let tinted = NSImage(size: i.size, flipped: false) { r in
            i.draw(in: r); Theme.muted.set(); r.fill(using: .sourceAtop); return true
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
        m.addItem(MenuAction(title: on ? tr("取消置顶", "Unpin") : tr("在 Kikumap 置顶", "Pin in Kikumap")) { [weak self] in
            self?.store.setPinned(c.id, !on)
        })
        m.addItem(MenuAction(title: tr("打开", "Open")) { [weak self] in self?.onOpen?(c.id) })
        return m
    }

    override func keyDown(with e: NSEvent) {
        // space, or ⌘↓ as in Finder: open it
        if e.keyCode == 49 || (e.keyCode == 125 && e.modifierFlags.contains(.command)), let s = sel { onOpen?(s) }
        else if e.keyCode == 53, !picked.isEmpty { picked = []; needsDisplay = true }
        else { super.keyDown(with: e) }
    }

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
    private(set) var selected: String?
    private var chips: [(NSRect, String?)] = []       // nil id = the "＋" chip
    private var pressed: (id: String?, at: NSPoint)?
    private let top: CGFloat = 38, chipH: CGFloat = 20, gap: CGFloat = 4
    private let chipF = Theme.ui(11.5, .medium)

    init(store: Store) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 80))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func chipW(_ t: Tag) -> CGFloat { ceil(t.name.size(chipF).width) + 24 }

    /// Lays the chips out in one flow for `width` — status first, then what a chat makes, then
    /// your own, then "＋"; returns the height needed.
    @discardableResult
    func layout(width: CGFloat) -> CGFloat {
        chips = []
        let order = ["status": 0, "output": 1]
        let tags = store.map.tags.enumerated().sorted {
            (order[$0.element.group ?? ""] ?? 2, $0.offset) < (order[$1.element.group ?? ""] ?? 2, $1.offset)
        }.map { $0.element }
        var x: CGFloat = 16, y = top
        func place(_ w: CGFloat, _ id: String?) {
            if x + w > width - 14 && x > 16 { x = 16; y += chipH + gap }
            chips.append((NSRect(x: x, y: y, width: w, height: chipH), id))
            x += w + gap
        }
        for t in tags { place(min(chipW(t), width - 30), t.id) }
        place(26, nil)
        return y + chipH + 12
    }

    func reload() {
        if let s = selected, !store.map.tags.contains(where: { $0.id == s }) { selected = nil; onHighlight?(nil) }
        layout(width: bounds.width)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paper.setFill(); bounds.fill()
        Theme.faint.setFill(); NSRect(x: 16, y: 0, width: bounds.width - 32, height: 1).fill()
        let hf = Theme.ui(14, .semibold)
        let head = tr("标签", "Tags")
        (head as NSString).draw(at: NSPoint(x: 16, y: 12), withAttributes: [.font: hf, .foregroundColor: Theme.ink])
        let hint = selected == nil ? tr("拖到条目上 · 点击高亮", "Drag onto an item · click to highlight")
                                   : tr("再点一下取消", "Click again to clear")
        (hint as NSString).draw(at: NSPoint(x: 16 + head.size(hf).width + 8, y: 14.5),
                                withAttributes: [.font: Theme.ui(11), .foregroundColor: Theme.muted])
        let tags = store.map.tags
        let f = chipF
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
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 8, y: r.midY - 3.5, width: 7, height: 7)).fill()
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            let th = ceil(f.ascender - f.descender + f.leading)
            (t.name as NSString).draw(with: NSRect(x: r.minX + 18, y: r.midY - th / 2, width: r.width - 24, height: th),
                                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: f, .foregroundColor: on ? Theme.paper : Theme.ink, .paragraphStyle: para])
        }
    }

    private func chip(at p: NSPoint) -> (NSRect, String?)? { chips.first { $0.0.contains(p) } }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
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
            if let (name, color) = TagPrompt.ask(color: store.map.nextTagColor(), window: window) {
                _ = store.map.addTag(name, color: color)
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

    init(sideways: Bool) {
        self.sideways = sideways
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: sideways ? .resizeLeftRight : .resizeUpDown) }
    override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { onToggle?() } }
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

    /// The few that matter most; the rest are one click away (`keysButton`).
    static func hintText() -> String {
        tr("拖动空白处框选 · 按住空格移动导图 · ⇥ 子主题 · ⏎ 同级 · ⌘F 搜索 · 右键改颜色和标签",
           "drag empty space to select · hold space to move the map · ⇥ subtopic · ⏎ sibling · ⌘F search · right-click for colours and tags")
    }

    /// Every shortcut in the map: (keys, what it does).
    static func allShortcuts() -> [(String, String)] {
        var list: [(String, String)] = [
            (tr("拖动空白处", "Drag on empty space"), tr("框选", "Select with a box")),
            (tr("⇧ / ⌘ 点击", "⇧ / ⌘-click"), tr("加选 / 取消选择", "Add to or remove from the selection")),
            (tr("按住空格、双指滑动", "Hold space, two fingers"), tr("移动导图", "Move around the map")),
            ("⇥ / ⌥⇥", tr("新建子主题 / 父主题", "New subtopic / parent topic")),
            ("⏎ / ⌥⏎ / ⇧⏎", tr("下方同级 / 上方同级 / 新一级主题", "Sibling below / above / new main topic")),
            (tr("双击空白处", "Double-click empty space"), tr("新主题", "New topic")),
            (tr("⌘⏎、双击", "⌘⏎, double-click"), tr("改名（对话名只在本机）", "Rename (chat names stay on this Mac)")),
            ("⌫", tr("删除；置顶的对话回到左栏", "Delete; pinned chats go back to the left column")),
            ("⌥.", tr("折叠 / 展开", "Fold / unfold")),
            ("⌥↑ ⌥↓", tr("在同级之间移动", "Move among siblings")),
            ("⌘↑", tr("回到所在的主题", "Up to the topic it's in")),
            ("⌘A", tr("全选", "Select all")),
            ("⌘Z / ⇧⌘Z", tr("撤销 / 重做", "Undo / redo")),
            ("⌘F", tr("搜索；⏎ 下一个", "Search; ⏎ for the next match")),
            (tr("右键", "Right-click"), tr("分支颜色、图形、标签", "Branch colour, shape, tags")),
            (tr("⌘↓、轻按空格、悬停对话 → ↗", "⌘↓, tap space, hover a chat → ↗"), tr("在它的 App 里打开", "Open it in its app")),
            (tr("⇧⌘U、悬停对话 → ✉", "⇧⌘U, hover a chat → ✉"), tr("标为未读 / 已读", "Mark unread / read")),
            ("⌃⌘S / ⌃⌘T", tr("显示或隐藏左栏 / 时间线", "Show or hide the left column / timeline")),
            ("⌘+ / ⌘-", tr("整个窗口放大 / 缩小", "Everything in the window bigger / smaller")),
            (tr("双指捏合、⌘0", "Pinch, ⌘0"), tr("缩放导图、适应窗口", "Zoom the map, fit it to the window")),
            ("⌘E / ⇧⌘E", tr("导出导图 PDF / 导出对话", "Export the map as PDF / export chats")),
        ]
        if Prefs.hotKeyEnabled { list.append((Prefs.hotKeyLabel(), tr("在任何地方呼出 / 收起导图", "Show / hide the map from anywhere"))) }
        return list
    }

    static func keysTitle() -> NSAttributedString {
        NSAttributedString(string: tr("全部快捷键", "All shortcuts"),
                           attributes: [.font: Theme.ui(11 * Prefs.uiScale, .semibold), .foregroundColor: Theme.ink])
    }

    /// All the shortcuts, in a popover under the button.
    @objc private func showKeys(_ sender: NSButton) {
        let rows = MainWindow.allShortcuts().map { k, what -> [NSView] in
            let key = NSTextField(labelWithString: k)
            key.font = Theme.ui(12, .semibold)
            key.textColor = Theme.ink
            let text = NSTextField(labelWithString: what)
            text.font = Theme.ui(12)
            text.textColor = Theme.muted
            return [key, text]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let vc = NSViewController()
        vc.view = NSView()
        vc.view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -16),
            grid.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -18),
        ])
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    /// Language changed: refresh every fixed label.
    func relabel() {
        hint.stringValue = MainWindow.hintText()
        keysButton.attributedTitle = MainWindow.keysTitle()
        window.title = "Kikumap"
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
        window.title = "Kikumap"
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

        tags.frame = NSRect(x: 0, y: tlH, width: sideW, height: 80)
        tags.autoresizingMask = [.maxYMargin]
        root.addSubview(tags)
        tags.onHighlight = { [weak self] id in self?.map.highlightTag = id }
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
        keysButton.attributedTitle = MainWindow.keysTitle()
        keysButton.target = self
        keysButton.action = #selector(showKeys(_:))
        root.addSubview(hint)
        root.addSubview(keysButton)

        timeline.frame = NSRect(x: 0, y: 0, width: W, height: tlH)
        timeline.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(timeline)

        // the column's and the timeline's edges: drag to resize or tuck away
        sideEdge.onDrag = { [weak self] x in
            if x < 120 { Prefs.sideHidden = true } else { Prefs.sideHidden = false; Prefs.sideWidth = min(440, max(200, x)) }
            self?.layoutPanes()
        }
        sideEdge.onToggle = { [weak self] in self?.toggleSidebar() }
        timelineEdge.onDrag = { [weak self] y in
            Prefs.timelineHidden = y < 60
            self?.layoutPanes()
        }
        timelineEdge.onToggle = { [weak self] in self?.toggleTimeline() }
        root.addSubview(sideEdge)
        root.addSubview(timelineEdge)
        header.onToggleSide = { [weak self] in self?.toggleSidebar() }
        header.onToggleTimeline = { [weak self] in self?.toggleTimeline() }
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
        [sideScroll, tags, line].forEach { $0.isHidden = sideW == 0 }
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
        layoutPanes()
        if Prefs.sideHidden { window.makeFirstResponder(map) }
    }
    func toggleTimeline() { Prefs.timelineHidden.toggle(); layoutPanes() }

    /// The tag shelf grows with its tags; the pinned list takes the rest of the column.
    private func layoutLeft() {
        let sideW = sideScroll.frame.width, bottom = timeline.frame.maxY, s = Prefs.uiScale
        let h = min(tags.layout(width: sideW / s), 300) * s
        tags.frame = NSRect(x: 0, y: bottom, width: sideW, height: h)
        tags.bounds = NSRect(x: 0, y: 0, width: sideW / s, height: h / s)
        let top = header.frame.minY
        sideScroll.frame = NSRect(x: 0, y: bottom + h, width: sideW, height: max(60, top - bottom - h))
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
        if map.sel == nil { map.select(store.map.root.id) }
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
