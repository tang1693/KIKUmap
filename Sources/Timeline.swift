import Cocoa

/// Minimal 5-field cron ("CRON_TZ=Zone m h dom mon dow") — enough to place upcoming runs on the timeline.
/// Claude's scheduled tasks are always in UTC (claude.ai's API says so), so UTC unless CRON_TZ= says otherwise.
struct Cron {
    let minutes: Set<Int>, hours: Set<Int>, doms: Set<Int>, months: Set<Int>, dows: Set<Int>
    let domAny: Bool, dowAny: Bool
    let tz: TimeZone

    init?(_ expr: String) {
        var parts = expr.split(separator: " ").map(String.init)
        let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        var zone = utc
        if let first = parts.first, first.hasPrefix("CRON_TZ=") {
            zone = TimeZone(identifier: String(first.dropFirst(8))) ?? utc
            parts.removeFirst()
        }
        guard parts.count == 5 else { return nil }
        func field(_ s: String, _ lo: Int, _ hi: Int) -> Set<Int>? {
            var out = Set<Int>()
            for item in s.split(separator: ",") {
                let stepParts = item.split(separator: "/")
                guard let first = stepParts.first else { return nil }       // "/" alone
                let step = stepParts.count > 1 ? Int(stepParts[1]) ?? 1 : 1
                var a = lo, b = hi
                let base = String(first)
                if base != "*" {
                    let r = base.split(separator: "-").compactMap { Int($0) }
                    guard !r.isEmpty else { return nil }
                    a = r[0]; b = r.count > 1 ? r[1] : (stepParts.count > 1 ? hi : r[0])
                }
                a = max(a, lo); b = min(b, hi)                              // "0-99999" can't run on forever
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
    /// Scheduled tasks come with usage, which is off until you turn it on: the lane says so and offers it.
    var onTurnOnUsage: (() -> Void)?

    private var start = Date().addingTimeInterval(-10 * 3600)
    private var spp: Double = 150            // seconds per point
    private var follow = true
    private var hoverX: CGFloat?
    private var hoverP: NSPoint?
    private var drag: (x: CGFloat, start: Date, moved: Bool)?
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var cronRuns: [String: [Date]] = [:]
    /// Every run, read once per reload (not on every frame): live ones are drawn up to now.
    private var spans: [(id: String, s: Date, e: Date, live: Bool, est: Bool, row: Int)] = []
    /// What the spans were read from. A sleep ends the running ones and a wake starts them again without a reload:
    /// then they're read again, so no bar runs on across the sleep.
    private var spansFrom: (open: [String: String], count: Int) = ([:], 0)
    private var stale: Bool { store.runStart != spansFrom.open || store.intervals.count != spansFrom.count }
    private var hits: [(NSRect, String, () -> Void)] = []

    /// The lanes' names column: 70, or wider where a language names them in more letters.
    private var labelW: CGFloat {
        if let c = labelWFor, c.lang == Prefs.lang { return c.w }   // read for every bar drawn: measured once per language
        let w = max(70, ceil(lanes.map { $0.size(Theme.ui(11)).width }.max() ?? 0) + 22)
        labelWFor = (Prefs.lang, w)
        return w
    }
    private var labelWFor: (lang: Lang, w: CGFloat)?
    private let rowTop: CGFloat = 34
    private let laneH: CGFloat = 26
    private var lanes: [String] { [tr("在跑", "Running"), tr("计划任务", "Scheduled")] }
    private var lanesBottom: CGFloat { rowTop + runLaneH + laneH }
    /// Chats Claude worked on at the same time get rows of their own in the Running lane (up to 4),
    /// and the strip grows to fit them.
    private let rowH: CGFloat = 18, maxRows = 4
    private var runRows = 1
    private var runLaneH: CGFloat { CGFloat(runRows) * rowH + 8 }
    var preferredHeight: CGFloat { 130 + runLaneH - laneH }
    var onHeightChange: (() -> Void)?
    private var ranges: [(String, Double)] {
        [(tr("3小时", "3h"), 3), (tr("6小时", "6h"), 6), (tr("12小时", "12h"), 12), (tr("24小时", "24h"), 24), (tr("2天", "2d"), 48), (tr("7天", "7d"), 168)]
    }
    /// The range chosen (it stays highlighted, and fits the strip whatever its width); nil once you've zoomed freely.
    private var rangeHours: Double? = {
        let h = UserDefaults.standard.double(forKey: "TimelineHours")
        return h > 0 ? h : 24
    }()
    private func applyRange() { if let h = rangeHours { spp = h * 3600 / Double(max(100, plotW)) } }

    init(store: Store, usage: UsageMonitor) {
        self.store = store
        self.usage = usage
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 160))
        timer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func tick() {
        guard window?.isVisible == true else { return }
        // (an estimated stretch of a run out of sight grows with the time too)
        if stale || spans.contains(where: \.est) { reload() } else { needsDisplay = true }
    }

    func reload() {
        cronRuns = [:]
        let from = Date().addingTimeInterval(-86400), to = Date().addingTimeInterval(10 * 86400)
        for r in usage.routines where r.enabled && !r.cron.isEmpty {
            cronRuns[r.id] = Cron(r.cron)?.runs(from: from, to: to) ?? []
        }
        spans = runs(now: Date())
        spansFrom = (store.runStart, store.intervals.count)
        let rows = max(1, (spans.map(\.row).max() ?? 0) + 1)
        if rows != runRows { runRows = rows; onHeightChange?() }
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

    /// Where the header's next-task line goes (`x`), what it says, and whether the title is shown: after the title, as
    /// `nextLine` fits it before ◎ Now (at `nowX`); in a strip too narrow to say there whole how old the list is (Chinese,
    /// zoomed in), in the title's place (the lanes and buttons say what the strip is).
    static func headerLine(name: String, countdown: String, asOf: String?, titleWidth: CGFloat, nowX: CGFloat, font: NSFont)
        -> (x: CGFloat, line: (text: String, whole: Bool)?, titled: Bool) {
        let x = 14 + titleWidth + 16
        let line = nextLine(name: name, countdown: countdown, asOf: asOf, room: nowX - 12 - x, font: font)
        // (only the last way out ends in "…": the as-of cut short)
        if asOf != nil, line?.text.hasSuffix("…") ?? true,
           let alone = nextLine(name: name, countdown: countdown, asOf: asOf, room: nowX - 12 - 14, font: font), !alone.text.hasSuffix("…") {
            return (14, alone, false)
        }
        return (x, line, true)
    }

    /// The header's line about the next scheduled task, as much of it as fits in `room` points (it must end before
    /// ◎ Now): the task's name shortened first, then left out, then all but how old the list is. That ("list as of …",
    /// for a list from an earlier read, `asOf`) is the timeline's only word of it, so it goes last: cut short only when
    /// nothing else is left. `whole`: nothing was left out. nil: no room for it.
    static func nextLine(name: String, countdown: String, asOf: String?, room: CGFloat, font: NSFont) -> (text: String, whole: Bool)? {
        let lead = tr("下一个计划任务：", "Next scheduled task: ")
        let tail = asOf.map { tr(" · \($0) 时的列表", " · list as of \($0)") } ?? ""
        func fits(_ s: String) -> Bool { s.size(font).width <= room }
        let whole = lead + name + " · " + countdown + tail
        if fits(whole) { return (whole, true) }
        // the most of the name that fits, three characters at the least
        let chars = Array(name)
        var lo = 3, hi = chars.count - 1, named: String?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = lead + String(chars[..<mid]).trimmingCharacters(in: .whitespaces) + "… · " + countdown + tail
            if fits(s) { named = s; lo = mid + 1 } else { hi = mid - 1 }
        }
        if let s = named { return (s, false) }
        var shorter = [lead + countdown + tail]
        if let t = asOf { shorter += [tr("计划任务 · \(t) 时的列表", "Scheduled tasks · as of \(t)"), tr("\(t) 时的列表", "List as of \(t)")] }
        if let s = shorter.first(where: fits) { return (s, false) }
        // (without a list that's out of date: nothing that says anything fits, and the lane shows the next one anyway)
        guard asOf != nil, let last = shorter.last else { return nil }
        let cut = Array(last)
        var n = cut.count - 1
        while n > 0 && !fits(String(cut[..<n]) + "…") { n -= 1 }
        return n >= 2 ? (String(cut[..<n]).trimmingCharacters(in: .whitespaces) + "…", false) : nil
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
    private func laneY(_ i: Int) -> CGFloat { i == 0 ? rowTop : rowTop + runLaneH }

    /// Every run with its row: runs are taken in order of start, each on the first row that's free by then.
    /// The same chats as Statistics and the widget count (ChatGPT's only while it's on).
    private func runs(now: Date) -> [(id: String, s: Date, e: Date, live: Bool, est: Bool, row: Int)] {
        var spans: [(String, Date, Date, Bool, Bool)] = store.intervals.compactMap { iv in
            guard let s = Clock.parse(iv.start), let e = Clock.parse(iv.end) else { return nil }
            return (iv.id, s, e, false, iv.est == true)
        }
        // (a Codex task whose log went quiet: seen up to its last activity, not drawn as live)
        // (started again at a launch or wake after its log went quiet: nothing seen since, nothing drawn)
        for (id, s) in store.runStart { if let d = Clock.parse(s) { let e = store.liveEnd(id, now: now); if e > d { spans.append((id, d, e, e >= now, false)) } } }
        // what isn't seen of runs out of sight right now: estimated
        for u in store.unseenStretches(now: now) { spans.append((u.id, u.a, u.b, false, true)) }
        var ends: [Date] = []
        return spans.filter { Store.counted($0.0) }.sorted { $0.1 < $1.1 }.map { sp in
            // (an estimated stretch carries on its run's row)
            let row = ends.firstIndex { $0 <= sp.1 } ?? ends.count
            if row == ends.count { ends.append(sp.2) } else { ends[row] = sp.2 }
            return (sp.0, sp.1, sp.2, sp.3, sp.4, min(row, maxRows - 1))
        }
    }

    private func keepNow() {
        if follow { start = Date().addingTimeInterval(-Double(plotW) * spp * 0.3) }
    }

    // MARK: drawing

    private func text(_ s: String, _ f: NSFont, _ c: NSColor, at p: NSPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: c])
    }

    override func draw(_ dirtyRect: NSRect) {
        // the runs changed under it (a wake): read again just after this frame (a reload may resize the strip)
        if stale { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { if self?.stale == true { self?.reload() } } } }
        applyRange()
        keepNow()
        hits = []
        Theme.paper.setFill(); bounds.fill()
        Theme.faint.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let now = Date()
        let small = Theme.ui(11), smallB = Theme.ui(11, .semibold)
        let cal = Calendar.current
        let left = time(labelW), right = time(bounds.width - 12)

        // header: the title, the next scheduled run, ◎ Now and the range buttons
        let head = tr("时间轴", "Timeline"), headF = Theme.ui(13, .semibold)
        // the ranges: one segmented control
        let segW = ranges.map { $0.0.size(smallB).width + 16 }
        let group = NSRect(x: bounds.width - 14 - segW.reduce(0, +), y: 7, width: segW.reduce(0, +), height: 20)
        let gp = NSBezierPath(roundedRect: group.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Theme.paper.setFill(); gp.fill()
        Theme.line.setStroke(); gp.lineWidth = 1; gp.stroke()
        var sx = group.minX
        for (i, (label, hours)) in ranges.enumerated() {
            let r = NSRect(x: sx, y: group.minY, width: segW[i], height: group.height)
            let on = rangeHours == hours
            if on {
                Theme.ink.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
            } else if i > 0 {
                Theme.faint.setFill(); NSRect(x: r.minX, y: r.minY + 5, width: 1, height: r.height - 10).fill()
            }
            text(label, smallB, on ? Theme.paper : Theme.ink, at: NSPoint(x: r.minX + 8, y: r.minY + 3))
            hits.append((r, "", { [weak self] in self?.setRange(hours) }))
            sx += segW[i]
        }
        // Now: a different kind of button (it moves, it doesn't zoom), solid when you've scrolled away
        let nowL = "◎ " + tr("现在", "Now")
        let nowW = nowL.size(smallB).width + 18
        let nowBtn = NSRect(x: group.minX - 12 - nowW, y: 7, width: nowW, height: 20)
        let np = NSBezierPath(roundedRect: nowBtn.insetBy(dx: 0.75, dy: 0.75), xRadius: 10, yRadius: 10)
        if follow {
            Theme.paper.setFill(); np.fill()
            Theme.running.setStroke(); np.lineWidth = 1.5; np.stroke()
        } else {
            Theme.running.setFill(); np.fill()
        }
        text(nowL, smallB, follow ? Theme.running : Theme.onColor(Theme.running), at: NSPoint(x: nowBtn.minX + 9, y: nowBtn.minY + 3))
        hits.append((nowBtn, "", { [weak self] in self?.follow = true; self?.needsDisplay = true }))
        // the next scheduled task, between the title and ◎ Now: as much as fits there (a list from an earlier read says
        // when it's from, a task changed since isn't known: that goes last, and where only that fits, in the title's
        // place rather than cut short); hovering it shows all of it when cut short (the lane's tasks say the as-of too)
        let listAsOf = usage.routinesAsOf.map { UsageMonitor.stamp($0) }
        let asOfTip = listAsOf.map { "\n" + tr("\($0) 时的列表", "List as of \($0)") } ?? ""
        var titled = true
        if let (r, d) = TimelineView.upcoming(usage.routines).first {
            let f = Theme.ui(12, .semibold)
            let h = Self.headerLine(name: r.name, countdown: Clock.countdown(d), asOf: listAsOf, titleWidth: head.size(headF).width, nowX: nowBtn.minX, font: f)
            titled = h.titled
            if let line = h.line {
                text(line.text, f, Theme.ink, at: NSPoint(x: h.x, y: 10))
                if !line.whole {
                    let tip = "\(r.name)\n" + tr("下一个计划任务：", "Next scheduled task: ") + "\(Self.dayHM(d)) · \(Clock.countdown(d))" + asOfTip
                    hits.append((NSRect(x: h.x, y: 8, width: line.text.size(f).width, height: 18), tip, {}))
                }
            }
        }
        if titled { text(head, headF, Theme.ink, at: NSPoint(x: 14, y: 10)) }

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

        // lane 0: when Claude was working on each chat, one row per chat running at the same time
        for (id, s, end, live, est, row) in spans {
            let e = live ? max(end, now) : end
            guard e >= left && s <= right else { continue }
            let r = NSRect(x: x(s), y: laneY(0) + 4 + rowH * CGFloat(row), width: max(4, x(e) - x(s)), height: rowH - 4)
            // your branch colour if the chat has one, otherwise neutral; time KIKUmap didn't see (estimated) faint,
            // with a dashed edge
            let base = store.branchColor(id) ?? Theme.muted
            let fill = live ? base : base.withAlphaComponent(est ? 0.22 : 0.55)
            fill.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            if live || est {
                (est ? base.withAlphaComponent(0.8) : Theme.ink).setStroke()
                let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3); o.lineWidth = 1
                if est { o.setLineDash([3, 2], count: 2, phase: 0) }
                o.stroke()
            }
            let name = store.mapLabel(id)
            if r.width > 46 {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: r.insetBy(dx: 4, dy: 0)).addClip()
                // black or white, whichever reads on the bar as it's seen (a finished one faded over the panel; white
                // was hard to read on yellow and light gray bars); a faint estimated one in the text color
                text(name, Theme.ui(10.5, .semibold), est ? Theme.ink : Theme.onColor(fill, over: Theme.paper), at: NSPoint(x: r.minX + 5, y: r.minY + 1))
                NSGraphicsContext.current?.restoreGraphicsState()
            }
            // still going, but out of sight since its end here (a Codex task whose log went quiet): said so; a stretch
            // KIKUmap didn't see: estimated, and how
            let unseen = !live && !est && store.runStart[id].flatMap(Clock.parse) == s && store.outOfSight(id)
            let typical = Self.dur(store.typicalRun(id))
            let tip = "\(store.name(id))\n\(est ? "≈ " : "")\(Self.hm(s)) – \(live ? tr("在跑", "running") : Self.hm(e)) (\(est ? "≈ " : "")\(Self.dur(e.timeIntervalSince(s))))"
                + (unseen ? tr("\n之后没再看到动静（可能在等你确认，也可能某一步做得久）", "\nNo activity seen since (maybe waiting for you, maybe a long step)") : "")
                + (est ? tr("\n估算：这段时间 KIKUmap 没看到。\n算到下次看到它、或已知做完的时候；\n都没有时，按你平常一次的时长 \(typical)",
                            "\nEstimated: KIKUmap didn't see this time.\nCounted up to when it was next seen or known done;\nelse your usual run of \(typical)") : "")
            hits.append((r, tip, { [weak self] in if self?.store.canOpen(id) == true { self?.onOpenChat?(id) } }))
        }

