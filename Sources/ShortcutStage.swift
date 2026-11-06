import Cocoa

// The stage on Settings → Shortcuts: a sample map, list, timeline and window, drawn in code and acted on step by step
// (keys going down in big caps, the pointer moving and clicking), so each shortcut shows where it works and what it
// does. It mirrors what KIKUmap really does (MapView, SidebarView, TimelineView, the menus); the sample is marked
// "Example" so its chats are never taken for yours.

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
}

/// A row of the sample left column.
struct DemoRow {
    var id: String
    var title: String
    var state = 0
    var app = "claude"
    var placed = true
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
}

/// One step: keys going down (the HUD shows them; `lights`: the playing row's keys light up too), letters typed into
/// the name being edited, the pointer gliding somewhere and clicking; then what changes.
struct DemoStep {
    var keys: [KeyPart]? = nil
    var lights = true
    var type: String? = nil
    /// Where the pointer glides first: an item's id, "r:" and a row's id, or "empty", "icon", "lanes", "bar",
    /// "search", "refresh" (the stage finds the spot).
    var pointAt: String? = nil
    var clicks = 0
    var right = false
    var hold: Double = 0.22
    var dur: Double = 1.05
    var change: ((inout DemoWorld) -> Void)? = nil
}

/// Which part of KIKUmap a demo happens in (the small window glyph at the top left fills it in).
enum DemoPart { case desktop, menuBar, window, map, list, tags, timeline }

/// What the stage draws for a demo.
enum DemoView { case map, list, timeline, window, menuBar }

struct DemoSlice {
    var whereText: String
    var part: DemoPart
    var view: DemoView
    var setup: DemoWorld
    var steps: [DemoStep]
}

final class ShortcutStage: NSView {
    /// The demo playing (nil: none yet).
    private(set) var slice: DemoSlice?
    /// The keys going down right now (nil: none), so the legend row lights just those.
    var onLit: (([KeyPart]?) -> Void)?
    /// A pass ended (after its rest).
    var onPassEnded: (() -> Void)?
    /// Clicked: pause or go on.
    private(set) var paused = false
    /// Held while the pointer is over the stage: the demo loops instead of moving on.
    private(set) var holding = false

    private var world = DemoWorld() { didSet { version += 1 } }
    private var from: DemoWorld?
    /// Goes up with every change to the world: layouts are worked out once per change, not every frame.
    private var version = 0
    private var layoutCache: [String: [String: NSRect]] = [:]
    /// A still (Reduce Motion): drawn once, nothing runs.
    private var still = false
    /// The ticking timer is fast (60 Hz) while something moves, else at the running-ring rate.
    private var fast = true
    private var tweenStart: TimeInterval = 0
    private let tweenDur = 0.32
    private var step = -1
    private var stepStart: TimeInterval = 0
    private var restStart: TimeInterval?
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
    /// The stage's own time: it only goes on while the timer runs, so a demo picks up where it was left (a tab
    /// switch, Settings hidden or covered, a pause) instead of jumping ahead.
    private var clock: TimeInterval = 0
    private var lastTick: TimeInterval?
    private static var lessMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        toolTip = tr("点一下暂停", "Click to pause")
        // Reduce Motion turned on or off while it shows: the demo again, as a still or moving
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func motionChanged() { if let s = slice { play(s) } }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Plays a demo from its start.
    func play(_ s: DemoSlice) {
        slice = s
        world = s.setup
        from = nil
        step = -1
        restStart = nil
        typed = nil
        hud = nil
        pointer = nil
        ripple = nil
        setLit(nil)
        setAccessibilityLabel(s.whereText)
        still = Self.lessMotion
        if still {
            // a still: what the row's first own keys do (and the typing after them), with those keys shown down
            let first = s.steps.firstIndex { $0.keys != nil && $0.lights } ?? s.steps.indices.last ?? 0
            for (i, st) in s.steps.enumerated() {
                if i > first && st.keys != nil { break }
                st.change?(&world)
                if let t = st.type, let e = world.editing { rename(e, t) }
            }
            world.editing = nil
            if s.steps.indices.contains(first) { hud = s.steps[first].keys }
            hudLit = true
        }
        stepStart = clock
        updateTimer()
        needsDisplay = true
    }

    private func setLit(_ parts: [KeyPart]?) {
        guard (parts != nil) != keysDown else { return }
        keysDown = parts != nil
        onLit?(parts)
    }

