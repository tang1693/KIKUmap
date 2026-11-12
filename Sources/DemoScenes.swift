import Cocoa

// The demos on Settings → Shortcuts, one per row of ShortcutTable: a sample map, list and timeline, and the steps
// that act a shortcut out. Each one follows what the real code does (named by the row's id). Settings → Access's,
// one per item (`access`), act out what the item gets you.

extension DemoWorld {
    mutating func node(_ id: String) -> Int? { nodes.firstIndex { $0.id == id } }
    /// Adds an item to `parent`'s items: after `after`, before `before`, or at the end.
    mutating func add(_ n: DemoNode, after: String? = nil, before: String? = nil) {
        if let a = after, let i = node(a) {
            // after the sibling and everything under it
            var j = i + 1
            func under(_ id: String) -> Bool { var p = nodes.first { $0.id == id }?.parent; while let q = p { if q == a { return true }; p = nodes.first { $0.id == q }?.parent }; return false }
            while j < nodes.count, under(nodes[j].id) { j += 1 }
            nodes.insert(n, at: j)
        } else if let b = before, let i = node(b) {
            nodes.insert(n, at: i)
        } else {
            nodes.append(n)
        }
    }
    /// Takes an item away, with everything under it; returns them (for putting back).
    @discardableResult
    mutating func remove(_ id: String) -> [DemoNode] {
        var gone: Set<String> = [id], changed = true
        while changed { changed = false; for n in nodes where !gone.contains(n.id) && n.parent.map(gone.contains) == true { gone.insert(n.id); changed = true } }
        let out = nodes.filter { gone.contains($0.id) }
        nodes.removeAll { gone.contains($0.id) }
        sel.subtract(gone)
        return out
    }
    /// Moves an item (and what's under it) into `parent`, after `after` or at the end.
    mutating func move(_ id: String, into parent: String, after: String? = nil, before: String? = nil) {
        var moved = remove(id)
        guard !moved.isEmpty else { return }
        moved[0].parent = parent
        if parent == "root" { moved[0].kind = moved[0].kind == .chat ? .chat : .topic } else if moved[0].kind == .topic { moved[0].kind = .sub }
        add(moved[0], after: after, before: before)
        var last = moved[0].id
        for n in moved.dropFirst() { add(n, after: nil); last = n.id }
        _ = last
    }
    mutating func title(_ id: String, _ t: String) { if let i = node(id) { nodes[i].title = t } }
    mutating func pick(_ id: String?) { sel = id.map { [$0] } ?? [] }
}

enum DemoScenes {
    // the sample: two topics on the map, five chats in the list, three runs on the timeline
    static func base() -> DemoWorld {
        var w = DemoWorld()
        w.nodes = [
            DemoNode(id: "root", title: "", parent: nil, kind: .root),
            DemoNode(id: "work", title: tr("工作", "Work"), parent: "root", kind: .topic),
            DemoNode(id: "weekly", title: tr("周报草稿", "Weekly report"), parent: "work", kind: .chat, state: 1, tag: Theme.highlight("yellow"), tagIcon: "hourglass"),
            DemoNode(id: "tax", title: tr("报税问题", "Tax question"), parent: "work", kind: .chat, state: 2),
            DemoNode(id: "trip", title: tr("旅行", "Trip"), parent: "root", kind: .topic),
            DemoNode(id: "flights", title: tr("机票", "Flights"), parent: "trip", kind: .sub),
            DemoNode(id: "tokyo", title: tr("东京机票", "Tokyo flights"), parent: "flights", kind: .chat),
            DemoNode(id: "hotel", title: tr("酒店比价", "Hotel deals"), parent: "trip", kind: .chat, app: "gpt"),
        ]
        w.rows = [
            DemoRow(id: "tax", title: tr("报税问题", "Tax question"), state: 2),
            DemoRow(id: "weekly", title: tr("周报草稿", "Weekly report"), state: 1),
            DemoRow(id: "tokyo", title: tr("东京机票", "Tokyo flights")),
            DemoRow(id: "kikumap", title: "kikumap", app: "code", placed: false),
            DemoRow(id: "hotel", title: tr("酒店比价", "Hotel deals"), app: "gpt"),
        ]
        return w
    }
    /// The sample with a third topic (for deleting and undoing).
    static func withLearning() -> DemoWorld {
        var w = base()
        w.nodes.append(DemoNode(id: "learn", title: tr("学习", "Learning"), parent: "root", kind: .topic))
        w.nodes.append(DemoNode(id: "swift", title: tr("Swift 入门", "Swift basics"), parent: "learn", kind: .chat))
        return w
    }

