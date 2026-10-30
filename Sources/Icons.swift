import Cocoa

/// Line icons (Lucide, see LucideIcons.swift): SVG path data turned into a path on their 24×24 grid, drawn with a stroke.
@MainActor
enum Icons {
    private static var cache: [String: NSBezierPath] = [:]

    static func exists(_ name: String) -> Bool { LucideData.paths[name] != nil }

    /// The icon on its 24×24 grid, y down.
    static func path(_ name: String) -> NSBezierPath? {
        if let p = cache[name] { return p }
        guard let d = LucideData.paths[name] else { return nil }
        let p = parse(d)
        cache[name] = p
        return p
    }

    /// Draws it in `r` (a square is best), in either kind of view.
    static func draw(_ name: String, in r: NSRect, color: NSColor, weight: CGFloat = 2) {
        guard let base = path(name) else { return }
        let side = min(r.width, r.height), s = side / 24
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        var t = AffineTransform(translationByX: r.midX - side / 2, byY: flipped ? r.midY - side / 2 : r.midY + side / 2)
        t.scale(x: s, y: flipped ? s : -s)
        let p = base.copy() as! NSBezierPath
        p.transform(using: t)
        p.lineWidth = max(1, weight * s)
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        color.setStroke()
        p.stroke()
    }

    /// As a picture, for menus and buttons (`color` nil: a template that takes the menu's colour).
    static func image(_ name: String, size: CGFloat = 14, color: NSColor? = nil) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            draw(name, in: r, color: color ?? .black); return true
        }
        img.isTemplate = color == nil
        return img
    }

    // MARK: SVG path data

    private static func parse(_ d: String) -> NSBezierPath {
        let p = NSBezierPath()
        let chars = Array(d.utf8)
        var i = 0
        func skip() { while i < chars.count, chars[i] == 32 || chars[i] == 44 || chars[i] == 10 { i += 1 } }
        func number() -> CGFloat {
            skip()
            let from = i
            if i < chars.count, chars[i] == 45 || chars[i] == 43 { i += 1 }
            var dot = false
            while i < chars.count {
                let c = chars[i]
                if c >= 48 && c <= 57 { i += 1 }
                else if c == 46 && !dot { dot = true; i += 1 }
                else if (c == 101 || c == 69), i + 1 < chars.count { i += 1; if chars[i] == 45 || chars[i] == 43 { i += 1 } }
                else { break }
            }
            return CGFloat(Double(String(decoding: chars[from..<i], as: UTF8.self)) ?? 0)
        }
        /// An arc's flag: one digit, which may touch the next number.
        func flag() -> Bool { skip(); defer { i += 1 }; return i < chars.count && chars[i] == 49 }
        func more() -> Bool {
            skip()
            guard i < chars.count else { return false }
            let c = chars[i]
            return (c >= 48 && c <= 57) || c == 45 || c == 46 || c == 43
        }
        var cur = NSPoint.zero, start = NSPoint.zero, lastC: NSPoint?, lastQ: NSPoint?
        var cmd: UInt8 = 0
        while true {
            skip()
            guard i < chars.count else { break }
            if !more() { cmd = chars[i]; i += 1 }
            let rel = cmd >= 97
            let base = rel ? cur : .zero
            func pt() -> NSPoint { let x = number(), y = number(); return NSPoint(x: base.x + x, y: base.y + y) }
            var keepC = false, keepQ = false
            switch cmd | 32 {
            case 109:  // m
                cur = pt(); start = cur; p.move(to: cur)
                cmd = rel ? 108 : 76                       // further pairs are lines
            case 108: cur = pt(); p.line(to: cur)
            case 104: let x = number(); cur.x = rel ? cur.x + x : x; p.line(to: cur)
            case 118: let y = number(); cur.y = rel ? cur.y + y : y; p.line(to: cur)
            case 99:
                let c1 = pt(), c2 = pt(), e = pt()
                p.curve(to: e, controlPoint1: c1, controlPoint2: c2); cur = e; lastC = c2; keepC = true
            case 115:
                let c1 = lastC.map { NSPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(), e = pt()
                p.curve(to: e, controlPoint1: c1, controlPoint2: c2); cur = e; lastC = c2; keepC = true
            case 113:
                let q = pt(), e = pt()
                quad(p, cur, q, e); cur = e; lastQ = q; keepQ = true
            case 116:
                let q = lastQ.map { NSPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let e = pt()
                quad(p, cur, q, e); cur = e; lastQ = q; keepQ = true
            case 97:
                let rx = number(), ry = number(), rot = number(), large = flag(), sweep = flag()
                let e = pt()
                arc(p, from: cur, to: e, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep); cur = e
            case 122:
                p.close(); cur = start
            case 124:                                      // "|": the next SVG element, counted from the origin again
                cur = .zero; start = .zero
            default:
                return p                                   // not path data
            }
            if !keepC { lastC = nil }
            if !keepQ { lastQ = nil }
        }
        return p
    }

    private static func quad(_ p: NSBezierPath, _ a: NSPoint, _ q: NSPoint, _ e: NSPoint) {
        p.curve(to: e, controlPoint1: NSPoint(x: a.x + 2 / 3 * (q.x - a.x), y: a.y + 2 / 3 * (q.y - a.y)),
                controlPoint2: NSPoint(x: e.x + 2 / 3 * (q.x - e.x), y: e.y + 2 / 3 * (q.y - e.y)))
    }

    /// An SVG arc as Bézier curves (SVG spec, appendix F.6).
    private static func arc(_ p: NSBezierPath, from a: NSPoint, to b: NSPoint, rx rx0: CGFloat, ry ry0: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 || a == b { p.line(to: b); return }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (a.x - b.x) / 2, dy = (a.y - b.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let l = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if l > 1 { rx *= sqrt(l); ry *= sqrt(l) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let co = (large == sweep ? -1 : 1) * sqrt(max(0, num / den))
        let cx1 = co * rx * y1 / ry, cy1 = -co * ry * x1 / rx
        let cx = cp * cx1 - sp * cy1 + (a.x + b.x) / 2, cy = sp * cx1 + cp * cy1 + (a.y + b.y) / 2
        let t1 = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
        var dt = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - t1
        if sweep && dt < 0 { dt += 2 * .pi } else if !sweep && dt > 0 { dt -= 2 * .pi }
        let n = max(1, Int(ceil(abs(dt) / (.pi / 2) - 0.0001)))
        let step = dt / CGFloat(n), k = 4 / 3 * tan(step / 4)
        var t = t1
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: cx + cp * x - sp * y, y: cy + sp * x + cp * y) }
        for i in 0..<n {
            let e = t + step
            let c1 = at(rx * (cos(t) - k * sin(t)), ry * (sin(t) + k * cos(t)))
            let c2 = at(rx * (cos(e) + k * sin(e)), ry * (sin(e) - k * cos(e)))
            p.curve(to: i == n - 1 ? b : at(rx * cos(e), ry * sin(e)), controlPoint1: c1, controlPoint2: c2)
            t = e
        }
    }
}

/// The grid in a popover.
@MainActor
enum IconPicker {
    private static var open: NSPopover?

    /// `clear`: a line under the grid to go without one (its title, and what it does).
    static func show(relativeTo rect: NSRect, of view: NSView, selected: String?, tint: NSColor, clear: (title: String, run: () -> Void)? = nil, onPick: @escaping (String) -> Void) {
        open?.close()
        let grid = IconGridView()
        grid.selected = selected
        grid.tint = tint
        let pop = NSPopover()
        pop.behavior = .transient
        grid.onPick = { n in onPick(n); pop.close() }
        let scroll = grid.scrolled(height: 300)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: scroll.frame.width, height: 300 + (clear == nil ? 0 : 34)))
        scroll.frame.origin = NSPoint(x: 0, y: clear == nil ? 0 : 34)
        box.addSubview(scroll)
        if let c = clear {
            let b = ClosureButton(title: c.title) { c.run(); pop.close() }
            b.frame = NSRect(x: 8, y: 4, width: scroll.frame.width - 16, height: 26)
            box.addSubview(b)
        }
        let vc = NSViewController()
        vc.view = box
        pop.contentViewController = vc
        pop.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        open = pop
    }
}

