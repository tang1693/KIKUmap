import Cocoa

// The stage on Settings → Shortcuts: a sample map, list, timeline and window, drawn in code and acted on step by step
// (keys going down in big caps, the pointer moving and clicking), so each shortcut shows where it works and what it
// does. It mirrors what KIKUmap really does (MapView, SidebarView, TimelineView, the menus); the sample is marked
// "Example" so its chats are never taken for yours. It plays only when a row is clicked, once, up from black and back
// to black, so it's plain when a demo starts and when it's over. Settings → Access plays its demos on one too (what
// each item lets KIKUmap read, beside what KIKUmap then shows), with a caption under each instead of keys.

/// An item of the sample map.
struct DemoNode {
    enum Kind { case root, topic, sub, chat }
    var id: String
    var title: String
    var parent: String?
    var kind: Kind
    var state = 0                       // chats: 0 plain, 1 unread, 2 running
    var app = "claude"                  // "claude", "gpt" or "code"
    var folded = false
    var tag: NSColor? = nil
    var tagIcon: String? = nil
    /// What the map says after a chat's name ("waiting for you", "running?"), as MapView's time label does.
    var note: String? = nil
    /// Running and seen running (the orange stretch goes round it); false: out of sight ("running?"), the outline
    /// stands dark and still.
    var seen = true
}

/// A row of the sample left column.
struct DemoRow {
    var id: String
    var title: String
    var state = 0
    var app = "claude"
    var placed = true
    /// What the row says at its end ("running", "just now"), as the left column's time does.
    var note: String? = nil
}

/// A usage line of the menu-bar drop-down (UsageMenuView): its name, how much is used (nil: "—"), the line under it.
struct DemoUsage {
    var title: String
    var percent: Double?
    var sub: String
}

/// Everything a demo can change: the map, the list, the timeline, the window and what's laid over them.
struct DemoWorld {
    var nodes: [DemoNode] = []
    var sel: Set<String> = []
    var editing: String? = nil
    var bright: Set<String>? = nil      // a search or a tag: only these stay bright
    var lit: [String: NSColor] = [:]    // a tag lighting up its items
    var pan = CGPoint.zero
    var zoom: CGFloat = 1
    var mapFocus = true

    var rows: [DemoRow] = []
    var picked: Set<String> = []
    var listFocus = false
    var filter = ""

    var tlShift: CGFloat = 0
    var tlScale: CGFloat = 1
    var following = true
    var tlHover: CGFloat? = nil

    var windowShown: CGFloat = 1
    var sideShown: CGFloat = 1
    var tlShown: CGFloat = 1
    var ui: CGFloat = 1
    var searchShown = false

    var card: (title: String, app: String)? = nil
    var menu: [String]? = nil
    var menuAt = CGPoint.zero
    var bubble: String? = nil
    var bubbleAt = CGPoint.zero
    var box: CGRect? = nil
    /// A selection box drawn round these items (dragging on empty space).
    var boxAround: Set<String> = []
    /// The chat whose ↗ and ✉ buttons show (hovered).
    var buttonsFor: String? = nil
    var spin: CGFloat = 0

    // Settings → Access: another app beside KIKUmap, and what KIKUmap shows of it
    /// The other app's own chat list (Claude's or ChatGPT's sidebar), each row's state as that app shows it: 0 plain,
    /// 1 done and unread, 2 running; `app` "gpt": pinned in ChatGPT (a pin before it, in its Pinned section).
    var appRows: [DemoRow] = []
    /// The other app's window: 1 open, 0 closed.
    var appShown: CGFloat = 1
    /// KIKUmap reading the other app: the arrow over to KIKUmap dark; Claude's list outlined too, as its window is
    /// what's read (with Accessibility). ChatGPT's files are read, not its window: its list is never outlined.
    var reads = false
    /// The lines in a terminal window.
    var term: [String] = []
    /// A banner from Notification Center (nil: none).
    var banner: (title: String, body: String)? = nil
    /// The menu-bar icon (StatusBar.image): how many run (and whether KIKUmap sees them), unread, waiting for you.
    var icon = (run: 0, seen: true, unread: 0, needs: 0)
    /// The menu-bar drop-down: open or not, its usage heading and lines (no lines: the item that turns Claude's on).
    var menuOpen = false
    var usageHead = ""
    var usage: [DemoUsage] = []
    /// What's happening, in a few words under the picture.
    var caption: String? = nil
}

/// One step: keys going down (the HUD shows them; `lights`: the playing row's keys light up too), letters typed into
/// the name being edited, the pointer gliding somewhere and clicking; then what changes.
struct DemoStep {
    var keys: [KeyPart]? = nil
    var lights = true
    var type: String? = nil
    /// Where the pointer glides first: an item's id, "r:" and a row's id, or "empty", "icon", "lanes", "bar",
    /// "search", "refresh", "kicon" (KIKUmap's icon on an Access demo's menu bar) (the stage finds the spot).
    var pointAt: String? = nil
    var clicks = 0
    var right = false
    var hold: Double = 0.22
    var dur: Double = 1.05
    /// A cut: what the last keys brought up is put away, or the next part is set up (another item picked). A still
    /// (Reduce Motion) ends before it.
    var cut = false
    var change: ((inout DemoWorld) -> Void)? = nil
}

/// Which part of KIKUmap a demo happens in (the small window glyph at the top left fills it in).
enum DemoPart { case desktop, menuBar, window, map, list, tags, timeline }

/// What the stage draws for a demo. Settings → Access's: the Claude app's window, Notification Center's banner
/// (Claude's window closed), a terminal running Claude Code, the ChatGPT app's window, each beside what KIKUmap shows
/// of it; the menu-bar drop-down's usage.
enum DemoView {
    case map, list, timeline, window, menuBar
    case claudeApp, notice, terminal, chatGPTApp, usageMenu
    /// One of Settings → Access's: a caption under it instead of keys.
    var isAccess: Bool { [.claudeApp, .notice, .terminal, .chatGPTApp, .usageMenu].contains(self) }
}

struct DemoSlice {
    var whereText: String
    var part: DemoPart
    var view: DemoView
    var setup: DemoWorld
    var steps: [DemoStep]
}

final class ShortcutStage: NSView {
    /// Where the picture is. Nothing plays by itself: a click on a row plays its demo once, up from black, its steps,
    /// its last frame a moment, back to black. `idle`: nothing chosen yet (black, "click a row below"); `leave`: going
    /// to black early (another row clicked, or Esc); `ended`: over (black, "watch again"); `still`: Reduce Motion
    /// (no fades, no motion).
    enum Phase { case idle, fadeIn, run, hold, fadeOut, leave, ended, still }
    /// Up from black, the last frame held, back to black on its own, and to black early (seconds).
    static let fadeInTime = 0.45, holdTime = 0.8, fadeOutTime = 0.6, leaveTime = 0.22

    /// The demo chosen (nil: none yet), and its row's name (for VoiceOver).
    private(set) var slice: DemoSlice?
    private(set) var title = ""
    private(set) var phase = Phase.idle
    /// Clicked while it plays, or Settings left: its clock stands still until the picture is clicked again.
    private(set) var paused = false
    /// The keys going down right now (nil: none), so the legend row lights just those.
    var onLit: (([KeyPart]?) -> Void)?
    /// A pass ended by itself (faded out to black).
    var onPassEnded: (() -> Void)?
    /// What the picture shows changed (playing, paused, over…), for the rows.
    var onChange: (() -> Void)?
    /// Whether motion is reduced (System Settings → Accessibility → Display), asked as each demo starts.
    var reducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var world = DemoWorld() { didSet { version += 1 } }
    private var from: DemoWorld?
    /// Goes up with every change to the world: layouts are worked out once per change, not every frame.
    private var version = 0
    private var layoutCache: [String: [String: NSRect]] = [:]
    /// The ticking timer is fast (60 Hz) while something moves, else at the running-ring rate.
    private var fast = true
    private var tweenStart: TimeInterval = 0
    private let tweenDur = 0.32
    private var step = -1
    private var stepStart: TimeInterval = 0
    private var phaseStart: TimeInterval = 0
    /// Going to black early: how black it was then, and the demo after it (nil: none, it stops there): the row
    /// clicked meanwhile, which comes up, or only waits on the black ("watch again") if Esc came after that click.
    private var leaveFrom: CGFloat = 0
    private var queued: (slice: DemoSlice, title: String, plays: Bool)?
    private var keysDown = false
    private var hud: [KeyPart]?
    private var hudLit = false
    private var typed: (id: String, full: String, start: TimeInterval)?
    private var pointer: CGPoint?
    private var pointerFrom: CGPoint?
    private var pointerTo: CGPoint?
    private var ripple: (at: CGPoint, start: TimeInterval, count: Int)?
    private var applied = false
    private var timer: Timer?
    /// The stage's own time: it only goes on while the timer runs, so a demo picks up where it was left (a pause,
    /// Settings left) instead of jumping ahead.
    private var clock: TimeInterval = 0
    private var lastTick: TimeInterval?

