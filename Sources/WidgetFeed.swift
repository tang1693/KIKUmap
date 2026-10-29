import Cocoa
import WidgetKit

/// What the desktop widget (Widget/) shows, written to the one file it may read:
/// ~/Library/Application Support/ClaudeConsole/widget.json — there even when the data folder was moved,
/// since the widget is sandboxed to that path. WidgetKit only redraws so often, so the file (and the
/// redraw request) changes right away for the lists and meters, and at most every five minutes for the chart.
@MainActor
final class WidgetFeed {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeConsole/widget.json")

    /// Same shape as WidgetState in Widget/WidgetViews.swift — keep the two in step.
    private struct State: Codable {
        struct Item: Codable { var id: String; var title: String }
        struct Meter: Codable { var label: String; var percent: Double; var resets: String?; var group: String?; var minutes: Int? }
        struct Hour: Codable { var start: String; var parts: [Double] }
        var updated: String
        var english: Bool
        var closed: Bool?
        var running: [Item]
        var unread: [Item]
        var runningCount: Int
        var unreadCount: Int
        var meters: [Meter]
        var usageOff: Bool
        var hours: [Hour]
        var legend: [String]
    }

    let store: Store
    let usage: UsageMonitor
    let gpt: GPTWatcher
    private var lastKey = ""
    private var lastBody = Data()
    private var lastWrite = Date.distantPast

    init(store: Store, usage: UsageMonitor, gpt: GPTWatcher) {
        self.store = store
        self.usage = usage
        self.gpt = gpt
    }

    func update(force: Bool = false) { write(closed: false, force: force) }

    /// Kikumap is quitting: the widget says so, instead of showing chats as still running.
    func closing() { write(closed: true, force: true) }

    private func write(closed: Bool, force: Bool) {
        let run = closed ? [] : store.runningChats, unread = closed ? [] : store.unreadChats
        var meters: [State.Meter] = []
        // whole percents and minutes, so small wobbles don't cost a redraw
        func meter(_ label: String, _ percent: Double, _ resets: Date?, _ group: String, minutes: Int) -> State.Meter {
            let r = resets.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
            return State.Meter(label: label, percent: percent.rounded(), resets: r.map { Clock.iso($0) }, group: group,
                               minutes: minutes > 0 ? minutes : nil)
        }
        if UsageMonitor.enabled {
            // Claude's: the 5-hour session and the week
            for (label, w, minutes) in [(tr("会话", "Session"), usage.session, 300), (tr("本周", "Week"), usage.weekly, 7 * 1440)] {
                if let w = w { meters.append(meter(label, w.percent, w.resets, "claude", minutes: minutes)) }
            }
        }
        // ChatGPT's, as its latest answer left them; a window that has reset since starts again at zero
        let gptOn = GPTWatcher.enabled && GPTWatcher.available
        if gptOn, let u = gpt.usage {
            for w in u.windows {
                let label = w.minutes > 0 && w.minutes <= 1440 ? tr("会话", "Session") : tr("本周", "Week")
                let over = w.resets.map { $0 < Date() } ?? false
                meters.append(meter(label, over ? 0 : w.percent, over ? nil : w.resets, "gpt", minutes: w.minutes))
            }
        }
        let key = [run.map(\.id).joined(separator: ","), unread.map(\.id).joined(separator: ","),
                   meters.map { "\($0.group ?? "")\($0.label)\($0.percent)\($0.resets ?? "")" }.joined(separator: ","),
                   Prefs.english ? "en" : "zh", closed ? "closed" : ""].joined(separator: "|")
        guard force || key != lastKey || Date().timeIntervalSince(lastWrite) >= 300 else { return }

        // the last 24 hours, by the hour; the five busiest chats get a colour each, the rest share one
        let hour = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let bounds = (0...24).map { hour.addingTimeInterval(Double($0 - 23) * 3600) }
        let slots = store.worked(bounds)
        var totals: [String: Double] = [:]
        for s in slots { for (id, v) in s { totals[id, default: 0] += v } }
        let top = totals.filter { $0.value >= 60 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { $0.key }
        let hours = zip(bounds, slots).map { start, s -> State.Hour in
            var parts = top.map { (s[$0] ?? 0).rounded() }
            parts.append(s.filter { !top.contains($0.key) }.values.reduce(0, +).rounded())
            return State.Hour(start: Clock.iso(start), parts: parts)
        }

        func items(_ cs: [Chat]) -> [State.Item] { cs.prefix(6).map { State.Item(id: $0.id, title: store.name($0.id)) } }
        var state = State(updated: "", english: Prefs.english, closed: closed ? true : nil,
                          running: items(run), unread: items(unread), runningCount: run.count, unreadCount: unread.count,
                          meters: meters, usageOff: !UsageMonitor.enabled && !gptOn, hours: hours, legend: top.map { store.name($0) })
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let body = try? e.encode(state) else { return }
        lastKey = key
        lastWrite = Date()
        if body == lastBody && !force { return }
        lastBody = body
        state.updated = Clock.iso()
        guard let data = try? e.encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: "KikumapWidget")
    }
}
