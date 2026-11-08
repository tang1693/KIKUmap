import Cocoa

// Settings → Access: what KIKUmap can be given, the one it needs first. Each item: its name (a red asterisk after the
// one it needs, a gray "(Optional)" after the rest), whether it's on, "▶ See it" and its button on one line, and under
// it one short line saying what you get (the whole story on hover). "▶ See it", or a click on the item's words,
// plays on the picture at the top what the item gets you: Settings → Shortcuts' own picture (ShortcutStage, with
// DemoScenes.access), so it plays only when clicked, once, up from black and back to black.

/// One item of Settings → Access: its name, whether KIKUmap needs it, what you get (one short line), the whole story
/// (on hover), its button, and its demo (DemoScenes.access, by `id`).
struct AccessItem {
    enum Need { case required, optional, experimental }
    let id: String
    let title: String
    let need: Need
    let short: String
    let full: String
    let action: String

    /// The gray words after the name; nil: the item KIKUmap needs (a red asterisk instead).
    var marker: String? {
        switch need {
        case .required: return nil
        case .optional: return tr("（可选）", "(Optional)")
        case .experimental: return tr("（可选 · 试验性）", "(Optional · experimental)")
        }
    }

    /// The name as VoiceOver says it: whether it's needed, in words (`required`: needed on this Mac).
    func spoken(required: Bool) -> String {
        switch need {
        case .required: return required ? title + tr("，必需", ", required") : title
        case .optional: return title + tr("，可选", ", optional")
        case .experimental: return title + tr("，可选，试验性", ", optional, experimental")
        }
    }