    private func rename(_ id: String, _ t: String) {
        if let i = world.nodes.firstIndex(where: { $0.id == id }) { world.nodes[i].title = t }
    }

    override func mouseDown(with e: NSEvent) { togglePause() }
    /// Paused, its clock stands still (it goes on where it was).
    func togglePause() {
        paused.toggle()
        toolTip = paused ? tr("点一下继续", "Click to go on") : tr("点一下暂停", "Click to pause")
        setAccessibilityValue(paused ? tr("已暂停", "Paused") : nil)
        updateTimer()
        needsDisplay = true
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 49 { togglePause() } else { super.keyDown(with: e) } }
    override func accessibilityPerformPress() -> Bool { togglePause(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { holding = true }
    override func mouseExited(with e: NSEvent) { holding = false }

    // MARK: running

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let nc = NotificationCenter.default
        let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        for n in names { nc.removeObserver(self, name: n, object: nil) }
        if let w = window { for n in names { nc.addObserver(self, selector: #selector(windowChanged), name: n, object: w) } }
        updateTimer()
    }
    @objc private func windowChanged() { updateTimer() }

    /// The timer runs only while Settings is the window you're using (in front, not covered), a demo plays, it
    /// isn't paused and motion isn't reduced: 60 times a second while something moves, else at the running ring's rate.
    private func updateTimer() {
        let w = window
        let visible = w?.isVisible == true && w?.occlusionState.contains(.visible) == true && w?.isKeyWindow == true
        let run = visible && !paused && slice != nil && !Self.lessMotion && !still
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

    /// Fast while something moves (a tween, the pointer, typing, a click, keys going down), slow otherwise.
    private func pace(_ moving: Bool) {
        guard moving != fast else { return }
        fast = moving
        timer?.invalidate(); timer = nil
        updateTimer()
    }

    private func tick() {
        guard let s = slice, !still, !Self.lessMotion else { updateTimer(); return }
        let real = ProcessInfo.processInfo.systemUptime
        if let l = lastTick { clock += min(real - l, 0.1) }
        lastTick = real
        let now = clock
        if let r = restStart {
            if now - r > 1.3 {
                restStart = nil
                if holding { play(s) } else { onPassEnded?() }
            }
            pace(false)
            needsDisplay = true
            return
        }
        if step < 0 { step = 0; stepStart = now; begin(s.steps.first) }
        guard step < s.steps.count else { finishPass(); return }
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
            if step < s.steps.count { begin(s.steps[step]) } else { finishPass() }
        }
        needsDisplay = true
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
        if let k = st.pointAt, let p = spot(k) { pointerFrom = pointer ?? CGPoint(x: p.x + 60, y: p.y + 50); pointerTo = p; pointer = pointerFrom }
        else { pointerFrom = nil; pointerTo = nil }
    }

    private func finishPass() {
        setLit(nil)
        hudLit = false
        hud = nil                       // the rest shows the hint instead
        restStart = clock
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
        case "menu1": return CGPoint(x: w.menuAt.x + 30, y: w.menuAt.y + 4 + 15 * 3 + 7)
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

    private var scene: NSRect { NSRect(x: 12, y: 28, width: bounds.width - 24, height: 132) }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.bg.setFill(); card.fill()
        NSColor.separatorColor.setStroke(); card.lineWidth = 1; card.stroke()
        guard let s = slice else { return }
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
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawWhere(_ s: DemoSlice) {
        drawLocator(s.part, in: NSRect(x: 12, y: 6, width: 26, height: 17))
        let f = Theme.ui(11.5, .semibold)
        (s.whereText as NSString).draw(at: NSPoint(x: 46, y: 7), withAttributes: [.font: f, .foregroundColor: Theme.muted])
        let ex = tr("示例", "Example") + (paused ? tr(" · 已暂停", " · paused") : "")
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
        guard let parts = hud else {
            if restStart != nil {
                let t = tr("悬停下面的一行来看它 · 点画面暂停", "Hover a row below to watch it · click here to pause")
                let f = Theme.ui(11)
                let w = t.size(withAttributes: [.font: f]).width
                (t as NSString).draw(at: NSPoint(x: (bounds.width - w) / 2, y: bounds.height - 34), withAttributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor])
            }
            return
        }
        let w = Keycaps.width(parts, .large)
        Keycaps.draw(parts, at: NSPoint(x: (bounds.width - w) / 2, y: bounds.height - 44), .large, lit: hudLit)
    }

    private func drawPointer(_ p: CGPoint) {
        let img = NSCursor.arrow.image
        let hs = NSCursor.arrow.hotSpot
        let s = img.size
        img.draw(in: NSRect(x: p.x - hs.x * 0.85, y: p.y - hs.y * 0.85, width: s.width * 0.85, height: s.height * 0.85),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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
            return NSSize(width: w + (n.state > 0 ? 16 : 2) + (n.tag != nil ? (n.tagIcon != nil ? 15 : 9) : 0), height: n.state > 0 ? 20 : 18)
        }
    }

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
        let z = b.zoom
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
            NSColor.systemRed.withAlphaComponent(al).setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)).fill()
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
                    Theme.paper.withAlphaComponent(alpha).setFill(); pill.fill()
                    Theme.ink.withAlphaComponent(0.35 * alpha).setStroke(); pill.lineWidth = 1.25; pill.stroke()
                    let b = r.insetBy(dx: 0.75, dy: 0.75)
                    Theme.drawSnake(pill, perimeter: 2 * (b.width - b.height) + .pi * b.height, color: Logo.orange.withAlphaComponent(alpha), lineWidth: 1.75)
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
        let st = b.filter.isEmpty ? tr("搜索置顶对话", "Search pinned chats") : b.filter
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
                Theme.drawSnake(pill, perimeter: 2 * (b.width - b.height) + .pi * b.height, color: Logo.orange, lineWidth: 1.75)
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
        if row.state == 1 {
            let c = CGPoint(x: r.maxX - 2, y: r.minY + 2)
            Theme.paper.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).fill()
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)).fill()
        }
    }

    // MARK: the timeline

    private func drawTimeline(_ a: DemoWorld, _ b: DemoWorld, _ p: CGFloat, in area: NSRect) {
        let band = NSRect(x: area.minX, y: area.minY + 6, width: area.width, height: area.height - 12)
        Theme.paper.setFill(); NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
        (tr("时间线", "Timeline") as NSString).draw(at: NSPoint(x: band.minX + 10, y: band.minY + 6), withAttributes: [.font: Theme.ui(11.5, .semibold), .foregroundColor: Theme.ink])
        // ◎ Now: an orange outline while following now, solid when not
        let follow = b.following
        let nowT = tr("◎ 现在", "◎ Now"), nf = Theme.ui(10, .semibold)
        let nw = nowT.size(withAttributes: [.font: nf]).width + 14
        let nr = NSRect(x: band.maxX - nw - 10, y: band.minY + 5, width: nw, height: 16)
        let np = NSBezierPath(roundedRect: nr, xRadius: 8, yRadius: 8)
        if follow { Logo.orange.setStroke(); np.lineWidth = 1.5; np.stroke() } else { Logo.orange.setFill(); np.fill() }
        (nowT as NSString).draw(at: NSPoint(x: nr.minX + 7, y: nr.minY + 1.5), withAttributes: [.font: nf, .foregroundColor: follow ? Logo.orange : NSColor.white])
        let plot = NSRect(x: band.minX + 70, y: band.minY + 30, width: band.width - 84, height: band.height - 44)
        (tr("进行中", "Running") as NSString).draw(at: NSPoint(x: band.minX + 10, y: plot.minY + 6), withAttributes: [.font: Theme.ui(9.5), .foregroundColor: Theme.muted])
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
            Theme.muted.withAlphaComponent(live ? 1 : 0.55).setFill(); path.fill()
            if live { Theme.ink.setStroke(); path.lineWidth = 1; path.stroke() }
            if r.width > 46 { (name as NSString).draw(at: NSPoint(x: r.minX + 5, y: r.minY + 1.5), withAttributes: [.font: Theme.ui(10, .semibold), .foregroundColor: NSColor.white]) }
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

    private func drawMenu(_ rows: [String], at pt: CGPoint) {
        let f = Theme.ui(10.5)
        let w = (rows.map { $0.size(withAttributes: [.font: f]).width }.max() ?? 60) + 24
        let h = CGFloat(rows.count) * 15 + 8
        let r = NSRect(x: min(pt.x, scene.maxX - w - 4), y: max(scene.minY + 2, min(pt.y, scene.maxY - 4 - h)), width: w, height: h)
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.2); shadow.shadowBlurRadius = 8; shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        Theme.paper.setFill(); p.fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, row) in rows.enumerated() {
            let y = r.minY + 4 + CGFloat(i) * 15
            if row == "—" { Theme.faint.setFill(); NSRect(x: r.minX + 8, y: y + 7, width: w - 16, height: 1).fill(); continue }
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
}
