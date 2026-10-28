import Foundation

/// A topic in the mind map. Children are topics or chats.
final class MapNode: Codable {
    var id: String
    var title: String
    var color: String?
    /// The mark before a topic's name: "square", "circle", "triangle", "diamond", "cross", "star", or
    /// "none". nil = automatic (main topics get one of the first three, sub-topics none).
    var shape: String?
    var collapsed: Bool?
    var children: [MapItem]

    init(id: String = MapNode.newId(), title: String = "", color: String? = nil, children: [MapItem] = []) {
        self.id = id
        self.title = title
        self.color = color
        self.children = children
    }

    static func newId() -> String {
        "n" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(UInt32.random(in: 0..<1_679_616), radix: 36)
    }

    var isCollapsed: Bool { collapsed ?? false }
}

enum MapItem: Codable {
    case node(MapNode)
    case chat(String)

    private enum CodingKeys: String, CodingKey { case chat }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .chat) {
            self = .chat(id)
        } else {
            self = .node(try MapNode(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .chat(let id):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .chat)
        case .node(let n):
            try n.encode(to: encoder)
        }
    }

    var key: String {
        switch self {
        case .node(let n): return n.id
        case .chat(let id): return "c:" + id
        }
    }

    var node: MapNode? { if case .node(let n) = self { return n }; return nil }
    var chatId: String? { if case .chat(let id) = self { return id }; return nil }
}

/// A label you can put on any topic or chat; several per item.
struct Tag: Codable, Equatable {
    var id: String
    var name: String
    var color: String
    /// "output" (what the chat makes), "status", or nil for your own.
    var group: String?

    static let groups: [(key: String?, zh: String, en: String)] = [("output", "产出", "Output"), ("status", "状态", "Status"), (nil, "我的", "Mine")]
}

struct MapDoc: Codable {
    var v: Int = 1
    var root: MapNode
    var aliases: [String: String]
    /// Set once the first-run topics were created from the chat titles.
    var seeded: Bool?
    var tags: [Tag]?
    /// item key ("c:<chat>" or topic id) → tag ids
    var itemTags: [String: [String]]?
    /// Top-level item key → side of the centre (-1 left, 1 right). Set when the item is created or
    /// dragged and never worked out again: the map must not rearrange itself.
    var sides: [String: Int]?
    /// The starter tags were added once (delete or rename them freely; they don't come back).
    var presets: Bool?
}