    /// Every item, in the page's order: the one KIKUmap needs, then what it can do more with.
    static var all: [AccessItem] {
        let open = tr("打开设置", "Open Settings"), connect = tr("连接", "Connect")
        return [
            AccessItem(id: "accessibility", title: tr("辅助功能", "Accessibility"), need: .required,
                       short: tr("读 Claude 和 ChatGPT 窗口里的对话列表，看出哪个在跑、哪个做完了。不开的话，KIKUmap 看不到 Claude App 里的对话。",
                                 "Reads the chat lists in Claude's and ChatGPT's windows to see which chats are running or done. Without it, KIKUmap can't see your Claude app chats."),
                       full: tr("用来读 Claude App 窗口里的对话列表：哪些对话还在跑，哪些你在 Claude 里看过了；也读 ChatGPT 窗口里的对话列表：它的普通对话在不在跑、有没有未读。会话所在的编辑器或终端在最前面时，还读它的窗口标题，判断你有没有看到做完的会话。",
                                "Lets KIKUmap read the chat list in the Claude app's window: which chats are still running and which you've read there. It also reads the list in ChatGPT's window: whether its ordinary chats are running or unread. While a session's editor or terminal is in front, it reads that app's window titles too, to tell whether you've seen a finished session there."),
                       action: open),
            AccessItem(id: "fullDisk", title: tr("完全磁盘访问", "Full Disk Access"), need: .optional,
                       short: tr("Claude 问「允许吗？」或等你回答时提醒你，Claude 的窗口关着也行。",
                                 "Tells you when Claude asks \"Allow this?\" or waits for your answer, even with its window closed."),
                       full: tr("可选。用来读通知中心里 Claude 发的通知：Claude 问「允许吗？」或等你回答时提醒你；Claude App 里的 Cowork 任务做完了，窗口关着也知道（普通对话回复完，Claude 不发通知）。只读，不上传。",
                                "Optional. Lets KIKUmap read Claude's notifications in Notification Center: you're told when Claude asks \"Allow this?\" or waits for your answer, and KIKUmap knows when a Cowork task in the Claude app finishes, even with its window closed (Claude sends no notification when an ordinary chat's reply finishes). Read-only, never uploaded."),
                       action: open),
            AccessItem(id: "claudeCode", title: "Claude Code", need: .optional,
                       short: tr("终端、VS Code 里的 Claude Code 会话也会列在左栏，显示在跑、做完。",
                                 "Claude Code sessions in Terminal or VS Code show in the left column, running or done."),
                       full: tr("在 Claude Code 的设置（~/.claude/settings.json）里加几行，让终端、VS Code 里的 Claude Code 会话也显示「在跑 / 未读」。原文件会先备份。只对之后新开的会话有用。",
                                "Adds a few lines to Claude Code's settings (~/.claude/settings.json) so Claude Code sessions in Terminal or VS Code show running / unread too. The old file is backed up first. Works for sessions started afterward."),
                       action: connect),
            // (a chat in the ChatGPT app, Codex or not, shows only once it's pinned there; a Codex session started in an
            // editor or a terminal shows like a Claude Code session: Store.isShown)
            AccessItem(id: "chatGPT", title: "ChatGPT", need: .optional,
                       short: tr("显示你在 ChatGPT App 里置顶的对话（其中的 Codex 对话看得出在跑、做完），还有编辑器、终端里的 Codex 会话。只读，不上传。",
                                 "Shows the chats you pin in the ChatGPT app (Codex ones show running and done), plus Codex sessions in your editor or terminal. Read-only, no uploads."),
                       full: tr("读 ChatGPT 桌面 App 存在这台 Mac 上的记录（~/.codex，只读）：你在 App 里置顶的对话，还有 Codex 对话（包括 VS Code、终端里的 Codex）的列表、未读和用量；小组件也能显示 ChatGPT 的用量。Codex 对话最准：窗口关着，「在跑 / 未读」也对。普通对话的「在跑 / 未读」只能从 ChatGPT 的窗口里看（要开「辅助功能」，窗口要露出一部分），点它会打开 ChatGPT。不改任何东西，不上传。",
                                "Reads what the ChatGPT desktop app keeps on this Mac (~/.codex, read-only): the chats you pin in the app, plus Codex chats' list, unread and usage (Codex in VS Code or the terminal too). The widget can show ChatGPT's usage as well. Codex chats work best: running / unread stay right even with the window closed. For ordinary chats, running / unread can only be read off ChatGPT's window (with Accessibility, while part of it shows), and clicking one brings up ChatGPT. Changes nothing, uploads nothing."),
                       action: connect),
            AccessItem(id: "usage", title: tr("Claude 用量", "Claude usage"), need: .optional,
                       short: tr("显示 Claude 套餐用了多少、什么时候重置。借用 Claude Code 的登录，可能不被允许。",
                                 "Shows how much of your Claude plan you've used and when it resets. Uses Claude\u{00A0}Code's sign-in, which may not be allowed."),
                       full: tr("可选，默认关闭。关着时不显示 Claude 的用量和计划任务（这台 Mac 上没有别的地方能读到）。需要 Claude 付费套餐，并在这台 Mac 的 Claude Code 里登录（免费套餐和 API key 没有用量可看）。开启后借用 Claude Code 存在钥匙串里的登录，每 10 分钟查一次用量和计划任务；只读，只发给 api.anthropic.com。Anthropic 不允许第三方应用收集 Claude 的登录信息：KIKUmap 只在本机读、不保存，但仍可能不被允许、被限制。",
                                "Optional, off by default. While it's off, Claude's usage and scheduled tasks aren't shown (nothing else on this Mac has them). Needs a paid Claude plan signed in to Claude Code on this Mac (the Free plan and API keys have no usage to show). When on, it uses Claude Code's sign-in from the Keychain to look up usage and scheduled tasks every 10 minutes. Read-only, sent only to api.anthropic.com. Anthropic doesn't allow third-party apps to collect Claude sign-ins: KIKUmap only reads it on this Mac and never saves it, but this may still not be allowed and could be blocked."),
                       action: connect),
            AccessItem(id: "gptUsage", title: tr("ChatGPT 用量", "ChatGPT usage"), need: .experimental,
                       short: tr("每 10 分钟更新 ChatGPT 用量，不用等下次跑 Codex。接口是 OpenAI 没公开的，可能失效。",
                                 "Updates ChatGPT's usage every 10 minutes, without waiting for your next Codex task. Uses an interface OpenAI hasn't published, so it may stop working."),
                       full: tr("可选，默认关闭。关着时，ChatGPT 的用量只在你用 Codex 跑任务时更新（从 Codex 在这台 Mac 上的记录里读）；用量重置后，要等下次用 Codex 才有新数字。开启后借用 Codex 存在这台 Mac 上的 ChatGPT 登录（~/.codex/auth.json），每 10 分钟向 OpenAI 查一次；只读，只发给 chatgpt.com。用的是 OpenAI 没公开的接口，OpenAI 也没说允许别的应用这样用，可能失效或被限制。",
                                "Optional, off by default. While it's off, ChatGPT's usage updates only when you run a Codex task (read from Codex's records on this Mac); after a reset, new numbers show only once you use Codex again. When on, it uses the ChatGPT sign-in Codex keeps on this Mac (~/.codex/auth.json) to ask OpenAI every 10 minutes. Read-only, sent only to chatgpt.com. It's an interface OpenAI hasn't published or said other apps may use, so it may stop working or be blocked."),
                       action: connect),
        ]
    }
}