    private static func press(_ keys: [KeyPart], lights: Bool = true, dur: Double = 1.05, _ change: ((inout DemoWorld) -> Void)? = nil) -> DemoStep {
        DemoStep(keys: keys, lights: lights, dur: dur, change: change)
    }
    private static func k(_ c: String) -> [KeyPart] { [.keys(c)] }
    private static func typing(_ zh: String, _ en: TrKey) -> DemoStep { DemoStep(type: tr(zh, en)) }
    private static func click(_ at: String, _ clicks: Int = 1, right: Bool = false, keys: [KeyPart]? = nil, lights: Bool = true, dur: Double = 1.1,
                              _ change: ((inout DemoWorld) -> Void)? = nil) -> DemoStep {
        DemoStep(keys: keys, lights: lights, pointAt: at, clicks: clicks, right: right, dur: dur, change: change)
    }
    private static func point(_ at: String, keys: [KeyPart]? = nil, dur: Double = 1.0, _ change: ((inout DemoWorld) -> Void)? = nil) -> DemoStep {
        DemoStep(keys: keys, lights: keys != nil, pointAt: at, dur: dur, change: change)
    }
    /// What was just shown put away, or the next part set up (a still ends before it).
    private static func cut(_ change: @escaping (inout DemoWorld) -> Void) -> DemoStep { DemoStep(dur: 0.5, cut: true, change: change) }
    private static func g(_ zh: String, _ en: TrKey, _ symbol: String) -> [KeyPart] { [.chip(tr(zh, en), symbol: symbol)] }
    private static func newTopic(_ id: String, under parent: String) -> DemoNode {
        DemoNode(id: id, title: "", parent: parent, kind: parent == "root" ? .topic : .sub)
    }

    private static var inFront: String { tr("KIKUmap 的窗口在最前面时", "While a KIKUmap window is in front") }
    private static var onMap: String { tr("导图 · 先选中一个条目", "Map · with an item selected") }
    private static var withMouse: String { tr("导图 · 鼠标或触控板", "Map · mouse or trackpad") }
    private static var inList: String { tr("左栏 · 先在左栏里点一下", "Left column · click in it first") }
    private static var onTimeline: String { tr("时间轴 · 导图窗口最下面", "Timeline · bottom of the map window") }