/// The user's map: tree operations (MindNode-style) with undo, saved as JSON.
@MainActor
final class MapModel {
    private(set) var doc: MapDoc
    let url: URL
    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private var colorCache: [String: String]?
    private var placedCache: Set<String>?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    var root: MapNode { doc.root }
    var aliases: [String: String] { doc.aliases }

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(MapDoc.self, from: d) {
            doc = m
        } else {
            doc = MapDoc(root: MapNode(id: "root", title: "Claude"), aliases: [:])
        }
        backup()
        addPresetTags()
    }

    /// Starter tags: what a chat produces (like Claude's artifact kinds) and where it stands.
    private static let presetTags: [(String, String, String, String)] = [
            ("视频", "Video", "red", "output"), ("网页", "Web page", "blue", "output"), ("文档", "Document", "teal", "output"),
            ("幻灯片", "Slides", "violet", "output"), ("图片", "Image", "pink", "output"), ("代码", "Code", "indigo", "output"),
            ("进行中", "In progress", "orange", "status"), ("已完成", "Done", "green", "status"),
            ("等别人", "Waiting on others", "yellow", "status"), ("搁置", "On hold", "brown", "status"),
        ]

    private func addPresetTags() {
        guard doc.presets != true else { return }
        let presets = MapModel.presetTags
        var list = doc.tags ?? []
        let have = Set(list.map { $0.name })
        for (zh, en, color, group) in presets where !have.contains(zh) && !have.contains(en) {
            list.append(Tag(id: MapNode.newId() + group, name: tr(zh, en), color: color, group: group))
        }
        doc.tags = list
        doc.presets = true
        save()
    }

    /// Language changed: starter tags you haven't renamed follow it.
    func relabelPresetTags() {
        guard var list = doc.tags else { return }
        var changed = false
        for i in list.indices where list[i].group != nil {
            if let p = MapModel.presetTags.first(where: { $0.0 == list[i].name || $0.1 == list[i].name }), list[i].name != tr(p.0, p.1) {
                list[i].name = tr(p.0, p.1); changed = true
            }
        }
        if changed { doc.tags = list; save() }
    }

    /// Once a day, before the first change, the map as it was is copied to data/backups/map-<date>.json.
    /// The newest 14 are kept.
    private func backup() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent().appendingPathComponent("backups")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let dest = dir.appendingPathComponent("map-\(f.string(from: Date())).json")
        guard !fm.fileExists(atPath: dest.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.copyItem(at: url, to: dest)
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let daily = files.filter { $0.hasPrefix("map-") && $0.hasSuffix(".json") && !$0.hasSuffix("-before.json") }.sorted()
        for old in daily.dropLast(14) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        let safety = files.filter { $0.hasSuffix("-before.json") }.sorted()
        for old in safety.dropLast(30) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
    }

    var isEmpty: Bool { doc.root.children.isEmpty }
    var needsSeed: Bool { isEmpty && doc.seeded != true }

    func save() {
        backup()
        guardAgainstLoss()
        colorCache = nil
        placedCache = nil
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        if let d = try? e.encode(doc) { try? d.write(to: url, options: .atomic) }
    }

    private static func itemCount(_ n: MapNode) -> Int {
        n.children.reduce(0) { $0 + 1 + ($1.node.map(itemCount) ?? 0) }
    }

    /// About to write a map with several items fewer than the one on disk: keep that one first
    /// (backups/map-…-before.json) and note it in logs/app.log.
    private func guardAgainstLoss() {
        guard let d = try? Data(contentsOf: url), let old = try? JSONDecoder().decode(MapDoc.self, from: d) else { return }
        let before = MapModel.itemCount(old.root), now = MapModel.itemCount(doc.root)
        guard before - now >= 5 || (now == 0 && before > 0) else { return }
        let dir = url.deletingLastPathComponent().appendingPathComponent("backups")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: dir.appendingPathComponent("map-\(f.string(from: Date()))-before.json"))
        let logs = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/app.log")
        let line = "\(Clock.iso()) map: \(before) → \(now) items, previous version kept in data/backups\n"
        if let h = try? FileHandle(forWritingTo: logs) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    }

    private func snapshot() -> Data { (try? encoder.encode(doc)) ?? Data() }

    /// Runs a change as one undo step. Returns true when something changed.
    @discardableResult
    func commit(_ change: () -> Void) -> Bool {
        let before = snapshot()
        change()
        fillSides()
        if snapshot() != before {
            undoStack.append(before)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
            save()
            return true
        }
        return false
    }

    func undo() -> Bool {
        guard let d = undoStack.popLast(), let m = try? JSONDecoder().decode(MapDoc.self, from: d) else { return false }
        redoStack.append(snapshot())
        doc = m
        save()
        return true
    }

    func redo() -> Bool {
        guard let d = redoStack.popLast(), let m = try? JSONDecoder().decode(MapDoc.self, from: d) else { return false }
        undoStack.append(snapshot())
        doc = m
        save()
        return true
    }

    // MARK: sides

    func side(of key: String) -> Int? { doc.sides?[key] }

    /// An old map, laid out before sides were recorded: the view records the sides it shows now.
    var needsSides: Bool { doc.sides == nil && !doc.root.children.isEmpty }

    func recordSides(_ s: [String: Int]) {
        doc.sides = s
        save()
    }

    private func setSide(_ key: String, _ side: Int?) {
        guard let side = side else { return }
        if doc.sides == nil { doc.sides = [:] }
        doc.sides?[key] = side
    }

    /// Any top-level item without a side takes the side of the item above it (else below, else right).
    @discardableResult
    func fillSides() -> Bool {
        guard doc.sides != nil else { return false }
        let kids = doc.root.children
        var changed = false
        for (i, k) in kids.enumerated() where doc.sides?[k.key] == nil {
            let above = kids[..<i].reversed().lazy.compactMap { self.doc.sides?[$0.key] }.first
            let below = kids[(i + 1)...].lazy.compactMap { self.doc.sides?[$0.key] }.first
            doc.sides?[k.key] = above ?? below ?? 1
            changed = true
        }
        // forget items that left the top level
        let top = Set(kids.map { $0.key })
        for k in (doc.sides ?? [:]).keys where !top.contains(k) { doc.sides?.removeValue(forKey: k); changed = true }
        return changed
    }

    // MARK: queries

    struct Location {
        let item: MapItem
        let parent: MapNode?
        let index: Int
    }

    func locate(_ key: String) -> Location? {
        if key == doc.root.id { return Location(item: .node(doc.root), parent: nil, index: 0) }
        func search(_ n: MapNode) -> Location? {
            for (i, ch) in n.children.enumerated() {
                if ch.key == key { return Location(item: ch, parent: n, index: i) }
                if let sub = ch.node, let hit = search(sub) { return hit }
            }
            return nil
        }
        return search(doc.root)
    }

    func walkChats(_ n: MapNode, _ f: (String) -> Void) {
        for ch in n.children {
            switch ch {
            case .chat(let id): f(id)
            case .node(let s): walkChats(s, f)
            }
        }
    }

    /// The topics above a chat, outermost first ([] when it isn't on the map).
    func topicPath(ofChat id: String) -> [String] {
        func search(_ n: MapNode, _ path: [String]) -> [String]? {
            for ch in n.children {
                switch ch {
                case .chat(let c): if c == id { return path }
                case .node(let s): if let p = search(s, path + [s.title]) { return p }
                }
            }
            return nil
        }
        return search(doc.root, []) ?? []
    }

    func placedChats() -> Set<String> {
        if let c = placedCache { return c }
        var s = Set<String>()
        walkChats(doc.root) { _ = s.insert($0) }
        placedCache = s
        return s
    }

    func contains(_ n: MapNode, key: String) -> Bool {
        if n.id == key { return true }
        for ch in n.children {
            if ch.key == key { return true }
            if let s = ch.node, contains(s, key: key) { return true }
        }
        return false
    }

    /// Colour key of the nearest coloured topic above a chat.
    func branchColorKey(ofChat id: String) -> String? {
        if colorCache == nil {
            var out: [String: String] = [:]
            func walk(_ n: MapNode, _ inherited: String?) {
                let c = Theme.highlight(n.color) != nil ? n.color : inherited
                for ch in n.children {
                    switch ch {
                    case .chat(let cid): if let c = c { out[cid] = c }
                    case .node(let s): walk(s, c)
                    }
                }
            }
            walk(doc.root, nil)
            colorCache = out
        }
        return colorCache?[id]
    }

    /// Swaps a chat id everywhere (notification-only chat → real id). Not an undo step.
    func renameChat(_ old: String, to new: String) {
        func walk(_ n: MapNode) {
            for (i, ch) in n.children.enumerated() {
                switch ch {
                case .chat(let id): if id == old { n.children[i] = .chat(new) }
                case .node(let s): walk(s)
                }
            }
        }
        walk(doc.root)
        if let a = doc.aliases.removeValue(forKey: old) { doc.aliases[new] = a }
        if let t = doc.itemTags?.removeValue(forKey: "c:" + old) { doc.itemTags?["c:" + new] = t }
        if let sd = doc.sides?.removeValue(forKey: "c:" + old) { doc.sides?["c:" + new] = sd }
        save()
    }

    // MARK: tags

    var tags: [Tag] { doc.tags ?? [] }

    func tags(of key: String) -> [Tag] {
        let ids = doc.itemTags?[key] ?? []
        return tags.filter { ids.contains($0.id) }
    }

    func hasTag(_ key: String, _ tagId: String) -> Bool { doc.itemTags?[key]?.contains(tagId) == true }

    /// Next unused highlight, for a new tag.
    func nextTagColor() -> String {
        let used = Set(tags.map { $0.color })
        return Theme.highlights.first { !used.contains($0.key) }?.key ?? Theme.highlights[tags.count % Theme.highlights.count].key
    }

    @discardableResult
    func addTag(_ name: String, color: String, to key: String? = nil) -> String {
        let t = Tag(id: MapNode.newId(), name: name, color: color)
        commit {
            doc.tags = tags + [t]
            if let k = key { doc.itemTags = doc.itemTags ?? [:]; doc.itemTags?[k, default: []].append(t.id) }
        }
        return t.id
    }

    func updateTag(_ id: String, name: String? = nil, color: String? = nil) {
        guard let i = tags.firstIndex(where: { $0.id == id }) else { return }
        commit {
            if let n = name, !n.isEmpty { doc.tags?[i].name = n }
            if let c = color { doc.tags?[i].color = c }
        }
    }

    func deleteTag(_ id: String) {
        commit {
            doc.tags = tags.filter { $0.id != id }
            if var m = doc.itemTags {
                for (k, v) in m { m[k] = v.filter { $0 != id }; if m[k]?.isEmpty == true { m.removeValue(forKey: k) } }
                doc.itemTags = m
            }
        }
    }

    func toggleTag(_ key: String, _ tagId: String) {
        commit {
            var m = doc.itemTags ?? [:]
            var list = m[key] ?? []
            if let i = list.firstIndex(of: tagId) { list.remove(at: i) } else { list.append(tagId) }
            m[key] = list.isEmpty ? nil : list
            doc.itemTags = m
        }
    }

    // MARK: operations (each is one undo step; returns the key to select)

    func addChild(_ key: String) -> String? {
        guard let loc = locate(key) else { return nil }
        guard let parent = loc.item.node else { return addSibling(key, above: false) }
        let n = MapNode()
        commit {
            parent.collapsed = nil
            parent.children.append(.node(n))
        }
        return n.id
    }

    func addSibling(_ key: String, above: Bool) -> String? {
        guard let loc = locate(key) else { return nil }
        guard let parent = loc.parent else { return addChild(key) }
        let n = MapNode()
        commit {
            parent.children.insert(.node(n), at: above ? loc.index : loc.index + 1)
            if parent === doc.root { setSide(n.id, side(of: loc.item.key)) }     // next to the one you were on
        }
        return n.id
    }

    func addParent(_ key: String) -> String? {
        guard let loc = locate(key), let parent = loc.parent else { return nil }
        let n = MapNode(children: [loc.item])
        commit {
            if parent === doc.root { n.color = loc.item.node?.color; setSide(n.id, side(of: loc.item.key)) }
            parent.children[loc.index] = .node(n)
        }
        return n.id
    }

    /// Removes a topic (with its subtree) or takes a chat off the map. Returns the next selection.
    func remove(_ key: String, keepChildren: Bool) -> String? {
        guard let loc = locate(key), let parent = loc.parent else { return nil }
        let arr = parent.children
        let next: String = loc.index + 1 < arr.count ? arr[loc.index + 1].key
            : (loc.index > 0 ? arr[loc.index - 1].key : parent.id)
        commit {
            parent.children.remove(at: loc.index)
            if keepChildren, let n = loc.item.node {
                parent.children.insert(contentsOf: n.children, at: loc.index)
                if parent === doc.root { for c in n.children { setSide(c.key, side(of: key)) } }
            }
        }
        return next
    }

    func rename(_ key: String, to text: String, chatTitle: String?) {
        guard let loc = locate(key) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        commit {
            switch loc.item {
            case .node(let n):
                n.title = t.isEmpty ? (n === doc.root ? "Claude" : tr("新主题", "New topic")) : t
            case .chat(let id):
                if t.isEmpty || t == chatTitle || t == chatTitle?.strippedPrefix {
                    doc.aliases.removeValue(forKey: id)
                } else {
                    doc.aliases[id] = t
                }
            }
        }
    }

    /// Where a dragged item lands relative to the target.
    enum Drop { case into, before, after }

    private func insert(_ item: MapItem, at target: String, _ drop: Drop, side: Int? = nil) -> Bool {
        guard let t = locate(target) else { return false }
        var parent: MapNode
        if drop == .into, let n = t.item.node {
            n.collapsed = nil
            n.children.append(item)
            parent = n
        } else {
            guard let p = t.parent else { return false }
            p.children.insert(item, at: drop == .before ? t.index : t.index + 1)
            parent = p
        }
        // a top-level item goes on the side you dropped it
        if parent === doc.root { setSide(item.key, side) }
        return true
    }

    /// Drag & drop: into a topic, or before / after any item.
    @discardableResult
    func move(_ key: String, to target: String, _ drop: Drop, side: Int? = nil) -> Bool {
        guard key != target, let loc = locate(key), let parent = loc.parent else { return false }
        if let n = loc.item.node, contains(n, key: target) { return false }
        return commit {
            parent.children.remove(at: loc.index)
            if !insert(loc.item, at: target, drop, side: side) { parent.children.insert(loc.item, at: loc.index) }
        }
    }

    func place(chat id: String, at target: String, _ drop: Drop, side: Int? = nil) {
        if placedChats().contains(id) { move("c:" + id, to: target, drop, side: side); return }
        commit { _ = insert(.chat(id), at: target, drop, side: side) }
    }

    func reorder(_ key: String, by d: Int) {
        guard let loc = locate(key), let p = loc.parent else { return }
        var j = loc.index + d
        // top level: swap with the nearest item on the same side, so it visibly moves
        if p === doc.root, let mine = side(of: key) {
            while j >= 0 && j < p.children.count && side(of: p.children[j].key) != mine { j += d }
        }
        guard j >= 0, j < p.children.count else { return }
        commit { p.children.swapAt(loc.index, j) }
    }

    func setColor(_ key: String, _ name: String?) {
        guard let n = locate(key)?.item.node else { return }
        commit { n.color = name }
    }

    func setShape(_ key: String, _ shape: String?) {
        guard let n = locate(key)?.item.node else { return }
        commit { n.shape = shape }
    }

    func toggleFold(_ key: String) {
        guard let n = locate(key)?.item.node, !n.children.isEmpty, n !== doc.root else { return }
        commit { n.collapsed = n.isCollapsed ? nil : true }
    }

    /// First run: one topic per title prefix ("[Work] …", "[Home] …").
    func seed(from chats: [Chat]) {
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for c in chats {
            guard let g = c.title.titlePrefix else { continue }
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(c.id)
        }
        for g in order {
            let n = MapNode(title: g, children: (groups[g] ?? []).map { .chat($0) })
            doc.root.children.append(.node(n))
        }
        if !order.isEmpty { doc.seeded = true; save() }
    }
}