/// One item of Settings → Access: its name and marker, whether it's on, "▶ See it" and its button on the first line,
/// what you get under them (the whole story on hover). A state too long to share the first line takes one of its own
/// under it. A click on the item's words, or "▶ See it", plays its demo once, as a Shortcuts row does; hovering only
/// highlights it; the one playing gets the same bar, fill and VoiceOver value as a Shortcuts row.
final class AccessRowView: NSView {
    let item: AccessItem
    let title: NSTextField
    /// The red asterisk, or the gray "(Optional)".
    let marker: NSTextField
    let status: NSTextField
    let short: NSTextField
    let seeIt: NSButton
    let action: NSButton
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    var mark = ShortcutRowView.Mark.none { didSet { if mark != oldValue { needsDisplay = true; sayState() } } }
    var onClick: ((AccessRowView) -> Void)?
    /// ↑ ↓ on a focused item: the focus goes to the one before / after (-1 / 1). Esc: stop the demo.
    var onStep: ((AccessRowView, Int) -> Void)?
    var onEscape: (() -> Void)?
    /// The state has a line of its own (it doesn't fit beside the name and the buttons).
    private(set) var statusBelow = false
    /// The asterisk shows: KIKUmap needs this item on this Mac (only the required one has one).
    private(set) var required = true

    private let head: NSStackView
    private let lines: NSStackView
    private static let width: CGFloat = 504, inset: (left: CGFloat, right: CGFloat) = (10, 6)
    /// Every item's button as wide as the widest title one can have (in this language), so the buttons and "▶ See it"
    /// line up down the page.
    static var actionWidth: CGFloat {
        [tr("打开设置", "Open Settings"), tr("连接", "Connect"), tr("重新读取", "Read again")]
            .map { ClosureButton(title: $0, {}).intrinsicContentSize.width }.max() ?? 100
    }

