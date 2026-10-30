import SwiftUI

// The desktop widget's views. Plain SwiftUI (no WidgetKit), so a preview tool can draw them too;
// KikumapWidget.swift puts them in a widget.

/// What Kikumap writes to ~/Library/Application Support/ClaudeConsole/widget.json
/// (Sources/WidgetFeed.swift writes the same shape — keep the two in step).
struct WidgetState: Codable {
    struct Item: Codable, Hashable { var id: String; var title: String; var unsure: Bool? = nil }
    /// One usage window; `group` is whose: "claude" (also when missing) or "gpt"; `minutes` how long it is.
    /// `asOf`: the numbers are from an earlier read (Kikumap couldn't read usage since): when that was.
    struct Meter: Codable, Hashable { var label: String; var percent: Double; var resets: String?; var group: String?; var minutes: Int?; var asOf: String? }
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
    /// Each named chat's branch colour on the map ("" for none; nil from an older Kikumap: the palette's).
    var colours: [String]? = nil
    /// Claude's chat list (or its unread marks) can't be read now: said, and the counts carry a "?".
    var claudeNote: String? = nil
    /// The note is about Claude's unread marks alone: what's running is read as usual.
    var claudeUnreadOnly: Bool? = nil
    /// Seconds of the chart's 24 hours that are estimated (runs out of Kikumap's sight): its total says "≈".
    var estimated: Double? = nil

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
        // chats running side by side share the time, so an hour never holds more than an hour
        let hours = shape.enumerated().map { i, p in
            let sum = p.reduce(0, +), scale = sum > 3300 ? 3300 / sum : 1
            return Hour(start: WidgetTime.iso(hour.addingTimeInterval(Double(i - 23) * 3600)), parts: p.map { ($0 * scale).rounded() })
        }
        return WidgetState(
            updated: WidgetTime.iso(now), english: english, closed: nil,
            running: [Item(id: "a", title: t("重构登录流程", "Refactor the login flow")),
                      Item(id: "b", title: t("周报数据整理", "Weekly report numbers"))],
            unread: [Item(id: "c", title: t("旅行行程规划", "Trip itinerary")),
                     Item(id: "d", title: t("上线检查清单", "Launch checklist")),
                     Item(id: "e", title: t("网站首页文案", "Homepage copy"))],
            runningCount: 2, unreadCount: 3,
            meters: [Meter(label: t("会话", "Session"), percent: 42, resets: WidgetTime.iso(now.addingTimeInterval(2 * 3600 + 600)), minutes: 300),
                     Meter(label: t("本周", "Week"), percent: 18, resets: WidgetTime.iso(now.addingTimeInterval(3 * 86400)), minutes: 7 * 1440)],
            usageOff: false, hours: hours,
            legend: [t("重构登录流程", "Refactor the login flow"), t("周报数据整理", "Weekly report numbers"),
                     t("旅行行程规划", "Trip itinerary"), t("上线检查清单", "Launch checklist"), t("网站首页文案", "Homepage copy")],
            // branch colours as a map might have them (one without: grey)
            colours: ["blue", "green", "orange", "violet", ""])
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

    /// "1h 20m" / "1小时20分" (any time at all is at least a minute, as in the app)
    static func duration(_ sec: Double, _ en: Bool) -> String {
        let sec = sec > 0 ? max(sec, 60) : 0
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

    /// "resets 16:10" / "16:10 重置" the same day, else "resets Fri 09:00" / "周五 09:00 重置": a clock time, which
    /// stays right however long the widget shows this entry (a countdown would freeze). Nothing once it's passed.
    static func resets(_ d: Date?, now: Date, _ en: Bool) -> String {
        guard let d = d, d > now else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: en ? "en_US" : "zh_CN")
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return en ? "resets " + f.string(from: d) : f.string(from: d) + " 重置"
    }

