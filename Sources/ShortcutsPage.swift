import Cocoa

// Settings → Shortcuts: every shortcut by where it works (ShortcutTable), its keys drawn as keycaps, and a small
// stage that acts each one out on a sample map, list and timeline, so you can see where and how it's used. Rows are
// for reading: clicking one plays its demo, nothing here runs a shortcut.

/// A shortcut's keys, drawn as keycaps, right-aligned; the ones the demo presses light up while they're down.
final class KeyComboView: NSView {
    var parts: [KeyPart] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// The keys going down in the demo (nil: none).
    var pressed: [KeyPart]? { didSet { if pressed != oldValue { needsDisplay = true } } }
    var dimmed = false { didSet { needsDisplay = true } }
    init(_ parts: [KeyPart]) {
        self.parts = parts
        super.init(frame: .zero)
        setAccessibilityElement(false)                      // the row speaks for its keys
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Keycaps.width(parts, .list), height: Keycaps.Size.list.height) }
    override func draw(_ dirtyRect: NSRect) {
        let w = Keycaps.width(parts, .list)
        let lit = pressed.map { Keycaps.litKeys(parts, pressed: $0) }
        Keycaps.draw(parts, at: NSPoint(x: max(0, bounds.maxX - w), y: (bounds.height - Keycaps.Size.list.height) / 2), .list, litOnly: lit, alpha: dimmed ? 0.45 : 1)
    }
}

/// One row of the legend: its keys, what it does; hover plays its demo, a click pins it.
final class ShortcutRowView: NSView {
    let row: ShortcutRow
    let keys: KeyComboView
    private let text: NSTextField
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var playing = false { didSet { if playing != oldValue { needsDisplay = true; sayState() } } }
    var pinned = false { didSet { if pinned != oldValue { needsDisplay = true; sayState() } } }
    var onHover: ((ShortcutRowView, Bool) -> Void)?
    var onClick: ((ShortcutRowView) -> Void)?
    /// ↑ ↓ on a focused row: the row before / after (-1 / 1). Esc: let the pinned row go.
    var onStep: ((ShortcutRowView, Int) -> Void)?
    var onEscape: (() -> Void)?

    init(_ row: ShortcutRow, keysWidth: CGFloat = 196) {
        self.row = row
        keys = KeyComboView(row.parts)
        keys.dimmed = row.dimmed
        text = NSTextField(labelWithString: row.label)
        super.init(frame: NSRect(x: 0, y: 0, width: 504, height: 24))
        text.font = .systemFont(ofSize: 13)
        text.textColor = row.dimmed ? .secondaryLabelColor : .labelColor
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        [keys, text].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 504), heightAnchor.constraint(equalToConstant: 24),
            keys.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), keys.widthAnchor.constraint(equalToConstant: keysWidth),
            keys.topAnchor.constraint(equalTo: topAnchor), keys.bottomAnchor.constraint(equalTo: bottomAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: keysWidth + 18), text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = row.label + "\n" + row.note
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.label + tr("，", ", ") + Keycaps.spoken(row.parts))
        setAccessibilityHelp(row.note)
    }

    // the keyboard: Tab reaches the rows; space or Return plays and pins one, ↑ ↓ move, Esc lets go
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { NSRect(x: 0, y: 1, width: bounds.width, height: bounds.height - 2) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 6, yRadius: 6).fill() }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49, 36, 76: onClick?(self)
        case 125: onStep?(self, 1)
        case 126: onStep?(self, -1)
        default: super.keyDown(with: e)
        }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    /// What it's doing, for VoiceOver.
    private func sayState() { setAccessibilityValue(pinned ? tr("已固定", "Pinned") : playing ? tr("正在演示", "Playing") : nil) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovered = true; onHover?(self, true) }
    override func mouseExited(with e: NSEvent) { hovered = false; onHover?(self, false) }
    override func mouseDown(with e: NSEvent) { onClick?(self) }
    override func accessibilityPerformPress() -> Bool { onClick?(self); return true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered || playing || pinned else { return }
        let p = NSBezierPath(roundedRect: NSRect(x: 0, y: 1, width: bounds.width, height: bounds.height - 2), xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(pinned ? 0.12 : playing ? 0.09 : 0.04).setFill(); p.fill()
        if pinned { NSColor.labelColor.withAlphaComponent(0.25).setStroke(); p.lineWidth = 1; p.stroke() }
        // the row the stage plays: a bar at its start, so it's plain which one it is
        if playing || pinned { NSColor.labelColor.setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: 5, width: 2.5, height: bounds.height - 10), xRadius: 1.2, yRadius: 1.2).fill() }
    }
}

