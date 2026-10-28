import SwiftUI

// The desktop widget's views. Plain SwiftUI (no WidgetKit), so a preview tool can draw them too;
// KikumapWidget.swift puts them in a widget.

/// What Kikumap writes to ~/Library/Application Support/ClaudeConsole/widget.json
/// (Sources/WidgetFeed.swift writes the same shape — keep the two in step).
struct WidgetState: Codable {
    struct Item: Codable, Hashable { var id: String; var title: String }
    struct Meter: Codable, Hashable { var label: String; var percent: Double; var resets: String? }
    /// One hour: seconds Claude worked per colour slot (legend order); the last one is every other chat.
    struct Hour: Codable, Hashable { var start: String; var parts: [Double] }
    var updated: String
    var english: Bool
    /// Kikumap quit (so nothing here is live any more).
    var closed: Bool?
    var running: [Item]
    var unread: [Item]
    var runningCount: Int
    var unreadCount: Int
    var meters: [Meter]
    var usageOff: Bool
    var hours: [Hour]
    var legend: [String]

    /// The file, read through the real home folder (inside the sandbox, NSHomeDirectory() is the widget's own container).
    static func load() -> WidgetState? {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { return nil }
        let url = URL(fileURLWithPath: String(cString: home) + "/Library/Application Support/ClaudeConsole/widget.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetState.self, from: d)
    }

    /// Made-up chats for the widget gallery.
    static func sample(_ now: Date, english: Bool = !WidgetText.systemChinese) -> WidgetState {
        let hour = WidgetTime.hourStart(now)
        let t: (String, String) -> String = { english ? $1 : $0 }
        // a plausible day: busy afternoon, quiet night, busy again now
        let shape: [[Double]] = [
            [0, 0, 0, 0, 0, 0], [1500, 0, 0, 0, 0, 300], [2400, 900, 0, 0, 0, 0], [1200, 1800, 600, 0, 0, 0],
            [0, 2100, 1200, 0, 0, 400], [600, 0, 2400, 0, 0, 0], [0, 0, 900, 1500, 0, 0], [0, 0, 0, 600, 0, 0],
            [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0],
            [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 900, 0],
            [1800, 0, 0, 0, 1200, 0], [2700, 0, 0, 1200, 0, 600], [3000, 1500, 0, 0, 0, 0], [900, 2400, 0, 0, 1800, 0],
            [0, 3000, 1200, 0, 0, 300], [1200, 1800, 2400, 0, 0, 0], [2400, 0, 1500, 900, 0, 0], [1500, 600, 0, 0, 0, 0],
        ]
        let hours = shape.enumerated().map { i, p in
            Hour(start: WidgetTime.iso(hour.addingTimeInterval(Double(i - 23) * 3600)), parts: p)
        }
        return WidgetState(
            updated: WidgetTime.iso(now), english: english, closed: nil,
            running: [Item(id: "a", title: t("重构登录流程", "Refactor the login flow")),
                      Item(id: "b", title: t("周报数据整理", "Weekly report numbers"))],
            unread: [Item(id: "c", title: t("旅行行程规划", "Trip itinerary")),
                     Item(id: "d", title: t("论文第三章润色", "Polish chapter 3")),
                     Item(id: "e", title: t("网站首页文案", "Homepage copy"))],
            runningCount: 2, unreadCount: 3,
            meters: [Meter(label: t("会话", "Session"), percent: 42, resets: WidgetTime.iso(now.addingTimeInterval(2 * 3600 + 600))),
                     Meter(label: t("本周", "Week"), percent: 18, resets: WidgetTime.iso(now.addingTimeInterval(3 * 86400)))],
            usageOff: false, hours: hours,
            legend: [t("重构登录流程", "Refactor the login flow"), t("周报数据整理", "Weekly report numbers"),
                     t("旅行行程规划", "Trip itinerary"), t("论文第三章润色", "Polish chapter 3"), t("网站首页文案", "Homepage copy")])
    }
}

enum WidgetTime {
    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
    static func parse(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
    static func hourStart(_ d: Date) -> Date { Calendar.current.dateInterval(of: .hour, for: d)?.start ?? d }
}

enum WidgetText {
    static var systemChinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") ?? false }

    /// "1h 20m" / "1小时20分"
    static func duration(_ sec: Double, _ en: Bool) -> String {
        let h = Int(sec / 3600), m = Int(sec.truncatingRemainder(dividingBy: 3600) / 60)
        if h == 0 { return en ? "\(m)m" : "\(m)分钟" }
        if m == 0 { return en ? "\(h)h" : "\(h)小时" }
        return en ? "\(h)h \(m)m" : "\(h)小时\(m)分"
    }

    /// Axis labels stay short in both languages.
    static func axis(_ sec: Double) -> String {
        if sec == 0 { return "0" }
        if sec.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(sec / 3600))h" }
        return "\(Int(sec / 60))m"
    }

