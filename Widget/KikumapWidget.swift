import SwiftUI
import WidgetKit

// The desktop widget: running, unread and usage on top, the last 24 hours below.
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
    /// is written); Kikumap asks for a fresh timeline whenever it writes the file.
    func getTimeline(in context: Context, completion: @escaping (Timeline<KikumapEntry>) -> Void) {
        let now = Date(), state = WidgetState.load()
        let hour = WidgetTime.hourStart(now)
        let later = (1...6).map { KikumapEntry(date: hour.addingTimeInterval(Double($0) * 3600), state: state) }
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
        .description(zh ? "进行中、未读、用量，和最近 24 小时 Claude 干了多久。"
                        : "Running, unread, usage, and how long Claude worked in the last 24 hours.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct KikumapWidgets: WidgetBundle {
    var body: some Widget { KikumapWidget() }
}