/// A place's rows (with Anywhere's two headings), top-aligned.
final class ShortcutLegendView: NSView {
    private(set) var rowViews: [ShortcutRowView] = []
    init(_ rows: [ShortcutRow], keysWidth: CGFloat) {
        super.init(frame: .zero)
        var y: CGFloat = 0
        var views: [NSView] = []
        for r in rows {
            if let s = r.section {
                let h = SectionHeading(s)
                h.frame = NSRect(x: 0, y: y, width: 504, height: 22)
                views.append(h); y += 22
            }
            let v = ShortcutRowView(r, keysWidth: keysWidth)
            v.translatesAutoresizingMaskIntoConstraints = true
            v.frame = NSRect(x: 0, y: y, width: 504, height: 24)
            rowViews.append(v); views.append(v); y += 24
        }
        views.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// A small heading with a rule after it.
    private final class SectionHeading: NSView {
        let text: String
        init(_ text: String) {
            self.text = text
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(text)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let f = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let s = text.size(withAttributes: [.font: f])
            (text as NSString).draw(at: NSPoint(x: 0, y: (bounds.height - s.height) / 2), withAttributes: [.font: f, .foregroundColor: NSColor.secondaryLabelColor])
            NSColor.separatorColor.setFill()
            NSRect(x: s.width + 8, y: bounds.midY, width: max(0, bounds.width - s.width - 8), height: 1).fill()
        }
    }
}

/// The page: the hotkey row on top, then where (a picker), the stage, a caption and that place's rows. The stage plays
/// the rows in turn; hovering one plays it, a click pins it (click again, or Esc, to let it go on).
final class ShortcutsPage: NSObject {
    let view: NSView
    private let stage = ShortcutStage(frame: NSRect(x: 0, y: 0, width: 504, height: 220))
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let picker: NSSegmentedControl
    private let legendBox = NSView()
    private var legends: [ShortcutPlace: ShortcutLegendView] = [:]
    private var place: ShortcutPlace
    private weak var playing: ShortcutRowView?
    private weak var pinned: ShortcutRowView?
    private var dwell: DispatchWorkItem?
    private static let placeKey = "ShortcutsPlace"

    init(top: NSView) {
        place = ShortcutPlace(rawValue: UserDefaults.standard.object(forKey: Self.placeKey) as? Int ?? 1) ?? .mapKeys
        picker = NSSegmentedControl(labels: ShortcutPlace.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        let stack = NSStackView()
        view = stack
        super.init()
        for p in ShortcutPlace.allCases {
            picker.setImage(NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular)), forSegment: p.rawValue)
            picker.setImageScaling(.scaleProportionallyDown, forSegment: p.rawValue)
            picker.setToolTip(p.tip, forSegment: p.rawValue)
        }
        picker.segmentDistribution = .fillEqually
        picker.selectedSegment = place.rawValue
        picker.target = self
        picker.action = #selector(picked)
        // fits the page whatever the language: drop the icons if the words don't fit
        if picker.fittingSize.width > 504 { for p in ShortcutPlace.allCases { picker.setImage(nil, forSegment: p.rawValue) } }

