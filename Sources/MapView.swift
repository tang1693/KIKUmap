import Cocoa
import UniformTypeIdentifiers

let dragType = NSPasteboard.PasteboardType("ninja.tang.claudeconsole.item")

/// One item laid out on the canvas.
final class VNode {
    enum Kind { case root, main, sub, chat }
    let key: String
    let kind: Kind
    var title: String
    var time = ""
    var state = 0                 // 0 plain, 1 waiting for you, 2 running
    var done = false
    var color: NSColor
    var colored = false
    var tagColors: [NSColor] = []
    var count = 0
    var runN = 0, unrN = 0
    var collapsed = false
    var hasKids = false
    var glyph: String?            // the topic's shape (nil: none)
    var kids: [VNode] = []
    weak var parent: VNode?
    var size = NSSize.zero
    var origin = NSPoint.zero          // where the layout puts it
    /// On screen it can sit elsewhere for a moment: `offset` glides back to zero after a re-layout,
    /// `shift` keeps a dragged branch under the pointer.
    var offset = CGVector.zero
    var shift = CGVector.zero
    var isCode = false
    var dir: CGFloat = 1
    var sh: CGFloat = 0
    var labelW: CGFloat = 0

    init(key: String, kind: Kind, title: String, color: NSColor) {
        self.key = key
        self.kind = kind
        self.title = title
        self.color = color
    }

    var frame: NSRect {
        NSRect(x: origin.x + offset.dx + shift.dx, y: origin.y + offset.dy + shift.dy, width: size.width, height: size.height)
    }
    var layoutFrame: NSRect { NSRect(origin: origin, size: size) }
    /// MindNode-style underline items connect at their baseline.
    var line: Bool { kind == .sub || (kind == .chat && state == 0) }
    var chatId: String? { kind == .chat ? String(key.dropFirst(2)) : nil }
}

/// The MindNode-style map: native drawing, keyboard, editing, drag & drop, pinch zoom.
@MainActor
final class MapView: NSView, NSTextFieldDelegate {
    let store: Store
    var onOpen: ((String) -> Void)?
    var onArchive: ((String) -> Void)?
    var onHide: (() -> Void)?
    var onManageTags: (() -> Void)?

    private var rootV: VNode?
    private var all: [VNode] = []
    private var byKey: [String: VNode] = [:]
    private(set) var sel: String?
    /// Several items selected at once (⇧-drag a box, ⇧/⌘-click). Empty when one or none is; `sel` is then the selection.
    private var group = Set<String>()
    /// ⇧-drag on empty space: the box, and what was selected before it started.
    private var band: (start: NSPoint, end: NSPoint, before: Set<String>)?
    /// A plain click on one of several selected items selects just it — unless the click turns into a drag.
    private var narrowOnUp: String?
    private var editing: (key: String, field: NSTextField)?
    private var editingText: String?
    private var pressed: (key: String, at: NSPoint)?
    private var pan: (start: NSPoint, origin: NSPoint)?
    /// Keys of the item being dragged and everything under it.
    private var dragged = Set<String>()
    private var drag: Drag?
    private var glideTimer: Timer?
    /// Is this window point over the left column? Lights it up when a chat would be taken off the map there.
    var overSidebar: ((NSPoint, Bool) -> Bool)?

    /// Where a dragged item will land: under `parent`, before `before` (nil = last), on `side` at the top level.
    private struct DropAt: Equatable { let parent: String; let before: String?; let side: CGFloat }
    /// An item's place in the layout without the dragged one — the drop is worked out from this, so the gap
    /// that opens never moves the target.
    private struct Spot { let frame: NSRect; let dir: CGFloat; let parent: String?; let kind: VNode.Kind }
    private struct Drag {
        let key: String             // the item the pointer holds
        let keys: [String]          // everything moving together, in map order (just `key` for one item)
        let fromMap: Bool           // false: a chat dragged in from the left column
        let grab: CGVector          // pointer − the item's top-left
        let dir0: CGFloat
        var pointer: NSPoint
        var to: DropAt?
        let base: [String: Spot]
    }
    /// A tag dragged over an item.
    private var tagTarget: String?
    /// Click a tag in the sidebar: everything that has it stays bright, the rest fades.
    var highlightTag: String? { didSet { needsDisplay = true } }

    /// ⌘F: items whose name, full chat title or tag matches stay bright; the rest fades.
    var searchQuery = "" { didSet { updateMatches(); if !matches.isEmpty { matchIndex = -1; nextMatch() } } }
    private var matches: [String] = []
    private var matchSet: Set<String>?
    private var matchIndex = -1
    var onMatches: ((Int, Int) -> Void)?            // (current 1-based, total)
    private var fitted = false
    private var showAll = false
    /// First layout after launch: come back to the zoom and spot you left, instead of re-fitting.
    private var restoring = true
    private var phase = 0
    var spinPhase: CGFloat { CGFloat(phase) / 8 }
    private var animTimer: Timer?
    private var minuteTimer: Timer?

    // metrics
    private let R: CGFloat = 36
    private let rootF = Theme.geo(15)
    private let mainF = Theme.ui(15, .bold)
    private let subF = Theme.ui(14, .bold)
    private let chatF = Theme.ui(14)
    private let pillF = Theme.ui(14, .semibold)
    private let timeF = Theme.ui(11.5)
    private let countF = Theme.geo(12)
    private let badgeF = Theme.geo(11, bold: true)
    private let maxLabel: CGFloat = 330
    /// The little mark before a real conversation (Claude burst, or a terminal for Claude Code).
    private let iconW: CGFloat = 17