    /// "as of 09:00" / "09:00 时的数据" the same day, "as of Mon 09:00" in the six days before, else "as of 10/21 09:00"
    /// (the app says it the same way: UsageMonitor.stamp).
    static func asOf(_ d: Date, now: Date, _ en: Bool) -> String {
        en ? "as of " + when(d, now: now, en) : when(d, now: now, en) + " 时的数据"
    }

    /// "09:00" the same day, "Mon 09:00" in the six days before, else "10/21 09:00".
    static func when(_ d: Date, now: Date, _ en: Bool) -> String {
        let cal = Calendar.current
        // noon to noon: a day whose midnight is skipped (1:00 start) is still a whole day
        func noon(_ x: Date) -> Date { cal.date(bySettingHour: 12, minute: 0, second: 0, of: x) ?? x }
        let days = cal.dateComponents([.day], from: noon(d), to: noon(now)).day ?? 0
        let f = DateFormatter()
        f.locale = Locale(identifier: en ? "en_US" : "zh_CN")
        f.dateFormat = days == 0 ? "HH:mm" : (1...6).contains(days) ? "EEE HH:mm" : "M/d HH:mm"
        return f.string(from: d)
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
    /// The map's highlight colours by key, light and dark (as Sources/Theme.swift's `highlights`), and the grey of a
    /// chat that has none (Theme.muted).
    static let highlights: [String: (UInt32, UInt32)] = [
        "red": (0xD5524C, 0xE8675F), "orange": (0xDB7633, 0xEF8B48), "yellow": (0xC99A10, 0xE2B52C), "green": (0x46955A, 0x5FB473),
        "teal": (0x2B948E, 0x3DB2AA), "blue": (0x3A78D0, 0x5A92E4), "indigo": (0x5A5DC4, 0x7C7FDF), "violet": (0x8B58BA, 0xA67AD5),
        "pink": (0xCF5789, 0xE5739F), "brown": (0x93704F, 0xAE8A69),
    ]
    static let plainLight: UInt32 = 0x86868B, plainDark: UInt32 = 0x8E8E93

    /// Colour of slot `i` out of `count` named chats; i == count is "every other chat". With `keys` (each chat's
    /// branch colour), as the app draws it: that colour, or grey.
    static func color(_ i: Int, count: Int, keys: [String]? = nil, dark: Bool) -> Color {
        if i >= count { return rgb(dark ? otherDark : otherLight) }
        if let keys {
            guard i < keys.count, let h = highlights[keys[i]] else { return rgb(dark ? plainDark : plainLight) }
            return rgb(dark ? h.1 : h.0)
        }
        guard i < light.count else { return rgb(dark ? otherDark : otherLight) }
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

    /// Kikumap said it quit, or there's been no word from it for longer than a timeline lasts (it rewrites the
    /// file at least every ten minutes while it runs, but macOS may wait hours before asking for a new
    /// timeline; until then the old one's entries go on, and they mustn't call a running Kikumap stopped).
    private var stale: Bool {
        guard let s = state else { return false }
        if s.closed == true { return true }
        guard let u = WidgetTime.parse(s.updated) else { return true }
        return date.timeIntervalSince(u) > 7 * 3600
    }

    /// What's shown is from a while back (macOS lets a widget be redrawn only so many times a day): it says from
    /// when, rather than pass for now.
    private var behind: Date? {
        guard let s = state, !stale, let u = WidgetTime.parse(s.updated), date.timeIntervalSince(u) > 600 else { return nil }
        return u
    }

    private func behindNote(_ u: Date) -> some View {
        Text(WidgetText.asOf(u, now: date, en))
            .font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.secondary).lineLimit(1)
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
            if stale { staleMark } else {
                if let u = behind { behindNote(u) }
                claudeNoteLine(s)
                meters(s, labelWidth: nil, compact: true, limit: 3)
            }
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
                    // a longer label ("Sonnet", "5 小时") gets the room it needs in Chinese too
                    if stale { staleMark } else {
                        meters(s, labelWidth: en ? 44 : s.meters.contains { $0.label.count > 2 } ? 40 : 26, compact: true, limit: 3)
                        if let u = behind { behindNote(u) }
                        claudeNoteLine(s)
                    }
                }
                .frame(width: tagged(s) ? 174 : 150)
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
                } else if behind != nil || s.claudeNote != nil {
                    // both when both apply: from when, and that Claude isn't read
                    Text([behind.map { WidgetText.asOf($0, now: date, en) }, s.claudeNote].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                } else {
                    Text(t("24小时 · ", "24h · ") + ((s.estimated ?? 0) >= 60 ? "≈" : "") + WidgetText.duration(total(s), en))
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Color.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                list(t("进行中", "Running"), s.runningCount, s.running, running: true)
                list(t("未读", "Unread"), s.unreadCount, s.unread, running: false)
            }
            if !stale { meters(s, labelWidth: 40, compact: false, limit: 4) }
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            chart(s, compact: false)
            legend(s)
        }
    }

    // MARK: pieces

    /// What the widget knows, and as of when: Kikumap said it quit then, or nothing has come from it since then
    /// (never "isn't running": macOS may not have let the widget hear of it starting again yet).
    private var staleMark: some View {
        let u = state.flatMap { WidgetTime.parse($0.updated) }
        let at = u.map { WidgetText.when($0, now: date, en) } ?? "?"
        let text = state?.closed == true ? t("Kikumap \(at) 退出了", "Kikumap quit at \(at)") : t("\(at) 起没有 Kikumap 的消息", "No word from Kikumap since \(at)")
        // (the small widget's line is too short for it: two lines, so the time isn't cut off)
        return Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondary)
            .lineLimit(size == .large ? 1 : 2).minimumScaleFactor(0.8)
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
            Text(number(n, running)).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(Color.primary)
        }
    }

    /// A count as known: "–" with no word from Kikumap, "2?" when some of those running are out of its sight or
    /// Claude can't be read.
    private func number(_ n: Int, _ running: Bool) -> String {
        if stale { return "–" }
        let unsure = blind(running) || (running && (state?.running.contains { $0.unsure == true } ?? false))
        return "\(n)" + (unsure ? "?" : "")
    }
    /// Claude can't be read for this list now (its chat list, or for unread its marks alone).
    private func blind(_ running: Bool) -> Bool { state?.claudeNote != nil && !(running && state?.claudeUnreadOnly == true) }
    private func titled(_ it: WidgetState.Item) -> String { (it.unsure == true ? "? " : "") + it.title }

    /// Claude can't be read now: one line saying so (from the app, in its words).
    @ViewBuilder private func claudeNoteLine(_ s: WidgetState) -> some View {
        if !stale, let n = s.claudeNote {
            Text(n).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Color.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// With no word from Kikumap, or Claude not read, what's running or unread isn't known: it isn't shown as "nothing".
    private func none(_ running: Bool, capital: Bool) -> String {
        // (with no word from Kikumap the lists aren't shown at all, see `list`)
        if stale || blind(running) { return t("不知道", capital ? "Not known" : "not known") }
        return running ? t("没有在跑的", capital ? "Nothing running" : "nothing running") : t("都看过了", capital ? "All read" : "all read")
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
            Text(number(n, running)).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Color.primary)
            Text(stale ? none(running, capital: false) : first.map(titled) ?? none(running, capital: false))
                .font(.system(size: 11)).foregroundStyle(first == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
        return Group {
            if let f = first, !stale { link(f.id) { row } } else { row }
        }
    }

    private func list(_ title: String, _ n: Int, _ items: [WidgetState.Item], running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                mark(running: running)
                Text(title + " · " + number(n, running)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(Color.primary)
            }
            if items.isEmpty || stale {
                Text(none(running, capital: true))
                    .font(.system(size: 11)).foregroundStyle(Color.secondary).padding(.leading, 16)
            }
            ForEach(stale ? [] : Array(items.prefix(3)), id: \.self) { it in
                link(it.id) {
                    Text(titled(it)).font(.system(size: 11)).foregroundStyle(Color.primary).lineLimit(1)
                        .padding(.leading, 16)
                }
            }
            if n > 3 && !stale {
                Text(t("还有 \(n - 3) 个", "+\(n - 3) more")).font(.system(size: 10)).foregroundStyle(Color.secondary)
                    .padding(.leading, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// ChatGPT's meters are there too: each group gets its mark (Claude's alone look as they always did).
    private func tagged(_ s: WidgetState) -> Bool { s.meters.contains { $0.group == "gpt" } }

    /// Claude's meters, then ChatGPT's. More than `limit`: the fullest of each, then the next fullest up to `limit`,
    /// still in that order. A window that has reset by the
    /// time this entry shows starts again at 0% (one from an earlier read is left out: what's used since is unknown).
    /// The small widget has no room to say a number is from an earlier read, so it leaves out one older than a
    /// quarter of an hour (the app's own "as of" rule) rather than show it as if current.
    private func shown(_ s: WidgetState, limit: Int) -> [WidgetState.Meter] {
        let current = s.meters.compactMap { m -> WidgetState.Meter? in
            if size == .small, let a = WidgetTime.parse(m.asOf), date.timeIntervalSince(a) > 900 { return nil }
            guard let r = WidgetTime.parse(m.resets), r <= date else { return m }
            // reset since: from an earlier read, or with the file itself from a while back, what's used since is unknown
            if m.asOf != nil || behind != nil { return nil }
            var z = m; z.percent = 0; z.resets = nil
            return z
        }
        let groups = ["claude", "gpt"].map { g in current.indices.filter { (current[$0].group ?? "claude") == g } }
        if current.count <= limit { return groups.flatMap { $0.map { current[$0] } } }
        var keep = Set(groups.compactMap { g in g.max { current[$0].percent < current[$1].percent } })
        for i in current.indices.sorted(by: { current[$0].percent > current[$1].percent }) where keep.count < limit { keep.insert(i) }
        return groups.flatMap { $0.filter(keep.contains).map { current[$0] } }
    }

    @ViewBuilder
    private func meters(_ s: WidgetState, labelWidth: CGFloat?, compact: Bool, limit: Int) -> some View {
        // no usage (off, the Free plan, or not read yet): nothing, rather than a note about it
        if !s.usageOff && !s.meters.isEmpty {
            let list = shown(s, limit: limit), tag = tagged(s)
            VStack(alignment: .leading, spacing: compact ? 4 : 5) {
                ForEach(list.indices, id: \.self) { i in
                    meter(list[i], labelWidth: labelWidth, compact: compact, marked: tag)
                }
                // the medium widget's rows have no room for it either: one line under them says when
                if let d = asOf(list) {
                    // the mark of whose numbers are old (both: no mark, the line is about all of them)
                    let groups = Set(list.filter { $0.asOf != nil }.map { $0.group ?? "claude" })
                    asOfLine(d, mark: tag && groups.count == 1 ? groups.first : nil)
                }
            }
        }
    }

    /// When the medium widget's meters are from an earlier read (Claude's or ChatGPT's), unless Kikumap isn't
    /// running (that says enough); the large one says it on each row, the small one leaves them out.
    private func asOf(_ list: [WidgetState.Meter]) -> Date? {
        size == .medium && !stale ? list.compactMap { WidgetTime.parse($0.asOf) }.min() : nil
    }

    private func asOfLine(_ d: Date, mark group: String?) -> some View {
        HStack(spacing: 6) {
            if let g = group { ProviderMark(gpt: g == "gpt").frame(width: 20, height: 10, alignment: .leading) }
            Text(WidgetText.asOf(d, now: date, en)).font(.system(size: 10)).foregroundStyle(Color.secondary).lineLimit(1)
        }
    }

    /// A window's length, short: "5h", "7d".
    static func span(_ minutes: Int) -> String {
        minutes >= 1440 && minutes % 1440 == 0 ? "\(minutes / 1440)d" : "\(max(1, minutes / 60))h"
    }

    /// `marked`: each row shows whose it is (Claude's mark or "GPT") when both are there.
    private func meter(_ m: WidgetState.Meter, labelWidth: CGFloat?, compact: Bool, marked: Bool) -> some View {
        let high = m.percent >= 90
        // the small widget: how long the window is ("5h", "7d"), or the two-character Chinese label; a longer one
        // ("Sonnet") by its first letter
        let label = size == .small && (en || m.label.count > 2) ? (m.minutes.map(Self.span) ?? String(m.label.prefix(1))) : m.label
        return HStack(spacing: 6) {
            if marked {
                ProviderMark(gpt: m.group == "gpt").frame(width: 20, height: 10, alignment: .leading)
            }
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondary)
                .frame(width: labelWidth ?? (en ? 16 : 22), alignment: .leading)
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
                .lineLimit(1)
                .fixedSize()
                .frame(width: 34, alignment: .trailing)
            if !compact {
                Text(WidgetTime.parse(m.asOf).map { WidgetText.asOf($0, now: date, en) } ?? WidgetText.resets(WidgetTime.parse(m.resets), now: date, en))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.secondary).lineLimit(1)
                    .frame(width: 118, alignment: .leading)
            }
        }
    }

    /// Everything recorded in these 24 hours, pieces too short for the chart to draw too (as the app counts it).
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
            // (with no word from Kikumap, nothing was recorded: the note above says since when)
            if total(s) == 0 && !stale {
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
                    Circle().fill(WidgetPalette.color(i, count: s.legend.count, keys: s.colours, dark: scheme == .dark)).frame(width: 7, height: 7)
                    Text(s.legend[i]).font(.system(size: 10)).foregroundStyle(Color.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 12)
    }
}

/// Whose meter it is: Claude's mark, or ChatGPT's "GPT" tag — as in Kikumap's sidebar.
struct ProviderMark: View {
    let gpt: Bool

    var body: some View {
        if gpt {
            Text("GPT").font(.system(size: 6.5, weight: .heavy)).kerning(-0.2).foregroundStyle(Color.secondary)
                .padding(.horizontal, 2).frame(height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2.2).stroke(Color.secondary, lineWidth: 0.9))
        } else {
            Spark().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.1, lineCap: .round)).frame(width: 10, height: 10)
        }
    }
}

/// Kikumap's twelve uneven rays (Sources/Logo.swift draws the same mark in the app).
struct Spark: Shape {
    private static let rays: [CGFloat] = [1.0, 0.66, 0.92, 0.72, 0.97, 0.62, 0.9, 0.7, 0.95, 0.64, 0.88, 0.74]

    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height), c = CGPoint(x: r.midX, y: r.midY)
        let inner = s * 0.11, outer = s / 2 - 0.55
        var p = Path()
        for (i, len) in Self.rays.enumerated() {
            let a = (90 - 360 * CGFloat(i) / CGFloat(Self.rays.count)) * .pi / 180
            let r1 = inner + (outer - inner) * len
            p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y - sin(a) * inner))
            p.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y - sin(a) * r1))
        }
        return p
    }
}

/// The last 24 hours, one bar per hour, a segment per chat (stacked in colour order, every other chat on top).
struct HoursChart: View {
    /// Pieces shorter than this (seconds) aren't drawn.
    static let minPart: Double = 30
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
                            let segs = b.parts.enumerated().filter { $0.element >= HoursChart.minPart }
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
                    .fill(WidgetPalette.color(slot, count: named, keys: state.colours, dark: dark))
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
