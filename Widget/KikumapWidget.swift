import SwiftUI
import WidgetKit

// The desktop widget: how long Claude worked (the last 24 hours, the last 7 days) and usage, as of when Kikumap last wrote.
// It only reads ~/Library/Application Support/ClaudeConsole/widget.json (Widget.entitlements), which
// Kikumap rewrites when something changes and asks WidgetKit to redraw.

struct KikumapEntry: TimelineEntry {
    let date: Date
    let state: WidgetState?
}

struct KikumapProvider: TimelineProvider {
    func placeholder(in context: Context) -> KikumapEntry {
        KikumapEntry(date: Date(), state: .sample(Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (KikumapEntry) -> Void) {
        let now = Date()
        completion(KikumapEntry(date: now, state: context.isPreview ? .sample(now) : WidgetState.load()))
    }

    /// Now, then each of the next six hours (the chart moves along with the clock even if nothing new
    /// is written); Kikumap asks for a fresh timeline whenever it writes the file. Also the moment a usage number
    /// from an earlier read turns a quarter of an hour old, when the small widget stops showing it.
    func getTimeline(in context: Context, completion: @escaping (Timeline<KikumapEntry>) -> Void) {
        let now = Date(), state = WidgetState.load()
        let hour = WidgetTime.hourStart(now)
        let aged = Set((state?.meters ?? []).compactMap { WidgetTime.parse($0.asOf)?.addingTimeInterval(901) }).filter { $0 > now }
        let later = ((1...6).map { hour.addingTimeInterval(Double($0) * 3600) } + aged).sorted().map { KikumapEntry(date: $0, state: state) }
        completion(Timeline(entries: [KikumapEntry(date: now, state: state)] + later, policy: .atEnd))
    }
}

struct KikumapWidgetEntryView: View {
    let entry: KikumapEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let size: WidgetSize = family == .systemSmall ? .small : family == .systemLarge ? .large : .medium
        KikumapWidgetView(state: entry.state, date: entry.date, size: size)
            .widgetURL(URL(string: "kikumap://map"))
            .containerBackground(for: .widget) { WidgetPalette.surface(dark: scheme == .dark) }
    }
}

struct KikumapWidget: Widget {
    var body: some WidgetConfiguration {
        let zh = WidgetText.systemChinese
        return StaticConfiguration(kind: "KikumapWidget", provider: KikumapProvider()) { entry in
            KikumapWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Kikumap")
        .description(zh ? "最近 24 小时和 7 天 Claude 干了多久，还有用量。在跑和未读的看菜单栏。"
                        : "How long Claude worked in the last 24 hours and 7 days, and your usage. What's running or unread is in the menu bar.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct KikumapWidgets: WidgetBundle {
    var body: some Widget { KikumapWidget() }
}
