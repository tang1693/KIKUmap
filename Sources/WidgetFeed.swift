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
        struct Item: Codable { var id: String; var title: String; var unsure: Bool? }
        struct Meter: Codable { var label: String; var percent: Double; var resets: String?; var group: String?; var minutes: Int?; var asOf: String? }
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
        /// Each named chat's branch colour on the map ("" for none), as the app's charts draw them.
        var colours: [String]?
        /// Claude's chat list can't be read now (or its unread marks): what that leaves unknown, said on the widget.
        var claudeNote: String?
        /// The note is about Claude's unread marks alone: what's running is read as usual.
        var claudeUnreadOnly: Bool?
        /// Seconds of the chart's 24 hours that are estimated (runs out of Kikumap's sight): its total says "≈".
        var estimated: Double?
    }

    let store: Store
    let usage: UsageMonitor
    let gpt: GPTWatcher
    private var lastKey = ""
    private var lastBody = Data()
    private var lastWrite = Date.distantPast
    private var lastBeat = Date.distantPast

    /// What's off with reading Claude right now (nil: nothing), and whether it's only Claude's unread marks.
    var claudeNote: (() -> (text: String, unreadOnly: Bool)?)?

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
        func meter(_ label: String, _ percent: Double, _ resets: Date?, _ group: String, minutes: Int, asOf: Date? = nil) -> State.Meter {
            let r = resets.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
            return State.Meter(label: label, percent: percent.rounded(), resets: r.map { Clock.iso($0) }, group: group,
                               minutes: minutes > 0 ? minutes : nil, asOf: asOf.map { Clock.iso($0) })
        }
        if UsageMonitor.enabled {
            // Claude's: the 5-hour session, the week, and the Sonnet-only week while it's the one that holds you back,
            // as they can be shown now (from an earlier read: saying when). The Sonnet one has no length, so the small
            // widget calls it "S" rather than a second "7d".
            for (label, w, minutes) in [(tr("会话", "Session"), usage.shownSession, 300), (tr("本周", "Week"), usage.shownWeekly, 7 * 1440),
                                        ("Sonnet", usage.bindingSonnet, 0)] {
                if let w = w { meters.append(meter(label, w.percent, w.resets, "claude", minutes: minutes, asOf: usage.asOf)) }
            }
        }
        // ChatGPT's, as its latest answer on this Mac left them (from a while back: saying when); a window that has
        // reset since is unknown, so it's left out
        let gptOn = GPTWatcher.enabled && GPTWatcher.available
        if gptOn, let u = gpt.usage {
            let old = Date().timeIntervalSince(u.at) > 900
            for w in u.windows where !(w.resets.map { $0 < Date() } ?? false) {
                meters.append(meter(GPTWatcher.windowLabel(w.minutes), w.percent, w.resets, "gpt", minutes: w.minutes, asOf: old ? u.at : nil))
            }
        }
        let note = closed ? nil : claudeNote?()
        // (a run going out of sight, or Claude no longer read, changes what the widget says: a redraw)
        let key = [run.map { $0.id + (store.outOfSight($0.id) ? "?" : "") }.joined(separator: ","), unread.map(\.id).joined(separator: ","), note?.text ?? "",
                   meters.map { "\($0.group ?? "")\($0.label)\($0.percent)\($0.resets ?? "")\($0.asOf ?? "")" }.joined(separator: ","),
                   Prefs.english ? "en" : "zh", closed ? "closed" : ""].joined(separator: "|")
        // at least every five minutes the chart moves on, and every ten the file is written again even if
        // nothing changed, so the widget always has a fresh "updated" to tell Kikumap is running
        let heartbeat = Date().timeIntervalSince(lastBeat) >= 600
        guard force || heartbeat || key != lastKey || Date().timeIntervalSince(lastWrite) >= 300 else { return }

        // the last 24 hours, by the hour; the five busiest chats get a colour each, the rest share one
        let hour = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let bounds = (0...24).map { hour.addingTimeInterval(Double($0 - 23) * 3600) }
        let slots = store.worked(bounds)
        let guessed = store.estimated([bounds[0], bounds[bounds.count - 1]])[0].values.reduce(0, +)
        var totals: [String: Double] = [:]
        for s in slots { for (id, v) in s { totals[id, default: 0] += v } }
        let top = totals.filter { $0.value >= 60 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { $0.key }
        let hours = zip(bounds, slots).map { start, s -> State.Hour in
            var parts = top.map { (s[$0] ?? 0).rounded() }
            parts.append(s.filter { !top.contains($0.key) }.values.reduce(0, +).rounded())
            return State.Hour(start: Clock.iso(start), parts: parts)
        }

        // (one out of Kikumap's sight, not known to run still, is marked so)
        func items(_ cs: [Chat]) -> [State.Item] { cs.prefix(6).map { State.Item(id: $0.id, title: store.name($0.id), unsure: store.outOfSight($0.id) ? true : nil) } }
        var state = State(updated: "", english: Prefs.english, closed: closed ? true : nil,
                          running: items(run), unread: items(unread), runningCount: run.count, unreadCount: unread.count,
                          meters: meters, usageOff: !UsageMonitor.enabled && !gptOn, hours: hours, legend: top.map { store.name($0) },
                          colours: top.map { id in store.map.branchColorKey(ofChat: id).flatMap { Theme.highlight($0) == nil ? nil : $0 } ?? "" },
                          claudeNote: note?.text, claudeUnreadOnly: note?.unreadOnly == true ? true : nil,
                          estimated: guessed >= 60 ? guessed.rounded() : nil)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        guard let body = try? e.encode(state) else { return }
        lastKey = key
        lastWrite = Date()
        let changed = body != lastBody
        if !changed && !force && !heartbeat { return }
        lastBody = body
        lastBeat = Date()
        state.updated = Clock.iso()
        guard let data = try? e.encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
        redraw(key, now: force)
    }

    /// macOS lets an app redraw its widget only so many times a day (spent, its requests are ignored and the widget
    /// sits on an old picture). So a redraw is asked for only when what it says changes (the chats running or unread,
    /// the meters, Kikumap quitting or starting), at most every five minutes, the latest always delivered in the end;
    /// the chart alone and the heartbeat wait for the widget's next timeline.
    private var lastRedraw = Date.distantPast, redrawnKey = ""
    private var redrawLater: Timer?
    private func redraw(_ key: String, now: Bool) {
        guard now || key != redrawnKey else { return }
        let wait = 300 - Date().timeIntervalSince(lastRedraw)
        if now || wait <= 0 || wait > 300 {
            redrawLater?.invalidate(); redrawLater = nil
            redrawnKey = key
            lastRedraw = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: "KikumapWidget")
        } else if redrawLater == nil {
            redrawLater = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; self.redrawLater = nil; self.redraw(self.lastKey, now: true) }
            }
        }
    }
}
