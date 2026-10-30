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
    /// "status" (where the work stands), "output" (what the chat makes), or nil / "other" for the rest.
    var group: String?
    /// A Lucide icon's name (nil: a plain dot in its colour).
    var icon: String?

    /// Which of `groups` it's in.
    var category: String { group == "status" || group == "output" ? group! : "other" }
    static let groups: [(key: String, zh: String, en: String)] = [("status", "任务进度", "Progress"), ("output", "产出", "Output"), ("other", "其他", "Other")]
}

struct MapDoc: Codable {
    var v: Int = 1
    var root: MapNode
    var aliases: [String: String]
    var tags: [Tag]?
    /// item key ("c:<chat>" or topic id) → tag ids
    var itemTags: [String: [String]]?
    /// Top-level item key → side of the centre (-1 left, 1 right). Set when the item is created or
    /// dragged and never worked out again: the map must not rearrange itself.
    var sides: [String: Int]?
    /// The starter tags were added once (delete or rename them freely; they don't come back).
    var presets: Bool?
    /// Which set of starter tags has been added (2: with categories and icons).
    var presetsV: Int?
}

/// The user's map: tree operations (MindNode-style) with undo, saved as JSON.
@MainActor
final class MapModel {
    private(set) var doc: MapDoc
    let url: URL
    /// Each snapshot with how many chat ids had changed when it was taken (see `renames`).
    private var undoStack: [(data: Data, gen: Int)] = []
    private var redoStack: [(data: Data, gen: Int)] = []
    private var colorCache: [String: String]?
    private var placedCache: Set<String>?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    var root: MapNode { doc.root }
    var aliases: [String: String] { doc.aliases }
    /// The map on disk couldn't be read: where it was kept (nil: it was read, or there was none yet).
    private(set) var unreadable: String?
    /// The map on disk is left alone this session (it couldn't be moved aside, or a newer Kikumap wrote it).
    private(set) var readOnly = false
    /// Why the map can't be saved right now (nil: it can).
    private(set) var saveError: String?
    /// Chat ids changed this session, in order (old → new). A snapshot taken after the first `gen` of them gets
    /// only the ones after, so a chat filed again under its old id stays.
    private var renames: [(old: String, new: String)] = []

