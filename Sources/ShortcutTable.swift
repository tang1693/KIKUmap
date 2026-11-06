import Cocoa

/// Where a shortcut works: the places Settings → Shortcuts sorts them into.
enum ShortcutPlace: Int, CaseIterable {
    case anywhere, mapKeys, mapMouse, column, timeline

    var title: String {
        switch self {
        case .anywhere: return tr("任何地方", "Anywhere")
        case .mapKeys: return tr("导图 · 按键", "Map · keys")
        case .mapMouse: return tr("导图 · 鼠标", "Map · mouse")
        case .column: return tr("左栏", "Left column")
        case .timeline: return tr("时间线", "Timeline")
        }
    }
    var symbol: String {
        switch self {
        case .anywhere: return "macwindow.on.rectangle"
        case .mapKeys: return "keyboard"
        case .mapMouse: return "computermouse"
        case .column: return "sidebar.left"
        case .timeline: return "rectangle.bottomthird.inset.filled"
        }
    }
    var tip: String {
        switch self {
        case .anywhere: return tr("任何 App 里，或 KIKUmap 的窗口在最前面时", "In any app, or while a KIKUmap window is in front")
        case .mapKeys: return tr("先点一下导图", "Click the map first")
        case .mapMouse: return tr("鼠标或触控板，在导图上", "Mouse or trackpad, on the map")
        case .column: return tr("先在左栏里点一下", "Click in the list first")
        case .timeline: return tr("导图窗口最下面那条", "The strip at the bottom of the map window")
        }
    }
}

/// One shortcut as Settings → Shortcuts and the map's "Map shortcuts" list show it: its keys, what it does, and a
/// note with the details (the caption, and the tooltip).
struct ShortcutRow {
    let id: String
    let place: ShortcutPlace
    /// A heading it starts (only in Anywhere: in any app / while a KIKUmap window is in front).
    var section: String? = nil
    let parts: [KeyPart]
    let label: String
    let note: String
    /// Shown faded: the shortcut is off.
    var dimmed = false
}

/// Every shortcut, checked against the code that handles it (MapView keyDown / performKeyEquivalent / mouse,
/// SidebarView, TimelineView, the app's menus, the global hotkey). Built fresh each time: the words follow the
/// language, the hotkey follows Settings. Change a behaviour, change its row here (and the READMEs' tables).
enum ShortcutTable {
    private static func k(_ c: String) -> KeyPart { .keys(c) }
    private static var or: KeyPart { .word(tr("或", "or")) }
    private static var dot: KeyPart { .word("·") }
    private static var then: KeyPart { .word(tr("然后", "then")) }
    private static var slash: KeyPart { .word("/") }
    private static var plus: KeyPart { .word("+") }
    private static var hold: KeyPart { .word(tr("按住", "hold")) }
    private static var tap: KeyPart { .word(tr("轻按", "tap")) }
    private static var space: KeyPart { .keys(tr("空格", "space")) }
    private static func g(_ zh: String, _ en: String, _ symbol: String) -> KeyPart { .chip(tr(zh, en), symbol: symbol) }
    private static var click: KeyPart { g("点击", "click", "cursorarrow.click") }