    init(_ item: AccessItem, run: @escaping () -> Void) {
        self.item = item
        title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        marker = NSTextField(labelWithString: item.marker ?? "*")
        marker.font = item.marker == nil ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12)
        marker.textColor = item.marker == nil ? .systemRed : .secondaryLabelColor
        marker.setAccessibilityElement(false)                // the name says it in words
        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.lineBreakMode = .byTruncatingTail
        short = NSTextField(wrappingLabelWithString: item.short)
        short.isSelectable = false                          // a click on it plays the demo, as on the name
        short.font = .systemFont(ofSize: 11.5)
        short.textColor = .secondaryLabelColor
        short.preferredMaxLayoutWidth = Self.width - Self.inset.left - Self.inset.right - 2
        short.setContentCompressionResistancePriority(.required, for: .vertical)
        short.toolTip = item.full
        seeIt = NSButton(title: "", target: nil, action: nil)
        action = ClosureButton(title: item.action, run)
        action.widthAnchor.constraint(equalToConstant: Self.actionWidth).isActive = true
        head = NSStackView(views: [title, marker, status])
        let line = NSStackView()
        lines = NSStackView(views: [line, short])
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 44))
        seeIt.target = self
        seeIt.action = #selector(seeItClicked)
        seeIt.isBordered = false
        seeIt.attributedTitle = NSAttributedString(string: AccessPage.seeItTitle, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.linkColor])
        seeIt.setAccessibilityLabel(tr("看看「\(item.title)」有什么用", "See what \(item.title) does"))
        seeIt.toolTip = tr("在上面的画面里演示一遍", "Plays it once in the picture above")
        head.spacing = 10
        head.setCustomSpacing(item.marker == nil ? 2 : 3, after: title)
        head.alignment = .firstBaseline
        head.setHuggingPriority(.defaultLow, for: .horizontal)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.setViews([head], in: .leading)
        line.setViews([seeIt, action], in: .trailing)
        line.spacing = 10
        line.setCustomSpacing(8, after: seeIt)
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1
        lines.setHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        for v in [line, lines] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(lines)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset.left),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset.right),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            line.widthAnchor.constraint(equalTo: lines.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setRequired(true)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// The asterisk (and "required" for VoiceOver) only while KIKUmap needs this on this Mac.
    func setRequired(_ on: Bool) {
        required = on && item.need == .required
        marker.isHidden = item.need == .required && !required
        head.setCustomSpacing(marker.isHidden ? 10 : (item.marker == nil ? 2 : 3), after: title)
        title.setAccessibilityLabel(item.spoken(required: required))
        setAccessibilityLabel(item.spoken(required: required))
        relayout()
    }

    /// What the item's state is now: its words (on hover, why), dark while it works; its button's title and whether
    /// it can be clicked. Whether the state moved to or from a line of its own.
    @discardableResult
    func show(_ text: String, on: Bool, why: String?, button: String?, enabled: Bool) -> Bool {
        if status.stringValue != text { status.stringValue = text }
        status.textColor = on ? .labelColor : .secondaryLabelColor
        status.toolTip = why
        if let t = button, action.title != t { action.title = t }
        action.isEnabled = enabled
        return relayout()
    }

    /// Beside the name while it fits there (the name and marker, then the buttons, are never squeezed); else on a
    /// line of its own under them. Whether that changed.
    @discardableResult
    func relayout() -> Bool {
        let room = Self.width - Self.inset.left - Self.inset.right - seeIt.intrinsicContentSize.width - 8 - max(action.intrinsicContentSize.width, Self.actionWidth) - 10
        let name = title.intrinsicContentSize.width + (marker.isHidden ? 0 : (item.marker == nil ? 2 : 3) + marker.intrinsicContentSize.width)
        let below = !status.stringValue.isEmpty && name + 10 + status.intrinsicContentSize.width > room
        guard below != statusBelow else { return false }
        statusBelow = below
        (below ? head : lines).removeArrangedSubview(status)
        status.removeFromSuperview()
        if below { lines.insertArrangedSubview(status, at: 1) } else { head.addArrangedSubview(status) }
        invalidateIntrinsicContentSize()
        return true
    }

    @objc private func seeItClicked() { press() }

    // the keyboard: Tab reaches the item (a click on its words focuses it too); space or Return plays it, ↑ ↓ move
    // the focus, Esc stops the demo
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { NSRect(x: 0, y: 1, width: bounds.width, height: bounds.height - 2) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 6, yRadius: 6).fill() }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49, 36, 76: if !e.isARepeat { onClick?(self) }  // (held down: once)
        case 125: onStep?(self, 1)
        case 126: onStep?(self, -1)
        default: super.keyDown(with: e)
        }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    /// What it's doing, for VoiceOver: "Playing" while its demo plays (on the item and its "▶ See it"), nothing otherwise.
    private func sayState() {
        let v = mark == .playing ? tr("正在演示", "Playing") : nil
        setAccessibilityValue(v)
        seeIt.setAccessibilityValue(v)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    // hovering only highlights: a demo plays when it's clicked
    override func mouseEntered(with e: NSEvent) { hovered = true }
    override func mouseExited(with e: NSEvent) { hovered = false }
    /// A click on the item's words (they never take the focus, so AppKit leaves it where it was): the item takes it,
    /// so Esc stops the demo it starts. Its buttons handle their own clicks.
    override func mouseDown(with e: NSEvent) { press() }
    override func accessibilityPerformPress() -> Bool { press(); return true }
    private func press() {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        onClick?(self)
    }

    override func draw(_ dirtyRect: NSRect) { ShortcutRowView.drawMark(in: bounds, hovered: hovered, mark: mark) }
}

