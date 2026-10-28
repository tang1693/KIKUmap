import Cocoa

/// Minimal 5-field cron ("CRON_TZ=Zone m h dom mon dow") — enough to place upcoming runs on the timeline.
struct Cron {
    let minutes: Set<Int>, hours: Set<Int>, doms: Set<Int>, months: Set<Int>, dows: Set<Int>
    let domAny: Bool, dowAny: Bool
    let tz: TimeZone

    init?(_ expr: String) {
        var parts = expr.split(separator: " ").map(String.init)
        var zone = TimeZone.current
        if let first = parts.first, first.hasPrefix("CRON_TZ=") {
            zone = TimeZone(identifier: String(first.dropFirst(8))) ?? .current
            parts.removeFirst()
        }
        guard parts.count == 5 else { return nil }
        func field(_ s: String, _ lo: Int, _ hi: Int) -> Set<Int>? {
            var out = Set<Int>()
            for item in s.split(separator: ",") {
                let stepParts = item.split(separator: "/")
                let step = stepParts.count > 1 ? Int(stepParts[1]) ?? 1 : 1
                var a = lo, b = hi
                let base = String(stepParts[0])
                if base != "*" {
                    let r = base.split(separator: "-").compactMap { Int($0) }
                    guard !r.isEmpty else { return nil }
                    a = r[0]; b = r.count > 1 ? r[1] : (stepParts.count > 1 ? hi : r[0])
                }
                guard a <= b else { return nil }
                for v in stride(from: a, through: b, by: max(1, step)) { out.insert(v) }
            }
            return out
        }
        guard let mi = field(parts[0], 0, 59), let h = field(parts[1], 0, 23), let d = field(parts[2], 1, 31),
              let mo = field(parts[3], 1, 12), var w = field(parts[4], 0, 7) else { return nil }
        if w.contains(7) { w.insert(0) }
        minutes = mi; hours = h; doms = d; months = mo; dows = w
        domAny = parts[2] == "*"; dowAny = parts[4] == "*"
        tz = zone
    }

    /// Run times in [from, to], at most `limit`.
    func runs(from: Date, to: Date, limit: Int = 200) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var out: [Date] = []
        // whole minutes in absolute time, so daylight-saving changes can never send t backwards
        var t = Date(timeIntervalSinceReferenceDate: (from.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
        var steps = 0
        while t <= to && out.count < limit && steps < 100_000 {
            steps += 1
            let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: t)
            guard let mo = c.month, let d = c.day, let wd = c.weekday, let h = c.hour, let m = c.minute else { break }
            let dayOK: Bool
            if domAny || dowAny { dayOK = doms.contains(d) && dows.contains(wd - 1) }
            else { dayOK = doms.contains(d) || dows.contains(wd - 1) }
            var next = t.addingTimeInterval(60)
            if !months.contains(mo) || !dayOK {
                // jump to the next day
                if let n = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t)) { next = n }
            } else if !hours.contains(h) {
                // jump to the next hour
                next = t.addingTimeInterval(Double(60 - m) * 60)
            } else if minutes.contains(m) {
                out.append(t)
            }
            t = max(next, t.addingTimeInterval(60))
        }
        return out
    }
}

/// Windy-style time strip: what ran, what's running, what's coming.
@MainActor
final class TimelineView: NSView {
    let store: Store
    let usage: UsageMonitor
    var onOpenChat: ((String) -> Void)?
    var onOpenRoutines: (() -> Void)?

    private var start = Date().addingTimeInterval(-10 * 3600)
    private var spp: Double = 150            // seconds per point
    private var follow = true
    private var hoverX: CGFloat?
    private var hoverP: NSPoint?
    private var drag: (x: CGFloat, start: Date, moved: Bool)?
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var cronRuns: [String: [Date]] = [:]
    private var hits: [(NSRect, String, () -> Void)] = []

    private let labelW: CGFloat = 70
    private let rowTop: CGFloat = 34
    private let laneH: CGFloat = 26
    private var lanes: [String] { [tr("进行中", "Running"), tr("计划任务", "Scheduled")] }
    private var lanesBottom: CGFloat { rowTop + laneH * CGFloat(lanes.count) }
    private var ranges: [(String, Double)] { [(tr("12小时", "12h"), 12), (tr("2天", "2d"), 48), (tr("7天", "7d"), 168)] }