/// A grid of icons by group, to pick one. Used in the tag dialog and the node's icon popover.
@MainActor
final class IconGridView: NSView {
    var selected: String? { didSet { needsDisplay = true } }
    var onPick: ((String) -> Void)?
    /// Drawn in this colour (the tag's or the branch's).
    var tint: NSColor = Theme.ink { didSet { needsDisplay = true } }
    private let cell: CGFloat = 28, columns: Int, head: CGFloat = 22
    private var hits: [(NSRect, String)] = []
    private var hover: String?
    private var tracking: NSTrackingArea?

    init(columns: Int = 9) {
        self.columns = columns
        super.init(frame: .zero)
        var h: CGFloat = 4
        for g in LucideData.groups {
            let rows = Int(ceil(Double(g.names.count) / Double(columns)))
            h += head + CGFloat(rows) * cell + 4
        }
        setFrameSize(NSSize(width: CGFloat(columns) * cell + 12, height: h))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func draw(_ dirtyRect: NSRect) {
        hits = []
        var y: CGFloat = 4
        for g in LucideData.groups {
            (tr(g.zh, g.en) as NSString).draw(at: NSPoint(x: 8, y: y + 4), withAttributes: [.font: Theme.ui(11, .semibold), .foregroundColor: Theme.muted])
            y += head
            for (i, n) in g.names.enumerated() {
                let r = NSRect(x: 6 + CGFloat(i % columns) * cell, y: y + CGFloat(i / columns) * cell, width: cell, height: cell)
                hits.append((r, n))
                if selected == n || hover == n {
                    let bg = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5)
                    (selected == n ? tint.withAlphaComponent(0.18) : Theme.hover).setFill(); bg.fill()
                    if selected == n { tint.setStroke(); bg.lineWidth = 1; bg.stroke() }
                }
                Icons.draw(n, in: r.insetBy(dx: 7, dy: 7), color: selected == n ? tint : Theme.ink, weight: 1.8)
            }
            y += CGFloat(Int(ceil(Double(g.names.count) / Double(columns)))) * cell + 4
        }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let h = hits.first { $0.0.contains(p) }?.1
        if h != hover { hover = h; toolTip = h; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let n = hits.first(where: { $0.0.contains(p) })?.1 else { return }
        selected = n
        onPick?(n)
    }

    /// In a scroll view of the given height.
    func scrolled(height: CGFloat) -> NSScrollView {
        let s = NSScrollView(frame: NSRect(x: 0, y: 0, width: frame.width + 16, height: height))
        s.documentView = self
        s.hasVerticalScroller = true
        s.drawsBackground = false
        s.borderType = .noBorder
        return s
    }
}