    static func all() -> [ShortcutRow] {
        let hot = Prefs.hotKeyWorks
        let refused = Prefs.hotKeyEnabled && Prefs.hotKeyError != nil
        let hotKey = Prefs.hotKeyLabel()
        // not active because KIKUmap's own menus use it (saved by an older build): why
        let own = refused ? HotKeyField.ownText(code: Prefs.hotKeyCode, mods: Prefs.hotKeyMods) : nil
        var rows: [ShortcutRow] = []
        func add(_ id: String, _ place: ShortcutPlace, _ parts: [KeyPart], _ zh: String, _ en: String, _ noteZh: String, _ noteEn: String,
                 section: String? = nil, dimmed: Bool = false) {
            rows.append(ShortcutRow(id: id, place: place, section: section, parts: parts, label: tr(zh, en), note: tr(noteZh, noteEn), dimmed: dimmed))
        }

        // anywhere (the hotkey's caption says what its row says: on, off, or not active and why)
        add("hotkey", .anywhere, [k(hotKey)],
            hot ? "呼出导图；它在最前面时再按就收起" : refused ? "没有生效：见上面" : "已关闭：在上面勾上「启用」",
            hot ? "Show the map; press again to put it away" : refused ? "Not active: see above" : "Off: tick Enabled above",
            hot ? "在任何 App 里都能按：导图来到你所在的桌面，按键直接给导图。导图在最前面时再按就收起。在本页最上面可以改。"
                : refused ? own.map { "现在按它没有反应：\($0)。在本页最上面换一个组合。" } ?? "现在按它没有反应：macOS 没接受这个组合，可能别的 App 或系统快捷键在用。在本页最上面换一个。"
                : "已关闭，现在按它没有反应。在本页最上面勾上「启用」后，在任何 App 里都能按：导图来到你所在的桌面，按键直接给导图。",
            hot ? "Works in any app: the map comes to the desktop you're on, with the keys on the map. Pressed while the map is in front, it puts it away. Change it at the top."
                : refused ? own.map { "Pressing it does nothing now: \($0). Pick another combination at the top of this page." }
                    ?? "Pressing it does nothing now: macOS didn't accept this combination; another app or a system shortcut may use it. Pick another at the top of this page."
                : "Off: pressing it does nothing now. Tick Enabled at the top of this page and it works in any app: the map comes to the desktop you're on, with the keys on the map.",
            section: tr("任何 App 里", "In any app"), dimmed: !hot)
        add("menuBar", .anywhere, [g("点菜单栏图标", "click the menu-bar icon", "menubar.rectangle")],
            "看在跑和未读的对话；点一个直接打开", "Running and unread chats; click one to open it",
            "圈里的数字 = 在跑几个；红色 = 做完了还没看，带 ! 是要你处理。「打开导图」在最上面。悬停图标能看各个标记的意思。",
            "A number in a ring: how many are running. Red: finished, not seen yet; ! means it needs you. Open map is at the top. Hover the icon for what each mark means.")
        add("search", .anywhere, [k("⌘F"), then, k("⏎"), dot, k("⇧⏎")],
            "搜索导图 · 下一个 · 上一个", "Search the map · next match · previous one",
            "主题、对话名和标题、标签都算。匹配的保持清晰，并选中第一个；折叠的主题里面有匹配也算。Esc 关闭并清空搜索。",
            "Topics, chat names and titles, and tags count. Matches stay bright and the first is selected; a folded topic counts if something inside matches. Esc closes and clears it.",
            section: tr("KIKUmap 的窗口在最前面时", "While a KIKUmap window is in front"))
        add("panes", .anywhere, [k("⌃⌘"), plus, k("S"), slash, k("G"), slash, k("T")],
            "显示或隐藏左栏 · 标签 · 时间线", "Show or hide the left column · tags · timeline",
            "和顶栏的按钮一样，双击那一栏的边也行。拖左栏的边改宽度，拖到靠近窗口左边就收起；标签栏的上边也能拖。",
            "Same as the top-bar buttons, or double-click the pane's edge. Drag the column's edge to set its width, or nearly to the window's edge to tuck it away; the tags' top edge drags too.")
        add("scale", .anywhere, [k("⌘+"), dot, k("⌘-")],
            "整个窗口放大 · 缩小", "Everything in the window bigger · smaller",
            "80%–160%，每次 10%，导图跟着缩放；「显示 → 默认大小」回到 100%。美式键盘上 ⌘+ 要按 ⇧⌘=；导图有焦点时 ⌘= 也行。",
            "80–160 % in 10 % steps, the map zooming with it; View → Default Size goes back to 100 %. On a US keyboard ⌘+ is ⇧⌘=; with the map focused, ⌘= works too.")
        add("export", .anywhere, [k("⌘E"), dot, k("⇧⌘E")],
            "导出导图 PDF · 导出对话", "Export the map as PDF · export chats",
            "PDF 用浅色、不带选中框，只裁到导图范围，会先问存到哪里。「导出对话」会打开它自己的窗口。",
            "The PDF is drawn light, with nothing selected, cropped to the map; it asks where to save. Export chats opens its own window.")
        add("windows", .anywhere, [k("⌘Y"), dot, k("⌘R"), dot, k("⌘,")],
            "统计 · 马上刷新 · 设置", "Statistics · refresh now · Settings",
            "刷新会马上重新读 Claude 的侧边栏和通知、ChatGPT 和用量，左栏的 ⟳ 会转一下。⌘Y、⌘, 也是顶栏的柱状图和齿轮按钮。",
            "Refresh reads Claude's sidebar and notifications, ChatGPT and usage again right away, and ⟳ in the left column turns. ⌘Y and ⌘, are the chart and gear buttons too.")
        add("close", .anywhere, [k("⌘W"), dot, k("⌘Q")],
            "收起窗口 · 退出 KIKUmap", "Put the window away · quit KIKUmap",
            hot ? "⌘W 关掉最前面的窗口；导图窗口只是收起，KIKUmap 还在菜单栏（窗口都关了就离开 Dock）。按 \(hotKey) 或点菜单栏图标就回来。"
                : "⌘W 关掉最前面的窗口；导图窗口只是收起，KIKUmap 还在菜单栏（窗口都关了就离开 Dock）。点菜单栏图标就回来。",
            hot ? "⌘W closes the front window; the map is only put away and KIKUmap stays in the menu bar (out of the Dock once no window is open). \(hotKey) or the menu-bar icon brings it back."
                : "⌘W closes the front window; the map is only put away and KIKUmap stays in the menu bar (out of the Dock once no window is open). The menu-bar icon brings it back.")

        // the map, keys
        add("tab", .mapKeys, [k("⇥"), dot, k("⌥⇥")],
            "新建子主题 · 给它套一个父主题", "New subtopic · new parent topic around it",
            "直接输入名字；再按 Tab 结束输入、再往下加一级。选中对话时 Tab 在它下面新建同级主题；什么都没选时新建主主题。⌥⇥ 对中心点无效。",
            "The name is ready to type; Tab again finishes it and adds a level. On a chat, Tab adds a topic below it; with nothing selected, a main topic. ⌥⇥ skips the centre.")
        add("returnKey", .mapKeys, [k("⏎"), dot, k("⌥⏎"), dot, k("⇧⏎")],
            "下方新建同级 · 上方新建同级 · 新建主主题", "New topic below · above · a new main topic",
            "上下两种都和选中的条目同级；选中中心点或什么都没选时新建主主题。⇧ 回车不管选中什么都新建主主题。",
            "Below and above stay at the selected item's level; on the centre, or with nothing selected, they add a main topic. ⇧ Return always adds a main topic.")
        add("rename", .mapKeys, [k("⌘⏎"), or, k("F2")],
            "改名（对话的新名字只在 KIKUmap 里显示）", "Rename (a chat's only in KIKUmap)",
            "回车、Esc 或点别处都会结束，Esc 也保留已输入的。名字清空：主题变回「新主题」，对话恢复原标题。中心点不能改名；F2 可能要同时按 fn。",
            "Return, Esc or a click elsewhere finishes; Esc keeps what you typed. Left empty, a topic reads New topic and a chat gets its own title back. Not the centre; F2 may need fn.")
        add("delete", .mapKeys, [k("⌫"), dot, k("⌥⌫")],
            "删除 · 只删这个主题（保留下面的）", "Delete · delete just the topic, keep its items",
            "主题连同下面的一起删；对话只是从导图上拿掉（置顶的仍在左栏）。⌦ 也行。选了好几个：每个都照样删，按住 ⌥ 时各主题下面的都留下。⌘Z 撤销。",
            "A topic goes with everything under it; a chat only comes off the map (a pinned one stays in the left column). ⌦ works too. Several selected: each goes the same way, and with ⌥ what's under the topics stays. ⌘Z undoes.")
        add("arrows", .mapKeys, [k("↑↓←→"), dot, k("⌘↑")],
            "选中那个方向最近的条目 · 所在的主题", "Select the nearest item that way · its topic",
            "↑↓ 选同一侧上下最近的，不分层级；背离中心点进到它下面，朝向中心点回到上一级。⌘↑ 选它所在的主题。什么都没选时选中心点。",
            "↑ ↓: the nearest item above or below on that side, at any level. Away from the centre: into its items; toward it: back out. ⌘↑: the topic it's in. Nothing selected: the centre.")
        add("optArrows", .mapKeys, [k("⌥"), plus, k("↑↓←→")],
            "上下移动，或者换一级", "Move it up or down, or a level in or out",
            "⌥↑⌥↓ 移过 ↑↓ 会选到的那个（必要时移进它的主题）。⌥ 背离中心点：移进上方紧挨着的主题；朝向中心点：移出所在的主题。选了好几个时只移一个。",
            "⌥↑ ⌥↓: past the item ↑ ↓ would pick (into its topic if need be). ⌥ away from the centre: into the topic just above; toward it: out of its topic. Several selected: only one moves.")
        add("fold", .mapKeys, [k("⌥.")],
            "折叠 / 展开主题", "Collapse or expand the topic",
            "有内容的主题才行。折叠后，外侧的小圆标显示里面有几个对话；点它或按 ⌘↓ 都能展开。",
            "A topic with items only. Collapsed, its small pill shows how many chats it holds; click the pill, or press ⌘↓, to expand it again.")
        add("open", .mapKeys, [k("⌘↓"), or, tap, space],
            "在对应的 App 里打开对话", "Open the chat in its app",
            "Claude、ChatGPT，或 Claude Code / Codex 会话所在的地方。空格要轻按、鼠标别动；按住是移动导图。",
            "Claude, ChatGPT, or wherever the Claude Code / Codex session runs. Tap space quickly with the mouse still; holding it moves the map instead.")
        add("undo", .mapKeys, [k("⌘Z"), dot, k("⇧⌘Z")],
            "撤销 · 重做（最多 200 步）", "Undo · redo, up to 200 steps",
            "编辑菜单里也有；按键给左栏时也行。在搜索框里或正在改名时，撤销的是刚输入的字。",
            "In the Edit menu too, and while the left column has the keys. In a search field or while typing a name, they undo the typing.")
        add("esc", .mapKeys, [k("esc"), dot, k("⌘A")],
            "取消选择（再按一次收起导图）· 全选", "Deselect (again: put the map away) · select all",
            "什么都没选时按 Esc 收起导图窗口；拖动条目时按 Esc 放回原处。⌘A 选中看得见的全部条目（不含中心点）。",
            "With nothing selected, Esc puts the map window away; while you drag an item, it puts the item back. ⌘A selects everything shown except the centre.")

        // the map, mouse and trackpad
        add("click", .mapMouse, [click],
            "点击选中条目；点空白处取消选择", "Select an item; click empty space to deselect",
            "中心点也能选中。点已选中的几个之一，没拖动就松手，只留下它。",
            "The centre can be selected too. Click one of several selected items and let go without dragging to keep just that one.")
        add("doubleClick", .mapMouse, [g("双击", "double-click", "cursorarrow.click.2")],
            "双击条目改名 · 双击空白处新建主主题", "Rename it · on empty space: a new main topic",
            "新主题直接输入名字。中心点没有名字，双击它没有反应。",
            "The new topic's name is ready to type. The centre has no name, so double-clicking it does nothing.")
        add("dragItem", .mapMouse, [g("拖动条目", "drag an item", "arrow.up.and.down.and.arrow.left.and.right")],
            "拖动条目：连同下面的一起移动", "Move it with everything under it",
            "边拖边让出位置。停在主题中间就放进去，拖过主题外侧就挂到它下面。对话拖到左栏就从导图上拿掉。按 Esc 放回原处。",
            "The map makes room as you drag. Over a topic's middle it goes inside; past its end, under it. Chats dropped on the left column come off the map. Esc puts it back.")
        add("box", .mapMouse, [g("拖空白处", "drag on empty space", "rectangle.dashed")],
            "拖一个框：碰到的都选中", "Select everything a box touches",
            "按住 ⇧ 或 ⌘ 就加到已选的里面；拖到边缘会自动滚动。",
            "Hold ⇧ or ⌘ to add to what's selected. The map scrolls when you reach its edge.")
        add("shiftClick", .mapMouse, [k("⇧"), slash, k("⌘"), click],
            "加选 / 取消选中", "Add to or take out of the selection",
            "拖其中任意一个就一起移动，指针旁显示数量。Tab 这类键只作用于最后点的那个；⌫ 全部删掉。在左栏里 ⇧ 是连续多选。",
            "Drag any of them to move them all, with a count by the pointer. Keys like Tab act on the last one clicked; ⌫ removes them all. In the left column ⇧ picks a range instead.")
        add("pan", .mapMouse, [hold, space],
            "按住空格，移动指针：导图跟着走", "Move around the map: just move the pointer",
            "不用按鼠标（拖也行）。双指滑动、按住 ⌥ 拖、鼠标中键拖也可以，从条目上开始拖也行。",
            "No click needed (dragging works too). Two-finger scrolling, ⌥-drag or the middle mouse button move it as well, even starting on an item.")
        add("pinch", .mapMouse, [g("捏合", "pinch", "arrow.up.left.and.arrow.down.right"), dot, k("⌘0")],
            "缩放导图 · 整张导图放进窗口", "Zoom the map · fit the whole map in",
            "捏合只缩放导图（40%–200%），会被记住。⌘0 让整张导图放进窗口并居中（55%–100%），不会撤销 ⌘+ / ⌘-。",
            "Pinching zooms only the map (40–200 %), and it's remembered. ⌘0 fits the whole map in and centres it, at 55–100 %; it doesn't undo ⌘+ / ⌘-.")
        add("rightClick", .mapMouse, [g("右键", "right-click", "contextualmenu.and.cursorarrow")],
            "分支颜色、图标、标签、打开、折叠…", "Colour, icon, tags, open, collapse and more",
            "会先选中指针下的条目。对话上还有打开、标为未读 / 已读，Claude 对话还有「让 Claude 写总结存档…」；空白处：新主题、导出 PDF…。按住 ⌃ 点也行。",
            "It selects what's under the pointer first. Chats also get Open and Mark unread / read, Claude chats Archive a summary…; empty space: New topic, Export PDF…. ⌃-click works too.")
        add("hoverButtons", .mapMouse, [g("悬停", "hover", "cursorarrow.rays"), dot, k("⇧⌘U")],
            "对话旁的按钮 · 标为未读 / 已读", "Buttons by a chat · mark unread / read",
            "悬停对话或只选中它：↗ 在对应 App 里打开，✉ 标为未读 / 已读（在跑的只有 ↗）。⇧⌘U：选中的对话标为未读，已经全是未读就标为已读。",
            "Hover a chat, or select only it: ↗ opens it, ✉ marks it unread or read (a running chat gets ↗ only). ⇧⌘U: selected chats unread, or read if all are.")

        // the left column
        add("sideClick", .column, [g("点一行", "click a row", "cursorarrow.click")],
            "选中一行，下面这些按键就给左栏", "Pick it; the keys below then go to the list",
            "蓝圈是实心的：按键给左栏；淡蓝：按键在别处。导图上同时选中这个对话（在导图上的话），两边一直同步。点左栏的空白处取消选择。",
            "A solid blue ring: the list has the keys; a pale one: they go elsewhere. The map selects the same chat (if it's on the map); the two stay in step. Click empty space in the list to clear the pick.")
        add("sideArrows", .column, [k("↑↓")],
            "下一行 / 上一行", "Next or previous row",
            "还没选时 ↓ 从第一行、↑ 从最后一行开始；到头就停，会取消多选。",
            "With no row picked, ↓ starts at the top and ↑ at the bottom; it stops at the ends and clears a multi-pick.")
        add("sideOpen", .column, [k("⏎"), or, space, or, k("⌘↓")],
            "在对应的 App 里打开对话", "Open the chat in its app",
            "双击一行也可以。选了好几行时只打开一行：最后 ⌘ 点的那行，或 ⇧ 范围的起点。",
            "Double-clicking a row does it too. With several picked, one opens: the last ⌘-clicked, or where a ⇧ range began.")
        add("sidePick", .column, [k("⌘"), click, dot, k("⇧"), click],
            "多选 · 从选中的那行到这一行全选", "Pick several · a range up to this row",
            "⌘ 加上或去掉一行；⇧ 从上次点的（或用 ↑↓ 选到的）那行一直选到这行。Esc 取消多选。在导图里 ⇧ 是加选一个。",
            "⌘ adds or removes one row; ⇧ picks every row from the last one you clicked or reached with ↑ ↓. Esc clears the extra picks. In the map, ⇧ adds one item instead.")
        add("sideDrag", .column, [g("拖到导图上", "drag onto the map", "arrow.up.and.down.and.arrow.left.and.right")],
            "拖到导图上，放在预览显示的位置", "File chats on the map where the preview shows",
            "拖多选中的任意一行，会按列表顺序全部带上。从导图拖回左栏，就从导图上拿掉。",
            "Drag any picked row to carry them all, in list order. Drag chats from the map back onto the list to take them off the map.")
        add("sideMenu", .column, [g("右键一行", "right-click a row", "contextualmenu.and.cursorarrow")],
            "打开 · 让 Claude 写总结存档… · 置顶会话", "Open · Archive a summary… · pin a session",
            "作用于指针下的那一行，不是选中的那些。Claude Code 会话可以在 KIKUmap 置顶；ChatGPT 和 Codex 的只能打开。",
            "It acts on the row under the pointer, not on the picked ones. Claude Code sessions can be pinned in KIKUmap; ChatGPT and Codex rows just open.")
        add("sideSearch", .column, [g("在搜索框里输入", "type in the search box", "magnifyingglass")],
            "按名字或标题筛选左栏", "Filter the list by name or title",
            "不分大小写、重音和全半角，数字显示 筛出 / 全部。Esc 清空。",
            "Case, accents and full- or half-width don't matter; the count shows matches / all. Esc clears it.")
        add("tags", .column, [g("拖或点标签", "drag or click a tag", "tag")],
            "拖到条目上加标签 · 点一下高亮带它的", "Tag an item · light up all with that tag",
            "标签在左栏下面的标签栏里。再点一次取消高亮。＋ 新建标签，点分类标题可以折叠，右键可以管理标签；拖动标签栏的上边调高度，⌄ 或 ⌃⌘G 收起。窗口太矮又放大时放不下，标签栏会让开：把窗口拉高，或按 ⌘- 缩小。",
            "Tags sit in the shelf under the list. Click the tag again to clear. ＋ makes a tag, a heading folds, right-click manages them; drag the shelf's top edge to resize, ⌄ or ⌃⌘G tucks it away. In a short window zoomed in it steps aside: make the window taller or press ⌘-.")
        add("syncSched", .column, [click],
            "⟳ 马上同步 · 点计划任务打开它的页面", "⟳ syncs now · a scheduled task opens its page",
            "⟳ 就是 ⌘R。开了「用量」才会列出计划任务，点一个打开 claude.ai/code/routines。悬停「置顶对话」标题能看到在读什么、什么时候读。",
            "⟳ is ⌘R. Scheduled tasks are listed once usage is on; one opens claude.ai/code/routines. Hover the Pinned heading to see what's read and when.")

        // the timeline
        add("tlHover", .timeline, [g("悬停", "hover", "cursorarrow.rays")],
            "看时间，以及哪个对话什么时候在跑", "See the time, and which chat ran when",
            "虚线跟着指针，显示日期和时间（未来的带倒计时）；停在运行条或计划任务上显示名字和时间。导图窗口在最前面时才有。",
            "A dashed line follows the pointer with the date and time, counting down for times ahead; over a run or a task, its name and times. While the map window is in front.")
        add("tlScroll", .timeline, [g("拖动", "drag", "arrow.left.and.right"), or, g("双指滑动", "scroll", "arrow.up.arrow.down")],
            "前后移动时间", "Move back and forth in time",
            "两个滚动方向都行，鼠标滚轮一格走得更远。一移动就不再跟随现在，「◎ 现在」变成实心橙色。",
            "Either scroll direction works; a mouse wheel moves further per notch. Once you move, it stops following now and ◎ Now turns solid orange.")
        add("tlZoom", .timeline, [k("⌘"), g("滑动", "scroll", "arrow.up.arrow.down"), or, g("捏合", "pinch", "arrow.up.left.and.arrow.down.right")],
            "以指针为中心缩放时间刻度", "Zoom the time scale around the pointer",
            "每个点 15 秒到 1 小时；缩放也会停止跟随现在。3小时…7天 按钮直接选时长，并重新跟随现在（会记住）。",
            "15 seconds to an hour per point; zooming stops following now too. The 3h … 7d buttons pick a span and follow now again (remembered).")
        add("tlNow", .timeline, [g("双击", "double-click", "cursorarrow.click.2"), or, g("◎ 现在", "◎ Now", "scope")],
            "回到现在并一直跟着", "Back to now, and keep following it",
            "双击时间线下部（点在运行条上，第一下会先打开对话），或点「◎ 现在」。",
            "Double-click the lanes (a bar opens its chat on the first click), or click ◎ Now.")
        add("tlClick", .timeline, [g("点运行条", "click a run", "cursorarrow.click")],
            "在对应的 App 里打开那个对话", "Open that chat in its app",
            "点计划任务（◆ 或跑过的那段）打开 claude.ai/code/routines；点日期条上的某一天就跳过去。",
            "A scheduled task (◆ or a past run) opens claude.ai/code/routines; a day in the day strip jumps to it.")
        return rows
    }

    static func rows(in place: ShortcutPlace) -> [ShortcutRow] { all().filter { $0.place == place } }
}