    /// "resets in 2h 10m" / "2小时10分后重置"; past a day, "resets Fri 09:00" / "周五 09:00 重置".
    static func resets(_ d: Date?, now: Date, _ en: Bool) -> String {
        guard let d = d else { return "" }
        let sec = d.timeIntervalSince(now)
        if sec <= 60 { return en ? "resets now" : "马上重置" }
        if sec < 86400 { return en ? "resets in " + duration(sec, en) : duration(sec, en) + "后重置" }
        let f = DateFormatter()
        f.locale = Locale(identifier: en ? "en_US" : "zh_CN")
        f.dateFormat = en ? "EEE HH:mm" : "EEE HH:mm"
        return en ? "resets " + f.string(from: d) : f.string(from: d) + " 重置"
    }
}

/// The categorical slots, fixed order, validated against the widget's surfaces (white / #1F1F21).
enum WidgetPalette {
    static let light: [UInt32] = [0x2A78D6, 0xEB6834, 0x1BAF7A, 0xEDA100, 0xE87BA4]
    static let dark: [UInt32] = [0x3987E5, 0xD95926, 0x199E70, 0xC98500, 0xD55181]
    static let otherLight: UInt32 = 0xB9B9BC, otherDark: UInt32 = 0x57575C

    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    /// Colour of slot `i` out of `count` named chats; i == count is "every other chat".
    static func color(_ i: Int, count: Int, dark: Bool) -> Color {
        if i >= count || i >= light.count { return rgb(dark ? otherDark : otherLight) }
        return rgb(dark ? self.dark[i] : light[i])
    }
    static func surface(dark: Bool) -> Color { rgb(dark ? 0x1F1F21 : 0xFFFFFF) }
}

enum WidgetSize { case small, medium, large }

struct KikumapWidgetView: View {
    let state: WidgetState?
    let date: Date
    let size: WidgetSize
    var links = true
    @Environment(\.colorScheme) private var scheme

    private var en: Bool { state?.english ?? !WidgetText.systemChinese }
    private func t(_ zh: String, _ e: String) -> String { en ? e : zh }

    /// No word from Kikumap for a while: it isn't running (the file changes at least every hour while it is).
    private var stale: Bool {
        guard let s = state else { return false }
        if s.closed == true { return true }
        guard let u = WidgetTime.parse(s.updated) else { return true }
        return date.timeIntervalSince(u) > 75 * 60
    }

    var body: some View {
        if let s = state {
            switch size {
            case .small: small(s)
            case .medium: medium(s)
            case .large: large(s)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Kikumap").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primary)
                Text(t("打开一次 Kikumap，这里就有内容了", "Open Kikumap once to fill this in"))
                    .font(.system(size: 11)).foregroundStyle(Color.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: sizes

    private func small(_ s: WidgetState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                count(s.runningCount, running: true)
                count(s.unreadCount, running: false)
                Spacer(minLength: 0)
            }
            if stale { staleMark } else { meters(s, labelWidth: nil, compact: true) }
            chart(s, compact: true)
        }
    }

    private func medium(_ s: WidgetState) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    summaryRow(s.runningCount, s.running.first, running: true)
                    summaryRow(s.unreadCount, s.unread.first, running: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    meters(s, labelWidth: en ? 44 : 26, compact: true)
                    if stale { staleMark }
                }
                .frame(width: 150)
            }
            chart(s, compact: false)
        }
    }