        // lane 1: scheduled tasks — past runs as blocks, future runs as markers with countdowns
        let y1 = laneY(1)
        if !UsageMonitor.enabled && usage.routines.isEmpty {
            let s = tr("开启「用量」后，这里会显示计划任务 · 点这里开启", "Scheduled tasks show here once usage is on · click to turn it on")
            let f = Theme.ui(11, .medium)
            let r = NSRect(x: labelW + 10, y: y1 + 5, width: s.size(f).width + 4, height: 16)
            text(s, f, Theme.muted, at: NSPoint(x: r.minX, y: r.minY))
            hits.append((r, "", { [weak self] in self?.onTurnOnUsage?() }))
        } else if let why = usage.routinesUnknown {
            // on, but no list to go by and none can be read now: said, with why, not an empty lane (whole on hovering
            // when a narrow strip cuts it short: in two lines, as in one it would be wider than a bubble gets)
            let s = tr("计划任务没同步：", "Scheduled tasks not synced: ") + why
            let f = Theme.ui(11, .medium)
            let r = NSRect(x: labelW + 10, y: y1 + 5, width: min(s.size(f).width + 4, max(0, bounds.width - labelW - 22)), height: 16)
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
            (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: f, .foregroundColor: Theme.muted, .paragraphStyle: p])
            if s.size(f).width + 4 > r.width { hits.append((r, tr("计划任务没同步", "Scheduled tasks not synced") + "\n" + why, {})) }
        }
        var lastLabelEnd: CGFloat = -1
        var marks: [(Date, String, Bool)] = []
        for r in usage.routines {
            if let f = r.lastFired, f <= right {
                let e = max(r.lastFinished ?? f, f.addingTimeInterval(spp * 4))
                let rect = NSRect(x: x(f), y: y1 + 8, width: max(4, x(e) - x(f)), height: laneH - 16)
                Theme.ink.withAlphaComponent(0.55).setFill(); rect.fill()
                hits.append((rect.insetBy(dx: -3, dy: -4), "\(r.name)\n" + tr("上次运行：", "Last ran: ") + Self.hm(f) + asOfTip, { [weak self] in self?.onOpenRoutines?() }))
            }
            // the server's next run is the one that counts: nothing runs before it, and the cron fills in the rest
            var future = cronRuns[r.id] ?? []
            if let n = r.upcoming, n > now { future = [n] + future.filter { $0 > n.addingTimeInterval(60) } }
            else if future.isEmpty, let n = r.upcoming { future = [n] }
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
            let label = isNext ? "\(name) · \(Clock.countdown(d))" : name, lf = isNext ? smallB : small
            // the label stops before the next marker (hover shows the full name); measured in the font it's drawn in (the
            // next one's bold: measured plain, its countdown lost its last letter)
            let room = (i + 1 < sortedMarks.count ? x(sortedMarks[i + 1].0) - 12 : bounds.width) - (mx + 11)
            let lw = min(label.size(lf).width, room)
            let labelled = mx + 11 > lastLabelEnd && room > 30
            if labelled {
                NSGraphicsContext.current?.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: mx + 11, y: my - 9, width: lw, height: 18)).addClip()
                text(label, lf, isNext ? Theme.ink : Theme.muted, at: NSPoint(x: mx + 11, y: my - 7))
                NSGraphicsContext.current?.restoreGraphicsState()
                lastLabelEnd = mx + 11 + lw + 8
            }
            hits.append((NSRect(x: mx - 10, y: my - 11, width: 20 + (labelled ? lw + 4 : 0), height: 22),
                         "\(name)\n\(Self.dayHM(d)) · \(Clock.countdown(d))" + asOfTip, { [weak self] in self?.onOpenRoutines?() }))
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
        let df = DateFormatter(); df.locale = Prefs.lang.locale; df.dateFormat = tr("EEE d日", "EEE d")
        while d < right {
            let next = cal.date(byAdding: .day, value: 1, to: d)!
            let a = max(x(d), labelW), b = min(x(next), bounds.width - 12)
            if b > a {
                let today = cal.isDateInToday(d)
                let r = NSRect(x: a + 1, y: dayY, width: b - a - 2, height: 20)
                let label = today ? tr("今天 ", "Today ") + df.string(from: d) : df.string(from: d)
                if today {
                    // today: 45° stripes, its name on a solid tab at the start
                    NSGraphicsContext.current?.saveGraphicsState()
                    NSBezierPath(rect: r).addClip()
                    Theme.faint.setFill(); r.fill()
                    let stripes = NSBezierPath()
                    var sx = r.minX - r.height
                    while sx < r.maxX {
                        stripes.move(to: NSPoint(x: sx, y: r.maxY)); stripes.line(to: NSPoint(x: sx + r.height, y: r.minY))
                        sx += 7
                    }
                    stripes.lineWidth = 1.5
                    Theme.ink.withAlphaComponent(0.3).setStroke(); stripes.stroke()
                    NSGraphicsContext.current?.restoreGraphicsState()
                    let tab = NSRect(x: r.minX, y: r.minY, width: min(r.width, label.size(smallB).width + 14), height: r.height)
                    Theme.ink.setFill(); tab.fill()
                    if r.width > label.size(smallB).width + 10 { text(label, smallB, Theme.paper, at: NSPoint(x: tab.minX + 7, y: tab.minY + 3)) }
                } else {
                    Theme.faint.setFill(); r.fill()
                    if r.width > label.size(smallB).width + 10 { text(label, smallB, Theme.ink, at: NSPoint(x: r.minX + 6, y: r.minY + 3)) }
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

        // hovering a run or a scheduled task: its name and times in a bubble (a note cut short: all of it)
        if let hp = hoverP, drag?.moved != true, let tip = hits.last(where: { $0.0.contains(hp) && !$0.1.isEmpty })?.1 {
            let lines = tip.components(separatedBy: "\n")
            let fonts = lines.indices.map { $0 == 0 ? smallB : small }
            let lh: CGFloat = 15
            let w = min(420, (zip(lines, fonts).map { $0.size($1).width }.max() ?? 0) + 16)
            let h = lh * CGFloat(lines.count) + 8
            var r = NSRect(x: hp.x + 12, y: hp.y - h - 6, width: w, height: h)
            if r.maxX > bounds.width - 4 { r.origin.x = hp.x - 12 - w }
            if r.minY < 2 { r.origin.y = hp.y + 14 }
            // never past the strip's edges: a wide bubble in a narrow strip (a small window at a large UI scale) would
            // lose its start or its end
            r.origin.x = max(2, min(r.origin.x, bounds.width - w - 2))
            r.origin.y = max(2, min(r.origin.y, bounds.height - h - 2))
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

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f
    }()
    /// "20:00" in every region (Latin digits), with one formatter for every frame.
    static func hm(_ d: Date) -> String {
        hmFormatter.timeZone = .current
        return hmFormatter.string(from: d)
    }
    static func dayHM(_ d: Date) -> String {
        Clock.format(d, "M月d日 EEE HH:mm", "MMM d, EEE HH:mm")
    }
    static func dur(_ s: TimeInterval) -> String {
        s < 3600 ? tr("\(max(1, Int(s / 60)))分钟", "\(max(1, Int(s / 60)))m") : String(format: tr("%.1f小时", "%.1fh"), s / 3600)
    }

    // MARK: interaction

    private func setRange(_ hours: Double) {
        rangeHours = hours
        UserDefaults.standard.set(hours, forKey: "TimelineHours")
        applyRange()
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
        rangeHours = nil
        spp = min(3600, max(15, spp * f))
        start = anchor.addingTimeInterval(-Double(px - labelW) * spp)
        if follow {
            follow = false
        }
        needsDisplay = true
    }
}