    init(store: Store, usage: UsageMonitor) {
        self.store = store
        self.usage = usage
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 160))
        timer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func tick() { if window?.isVisible == true { needsDisplay = true } }

    func reload() {
        cronRuns = [:]
        let from = Date().addingTimeInterval(-86400), to = Date().addingTimeInterval(10 * 86400)
        for r in usage.routines where r.enabled && !r.cron.isEmpty {
            cronRuns[r.id] = Cron(r.cron)?.runs(from: from, to: to) ?? []
        }
        needsDisplay = true
    }

    /// Upcoming scheduled runs, soonest first.
    static func upcoming(_ routines: [Routine]) -> [(Routine, Date)] {
        var out: [(Routine, Date)] = []
        let now = Date()
        for r in routines {
            if let d = r.upcoming, d > now { out.append((r, d)) }
            if r.enabled, !r.cron.isEmpty, !out.contains(where: { $0.0.id == r.id }), let c = Cron(r.cron),
               let d = c.runs(from: now, to: now.addingTimeInterval(40 * 86400), limit: 1).first {
                out.append((r, d))
            }
        }
        return out.sorted { $0.1 < $1.1 }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: time ↔ x

    private var plotW: CGFloat { bounds.width - labelW - 12 }
    private func x(_ t: Date) -> CGFloat { labelW + CGFloat(t.timeIntervalSince(start) / spp) }
    private func time(_ x: CGFloat) -> Date { start.addingTimeInterval(Double(x - labelW) * spp) }
    private func laneY(_ i: Int) -> CGFloat { rowTop + laneH * CGFloat(i) }

    private func keepNow() {
        if follow { start = Date().addingTimeInterval(-Double(plotW) * spp * 0.3) }
    }

    // MARK: drawing

    private func text(_ s: String, _ f: NSFont, _ c: NSColor, at p: NSPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: c])
    }

    override func draw(_ dirtyRect: NSRect) {
        keepNow()
        hits = []
        Theme.paper.setFill(); bounds.fill()
        Theme.faint.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let now = Date()
        let small = Theme.ui(11), smallB = Theme.ui(11, .semibold)
        let cal = Calendar.current
        let left = time(labelW), right = time(bounds.width - 12)

        // header: next scheduled run + range buttons
        var hx: CGFloat = 14
        let head = tr("时间线", "Timeline")
        text(head, Theme.ui(13, .semibold), Theme.ink, at: NSPoint(x: hx, y: 10))
        hx += head.size(Theme.ui(13, .semibold)).width + 16
        if let (r, d) = TimelineView.upcoming(usage.routines).first {
            let s = tr("下一个计划任务：", "Next scheduled task: ") + "\(r.name) · \(Clock.countdown(d))"
            text(s, Theme.ui(12, .semibold), Theme.ink, at: NSPoint(x: hx, y: 10))
            hx += s.size(Theme.ui(12, .semibold)).width + 16
        } else if !usage.hint.isEmpty {
            text(usage.hint, Theme.ui(12), Theme.muted, at: NSPoint(x: hx, y: 10))
        }
        var bx = bounds.width - 14
        for (label, hours) in ranges.reversed() {
            let w = label.size(smallB).width + 14
            bx -= w
            let r = NSRect(x: bx, y: 7, width: w, height: 20)
            let on = abs(Double(plotW) * spp / 3600 - hours) < hours * 0.08
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (on ? Theme.ink : Theme.paper).setFill(); p.fill()
            if !on { Theme.line.setStroke(); p.lineWidth = 1; p.stroke() }
            text(label, smallB, on ? Theme.paper : Theme.ink, at: NSPoint(x: r.minX + 7, y: r.minY + 3))
            hits.append((r, "", { [weak self] in self?.setRange(hours) }))
            bx -= 6
        }
        let nowL = tr("现在", "Now")
        let nowW = nowL.size(smallB).width + 14
        bx -= nowW
        let nowBtn = NSRect(x: bx, y: 7, width: nowW, height: 20)
        let np = NSBezierPath(roundedRect: nowBtn.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Theme.paper.setFill(); np.fill(); Theme.line.setStroke(); np.lineWidth = 1; np.stroke()
        text(nowL, smallB, Theme.ink, at: NSPoint(x: nowBtn.minX + 7, y: nowBtn.minY + 3))
        hits.append((nowBtn, "", { [weak self] in self?.follow = true; self?.needsDisplay = true }))

        // lane labels and night shading
        for (i, l) in lanes.enumerated() {
            let y = laneY(i)
            Theme.faint.setFill(); NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
            text(l, small, Theme.muted, at: NSPoint(x: 14, y: y + 6))
        }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: labelW, y: rowTop, width: bounds.width - labelW, height: bounds.height - rowTop)).addClip()
        var day = cal.startOfDay(for: left)
        while day < right {
            for (a, b) in [(0, 6), (22, 30)] {
                let s = day.addingTimeInterval(Double(a) * 3600), e = day.addingTimeInterval(Double(b) * 3600)
                Theme.hover.withAlphaComponent(0.55).setFill()
                NSRect(x: x(s), y: rowTop, width: x(e) - x(s), height: lanesBottom - rowTop).fill()
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        // lane 0: when Claude was working on each chat
        let y0 = laneY(0) + 6
        var spans: [(String, Date, Date, Bool)] = store.intervals.compactMap { iv in
            guard let s = Clock.parse(iv.start), let e = Clock.parse(iv.end) else { return nil }
            return (iv.id, s, e, false)
        }
        for (id, s) in store.runStart { if let d = Clock.parse(s) { spans.append((id, d, now, true)) } }
        spans = spans.filter { store.isShown(id: $0.0) }
        for (id, s, e, live) in spans where e >= left && s <= right {
            let r = NSRect(x: x(s), y: y0, width: max(4, x(e) - x(s)), height: laneH - 12)
            // your branch colour if the chat has one, otherwise neutral
            let base = store.branchColor(id) ?? Theme.muted
            (live ? base : base.withAlphaComponent(0.55)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            if live {
                Theme.ink.setStroke()
                let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3); o.lineWidth = 1; o.stroke()
            }
            let name = store.mapLabel(id)
            if r.width > 46 {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: r.insetBy(dx: 4, dy: 0)).addClip()
                text(name, Theme.ui(10.5, .semibold), .white, at: NSPoint(x: r.minX + 5, y: r.minY + 1))
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            let tip = "\(store.name(id))\n\(Self.hm(s)) – \(live ? tr("进行中", "running") : Self.hm(e)) (\(Self.dur(e.timeIntervalSince(s))))"
            hits.append((r, tip, { [weak self] in self?.onOpenChat?(id) }))
        }

        // lane 1: scheduled tasks — past runs as blocks, future runs as markers with countdowns
        let y1 = laneY(1)
        var lastLabelEnd: CGFloat = -1
        var marks: [(Date, String, Bool)] = []
        for r in usage.routines {
            if let f = r.lastFired, f <= right {
                let e = max(r.lastFinished ?? f, f.addingTimeInterval(spp * 4))
                let rect = NSRect(x: x(f), y: y1 + 8, width: max(4, x(e) - x(f)), height: laneH - 16)
                Theme.ink.withAlphaComponent(0.55).setFill(); rect.fill()
                hits.append((rect.insetBy(dx: -3, dy: -4), "\(r.name)\n" + tr("运行于 ", "ran at ") + Self.hm(f), { [weak self] in self?.onOpenRoutines?() }))
            }
            var future = cronRuns[r.id] ?? []
            if future.isEmpty, let n = r.upcoming { future = [n] }
            for d in future where d >= left && d <= right && d > now.addingTimeInterval(-60) {
                marks.append((d, r.name, r.upcoming.map { abs($0.timeIntervalSince(d)) < 61 } ?? false))
            }
        }
        let sortedMarks = marks.sorted(by: { $0.0 < $1.0 })
        for (i, (d, name, isNext)) in sortedMarks.enumerated() {
            let mx = x(d), my = y1 + laneH / 2
            let p = NSBezierPath()
            p.move(to: NSPoint(x: mx, y: my - 7)); p.line(to: NSPoint(x: mx + 7, y: my))
            p.line(to: NSPoint(x: mx, y: my + 7)); p.line(to: NSPoint(x: mx - 7, y: my)); p.close()
            (isNext ? Theme.ink : Theme.muted).setFill(); p.fill()
            let label = isNext ? "\(name) · \(Clock.countdown(d))" : name
            // the label stops before the next marker (hover shows the full name)
            let room = (i + 1 < sortedMarks.count ? x(sortedMarks[i + 1].0) - 12 : bounds.width) - (mx + 11)
            let lw = min(label.size(small).width, room)
            let labelled = mx + 11 > lastLabelEnd && room > 30
            if labelled {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: mx + 11, y: my - 9, width: lw, height: 18)).addClip()
                text(label, isNext ? smallB : small, isNext ? Theme.ink : Theme.muted, at: NSPoint(x: mx + 11, y: my - 7))
                NSGraphicsContext.current?.restoreGraphicsState()
                lastLabelEnd = mx + 11 + lw + 8
            }
            hits.append((NSRect(x: mx - 10, y: my - 11, width: 20 + (labelled ? lw + 4 : 0), height: 22),
                         "\(name)\n\(Self.dayHM(d)) · \(Clock.countdown(d))", { [weak self] in self?.onOpenRoutines?() }))
        }

        NSGraphicsContext.current?.restoreGraphicsState()

        // hour ticks and day strip (Windy-style)
        let tickY = lanesBottom
        Theme.ink.setFill(); NSRect(x: labelW, y: tickY, width: bounds.width - labelW, height: 1).fill()
        let stepH: Int = spp < 60 ? 1 : (spp < 200 ? 3 : (spp < 600 ? 6 : 12))
        var t = cal.date(bySettingHour: 0, minute: 0, second: 0, of: left)!
        while t < right {
            if t >= left {
                let h = cal.component(.hour, from: t)
                let tx = x(t)
                Theme.muted.setFill(); NSRect(x: tx, y: tickY, width: 1, height: h == 0 ? 8 : 4).fill()
                if h % stepH == 0 && h != 0 { text("\(h)", Theme.geo(10), Theme.muted, at: NSPoint(x: tx + 2, y: tickY + 2)) }
            }
            t = t.addingTimeInterval(3600)
        }
        let dayY = tickY + 16
        var d = cal.startOfDay(for: left)
        let df = DateFormatter(); df.locale = Locale(identifier: Prefs.english ? "en_US" : "zh_CN"); df.dateFormat = tr("EEE d日", "EEE d")
        while d < right {
            let next = cal.date(byAdding: .day, value: 1, to: d)!
            let a = max(x(d), labelW), b = min(x(next), bounds.width - 12)
            if b > a {
                let today = cal.isDateInToday(d)
                let r = NSRect(x: a + 1, y: dayY, width: b - a - 2, height: 20)
                (today ? Theme.ink : Theme.faint).setFill(); r.fill()
                let label = today ? tr("今天 ", "Today ") + df.string(from: d) : df.string(from: d)
                if r.width > label.size(smallB).width + 10 {
                    text(label, smallB, today ? Theme.paper : Theme.ink, at: NSPoint(x: r.minX + 6, y: r.minY + 3))
                }
                let dd = d
                hits.append((r, "", { [weak self] in
                    guard let self = self else { return }
                    self.follow = false
                    self.start = dd.addingTimeInterval(-3600)
                    self.needsDisplay = true
                }))
            }
            d = next
        }

        // now line
        let nx = x(now)
        if nx >= labelW && nx <= bounds.width {
            Theme.ink.setFill()
            NSRect(x: nx - 0.75, y: rowTop, width: 1.5, height: tickY - rowTop + 8).fill()
            let s = Self.hm(now)
            let w = s.size(Theme.mono(10, .bold)).width + 8
            let r = NSRect(x: nx - w / 2, y: rowTop - 2, width: w, height: 13)
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            text(s, Theme.mono(10, .bold), Theme.paper, at: NSPoint(x: r.minX + 4, y: r.minY))
        }

        // hover cursor with time bubble and details
        if let hx = hoverX, hx > labelW {
            let ht = time(hx)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: hx, y: rowTop)); p.line(to: NSPoint(x: hx, y: tickY))
            p.lineWidth = 1; p.setLineDash([3, 3], count: 2, phase: 0)
            Theme.ink.setStroke(); p.stroke()
            let s = Self.dayHM(ht) + (ht > now ? " · \(Clock.countdown(ht))" : "")
            let w = s.size(smallB).width + 12
            let r = NSRect(x: min(max(hx - w / 2, labelW), bounds.width - w - 4), y: tickY + 1, width: w, height: 16)
            Theme.ink.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            text(s, smallB, Theme.paper, at: NSPoint(x: r.minX + 6, y: r.minY + 1))
        }

        // hovering a run or a scheduled task: its name and times in a bubble
        if let hp = hoverP, drag?.moved != true, let tip = hits.last(where: { $0.0.contains(hp) && !$0.1.isEmpty })?.1 {
            let lines = tip.components(separatedBy: "\n")
            let fonts = lines.indices.map { $0 == 0 ? smallB : small }
            let lh: CGFloat = 15
            let w = min(420, (zip(lines, fonts).map { $0.size($1).width }.max() ?? 0) + 16)
            let h = lh * CGFloat(lines.count) + 8
            var r = NSRect(x: hp.x + 12, y: hp.y - h - 6, width: w, height: h)
            if r.maxX > bounds.width - 4 { r.origin.x = hp.x - 12 - w }
            if r.minY < 2 { r.origin.y = hp.y + 14 }
            NSGraphicsContext.current?.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = 6; sh.shadowColor = NSColor.black.withAlphaComponent(0.25); sh.set()
            Theme.ink.setFill(); NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: r.insetBy(dx: 6, dy: 0)).addClip()
            for (i, l) in lines.enumerated() {
                text(l, fonts[i], Theme.paper, at: NSPoint(x: r.minX + 8, y: r.minY + 4 + lh * CGFloat(i)))
            }
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }

    static func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    static func dayHM(_ d: Date) -> String {
        Clock.format(d, "M月d日 EEE HH:mm", "MMM d, EEE HH:mm")
    }
    static func dur(_ s: TimeInterval) -> String {
        s < 3600 ? tr("\(max(1, Int(s / 60)))分钟", "\(max(1, Int(s / 60)))m") : String(format: tr("%.1f小时", "%.1fh"), s / 3600)
    }

    // MARK: interaction

    private func setRange(_ hours: Double) {
        spp = hours * 3600 / Double(max(100, plotW))
        follow = true
        needsDisplay = true
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        hoverX = p.x
        hoverP = p
        needsDisplay = true
    }

    override func mouseExited(with e: NSEvent) { hoverX = nil; hoverP = nil; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        drag = (p.x, start, false)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { return }
        let p = convert(e.locationInWindow, from: nil)
        if abs(p.x - d.x) > 3 || d.moved {
            drag = (d.x, d.start, true)
            follow = false
            start = d.start.addingTimeInterval(-Double(p.x - d.x) * spp)
            hoverX = p.x
            needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = nil }
        guard let d = drag, !d.moved else { return }
        let p = convert(e.locationInWindow, from: nil)
        if e.clickCount == 2 && p.y > rowTop { follow = true; needsDisplay = true; return }
        if let h = hits.last(where: { $0.0.contains(p) }) { h.2() }
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            zoom(by: e.scrollingDeltaY > 0 ? 1 / 1.1 : 1.1, at: convert(e.locationInWindow, from: nil).x)
            return
        }
        let dx = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        follow = false
        start = start.addingTimeInterval(-Double(dx) * spp * (e.hasPreciseScrollingDeltas ? 1 : 8))
        needsDisplay = true
    }

    override func magnify(with e: NSEvent) {
        zoom(by: 1 / (1 + e.magnification), at: convert(e.locationInWindow, from: nil).x)
    }

    private func zoom(by f: Double, at px: CGFloat) {
        let anchor = time(px)
        spp = min(3600, max(15, spp * f))
        start = anchor.addingTimeInterval(-Double(px - labelW) * spp)
        if follow {
            follow = false
        }
        needsDisplay = true
    }
}
