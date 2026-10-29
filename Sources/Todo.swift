import Cocoa

/// Something you could do so Kikumap works fully: what to do, what doesn't work until then, and a button that
/// does it. It's up to you: an ignored one is only counted again once you ask for it back.
struct Todo {
    let id: String
    let title: String
    let impact: String
    var action: (title: String, run: () -> Void)?
}

@MainActor
enum Todos {
    static var ignored: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "IgnoredTodos") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "IgnoredTodos") }
    }

    static func ignore(_ id: String, _ on: Bool) {
        if on { ignored.insert(id) } else { ignored.remove(id) }
    }

    /// The ones not ignored.
    static func open(_ all: [Todo]) -> [Todo] {
        let skip = ignored
        return all.filter { !skip.contains($0.id) }
    }
}

/// The ▸ in the top bar: how many to-dos are open (muted when they're all ignored); a click lists them.
final class TodoButton: NSButton {
    var count = 0 { didSet { if count != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    private var label: String { tr("待办", "To-do") + (count > 0 ? " · \(count)" : "") }

    convenience init(target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        toolTip = tr("哪些事还没做，没做会影响什么；做不做由你决定", "What's left to do and what it affects; up to you whether to do it")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.size(Theme.ui(12, .medium)).width) + 32, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (isHighlighted ? Theme.hover : Theme.paper).setFill(); p.fill()
        Theme.line.setStroke(); p.lineWidth = 1; p.stroke()
        let c = count > 0 ? Theme.ink : Theme.muted
        // the small triangle, pointing right
        let tri = NSBezierPath()
        let tx = r.minX + 10, ty = bounds.midY
        tri.move(to: NSPoint(x: tx, y: ty - 4)); tri.line(to: NSPoint(x: tx + 6, y: ty)); tri.line(to: NSPoint(x: tx, y: ty + 4)); tri.close()
        c.setFill(); tri.fill()
        let f = Theme.ui(12, .medium)
        let s = label.size(f)
        (label as NSString).draw(at: NSPoint(x: tx + 11, y: bounds.midY - s.height / 2), withAttributes: [.font: f, .foregroundColor: c])
    }
}

/// The list the ▸ opens: each to-do with what it affects, a button that does it, and Ignore; the ignored ones
/// below, each with Remind me.
@MainActor
final class TodoPopover: NSObject {
    private let popover = NSPopover()
    private var items: [Todo] = []
    private var changed: (() -> Void)?

    func show(_ todos: [Todo], from view: NSView, changed: @escaping () -> Void) {
        items = todos
        self.changed = changed
        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = build()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    private func rebuild() {
        guard popover.isShown else { return }
        popover.contentViewController?.view = build()
    }

    private func build() -> NSView {
        let width: CGFloat = 340
        let ignored = Todos.ignored
        let open = items.filter { !ignored.contains($0.id) }, quiet = items.filter { ignored.contains($0.id) }
        var views: [NSView] = []
        func label(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = font
            l.textColor = color
            l.preferredMaxLayoutWidth = width
            l.isSelectable = false
            return l
        }
        views.append(label(open.isEmpty ? tr("没有要做的事。", "Nothing to do.") : tr("待办", "To-do"), Theme.ui(13, .semibold), Theme.ink))
        for t in open {
            let buttons = NSStackView()
            buttons.spacing = 8
            if let a = t.action {
                buttons.addArrangedSubview(ClosureButton(title: a.title) { [weak self] in self?.popover.close(); a.run() })
            }
            buttons.addArrangedSubview(ClosureButton(title: tr("忽略", "Ignore")) { [weak self] in
                Todos.ignore(t.id, true); self?.changed?(); self?.rebuild()
            })
            let block = NSStackView(views: [label(t.title, Theme.ui(12.5, .semibold), Theme.ink), label(t.impact, Theme.ui(11.5), Theme.muted), buttons])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 5
            views.append(block)
        }
        if !quiet.isEmpty {
            views.append(label(tr("已忽略", "Ignored"), Theme.ui(11.5, .semibold), Theme.muted))
            for t in quiet {
                let row = NSStackView(views: [label(t.title, Theme.ui(12), Theme.muted),
                                              ClosureButton(title: tr("再提醒我", "Remind me")) { [weak self] in
                                                  Todos.ignore(t.id, false); self?.changed?(); self?.rebuild()
                                              }])
                row.spacing = 8
                views.append(row)
            }
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        stack.setFrameSize(stack.fittingSize)
        return stack
    }
}