        caption.font = .systemFont(ofSize: 12)
        caption.textColor = .secondaryLabelColor
        caption.maximumNumberOfLines = 3
        caption.preferredMaxLayoutWidth = 504
        caption.lineBreakMode = .byWordWrapping              // two lines, the second cut with …
        caption.cell?.truncatesLastVisibleLine = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for v in [top, picker, stage, caption, legendBox] as [NSView] { stack.addArrangedSubview(v) }
        stack.setCustomSpacing(16, after: top)
        stack.setCustomSpacing(6, after: stage)
        stack.setCustomSpacing(8, after: caption)
        for (v, h) in [(stage as NSView, 220.0), (caption, 47.0), (legendBox, 240.0)] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 504).isActive = true
            v.heightAnchor.constraint(equalToConstant: h).isActive = true
        }
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.widthAnchor.constraint(equalToConstant: 504).isActive = true
        stack.setContentHuggingPriority(.required, for: .vertical)

        stage.onLit = { [weak self] parts in self?.playing?.keys.pressed = parts }
        stage.onPassEnded = { [weak self] in self?.next() }
        buildLegends()
        show(place)
    }

    /// The rows again (the hotkey changed, or was switched on or off): the same place, its first row.
    func rebuild() {
        legends.values.forEach { $0.removeFromSuperview() }
        legends = [:]
        buildLegends()
        show(place)
    }

    private func buildLegends() {
        legendBox.wantsLayer = false
        // one keys column for every place, as wide as the widest combo (never squeezed, never past the page)
        let keysWidth = min(250, max(150, ShortcutTable.all().map { Keycaps.width($0.parts, .list) }.max() ?? 196))
        for p in ShortcutPlace.allCases {
            let l = ShortcutLegendView(ShortcutTable.rows(in: p), keysWidth: keysWidth)
            l.isHidden = true
            for r in l.rowViews {
                r.onHover = { [weak self] v, on in self?.hover(v, on) }
                r.onClick = { [weak self] v in self?.click(v) }
                r.onStep = { [weak self] v, d in self?.step(from: v, d) }
                r.onEscape = { [weak self] in self?.pin(nil) }
            }
            legendBox.addSubview(l)
            // pinned to the box's top (an autoresizing frame would grow with the box from zero and slide up over the stage)
            l.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([l.topAnchor.constraint(equalTo: legendBox.topAnchor), l.leadingAnchor.constraint(equalTo: legendBox.leadingAnchor),
                                         l.widthAnchor.constraint(equalToConstant: 504), l.heightAnchor.constraint(equalToConstant: 240)])
            legends[p] = l
        }
    }

    @objc private func picked() {
        guard let p = ShortcutPlace(rawValue: picker.selectedSegment) else { return }
        UserDefaults.standard.set(p.rawValue, forKey: Self.placeKey)
        show(p)
    }

    private func show(_ p: ShortcutPlace) {
        place = p
        for (q, l) in legends { l.isHidden = q != p }
        pin(nil)
        if let first = legends[p]?.rowViews.first { play(first) }
    }

    /// ↑ ↓ on a focused row: the next one gets the keys and plays.
    private func step(from r: ShortcutRowView, _ d: Int) {
        guard let rows = legends[place]?.rowViews, let i = rows.firstIndex(where: { $0 === r }) else { return }
        let j = max(0, min(rows.count - 1, i + d))
        guard j != i else { return }
        rows[j].window?.makeFirstResponder(rows[j])
        if pinned != nil { pin(rows[j]) }
        play(rows[j])
    }

    private func play(_ r: ShortcutRowView) {
        playing?.playing = false
        playing?.keys.pressed = nil
        playing = r
        r.playing = true
        caption.stringValue = r.row.note
        caption.toolTip = r.row.note
        stage.play(DemoScenes.slice(r.row.id))
    }

    /// The pass ended: the pinned row again, else the next one (round the place).
    private func next() {
        if let p = pinned { play(p); return }
        guard let rows = legends[place]?.rowViews, !rows.isEmpty else { return }
        if let cur = playing, cur.hovered { play(cur); return }
        let i = playing.flatMap { r in rows.firstIndex { $0 === r } } ?? -1
        play(rows[(i + 1) % rows.count])
    }

    private func hover(_ r: ShortcutRowView, _ on: Bool) {
        dwell?.cancel()
        guard on, r !== playing else { return }
        let w = DispatchWorkItem { [weak self, weak r] in
            guard let self, let r, r.hovered else { return }
            self.play(r)
        }
        dwell = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func click(_ r: ShortcutRowView) {
        if pinned === r { pin(nil); return }
        pin(r)
        play(r)
    }

    private func pin(_ r: ShortcutRowView?) {
        pinned?.pinned = false
        pinned = r
        r?.pinned = true
    }
}