    /// The words on the black: before anything is chosen, after a demo, and while one is paused.
    static var chooseHint: String { tr("点下面的一行，看它在哪里、怎么用", "Click a row below to see where and how it works") }
    /// Before anything is chosen on this page (nil: Shortcuts' words, `chooseHint`).
    var idleHint: String? { didSet { if phase == .idle { needsDisplay = true; changed() } } }
    static var againHint: String { tr("▶ 再看一次", "▶ Watch again") }
    static var pausedHint: String { tr("已暂停 · 点一下继续", "Paused · click to go on") }
    /// Their light gray, the same on black in light and dark.
    static let hintInk = NSColor(srgbRed: 0.84, green: 0.84, blue: 0.84, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        // Reduce Motion turned on or off while it shows: a demo going becomes its still; a still gives way to black
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        changed()
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // MARK: what it shows

    /// A demo on its way for the row chosen: coming up, playing (or paused), fading out, or the one coming up
    /// after the picture goes to black.
    var isPlaying: Bool {
        switch phase {
        case .fadeIn, .run, .hold, .fadeOut: return true
        case .leave: return queued?.plays == true
        default: return false
        }
    }
    /// Something for the timer to do: a fade, the steps, the last frame held.
    private var isMoving: Bool { [.fadeIn, .run, .hold, .fadeOut, .leave].contains(phase) }

    /// How black the picture is (0…1): black before anything plays and after it, clear while a demo runs.
    var veil: CGFloat {
        let t = clock - phaseStart
        switch phase {
        case .idle, .ended: return 1
        case .run, .hold, .still: return 0
        case .fadeIn: return 1 - smooth(min(1, t / Self.fadeInTime))
        case .fadeOut: return smooth(min(1, t / Self.fadeOutTime))
        case .leave: return leaveFrom + (1 - leaveFrom) * smooth(min(1, t / Self.leaveTime))
        }
    }

    /// How black it's drawn: the veil, deeper while paused so the words read.
    var shade: CGFloat { paused ? max(veil, Self.pauseShade) : veil }
    private static let pauseShade: CGFloat = 0.55

    /// The words in the middle of the picture (nil: none).
    var hint: String? {
        if paused { return Self.pausedHint }
        switch phase {
        case .idle: return idleHint ?? Self.chooseHint
        case .ended: return Self.againHint
        default: return nil
        }
    }

    /// Plays a demo once, from its start. One showing goes to black first; with Reduce Motion, its still at once.
    func play(_ s: DemoSlice, title: String = "") {
        let was = shade
        paused = false
        if reducedMotion() { queued = nil; load(s, title); showStill(); return }
        if was >= 0.999 { queued = nil; load(s, title); enter(.fadeIn); return }
        queued = (s, title, true)
        if phase == .leave { changed(); return }
        leaveFrom = was
        setLit(nil)
        enter(.leave)
    }

    /// Nothing chosen: black, with the hint to click a row (the page opened, or another place picked).
    func reset() {
        queued = nil
        paused = false
        setLit(nil)
        slice = nil
        title = ""
        world = DemoWorld()
        from = nil; hud = nil; typed = nil; pointer = nil; pointerFrom = nil; pointerTo = nil; ripple = nil
        enter(.idle)
    }

    /// A demo chosen but not playing (its row was rebuilt): black with "watch again", or with Reduce Motion its still.
    func cue(_ s: DemoSlice, title: String) {
        queued = nil
        paused = false
        load(s, title)
        if reducedMotion() { showStill() } else { enter(.ended) }
    }

    /// Esc: a demo going fades to black quickly and stops there. Already going to black for another row clicked:
    /// that row stays the one chosen (as the page shows), waiting on the black instead of coming up. Whether there
    /// was one.
    @discardableResult func stop() -> Bool {
        guard isMoving else { return false }
        let was = shade                 // as dark as it's drawn now (deeper while paused): no jump
        paused = false
        if phase == .leave { queued?.plays = false; changed(); return true }
        leaveFrom = was
        queued = nil
        setLit(nil)
        enter(.leave)
        return true
    }

    /// A click on the picture: pause or go on while it plays; once it's over (or fading out), play it again.
    func clicked() {
        switch phase {
        case .fadeIn, .run, .hold: togglePause()
        case .fadeOut, .ended: if let s = slice { play(s, title: title) }
        default: break                  // nothing chosen yet, a still, or already going to black
        }
    }

    /// Paused, its clock stands still (it goes on where it was).
    func togglePause() {
        guard [.fadeIn, .run, .hold].contains(phase) else { return }
        paused.toggle()
        updateTimer()
        needsDisplay = true
        changed()
    }

    /// A demo's first frame, nothing moving yet.
    private func load(_ s: DemoSlice, _ t: String) {
        slice = s
        title = t
        world = s.setup
        from = nil
        step = -1
        applied = false
        typed = nil; hud = nil; hudLit = false
        pointer = nil; pointerFrom = nil; pointerTo = nil; ripple = nil
        setLit(nil)
    }

    /// Reduce Motion: the row's own keys (a row without keys: its first click) and what they do, standing still. The
    /// steps up to them, then the ones carrying on from them (the name typed, the drop after a drag, the search
    /// filled in), up to the next keys, the next click or a cut (which would put the result away again). Those keys
    /// stay shown down, the pointer where it went.
    private func showStill() {
        guard let s = slice else { return }
        let first = s.steps.firstIndex { $0.keys != nil && $0.lights } ?? s.steps.firstIndex { $0.change != nil || $0.type != nil } ?? 0
        var at: CGPoint?
        for (i, st) in s.steps.enumerated() {
            if i > first && (st.keys != nil || st.clicks > 0 || st.cut) { break }
            if let k = st.pointAt, let p = spot(k) { at = p }       // where it goes, as things are when it starts
            st.change?(&world)
            if let t = st.type, let e = world.editing { rename(e, t) }
        }
        world.editing = nil
        hud = s.steps.indices.contains(first) ? s.steps[first].keys : nil
        hudLit = true
        pointer = at
        enter(.still)
    }

    private func enter(_ p: Phase) {
        phase = p
        phaseStart = clock
        updateTimer()
        needsDisplay = true
        changed()
    }

    /// The tooltip and what VoiceOver says follow what the picture shows; the page hears of it.
    private func changed() {
        let next = phase == .leave ? queued : nil
        let whereText = (next?.slice ?? slice)?.whereText ?? ""
        let raw = next?.title ?? title
        let name = raw.isEmpty ? whereText : raw
        let label: String, tip: String?
        if phase == .idle {
            label = tr("演示画面：还没选。", "Demo: nothing chosen yet. ") + (idleHint ?? Self.chooseHint)
            tip = nil
        } else if paused {
            label = tr("演示画面：「\(name)」已暂停，点一下继续", "Demo: “\(name)” paused; click to go on")
            tip = tr("点一下继续", "Click to go on")
        } else if phase == .still {
            label = tr("演示画面：「\(name)」的静止画面（已打开减弱动态效果）", "Demo: a still of “\(name)” (Reduce Motion is on)")
            tip = nil
        } else if !isPlaying {
            label = tr("演示画面：「\(name)」演示完了，点一下再看一次", "Demo: “\(name)” ended; click to watch again")
            tip = phase == .ended ? tr("点一下再看一次", "Click to watch again") : nil
        } else {
            label = tr("演示画面：正在演示「\(name)」（\(whereText)）", "Demo: playing “\(name)” (\(whereText))")
            tip = phase == .fadeOut ? tr("点一下再看一次", "Click to watch again") : phase == .leave ? nil : tr("点一下暂停", "Click to pause")
        }
        setAccessibilityLabel(label)
        if toolTip != tip { toolTip = tip }
        onChange?()
    }

    private func setLit(_ parts: [KeyPart]?) {
        guard (parts != nil) != keysDown else { return }
        keysDown = parts != nil
        onLit?(parts)
    }

    private func rename(_ id: String, _ t: String) {
        if let i = world.nodes.firstIndex(where: { $0.id == id }) { world.nodes[i].title = t }
    }

    /// A click on the picture: it takes the focus (so Esc stops what it plays), then pauses, goes on or plays again.
    override func mouseDown(with e: NSEvent) { press() }
    override var acceptsFirstResponder: Bool { true }
    /// Space or Return: as a click on the picture; Esc: stop.
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49, 36, 76: if !e.isARepeat { clicked() }  // (held down: once)
        default: super.keyDown(with: e)
        }
    }
    override func cancelOperation(_ sender: Any?) { stop() }
    override func accessibilityPerformPress() -> Bool { press(); return true }
    private func press() {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        clicked()
    }

    @objc private func motionChanged() {
        if reducedMotion() {
            guard isMoving else { return }
            if phase == .leave && queued?.plays != true { arrive(); return }     // Esc pressed: black, "watch again"
            let next = queued ?? slice.map { (slice: $0, title: title, plays: true) }
            queued = nil
            paused = false
            if let n = next { load(n.slice, n.title); showStill() }
        } else if phase == .still {
            setLit(nil)
            enter(.ended)               // nothing starts by itself: black, "watch again"
        }
    }

    // MARK: running

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let nc = NotificationCenter.default
        let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        for n in names { nc.removeObserver(self, name: n, object: nil) }
        if let w = window { for n in names { nc.addObserver(self, selector: #selector(windowChanged(_:)), name: n, object: w) } }
        else { leftFront() }            // another tab, or the window gone
        updateTimer()
    }
    @objc private func windowChanged(_ n: Notification) {
        if n.name == NSWindow.willCloseNotification || !isFront { leftFront() }
        updateTimer()
    }

    /// Settings is the window you're using: in front, not covered.
    private var isFront: Bool {
        guard let w = window else { return false }
        return w.isVisible && w.occlusionState.contains(.visible) && w.isKeyWindow
    }

    /// Settings is no longer the window you're using (another window or app in front, covered, closed, another tab):
    /// a demo playing pauses and waits for a click, even once Settings is back; one already going to black finishes.
    private func leftFront() {
        switch phase {
        case .fadeIn, .run, .hold:
            guard !paused else { return }
            paused = true
            needsDisplay = true
            changed()
        case .fadeOut:
            finish()
        case .leave:
            arrive(pausing: true)
        default: break
        }
    }

    /// Gone to black early: the row clicked meanwhile comes up (paused, if Settings was left), or, Esc pressed after
    /// that click, it waits on the black, chosen ("watch again"); with no row clicked, it's over.
    private func arrive(pausing: Bool = false) {
        guard let q = queued else { enter(.ended); return }
        queued = nil
        load(q.slice, q.title)
        if q.plays { paused = pausing; enter(.fadeIn) } else { enter(.ended) }
    }

    /// The timer runs only while something fades or plays, it isn't paused, and Settings is the window you're using:
    /// 60 times a second while something moves, else at the running ring's rate. Nothing wakes up before a click,
    /// or once a demo is over.
    private func updateTimer() {
        let run = isFront && !paused && isMoving
        if run && timer == nil {
            let t = Timer(timeInterval: fast ? 1.0 / 60 : Theme.turnFrame, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self else { t.invalidate(); return }
                    self.tick()
                }
            }
            t.tolerance = 0.004
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !run, let t = timer {
            t.invalidate()
            timer = nil
            lastTick = nil                      // the clock stands still meanwhile
        }
    }

    /// Fast while something moves (a fade, a tween, the pointer, typing, a click, keys going down), slow otherwise.
    private func pace(_ moving: Bool) {
        guard moving != fast else { return }
        fast = moving
        timer?.invalidate(); timer = nil
        updateTimer()
    }

    private func tick() {
        guard isMoving, !paused, let s = slice else { updateTimer(); return }
        let real = ProcessInfo.processInfo.systemUptime
        if let l = lastTick { clock += min(real - l, 0.1) }
        lastTick = real
        let t = clock - phaseStart
        switch phase {
        case .fadeIn:
            if t >= Self.fadeInTime { enter(.run) }     // the steps start on the next tick
            pace(true)
        case .run:
            runSteps(s)
        case .hold:
            if t >= Self.holdTime { enter(.fadeOut) }
            pace(phase == .fadeOut)
        case .fadeOut:
            if t >= Self.fadeOutTime { finish() } else { pace(true) }
        case .leave:
            if t >= Self.leaveTime { arrive() }
            pace(true)
        default: break
        }
        needsDisplay = true
    }

    /// The steps, one after another; after the last, its frame holds.
    private func runSteps(_ s: DemoSlice) {
        let now = clock
        if step < 0 { step = 0; stepStart = now; begin(s.steps.first) }
        guard step < s.steps.count else { endSteps(); return }
        let st = s.steps[step], t = now - stepStart
        // the pointer glides, then clicks
        if let a = pointerFrom, let b = pointerTo {
            let p = smooth(min(1, t / 0.45))
            pointer = CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p - sin(p * .pi) * 10)
        }
        let at = st.pointAt != nil ? 0.5 : 0.3
        if st.keys != nil {
            hudLit = t >= at && t < at + st.hold
            setLit(st.lights && hudLit ? st.keys : nil)
        }
        if let ty = typed {
            let per = ty.full.unicodeScalars.contains { $0.value > 0x2E80 } ? 0.2 : 0.11
            let n = min(ty.full.count, max(0, Int((now - ty.start) / per)))
            rename(ty.id, String(ty.full.prefix(n)))
        }
        if !applied && t >= at {
            applied = true
            if st.clicks > 0, let p = pointer { ripple = (p, now, st.clicks) }
            if let c = st.change { from = world; tweenStart = now; c(&world) }
            if let ty = st.type, let e = world.editing { typed = (e, ty, now); rename(e, "") }
        }
        let moving = (from != nil && now - tweenStart < tweenDur) || (pointerTo != nil && t < 0.5) || typed != nil
            || (ripple.map { now - $0.start < 0.3 } ?? false) || (st.keys != nil && t < at + st.hold + 0.1)
        pace(moving)
        if t >= duration(st) {
            setLit(nil)
            hudLit = false
            if let ty = typed { rename(ty.id, ty.full) }
            typed = nil
            step += 1
            stepStart = now
            if step < s.steps.count { begin(s.steps[step]) } else { endSteps() }
        }
    }

    private func duration(_ st: DemoStep) -> Double {
        if let t = st.type { return max(st.dur, 0.45 + Double(t.count) * (t.unicodeScalars.contains { $0.value > 0x2E80 } ? 0.2 : 0.11) + 0.35) }
        return st.dur
    }

    private func begin(_ st: DemoStep?) {
        applied = false
        guard let st else { return }
        hud = st.keys
        hudLit = false
        if let k = st.pointAt, let p = spot(k) {
            // (from below right, or below left near the right edge, so it comes in from inside the picture)
            pointerFrom = pointer ?? CGPoint(x: p.x + 60 > scene.maxX - 12 ? p.x - 70 : p.x + 60, y: p.y + 50); pointerTo = p; pointer = pointerFrom
        }
        else { pointerFrom = nil; pointerTo = nil }
    }

    /// The last step done: its frame holds a moment (its keys still shown, up), then it fades out.
    private func endSteps() {
        setLit(nil)
        hudLit = false
        enter(.hold)
    }

    /// Faded out: it stops there, black, "watch again".
    private func finish() {
        setLit(nil)
        enter(.ended)
        onPassEnded?()
    }

    private func smooth(_ x: Double) -> CGFloat { CGFloat(x * x * (3 - 2 * x)) }

    /// Where the map of a demo is drawn (beside the list in the left column's demos).
    private func mapArea(_ v: DemoView) -> NSRect {
        v == .list ? NSRect(x: scene.minX + 214, y: scene.minY, width: scene.width - 214, height: scene.height) : scene
    }

    /// The timeline's plot, and where now is on it.
    private var plot: NSRect {
        let band = NSRect(x: scene.minX, y: scene.minY + 6, width: scene.width, height: scene.height - 12)
        return NSRect(x: band.minX + 70, y: band.minY + 30, width: band.width - 84, height: band.height - 44)
    }

    /// A named spot, in the stage's coordinates, as things are now.
    private func spot(_ key: String) -> CGPoint? {
        guard let s = slice else { return nil }
        let w = world
        switch key {
        case "empty": return CGPoint(x: scene.maxX - 70, y: scene.maxY - 22)
        case "icon": return CGPoint(x: scene.maxX - 78, y: scene.minY + 10)
        case "lanes": return CGPoint(x: plot.minX + plot.width * 0.3, y: plot.minY + 12)
        case "lanes2": return CGPoint(x: plot.minX + plot.width * 0.8, y: plot.minY + 12)
        case "bar": return CGPoint(x: plot.minX + plot.width * 0.62 - 8, y: plot.minY + 12)
        case "search": return CGPoint(x: scene.minX + 70, y: scene.minY + 32)
        case "refresh": return CGPoint(x: scene.minX + 192, y: scene.minY + 13)
        case "menu1":                   // the menu's fourth row, where it's drawn
            guard let m = w.menu, m.count > 3 else { return nil }
            let r = menuRect(m, at: w.menuAt)
            return CGPoint(x: r.minX + 30, y: r.minY + Self.menuRows(m).tops[3] + 7.5)
        case "kicon": let r = kikuIcon(w, in: menuStrip(scene)); return CGPoint(x: r.midX - 2, y: r.midY + 1)
        default: break
        }
        if key.hasPrefix("open:") || key.hasPrefix("mail:") {
            var ww = w
            if s.view == .list { ww.zoom *= 0.86 }
            guard let r = layout(ww, in: mapArea(s.view))[String(key.split(separator: ":")[1])] else { return nil }
            let b = buttonRect(r, key.hasPrefix("open:") ? 0 : 1)
            return CGPoint(x: b.midX, y: b.midY)
        }
                if key.hasPrefix("r:") {
            let id = String(key.dropFirst(2))
            let shown = w.rows.filter { w.filter.isEmpty || $0.title.localizedCaseInsensitiveContains(w.filter) }
            guard let i = shown.firstIndex(where: { $0.id == id }) else { return nil }
            return CGPoint(x: scene.minX + 70, y: scene.minY + 41 + CGFloat(i) * 18 + 8)
        }
        var ww = w
        if s.view == .list { ww.zoom *= 0.86 }
        guard let r = layout(ww, in: mapArea(s.view))[key] else { return nil }
        return CGPoint(x: r.minX + min(28, r.width / 2), y: r.midY)
    }

    // MARK: drawing

    /// Where the sample is drawn: under the header and over the keys; an Access demo's over its caption, as tall as
    /// the picture leaves (Settings → Access's picture is a shorter one).
    private var scene: NSRect {
        if slice?.view.isAccess == true { return NSRect(x: 12, y: 27, width: bounds.width - 24, height: bounds.height - 27 - 31) }
        return NSRect(x: 12, y: 28, width: bounds.width - 24, height: 132)
    }

    override func draw(_ dirtyRect: NSRect) {
        let v = veil
        if v < 0.999, let s = slice { drawFrame(s) }
        // black over it, pure black in light and dark alike: before a demo, after it, and fading between (deeper
        // while paused, so the words read)
        let shade = self.shade
        if shade > 0.001 {
            NSColor.black.withAlphaComponent(shade).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
        if let h = hint { drawHint(h, onFrame: v < 0.999) }
    }

    /// Where the words in the middle go.
    func hintRect(_ text: String) -> NSRect {
        let s = (text as NSString).size(withAttributes: [.font: Self.hintFont])
        return NSRect(x: ((bounds.width - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(), width: ceil(s.width), height: ceil(s.height))
    }
    private static let hintFont = Theme.ui(13, .medium)

    /// The words in the middle, light gray; over a frame (paused) on a dark pill, so they read whatever it shows.
    private func drawHint(_ text: String, onFrame: Bool) {
        let r = hintRect(text)
        if onFrame {
            let pill = r.insetBy(dx: -14, dy: -7)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        }
        (text as NSString).draw(at: r.origin, withAttributes: [.font: Self.hintFont, .foregroundColor: Self.hintInk])
    }

    /// The demo's frame as it is now: where it happens, the sample, the pointer, the keys.
    private func drawFrame(_ s: DemoSlice) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.bg.setFill(); card.fill()
        NSColor.separatorColor.setStroke(); card.lineWidth = 1; card.stroke()
        NSGraphicsContext.saveGraphicsState()
        card.addClip()
        drawWhere(s)
        // the world, tweening from the last change
        let p = from.map { _ in smooth(min(1, (clock - tweenStart) / tweenDur)) } ?? 1
        let a = (p < 1 ? from : nil) ?? world
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: scene).addClip()
        switch s.view {
        case .map: drawMap(a, world, p, in: scene)
        case .list: drawList(a, world, p, in: scene)
        case .timeline: drawTimeline(a, world, p, in: scene)
        case .window: drawWindow(a, world, p, in: scene)
        case .menuBar: drawMenuBar(a, world, p, in: scene)
        case .claudeApp: drawClaudeApp(a, world, p, in: scene)
        case .notice: drawNotice(a, world, p, in: scene)
        case .terminal: drawTerminal(a, world, p, in: scene)
        case .chatGPTApp: drawChatGPTApp(a, world, p, in: scene)
        case .usageMenu: drawUsageMenu(a, world, p, in: scene)
        }
        drawOverlays(world, p)
        if let pt = pointer { drawPointer(pt) }
        if let r = ripple {
            let k = CGFloat((clock - r.start) / 0.28)
            if k < 1 {
                Theme.ink.withAlphaComponent(0.5 * (1 - k)).setStroke()
                let rad = 3 + 9 * k
                let c = NSBezierPath(ovalIn: NSRect(x: r.at.x - rad, y: r.at.y - rad, width: rad * 2, height: rad * 2)); c.lineWidth = 1.5; c.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        drawHUD()
        if s.view.isAccess { drawCaption(a.caption, world.caption, p) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawWhere(_ s: DemoSlice) {
        drawLocator(s.part, in: NSRect(x: 12, y: 6, width: 26, height: 17))
        let f = Theme.ui(11.5, .semibold)
        (s.whereText as NSString).draw(at: NSPoint(x: 46, y: 7), withAttributes: [.font: f, .foregroundColor: Theme.muted])
        let ex = tr("示例", "Example")
        let ef = Theme.ui(10, .medium)
        let w = ex.size(withAttributes: [.font: ef]).width
        (ex as NSString).draw(at: NSPoint(x: bounds.width - 12 - w, y: 9), withAttributes: [.font: ef, .foregroundColor: Theme.muted])
    }

    /// A wireframe of the map window with the part the demo happens in filled.
    private func drawLocator(_ part: DemoPart, in r: NSRect) {
        let ink = Theme.ink
        let frame = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        ink.withAlphaComponent(0.6).setStroke(); frame.lineWidth = 1; frame.stroke()
        func fill(_ rr: NSRect, _ a: CGFloat = 0.8) { ink.withAlphaComponent(a).setFill(); NSBezierPath(roundedRect: rr, xRadius: 1, yRadius: 1).fill() }
        let head = NSRect(x: r.minX + 2, y: r.minY + 2, width: r.width - 4, height: 3)
        let col = NSRect(x: r.minX + 2, y: r.minY + 6, width: 7, height: r.height - 12)
        let tl = NSRect(x: r.minX + 2, y: r.maxY - 5, width: r.width - 4, height: 3)
        let map = NSRect(x: r.minX + 10, y: r.minY + 6, width: r.width - 12, height: r.height - 12)
        // every part faint, so the window reads as a window; the demo's part filled
        if part != .menuBar && part != .desktop { [head, col, tl, map].forEach { fill($0, 0.14) } }
        switch part {
        case .map: fill(map)
        case .list, .tags: fill(col)
        case .timeline: fill(tl)
        case .window: [head, col, tl, map].forEach { fill($0, 0.4) }
        case .menuBar: fill(NSRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: 3))
        case .desktop: fill(NSRect(x: r.midX - 5, y: r.midY - 3, width: 10, height: 7))
        }
    }

    private func drawHUD() {
        guard let parts = hud else { return }
        let w = Keycaps.width(parts, .large)
        Keycaps.draw(parts, at: NSPoint(x: (bounds.width - w) / 2, y: bounds.height - 44), .large, lit: hudLit)
    }

    private func drawPointer(_ p: CGPoint) {
        let img = NSCursor.arrow.image
        let hs = NSCursor.arrow.hotSpot
        let s = img.size
        if s.width > 0 && s.height > 0 {
            img.draw(in: NSRect(x: p.x - hs.x * 0.85, y: p.y - hs.y * 0.85, width: s.width * 0.85, height: s.height * 0.85),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        // no system arrow to draw (no window server, as in a headless check): one of our own, its tip on the spot
        let corners: [(CGFloat, CGFloat)] = [(0, 0), (0, 15.5), (3.9, 11.9), (6.5, 17.9), (9, 16.8), (6.4, 11), (11.2, 11)]
        let arrow = NSBezierPath()
        for (i, c) in corners.enumerated() {
            let q = CGPoint(x: p.x + c.0, y: p.y + c.1)
            if i == 0 { arrow.move(to: q) } else { arrow.line(to: q) }
        }
        arrow.close()
        arrow.lineJoinStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
        NSColor.white.setStroke(); arrow.lineWidth = 2.4; arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.setFill(); arrow.fill()
    }

    // MARK: the map

    private static let topicF = Theme.ui(11.5, .bold), subF = Theme.ui(11, .bold), chatF = Theme.ui(11)

    private func mark(_ app: String, _ c: NSColor) -> NSImage {
        app == "gpt" ? GPTWatcher.mark(c, height: 9) : Theme.claudeTag(c, height: 9)
    }

    private func size(_ n: DemoNode) -> NSSize {
        switch n.kind {
        case .root: return NSSize(width: 12, height: 12)
        case .topic: return NSSize(width: ceil(n.title.size(withAttributes: [.font: Self.topicF]).width) + 20 + (n.folded ? 20 : 0), height: 20)
        case .sub: return NSSize(width: ceil(n.title.size(withAttributes: [.font: Self.subF]).width) + 4, height: 18)
        case .chat:
            let w = ceil(n.title.size(withAttributes: [.font: Self.chatF]).width) + mark(n.app, Theme.muted).size.width + 6 + (n.app == "code" ? 14 : 0)
                + (n.note.map { ceil($0.size(withAttributes: [.font: Self.noteF]).width) + 6 } ?? 0)
            return NSSize(width: w + (n.state > 0 ? 16 : 2) + (n.tag != nil ? (n.tagIcon != nil ? 15 : 9) : 0), height: n.state > 0 ? 20 : 18)
        }
    }
    /// A chat's note after its name (MapView's time label).
    private static let noteF = Theme.ui(9.5)

    private func kids(_ w: DemoWorld, _ id: String) -> [DemoNode] { w.nodes.filter { $0.parent == id } }

    /// A tree growing right from the centre: each level past its parent, leaves 23 pt apart, a parent in the middle of
    /// its items, the whole tree centred in `area` (then panned and zoomed).
    private func layout(_ w: DemoWorld, in area: NSRect) -> [String: NSRect] {
        var out: [String: NSRect] = [:]
        guard let root = w.nodes.first(where: { $0.kind == .root }) else { return out }
        var leafY: CGFloat = 0
        func place(_ n: DemoNode, x: CGFloat, depth: Int) -> CGFloat {
            let sz = size(n)
            let ch = n.folded ? [] : kids(w, n.id)
            var y: CGFloat
            if ch.isEmpty {
                y = leafY; leafY += 23
            } else {
                let cx = n.kind == .root ? x + sz.width + 26 : x + sz.width + 22
                var ys: [CGFloat] = []
                for (i, c) in ch.enumerated() {
                    if n.kind == .root && i > 0 { leafY += 6 }
                    ys.append(place(c, x: cx, depth: depth + 1))
                }
                y = ((ys.first ?? 0) + (ys.last ?? 0)) / 2
            }
            out[n.id] = NSRect(x: x, y: y - sz.height / 2, width: sz.width, height: sz.height)
            return y
        }
        _ = place(root, x: 0, depth: 0)
        let all = out.values.reduce(out[root.id]!) { $0.union($1) }
        let fit = min(1, (area.height - 12) / max(1, all.height), (area.width - 30) / max(1, all.width))
        let z = w.zoom * fit
        let dx = area.minX + 18 - all.minX, dy = area.midY - all.midY
        for (k, r) in out {
            let rr = r.offsetBy(dx: dx, dy: dy)
            let c = CGPoint(x: area.minX + 18, y: area.midY)
            out[k] = NSRect(x: c.x + (rr.minX - c.x) * z + w.pan.x, y: c.y + (rr.minY - c.y) * z + w.pan.y, width: rr.width * z, height: rr.height * z)
        }
        return out
    }

    private func lerp(_ a: NSRect, _ b: NSRect, _ p: CGFloat) -> NSRect {
        NSRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p, width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
    }

    private func cachedLayout(_ w: DemoWorld, _ isWorld: Bool, in area: NSRect) -> [String: NSRect] {
        let key = "\(isWorld ? version : version - 1000_000)|\(area)|\(w.zoom)|\(w.pan)"
        if let c = layoutCache[key] { return c }
        if layoutCache.count > 12 { layoutCache = [:] }
        let l = layout(w, in: area)
        layoutCache[key] = l
        return l
    }

    private func drawMap(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        let fb = cachedLayout(b, true, in: area)
        let fa = p >= 1 ? fb : layout(a, in: area)
        let ids = Array(Set(fa.keys).union(fb.keys))
        let byID = Dictionary(b.nodes.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            .merging(a.nodes.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        func frame(_ id: String) -> (NSRect, CGFloat)? {
            switch (fa[id], fb[id]) {
            case let (x?, y?): return (lerp(x, y, p), 1)
            case let (nil, y?): return (y, p)
            case let (x?, nil): return (x, 1 - p)
            default: return nil
            }
        }
        // the words drawn at the scale the items are laid out at: the zoom, and how much the tree was shrunk to fit
        // (the root is 12 pt across at 1), so a name never runs out of its pill
        let z = b.nodes.first { $0.kind == .root }.flatMap { frame($0.id) }.map { $0.0.width / 12 } ?? b.zoom
        NSGraphicsContext.saveGraphicsState()
        // edges first
        for id in ids {
            guard let n = byID[id], let par = n.parent, let (r, al) = frame(id), let (pr, pal) = frame(par) else { continue }
            let alpha = min(al, pal) * dimAlpha(b, id)
            let start = byID[par]?.kind == .root ? CGPoint(x: pr.midX, y: pr.midY) : CGPoint(x: pr.maxX, y: byID[par]?.kind == .topic ? pr.midY : pr.maxY - 1)
            let end = CGPoint(x: r.minX, y: n.kind == .chat && n.state == 0 || n.kind == .sub ? r.maxY - 1 : r.midY)
            let path = NSBezierPath()
            path.move(to: start)
            path.curve(to: end, controlPoint1: CGPoint(x: (start.x + end.x) / 2, y: start.y), controlPoint2: CGPoint(x: (start.x + end.x) / 2, y: end.y))
            Theme.line.withAlphaComponent(alpha).setStroke(); path.lineWidth = 1.5 * z; path.stroke()
        }
        for id in ids {
            guard let n = byID[id], let (r, al) = frame(id) else { continue }
            drawNode(n, r, alpha: al * dimAlpha(b, id), editing: b.editing == id, z: z)
            if let c = b.lit[id] {
                c.withAlphaComponent(al).setStroke()
                let o = NSBezierPath(roundedRect: r.insetBy(dx: -4, dy: -3), xRadius: 6, yRadius: 6); o.lineWidth = 2.5; o.stroke()
            }
        }
        // the selection ring, fading from where it was to where it is
        for (w, alpha) in [(a, 1 - p), (b, p)] where alpha > 0.01 {
            for id in w.sel {
                guard let (r, _) = frame(id), let n = byID[id] else { continue }
                let path: NSBezierPath
                switch n.kind {
                case .root: path = NSBezierPath(ovalIn: r.insetBy(dx: -4, dy: -4))
                case .chat where n.state > 0: let rr = r.insetBy(dx: -2, dy: -2); path = NSBezierPath(roundedRect: rr, xRadius: rr.height / 2, yRadius: rr.height / 2)
                case .topic: path = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8)
                default: path = NSBezierPath(roundedRect: r.insetBy(dx: -4, dy: -3), xRadius: 5, yRadius: 5)
                }
                Theme.pickRing(focused: w.mapFocus).withAlphaComponent((w.mapFocus ? 1 : 0.5) * alpha).setStroke()
                path.lineWidth = 2; path.stroke()
            }
        }
        // a selection box being dragged round items
        if !b.boxAround.isEmpty {
            let rs = b.boxAround.compactMap { fb[$0] }
            if let u = rs.first.map({ rs.dropFirst().reduce($0) { $0.union($1) } }) {
                let box = u.insetBy(dx: -10, dy: -6).offsetBy(dx: 6, dy: 0)
                Theme.ink.withAlphaComponent(0.06 * p).setFill(); box.fill()
                Theme.ink.withAlphaComponent(0.35 * p).setStroke(); let bp = NSBezierPath(rect: box); bp.lineWidth = 1; bp.stroke()
            }
        }
        // the ↗ and ✉ buttons beside a hovered chat
        if let id = b.buttonsFor, let r = fb[id], let n = byID[id] {
            for (i, sym) in ["arrow.up.forward", n.state == 1 ? "envelope.open" : "envelope.badge"].enumerated() {
                let br = buttonRect(r, i)
                let bp = NSBezierPath(roundedRect: br, xRadius: 5, yRadius: 5)
                Theme.paper.setFill(); bp.fill(); Theme.line.setStroke(); bp.lineWidth = 1; bp.stroke()
                if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
                    Keycaps.drawSymbol(img, centredIn: br, Theme.ink)
                }
            }
        }
        // unread dots on top, as on the real map
        for id in ids {
            guard let n = byID[id], n.kind == .chat, n.state == 1, let (r, al) = frame(id) else { continue }
            let c = CGPoint(x: r.maxX - 2, y: r.minY + 2)
            Theme.bg.withAlphaComponent(al).setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).fill()
            Theme.unread.withAlphaComponent(al).setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if b.searchShown { drawSearchField(in: area, b) }
    }

    /// Where a hovered chat's buttons sit (0: ↗, 1: ✉).
    private func buttonRect(_ chat: NSRect, _ i: Int) -> NSRect {
        NSRect(x: chat.maxX + 6 + CGFloat(i) * 24, y: chat.midY - 8.5, width: 20, height: 17)
    }

    private func dimAlpha(_ w: DemoWorld, _ id: String) -> CGFloat {
        guard let keep = w.bright else { return 1 }
        return keep.contains(id) ? 1 : 0.22
    }

    private func drawNode(_ n: DemoNode, _ r: NSRect, alpha: CGFloat, editing: Bool, z: CGFloat) {
        guard alpha > 0.01 else { return }
        let ink = Theme.ink.withAlphaComponent(alpha), muted = Theme.muted.withAlphaComponent(alpha)
        func text(_ s: String, _ f: NSFont, _ c: NSColor, x: CGFloat, midY: CGFloat) {
            let ff = NSFont(descriptor: f.fontDescriptor, size: f.pointSize * z) ?? f
            let h = s.size(withAttributes: [.font: ff]).height
            (s as NSString).draw(at: NSPoint(x: x, y: midY - h / 2), withAttributes: [.font: ff, .foregroundColor: c])
        }
        switch n.kind {
        case .root:
            muted.setFill(); NSBezierPath(ovalIn: r).fill()
        case .topic:
            let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 6 * z, yRadius: 6 * z)
            Theme.paper.withAlphaComponent(alpha).setFill(); shape.fill()
            Theme.line.withAlphaComponent(alpha).setStroke(); shape.lineWidth = 1.5; shape.stroke()
            text(n.title, Self.topicF, ink, x: r.minX + 10 * z, midY: r.midY)
            if n.folded {
                let pill = NSRect(x: r.maxX - 18 * z, y: r.midY - 7 * z, width: 14 * z, height: 14 * z)
                Theme.bg.withAlphaComponent(alpha).setFill(); NSBezierPath(ovalIn: pill).fill()
                Theme.line.withAlphaComponent(alpha).setStroke(); let o = NSBezierPath(ovalIn: pill); o.lineWidth = 1.25; o.stroke()
                text("2", Theme.ui(9, .bold), muted, x: pill.minX + 4 * z, midY: pill.midY)
            }
        case .sub:
            text(n.title, Self.subF, ink, x: r.minX + 2 * z, midY: r.midY - 2 * z)
            Theme.line.withAlphaComponent(alpha).setFill(); NSRect(x: r.minX, y: r.maxY - 1.75, width: r.width, height: 1.75).fill()
        case .chat:
            var tc = ink, mc = muted
            if n.state > 0 {
                let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: r.height / 2, yRadius: r.height / 2)
                if n.state == 1 {
                    Theme.ink.withAlphaComponent(alpha).setFill(); pill.fill()
                    tc = Theme.bg.withAlphaComponent(alpha); mc = Theme.bg.withAlphaComponent(0.75 * alpha)
                } else {
                    // as on the map: an orange stretch going round while it's seen running; out of sight, a dark outline
                    Theme.paper.withAlphaComponent(alpha).setFill(); pill.fill()
                    Theme.ink.withAlphaComponent((n.seen ? 0.35 : 1) * alpha).setStroke(); pill.lineWidth = 1.25; pill.stroke()
                    let b = r.insetBy(dx: 0.75, dy: 0.75)
                    if n.seen { Theme.drawSnake(pill, perimeter: 2 * (b.width - b.height) + .pi * b.height, color: Theme.running.withAlphaComponent(alpha), lineWidth: 1.75) }
                }
            } else {
                Theme.line.withAlphaComponent(alpha).setFill(); NSRect(x: r.minX, y: r.maxY - 1.75, width: r.width, height: 1.75).fill()
            }
            var x = r.minX + (n.state > 0 ? 8 : 1) * z
            let midY = n.state > 0 ? r.midY : r.midY - 2 * z
            if n.app == "code", let t = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 8.5 * z, weight: .semibold)) {
                Keycaps.drawSymbol(t, centredIn: NSRect(x: x, y: midY - 5, width: 12 * z, height: 10), mc)
                x += 14 * z
            }
            let m = mark(n.app == "code" ? "claude" : n.app, mc)
            m.draw(in: NSRect(x: x, y: midY - m.size.height * z / 2, width: m.size.width * z, height: m.size.height * z), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += (m.size.width + 5) * z
            text(n.title, Self.chatF, tc, x: x, midY: midY)
            if let note = n.note {
                text(note, Self.noteF, n.state == 1 ? mc : muted, x: x + (n.title.size(withAttributes: [.font: Self.chatF]).width + 6) * z, midY: midY + 0.5)
            }
            if let c = n.tag {
                let tw = n.title.size(withAttributes: [.font: Self.chatF]).width * z
                if let icon = n.tagIcon { Icons.draw(icon, in: NSRect(x: x + tw + 4 * z, y: midY - 5.5, width: 11, height: 11), color: c.withAlphaComponent(alpha), weight: 2.2) }
                else { c.withAlphaComponent(alpha).setFill(); NSBezierPath(ovalIn: NSRect(x: x + tw + 4 * z, y: midY - 3, width: 6, height: 6)).fill() }
            }
        }
        if editing {
            // the name being typed, with its caret
            let tw: CGFloat = n.title.size(withAttributes: [.font: n.kind == .chat ? Self.chatF : n.kind == .sub ? Self.subF : Self.topicF]).width * z
            let x0 = r.minX + (n.kind == .topic ? 10 : n.kind == .chat ? r.width - tw - 6 : 2) * z
            if Int(clock / 0.53) % 2 == 0 {
                Theme.ink.setFill(); NSRect(x: x0 + tw + 1, y: r.midY - 7, width: 1.25, height: 14).fill()
            }
        }
    }

    private func drawSearchField(in area: NSRect, _ w: DemoWorld) {
        let r = NSRect(x: area.maxX - 150, y: area.minY + 4, width: 142, height: 18)
        let p = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        Theme.paper.setFill(); p.fill(); Theme.line.setStroke(); p.lineWidth = 1; p.stroke()
        if let g = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) {
            Keycaps.drawSymbol(g, centredIn: NSRect(x: r.minX + 4, y: r.minY, width: 12, height: r.height), Theme.muted)
        }
        let t = w.filter.isEmpty ? tr("搜索", "Search") : w.filter
        (t as NSString).draw(at: NSPoint(x: r.minX + 20, y: r.minY + 2), withAttributes: [.font: Theme.ui(10.5), .foregroundColor: w.filter.isEmpty ? Theme.muted : Theme.ink])
    }

    // MARK: the left column

    private func drawList(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        let col = NSRect(x: area.minX, y: area.minY, width: 206, height: area.height)
        Theme.paper.setFill(); NSBezierPath(roundedRect: col, xRadius: 6, yRadius: 6).fill()
        let shown = b.rows.filter { b.filter.isEmpty || $0.title.localizedCaseInsensitiveContains(b.filter) }
        let head = tr("置顶对话", "Pinned")
        let hf = Theme.ui(12, .semibold)
        (head as NSString).draw(at: NSPoint(x: col.minX + 10, y: col.minY + 6), withAttributes: [.font: hf, .foregroundColor: Theme.ink])
        let count = b.filter.isEmpty ? "\(b.rows.count)" : "\(shown.count)/\(b.rows.count)"
        (count as NSString).draw(at: NSPoint(x: col.minX + 16 + head.size(withAttributes: [.font: hf]).width, y: col.minY + 7), withAttributes: [.font: Theme.mono(10.5, .medium), .foregroundColor: Theme.muted])
        if let g = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) {
            NSGraphicsContext.saveGraphicsState()
            let c = CGPoint(x: col.maxX - 14, y: col.minY + 13)
            let t = NSAffineTransform(); t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: -(a.spin + (b.spin - a.spin) * p)); t.translateX(by: -c.x, yBy: -c.y); t.concat()
            Keycaps.drawSymbol(g, centredIn: NSRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12), Theme.muted)
            NSGraphicsContext.restoreGraphicsState()
        }
        let sf = NSRect(x: col.minX + 8, y: col.minY + 23, width: col.width - 16, height: 14)
        let sp = NSBezierPath(roundedRect: sf, xRadius: 4, yRadius: 4)
        Theme.bg.setFill(); sp.fill()
        let st = b.filter.isEmpty ? tr("搜索左栏", "Search the list") : b.filter
        (st as NSString).draw(at: NSPoint(x: sf.minX + 6, y: sf.minY), withAttributes: [.font: Theme.ui(9.5), .foregroundColor: b.filter.isEmpty ? Theme.muted : Theme.ink])
        for (i, row) in shown.enumerated() {
            let r = NSRect(x: col.minX + 8, y: col.minY + 41 + CGFloat(i) * 18, width: col.width - 16, height: 16)
            drawRow(row, r, picked: b.picked.contains(row.id), focus: b.listFocus)
        }
        // the map beside it, so a pick shows on both
        let mapArea = NSRect(x: col.maxX + 8, y: area.minY, width: area.width - col.width - 8, height: area.height)
        var aa = a, bb = b
        aa.zoom *= 0.86; bb.zoom *= 0.86
        drawMap(aa, bb, p, in: mapArea)
    }

    private func drawRow(_ row: DemoRow, _ r: NSRect, picked: Bool, focus: Bool) {
        var ink = Theme.ink, faded = Theme.muted
        if row.state > 0 {
            let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
            if row.state == 1 { Theme.ink.setFill(); pill.fill(); ink = Theme.bg; faded = Theme.bg.withAlphaComponent(0.75) }
            else {
                Theme.paper.setFill(); pill.fill()
                Theme.ink.withAlphaComponent(0.35).setStroke(); pill.lineWidth = 1.25; pill.stroke()
                let b = r.insetBy(dx: 0.5, dy: 0.5)
                Theme.drawSnake(pill, perimeter: 2 * (b.width - b.height) + .pi * b.height, color: Theme.running, lineWidth: 1.75)
            }
        }
        if row.placed { Theme.line.setFill(); NSBezierPath(roundedRect: NSRect(x: r.minX - 5, y: r.minY + 4, width: 2, height: r.height - 8), xRadius: 1, yRadius: 1).fill() }
        if picked {
            let rr = r.insetBy(dx: -2, dy: -2)
            Theme.pickRing(focused: focus).setStroke()
            let ring = NSBezierPath(roundedRect: rr, xRadius: rr.height / 2, yRadius: rr.height / 2); ring.lineWidth = 2; ring.stroke()
        }
        var x = r.minX + 8
        if row.app == "code", let t = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold)) {
            Keycaps.drawSymbol(t, centredIn: NSRect(x: x, y: r.minY, width: 12, height: r.height), faded); x += 14
        }
        let m = mark(row.app == "code" ? "claude" : row.app, faded)
        m.draw(in: NSRect(x: x, y: r.midY - m.size.height / 2, width: m.size.width, height: m.size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        x += m.size.width + 5
        let f = Theme.ui(11, row.state > 0 ? .semibold : .regular)
        (row.title as NSString).draw(at: NSPoint(x: x, y: r.midY - 7), withAttributes: [.font: f, .foregroundColor: ink])
        // its time at the end, as the left column says it
        if let note = row.note {
            let nf = Theme.ui(9.5), w = ceil(note.size(withAttributes: [.font: nf]).width)
            (note as NSString).draw(at: NSPoint(x: r.maxX - 9 - w, y: r.midY - 6), withAttributes: [.font: nf, .foregroundColor: row.state > 0 ? ink : faded])
        }
        if row.state == 1 {
            let c = CGPoint(x: r.maxX - 2, y: r.minY + 2)
            Theme.paper.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).fill()
            Theme.unread.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)).fill()
        }
    }

    // MARK: the timeline

    private func drawTimeline(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        let band = NSRect(x: area.minX, y: area.minY + 6, width: area.width, height: area.height - 12)
        Theme.paper.setFill(); NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
        (tr("时间轴", "Timeline") as NSString).draw(at: NSPoint(x: band.minX + 10, y: band.minY + 6), withAttributes: [.font: Theme.ui(11.5, .semibold), .foregroundColor: Theme.ink])
        // ◎ Now: an orange outline while following now, solid when not
        let follow = b.following
        let nowT = tr("◎ 现在", "◎ Now"), nf = Theme.ui(10, .semibold)
        let nw = nowT.size(withAttributes: [.font: nf]).width + 14
        let nr = NSRect(x: band.maxX - nw - 10, y: band.minY + 5, width: nw, height: 16)
        let np = NSBezierPath(roundedRect: nr, xRadius: 8, yRadius: 8)
        if follow { Theme.running.setStroke(); np.lineWidth = 1.5; np.stroke() } else { Theme.running.setFill(); np.fill() }
        (nowT as NSString).draw(at: NSPoint(x: nr.minX + 7, y: nr.minY + 1.5), withAttributes: [.font: nf, .foregroundColor: follow ? Theme.running : Theme.onColor(Theme.running)])
        let plot = NSRect(x: band.minX + 70, y: band.minY + 30, width: band.width - 84, height: band.height - 44)
        (tr("在跑", "Running") as NSString).draw(at: NSPoint(x: band.minX + 10, y: plot.minY + 6), withAttributes: [.font: Theme.ui(9.5), .foregroundColor: Theme.muted])
        let shift = a.tlShift + (b.tlShift - a.tlShift) * p, scale = a.tlScale + (b.tlScale - a.tlScale) * p
        let nowX = plot.minX + plot.width * 0.62
        func x(_ hours: CGFloat) -> CGFloat { nowX + (hours * 60 + shift) * scale }      // hours from now
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot).addClip()
        for h in stride(from: -6, through: 3, by: 1) {
            Theme.faint.setFill(); NSRect(x: x(CGFloat(h)), y: plot.minY, width: 1, height: plot.height).fill()
        }
        let bars: [(String, CGFloat, CGFloat, Bool)] = [(tr("周报草稿", "Weekly report"), -1.8, -1.15, false),
                                                       (tr("东京机票", "Tokyo flights"), -1.1, -0.5, false),
                                                       (tr("报税问题", "Tax question"), -0.42, 0, true)]
        for (name, s, e, live) in bars {
            let r = NSRect(x: x(s), y: plot.minY + 4, width: max(2, x(e) - x(s)), height: 16)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            let fill = Theme.muted.withAlphaComponent(live ? 1 : 0.55)
            fill.setFill(); path.fill()
            if live { Theme.ink.setStroke(); path.lineWidth = 1; path.stroke() }
            // (black or white, as the real timeline picks it; and kept to its bar as it does: a name longer than its
            // bar is cut 4 pt before its end, not run into the next one)
            if r.width > 46 {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: r.insetBy(dx: 4, dy: 0)).addClip()
                (name as NSString).draw(at: NSPoint(x: r.minX + 5, y: r.minY + 1.5), withAttributes: [.font: Theme.ui(10, .semibold), .foregroundColor: Theme.onColor(fill, over: Theme.paper)])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        Theme.ink.setFill(); NSRect(x: x(0) - 0.75, y: plot.minY - 2, width: 1.5, height: plot.height + 2).fill()
        if let frac = b.tlHover {
            let hx = plot.minX + plot.width * frac
            let path = NSBezierPath(); path.move(to: CGPoint(x: hx, y: plot.minY)); path.line(to: CGPoint(x: hx, y: plot.maxY))
            Theme.ink.withAlphaComponent(0.6).setStroke(); path.setLineDash([3, 2], count: 2, phase: 0); path.lineWidth = 1; path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: the window, the menu bar

    private func drawWindow(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        // another app behind
        let other = NSRect(x: area.minX + 6, y: area.minY + 16, width: 150, height: 96)
        let op = NSBezierPath(roundedRect: other, xRadius: 6, yRadius: 6)
        Theme.paper.setFill(); op.fill(); Theme.line.setStroke(); op.lineWidth = 1; op.stroke()
        (tr("其他 App", "Another app") as NSString).draw(at: NSPoint(x: other.minX + 8, y: other.minY + 5), withAttributes: [.font: Theme.ui(10, .semibold), .foregroundColor: Theme.muted])
        for i in 0..<3 { Theme.faint.setFill(); NSRect(x: other.minX + 8, y: other.minY + 26 + CGFloat(i) * 12, width: other.width - 30 - CGFloat(i) * 12, height: 5).fill() }
        let shown = a.windowShown + (b.windowShown - a.windowShown) * p
        guard shown > 0.01 else { return }
        let wr = NSRect(x: area.minX + 120, y: area.minY + 4, width: area.width - 126, height: area.height - 8)
        let s = 0.96 + 0.04 * shown
        let w = NSRect(x: wr.midX - wr.width * s / 2, y: wr.midY - wr.height * s / 2, width: wr.width * s, height: wr.height * s)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(shown)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18); shadow.shadowBlurRadius = 10; shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
        let wp = NSBezierPath(roundedRect: w, xRadius: 8, yRadius: 8)
        Theme.bg.setFill(); wp.fill()
        NSShadow().set()
        Theme.line.setStroke(); wp.lineWidth = 1; wp.stroke()
        wp.addClip()
        let ui = a.ui + (b.ui - a.ui) * p
        let head = NSRect(x: w.minX, y: w.minY, width: w.width, height: 18 * ui)
        Theme.paper.setFill(); head.fill()
        for i in 0..<3 { Theme.line.setFill(); NSBezierPath(ovalIn: NSRect(x: head.minX + 8 + CGFloat(i) * 10, y: head.midY - 3, width: 6, height: 6)).fill() }
        let side = (a.sideShown + (b.sideShown - a.sideShown) * p) * 96 * ui
        let tlH = (a.tlShown + (b.tlShown - a.tlShown) * p) * 24 * ui
        let col = NSRect(x: w.minX, y: head.maxY, width: side, height: w.maxY - head.maxY - tlH)
        Theme.paper.setFill(); col.fill()
        for i in 0..<5 where side > 20 {
            Theme.faint.setFill(); NSRect(x: col.minX + 8, y: col.minY + 8 + CGFloat(i) * 13 * ui, width: col.width - 20, height: 6 * ui).fill()
        }
        let tl = NSRect(x: w.minX, y: w.maxY - tlH, width: w.width, height: tlH)
        if tlH > 1 {
            Theme.paper.setFill(); tl.fill()
            Theme.muted.withAlphaComponent(0.5).setFill(); NSRect(x: tl.minX + 40, y: tl.midY - 3, width: 60, height: 6 * ui).fill()
            Theme.ink.setFill(); NSRect(x: tl.minX + tl.width * 0.62, y: tl.minY + 2, width: 1.25, height: tl.height - 4).fill()
        }
        let map = NSRect(x: col.maxX, y: head.maxY, width: w.maxX - col.maxX, height: w.maxY - head.maxY - tlH)
        // the map, a little smaller than in the map demos
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: map).addClip()
        var aa = a, bb = b
        aa.zoom = 0.72 * ui; bb.zoom = 0.72 * ui
        drawMap(aa, bb, p, in: map)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawMenuBar(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        let bar = NSRect(x: area.minX, y: area.minY, width: area.width, height: 20)
        Theme.paper.withAlphaComponent(0.92).setFill(); bar.fill()
        for (i, wd) in [22.0, 30.0, 26.0].enumerated() {
            Theme.line.setFill(); NSRect(x: bar.minX + 12 + CGFloat(i) * 40, y: bar.midY - 3, width: wd, height: 6).fill()
        }
        let icon = StatusBar.image(run: 1, unread: 1, phase: Theme.turn(), ink: Theme.ink)
        icon.draw(in: NSRect(x: bar.maxX - 90, y: bar.minY + 1, width: icon.size.width * 18 / max(1, icon.size.height), height: 18),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ("9:41" as NSString).draw(at: NSPoint(x: bar.maxX - 40, y: bar.minY + 3), withAttributes: [.font: Theme.ui(11, .medium), .foregroundColor: Theme.ink])
    }

    // MARK: overlays

    private func drawOverlays(_ w: DemoWorld, _ p: CGFloat) {
        if let m = w.menu { drawMenu(m, at: w.menuAt) }
        if let c = w.card { drawCard(c.title, app: c.app) }
        if let b = w.bubble { drawBubble(b, at: w.bubbleAt) }
        if let box = w.box {
            Theme.ink.withAlphaComponent(0.06).setFill(); box.fill()
            Theme.ink.withAlphaComponent(0.35).setStroke(); let bp = NSBezierPath(rect: box); bp.lineWidth = 1; bp.stroke()
        }
    }

    /// The chat as its app would show it, coming up beside it.
    private func drawCard(_ title: String, app: String) {
        let r = NSRect(x: scene.maxX - 176, y: scene.minY + 18, width: 164, height: 64)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 10; shadow.shadowOffset = NSSize(width: 0, height: -3)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        Theme.paper.setFill(); p.fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.line.setStroke(); p.lineWidth = 1; p.stroke()
        for i in 0..<3 { Theme.line.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 8 + CGFloat(i) * 9, y: r.minY + 7, width: 5, height: 5)).fill() }
        let name = ["gpt": "ChatGPT", "code": "VS Code", "pdf": "PDF", "kikumap": "KIKUmap", "web": tr("浏览器", "Browser")][app] ?? "Claude"
        (name as NSString).draw(at: NSPoint(x: r.minX + 40, y: r.minY + 3), withAttributes: [.font: Theme.ui(10, .semibold), .foregroundColor: Theme.muted])
        (title as NSString).draw(at: NSPoint(x: r.minX + 10, y: r.minY + 22), withAttributes: [.font: Theme.ui(11.5, .semibold), .foregroundColor: Theme.ink])
        Theme.faint.setFill(); NSRect(x: r.minX + 10, y: r.minY + 42, width: 120, height: 5).fill(); NSRect(x: r.minX + 10, y: r.minY + 52, width: 90, height: 5).fill()
    }

    private static let menuFont = Theme.ui(10.5)
    /// A menu's rows, from its top: an item 15 pt, a separator ("—") 7 pt, 4 pt above and below; and its height.
    static func menuRows(_ rows: [String]) -> (tops: [CGFloat], height: CGFloat) {
        var y: CGFloat = 4, tops: [CGFloat] = []
        for row in rows { tops.append(y); y += row == "—" ? 7 : 15 }
        return (tops, y + 4)
    }
    /// Where a menu opened at `pt` is drawn: there, moved in to stay inside the scene (a demo's menu fits in it whole).
    func menuRect(_ rows: [String], at pt: CGPoint) -> NSRect {
        let w = (rows.map { $0.size(withAttributes: [.font: Self.menuFont]).width }.max() ?? 60) + 24
        let h = Self.menuRows(rows).height
        return NSRect(x: min(pt.x, scene.maxX - w - 4), y: max(scene.minY + 2, min(pt.y, scene.maxY - 4 - h)), width: w, height: h)
    }

    private func drawMenu(_ rows: [String], at pt: CGPoint) {
        let f = Self.menuFont
        let r = menuRect(rows, at: pt), w = r.width
        let tops = Self.menuRows(rows).tops
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        Theme.paper.setFill(); p.fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, row) in rows.enumerated() {
            let y = r.minY + tops[i]
            if row == "—" { Theme.faint.setFill(); NSRect(x: r.minX + 8, y: y + 3, width: w - 16, height: 1).fill(); continue }
            (row as NSString).draw(at: NSPoint(x: r.minX + 12, y: y), withAttributes: [.font: f, .foregroundColor: Theme.ink])
        }
    }

    private func drawBubble(_ text: String, at pt: CGPoint) {
        let f = Theme.ui(10.5, .semibold)
        let s = text.size(withAttributes: [.font: f])
        let r = NSRect(x: min(pt.x, scene.maxX - s.width - 16), y: pt.y, width: s.width + 14, height: s.height + 8)
        Theme.ink.setFill(); NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: NSPoint(x: r.minX + 7, y: r.minY + 4), withAttributes: [.font: f, .foregroundColor: Theme.paper])
    }

    // MARK: Settings → Access: another app beside KIKUmap
    // Each demo puts what an item lets KIKUmap read on the left (Claude's window, a banner from Notification Center,
    // a terminal, ChatGPT's window, the menu bar) and what KIKUmap then shows on the right, in its own window, as the
    // real map, left column and drop-down draw it.

    /// The other app's side (left) and KIKUmap's window (right), below `top` points of menu bar.
    private func accessSides(_ area: NSRect, top: CGFloat = 0) -> (app: NSRect, kiku: NSRect) {
        let y = area.minY + top + 3, h = area.height - top - 6
        let app = NSRect(x: area.minX + 2, y: y, width: 188, height: h)
        return (app, NSRect(x: app.maxX + 28, y: y, width: area.maxX - 2 - app.maxX - 28, height: h))
    }

    /// A window as macOS draws one: its frame and shadow, the title bar with its three dots and name; `body` draws what's
    /// in it (clipped to it). All of it faded by `alpha`.
    private func drawAppWindow(_ r: NSRect, title: String, alpha: CGFloat = 1, _ body: (NSRect) -> Void) {
        guard alpha > 0.01 else { return }
        NSGraphicsContext.saveGraphicsState()
        if alpha < 1 { NSGraphicsContext.current?.cgContext.setAlpha(alpha) }
        let shape = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.16); shadow.shadowBlurRadius = 7; shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.set()
        Theme.bg.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let head = NSRect(x: r.minX, y: r.minY, width: r.width, height: 15)
        Theme.paper.setFill(); head.fill()
        Theme.faint.setFill(); NSRect(x: r.minX, y: head.maxY - 1, width: r.width, height: 1).fill()
        for i in 0..<3 { Theme.line.setFill(); NSBezierPath(ovalIn: NSRect(x: head.minX + 7 + CGFloat(i) * 9, y: head.midY - 2.5, width: 5, height: 5)).fill() }
        let f = Theme.ui(9.5, .semibold), tw = ceil(title.size(withAttributes: [.font: f]).width)
        (title as NSString).draw(at: NSPoint(x: max(head.minX + 36, head.midX - tw / 2), y: head.minY + 1.5), withAttributes: [.font: f, .foregroundColor: Theme.muted])
        body(NSRect(x: r.minX, y: head.maxY, width: r.width, height: r.height - head.height))
        NSGraphicsContext.restoreGraphicsState()
        Theme.line.setStroke(); shape.lineWidth = 1; shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// From what KIKUmap reads over to KIKUmap: an arrow in the gap, dark while it reads.
    private func drawReadArrow(from app: NSRect, to kiku: NSRect, at y: CGFloat, strong: Bool) {
        let x0 = app.maxX + 6, x1 = kiku.minX - 6
        let c = Theme.ink.withAlphaComponent(strong ? 0.75 : 0.3)
        let line = NSBezierPath(); line.move(to: CGPoint(x: x0, y: y)); line.line(to: CGPoint(x: x1 - 2, y: y))
        line.lineWidth = 1.5; line.lineCapStyle = .round
        if !strong { line.setLineDash([2, 3], count: 2, phase: 0) }
        c.setStroke(); line.stroke()
        let head = NSBezierPath(); head.move(to: CGPoint(x: x1 - 6, y: y - 4)); head.line(to: CGPoint(x: x1, y: y)); head.line(to: CGPoint(x: x1 - 6, y: y + 4))
        head.lineWidth = 1.5; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()
    }

    /// A spinner, as an app shows a chat at work.
    private func drawSpinner(_ c: CGPoint, radius: CGFloat, _ color: NSColor) {
        let a0 = CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1) * -360
        let p = NSBezierPath(); p.appendArc(withCenter: c, radius: radius, startAngle: a0, endAngle: a0 + 260)
        p.lineWidth = 1.4; p.lineCapStyle = .round
        color.setStroke(); p.stroke()
    }

    /// An app's own chat list (Claude's sidebar, or ChatGPT's Pinned section, a pin before each), under its heading:
    /// each row as that app marks it, a spinner while it runs, a dot when it's done and unread (`dot`: ChatGPT's is
    /// yellow); `outlined`: KIKUmap reads this list off the window (Claude's, with Accessibility).
    private func drawAppList(_ rows: [DemoRow], head: String, in r: NSRect, outlined: Bool, dot: NSColor = Theme.ink) {
        let hf = Theme.ui(8.5, .semibold), rf = Theme.ui(10)
        var y = r.minY + 5
        (head as NSString).draw(at: NSPoint(x: r.minX + 8, y: y), withAttributes: [.font: hf, .foregroundColor: Theme.muted])
        y += 13
        let top = y
        for row in rows {
            let rr = NSRect(x: r.minX + 4, y: y, width: r.width - 8, height: 15)
            if row.state == 2 { Theme.hover.setFill(); NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4).fill() }
            var x = rr.minX + 5
            if row.app == "gpt", let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 7, weight: .semibold)) {
                Keycaps.drawSymbol(pin, centredIn: NSRect(x: x, y: rr.minY, width: 8, height: rr.height), Theme.muted); x += 11
            }
            (row.title as NSString).draw(at: NSPoint(x: x, y: rr.midY - 6.5), withAttributes: [.font: rf, .foregroundColor: Theme.ink])
            let c = CGPoint(x: rr.maxX - 8, y: rr.midY)
            if row.state == 2 { drawSpinner(c, radius: 3.6, Theme.muted) }
            if row.state == 1 { dot.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - 2.75, y: c.y - 2.75, width: 5.5, height: 5.5)).fill() }
            y += 16
        }
        y += 4
        // what KIKUmap reads off the window: the list, outlined
        if outlined, !rows.isEmpty {
            let box = NSRect(x: r.minX + 2, y: top - 2, width: r.width - 4, height: y - 4 - top + 3)
            let o = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            o.lineWidth = 1.25; o.setLineDash([3, 2], count: 2, phase: 0)
            Theme.ink.withAlphaComponent(0.6).setStroke(); o.stroke()
        }
    }

    /// KIKUmap's left column, as SidebarView draws it: "Pinned" and how many, then its rows; one that's new fades in.
    private func drawColumn(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in col: NSRect) {
        Theme.paper.setFill(); col.fill()
        let head = tr("置顶对话", "Pinned"), hf = Theme.ui(10.5, .semibold)
        (head as NSString).draw(at: NSPoint(x: col.minX + 10, y: col.minY + 4), withAttributes: [.font: hf, .foregroundColor: Theme.ink])
        ("\(b.rows.count)" as NSString).draw(at: NSPoint(x: col.minX + 16 + head.size(withAttributes: [.font: hf]).width, y: col.minY + 5),
                                             withAttributes: [.font: Theme.mono(9.5, .medium), .foregroundColor: Theme.muted])
        for (i, row) in b.rows.enumerated() {
            let r = NSRect(x: col.minX + 12, y: col.minY + 22 + CGFloat(i) * 19, width: col.width - 22, height: 16)
            let fresh = !a.rows.contains { $0.id == row.id }
            NSGraphicsContext.saveGraphicsState()
            if fresh && p < 1 { NSGraphicsContext.current?.cgContext.setAlpha(p) }
            drawRow(row, r, picked: false, focus: false)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The menu bar along the top: what other apps keep there, KIKUmap's icon (as StatusBar.image draws it), the time.
    private func menuStrip(_ area: NSRect) -> NSRect { NSRect(x: area.minX, y: area.minY, width: area.width, height: 16) }
    /// Where KIKUmap's icon sits in it.
    private func kikuIcon(_ w: DemoWorld, in strip: NSRect) -> NSRect {
        let img = StatusBar.image(run: w.icon.run, unread: w.icon.unread, needs: w.icon.needs)
        let h: CGFloat = 15, wd = img.size.width * h / max(1, img.size.height)
        return NSRect(x: strip.maxX - 48 - wd, y: strip.minY + 0.5, width: wd, height: h)
    }
    private func drawMenuStrip(_ w: DemoWorld, in area: NSRect) {
        let bar = menuStrip(area)
        Theme.paper.withAlphaComponent(0.92).setFill(); NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
        for (i, wd) in [18.0, 26.0, 22.0, 30.0].enumerated() {
            Theme.line.setFill(); NSRect(x: bar.minX + 10 + CGFloat(i) * 36, y: bar.midY - 2.5, width: wd, height: 5).fill()
        }
        let img = StatusBar.image(run: w.icon.run, unread: w.icon.unread, needs: w.icon.needs, phase: w.icon.run > 0 && w.icon.seen ? Theme.turn() : nil,
                                  ink: Theme.ink, unsure: !w.icon.seen)
        img.draw(in: kikuIcon(w, in: bar), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ("9:41" as NSString).draw(at: NSPoint(x: bar.maxX - 34, y: bar.minY + 1.5), withAttributes: [.font: Theme.ui(9.5, .medium), .foregroundColor: Theme.ink])
    }

    /// Accessibility: the Claude app's chat list beside KIKUmap's map; a chat Claude works on runs on the map, then
    /// waits there unread.
    private func drawClaudeApp(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        let (app, kiku) = accessSides(area)
        drawAppWindow(app, title: "Claude") { body in
            let side = NSRect(x: body.minX, y: body.minY, width: body.width * 0.66, height: body.height)
            Theme.paper.setFill(); side.fill()
            for i in 0..<4 { Theme.faint.setFill(); NSRect(x: side.maxX + 8, y: body.minY + 12 + CGFloat(i) * 11, width: body.maxX - side.maxX - 16 - CGFloat(i % 2) * 10, height: 4).fill() }
            drawAppList(b.appRows, head: tr("置顶", "Pinned"), in: side, outlined: b.reads)
        }
        drawReadArrow(from: app, to: kiku, at: app.midY + 6, strong: b.reads)
        drawAppWindow(kiku, title: "KIKUmap") { body in drawMap(a, b, p, in: body.insetBy(dx: 2, dy: 2)) }
    }

    /// Full Disk Access: Claude's window closed, a banner from Notification Center, the chat waiting for you on the
    /// map and the "!" on KIKUmap's icon.
    private func drawNotice(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        drawMenuStrip(b, in: area)
        let (app, kiku) = accessSides(area, top: 17)
        let shown = a.appShown + (b.appShown - a.appShown) * p
        if shown > 0.01 {
            let s = 0.94 + 0.06 * shown
            let r = NSRect(x: app.midX - app.width * s / 2, y: app.minY + 6 + (1 - s) * 30, width: app.width * s, height: (app.height - 6) * s)
            drawAppWindow(r, title: "Claude", alpha: shown) { body in
                Theme.paper.setFill(); NSRect(x: body.minX, y: body.minY, width: body.width * 0.62, height: body.height).fill()
                for i in 0..<4 { Theme.faint.setFill(); NSRect(x: body.minX + 8, y: body.minY + 10 + CGFloat(i) * 12, width: body.width * 0.62 - 20 - CGFloat(i % 2) * 14, height: 5).fill() }
            }
        }
        // the banner slides in at the top right, as macOS shows one
        let slide = a.banner == nil && b.banner != nil ? p : 1
        if let n = b.banner {
            let bf = Theme.ui(9.5), textW: CGFloat = 186 - 9 - 37
            let bh = min(26, ceil((n.body as NSString).boundingRect(with: NSSize(width: textW, height: 100), options: .usesLineFragmentOrigin, attributes: [.font: bf]).height))
            let r = NSRect(x: app.maxX - 186 + (1 - slide) * 24, y: app.minY + 2, width: 186, height: 31 + bh + 5)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(slide)
            let shape = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.set()
            Theme.paper.setFill(); shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            Theme.line.setStroke(); shape.lineWidth = 1; shape.stroke()
            let icon = NSRect(x: r.minX + 8, y: (r.midY - 11).rounded(), width: 22, height: 22)
            Theme.ink.setFill(); NSBezierPath(roundedRect: icon, xRadius: 5, yRadius: 5).fill()
            if let g = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                Keycaps.drawSymbol(g, centredIn: icon, Theme.bg)
            }
            let x = icon.maxX + 7, tf = Theme.ui(9.5, .semibold)
            ("Claude" as NSString).draw(at: NSPoint(x: x, y: r.minY + 4), withAttributes: [.font: Theme.ui(8.5, .medium), .foregroundColor: Theme.muted])
            let now = tr("现在", "now"), nw = ceil(now.size(withAttributes: [.font: Theme.ui(8.5)]).width)
            (now as NSString).draw(at: NSPoint(x: r.maxX - 9 - nw, y: r.minY + 4), withAttributes: [.font: Theme.ui(8.5), .foregroundColor: Theme.muted])
            (n.title as NSString).draw(at: NSPoint(x: x, y: r.minY + 15), withAttributes: [.font: tf, .foregroundColor: Theme.ink])
            (n.body as NSString).draw(with: NSRect(x: x, y: r.minY + 27, width: r.maxX - 9 - x, height: bh + 1), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: [.font: bf, .foregroundColor: Theme.ink])
            NSGraphicsContext.restoreGraphicsState()
        }
        // (KIKUmap reads the banner: no arrow before there's one)
        if b.reads { drawReadArrow(from: app, to: kiku, at: app.minY + 24, strong: true) }
        drawAppWindow(kiku, title: "KIKUmap") { body in drawMap(a, b, p, in: body.insetBy(dx: 2, dy: 2)) }
    }

    /// Claude Code: a session at work in a terminal, and KIKUmap's left column with it, running, then unread.
    private func drawTerminal(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        let (app, kiku) = accessSides(area)
        drawAppWindow(app, title: "kikumap — claude") { body in
            let f = Theme.mono(9, .regular)
            for (i, line) in b.term.enumerated() {
                let fresh = i >= a.term.count
                // its "working" line orange while it's the last, gray once something came after it
                let ink = line.hasPrefix("✻") ? (i == b.term.count - 1 ? Theme.running : Theme.muted) : Theme.ink
                (line as NSString).draw(with: NSRect(x: body.minX + 8, y: body.minY + 6 + CGFloat(i) * 14, width: body.width - 14, height: 13),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                        attributes: [.font: f, .foregroundColor: ink.withAlphaComponent(fresh ? p : 1)])
            }
        }
        drawReadArrow(from: app, to: kiku, at: app.midY + 6, strong: b.reads)
        drawAppWindow(kiku, title: "KIKUmap") { body in drawColumn(a, b, p, in: body) }
    }

    /// ChatGPT: the ChatGPT app's window with the chats pinned there (one a Codex chat), and KIKUmap's left column with
    /// both, marked GPT. Its files in ~/.codex are what's read, not its window: no outline on its list.
    private func drawChatGPTApp(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        let (app, kiku) = accessSides(area)
        drawAppWindow(app, title: "ChatGPT") { body in
            let side = NSRect(x: body.minX, y: body.minY, width: body.width * 0.7, height: body.height)
            Theme.paper.setFill(); side.fill()
            for i in 0..<4 { Theme.faint.setFill(); NSRect(x: side.maxX + 8, y: body.minY + 12 + CGFloat(i) * 11, width: body.maxX - side.maxX - 16 - CGFloat(i % 2) * 8, height: 4).fill() }
            // (its unread dot yellow, as ChatGPT's sidebar shows it: GPTSidebar)
            drawAppList(b.appRows, head: tr("置顶", "Pinned"), in: side, outlined: false, dot: .systemYellow)
        }
        drawReadArrow(from: app, to: kiku, at: app.midY + 6, strong: b.reads)
        drawAppWindow(kiku, title: "KIKUmap") { body in drawColumn(a, b, p, in: body) }
    }

    /// Usage: KIKUmap's drop-down from the menu bar, its usage lines laid out as UsageMenuView lays them out (a bar,
    /// how much is used, when it resets); Claude's off: the item that turns it on, in their place.
    private func drawUsageMenu(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        drawMenuStrip(b, in: area)
        guard b.menuOpen else { return }
        let icon = kikuIcon(b, in: menuStrip(area))
        let rows = b.usage, old = a.usage
        let offItem = tr("显示 Claude 的用量和计划任务（付费套餐）…", "Show Claude's usage and scheduled tasks (paid plans)…")
        let w = min(area.width - 4, max(268, ceil(offItem.size(withAttributes: [.font: Theme.ui(10)]).width) + 26))     // (one width all through)
        let h: CGFloat = 8 + 11 + 8 + 14 + (rows.isEmpty ? 16 : CGFloat(rows.count) * 28) + 4
        let r = NSRect(x: min(icon.minX - 6, area.maxX - w - 2), y: area.minY + 18, width: w, height: min(h, area.height - 19))
        let opening = !a.menuOpen ? p : 1
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(opening)
        let shape = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -2); shadow.set()
        Theme.paper.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        Theme.line.setStroke(); shape.lineWidth = 1; shape.stroke()
        // the rest of the menu above, in short
        Theme.faint.setFill(); NSRect(x: r.minX + 12, y: r.minY + 9, width: 90, height: 5).fill(); NSRect(x: r.minX + 110, y: r.minY + 9, width: 50, height: 5).fill()
        Theme.faint.setFill(); NSRect(x: r.minX + 8, y: r.minY + 22, width: r.width - 16, height: 1).fill()
        var y = r.minY + 27
        (b.usageHead as NSString).draw(at: NSPoint(x: r.minX + 12, y: y), withAttributes: [.font: Theme.ui(9, .semibold), .foregroundColor: Theme.muted])
        y += 14
        if rows.isEmpty {
            (offItem as NSString).draw(at: NSPoint(x: r.minX + 12, y: y), withAttributes: [.font: Theme.ui(10), .foregroundColor: Theme.ink])
        }
        let titleF = Theme.ui(10, .medium), subF = Theme.ui(8.5), pctF = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let bx = r.minX + 12 + ceil(rows.map { $0.title.size(withAttributes: [.font: titleF]).width }.max() ?? 0) + 10
        for (i, row) in rows.enumerated() {
            // a line that's new fades in; one that was there moves to its new numbers
            let before = old.first { $0.title == row.title }
            let al: CGFloat = old.isEmpty ? p : 1
            let pct = row.percent.map { v in before?.percent.map { $0 + (v - $0) * Double(p) } ?? v }
            let ry = y + CGFloat(i) * 28
            NSGraphicsContext.saveGraphicsState()
            if al < 1 { NSGraphicsContext.current?.cgContext.setAlpha(al * opening) }
            (row.title as NSString).draw(at: NSPoint(x: r.minX + 12, y: ry), withAttributes: [.font: titleF, .foregroundColor: Theme.ink])
            let subText = p < 0.5 && before != nil ? before!.sub : row.sub
            (subText as NSString).draw(at: NSPoint(x: r.minX + 12, y: ry + 13), withAttributes: [.font: subF, .foregroundColor: Theme.muted])
            let pctText = pct.map { "\(Int($0.rounded()))%" + tr(" 已用", " used") } ?? "—"
            let pw = ceil(pctText.size(withAttributes: [.font: pctF]).width)
            (pctText as NSString).draw(at: NSPoint(x: r.maxX - 10 - pw, y: ry + 4), withAttributes: [.font: pctF, .foregroundColor: Theme.muted])
            let track = NSRect(x: bx, y: ry + 7, width: max(20, r.maxX - 14 - 54 - bx), height: 4)
            Theme.ink.withAlphaComponent(0.13).setFill(); NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            if let v = pct {
                Theme.ink.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(4, track.width * CGFloat(min(max(v, 0), 100) / 100)), height: 4), xRadius: 2, yRadius: 2).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// What's happening, in a few words on a pill under an Access demo; the last words fade into the next.
    private func drawCaption(_ from: String?, _ to: String?, _ p: CGFloat) {
        let f = Theme.ui(11, .medium)
        func pill(_ s: String, _ alpha: CGFloat) {
            guard alpha > 0.01 else { return }
            let ts = s.size(withAttributes: [.font: f])
            let r = NSRect(x: ((bounds.width - ts.width) / 2 - 11).rounded(), y: (scene.maxY + (bounds.height - scene.maxY - 21) / 2).rounded(),
                           width: ceil(ts.width) + 22, height: 21)
            let shape = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            Theme.paper.withAlphaComponent(alpha).setFill(); shape.fill()
            Theme.line.withAlphaComponent(alpha).setStroke(); shape.lineWidth = 1; shape.stroke()
            (s as NSString).draw(at: NSPoint(x: r.minX + 11, y: r.midY - ts.height / 2), withAttributes: [.font: f, .foregroundColor: Theme.ink.withAlphaComponent(alpha)])
        }
        if from != to, let a = from { pill(a, 1 - p) }
        if let b = to { pill(b, from == to ? 1 : p) }
    }
    /// The caption's words fit in one line under the picture (for the checks).
    func captionFits(_ s: String) -> Bool { s.size(withAttributes: [.font: Theme.ui(11, .medium)]).width + 22 <= bounds.width - 16 }
}
