import Cocoa

/// The statistics window: how long Claude worked — one bar per hour, few hours, day or two days, a
/// segment per chat.
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
    /// Store changes come often (every read of Claude's sidebar): the chart is worked out again at most every
    /// 15 seconds (its own timer keeps a running chat's bar moving).
    private var lastReload = Date.distantPast
    private var reloadPending = false
    func refresh() {
        guard window?.isVisible == true else { return }
        let since = Date().timeIntervalSince(lastReload), wait = since < 0 ? 0 : 15 - since
        if wait <= 0 { lastReload = Date(); chart?.reload(); return }
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.reloadPending = false
                self.lastReload = Date()
                if self.window?.isVisible == true { self.chart?.reload() }
            }
        }
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

    /// How many chats are named in the chart and the legend; the rest share "other chats".
    static let named = 7
    /// The colour the chats too small to name share (a named chat wears its branch's, see `colour`).
    static let otherColour = Theme.dyn(0xB9B9BC, 0x57575C)

    private enum Part: Equatable { case chat(String), other }
    private struct Hit: Equatable { var bar: Int?; var part: Part? }

    private static let choices = [7, 14, 30, 90]
    /// Hours per bar. A range shows at most `maxBars` bars: picking one that would show more changes the other.
    private static let spans = [1, 3, 6, 12, 24, 48]
    private static let maxBars = 180
    private static func fits(_ days: Int, _ hours: Int) -> Bool { days * 24 / hours <= maxBars }
    private let range = NSSegmentedControl()
    private let every = NSSegmentedControl()
    private var days: Int {
        get { let d = UserDefaults.standard.integer(forKey: "StatsDays"); return Self.choices.contains(d) ? d : 14 }
        set { UserDefaults.standard.set(newValue, forKey: "StatsDays") }
    }
    private var hours: Int {
        get { let h = UserDefaults.standard.integer(forKey: "StatsHours"); return Self.spans.contains(h) ? h : 24 }
        set { UserDefaults.standard.set(newValue, forKey: "StatsHours") }
    }
    private var starts: [Date] = []                  // each bar's start, then the next one's
    private var perBar: [[String: Double]] = []
    private var dayStarts: [Date] = []               // the summary goes by day: each day's start, then tomorrow's
    private var daySums: [Double] = []
    /// How much of the range's time is estimated (stretches Kikumap didn't see): in all, by day, by bar and chat.
    private var estTotal: Double = 0
    private var estDays: [Double] = []
    private var estPerBar: [[String: Double]] = []
    private var estTotals: [String: Double] = [:]
    /// A time, with "≈" when a minute or more of it is estimated.
    private func dur(_ secs: Double, _ est: Double) -> String { (est >= 60 ? "≈" : "") + Clock.duration(secs) }
    private var totals: [String: Double] = [:]
    /// Chat → colour. Kept while the window lives, so a chat keeps its colour when the range changes.
    private var slots: [String: Int] = [:]
    private var hover: Hit?
    private var mouse = NSPoint.zero
    private var segRects: [(bar: Int, part: Part, rect: NSRect)] = []
    private var legendRows: [(part: Part, rect: NSRect)] = []

    private let pad: CGFloat = 24
    private let top: CGFloat = 150

    init(store: Store) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 880, height: 560))
        range.segmentStyle = .rounded
        range.trackingMode = .selectOne
        range.target = self
        range.action = #selector(pickRange)
        addSubview(range)
        every.segmentStyle = .rounded
        every.trackingMode = .selectOne
        every.target = self
        every.action = #selector(pickEvery)
        addSubview(every)
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
        every.segmentCount = Self.spans.count
        for (i, h) in Self.spans.enumerated() {
            every.setLabel(h == 1 ? tr("每小时", "1h") : tr("每\(h)小时", "\(h)h"), forSegment: i)
            every.setWidth(0, forSegment: i)
        }
        every.selectedSegment = Self.spans.firstIndex(of: hours) ?? 4
        every.toolTip = tr("每根柱子是多长时间", "How long each bar is")
        every.sizeToFit()
        needsLayout = true
        needsDisplay = true
    }

    @objc private func pickRange() {
        days = Self.choices[max(range.selectedSegment, 0)]
        if !Self.fits(days, hours) { hours = Self.spans.first { Self.fits(days, $0) } ?? 24 }     // wider bars
        every.selectedSegment = Self.spans.firstIndex(of: hours) ?? 4
        hover = nil
        reload()
    }

    @objc private func pickEvery() {
        hours = Self.spans[max(every.selectedSegment, 0)]
        if !Self.fits(days, hours) { days = Self.choices.last { Self.fits($0, hours) } ?? 7 }      // a shorter range
        range.selectedSegment = Self.choices.firstIndex(of: days) ?? 1
        hover = nil
        reload()
    }

    override func layout() {
        super.layout()
        every.setFrameOrigin(NSPoint(x: pad, y: 108))
        range.setFrameOrigin(NSPoint(x: max(bounds.width - pad - range.frame.width, every.frame.maxX + 12), y: 108))
    }

    /// The summary's days (each day's start, then tomorrow's) and the bars (each bar's start, then the next one's), from
    /// the first day up to the bar that holds `now`. Each day starts at its own first moment, found from its noon, so a
    /// midnight that daylight saving skips (Santiago, Havana, Cairo, Beirut) moves only that day's start.
    static func grid(days: Int, hours: Int, now: Date, cal: Calendar = .current) -> (days: [Date], bars: [Date]) {
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        func day(_ k: Int) -> Date { cal.startOfDay(for: cal.date(byAdding: .day, value: k - days + 1, to: noon) ?? noon) }
        let ds = (0...days).map(day)
        var b: [Date] = []
        if hours >= 24 {
            // whole days, each from its own date
            for k in stride(from: 0, through: days + hours / 24, by: hours / 24) {
                b.append(day(k))
                if b[b.count - 1] > now || b.count > maxBars + 1 { break }
            }
        } else if hours == 1 {
            // hours one by one (the hour that comes twice when daylight saving ends is two bars)
            b = [ds[0]]
            while let last = b.last, last <= now, b.count <= maxBars + 1, let next = cal.date(byAdding: .hour, value: 1, to: last) { b.append(next) }
        } else {
            // 3, 6, 12 hours: the same clock hours every day (0:00, 6:00…); a skipped hour moves to the next one
            fill: for d in ds {
                for h in stride(from: 0, to: 24, by: hours) {
                    guard let t = h == 0 ? d : cal.date(bySettingHour: h, minute: 0, second: 0, of: d), t > (b.last ?? .distantPast) else { continue }
                    b.append(t)
                    if t > now || b.count > maxBars + 1 { break fill }
                }
            }
        }
        return (ds, b)
    }

    func reload() {
        (dayStarts, starts) = Self.grid(days: days, hours: hours, now: Date())
        daySums = store.worked(dayStarts).map { $0.values.reduce(0, +) }
        estDays = store.estimated(dayStarts).map { $0.values.reduce(0, +) }
        estTotal = estDays.reduce(0, +)
        estPerBar = store.estimated(starts)
        estTotals = [:]
        for d in estPerBar { for (id, s) in d { estTotals[id, default: 0] += s } }
        perBar = store.worked(starts, wholeDays: hours >= 24)
        totals = [:]
        for d in perBar { for (id, s) in d { totals[id, default: 0] += s } }
        let top = totals.sorted { $0.value > $1.value }.prefix(Self.named).map { $0.key }
        slots = slots.filter { top.contains($0.key) }
        var free = (0..<Self.named).filter { s in !slots.values.contains(s) }
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

    /// A chat wears the colour you gave its branch on the map, as in the timeline; one you gave none is grey.
    private func colour(_ p: Part) -> NSColor {
        if case .chat(let id) = p { return store.branchColor(id) ?? Theme.muted }
        return Self.otherColour
    }

    /// A day of the summary.
    private func dayLabel(_ i: Int) -> String {
        i == daySums.count - 1 ? tr("今天", "Today") : Clock.format(dayStarts[i], "M/d", "MMM d")
    }

    /// Under a bar of a day or more: its date ("Today" for the one that holds now).
    private func barDay(_ i: Int, short: Bool) -> String {
        if starts[i] <= Date() && Date() < starts[i + 1] { return tr("今天", "Today") }
        return short ? Clock.format(starts[i], "M/d", "MMM d") : Clock.format(starts[i], "EEE d", "EEE d")
    }

    /// A bar's time, for the tooltip.
    private func barTitle(_ i: Int) -> String {
        let a = starts[i], b = starts[i + 1]
        if hours == 24 { return barDay(i, short: false) == tr("今天", "Today") ? tr("今天", "Today") : Clock.format(a, "M月d日 EEE", "EEE, MMM d") }
        if hours > 24 { return Clock.format(a, "M月d日", "MMM d") + " – " + Clock.format(b.addingTimeInterval(-1), "M月d日", "MMM d") }
        let day = Calendar.current.isDateInToday(a) ? tr("今天 ", "Today ") : Clock.format(a, "M月d日 EEE ", "EEE, MMM d, ")
        return day + Clock.format(a, "H:mm", "H:mm") + "–" + Clock.format(b, "H:mm", "H:mm")
    }

    /// The labels under the bars, as many as fit: dates under bars of a day or more; otherwise the time at
    /// round hours, and the date where a day starts (at the bar's left edge, where its time begins).
    private func xLabels(slotW: CGFloat) -> [(bar: Int, text: String, bold: Bool, edge: Bool)] {
        let n = perBar.count
        if hours >= 24 {
            let short = n > 7 || slotW < 52
            let stride = max(1, Int(ceil((short ? 46 : 52) / slotW)))
            return (0..<n).filter { (n - 1 - $0) % stride == 0 }.map {
                let t = barDay($0, short: short)
                return ($0, t, t == tr("今天", "Today"), false)
            }
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let step = [1, 2, 3, 6, 12, 24, 48, 72, 168].first { $0 % hours == 0 && CGFloat($0 / hours) * slotW >= 44 } ?? 168
        return (0..<n).compactMap { i in
            let d = starts[i], h = cal.component(.hour, from: d)
            // a day's start, also where daylight saving skips midnight and the day starts at 1:00
            let midnight = d == cal.startOfDay(for: d)
            if step >= 24 {
                // (days counted, not 24-hour spans: a day that starts at 1:00, its midnight skipped, is a whole one)
                let back = Clock.days(from: d, to: today, cal)
                guard midnight, back % (step / 24) == 0 else { return nil }
            } else {
                guard midnight || h % step == 0 else { return nil }
            }
            let isToday = cal.isDateInToday(d)
            let text = !midnight ? Clock.format(d, "H:mm", "H:mm") : isToday ? tr("今天", "Today") : Clock.format(d, "M/d", "MMM d")
            return (i, text, midnight && isToday, true)
        }
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
        let sums = perBar.map { $0.values.reduce(0, +) }
        let total = daySums.reduce(0, +)

        // the summary, by day
        let active = daySums.filter { $0 > 0 }.count
        let busiest = daySums.indices.max { daySums[$0] < daySums[$1] }
        let tiles: [(String, String)] = [
            (tr("\(GPTWatcher.who) 干活总时长", "\(GPTWatcher.who) worked"), total > 0 ? (estTotal >= 60 ? "≈" : "") + Clock.duration(total) : "—"),
            (tr("有活动的日子 · 平均", "Average per active day"), active > 0 ? dur(total / Double(active), estTotal / Double(active)) : "—"),
            (busiest.map { daySums[$0] > 0 ? tr("最忙 · ", "Busiest · ") + dayLabel($0) : tr("最忙", "Busiest") } ?? tr("最忙", "Busiest"),
             busiest.map { daySums[$0] > 0 ? dur(daySums[$0], $0 < estDays.count ? estDays[$0] : 0) : "—" } ?? "—"),
        ]
        var x = pad
        for (label, value) in tiles {
            draw(label, Theme.ui(11.5), Theme.muted, in: NSRect(x: x, y: 20, width: 190, height: 16))
            draw(value, Theme.mono(24), Theme.ink, in: NSRect(x: x, y: 38, width: 190, height: 32))
            x += 200
        }
        let per = hours == 24 ? tr("每天", "each day") : hours == 48 ? tr("每 2 天", "every 2 days")
            : hours == 1 ? tr("每小时", "each hour") : tr("每 \(hours) 小时", "every \(hours) hours")
        var note = tr("\(per) \(GPTWatcher.who) 干活的时长，按对话分段；几个对话同时进行时，平分那段时间。",
                      "Hours \(GPTWatcher.who) worked \(per), split by chat. Chats running side by side share the time.")
        if estTotal >= 60 {
            note += tr(" 其中 ≈\(Clock.duration(estTotal)) 是估算：Kikumap 看不到的时候（Claude 窗口关了、Codex 任务没动静），按你一次运行的常见时长算。",
                       " ≈\(Clock.duration(estTotal)) of it is estimated: while Kikumap couldn't see (Claude's window closed, a Codex task quiet), at your typical run's length.")
        }
        if hours < 24, let until = store.dailyOnlyUntil, until > dayStarts[0] {
            let d = Clock.format(until, "M月d日", "MMM d")
            note += tr(" \(d) 以前只记了每天的总数，要按天看。", " Before \(d) only daily totals were kept: see those by day.")
        }
        draw(note, Theme.ui(11.5), Theme.muted, in: NSRect(x: pad, y: 84, width: bounds.width - pad * 2, height: 16))

        let plot = self.plot
        guard sums.reduce(0, +) > 0 else {
            draw(tr("这段时间还没有记录。Kikumap 开着时，\(GPTWatcher.who) 干活的时长都会记下来。", "Nothing recorded in this range yet. While Kikumap runs, it records how long \(GPTWatcher.who) work."),
                 Theme.ui(13), Theme.muted, in: NSRect(x: plot.minX, y: plot.midY - 10, width: plot.width, height: 20), .center)
            drawLegend(total: 0)
            return
        }

        // y axis: at most four steps of a round size
        let maxBar = sums.max() ?? 0
        let steps: [Double] = [300, 600, 900, 1800, 3600, 7200, 10800, 14400, 21600, 43200, 86400, 172800]
        let step = steps.first { maxBar / $0 <= 4 } ?? 172800
        let yMax = step * max(ceil(maxBar / step), 1)
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
        let n = perBar.count
        let slotW = plot.width / CGFloat(n)
        let barW = max(min(3, slotW - 1), min(30, (slotW * 0.64).rounded()))
        let dim = hover?.part
        if let d = hover?.bar {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: NSRect(x: plot.minX + slotW * CGFloat(d) + 1, y: plot.minY - 6, width: slotW - 2, height: plot.height + 6),
                         xRadius: 4, yRadius: 4).fill()
        }
        for (i, bar) in perBar.enumerated() {
            let x = (plot.minX + slotW * (CGFloat(i) + 0.5) - barW / 2).rounded()
            var y = plot.maxY
            let parts = stack(bar)
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

        for l in xLabels(slotW: slotW) {
            let cx = plot.minX + slotW * (CGFloat(l.bar) + (l.edge ? 0 : 0.5))
            draw(l.text, l.bold ? Theme.ui(11, .semibold) : Theme.ui(11), l.bold ? Theme.ink : Theme.muted,
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
            rows.append((.other, tr("其他 \(rest.count) 个对话", rest.count == 1 ? "1 other chat" : "\(rest.count) other chats"), rest.values.reduce(0, +)))
        }
        func estimated(_ part: Part) -> Double {
            if case .chat(let id) = part { return estTotals[id] ?? 0 }
            return estTotals.filter { slots[$0.key] == nil }.values.reduce(0, +)
        }
        for (part, title, secs) in rows {
            guard y + 24 < bounds.height - 12 else { break }
            let r = NSRect(x: x - 6, y: y - 4, width: w + 12, height: 24)
            legendRows.append((part, r))
            if hover?.part == part && hover?.bar == nil {
                Theme.hover.setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            colour(part).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y + 3, width: 10, height: 10), xRadius: 3, yRadius: 3).fill()
            let value = dur(secs, estimated(part))
            let vw = (value as NSString).size(withAttributes: attrs(Theme.mono(11.5, .regular), Theme.ink)).width
            draw(title, Theme.ui(12), Theme.ink, in: NSRect(x: x + 18, y: y, width: w - 26 - vw, height: 16))
            draw(value, Theme.mono(11.5, .regular), Theme.ink, in: NSRect(x: x + w - vw - 2, y: y, width: vw + 2, height: 16), .right)
            y += 26
        }
    }

    /// The tooltip for the hovered bar or segment.
    private func drawTip(plot: NSRect) {
        guard let h = hover, let d = h.bar, d < perBar.count else { return }
        let day = perBar[d]
        let sum = day.values.reduce(0, +)
        let est = d < estPerBar.count ? estPerBar[d] : [:], estSum = est.values.reduce(0, +)
        let date = barTitle(d)
        var lines: [(String, NSFont, NSColor)] = []
        switch h.part {
        case .chat(let id)?:
            lines = [(store.name(id), Theme.ui(12, .semibold), Theme.ink),
                     (date + " · " + dur(day[id] ?? 0, est[id] ?? 0), Theme.ui(11.5), Theme.ink),
                     (tr("合计 ", "Total ") + dur(sum, estSum), Theme.ui(11.5), Theme.muted)]
        case .other?:
            let rest = day.filter { slots[$0.key] == nil }
            lines = [(tr("其他 \(rest.count) 个对话", rest.count == 1 ? "1 other chat" : "\(rest.count) other chats"), Theme.ui(12, .semibold), Theme.ink),
                     (date + " · " + dur(rest.values.reduce(0, +), est.filter { slots[$0.key] == nil }.values.reduce(0, +)), Theme.ui(11.5), Theme.ink)]
            for (id, s) in rest.sorted(by: { $0.value > $1.value }).prefix(4) {
                lines.append(("  " + store.name(id) + " · " + dur(s, est[id] ?? 0), Theme.ui(11), Theme.muted))
            }
        case nil:
            guard sum > 0 else { return }
            lines = [(date, Theme.ui(12, .semibold), Theme.ink),
                     (tr("共 ", "Total ") + dur(sum, estSum) + tr(" · \(day.count) 个对话", " · \(day.count) chats"), Theme.ui(11.5), Theme.ink)]
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
        if let row = legendRows.first(where: { $0.rect.contains(p) }) { return Hit(bar: nil, part: row.part) }
        let plot = self.plot
        guard !perBar.isEmpty, p.x >= plot.minX, p.x < plot.maxX, p.y >= plot.minY - 6, p.y <= plot.maxY + 24 else { return nil }
        let d = min(Int((p.x - plot.minX) / (plot.width / CGFloat(perBar.count))), perBar.count - 1)
        // the whole column is the target, not just the thin bar
        let seg = segRects.first { $0.bar == d && p.y >= $0.rect.minY - 1 && p.y <= $0.rect.maxY + 2 }
        return Hit(bar: d, part: seg?.part)
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        let h = hit(mouse)
        if case .chat(let id)? = h?.part, store.canOpen(id) { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if h != hover || h?.bar != nil {
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
        if case .chat(let id)? = hit(convert(event.locationInWindow, from: nil))?.part, store.canOpen(id) { onOpen?(id) }
    }
}
