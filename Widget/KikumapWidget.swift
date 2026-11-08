import SwiftUI
import WidgetKit

// The desktop widget: how long Claude, ChatGPT and Codex worked (the last 24 hours, the last 7 days) and usage, as of when
// KIKUmap last wrote.
// It only reads ~/Library/Application Support/ClaudeConsole/widget.json (Widget.entitlements), which
// KIKUmap rewrites when something changes and asks WidgetKit to redraw.

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
    /// is written); KIKUmap asks for a fresh timeline whenever it writes the file. Also the moment a usage number
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
        StaticConfiguration(kind: "KikumapWidget", provider: KikumapProvider()) { entry in
            KikumapWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("KIKUmap")
        .description(WidgetText.gallery(!WidgetText.systemChinese))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct KikumapWidgets: WidgetBundle {
    var body: some Widget { KikumapWidget() }
}