    init(store: Store) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        registerForDraggedTypes([dragType])
        minuteTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(minute), userInfo: nil, repeats: true)
    }

    /// The spinner timer only runs while the map is on screen; hidden, the map costs nothing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let w = window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: w)
        }
        occlusionChanged()
    }

    @objc private func occlusionChanged() {
        let onScreen = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        if onScreen && animTimer == nil {
            animTimer = Timer.scheduledTimer(timeInterval: 0.12, target: self, selector: #selector(animate), userInfo: nil, repeats: true)
        } else if !onScreen {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    @objc private func minute() { if window?.isVisible == true && editing == nil { reload() } }

    @objc private func animate() {
        guard window?.isVisible == true, window?.occlusionState.contains(.visible) == true else { return }
        let running = all.filter { $0.state == 2 || ($0.kind != .chat && $0.runN > 0) }
        guard !running.isEmpty else { return }
        phase = (phase + 1) % 8
        for v in running { setNeedsDisplay(v.frame.insetBy(dx: -14, dy: -14)) }
    }

    // MARK: build & layout

    func reload() {
        if drag != nil { return }
        let prev = snapshot()
        let keepRoot = rootV.map { NSPoint(x: $0.frame.midX - visibleRect.minX, y: $0.frame.midY - visibleRect.minY) }
        if store.map.needsSides { recordCurrentSides() }
        build()
        layoutTree(keep: keepRoot)
        glide(from: prev)
        if let s = sel, byKey[s] == nil { sel = nil }
        group = group.filter { byKey[$0] != nil }
        if group.count < 2 { group = [] }
        if let e = editing, let v = byKey[e.key] { e.field.frame = editRect(v) }
        if !searchQuery.isEmpty { updateMatches() }
        needsDisplay = true
    }

    // MARK: search

    private func updateMatches() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { matches = []; matchSet = nil; onMatches?(0, 0); needsDisplay = true; return }
        func hit(_ text: String) -> Bool { text.lowercased().contains(q) }
        func itemHit(_ key: String) -> Bool {
            if store.map.tags(of: key).contains(where: { hit($0.name) }) { return true }
            if key.hasPrefix("c:") {
                let id = String(key.dropFirst(2))
                return hit(store.name(id)) || hit(store.chat(id)?.title ?? "")
            }
            return hit(store.map.locate(key)?.item.node?.title ?? "")
        }
        // a folded topic counts when something inside it matches
        func insideHit(_ n: MapNode) -> Bool {
            n.children.contains { itemHit($0.key) || ($0.node.map(insideHit) ?? false) }
        }
        let found = all.filter { v in
            guard v.kind != .root else { return false }
            if itemHit(v.key) { return true }
            if v.collapsed, let n = store.map.locate(v.key)?.item.node { return insideHit(n) }
            return false
        }.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        matches = found.map { $0.key }
        matchSet = Set(matches)
        if matchIndex >= matches.count { matchIndex = matches.count - 1 }
        onMatches?(matchIndex + 1, matches.count)
        needsDisplay = true
    }

    /// ⏎ / ⇧⏎ in the search field: select the next / previous match and bring it into view.
    func nextMatch(back: Bool = false) {
        guard !matches.isEmpty else { return }
        matchIndex = back ? (matchIndex - 1 + matches.count) % matches.count : (matchIndex + 1) % matches.count
        let k = matches[matchIndex]
        select(k)
        if let v = byKey[k] { scrollToVisible(v.frame.insetBy(dx: -120, dy: -80)) }
        onMatches?(matchIndex + 1, matches.count)
    }

    /// A map from before sides were recorded: write down the sides it has always been drawn with
    /// (every chat counted, balanced by height — the old rule), so updating moves nothing.
    private func recordCurrentSides() {
        showAll = true
        build()
        showAll = false
        guard let root = rootV else { return }
        measureSubtrees(root)
        let total = root.kids.reduce(0) { $0 + $1.sh } + 26 * CGFloat(max(0, root.kids.count - 1))
        var acc: CGFloat = 0
        var sides: [String: Int] = [:]
        for (i, k) in root.kids.enumerated() {
            sides[k.key] = i == 0 || acc + k.sh / 2 <= total / 2 ? 1 : -1
            acc += k.sh + 26
        }
        // items the view skipped (a deleted chat) still need one
        for c in store.map.root.children where sides[c.key] == nil { sides[c.key] = 1 }
        store.map.recordSides(sides)
    }

    private func measureSubtrees(_ v: VNode) {
        v.kids.forEach(measureSubtrees)
        let gap: CGFloat = v.kind == .root ? 26 : 8
        let ch = v.kids.reduce(0) { $0 + $1.sh } + gap * CGFloat(max(0, v.kids.count - 1))
        v.sh = max(v.size.height, ch)
    }

    private func build() {
        all = []
        byKey = [:]
        let map = store.map
        let root = VNode(key: map.root.id, kind: .root, title: map.root.title, color: Theme.line)
        fill(root, from: map.root, depth: 0, color: Theme.line, colored: false)
        rootV = root
    }

    private func register(_ v: VNode) {
        all.append(v)
        byKey[v.key] = v
        v.tagColors = store.map.tags(of: v.key).compactMap { Theme.highlight($0.color) }
        if editing?.key == v.key, let t = editingText { v.title = t }
        measure(v)
    }

    private func fill(_ v: VNode, from n: MapNode, depth: Int, color: NSColor, colored: Bool) {
        register(v)
        var run = 0, unr = 0, cnt = 0
        func tally(_ n: MapNode) {
            store.map.walkChats(n) { id in
                guard let c = self.store.chat(id), self.store.isShown(c) || self.showAll else { return }
                cnt += 1
                if self.store.isRunning(id) { run += 1 } else if self.store.isUnread(c) { unr += 1 }
            }
        }
        tally(n)
        v.count = cnt; v.runN = run; v.unrN = unr
        v.hasKids = !n.children.isEmpty
        v.collapsed = n.isCollapsed
        measure(v)
        if n.isCollapsed { return }
        for ch in n.children {
            switch ch {
            case .chat(let id):
                guard let c = store.chat(id), store.isShown(c) || showAll else { continue }
                let k = VNode(key: "c:" + id, kind: .chat, title: store.mapLabel(id), color: color)
                k.colored = colored
                k.state = store.isRunning(id) ? 2 : (store.isUnread(c) ? 1 : 0)
                k.time = store.timeLabel(c)
                k.done = c.title.contains("🟢")
                k.isCode = c.isCode
                k.parent = v
                register(k)
                v.kids.append(k)
            case .node(let s):
                let own = Theme.highlight(s.color)
                let col = own ?? color, isColored = own != nil || colored
                let k = VNode(key: s.id, kind: depth == 0 ? .main : .sub, title: s.title.isEmpty ? tr("新主题", "New topic") : s.title, color: col)
                k.colored = isColored
                let auto = depth == 0 ? MapView.shapes[s.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 3].key : nil
                k.glyph = s.shape == "none" ? nil : (s.shape ?? auto)
                k.parent = v
                fill(k, from: s, depth: depth + 1, color: col, colored: isColored)
                v.kids.append(k)
            }
        }
    }

    private func textH(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) }

    /// Room the topic's shape takes before its name.
    private func glyphW(_ v: VNode) -> CGFloat { v.glyph == nil ? 0 : (v.kind == .main ? 20 : 14) }

    private func tagW(_ v: VNode) -> CGFloat { v.tagColors.isEmpty ? 0 : 6 + CGFloat(v.tagColors.count) * 10 }

    private func measure(_ v: VNode) {
        defer { if v.kind != .root { v.size.width += tagW(v) } }
        switch v.kind {
        case .root:
            v.size = NSSize(width: R * 2, height: R * 2)
        case .main:
            v.labelW = ceil(v.title.size(mainF).width)
            let cw = ceil(max(String(v.count).size(countF).width, "00".size(countF).width))   // 9 → 10 doesn't widen it
            v.size = NSSize(width: 13 + glyphW(v) + v.labelW + 8 + cw + 13, height: textH(mainF) + 14 + 5)
        case .sub:
            v.labelW = ceil(v.title.size(subF).width)
            v.size = NSSize(width: glyphW(v) + v.labelW + 8, height: textH(subF) + 7 + 2.5)
        case .chat:
            let f = v.state == 0 ? chatF : pillF
            v.labelW = min(maxLabel, ceil(v.title.size(f).width))
            let tw = ceil((v.time + (v.state == 2 ? "···" : "")).size(timeF).width)
            let pad: CGFloat = v.state == 0 ? 4 : 10
            let dot: CGFloat = v.state > 0 && v.colored ? 8 : 0
            // same height whether idle, waiting or running, so nothing below it shifts
            v.size = NSSize(width: pad + dot + iconW + v.labelW + 8 + tw + pad, height: max(textH(chatF), textH(pillF)) + 10)
        }
    }

    /// Places `v` and its subtree: `v`'s inner edge at `x`, centred on `cy`, growing toward `dir`.
    private func place(_ v: VNode, _ x: CGFloat, _ cy: CGFloat, _ dir: CGFloat) {
        v.dir = dir
        v.origin = NSPoint(x: dir > 0 ? x : x - v.size.width, y: cy - v.size.height / 2)
        let hgap: CGFloat = v.kind == .main ? 46 : 34
        let tot = v.kids.reduce(0) { $0 + $1.sh } + 8 * CGFloat(max(0, v.kids.count - 1))
        var y = cy - tot / 2
        for k in v.kids {
            place(k, dir > 0 ? v.origin.x + v.size.width + hgap : v.origin.x - hgap, y + k.sh / 2, dir)
            y += k.sh + 8
        }
    }

    /// Lays the tree out around the root at (−R, −R). Top-level items stay on their recorded side
    /// (`sides` overrides, for a drag in progress) — never rebalanced.
    private func position(_ root: VNode, sides: [String: CGFloat] = [:]) {
        measureSubtrees(root)
        var right: [VNode] = [], left: [VNode] = []
        for k in root.kids {
            if (sides[k.key] ?? (store.map.side(of: k.key) == -1 ? -1 : 1)) < 0 { left.append(k) } else { right.append(k) }
        }
        func side(_ arr: [VNode], _ dir: CGFloat) {
            let h = arr.reduce(0) { $0 + $1.sh } + 26 * CGFloat(max(0, arr.count - 1))
            var y = -h / 2
            for k in arr {
                place(k, dir > 0 ? R + 84 : -R - 84, y + k.sh / 2, dir)
                y += k.sh + 26
            }
        }
        root.origin = NSPoint(x: -R, y: -R)
        side(right, 1)
        side(left, -1)
    }

    private func layoutTree(keep: NSPoint?) {
        guard let root = rootV else { return }
        if store.map.fillSides() { store.map.save() }
        position(root)
        var minX = -R, maxX = R, minY = -R, maxY = R
        for v in all {
            minX = min(minX, v.origin.x); maxX = max(maxX, v.layoutFrame.maxX)
            minY = min(minY, v.origin.y); maxY = max(maxY, v.layoutFrame.maxY)
        }
        // keep the root horizontally centred in the canvas
        let half = max(-minX, maxX)
        let pad: CGFloat = 260
        let mag = enclosingScrollView?.magnification ?? 1
        let clip = enclosingScrollView?.contentView.bounds.size ?? NSSize(width: 1000, height: 700)
        var keep = keep
        if !fitted, clip.width > 100 {
            let d = UserDefaults.standard
            if restoring, d.object(forKey: "MapZoom") != nil {
                enclosingScrollView?.magnification = CGFloat(d.double(forKey: "MapZoom"))
                if keep == nil { keep = NSPoint(x: d.double(forKey: "MapRootX"), y: d.double(forKey: "MapRootY")) }
            } else {
                let s = min(1, (clip.width * mag - 40) / (2 * half), (clip.height * mag - 40) / (maxY - minY))
                enclosingScrollView?.magnification = max(0.55, s)
            }
            fitted = true
            restoring = false
        }
        let m = enclosingScrollView?.magnification ?? 1
        let minW = (enclosingScrollView?.contentSize.width ?? 1000) / m + 2
        let minH = (enclosingScrollView?.contentSize.height ?? 700) / m + 2
        let W = max(2 * half + 2 * pad, minW)
        let H = max(maxY - minY + 2 * pad, minH)
        let ox = W / 2
        let oy = (H - (maxY - minY)) / 2 - minY
        for v in all { v.origin.x += ox; v.origin.y += oy }
        setFrameSize(NSSize(width: W, height: H))
        // keep the root where it was on screen (or centre it the first time)
        let rc = NSPoint(x: root.layoutFrame.midX, y: root.layoutFrame.midY)
        let vs = visibleRect.size
        let want = keep ?? NSPoint(x: vs.width / 2, y: vs.height / 2)
        scroll(NSPoint(x: rc.x - want.x, y: rc.y - want.y))
    }

    // MARK: gliding

    /// Every item's spot on screen, relative to the root.
    private func snapshot() -> [String: NSPoint] {
        guard let r = rootV else { return [:] }
        var m: [String: NSPoint] = [:]
        for v in all { m[v.key] = NSPoint(x: v.frame.minX - r.frame.minX, y: v.frame.minY - r.frame.minY) }
        return m
    }

    /// After a re-layout, items slide from where they were instead of jumping.
    private func glide(from prev: [String: NSPoint]) {
        guard let r = rootV else { return }
        var moving = false
        for v in all {
            guard let p = prev[v.key] else { v.offset = .zero; continue }
            let dx = p.x - (v.origin.x + v.shift.dx - r.origin.x), dy = p.y - (v.origin.y + v.shift.dy - r.origin.y)
            v.offset = abs(dx) < 0.5 && abs(dy) < 0.5 ? .zero : CGVector(dx: dx, dy: dy)
            if v.offset != .zero { moving = true }
        }
        if moving && glideTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.glideStep() } }
            RunLoop.main.add(t, forMode: .common)
            glideTimer = t
        }
        needsDisplay = true
    }

    private func glideStep() {
        var moving = false
        for v in all where v.offset != .zero {
            v.offset.dx *= 0.72; v.offset.dy *= 0.72
            if abs(v.offset.dx) < 0.3 && abs(v.offset.dy) < 0.3 { v.offset = .zero } else { moving = true }
        }
        needsDisplay = true
        if !moving { glideTimer?.invalidate(); glideTimer = nil }
    }

    /// The whole map as a PDF — light colours, nothing selected, cropped to what's drawn.
    func pdfData() -> Data? {
        guard let root = rootV else { return nil }
        if editing != nil { finishEdit() }
        let r = all.reduce(root.frame) { $0.union($1.frame) }.insetBy(dx: -40, dy: -40).intersection(bounds)
        let keep = (sel, group)
        sel = nil
        group = []
        defer { (sel, group) = keep; needsDisplay = true }
        var d: Data?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { d = dataWithPDF(inside: r) }
        return d
    }

    /// Asks where to save, then writes the PDF.
    func exportPDF() {
        guard let w = window, let d = pdfData() else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = tr("Claude 导图 ", "Claude map ") + Clock.format(Date(), "yyyy-MM-dd", "yyyy-MM-dd") + ".pdf"
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url else { return }
            do { try d.write(to: url, options: .atomic); NSWorkspace.shared.activateFileViewerSelecting([url]) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    /// Remembers zoom and where the centre sits on screen (called whenever you scroll or zoom).
    func saveViewport() {
        guard !restoring, let r = rootV, let sv = enclosingScrollView else { return }
        let d = UserDefaults.standard
        d.set(Double(sv.magnification), forKey: "MapZoom")
        d.set(Double(r.frame.midX - visibleRect.minX), forKey: "MapRootX")
        d.set(Double(r.frame.midY - visibleRect.minY), forKey: "MapRootY")
    }

    func fit() {
        restoring = false
        fitted = false
        reload()
        if let r = rootV { scroll(NSPoint(x: r.frame.midX - visibleRect.width / 2, y: r.frame.midY - visibleRect.height / 2)) }
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let root = rootV else { return }
        drawLandingSpot()
        if root.kids.isEmpty && drag == nil {
            // the map starts empty: what goes on it is up to you
            let lines = [tr("把左边的置顶对话或 Claude Code 会话拖到这里", "Drag pinned chats or Claude Code sessions here from the left"),
                         tr("双击空白处新建主题", "Double-click empty space for a topic")]
            for (i, l) in lines.enumerated() {
                let f = i == 0 ? Theme.ui(14, .medium) : Theme.ui(12.5)
                let w = ceil(l.size(f).width) + 2
                drawText(l, f, Theme.muted, x: root.frame.midX - w / 2, midY: root.frame.maxY + 34 + CGFloat(i) * 22, width: w)
            }
        }
        drawEdges(root)
        for v in all where !dragged.contains(v.key) && v.frame.insetBy(dx: -30, dy: -30).intersects(dirtyRect) { drawNode(v) }
        drawDragged()
        if let b = band {
            let r = bandRect(b.start, b.end)
            Theme.ink.withAlphaComponent(0.06).setFill(); r.fill()
            let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            Theme.ink.withAlphaComponent(0.35).setStroke(); p.stroke()
        }
    }

    /// Connectors from `v` down through its subtree.
    private func drawEdges(_ v: VNode) {
            for k in v.kids {
                let x1: CGFloat, y1: CGFloat
                if v.kind == .root {
                    x1 = v.frame.midX + k.dir * (R - 6); y1 = v.frame.midY
                } else {
                    x1 = k.dir > 0 ? v.frame.maxX : v.frame.minX; y1 = anchorY(v)
                }
                let x2 = k.dir > 0 ? k.frame.minX : k.frame.maxX, y2 = anchorY(k)
                let mx = (x1 + x2) / 2
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x1, y: y1))
                p.curve(to: NSPoint(x: x2, y: y2), controlPoint1: NSPoint(x: mx, y: y1), controlPoint2: NSPoint(x: mx, y: y2))
                p.lineWidth = v.kind == .root ? 3.5 : (v.kind == .main ? 2.5 : 1.75)
                p.lineCapStyle = .round
                let faded = (highlightTag.map { !store.map.hasTag(k.key, $0) } ?? false)
                    || (matchSet.map { !$0.contains(k.key) } ?? false)
                (faded ? k.color.withAlphaComponent(0.25) : k.color).setStroke()
                p.stroke()
                drawEdges(k)
            }
    }

    /// While dragging: a faint outline of the gap the item (or items) will drop into.
    private func drawLandingSpot() {
        guard let d = drag, d.to != nil else { return }
        let frames = d.keys.compactMap { byKey[$0]?.layoutFrame }
        guard let first = frames.first else { return }
        let gap = frames.dropFirst().reduce(first) { $0.union($1) }
        let p = NSBezierPath(roundedRect: gap.insetBy(dx: -4, dy: -3), xRadius: 6, yRadius: 6)
        Theme.ink.withAlphaComponent(0.05).setFill(); p.fill()
        p.lineWidth = 1.2; p.setLineDash([4, 3], count: 2, phase: 0)
        Theme.ink.withAlphaComponent(0.3).setStroke(); p.stroke()
    }

    /// The dragged branch on top, under the pointer (a chat from the left column: a faint copy in its gap).
    private func drawDragged() {
        guard let d = drag, !dragged.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        if d.fromMap {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.3)
            sh.shadowBlurRadius = 12
            sh.shadowOffset = NSSize(width: 0, height: -4)
            sh.set()
        } else {
            ctx.setAlpha(0.45)
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if d.to == nil { for m in d.keys.compactMap({ byKey[$0] }) { drawEdges(m) } }   // not attached anywhere: their own branches still show
        all.filter { dragged.contains($0.key) }.forEach(drawNode)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        if d.fromMap && d.keys.count > 1 {
            // how many are moving, by the pointer
            let s = String(d.keys.count)
            let w = max(22, ceil(s.size(badgeF).width) + 10)
            let b = NSRect(x: d.pointer.x + 10, y: d.pointer.y - 30, width: w, height: 22)
            Theme.ink.setFill(); NSBezierPath(roundedRect: b, xRadius: 11, yRadius: 11).fill()
            let ts = s.size(badgeF)
            (s as NSString).draw(at: NSPoint(x: b.midX - ts.width / 2, y: b.midY - ts.height / 2), withAttributes: [.font: badgeF, .foregroundColor: Theme.bg])
        }
    }

    private func anchorY(_ v: VNode) -> CGFloat { v.line ? v.frame.maxY - 1 : v.frame.midY }

    private func attrs(_ f: NSFont, _ c: NSColor, truncate: Bool = false) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = truncate ? .byTruncatingTail : .byClipping
        return [.font: f, .foregroundColor: c, .paragraphStyle: p]
    }

    private func drawText(_ s: String, _ f: NSFont, _ c: NSColor, x: CGFloat, midY: CGFloat, width: CGFloat? = nil) {
        let h = textH(f)
        let w = width ?? ceil(s.size(f).width) + 2
        (s as NSString).draw(with: NSRect(x: x, y: midY - h / 2, width: w, height: h),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs(f, c, truncate: true))
    }

    private func drawNode(_ v: VNode) {
        let r = v.frame
        let isEditing = editing?.key == v.key
        var alpha: CGFloat = 1
        if let tag = highlightTag, v.kind != .root, !store.map.hasTag(v.key, tag) { alpha = min(alpha, 0.22) }
        if let m = matchSet, v.kind != .root, !m.contains(v.key) { alpha = min(alpha, 0.22) }
        NSGraphicsContext.current?.saveGraphicsState()
        if alpha < 1 { NSGraphicsContext.current?.cgContext.setAlpha(alpha) }
        switch v.kind {
        case .root:
            Theme.ink.setFill()
            NSBezierPath(ovalIn: r).fill()
            if !isEditing {
                let w = min(r.width - 12, ceil(v.title.size(rootF).width) + 2)
                drawText(v.title, rootF, Theme.bg, x: r.midX - w / 2, midY: r.midY, width: w)
            }
        case .main:
            let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)
            Theme.paper.setFill(); shape.fill()
            (v.colored ? v.color : Theme.line).setStroke(); shape.lineWidth = 1.5; shape.stroke()
            if let g = v.glyph { MapView.drawShape(g, in: NSRect(x: r.minX + 13, y: r.midY - 5, width: 10, height: 10), color: v.colored ? v.color : Theme.muted) }
            let tx = r.minX + 13 + glyphW(v)
            if !isEditing { drawText(v.title, mainF, Theme.ink, x: tx, midY: r.midY, width: v.labelW + 2) }
            let cx = tx + v.labelW + 8
            drawText(String(v.count), countF, Theme.muted, x: cx, midY: r.midY + 1)
            drawTags(v, x: cx + ceil(String(v.count).size(countF).width) + 6, midY: r.midY)
        case .sub:
            let my = r.minY + 3 + textH(subF) / 2
            if let g = v.glyph { MapView.drawShape(g, in: NSRect(x: r.minX + 4, y: my - 4, width: 8, height: 8), color: v.colored ? v.color : Theme.muted) }
            let tx = r.minX + 4 + glyphW(v)
            if !isEditing { drawText(v.title, subF, Theme.ink, x: tx, midY: my, width: v.labelW + 2) }
            drawTags(v, x: tx + v.labelW + 4, midY: my)
            v.color.setFill()
            NSRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2).fill()
        case .chat:
            let f = v.state == 0 ? chatF : pillF
            var textC = Theme.ink, timeC = Theme.muted
            if v.state > 0 {
                let pill = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: r.height / 2, yRadius: r.height / 2)
                if v.state == 1 {
                    // waiting for you: solid
                    Theme.ink.setFill(); pill.fill()
                    textC = Theme.bg; timeC = Theme.bg.withAlphaComponent(0.75)
                } else {
                    // running: outlined
                    Theme.paper.setFill(); pill.fill()
                    Theme.ink.setStroke(); pill.lineWidth = 1.5; pill.stroke()
                }
                if v.colored {
                    v.color.setFill()
                    NSBezierPath(ovalIn: NSRect(x: r.minX + 7, y: r.midY - 3, width: 6, height: 6)).fill()
                }
            } else {
                v.color.setFill()
                NSRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2).fill()
                if v.done { textC = Theme.muted }
            }
            let pad: CGFloat = v.state == 0 ? 4 : (v.colored ? 18 : 10)
            let midY = v.state == 0 ? r.minY + 3 + textH(f) / 2 : r.midY
            drawChatMark(v, NSRect(x: r.minX + pad, y: midY - 6, width: 12, height: 12), on: v.state == 1)
            if !isEditing { drawText(v.title, f, textC, x: r.minX + pad + iconW, midY: midY, width: v.labelW) }
            let t = v.time + (v.state == 2 ? String(repeating: "·", count: phase / 2) : "")
            let tx = r.minX + pad + iconW + v.labelW + 8
            drawText(t, timeF, timeC, x: tx, midY: midY + 1)
            drawTags(v, x: tx + ceil((v.time + (v.state == 2 ? "···" : "")).size(timeF).width) + 6, midY: midY)
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        // selection and drop outlines first, then badges and the fold handle on top of them
        if (sel == v.key || group.contains(v.key)) && !isEditing {
            let p = v.kind == .root ? NSBezierPath(ovalIn: r.insetBy(dx: -5, dy: -5)) : NSBezierPath(rect: r.insetBy(dx: -4, dy: -4))
            p.lineWidth = 2
            p.setLineDash([5, 3], count: 2, phase: 0)
            Theme.ink.setStroke()
            p.stroke()
        }
        if tagTarget == v.key {
            Theme.ink.set()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: -5, dy: -5), xRadius: 6, yRadius: 6)
            p.lineWidth = 2; p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
        }
        if let tag = highlightTag, v.kind != .root, store.map.hasTag(v.key, tag), let c = store.map.tags.first(where: { $0.id == tag }).flatMap({ Theme.highlight($0.color) }) {
            c.set()
            let p = NSBezierPath(roundedRect: r.insetBy(dx: -5, dy: -4), xRadius: 6, yRadius: 6)
            p.lineWidth = 2.5; p.stroke()
        }
        if let d = drag, d.to?.parent == v.key, !dragged.contains(v.key) {
            // the item's new parent
            Theme.ink.set()
            let p = v.kind == .root ? NSBezierPath(ovalIn: r.insetBy(dx: -5, dy: -5)) : NSBezierPath(roundedRect: r.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6)
            p.lineWidth = 2; p.stroke()
        }
        if v.kind != .chat { drawBadges(v) }
        if (v.kind == .main || v.kind == .sub) && v.hasKids && (v.collapsed || sel == v.key) { drawFold(v) }
    }

    /// Marks a real conversation, so it reads apart from a plain topic: the little Claude burst, or a
    /// terminal for a Claude Code session.
    private func drawChatMark(_ v: VNode, _ r: NSRect, on solid: Bool) {
        if v.isCode {
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            guard let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
            let c = solid ? Theme.bg : Theme.muted
            let tinted = NSImage(size: img.size, flipped: false) { b in img.draw(in: b); c.set(); b.fill(using: .sourceAtop); return true }
            let s = img.size
            tinted.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        } else {
            Logo.draw(in: r)
        }
    }

    private func drawTags(_ v: VNode, x: CGFloat, midY: CGFloat) {
        for (i, c) in v.tagColors.enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + CGFloat(i) * 10, y: midY - 3.5, width: 7, height: 7)).fill()
        }
    }

    static let shapes: [(key: String, zh: String, en: String)] = [
        ("square", "方块", "Square"), ("circle", "圆圈", "Circle"), ("triangle", "三角", "Triangle"),
        ("diamond", "菱形", "Diamond"), ("cross", "交叉", "Cross"), ("star", "星星", "Star"),
    ]

    static func drawShape(_ name: String, in r: NSRect, color c: NSColor) {
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + x * r.width, y: flipped ? r.minY + y * r.height : r.maxY - y * r.height) }
        c.setFill(); c.setStroke()
        switch name {
        case "circle": NSBezierPath(ovalIn: r).fill()
        case "triangle":
            let p = NSBezierPath()
            p.move(to: pt(0, 1)); p.line(to: pt(1, 1)); p.line(to: pt(0.5, 0)); p.close(); p.fill()
        case "diamond":
            let p = NSBezierPath()
            p.move(to: pt(0.5, -0.08)); p.line(to: pt(1.08, 0.5)); p.line(to: pt(0.5, 1.08)); p.line(to: pt(-0.08, 0.5)); p.close(); p.fill()
        case "cross":
            let p = NSBezierPath()
            p.move(to: pt(0.08, 0.08)); p.line(to: pt(0.92, 0.92))
            p.move(to: pt(0.92, 0.08)); p.line(to: pt(0.08, 0.92))
            p.lineWidth = max(1.6, r.width * 0.24); p.lineCapStyle = .round; p.stroke()
        case "star":
            let p = NSBezierPath()
            for i in 0..<10 {
                let a = (-90 + 36 * CGFloat(i)) * .pi / 180, rr: CGFloat = i % 2 == 0 ? 0.62 : 0.26
                let q = pt(0.5 + rr * cos(a), 0.55 + rr * sin(a))
                if i == 0 { p.move(to: q) } else { p.line(to: q) }
            }
            p.close(); p.fill()
        default: r.fill()
        }
    }

    /// A small picture of a shape for menus.
    static func shapeImage(_ name: String) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            drawShape(name, in: r.insetBy(dx: 1.5, dy: 1.5), color: .black); return true
        }
        img.isTemplate = true
        return img
    }

    private func drawBadges(_ v: VNode) {
        var items: [(Int, Int)] = []
        if v.runN > 0 { items.append((v.runN, 2)) }
        if v.unrN > 0 { items.append((v.unrN, 1)) }
        guard !items.isEmpty else { return }
        let r = v.frame
        var x = v.kind == .root ? r.maxX - 22 : (v.dir < 0 ? r.minX - 11 : r.maxX - 11 - CGFloat(items.count - 1) * 25)
        let y = v.kind == .root ? r.minY : r.minY - 11
        for (n, state) in items {
            let s = String(n)
            let w = max(22, ceil(s.size(badgeF).width) + 10)
            let b = NSRect(x: x, y: y, width: w, height: 22)
            Theme.bg.setFill(); NSBezierPath(roundedRect: b.insetBy(dx: -2, dy: -2), xRadius: 13, yRadius: 13).fill()
            let p = NSBezierPath(roundedRect: b.insetBy(dx: 0.75, dy: 0.75), xRadius: 10.5, yRadius: 10.5)
            if state == 1 { Theme.ink.setFill(); p.fill() } else {
                Theme.paper.setFill(); p.fill(); Theme.ink.setStroke(); p.lineWidth = 1.5; p.stroke()
            }
            let ts = s.size(badgeF)
            (s as NSString).draw(at: NSPoint(x: b.midX - ts.width / 2, y: b.midY - ts.height / 2),
                                 withAttributes: [.font: badgeF, .foregroundColor: state == 1 ? Theme.bg : Theme.ink])
            x += w + 3
        }
    }

    private func foldRect(_ v: VNode) -> NSRect {
        let r = v.frame
        let label = v.collapsed ? String(v.count) : "−"
        let w = max(18, ceil(label.size(badgeF).width) + 8)
        let x = v.dir > 0 ? r.maxX + 7 : r.minX - 7 - w
        let y = v.kind == .sub ? r.maxY - 9 : r.midY - 9
        return NSRect(x: x, y: y, width: w, height: 18)
    }

    private func drawFold(_ v: VNode) {
        let f = foldRect(v)
        let p = NSBezierPath(roundedRect: f, xRadius: 9, yRadius: 9)
        Theme.bg.setFill(); p.fill()
        v.color.setStroke(); p.lineWidth = 1.5; p.stroke()
        let label = v.collapsed ? String(v.count) : "−"
        let ts = label.size(badgeF)
        (label as NSString).draw(at: NSPoint(x: f.midX - ts.width / 2, y: f.midY - ts.height / 2), withAttributes: [.font: badgeF, .foregroundColor: Theme.ink])
    }

    // MARK: hit testing

    private func hit(_ p: NSPoint) -> VNode? {
        for v in all.reversed() {
            if v.kind == .root {
                let c = NSPoint(x: v.frame.midX, y: v.frame.midY)
                if hypot(p.x - c.x, p.y - c.y) <= R { return v }
            } else if v.frame.insetBy(dx: -3, dy: -3).contains(p) {
                return v
            }
        }
        return nil
    }

    private func foldHit(_ p: NSPoint) -> VNode? {
        all.first { ($0.kind == .main || $0.kind == .sub) && $0.hasKids && ($0.collapsed || sel == $0.key) && foldRect($0).insetBy(dx: -3, dy: -3).contains(p) }
    }

    // MARK: selection & navigation

    func select(_ key: String?) {
        sel = key
        group = []
        needsDisplay = true
        if let k = key, let v = byKey[k] { scrollToVisible(v.frame.insetBy(dx: -40, dy: -40)) }
    }

    /// Everything selected: the group, or the one selected item.
    private var selection: Set<String> { group.isEmpty ? Set(sel.map { [$0] } ?? []) : group }

    /// Sets several items as the selection (the root never joins a group); `lead` gets the keyboard.
    private func setSelection(_ keys: Set<String>, lead: String?) {
        let s = keys.count > 1 ? keys.filter { byKey[$0]?.kind != .root } : keys
        group = s.count > 1 ? s : []
        sel = lead.flatMap { s.contains($0) ? $0 : nil } ?? s.first
        needsDisplay = true
    }

    /// ⇧/⌘-click: adds the item to the selection, or takes it out.
    private func toggle(_ key: String) {
        var s = selection
        if s.contains(key) { s.remove(key) } else { s.insert(key) }
        setSelection(s, lead: s.contains(key) ? key : sel)
    }

    private func bandRect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The box covers what it touches, on top of what was selected when it started.
    private func updateBand(to p: NSPoint) {
        guard var b = band else { return }
        b.end = p
        band = b
        let r = bandRect(b.start, b.end)
        var s = b.before
        for v in all where v.kind != .root && v.frame.intersects(r) { s.insert(v.key) }
        setSelection(s, lead: sel)
    }

    /// The items that move together: no root, nothing whose parent topic is moving too, in map order.
    private func movingKeys(_ keys: Set<String>) -> [String] {
        func covered(_ v: VNode) -> Bool {
            var p = v.parent
            while let q = p { if keys.contains(q.key) { return true }; p = q.parent }
            return false
        }
        return all.filter { keys.contains($0.key) && $0.kind != .root && !covered($0) }.map(\.key)
    }

    private func nav(_ d: String) {
        guard let k = sel, let v = byKey[k] else { select(rootV?.key); return }
        if v.kind == .root {
            if d == "left" || d == "right" {
                if let first = v.kids.first(where: { d == "left" ? $0.dir < 0 : $0.dir > 0 }) { select(first.key) }
            }
            return
        }
        let outward = (v.dir > 0 && d == "right") || (v.dir < 0 && d == "left")
        let inward = (v.dir > 0 && d == "left") || (v.dir < 0 && d == "right")
        if outward, !v.kids.isEmpty {
            let best = v.kids.min { abs($0.frame.midY - v.frame.midY) < abs($1.frame.midY - v.frame.midY) }
            select(best?.key)
        } else if inward, let p = v.parent {
            select(p.key)
        } else if d == "up" || d == "down", let p = v.parent {
            let sibs = p.kids.filter { $0.dir == v.dir }
            if let i = sibs.firstIndex(where: { $0 === v }) {
                let j = i + (d == "up" ? -1 : 1)
                if j >= 0 && j < sibs.count { select(sibs[j].key) }
            }
        }
    }

    // MARK: operations

    private func changed(select key: String?, edit: Bool = false) {
        store.notify()
        if let k = key { select(k) }
        if edit, let k = key { startEdit(k) }
    }

    func addTopicUnderRoot() { changed(select: store.map.addChild(store.map.root.id), edit: true) }

    // MARK: keyboard (MindNode shortcuts)

    override func keyDown(with e: NSEvent) {
        if drag?.fromMap == true, e.keyCode == 53 { cancelDrag(); return }        // esc: put it back
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = f.contains(.command), opt = f.contains(.option), shift = f.contains(.shift)
        let map = store.map
        guard let k = sel else {
            switch e.keyCode {
            case 53: onHide?()
            case 48: changed(select: map.addChild(map.root.id), edit: true)                 // ⇥ → new topic
            case 36, 76: addTopicUnderRoot()                                                // ⏎ → new topic
            case 123, 124, 125, 126: select(rootV?.key)
            default: super.keyDown(with: e)
            }
            return
        }
        if group.count > 1 {
            switch e.keyCode {
            case 53: select(nil); return                                                 // esc
            case 51, 117:                                                                // delete them all
                map.remove(movingKeys(group))
                changed(select: nil)
                return
            default: break
            }
        }
        switch e.keyCode {
        case 53: select(nil)                                                             // esc
        case 48: changed(select: opt ? map.addParent(k) : map.addChild(k), edit: true)   // tab / ⌥tab
        case 36, 76:                                                                     // return
            if cmd { startEdit(k) }
            else if shift { addTopicUnderRoot() }
            else { changed(select: map.addSibling(k, above: opt), edit: true) }
        case 51, 117: changed(select: map.remove(k, keepChildren: opt))                  // delete
        case 49: if let id = byKey[k]?.chatId { onOpen?(id) }                            // space
        case 120: startEdit(k)                                                           // F2
        case 126: if cmd { map.reorder(k, by: -1); changed(select: k) } else { nav("up") }
        case 125: if cmd { map.reorder(k, by: 1); changed(select: k) } else { nav("down") }
        case 123: nav("left")
        case 124: nav("right")
        case 47 where opt: map.toggleFold(k); changed(select: k)                         // ⌥.
        default: super.keyDown(with: e)
        }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: e) }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f.contains(.command) else { return super.performKeyEquivalent(with: e) }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (ch, e.keyCode) {
        case ("z", _):
            let ok = f.contains(.shift) ? store.map.redo() : store.map.undo()
            if ok { store.notify() }
            return true
        case ("a", _):
            setSelection(Set(all.filter { $0.kind != .root }.map(\.key)), lead: sel)
            return true
        case ("=", _), ("+", _): zoom(1.15); return true
        case ("-", _): zoom(1 / 1.15); return true
        case ("0", _): fit(); return true
        case (_, 36), (_, 76): if let k = sel { startEdit(k) }; return true
        case (_, 126), (_, 125):
            if let k = sel { store.map.reorder(k, by: e.keyCode == 126 ? -1 : 1); changed(select: k) }
            return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    private func zoom(_ by: CGFloat) {
        guard let sv = enclosingScrollView else { return }
        let c = NSPoint(x: visibleRect.midX, y: visibleRect.midY)
        sv.setMagnification(min(2, max(0.4, sv.magnification * by)), centeredAt: c)
    }

    // MARK: editing (MindNode: new topics start in edit mode; ⏎ / esc finishes; ⇥ adds a child)

    private func font(for v: VNode) -> NSFont {
        switch v.kind {
        case .root: return rootF
        case .main: return mainF
        case .sub: return subF
        case .chat: return v.state == 0 ? chatF : pillF
        }
    }

    private func editRect(_ v: VNode) -> NSRect {
        let f = font(for: v)
        let h = textH(f) + 4
        let w = max(80, ceil((editingText ?? v.title).size(f).width) + 24)
        switch v.kind {
        case .root: return NSRect(x: v.frame.midX - 45, y: v.frame.midY - h / 2, width: 90, height: h)
        case .main: return NSRect(x: v.frame.minX + 11 + glyphW(v), y: v.frame.midY - h / 2, width: w, height: h)
        case .sub: return NSRect(x: v.frame.minX + 2 + glyphW(v), y: v.frame.minY + 1, width: w, height: h)
        case .chat:
            let pad: CGFloat = (v.state == 0 ? 2 : (v.colored ? 16 : 8)) + iconW
            let y = v.state == 0 ? v.frame.minY + 1 : v.frame.midY - h / 2
            return NSRect(x: v.frame.minX + pad, y: y, width: w, height: h)
        }
    }

    func startEdit(_ key: String) {
        guard let v = byKey[key] else { return }
        if editing != nil { finishEdit() }
        let text: String
        if let id = v.chatId { text = store.mapLabel(id) } else { text = store.map.locate(key)?.item.node?.title ?? v.title }
        let tf = NSTextField(string: text)
        tf.isBordered = false
        tf.isBezeled = false
        tf.focusRingType = .none
        tf.drawsBackground = true
        tf.backgroundColor = Theme.paper
        tf.textColor = Theme.ink
        tf.font = font(for: v)
        tf.alignment = v.kind == .root ? .center : .left
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        tf.delegate = self
        editing = (key, tf)
        editingText = text
        tf.frame = editRect(v)
        addSubview(tf)
        window?.makeFirstResponder(tf)
        tf.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    func finishEdit() {
        guard let e = editing else { return }
        editing = nil
        let text = e.field.stringValue
        editingText = nil
        e.field.delegate = nil
        e.field.removeFromSuperview()
        let chatTitle = e.key.hasPrefix("c:") ? store.chat(String(e.key.dropFirst(2)))?.title : nil
        store.map.rename(e.key, to: text, chatTitle: chatTitle)
        window?.makeFirstResponder(self)
        changed(select: e.key)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let e = editing else { return }
        editingText = e.field.stringValue
        reload()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if editing != nil { finishEdit() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) || sel == #selector(NSResponder.cancelOperation(_:)) {
            finishEdit()
            return true
        }
        if sel == #selector(NSResponder.insertTab(_:)) {
            let k = editing?.key
            finishEdit()
            if let k = k { changed(select: store.map.addChild(k), edit: true) }
            return true
        }
        return false
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if editing != nil { finishEdit() }
        window?.makeFirstResponder(self)
        narrowOnUp = nil
        let adding = !e.modifierFlags.intersection([.shift, .command]).isEmpty
        if !adding, let v = foldHit(p) { store.map.toggleFold(v.key); changed(select: v.key); return }
        if let v = hit(p) {
            if adding {
                // ⇧/⌘-click: in or out of the selection; holding on and dragging moves the whole selection
                if v.kind != .root { toggle(v.key) }
                if selection.contains(v.key) && v.kind != .root { pressed = (v.key, p) }
                return
            }
            if group.contains(v.key) {
                sel = v.key                 // keep the group: dragging moves all of it, a click narrows to this one
                narrowOnUp = v.key
                needsDisplay = true
            } else {
                select(v.key)
            }
            if e.clickCount == 2 {
                if let id = v.chatId { onOpen?(id) } else { startEdit(v.key) }
                return
            }
            if v.kind != .root { pressed = (v.key, p) }
        } else if adding {
            band = (p, p, selection.filter { byKey[$0]?.kind != .root })
        } else if e.clickCount == 2 {
            addTopicUnderRoot()
        } else {
            select(nil)
            pan = (e.locationInWindow, visibleRect.origin)
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with e: NSEvent) {
        if let pn = pan {
            let m = enclosingScrollView?.magnification ?? 1
            let dx = e.locationInWindow.x - pn.start.x, dy = e.locationInWindow.y - pn.start.y
            scroll(NSPoint(x: pn.origin.x - dx / m, y: pn.origin.y + dy / m))
            return
        }
        if band != nil {
            autoscroll(with: e)
            updateBand(to: convert(e.locationInWindow, from: nil))
            return
        }
        if drag != nil { dragMoved(e); return }
        guard let pr = pressed else { return }
        let p = convert(e.locationInWindow, from: nil)
        if hypot(p.x - pr.at.x, p.y - pr.at.y) < 5 { return }
        pressed = nil
        narrowOnUp = nil
        startDrag(pr.key, pressedAt: pr.at, pointer: p)
    }

    override func mouseUp(with e: NSEvent) {
        if pan != nil { NSCursor.pop() }
        if band != nil { band = nil; needsDisplay = true }
        if let k = narrowOnUp { select(k) }
        narrowOnUp = nil
        pressed = nil
        pan = nil
        if drag?.fromMap == true { endDrag(e) }
    }

    // MARK: right-click menu

    override func menu(for e: NSEvent) -> NSMenu? {
        if editing != nil { finishEdit() }
        let p = convert(e.locationInWindow, from: nil)
        let v = hit(p)
        if let v = v { select(v.key) }
        let m = NSMenu()
        m.autoenablesItems = false
        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [], _ f: @escaping () -> Void) {
            let it = MenuAction(title: title, key: key, mods: mods, f)
            m.addItem(it)
        }
        add(tr("新主题", "New topic"), "\r", [.shift]) { [weak self] in self?.addTopicUnderRoot() }
        guard let v = v else {
            add(tr("导出 PDF…", "Export PDF…"), "e") { [weak self] in self?.exportPDF() }
            return m
        }
        let k = v.key, map = store.map
        if v.kind != .chat {
            add(tr("新子主题", "New subtopic"), "\t") { [weak self] in self?.changed(select: map.addChild(k), edit: true) }
        }
        if v.kind != .root {
            add(tr("新同级主题", "New sibling"), "\r") { [weak self] in self?.changed(select: map.addSibling(k, above: false), edit: true) }
        }
        m.addItem(.separator())
        if let id = v.chatId {
            add(tr("在 Claude 里打开", "Open in Claude"), " ") { [weak self] in self?.onOpen?(id) }
            if store.chat(id)?.isCode == false {
                add(tr("让 Claude 写总结存档…", "Archive a summary…")) { [weak self] in self?.onArchive?(id) }
            }
        }
        add(v.kind == .chat ? tr("改显示名称", "Rename (local)") : tr("改名", "Rename"), "\r", [.command]) { [weak self] in self?.startEdit(k) }
        if v.kind == .main || v.kind == .sub {
            let colors = NSMenuItem(title: tr("分支颜色", "Branch colour"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let current = map.locate(k)?.item.node?.color
            let none = MenuAction(title: tr("无颜色", "None")) { [weak self] in map.setColor(k, nil); self?.changed(select: k) }
            none.image = Theme.swatch(nil)
            none.state = Theme.highlight(current) == nil ? .on : .off
            sub.addItem(none)
            sub.addItem(.separator())
            for h in Theme.highlights {
                let it = MenuAction(title: tr(h.zh, h.en)) { [weak self] in map.setColor(k, h.key); self?.changed(select: k) }
                it.image = Theme.swatch(h.color)
                it.state = current == h.key ? .on : .off
                sub.addItem(it)
            }
            colors.submenu = sub
            m.addItem(colors)
            let shapes = NSMenuItem(title: tr("图形", "Shape"), action: nil, keyEquivalent: "")
            let sm = NSMenu()
            let own = map.locate(k)?.item.node?.shape
            for s in MapView.shapes {
                let it = MenuAction(title: tr(s.zh, s.en)) { [weak self] in map.setShape(k, s.key); self?.changed(select: k) }
                it.image = MapView.shapeImage(s.key)
                it.state = v.glyph == s.key ? .on : .off
                sm.addItem(it)
            }
            sm.addItem(.separator())
            let noShape = MenuAction(title: tr("不要图形", "No shape")) { [weak self] in map.setShape(k, "none"); self?.changed(select: k) }
            noShape.state = v.glyph == nil ? .on : .off
            sm.addItem(noShape)
            if own != nil {
                sm.addItem(MenuAction(title: tr("恢复默认", "Default")) { [weak self] in map.setShape(k, nil); self?.changed(select: k) })
            }
            shapes.submenu = sm
            m.addItem(shapes)
        }
        if v.kind != .root { m.addItem(tagMenu(k)) }
        if v.hasKids && v.kind != .root {
            add(v.collapsed ? tr("展开", "Expand") : tr("折叠", "Collapse"), ".", [.option]) { [weak self] in map.toggleFold(k); self?.changed(select: k) }
        }
        if v.kind != .root {
            m.addItem(.separator())
            add(v.kind == .chat ? tr("从导图移回左边", "Back to the inbox") : tr("删除", "Delete"), "\u{8}") { [weak self] in self?.changed(select: map.remove(k, keepChildren: false)) }
            if v.kind != .chat && v.hasKids {
                add(tr("只删这个主题（保留下面的）", "Delete topic, keep its items"), "\u{8}", [.option]) { [weak self] in self?.changed(select: map.remove(k, keepChildren: true)) }
            }
        }
        return m
    }

    /// "Tags" submenu: tick any number of tags, or make a new one.
    func tagMenu(_ key: String) -> NSMenuItem {
        let top = NSMenuItem(title: tr("标签", "Tags"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let map = store.map
        for t in map.tags {
            let it = MenuAction(title: t.name) { [weak self] in map.toggleTag(key, t.id); self?.changed(select: key) }
            it.image = Theme.swatch(Theme.highlight(t.color))
            it.state = map.hasTag(key, t.id) ? .on : .off
            sub.addItem(it)
        }
        if !map.tags.isEmpty { sub.addItem(.separator()) }
        sub.addItem(MenuAction(title: tr("新标签…", "New tag…")) { [weak self] in
            guard let self = self, let (name, color) = TagPrompt.ask(color: map.nextTagColor(), window: self.window) else { return }
            map.addTag(name, color: color, to: key)
            self.changed(select: key)
        })
        sub.addItem(MenuAction(title: tr("管理标签…", "Manage tags…")) { [weak self] in self?.onManageTags?() })
        top.submenu = sub
        return top
    }

    // MARK: drag & drop

    static func dragImage(_ text: String) -> NSImage {
        let f = Theme.ui(13, .semibold)
        let t = text.count > 40 ? String(text.prefix(40)) + "…" : text
        let s = t.size(f)
        let size = NSSize(width: ceil(s.width) + 20, height: ceil(s.height) + 10)
        return NSImage(size: size, flipped: false) { r in
            Theme.ink.setFill()
            r.fill()
            (t as NSString).draw(at: NSPoint(x: 10, y: 5), withAttributes: [.font: f, .foregroundColor: Theme.bg])
            return true
        }
    }

    // Dragging is tracked by hand (mouseDragged), so the branch can follow the pointer while the rest
    // of the map makes room — MindNode-style. Chats dragged in from the left column come as a drag session.

    private func subtreeKeys(_ v: VNode) -> Set<String> {
        var s = Set<String>()
        func mark(_ n: VNode) { s.insert(n.key); n.kids.forEach(mark) }
        mark(v)
        return s
    }

    /// Every item's place with `keys` (and what's under them) taken out, the root staying where it is.
    private func baseSpots(without keys: [String]) -> [String: Spot] {
        let rootAt = rootV?.layoutFrame.origin ?? .zero
        build()
        guard let root = rootV else { return [:] }
        var blocked = Set<String>()
        for k in keys {
            guard let v = byKey[k] else { continue }
            blocked.formUnion(subtreeKeys(v))
            v.parent?.kids.removeAll { $0 === v }
        }
        position(root)
        let dx = rootAt.x - root.origin.x, dy = rootAt.y - root.origin.y
        for v in all { v.origin.x += dx; v.origin.y += dy }
        var out: [String: Spot] = [:]
        for v in all where !blocked.contains(v.key) {
            out[v.key] = Spot(frame: v.layoutFrame, dir: v.dir, parent: v.parent?.key, kind: v.kind)
        }
        return out
    }

    /// Where letting go at `p` puts the item: right on a topic → inside it; out past a topic → one of
    /// its children; beside an item → its sibling, in the order the pointer is at.
    private func dropAt(_ p: NSPoint, _ base: [String: Spot]) -> DropAt? {
        guard let rootKey = rootV?.key, let rs = base[rootKey] else { return nil }
        if let on = base.first(where: { ($0.value.kind == .main || $0.value.kind == .sub) && $0.value.frame.insetBy(dx: 2, dy: 0).contains(p) }) {
            let f = (p.y - on.value.frame.minY) / max(1, on.value.frame.height)
            if f > 0.22 && f < 0.78 { return DropAt(parent: on.key, before: nil, side: on.value.dir) }
        }
        func dist(_ s: Spot) -> CGFloat {
            if s.kind == .root { return max(0, hypot(p.x - s.frame.midX, p.y - s.frame.midY) - R) }
            let r = s.frame
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return hypot(dx, dy * 1.6)          // rows are close together: vertical distance counts more
        }
        guard let near = base.min(by: { dist($0.value) < dist($1.value) }) else { return nil }
        let s = near.value
        let parent: String, side: CGFloat
        if s.kind == .root {
            parent = rootKey; side = p.x < rs.frame.midX ? -1 : 1
        } else if s.kind != .chat && (s.dir > 0 ? p.x > s.frame.maxX + 14 : p.x < s.frame.minX - 14) {
            parent = near.key; side = s.dir
        } else {
            parent = s.parent ?? rootKey; side = s.dir
        }
        let sibs = base.filter { $0.value.parent == parent && (parent != rootKey || $0.value.dir == side) }
            .sorted { $0.value.frame.midY < $1.value.frame.midY }
        return DropAt(parent: parent, before: sibs.first { $0.value.frame.midY > p.y }?.key, side: side)
    }

    /// The map as it will be after the drop: the gap opens, the rest slides aside, and the dragged
    /// branches hang off their new parent, together, wherever the pointer holds them.
    private func rebuildPreview(from prev: [String: NSPoint]? = nil) {
        guard let d = drag else { return }
        let prev = prev ?? snapshot()
        let rootAt = rootV?.layoutFrame.origin ?? .zero
        build()
        guard let root = rootV else { return }
        var moving: [VNode] = []
        if d.fromMap || d.to != nil {
            for k in d.keys {
                if let m = byKey[k] {
                    m.parent?.kids.removeAll { $0 === m }
                    moving.append(m)
                } else if !d.fromMap {
                    // a chat from the left column that isn't on the map yet
                    let id = String(k.dropFirst(2))
                    let v = VNode(key: k, kind: .chat, title: store.mapLabel(id), color: Theme.line)
                    if let c = store.chat(id) {
                        v.state = store.isRunning(id) ? 2 : (store.isUnread(c) ? 1 : 0)
                        v.time = store.timeLabel(c)
                        v.isCode = c.isCode
                    }
                    register(v)
                    moving.append(v)
                }
            }
        }
        var sides: [String: CGFloat] = [:]
        var attached = false
        if !moving.isEmpty, let t = d.to, let pv = byKey[t.parent] {
            var i = pv.kids.count
            if let b = t.before, let j = pv.kids.firstIndex(where: { $0.key == b }) {
                i = j
            } else if pv.kind == .root, let j = pv.kids.lastIndex(where: { (store.map.side(of: $0.key) == -1 ? -1 : 1) == t.side }) {
                i = j + 1
            }
            pv.kids.insert(contentsOf: moving, at: i)
            for m in moving {
                m.parent = pv
                if pv.kind == .root { sides[m.key] = t.side }
            }
            attached = true
        }
        position(root, sides: sides)
        if !attached && !moving.isEmpty {
            // not attached anywhere yet: the branches hang together, stacked as they will land
            moving.forEach(measureSubtrees)
            var y = -(moving.reduce(0) { $0 + $1.sh } + 8 * CGFloat(moving.count - 1)) / 2
            for m in moving { place(m, 0, y + m.sh / 2, d.dir0); y += m.sh + 8 }
        }
        let dx = rootAt.x - root.origin.x, dy = rootAt.y - root.origin.y
        for v in all { v.origin.x += dx; v.origin.y += dy }
        dragged = moving.reduce(into: Set<String>()) { $0.formUnion(subtreeKeys($1)) }
        followPointer()
        glide(from: prev)
        if d.fromMap { for m in moving { m.offset = .zero } }        // the items themselves stay right under the pointer
    }

    /// The dragged branch sits where the pointer holds it.
    private func followPointer() {
        guard let d = drag, d.fromMap, let m = byKey[d.key] else { return }
        let s = CGVector(dx: d.pointer.x - d.grab.dx - m.origin.x, dy: d.pointer.y - d.grab.dy - m.origin.y)
        for v in all where dragged.contains(v.key) { v.shift = s }
        needsDisplay = true
    }

    private func startDrag(_ key: String, pressedAt: NSPoint, pointer: NSPoint) {
        guard let pressedV = byKey[key], pressedV.kind != .root else { return }
        if editing != nil { finishEdit() }
        // a selected item drags the whole selection with it
        let keys = group.contains(key) ? movingKeys(group) : [key]
        // the pointer holds the pressed item, or the selected topic it sits in
        var lead: VNode? = pressedV
        while let l = lead, !keys.contains(l.key) { lead = l.parent }
        guard let v = lead else { return }
        let prev = snapshot()
        let grab = CGVector(dx: pressedAt.x - v.frame.minX, dy: pressedAt.y - v.frame.minY)
        let base = baseSpots(without: keys)
        drag = Drag(key: v.key, keys: keys, fromMap: true, grab: grab, dir0: v.dir, pointer: pointer, to: dropAt(pointer, base), base: base)
        rebuildPreview(from: prev)
        NSCursor.closedHand.push()
    }

    private func dragMoved(_ e: NSEvent) {
        guard var d = drag else { return }
        autoscroll(with: e)
        let p = convert(e.locationInWindow, from: nil)
        d.pointer = p
        let offMap = overSidebar?(e.locationInWindow, d.keys.allSatisfy { $0.hasPrefix("c:") }) ?? false
        let t = offMap ? nil : dropAt(p, d.base)
        let moved = t != d.to
        d.to = t
        drag = d
        if moved { rebuildPreview() } else { followPointer() }
    }

    private func endDrag(_ e: NSEvent) {
        guard let d = drag else { return }
        NSCursor.pop()
        let offMap = overSidebar?(e.locationInWindow, false) ?? false     // also turns the highlight off
        drag = nil
        if offMap {
            // back to the left column: chats only
            if d.keys.allSatisfy({ $0.hasPrefix("c:") }) { store.map.remove(d.keys) }
        } else if let t = d.to {
            land(d, t)
        }
        dragged = []
        reload()
        changed(select: offMap ? nil : d.key)
        if !offMap && d.keys.count > 1 { setSelection(Set(d.keys), lead: d.key) }
    }

    private func cancelDrag() {
        NSCursor.pop()
        _ = overSidebar?(NSPoint(x: -1e6, y: -1e6), false)
        drag = nil
        dragged = []
        reload()
    }

    /// Puts the item where the preview showed it.
    private func land(_ d: Drag, _ t: DropAt) {
        let map = store.map
        let target: String, drop: MapModel.Drop
        if let b = t.before {
            target = b; drop = .before
        } else if let last = d.base.filter({ $0.value.parent == t.parent && (t.parent != map.root.id || $0.value.dir == t.side) })
                    .max(by: { $0.value.frame.midY < $1.value.frame.midY })?.key {
            target = last; drop = .after
        } else {
            target = t.parent; drop = .into
        }
        if d.keys.count > 1 {
            map.move(d.keys, to: target, drop, side: Int(t.side))
        } else if d.fromMap {
            map.move(d.key, to: target, drop, side: Int(t.side))
        } else {
            map.place(chat: String(d.key.dropFirst(2)), at: target, drop, side: Int(t.side))
        }
    }

    // chats from the left column, and tags

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let s = sender.draggingPasteboard.string(forType: dragType), s.hasPrefix("side|c:"), drag == nil {
            // one chat, or several picked in the left column (one key per line)
            let keys = s.dropFirst(5).split(separator: "\n").map(String.init)
            let prev = snapshot()
            let base = baseSpots(without: keys)
            drag = Drag(key: keys[0], keys: keys, fromMap: false, grab: .zero, dir0: 1, pointer: .zero, to: nil, base: base)
            rebuildPreview(from: prev)
        }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let s = sender.draggingPasteboard.string(forType: dragType) else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        if s.hasPrefix("tag|") {
            // a tag from the sidebar: onto whatever item is under the pointer
            let k = hit(p).flatMap { $0.kind == .root ? nil : $0.key }
            if k != tagTarget { tagTarget = k; needsDisplay = true }
            return k == nil ? [] : .copy
        }
        guard var d = drag, !d.fromMap else { return [] }
        autoscroll(with: NSApp.currentEvent ?? NSEvent())
        let t = dropAt(p, d.base)
        if t != d.to { d.to = t; drag = d; rebuildPreview() }
        return t == nil ? [] : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        tagTarget = nil
        if drag?.fromMap == false { drag = nil; dragged = []; reload() }
        needsDisplay = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        if drag?.fromMap == false { drag = nil; dragged = []; reload() }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = sender.draggingPasteboard.string(forType: dragType) else { return false }
        let parts = s.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        if parts[0] == "tag" {
            guard let k = tagTarget else { return false }
            tagTarget = nil
            if !store.map.hasTag(k, parts[1]) { store.map.toggleTag(k, parts[1]) }
            changed(select: k)
            return true
        }
        guard let d = drag, !d.fromMap, let t = d.to else { return false }
        drag = nil
        land(d, t)
        dragged = []
        reload()
        changed(select: d.key)
        if d.keys.count > 1 { setSelection(Set(d.keys), lead: d.key) }
        return true
    }
}

/// A menu item that runs a closure (the shortcut is shown for reference; the map handles the keys).
final class MenuAction: NSMenuItem {
    private let run: () -> Void
    init(title: String, key: String = "", mods: NSEvent.ModifierFlags = [], _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = mods
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