    init(url: URL) {
        self.url = url
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            do {
                let d = try Data(contentsOf: url)
                struct Version: Decodable { var v: Int? }
                if let v = (try? JSONDecoder().decode(Version.self, from: d))?.v, v > 1 {
                    // written by a newer Kikumap: shown empty here, never written over
                    doc = MapDoc(root: MapNode(id: "root", title: "Claude"), aliases: [:])
                    readOnly = true
                    unreadable = "data/map.json" + tr("（新版 Kikumap 存的；现在对导图的改动不会保存）",
                                                      " (saved by a newer Kikumap; changes you make to the map now won't be saved)")
                    return
                }
                doc = try JSONDecoder().decode(MapDoc.self, from: d)
            } catch {
                // there but unreadable: moved aside before anything can write over it
                doc = MapDoc(root: MapNode(id: "root", title: "Claude"), aliases: [:])
                let dir = url.deletingLastPathComponent().appendingPathComponent("backups")
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let to = dir.appendingPathComponent("unreadable-map-" + MapModel.stamp("yyyyMMdd-HHmmss") + ".json")
                if (try? fm.moveItem(at: url, to: to)) != nil { unreadable = "data/backups/" + to.lastPathComponent }
                else {
                    readOnly = true
                    unreadable = "data/map.json" + tr("（没法移开；现在对导图的改动不会保存）",
                                                      " (it couldn't be moved aside; changes you make to the map now won't be saved)")
                }
                MapModel.log(url, "map.json couldn't be read (\(error.localizedDescription)); kept as \(unreadable ?? "-")")
            }
        } else {
            doc = MapDoc(root: MapNode(id: "root", title: "Claude"), aliases: [:])
        }
        backup()
        addPresetTags()
    }

    /// A date for a file name: Gregorian, Latin digits, whatever the Mac's calendar.
    static func stamp(_ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: Date())
    }

    private static func log(_ url: URL, _ text: String) {
        let logs = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("logs/app.log")
        guard let d = "\(Clock.iso()) \(text)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logs) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: d) }
        else { try? d.write(to: logs) }
    }

    /// Starter tags by category: where the work stands, what the chat makes (like Claude's artifact kinds), the rest.
    /// `since`: the set they came with (one you deleted from an earlier set doesn't come back).
    private static let presetTags: [(zh: String, en: String, color: String, group: String, icon: String, since: Int)] = [
        ("未开始", "Not started", "brown", "status", "circle-dashed", 2),
        ("进行中", "In progress", "orange", "status", "loader-circle", 1),
        ("等别人", "Waiting on others", "yellow", "status", "hourglass", 1),
        ("搁置", "On hold", "brown", "status", "circle-pause", 1),
        ("已完成", "Done", "green", "status", "circle-check", 1),
        ("文档", "Document", "teal", "output", "file-text", 1),
        ("网页", "Web page", "blue", "output", "globe", 1),
        ("幻灯片", "Slides", "violet", "output", "presentation", 1),
        ("图片", "Image", "pink", "output", "image", 1),
        ("视频", "Video", "red", "output", "video", 1),
        ("代码", "Code", "indigo", "output", "code-xml", 1),
        ("表格", "Spreadsheet", "green", "output", "sheet", 2),
        ("图表", "Chart", "orange", "output", "chart-column", 2),
        ("重要", "Important", "yellow", "other", "star", 2),
        ("紧急", "Urgent", "red", "other", "flame", 2),
        ("想法", "Idea", "orange", "other", "lightbulb", 2),
        ("调研", "Research", "blue", "other", "microscope", 2),
        ("个人", "Personal", "pink", "other", "user", 2),
    ]

    private func addPresetTags() {
        let done = doc.presetsV ?? (doc.presets == true ? 1 : 0)
        guard done < 2, !readOnly else { return }
        var list = doc.tags ?? []
        for p in MapModel.presetTags {
            if let i = list.firstIndex(where: { $0.name == p.zh || $0.name == p.en }) {
                if list[i].icon == nil { list[i].icon = p.icon }         // one already there gets its icon
            } else if p.since > done {
                list.append(Tag(id: MapNode.newId() + p.group, name: tr(p.zh, p.en), color: p.color, group: p.group, icon: p.icon))
            }
        }
        // the starter tags in their order within each category; your own after them
        func rank(_ t: Tag) -> Int { MapModel.presetTags.firstIndex { $0.zh == t.name || $0.en == t.name } ?? 999 }
        doc.tags = list.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        doc.presets = true
        doc.presetsV = 2
        save()
    }

    /// Language changed: starter tags you haven't renamed follow it.
    func relabelPresetTags() {
        guard var list = doc.tags else { return }
        var changed = false
        for i in list.indices where list[i].group != nil {
            if let p = MapModel.presetTags.first(where: { $0.zh == list[i].name || $0.en == list[i].name }), list[i].name != tr(p.zh, p.en) {
                list[i].name = tr(p.zh, p.en); changed = true
            }
        }
        if changed { doc.tags = list; save() }
    }

    /// Once a day, before the first change, the map as it was is copied to data/backups/map-<date>.json.
    /// The newest 14 are kept (newest by when they were written, so a name in another calendar can't upset it).
    private func backup() {
        let fm = FileManager.default
        guard !readOnly, fm.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent().appendingPathComponent("backups")
        let dest = dir.appendingPathComponent("map-\(MapModel.stamp("yyyy-MM-dd")).json")
        guard !fm.fileExists(atPath: dest.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.copyItem(at: url, to: dest)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        func newestLast(_ names: [String]) -> [String] {
            func date(_ n: String) -> Date { ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(n).path))?[.modificationDate] as? Date) ?? .distantPast }
            return names.sorted { (date($0), $0) < (date($1), $1) }
        }
        let daily = newestLast(files.filter { $0.hasPrefix("map-") && $0.hasSuffix(".json") && !$0.hasSuffix("-before.json") })
        for old in daily.dropLast(14) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        let safety = newestLast(files.filter { $0.hasPrefix("map-") && $0.hasSuffix("-before.json") })
        for old in safety.dropLast(30) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
    }

    func save() {
        // what's placed, and its colours, follow the map in memory, saved or not
        colorCache = nil
        placedCache = nil
        guard !readOnly else { return }
        backup()
        guardAgainstLoss()
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let d = try? e.encode(doc) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: url, options: .atomic)
            saveError = nil
        } catch {
            if saveError == nil { MapModel.log(url, "map.json couldn't be saved: \(error.localizedDescription)") }
            saveError = error.localizedDescription
        }
    }

    /// The last save failed (a full disk, a folder that can't be written): try again, with no change needed.
    func retrySave() { if saveError != nil { save() } }

    private static func itemCount(_ n: MapNode) -> Int {
        n.children.reduce(0) { $0 + 1 + ($1.node.map(itemCount) ?? 0) }
    }

    /// About to write a map with several items fewer than the one on disk: keep that one first
    /// (backups/map-…-before.json) and note it in logs/app.log.
    private func guardAgainstLoss() {
        guard let d = try? Data(contentsOf: url) else { return }
        let dir = url.deletingLastPathComponent().appendingPathComponent("backups")
        // on disk but not readable as a map (a sync tool, a hand edit): kept before it's written over
        guard let old = try? JSONDecoder().decode(MapDoc.self, from: d) else {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? d.write(to: dir.appendingPathComponent("map-\(MapModel.stamp("yyyy-MM-dd-HHmmss"))-before.json"))
            MapModel.log(url, "map: the file on disk couldn't be read, kept in data/backups before saving")
            return
        }
        let before = MapModel.itemCount(old.root), now = MapModel.itemCount(doc.root)
        guard before - now >= 5 || (now == 0 && before > 0) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: dir.appendingPathComponent("map-\(MapModel.stamp("yyyy-MM-dd-HHmmss"))-before.json"))
        MapModel.log(url, "map: \(before) → \(now) items, previous version kept in data/backups")
    }

    private func snapshot() -> Data { (try? encoder.encode(doc)) ?? Data() }

    /// Runs a change as one undo step. Returns true when something changed.
    @discardableResult
    func commit(_ change: () -> Void) -> Bool {
        let before = snapshot()
        change()
        fillSides()
        if snapshot() != before {
            undoStack.append((before, renames.count))
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
            save()
            return true
        }
        return false
    }

    func undo() -> Bool {
        guard let s = undoStack.popLast(), let m = restore(s) else { return false }
        redoStack.append((snapshot(), renames.count))
        doc = m
        save()
        return true
    }

    func redo() -> Bool {
        guard let s = redoStack.popLast(), let m = restore(s) else { return false }
        undoStack.append((snapshot(), renames.count))
        doc = m
        save()
        return true
    }

    /// A snapshot as it would be now: chats that got new ids after it was taken take their places, names, tags and
    /// sides along (the renames before it are in it already).
    private func restore(_ s: (data: Data, gen: Int)) -> MapDoc? {
        guard var m = try? JSONDecoder().decode(MapDoc.self, from: s.data) else { return nil }
        for r in renames.dropFirst(s.gen) { MapModel.rename(r.old, to: r.new, in: &m) }
        return m
    }

    /// One chat id for another everywhere in a map; if the new id is already placed, the old entry goes (no twins).
    private static func rename(_ old: String, to new: String, in d: inout MapDoc) {
        func placed(_ n: MapNode) -> Bool { n.children.contains { $0.chatId == new || ($0.node.map(placed) ?? false) } }
        let twin = placed(d.root)
        func walk(_ n: MapNode) {
            var out: [MapItem] = []
            for ch in n.children {
                switch ch {
                case .chat(let id) where id == old: if !twin { out.append(.chat(new)) }
                case .node(let s): walk(s); out.append(ch)
                default: out.append(ch)
                }
            }
            n.children = out
        }
        walk(d.root)
        if let a = d.aliases.removeValue(forKey: old), d.aliases[new] == nil { d.aliases[new] = a }
        if let t = d.itemTags?.removeValue(forKey: "c:" + old), d.itemTags?["c:" + new] == nil { d.itemTags?["c:" + new] = t }
        if let sd = d.sides?.removeValue(forKey: "c:" + old), d.sides?["c:" + new] == nil { d.sides?["c:" + new] = sd }
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
        guard old != new else { return }
        MapModel.rename(old, to: new, in: &doc)
        // undo / redo snapshots taken before this still name the old id: they're brought along when restored
        renames.append((old, new))
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
    func addTag(_ name: String, color: String, icon: String? = nil, group: String? = nil, to key: String? = nil) -> String {
        let t = Tag(id: MapNode.newId(), name: name, color: color, group: group, icon: icon)
        commit {
            doc.tags = tags + [t]
            if let k = key { doc.itemTags = doc.itemTags ?? [:]; doc.itemTags?[k, default: []].append(t.id) }
        }
        return t.id
    }

    func updateTag(_ id: String, name: String? = nil, color: String? = nil, icon: String?? = nil, group: String? = nil) {
        guard let i = tags.firstIndex(where: { $0.id == id }) else { return }
        commit {
            if let n = name, !n.isEmpty { doc.tags?[i].name = n }
            if let c = color { doc.tags?[i].color = c }
            if let ic = icon { doc.tags?[i].icon = ic }
            if let g = group { doc.tags?[i].group = g }
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

    /// Several items into one place, keeping the order given, as one undo step. Chats that aren't
    /// on the map yet (picked in the left column) are placed there.
    @discardableResult
    func move(_ keys: [String], to target: String, _ drop: Drop, side: Int? = nil) -> Bool {
        commit {
            var at = target
            for k in keys where k != target {
                var placed: Bool
                if let loc = locate(k) {
                    guard let parent = loc.parent else { continue }
                    if let n = loc.item.node, contains(n, key: target) { continue }
                    parent.children.remove(at: loc.index)
                    placed = insert(loc.item, at: at, drop, side: side)
                    if !placed { parent.children.insert(loc.item, at: loc.index) }
                } else if k.hasPrefix("c:") {
                    placed = insert(.chat(String(k.dropFirst(2))), at: at, drop, side: side)
                } else {
                    continue
                }
                if placed && drop == .after { at = k }        // each goes after the one before it
            }
        }
    }

    /// Removes several items as one undo step: topics with what's under them, chats back to the left column.
    func remove(_ keys: [String]) {
        commit {
            for k in keys {
                if let loc = locate(k), let parent = loc.parent { parent.children.remove(at: loc.index) }
            }
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
        if j >= 0, j < p.children.count { commit { p.children.swapAt(loc.index, j) }; return }
        // at the end of its siblings: on into the next topic at its parent's level (the side stays the same)
        guard p !== doc.root, let up = locate(p.id), let gp = up.parent else { return }
        var i = up.index + d
        while i >= 0, i < gp.children.count {
            if let next = gp.children[i].node, gp !== doc.root || side(of: next.id) == side(of: p.id) {
                commit {
                    p.children.remove(at: loc.index)
                    next.collapsed = nil
                    if d > 0 { next.children.insert(loc.item, at: 0) } else { next.children.append(loc.item) }
                }
                return
            }
            i += d
        }
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
}