/// The page: the picture, the legend, the items, then what's put under them (the tip, the buttons that turn things
/// off). Nothing plays by itself (not when the page opens, an item is hovered or Settings comes back).
final class AccessPage: NSObject {
    let view = NSStackView()
    let stage = ShortcutStage(frame: NSRect(x: 0, y: 0, width: 504, height: AccessPage.stageHeight))
    /// A red asterisk: required (hidden while nothing is), lined up with the items' names.
    let legend = NSTextField(labelWithString: "")
    private let legendLine = NSStackView()
    private(set) var rows: [AccessRowView] = []
    /// The item last clicked: the picture is about it (nil: none yet).
    private(set) weak var chosen: AccessRowView?
    /// Shorter than Shortcuts' picture, so the page fits a small screen.
    static let stageHeight: CGFloat = 176

    static var hint: String { tr("点一项的「▶ 看看」，看它有什么用", "Click \"▶ See it\" on an item to see what it does") }
    static var seeItTitle: String { tr("▶ 看看", "▶ See it") }

    /// `rows`: the items with their buttons' actions; `below`: what goes under them.
    init(_ items: [(AccessItem, () -> Void)], below: [NSView]) {
        super.init()
        stage.idleHint = Self.hint
        let required = NSMutableAttributedString(string: "* ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.systemRed])
        required.append(NSAttributedString(string: tr("必需", "Required"), attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
        legend.attributedStringValue = required
        legend.setAccessibilityElement(false)               // (each item's name says required or optional in words)
        rows = items.map { item, run in
            let r = AccessRowView(item, run: run)
            r.onClick = { [weak self] v in self?.play(v) }
            r.onStep = { [weak self] v, d in self?.step(from: v, d) }
            r.onEscape = { [weak self] in self?.stage.stop() }
            return r
        }
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 2
        legendLine.addArrangedSubview(legend)
        legendLine.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)
        for v in [stage, legendLine] + rows + below { view.addArrangedSubview(v) }
        view.setCustomSpacing(8, after: stage)
        view.setCustomSpacing(2, after: legendLine)
        if let last = rows.last { view.setCustomSpacing(12, after: last) }
        for v in below.dropLast() { view.setCustomSpacing(10, after: v) }
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.widthAnchor.constraint(equalToConstant: 504).isActive = true
        stage.heightAnchor.constraint(equalToConstant: Self.stageHeight).isActive = true
        legend.setContentHuggingPriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        stage.onChange = { [weak self] in self?.marks() }
        stage.reset()
    }

    /// Whether an item is needed on this Mac (only Accessibility can be): its asterisk and the legend (nothing is
    /// required otherwise).
    func setRequired(_ on: Bool) {
        legend.isHidden = !on
        legendLine.isHidden = !on
        rows.forEach { $0.setRequired(on) }
    }

    /// An item clicked (its words, "▶ See it", or Return / space on it): its demo once, from the start.
    func play(_ r: AccessRowView) {
        chosen = r
        stage.play(DemoScenes.access(r.item.id), title: r.item.title)
        marks()
    }

    /// ↑ ↓ on a focused item: the focus moves on (Return or space plays that one).
    private func step(from r: AccessRowView, _ d: Int) {
        guard let i = rows.firstIndex(where: { $0 === r }) else { return }
        let j = max(0, min(rows.count - 1, i + d))
        guard j != i else { return }
        rows[j].window?.makeFirstResponder(rows[j])
    }

    /// Each item follows the picture: the one chosen playing, paused or done; the rest plain.
    private func marks() {
        let m: ShortcutRowView.Mark = !stage.isPlaying ? .done : stage.paused ? .paused : .playing
        for r in rows { r.mark = r === chosen && stage.slice != nil ? m : .none }
    }
}