    private func large(_ s: WidgetState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Kikumap").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondary)
                Spacer(minLength: 4)
                if stale {
                    staleMark
                } else {
                    Text(t("24小时 · ", "24h · ") + WidgetText.duration(total(s), en))
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Color.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                list(t("进行中", "Running"), s.runningCount, s.running, running: true)
                list(t("未读", "Unread"), s.unreadCount, s.unread, running: false)
            }
            meters(s, labelWidth: 40, compact: false)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            chart(s, compact: false)
            legend(s)
        }
    }

    // MARK: pieces

    private var staleMark: some View {
        Text(t("Kikumap 没在运行", "Kikumap isn't running"))
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondary).lineLimit(1)
    }

    private func mark(running: Bool) -> some View {
        Group {
            if running {
                Image(systemName: "circle.dotted").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.primary)
            } else {
                Circle().fill(Color.red).frame(width: 7, height: 7)
            }
        }
        .frame(width: 11, height: 11)
    }

    private func count(_ n: Int, running: Bool) -> some View {
        HStack(spacing: 4) {
            mark(running: running)
            Text("\(n)").font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(Color.primary)
        }
    }

    private func link<V: View>(_ id: String, @ViewBuilder _ v: () -> V) -> some View {
        Group {
            if links, let u = URL(string: "kikumap://chat/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)) {
                Link(destination: u) { v() }
            } else {
                v()
            }
        }
    }

    /// "◌ 2  Refactor the login flow"
    private func summaryRow(_ n: Int, _ first: WidgetState.Item?, running: Bool) -> some View {
        let row = HStack(spacing: 5) {
            mark(running: running)
            Text("\(n)").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Color.primary)
            Text(first?.title ?? (running ? t("没有在跑的", "nothing running") : t("都看过了", "all read")))
                .font(.system(size: 11)).foregroundStyle(first == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
        return Group {
            if let f = first { link(f.id) { row } } else { row }
        }
    }

    private func list(_ title: String, _ n: Int, _ items: [WidgetState.Item], running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                mark(running: running)
                Text(title + " · \(n)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Color.primary)
            }
            if items.isEmpty {
                Text(running ? t("没有在跑的", "Nothing running") : t("都看过了", "All read"))
                    .font(.system(size: 11)).foregroundStyle(Color.secondary).padding(.leading, 16)
            }
            ForEach(items.prefix(3), id: \.self) { it in
                link(it.id) {
                    Text(it.title).font(.system(size: 11)).foregroundStyle(Color.primary).lineLimit(1)
                        .padding(.leading, 16)
                }
            }
            if n > 3 {
                Text(t("还有 \(n - 3) 个", "+\(n - 3) more")).font(.system(size: 10)).foregroundStyle(Color.secondary)
                    .padding(.leading, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func meters(_ s: WidgetState, labelWidth: CGFloat?, compact: Bool) -> some View {
        if s.usageOff || s.meters.isEmpty {
            Text(s.usageOff ? t("用量未开启", "Usage off") : t("用量读取中…", "Usage loading…"))
                .font(.system(size: 10)).foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: compact ? 4 : 5) {
                ForEach(s.meters, id: \.self) { m in meter(m, labelWidth: labelWidth, compact: compact) }
            }
        }
    }

    private func meter(_ m: WidgetState.Meter, labelWidth: CGFloat?, compact: Bool) -> some View {
        let high = m.percent >= 90
        // the small widget: "S" / "W", or the two-character Chinese label
        let label = size == .small && en ? String(m.label.prefix(1)) : m.label
        return HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondary)
                .frame(width: labelWidth ?? (en ? 10 : 22), alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.primary)
                        .frame(width: max(4, g.size.width * CGFloat(min(max(m.percent, 0), 100) / 100)))
                }
            }
            .frame(height: 4)
            Text("\(Int(m.percent.rounded()))%")
                .font(.system(size: 10, weight: high ? .bold : .medium).monospacedDigit())
                .foregroundStyle(high ? Color.primary : Color.secondary)
                .frame(width: 30, alignment: .trailing)
            if !compact {
                Text(WidgetText.resets(WidgetTime.parse(m.resets), now: date, en))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.secondary).lineLimit(1)
                    .frame(width: 118, alignment: .leading)
            }
        }
    }

    private func total(_ s: WidgetState) -> Double {
        HoursChart.bins(s, at: date).reduce(0) { $0 + $1.parts.reduce(0, +) }
    }

    private func chart(_ s: WidgetState, compact: Bool) -> some View {
        Group {
            if links, let u = URL(string: "kikumap://stats") {
                Link(destination: u) { HoursChart(state: s, date: date, compact: compact, dark: scheme == .dark) }
            } else {
                HoursChart(state: s, date: date, compact: compact, dark: scheme == .dark)
            }
        }
        .frame(maxHeight: .infinity)
        .overlay {
            if total(s) == 0 {
                Text(t("最近 24 小时没有活动", "Nothing in the last 24 hours"))
                    .font(.system(size: 10)).foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(WidgetPalette.surface(dark: scheme == .dark))
                    .padding(.bottom, 14)
            }
        }
    }

    /// The named chats in the chart (only those with time in these 24 hours).
    private func legend(_ s: WidgetState) -> some View {
        let bins = HoursChart.bins(s, at: date)
        let shown = s.legend.indices.filter { i in bins.contains { i < $0.parts.count && $0.parts[i] > 0 } }
        return HStack(spacing: 10) {
            ForEach(shown.prefix(3), id: \.self) { i in
                HStack(spacing: 4) {
                    Circle().fill(WidgetPalette.color(i, count: s.legend.count, dark: scheme == .dark)).frame(width: 7, height: 7)
                    Text(s.legend[i]).font(.system(size: 10)).foregroundStyle(Color.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 12)
    }
}

/// The last 24 hours, one bar per hour, a segment per chat (stacked in colour order, every other chat on top).
struct HoursChart: View {
    let state: WidgetState
    let date: Date
    let compact: Bool
    let dark: Bool

    /// The 24 hours ending with the current one; the file's hours are matched by start time, so a file
    /// written a while ago still lines up.
    static func bins(_ s: WidgetState, at now: Date) -> [(start: Date, parts: [Double])] {
        var byStart: [Int: [Double]] = [:]
        for h in s.hours { if let d = WidgetTime.parse(h.start) { byStart[Int((d.timeIntervalSince1970 / 60).rounded())] = h.parts } }
        let hour = WidgetTime.hourStart(now)
        return (0..<24).map { i in
            let start = hour.addingTimeInterval(Double(i - 23) * 3600)
            return (start, byStart[Int((start.timeIntervalSince1970 / 60).rounded())] ?? [])
        }
    }

    /// A gridline step that gives one or two lines above zero.
    private static func scale(_ peak: Double) -> (step: Double, top: Double) {
        let steps: [Double] = [900, 1800, 3600, 7200, 10800, 14400, 21600]
        let step = steps.first { peak / $0 <= 2 } ?? 21600
        return (step, max(step, step * (peak / step).rounded(.up)))
    }

    var body: some View {
        GeometryReader { g in
            let bins = Self.bins(state, at: date)
            let named = state.legend.count
            let peak = bins.map { $0.parts.reduce(0, +) }.max() ?? 0
            let (step, top) = Self.scale(peak)
            let labelW: CGFloat = compact ? 20 : 24
            let plot = CGRect(x: 0, y: 5, width: max(g.size.width - labelW, 10), height: max(g.size.height - 5 - 13, 10))
            let slotW = plot.width / 24
            let barW = max(2, slotW * 0.62)
            let gap: CGFloat = slotW >= 9 ? 2 : 1.5
            let cal = Calendar.current
            ZStack(alignment: .topLeading) {
                // grid: zero, then each step
                Path { p in
                    var v = 0.0
                    while v <= top + 1 {
                        let y = plot.maxY - CGFloat(v / top) * plot.height
                        p.move(to: CGPoint(x: plot.minX, y: y)); p.addLine(to: CGPoint(x: plot.maxX, y: y))
                        v += step
                    }
                }
                .stroke(Color.primary.opacity(0.13), lineWidth: 0.5)
                // midnight
                Path { p in
                    for (i, b) in bins.enumerated() where cal.component(.hour, from: b.start) == 0 {
                        let x = plot.minX + slotW * CGFloat(i)
                        p.move(to: CGPoint(x: x, y: plot.minY - 4)); p.addLine(to: CGPoint(x: x, y: plot.maxY + 12))
                    }
                }
                .stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))
                // bars, one path per colour
                ForEach(0...named, id: \.self) { slot in
                    Path { p in
                        for (i, b) in bins.enumerated() {
                            let segs = b.parts.enumerated().filter { $0.element >= 30 }
                            var y = plot.maxY
                            let x = plot.minX + slotW * (CGFloat(i) + 0.5) - barW / 2
                            for (k, seg) in segs.enumerated() {
                                let h = max(CGFloat(seg.element / top) * plot.height, k == 0 ? 1.5 : 1.5 + gap)
                                let topY = y - h
                                var r = CGRect(x: x, y: topY, width: barW, height: h)
                                if k > 0 { r.size.height -= gap }
                                y = topY
                                guard min(seg.offset, named) == slot, r.height > 0.2 else { continue }
                                if k == segs.count - 1 {
                                    let rad = min(compact ? 2 : 3, barW / 2, r.height)
                                    p.addPath(UnevenRoundedRectangle(topLeadingRadius: rad, bottomLeadingRadius: 0,
                                                                     bottomTrailingRadius: 0, topTrailingRadius: rad).path(in: r))
                                } else {
                                    p.addRect(r)
                                }
                            }
                        }
                    }
                    .fill(WidgetPalette.color(slot, count: named, dark: dark))
                }
                // value axis, on the right
                ForEach(Array(stride(from: 0.0, through: top + 1, by: step)), id: \.self) { v in
                    Text(WidgetText.axis(v))
                        .font(.system(size: compact ? 8 : 9).monospacedDigit()).foregroundStyle(Color.secondary)
                        .fixedSize()
                        .frame(width: labelW - 3, alignment: .leading)
                        .position(x: plot.maxX + 3 + (labelW - 3) / 2, y: plot.maxY - CGFloat(v / top) * plot.height)
                }
                // hours: every six, at the start of the hour
                ForEach(Array(bins.enumerated()).filter { cal.component(.hour, from: $0.element.start) % 6 == 0 }, id: \.offset) { item in
                    let x = plot.minX + slotW * CGFloat(item.offset)
                    Text(String(format: "%02d", cal.component(.hour, from: item.element.start)))
                        .font(.system(size: compact ? 8 : 9).monospacedDigit()).foregroundStyle(Color.secondary)
                        .fixedSize()
                        .position(x: min(max(x + 8, 8), plot.maxX - 6), y: plot.maxY + 7)
                }
            }
        }
    }
}
