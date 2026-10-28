import Cocoa

/// The statistics window: how long Claude worked each day — one bar per day, a segment per chat.
@MainActor
final class StatsWindow: NSObject, NSWindowDelegate {
    let store: Store
    var onOpen: ((String) -> Void)?
    private var window: NSWindow?
    private var chart: StatsView?
    private var timer: Timer?

    init(store: Store) {
        self.store = store
        super.init()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 640, height: 430)
            w.delegate = self
            let v = StatsView(store: store)
            v.onOpen = { [weak self] id in self?.onOpen?(id) }
            w.contentView = v
            w.center()
            window = w
            chart = v
        }
        window?.title = tr("统计", "Statistics")
        chart?.relabel()
        chart?.reload()
        timer?.invalidate()
        // running chats keep adding time
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.chart?.reload() }
        }
        Front.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// A chat started or finished, or was renamed.
    func refresh() {
        guard window?.isVisible == true else { return }
        chart?.reload()
    }

    func relabel() {
        window?.title = tr("统计", "Statistics")
        chart?.relabel()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

/// Stacked bars, the summary above them and a legend that doubles as the table of totals.
final class StatsView: NSView {
    let store: Store
    var onOpen: ((String) -> Void)?

    /// Categorical colours, in this fixed order (checked for colour-blind separation in both modes).
    static let colours: [NSColor] = [
        Theme.dyn(0x2A78D6, 0x3987E5), Theme.dyn(0xEB6834, 0xD95926), Theme.dyn(0x1BAF7A, 0x199E70),
        Theme.dyn(0xEDA100, 0xC98500), Theme.dyn(0xE87BA4, 0xD55181), Theme.dyn(0x008300, 0x008300),
        Theme.dyn(0x6250D6, 0x9085E9),
    ]
    static let otherColour = Theme.dyn(0xB9B9BC, 0x57575C)

    private enum Part: Equatable { case chat(String), other }
    private struct Hit: Equatable { var day: Int?; var part: Part? }

    private static let choices = [7, 14, 30, 90]
    private let range = NSSegmentedControl()
    private var days: Int {
        get { let d = UserDefaults.standard.integer(forKey: "StatsDays"); return Self.choices.contains(d) ? d : 14 }
        set { UserDefaults.standard.set(newValue, forKey: "StatsDays") }
    }
    private var starts: [Date] = []                  // each day's start, then tomorrow's
    private var perDay: [[String: Double]] = []
    private var totals: [String: Double] = [:]
    /// Chat → colour. Kept while the window lives, so a chat keeps its colour when the range changes.
    private var slots: [String: Int] = [:]
    private var hover: Hit?
    private var mouse = NSPoint.zero
    private var segRects: [(day: Int, part: Part, rect: NSRect)] = []
    private var legendRows: [(part: Part, rect: NSRect)] = []

    private let pad: CGFloat = 24
    private let top: CGFloat = 128

    init(store: Store) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 560))
        range.segmentStyle = .rounded
        range.trackingMode = .selectOne
        range.target = self
        range.action = #selector(pickRange)
        addSubview(range)
        relabel()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func relabel() {
        range.segmentCount = Self.choices.count
        for (i, n) in Self.choices.enumerated() {
            range.setLabel(tr("\(n) 天", "\(n) days"), forSegment: i)
            range.setWidth(0, forSegment: i)
        }
        range.selectedSegment = Self.choices.firstIndex(of: days) ?? 1
        range.sizeToFit()
        needsLayout = true
        needsDisplay = true
    }

    @objc private func pickRange() {
        days = Self.choices[max(range.selectedSegment, 0)]
        hover = nil
        reload()
    }

    override func layout() {
        super.layout()
        range.setFrameOrigin(NSPoint(x: bounds.width - pad - range.frame.width, y: 84))
    }

    func reload() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        starts = (0...days).map { cal.date(byAdding: .day, value: $0 - days + 1, to: today)! }
        perDay = store.worked(starts)
        totals = [:]
        for d in perDay { for (id, s) in d { totals[id, default: 0] += s } }
        let top = totals.sorted { $0.value > $1.value }.prefix(Self.colours.count).map { $0.key }
        slots = slots.filter { top.contains($0.key) }
        var free = (0..<Self.colours.count).filter { s in !slots.values.contains(s) }
        for id in top where slots[id] == nil { slots[id] = free.removeFirst() }
        needsDisplay = true
    }

    // MARK: drawing

    private var legendWidth: CGFloat { min(250, bounds.width * 0.3) }
    private var plot: NSRect {
        let left = pad + 46
        return NSRect(x: left, y: top, width: bounds.width - legendWidth - pad * 2 - 20 - left + pad,
                      height: max(bounds.height - top - 46, 60))
    }

    private func attrs(_ font: NSFont, _ color: NSColor, _ align: NSTextAlignment = .left) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: p]
    }

    private func draw(_ s: String, _ font: NSFont, _ color: NSColor, in r: NSRect, _ align: NSTextAlignment = .left) {
        (s as NSString).draw(in: r, withAttributes: attrs(font, color, align))
    }

    /// Stacked bottom to top in colour order, the rest on top as "Other".
    private func stack(_ day: [String: Double]) -> [(Part, Double)] {
        var out = day.compactMap { id, s in slots[id].map { (slot: $0, id: id, s: s) } }
            .sorted { $0.slot < $1.slot }.map { (Part.chat($0.id), $0.s) }
        let rest = day.filter { slots[$0.key] == nil }.values.reduce(0, +)
        if rest > 0 { out.append((.other, rest)) }
        return out
    }

    private func colour(_ p: Part) -> NSColor {
        if case .chat(let id) = p, let s = slots[id] { return Self.colours[s] }
        return Self.otherColour
    }

    private func dayLabel(_ i: Int, short: Bool) -> String {
        if i == perDay.count - 1 { return tr("今天", "Today") }
        let d = starts[i]
        return short ? Clock.format(d, "M/d", "MMM d") : Clock.format(d, "EEE d", "EEE d")
    }

    private func axis(_ secs: Double) -> String {
        if secs == 0 { return "0" }
        let h = Int(secs) / 3600, m = Int(secs) % 3600 / 60
        if m == 0 { return tr("\(h)小时", "\(h)h") }
        return h == 0 ? tr("\(m)分", "\(m)m") : tr("\(h)小时\(m)分", "\(h)h\(m)m")
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.paper.setFill()
        bounds.fill()
        segRects = []
        legendRows = []
        let sums = perDay.map { $0.values.reduce(0, +) }
        let total = sums.reduce(0, +)

        // the summary
        let active = sums.filter { $0 > 0 }.count
        let busiest = sums.indices.max { sums[$0] < sums[$1] }
        let tiles: [(String, String)] = [
            (tr("Claude 干活总时长", "Claude worked"), total > 0 ? Clock.duration(total) : "—"),
            (tr("有活动的日子 · 平均", "Average per active day"), active > 0 ? Clock.duration(total / Double(active)) : "—"),
            (busiest.map { sums[$0] > 0 ? tr("最忙 · ", "Busiest · ") + dayLabel($0, short: true) : tr("最忙", "Busiest") } ?? tr("最忙", "Busiest"),
             busiest.map { sums[$0] > 0 ? Clock.duration(sums[$0]) : "—" } ?? "—"),
        ]
        var x = pad
        for (label, value) in tiles {
            draw(label, Theme.ui(11.5), Theme.muted, in: NSRect(x: x, y: 20, width: 190, height: 16))
            draw(value, Theme.mono(24), Theme.ink, in: NSRect(x: x, y: 38, width: 190, height: 32))
            x += 200
        }
        draw(tr("每天 Claude 干活的时长，按对话分段；同时进行的对话各算各的。", "Hours Claude worked each day, split by chat. Chats running side by side each count."),
             Theme.ui(11.5), Theme.muted, in: NSRect(x: pad, y: 88, width: bounds.width - pad * 3 - range.frame.width, height: 16))

        let plot = self.plot
        guard total > 0 else {
            draw(tr("这段时间还没有记录。Kikumap 开着时，Claude 干活的时长都会记下来。", "Nothing recorded in this range yet. While Kikumap runs, it records how long Claude works."),
                 Theme.ui(13), Theme.muted, in: NSRect(x: plot.minX, y: plot.midY - 10, width: plot.width, height: 20), .center)
            drawLegend(total: 0)
            return
        }

        // y axis: at most four steps of a round size
        let maxDay = sums.max() ?? 0
        let steps: [Double] = [900, 1800, 3600, 7200, 10800, 14400, 21600, 43200, 86400]
        let step = steps.first { maxDay / $0 <= 4 } ?? 86400
        let yMax = step * max(ceil(maxDay / step), 1)
        func yOf(_ s: Double) -> CGFloat { plot.maxY - CGFloat(s / yMax) * plot.height }
        var t = 0.0
        while t <= yMax + 1 {
            let y = yOf(t).rounded() + 0.5
            (t == 0 ? Theme.line : Theme.faint).setFill()
            NSRect(x: plot.minX, y: y - 0.5, width: plot.width, height: 1).fill()
            draw(axis(t), Theme.mono(10.5, .regular), Theme.muted, in: NSRect(x: plot.minX - 50, y: y - 7, width: 44, height: 14), .right)
            t += step
        }

        // the bars
        let n = perDay.count
        let slotW = plot.width / CGFloat(n)
        let barW = max(3, min(30, (slotW * 0.64).rounded()))
        let dim = hover?.part
        if let d = hover?.day {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: NSRect(x: plot.minX + slotW * CGFloat(d) + 1, y: plot.minY - 6, width: slotW - 2, height: plot.height + 6),
                         xRadius: 4, yRadius: 4).fill()
        }
        for (i, day) in perDay.enumerated() {
            let x = (plot.minX + slotW * (CGFloat(i) + 0.5) - barW / 2).rounded()
            var y = plot.maxY
            let parts = stack(day)
            for (j, (part, secs)) in parts.enumerated() {
                let h = CGFloat(secs / yMax) * plot.height
                var r = NSRect(x: x, y: y - h, width: barW, height: h)
                y -= h
                if j > 0 { r.size.height -= 2 }               // a 2 pt gap of background between segments
                guard r.height > 0.5 else { continue }
                segRects.append((i, part, r))
                colour(part).withAlphaComponent(dim == nil || dim == part ? 1 : 0.28).setFill()
                if j == parts.count - 1 {
                    // the data end: rounded on top only
                    let rad = min(4, barW / 2, r.height)
                    let p = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
                    p.append(NSBezierPath(rect: NSRect(x: r.minX, y: r.minY + rad, width: r.width, height: r.height - rad)))
                    p.windingRule = .nonZero
                    p.fill()
                } else {
                    r.fill()
                }
            }
        }

        // dates, as many as fit (always today)
        let short = n > 7 || slotW < 52
        let stride = max(1, Int(ceil((short ? 46 : 52) / slotW)))
        for i in 0..<n where (n - 1 - i) % stride == 0 {
            let cx = plot.minX + slotW * (CGFloat(i) + 0.5)
            let today = i == n - 1
            draw(dayLabel(i, short: short), today ? Theme.ui(11, .semibold) : Theme.ui(11), today ? Theme.ink : Theme.muted,
                 in: NSRect(x: cx - 40, y: plot.maxY + 8, width: 80, height: 16), .center)
        }

        drawLegend(total: total)
        drawTip(plot: plot)
    }

    /// The legend: colour, chat, total — the chart's numbers as a table.
    private func drawLegend(total: Double) {
        let w = legendWidth
        let x = bounds.width - pad - w
        var y = top - 6
        let chats = totals.filter { $0.value > 0 }
        draw(tr("对话 · \(chats.count)", "Chats · \(chats.count)"), Theme.ui(11.5, .semibold), Theme.muted, in: NSRect(x: x, y: y, width: w, height: 16))
        y += 24
        var rows: [(Part, String, Double)] = slots.keys.compactMap { id in totals[id].map { (Part.chat(id), store.name(id), $0) } }
            .sorted { $0.2 > $1.2 }
        let rest = chats.filter { slots[$0.key] == nil }
        if !rest.isEmpty {
            rows.append((.other, tr("其他 \(rest.count) 个对话", "\(rest.count) other chats"), rest.values.reduce(0, +)))
        }
        for (part, title, secs) in rows {
            guard y + 24 < bounds.height - 12 else { break }
            let r = NSRect(x: x - 6, y: y - 4, width: w + 12, height: 24)
            legendRows.append((part, r))
            if hover?.part == part && hover?.day == nil {
                Theme.hover.setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            colour(part).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 3, width: 10, height: 10), xRadius: 3, yRadius: 3).fill()
            let value = Clock.duration(secs)
            let vw = (value as NSString).size(withAttributes: attrs(Theme.mono(11.5, .regular), Theme.ink)).width
            draw(title, Theme.ui(12), Theme.ink, in: NSRect(x: x + 18, y: y, width: w - 26 - vw, height: 16))
            draw(value, Theme.mono(11.5, .regular), Theme.ink, in: NSRect(x: x + w - vw - 2, y: y, width: vw + 2, height: 16), .right)
            y += 26
        }
    }

    /// The tooltip for the hovered bar or segment.
    private func drawTip(plot: NSRect) {
        guard let h = hover, let d = h.day, d < perDay.count else { return }
        let day = perDay[d]
        let sum = day.values.reduce(0, +)
        let date = d == perDay.count - 1 ? tr("今天", "Today") : Clock.format(starts[d], "M月d日 EEE", "EEE, MMM d")
        var lines: [(String, NSFont, NSColor)] = []
        switch h.part {
        case .chat(let id)?:
            lines = [(store.name(id), Theme.ui(12, .semibold), Theme.ink),
                     (date + " · " + Clock.duration(day[id] ?? 0), Theme.ui(11.5), Theme.ink),
                     (tr("当天共 ", "Day total ") + Clock.duration(sum), Theme.ui(11.5), Theme.muted)]
        case .other?:
            let rest = day.filter { slots[$0.key] == nil }
            lines = [(tr("其他 \(rest.count) 个对话", "\(rest.count) other chats"), Theme.ui(12, .semibold), Theme.ink),
                     (date + " · " + Clock.duration(rest.values.reduce(0, +)), Theme.ui(11.5), Theme.ink)]
            for (id, s) in rest.sorted(by: { $0.value > $1.value }).prefix(4) {
                lines.append(("  " + store.name(id) + " · " + Clock.duration(s), Theme.ui(11), Theme.muted))
            }
        case nil:
            guard sum > 0 else { return }
            lines = [(date, Theme.ui(12, .semibold), Theme.ink),
                     (tr("共 ", "Total ") + Clock.duration(sum) + tr(" · \(day.count) 个对话", " · \(day.count) chats"), Theme.ui(11.5), Theme.ink)]
        }
        let w = min(300, lines.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]).width }.max()! + 24)
        let ht = CGFloat(lines.count) * 17 + 14
        var r = NSRect(x: mouse.x + 14, y: mouse.y + 14, width: w, height: ht)
        if r.maxX > bounds.width - 8 { r.origin.x = mouse.x - w - 14 }
        if r.maxY > bounds.height - 8 { r.origin.y = mouse.y - ht - 10 }
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = 10
        sh.shadowOffset = NSSize(width: 0, height: -2)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.18)
        sh.set()
        Theme.paper.setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.faint.setStroke()
        NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
        var y = r.minY + 7
        for (s, f, c) in lines {
            draw(s, f, c, in: NSRect(x: r.minX + 12, y: y, width: w - 24, height: 17))
            y += 17
        }
    }

    // MARK: mouse

    private func hit(_ p: NSPoint) -> Hit? {
        if let row = legendRows.first(where: { $0.rect.contains(p) }) { return Hit(day: nil, part: row.part) }
        let plot = self.plot
        guard !perDay.isEmpty, p.x >= plot.minX, p.x < plot.maxX, p.y >= plot.minY - 6, p.y <= plot.maxY + 24 else { return nil }
        let d = min(Int((p.x - plot.minX) / (plot.width / CGFloat(perDay.count))), perDay.count - 1)
        // the whole column is the target, not just the thin bar
        let seg = segRects.first { $0.day == d && p.y >= $0.rect.minY - 1 && p.y <= $0.rect.maxY + 2 }
        return Hit(day: d, part: seg?.part)
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        let h = hit(mouse)
        if case .chat? = h?.part { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if h != hover || h?.day != nil {
            hover = h
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if case .chat(let id)? = hit(convert(event.locationInWindow, from: nil))?.part { onOpen?(id) }
    }
}