    /// The demo for a row (by its id in ShortcutTable).
    static func slice(_ id: String) -> DemoSlice {
        var b = base()
        let hot = [KeyPart.keys(Prefs.hotKeyLabel())]
        switch id {
        // MARK: global
        case "hotkey":
            b.windowShown = 0
            guard Prefs.hotKeyWorks else {
                // switched off, or refused by macOS: pressing it does nothing
                let why = Prefs.hotKeyEnabled ? tr("没有生效：见上面", "Not active: see above") : tr("已关闭：在上面勾上「启用」", "Off: check Enabled above")
                return DemoSlice(whereText: tr("任何 App 里", "In any app"), part: .desktop, view: .window, setup: b, steps: [
                    DemoStep(keys: hot, lights: false, dur: 2.2) { $0.bubble = why; $0.bubbleAt = CGPoint(x: 200, y: 60) },
                ])
            }
            return DemoSlice(whereText: tr("任何 App 里", "In any app"), part: .desktop, view: .window, setup: b, steps: [
                press(hot) { $0.windowShown = 1; $0.pick("root") },
                press(hot) { $0.windowShown = 0 },
            ])
        case "menuBar":
            return DemoSlice(whereText: tr("菜单栏", "Menu bar"), part: .menuBar, view: .menuBar, setup: b, steps: [
                click("icon", keys: g("点菜单栏图标", "click the menu-bar icon", "menubar.rectangle")) {
                    $0.menuAt = CGPoint(x: 330, y: 50)
                    $0.menu = [tr("打开导图", "Open map") + (Prefs.hotKeyWorks ? "   " + Prefs.hotKeyLabel() : ""), "—",
                               tr("在跑 · 1", "Running · 1"), "◯ " + tr("报税问题", "Tax question"), "—",
                               tr("未读 · 1", "Unread · 1"), "● " + tr("周报草稿", "Weekly report")]
                },
                click("menu1", lights: false) { $0.menu = nil; $0.card = (tr("报税问题", "Tax question"), "claude") },
                DemoStep(dur: 1.2),
            ])
        case "search":
            b.pick("root")
            return DemoSlice(whereText: inFront, part: .map, view: .map, setup: b, steps: [
                press(k("⌘F")) { $0.searchShown = true },
                DemoStep(dur: 1.3) { $0.filter = tr("机票", "flight"); $0.bright = ["flights", "tokyo"]; $0.pick("flights") },
                press(k("⏎")) { $0.pick("tokyo") },
                press(k("⇧⏎")) { $0.pick("flights") },
                press(k("esc"), lights: false) { $0.searchShown = false; $0.filter = ""; $0.bright = nil },
            ])
        case "panes":
            return DemoSlice(whereText: inFront, part: .window, view: .window, setup: b, steps: [
                press(k("⌃⌘S")) { $0.sideShown = 0 },
                press(k("⌃⌘S")) { $0.sideShown = 1 },
                press(k("⌃⌘T")) { $0.tlShown = 0 },
                press(k("⌃⌘T")) { $0.tlShown = 1 },
            ])
        case "scale":
            return DemoSlice(whereText: inFront, part: .window, view: .window, setup: b, steps: [
                press(k("⌘+")) { $0.ui = 1.1 }, press(k("⌘+")) { $0.ui = 1.2 },
                press(k("⌘-")) { $0.ui = 1.1 }, press(k("⌘-")) { $0.ui = 1 },
            ])
        case "export":
            return DemoSlice(whereText: inFront, part: .window, view: .window, setup: b, steps: [
                press(k("⌘E"), dur: 1.6) { $0.card = (tr("导出导图 PDF…", "Export map as PDF…"), "pdf") },
                press(k("⇧⌘E"), dur: 1.6) { $0.card = (tr("导出对话", "Export chats"), "kikumap") },
                cut { $0.card = nil },
            ])
        case "windows":
            return DemoSlice(whereText: inFront, part: .window, view: .window, setup: b, steps: [
                press(k("⌘Y"), dur: 1.4) { $0.card = (tr("统计", "Statistics"), "kikumap") },
                press(k("⌘R"), dur: 1.2) { $0.card = nil; $0.bubble = tr("马上重新读 Claude 和 ChatGPT", "Reading Claude and ChatGPT again now"); $0.bubbleAt = CGPoint(x: 200, y: 44) },
                press(k("⌘,"), dur: 1.4) { $0.bubble = nil; $0.card = (tr("设置", "Settings"), "kikumap") },
                cut { $0.card = nil },
            ])
        case "close":
            return DemoSlice(whereText: inFront, part: .window, view: .window, setup: b, steps: [
                press(k("⌘W"), dur: 1.4) { $0.windowShown = 0; $0.bubble = tr("还在菜单栏里", "Still in the menu bar"); $0.bubbleAt = CGPoint(x: 300, y: 40) },
                cut { $0.windowShown = 1; $0.bubble = nil },
                press(k("⌘Q"), dur: 1.3) { $0.windowShown = 0 },
            ])

        // MARK: the map, keys
        case "tab":
            b.pick("trip")
            return DemoSlice(whereText: onMap, part: .map, view: .map, setup: b, steps: [
                press(k("⇥")) { $0.add(newTopic("n1", under: "trip")); $0.pick("n1"); $0.editing = "n1" },
                typing("签证", "Visa"),
                press(k("⏎"), lights: false) { $0.editing = nil },
                press(k("⌥⇥")) { w in
                    w.add(DemoNode(id: "n2", title: "", parent: "trip", kind: .sub), before: "n1")
                    w.move("n1", into: "n2")
                    w.pick("n2"); w.editing = "n2"
                },
                typing("准备", "Prep"),
                press(k("⏎"), lights: false) { $0.editing = nil },
            ])
        case "returnKey":
            b.pick("flights")
            return DemoSlice(whereText: onMap, part: .map, view: .map, setup: b, steps: [
                press(k("⏎")) { $0.add(newTopic("n1", under: "trip"), after: "flights"); $0.pick("n1"); $0.editing = "n1" },
                typing("签证", "Visa"),
                press(k("⏎"), lights: false) { $0.editing = nil },
                press(k("⌥⏎")) { $0.add(newTopic("n2", under: "trip"), before: "n1"); $0.pick("n2"); $0.editing = "n2" },
                press(k("⏎"), lights: false) { $0.editing = nil; $0.title("n2", tr("新主题", "New topic")) },
                press(k("⇧⏎")) { $0.add(newTopic("n3", under: "root")); $0.pick("n3"); $0.editing = "n3" },
                press(k("⏎"), lights: false) { $0.editing = nil; $0.title("n3", tr("新主题", "New topic")) },
            ])
        case "rename":
            b.pick("hotel")
            return DemoSlice(whereText: onMap, part: .map, view: .map, setup: b, steps: [
                press(k("⌘⏎")) { $0.editing = "hotel" },
                typing("东京酒店", "Tokyo hotels"),
                press(k("⏎"), lights: false) { $0.editing = nil },
                cut { $0.pick("work") },
                press(k("F2")) { $0.editing = "work" },
                typing("工作 · 本周", "Work · this week"),
                press(k("esc"), lights: false) { $0.editing = nil },
            ])
        case "delete":
            b = withLearning(); b.pick("weekly")
            return DemoSlice(whereText: onMap, part: .map, view: .map, setup: b, steps: [
                press(k("⌫")) { $0.remove("weekly"); $0.pick("tax") },
                cut { $0.pick("flights") },
                press(k("⌥⌫")) { w in w.move("tokyo", into: "trip", before: "flights"); w.remove("flights"); w.pick("hotel") },
                cut { $0.pick("learn") },
                press(k("⌫")) { $0.remove("learn"); $0.pick("trip") },
                press(k("⌘Z"), lights: false) { w in
                    w.add(DemoNode(id: "learn", title: tr("学习", "Learning"), parent: "root", kind: .topic))
                    w.add(DemoNode(id: "swift", title: tr("Swift 入门", "Swift basics"), parent: "learn", kind: .chat))
                },
            ])
        case "arrows":
            b.pick("root")
            return DemoSlice(whereText: tr("导图 · 先点一下导图", "Map · click the map first"), part: .map, view: .map, setup: b, steps: [
                press(k("→"), dur: 0.7) { $0.pick("work") }, press(k("→"), dur: 0.7) { $0.pick("weekly") },
                press(k("↓"), dur: 0.7) { $0.pick("tax") }, press(k("↓"), dur: 0.7) { $0.pick("flights") },
                press(k("→"), dur: 0.7) { $0.pick("tokyo") }, press(k("←"), dur: 0.7) { $0.pick("flights") },
                press(k("⌘↑")) { $0.pick("trip") },
            ])
        case "optArrows":
            b.pick("hotel")
            return DemoSlice(whereText: onMap, part: .map, view: .map, setup: b, steps: [
                press(k("⌥→")) { $0.move("hotel", into: "flights"); $0.pick("hotel") },
                press(k("⌥←")) { $0.move("hotel", into: "trip", after: "flights"); $0.pick("hotel") },
                press(k("⌥↑")) { $0.move("hotel", into: "trip", before: "flights"); $0.pick("hotel") },
                press(k("⌥↓")) { $0.move("hotel", into: "trip", after: "flights"); $0.pick("hotel") },
            ])
        case "fold":
            b.pick("trip")
            return DemoSlice(whereText: onMap, part: .map, view: .map, setup: b, steps: [
                press(k("⌥.")) { if let i = $0.node("trip") { $0.nodes[i].folded = true } },
                DemoStep(dur: 0.6),
                press(k("⌥.")) { if let i = $0.node("trip") { $0.nodes[i].folded = false } },
            ])
        case "open":
            b.pick("tokyo")
            return DemoSlice(whereText: onMap, part: .map, view: .map, setup: b, steps: [
                press(k("⌘↓"), dur: 1.5) { $0.card = (tr("东京机票", "Tokyo flights"), "claude") },
                cut { $0.card = nil; $0.pick("hotel") },
                DemoStep(keys: [.word(tr("轻按", "tap")), .keys(tr("空格", "space"))], hold: 0.12, dur: 1.5) { $0.card = (tr("酒店比价", "Hotel deals"), "gpt") },
                cut { $0.card = nil },
                DemoStep(keys: [.word(tr("按住", "hold")), .keys(tr("空格", "space"))], lights: false, hold: 1.0, dur: 1.5) { $0.pan = CGPoint(x: 50, y: 0) },
            ])
        case "undo":
            b = withLearning(); b.pick("learn")
            // ⌫ selects the next item (here the one before: Learning is last); undo and redo leave the selection alone
            let back: (inout DemoWorld) -> Void = { w in
                w.add(DemoNode(id: "learn", title: tr("学习", "Learning"), parent: "root", kind: .topic))
                w.add(DemoNode(id: "swift", title: tr("Swift 入门", "Swift basics"), parent: "learn", kind: .chat))
            }
            return DemoSlice(whereText: onMap, part: .map, view: .map, setup: b, steps: [
                press(k("⌫"), lights: false) { $0.remove("learn"); $0.pick("trip") },
                press(k("⌘Z"), back),
                press(k("⇧⌘Z")) { $0.remove("learn") },
                press(k("⌘Z"), back),
            ])
        case "esc":
            b.pick("tax")
            return DemoSlice(whereText: onMap, part: .map, view: .map, setup: b, steps: [
                press(k("⌘A")) { $0.sel = Set($0.nodes.filter { $0.kind != .root }.map(\.id)) },
                press(k("esc")) { $0.sel = [] },
                press(k("esc"), dur: 1.4) { $0.bubble = tr("什么都没选：收起导图窗口", "Nothing selected: the map is put away"); $0.bubbleAt = CGPoint(x: 150, y: 40) },
                cut { $0.bubble = nil },
            ])

        // MARK: the map, mouse
        case "click":
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                click("trip") { $0.pick("trip") },
                click("empty") { $0.sel = [] },
                click("root") { $0.pick("root") },
            ])
        case "doubleClick":
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                click("trip", 2) { $0.pick("trip"); $0.editing = "trip" },
                typing("东京旅行", "Tokyo trip"),
                press(k("⏎"), lights: false) { $0.editing = nil },
                click("empty", 2, lights: false) { $0.add(newTopic("n1", under: "root")); $0.pick("n1"); $0.editing = "n1" },
                typing("家", "Home"),
                press(k("⏎"), lights: false) { $0.editing = nil },
            ])
        case "dragItem":
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                click("hotel", keys: g("拖动", "drag", "arrow.up.and.down.and.arrow.left.and.right")) { $0.pick("hotel") },
                point("work", dur: 1.2) { $0.move("hotel", into: "work"); $0.pick("hotel") },
            ])
        case "box":
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                point("empty", keys: g("拖空白处", "drag on empty space", "rectangle.dashed"), dur: 1.4) { $0.boxAround = ["weekly", "tax"]; $0.sel = ["weekly", "tax"] },
                cut { $0.boxAround = [] },
                point("hotel", keys: [.keys("⌘")] + g("拖", "drag", "rectangle.dashed"), dur: 1.3) { $0.boxAround = ["hotel"]; $0.sel.insert("hotel") },
                cut { $0.boxAround = [] },
            ])
        case "shiftClick":
            b.pick("weekly")
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                click("tax", keys: [.keys("⇧")] + g("点击", "click", "cursorarrow.click")) { $0.sel.insert("tax") },
                click("hotel", keys: [.keys("⌘")] + g("点击", "click", "cursorarrow.click")) { $0.sel.insert("hotel") },
                click("tax", keys: [.keys("⌘")] + g("点击", "click", "cursorarrow.click")) { $0.sel.remove("tax") },
            ])
        case "pan":
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                DemoStep(keys: [.word(tr("按住", "hold")), .keys(tr("空格", "space"))], pointAt: "empty", hold: 1.2, dur: 1.6) { $0.pan = CGPoint(x: -60, y: 0) },
                DemoStep(keys: g("双指滑动", "two fingers", "arrow.up.arrow.down"), lights: false, dur: 1.2) { $0.pan = .zero },
            ])
        case "pinch":
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                press(g("捏合", "pinch", "arrow.up.left.and.arrow.down.right")) { $0.zoom = 1.25 },
                press(g("捏合", "pinch", "arrow.up.left.and.arrow.down.right")) { $0.zoom = 0.85 },
                press(k("⌘0")) { $0.zoom = 1; $0.pan = .zero },
            ])
        case "rightClick":
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                click("trip", right: true, keys: g("右键", "right-click", "contextualmenu.and.cursorarrow"), dur: 1.8) {
                    $0.pick("trip"); $0.menuAt = CGPoint(x: 260, y: 34)
                    // (most of a topic's menu, in its order: all of it is taller than the picture)
                    $0.menu = [tr("新子主题  ⇥", "New subtopic  ⇥"), tr("改名  ⌘↩", "Rename  ⌘↩"), tr("分支颜色 ▸", "Branch color ▸"), tr("图标…", "Icon…"),
                               tr("标签 ▸", "Tags ▸"), tr("折叠  ⌥.", "Collapse  ⌥."), "—", tr("删除  ⌫", "Delete  ⌫")]
                },
                cut { $0.menu = nil },
            ])
        case "hoverButtons":
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                point("tokyo", keys: g("悬停", "hover", "cursorarrow.rays"), dur: 1.3) { $0.buttonsFor = "tokyo" },
                click("mail:tokyo", lights: false, dur: 1.3) { w in if let i = w.node("tokyo") { w.nodes[i].state = 1 } },
                click("tokyo", lights: false, dur: 0.9) { $0.pick("tokyo") },
                press(k("⇧⌘U")) { if let i = $0.node("tokyo") { $0.nodes[i].state = 0 } },
                cut { $0.buttonsFor = nil },
            ])

        // MARK: the left column
        case "sideClick":
            b.picked = ["tokyo"]; b.pick("root")
            return DemoSlice(whereText: inList, part: .list, view: .list, setup: b, steps: [
                click("r:weekly") { $0.picked = ["weekly"]; $0.listFocus = true; $0.mapFocus = false; $0.pick("weekly") },
                click("trip", lights: false) { $0.pick("trip"); $0.picked = []; $0.listFocus = false; $0.mapFocus = true },
            ])
        case "sideArrows":
            b.picked = ["weekly"]; b.listFocus = true; b.mapFocus = false; b.pick("weekly")
            func to(_ id: String, placed: Bool = true) -> (inout DemoWorld) -> Void { { $0.picked = [id]; $0.sel = placed ? [id] : [] } }
            return DemoSlice(whereText: inList, part: .list, view: .list, setup: b, steps: [
                press(k("↓"), dur: 0.75, to("tokyo")), press(k("↓"), dur: 0.75, to("kikumap", placed: false)),
                press(k("↓"), dur: 0.75, to("hotel")), press(k("↓"), dur: 0.75, to("hotel")),
                press(k("↑"), dur: 0.9, to("kikumap", placed: false)),
            ])
        case "sideOpen":
            b.picked = ["tokyo"]; b.listFocus = true; b.mapFocus = false; b.pick("tokyo")
            return DemoSlice(whereText: inList, part: .list, view: .list, setup: b, steps: [
                press(k("⏎"), dur: 1.4) { $0.card = (tr("东京机票", "Tokyo flights"), "claude") },
                press(k("↓"), lights: false, dur: 0.6) { $0.card = nil; $0.picked = ["kikumap"]; $0.sel = [] },
                press(k(tr("空格", "space")), dur: 1.4) { $0.card = ("kikumap", "code") },
                press(k("↓"), lights: false, dur: 0.6) { $0.card = nil; $0.picked = ["hotel"]; $0.sel = ["hotel"] },
                press(k("⌘↓"), dur: 1.4) { $0.card = (tr("酒店比价", "Hotel deals"), "gpt") },
                cut { $0.card = nil },
            ])
        case "sidePick":
            b.picked = ["tax"]; b.listFocus = true; b.mapFocus = false; b.pick("tax")
            return DemoSlice(whereText: inList, part: .list, view: .list, setup: b, steps: [
                click("r:tokyo", keys: [.keys("⌘")] + g("点击", "click", "cursorarrow.click")) { $0.picked.insert("tokyo"); $0.sel.insert("tokyo") },
                click("r:kikumap", keys: [.keys("⌘")] + g("点击", "click", "cursorarrow.click")) { $0.picked.insert("kikumap") },
                press(k("esc"), lights: false) { $0.picked = ["kikumap"]; $0.sel = [] },
                click("r:weekly", lights: false) { $0.picked = ["weekly"]; $0.sel = ["weekly"] },
                click("r:hotel", keys: [.keys("⇧")] + g("点击", "click", "cursorarrow.click")) { $0.picked = ["weekly", "tokyo", "kikumap", "hotel"]; $0.sel = ["weekly", "tokyo", "hotel"] },
            ])
        case "sideDrag":
            b.picked = ["kikumap"]; b.listFocus = true; b.mapFocus = false
            return DemoSlice(whereText: tr("左栏", "Left column"), part: .list, view: .list, setup: b, steps: [
                click("r:kikumap", keys: g("拖到导图上", "drag onto the map", "arrow.up.and.down.and.arrow.left.and.right")),
                // dropped: selected on the map, which has the keys now (the row stays picked, its ring pale)
                point("trip", dur: 1.3) { w in
                    w.add(DemoNode(id: "kikumap", title: "kikumap", parent: "trip", kind: .chat, app: "code"))
                    if let i = w.rows.firstIndex(where: { $0.id == "kikumap" }) { w.rows[i].placed = true }
                    w.pick("kikumap")
                    w.listFocus = false; w.mapFocus = true
                },
            ])
        case "sideMenu":
            return DemoSlice(whereText: tr("左栏", "Left column"), part: .list, view: .list, setup: b, steps: [
                click("r:weekly", right: true, keys: g("右键", "right-click", "contextualmenu.and.cursorarrow"), dur: 1.6) {
                    $0.menuAt = CGPoint(x: 100, y: 110); $0.menu = [tr("打开", "Open"), tr("让 Claude 写总结存档…", "Archive a summary…")]
                },
                cut { $0.menu = nil },
                click("r:kikumap", right: true, keys: g("右键", "right-click", "contextualmenu.and.cursorarrow"), dur: 1.6) {
                    $0.menuAt = CGPoint(x: 100, y: 150)
                    // (a session in a terminal, done, not on the map: the menu's words for it)
                    $0.menu = [SidebarView.keepTitle(kept: false, onMap: false, script: false, running: false), tr("打开", "Open")]
                },
                cut { $0.menu = nil },
            ])
        case "sideSearch":
            return DemoSlice(whereText: tr("左栏", "Left column"), part: .list, view: .list, setup: b, steps: [
                click("search", keys: g("在搜索框里输入", "type in the search box", "magnifyingglass")),
                DemoStep(dur: 1.6) { $0.filter = tr("机票", "flight") },
                press(k("esc"), lights: false) { $0.filter = "" },
            ])
        case "tagOff":
            return DemoSlice(whereText: withMouse, part: .map, view: .map, setup: b, steps: [
                click("tag:weekly", keys: g("拖标签", "drag the tag", "tag")) { $0.pick("weekly") },
                point("off:weekly", dur: 1.3) { if let i = $0.node("weekly") { $0.nodes[i].tag = nil; $0.nodes[i].tagIcon = nil } },
            ])
        case "tags":
            return DemoSlice(whereText: tr("左栏 · 标签区", "Left column · tags"), part: .tags, view: .map, setup: b, steps: [
                press(g("点标签「等别人」", "click Waiting on others", "tag"), dur: 1.6) { $0.lit = ["weekly": Theme.highlight("yellow") ?? .systemYellow]; $0.bright = ["weekly"] },
                press(g("再点一下", "click it again", "tag"), dur: 1.0) { $0.lit = [:]; $0.bright = nil },
            ])
        case "syncSched":
            return DemoSlice(whereText: tr("左栏", "Left column"), part: .list, view: .list, setup: b, steps: [
                click("refresh", dur: 1.4) { $0.spin = 720 },
                cut { $0.spin = 0 },
            ])

        // MARK: the timeline
        case "tlHover":
            return DemoSlice(whereText: onTimeline, part: .timeline, view: .timeline, setup: b, steps: [
                point("lanes", keys: g("悬停", "hover", "cursorarrow.rays"), dur: 1.3) { $0.tlHover = 0 },
                point("lanes2", dur: 1.3) { $0.tlHover = 1 },
                point("bar", dur: 1.4) { $0.tlHover = nil; $0.bubble = tr("报税问题 13:55 – 在跑", "Tax question 13:55 – running"); $0.bubbleAt = CGPoint(x: 260, y: 36) },
                cut { $0.bubble = nil },
            ])
        case "tlScroll":
            return DemoSlice(whereText: onTimeline, part: .timeline, view: .timeline, setup: b, steps: [
                press(g("双指滑动", "scroll", "arrow.up.arrow.down"), dur: 1.3) { $0.tlShift = 70; $0.following = false },
                press(g("拖动", "drag", "arrow.left.and.right"), dur: 1.3) { $0.tlShift = 20 },
            ])
        case "tlZoom":
            return DemoSlice(whereText: onTimeline, part: .timeline, view: .timeline, setup: b, steps: [
                press([.keys("⌘")] + g("滑动", "scroll", "arrow.up.arrow.down"), dur: 1.2) { $0.tlScale = 1.6; $0.following = false },
                press(g("捏合", "pinch", "arrow.up.left.and.arrow.down.right"), dur: 1.2) { $0.tlScale = 2.2 },
                press(g("点「3小时」", "click 3h", "cursorarrow.click"), lights: false, dur: 1.2) { $0.tlScale = 1; $0.tlShift = 0; $0.following = true },
            ])
        case "tlNow":
            b.tlShift = 80; b.following = false
            return DemoSlice(whereText: onTimeline, part: .timeline, view: .timeline, setup: b, steps: [
                click("lanes", 2, keys: g("双击", "double-click", "cursorarrow.click.2")) { $0.tlShift = 0; $0.following = true },
                press(g("双指滑动", "scroll", "arrow.up.arrow.down"), lights: false) { $0.tlShift = 60; $0.following = false },
                press(g("点「◎ 现在」", "click ◎ Now", "scope")) { $0.tlShift = 0; $0.following = true },
            ])
        case "tlClick":
            return DemoSlice(whereText: onTimeline, part: .timeline, view: .timeline, setup: b, steps: [
                click("bar", dur: 1.5) { $0.card = (tr("报税问题", "Tax question"), "claude") },
                cut { $0.card = nil },
            ])
        default:
            return DemoSlice(whereText: inFront, part: .window, view: .window, setup: b, steps: [DemoStep(dur: 1.5)])
        }
    }

    // MARK: Settings → Access

    /// The ids of Settings → Access's items, in its order (AccessItem.all), each with a demo here.
    static let accessIDs = ["accessibility", "fullDisk", "claudeCode", "chatGPT", "usage", "gptUsage"]

    /// What an item of Settings → Access gets you, acted out on made-up chats: what KIKUmap reads on the left, what it
    /// then shows on the right, as the real map, left column and menu draw it (MapView, SidebarView, StatusBar). Each
    /// is a few seconds; a caption under it says what's happening.
    static func access(_ id: String) -> DemoSlice {
        let weekly = tr("周报草稿", "Weekly report"), tax = tr("报税问题", "Tax question"), tokyo = tr("东京机票", "Tokyo flights")
        // a small map: what's on it was put there before
        var m = DemoWorld()
        m.nodes = [
            DemoNode(id: "root", title: "", parent: nil, kind: .root),
            DemoNode(id: "work", title: tr("工作", "Work"), parent: "root", kind: .topic),
            DemoNode(id: "weekly", title: weekly, parent: "work", kind: .chat),
            DemoNode(id: "tax", title: tax, parent: "work", kind: .chat),
        ]
        func chat(_ w: inout DemoWorld, _ id: String, _ f: (inout DemoNode) -> Void) { if let i = w.node(id) { f(&w.nodes[i]) } }
        func appRow(_ w: inout DemoWorld, _ id: String, _ state: Int) {
            if let i = w.appRows.firstIndex(where: { $0.id == id }) { w.appRows[i].state = state }
        }
        func row(_ w: inout DemoWorld, _ id: String, _ state: Int, _ note: String?) {
            if let i = w.rows.firstIndex(where: { $0.id == id }) { w.rows[i].state = state; w.rows[i].note = note }
        }
        func step(_ dur: Double, _ caption: String, _ change: @escaping (inout DemoWorld) -> Void) -> DemoStep {
            DemoStep(dur: dur) { w in change(&w); w.caption = caption }
        }
        switch id {
        case "fullDisk":
            // Claude's window closed: the chat it was working on can't be seen ("running?"); Claude's banner asks
            // for an OK; KIKUmap reads it from Notification Center: waiting for you, and the "!" in the menu bar
            var w = m
            if let i = w.node("tax") { w.nodes[i].state = 2 }
            w.icon = (run: 1, seen: true, unread: 0, needs: 0)
            return DemoSlice(whereText: tr("完全磁盘访问 · 读 Claude 发的通知", "Full Disk Access · reads Claude's notifications"), part: .map, view: .notice, setup: w, steps: [
                step(1.3, tr("Claude 的窗口关着", "Claude's window is closed")) { w in
                    w.appShown = 0; w.icon.seen = false
                    chat(&w, "tax") { $0.seen = false; $0.note = tr("在跑？", "running?") }
                },
                step(1.5, tr("Claude 发通知：要你允许一步", "Claude's notification asks for your OK")) { w in
                    w.banner = (tax, tr("要允许 Claude 运行这条命令吗？", "Allow Claude to run this command?")); w.reads = true
                },
                step(1.8, tr("KIKUmap 提醒你：等你确认", "KIKUmap tells you: waiting for you")) { w in
                    chat(&w, "tax") { $0.state = 1; $0.seen = true; $0.note = tr("等你确认", "waiting for you") }
                    w.icon = (run: 0, seen: true, unread: 1, needs: 1)
                },
            ])
        case "claudeCode":
            // a session at work in a terminal reports through Claude Code's hooks: it joins the left column, running,
            // then finished and unread
            var w = DemoWorld()
            w.rows = [DemoRow(id: "weekly", title: weekly), DemoRow(id: "tokyo", title: tokyo)]
            w.term = ["~/kikumap $ claude"]
            return DemoSlice(whereText: tr("Claude Code · 会话自己报给 KIKUmap", "Claude Code · sessions report to KIKUmap"), part: .list, view: .terminal, setup: w, steps: [
                step(1.2, tr("终端里的 Claude Code 开始干活", "Claude Code gets to work in Terminal")) { w in
                    w.term.append(tr("> 修好登录页的按钮", "> fix the login button"))
                },
                step(1.6, tr("左栏里出现，在跑", "It shows up in the left column, running")) { w in
                    w.term.append(tr("✻ 正在改…", "✻ Working…")); w.reads = true
                    w.rows.append(DemoRow(id: "kikumap", title: "kikumap", state: 2, app: "code", placed: false, note: tr("在跑", "running")))
                },
                step(1.7, tr("做完了：红点，等你去看", "Done: a red dot until you look")) { w in
                    w.term.append(tr("✓ 改好了", "✓ Done"))
                    row(&w, "kikumap", 1, tr("刚刚", "just now"))
                },
            ])
        case "chatGPT":
            // read from the ChatGPT app's files in ~/.codex (not its window: nothing outlined there): the chats pinned
            // in ChatGPT, one of them a Codex chat, which runs, then is done. Both are in ChatGPT's Pinned section, as a
            // chat in the app, Codex or not, shows only once it's pinned there (Store.isShown).
            let hotel = tr("酒店比价", "Hotel deals"), copy = tr("首页文案", "Home page copy")
            var w = DemoWorld()
            w.appRows = [DemoRow(id: "hotel", title: hotel, app: "gpt"), DemoRow(id: "codex", title: copy, app: "gpt")]
            w.rows = [DemoRow(id: "weekly", title: weekly), DemoRow(id: "tokyo", title: tokyo)]
            return DemoSlice(whereText: tr("ChatGPT · 读 ~/.codex 里的记录（只读）", "ChatGPT · reads its records in ~/.codex (read-only)"), part: .list, view: .chatGPTApp, setup: w, steps: [
                step(1.4, tr("在 ChatGPT 里置顶的对话，列进左栏", "Chats you pin in ChatGPT join the left column")) { w in
                    w.reads = true
                    w.rows += [DemoRow(id: "hotel", title: hotel, app: "gpt", placed: false), DemoRow(id: "codex", title: copy, app: "gpt", placed: false)]
                },
                step(1.5, tr("置顶的 Codex 对话，看得出在跑", "A pinned Codex chat shows it's running")) { w in
                    appRow(&w, "codex", 2)
                    row(&w, "codex", 2, tr("在跑", "running"))
                },
                step(1.6, tr("做完了：红点，等你去看", "Done: a red dot until you look")) { w in
                    appRow(&w, "codex", 1)
                    row(&w, "codex", 1, tr("刚刚", "just now"))
                },
            ])
        case "usage":
            // the drop-down without it: the item that turns it on; with it: the session and the week, as the menu
            // lays them out
            var w = DemoWorld()
            w.icon = (run: 1, seen: true, unread: 1, needs: 0)
            w.usageHead = tr("用量", "Usage")
            return DemoSlice(whereText: tr("Claude 用量 · 菜单栏里", "Claude usage · in the menu bar"), part: .menuBar, view: .usageMenu, setup: w, steps: [
                DemoStep(pointAt: "kicon", clicks: 1, dur: 1.4) { w in w.menuOpen = true; w.caption = tr("没开：菜单里没有 Claude 的用量", "Off: no Claude usage in the menu") },
                step(2.0, tr("开了：用了多少、什么时候重置", "On: how much you've used, when it resets")) { w in
                    w.usageHead = tr("用量 · Claude Pro", "Usage · Claude Pro")
                    w.usage = [DemoUsage(title: tr("当前会话", "Current session"), percent: 42, sub: tr("今天 15:00 重置", "resets today 15:00")),
                               DemoUsage(title: tr("本周", "This week"), percent: 18, sub: tr("周一 09:00 重置", "resets Mon 09:00"))]
                },
            ])
        case "gptUsage":
            // without it, ChatGPT's numbers come from Codex's own records: old ones, a reset passed; with it, fresh
            var w = DemoWorld()
            w.icon = (run: 1, seen: true, unread: 1, needs: 0)
            w.usageHead = tr("用量 · ChatGPT Plus", "Usage · ChatGPT Plus")
            let session = "ChatGPT · " + tr("会话", "Session"), week = "ChatGPT · " + tr("本周", "Week")
            w.usage = [DemoUsage(title: session, percent: nil, sub: tr("13:00 已重置", "reset 13:00")),
                       DemoUsage(title: week, percent: 40, sub: tr("09:12 时的数据", "as of 09:12"))]
            return DemoSlice(whereText: tr("ChatGPT 用量 · 菜单栏里", "ChatGPT usage · in the menu bar"), part: .menuBar, view: .usageMenu, setup: w, steps: [
                DemoStep(pointAt: "kicon", clicks: 1, dur: 1.4) { w in w.menuOpen = true; w.caption = tr("没开：等下次用 Codex 才更新", "Off: it waits for your next Codex task") },
                step(2.0, tr("开了：每 10 分钟更新一次", "On: it updates every 10 minutes")) { w in
                    w.usage = [DemoUsage(title: session, percent: 6, sub: tr("今天 18:00 重置", "resets today 18:00")),
                               DemoUsage(title: week, percent: 41, sub: tr("周一 09:00 重置", "resets Mon 09:00"))]
                },
            ])
        default:
            // Accessibility: Claude's own chat list, read; a chat Claude works on runs on the map, then waits there unread
            var w = m
            w.nodes += [DemoNode(id: "trip", title: tr("旅行", "Trip"), parent: "root", kind: .topic),
                        DemoNode(id: "tokyo", title: tokyo, parent: "trip", kind: .chat)]
            w.appRows = [DemoRow(id: "weekly", title: weekly), DemoRow(id: "tax", title: tax), DemoRow(id: "tokyo", title: tokyo)]
            return DemoSlice(whereText: tr("辅助功能 · 读 Claude 窗口里的对话列表", "Accessibility · reads the chat list in Claude's window"), part: .map, view: .claudeApp, setup: w, steps: [
                step(1.3, tr("KIKUmap 读 Claude 窗口里的对话列表", "KIKUmap reads the chat list in Claude's window")) { $0.reads = true },
                step(1.6, tr("Claude 在回答：导图上显示在跑", "Claude is answering: running on the map")) { w in
                    appRow(&w, "tax", 2); chat(&w, "tax") { $0.state = 2 }
                },
                step(1.7, tr("做完了：红点，等你去看", "Done: a red dot until you look")) { w in
                    appRow(&w, "tax", 1); chat(&w, "tax") { $0.state = 1 }
                },
            ])
        }
    }
}
