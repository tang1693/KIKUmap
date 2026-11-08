import Foundation
import Compression

/// Reads the zip you get from Claude → Settings → Privacy → Export data: every conversation with its
/// messages, the artifacts and files Claude made, and the text of what you uploaded.
struct ExportedChat {
    struct Message { let human: Bool; let time: String; let text: String; let files: [String] }
    struct File { let name: String; let content: String }
    let id: String
    let name: String
    let messages: [Message]
    let artifacts: [File]
    let attachments: [File]
}

enum ClaudeExport {
    /// Looking through ~/Downloads makes macOS ask about that folder unless KIKUmap has Full Disk Access,
    /// so without it nothing is looked for by itself: you pick the zip, and the open panel needs no prompt. KIKUmap
    /// reads the zip itself (ZipFile): the open panel's yes is for KIKUmap only, so a helper program reading it (unzip)
    /// could have macOS ask about Downloads after all.
    static var canLookInDownloads: Bool {
        let tcc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let h = FileHandle(forReadingAtPath: tcc.path) else { return false }
        try? h.close()
        return true
    }

    /// The newest zip in ~/Downloads that's Claude's export (nil without Full Disk Access).
    static func newestZip() -> URL? {
        guard canLookInDownloads else { return nil }
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(at: dl, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let zips = files.filter { $0.pathExtension.lowercased() == "zip" }
            .sorted { modified($0) > modified($1) }
        for z in zips.prefix(12) where isClaude(z) { return z }
        return nil
    }

    /// Claude's export, not another app's: ChatGPT's has a conversations.json too, but only Claude's has a users.json
    /// beside it (ChatGPT's is user.json).
    static func isClaude(_ zip: URL) -> Bool {
        guard let names = ZipFile.entries(zip)?.map(\.name) else { return false }
        let convos = Set(names.compactMap { folder($0, of: "conversations.json") })
        return names.contains { folder($0, of: "users.json").map(convos.contains) == true }
    }

    /// The folder an entry of the zip is `file` in ("" at the top), or nil: it's another file.
    private static func folder(_ entry: String, of file: String) -> String? {
        entry == file ? "" : entry.hasSuffix("/" + file) ? String(entry.dropLast(file.count)) : nil
    }

    static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// (Nothing is unpacked into it anymore: the zip is read in KIKUmap's own process. Kept for the checks that point
    /// it at a folder they can write in.)
    nonisolated(unsafe) static var scratch = FileManager.default.temporaryDirectory

    /// Reads conversations.json out of the zip (Claude's: the one with users.json beside it) and every chat in it,
    /// keyed by its id (nil: it can't be read). `claude` is false when it holds chats but none of Claude's shape (a uuid
    /// and chat_messages): another app's export, nothing to use.
    static func load(_ zip: URL) -> (chats: [String: ExportedChat], claude: Bool)? {
        guard let all = ZipFile.entries(zip) else { return nil }
        let convos = all.filter { folder($0.name, of: "conversations.json") != nil }
        let users = Set(all.compactMap { folder($0.name, of: "users.json") })
        guard let entry = convos.first(where: { folder($0.name, of: "conversations.json").map(users.contains) == true }) ?? convos.first,
              let data = ZipFile.read(zip, entry),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var out: [String: ExportedChat] = [:], shaped = false
        for c in list {
            guard let id = (c["uuid"] as? String)?.lowercased() else { continue }
            shaped = shaped || c["chat_messages"] is [Any]
            out[id] = chat(c, id: id)
        }
        return (out, shaped || list.isEmpty)
    }

    private static func chat(_ c: [String: Any], id: String) -> ExportedChat {
        var messages: [ExportedChat.Message] = []
        var artifacts: [String: (title: String, type: String, lang: String, content: String)] = [:]
        var artifactOrder: [String] = []
        var files: [String: String] = [:]
        var fileOrder: [String] = []
        var attachments: [ExportedChat.File] = []

        func artifact(_ input: [String: Any]) -> String {
            let aid = input["id"] as? String ?? "artifact-\(artifactOrder.count + 1)"
            var a = artifacts[aid] ?? (title: aid, type: "", lang: "", content: "")
            if let t = input["title"] as? String, !t.isEmpty { a.title = t }
            if let t = input["type"] as? String, !t.isEmpty { a.type = t }
            if let l = input["language"] as? String, !l.isEmpty { a.lang = l }
            switch input["command"] as? String ?? "create" {
            case "update":
                if let o = input["old_str"] as? String, let n = input["new_str"] as? String, let r = a.content.range(of: o) {
                    a.content.replaceSubrange(r, with: n)
                }
            default:
                if let body = input["content"] as? String { a.content = body }
            }
            if artifacts[aid] == nil { artifactOrder.append(aid) }
            artifacts[aid] = a
            return a.title
        }
        func file(_ name: String, _ input: [String: Any]) -> String? {
            guard let path = input["path"] as? String ?? input["file_path"] as? String else { return nil }
            if name == "str_replace" {
                guard var cur = files[path], let o = input["old_str"] as? String, let n = input["new_str"] as? String,
                      let r = cur.range(of: o) else { return path }
                cur.replaceSubrange(r, with: n)
                files[path] = cur
            } else if let body = input["file_text"] as? String ?? input["content"] as? String {
                if files[path] == nil { fileOrder.append(path) }
                files[path] = body
            } else {
                return nil
            }
            return path
        }

        for m in c["chat_messages"] as? [[String: Any]] ?? [] {
            let human = (m["sender"] as? String) == "human"
            var parts: [String] = []
            if let blocks = m["content"] as? [[String: Any]], !blocks.isEmpty {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text": if let t = b["text"] as? String, !t.isEmpty { parts.append(t) }
                    case "tool_use":
                        let name = b["name"] as? String ?? "tool"
                        let input = b["input"] as? [String: Any] ?? [:]
                        if name == "artifacts" {
                            parts.append("[Artifact: \(artifact(input))]")
                        } else if ["create_file", "str_replace", "file_create", "write_file"].contains(name), let p = file(name, input) {
                            parts.append("[File: \((p as NSString).lastPathComponent)]")
                        } else {
                            parts.append("[\(name)]")
                        }
                    default: break
                    }
                }
            } else if let t = m["text"] as? String {
                parts.append(t)
            }
            var text = parts.joined(separator: "\n\n")
            // older exports: artifacts written inline in the reply
            text = inlineArtifacts(text) { input in artifact(input) }
            var names: [String] = []
            for a in m["attachments"] as? [[String: Any]] ?? [] {
                let n = a["file_name"] as? String ?? "attachment"
                names.append(n)
                if let t = a["extracted_content"] as? String, !t.isEmpty { attachments.append(.init(name: n, content: t)) }
            }
            for f in m["files"] as? [[String: Any]] ?? [] { if let n = f["file_name"] as? String { names.append(n) } }
            messages.append(.init(human: human, time: m["created_at"] as? String ?? "", text: text, files: names))
        }

        var made: [ExportedChat.File] = artifactOrder.compactMap { aid in
            guard let a = artifacts[aid], !a.content.isEmpty else { return nil }
            return .init(name: a.title + "." + ext(type: a.type, lang: a.lang), content: a.content)
        }
        made += fileOrder.compactMap { p in files[p].map { .init(name: (p as NSString).lastPathComponent, content: $0) } }
        return ExportedChat(id: id, name: c["name"] as? String ?? "", messages: messages, artifacts: made, attachments: attachments)
    }

    private static let inlineRx = try! NSRegularExpression(pattern: #"<antArtifact([^>]*)>([\s\S]*?)</antArtifact>"#)
    private static let attrRx = try! NSRegularExpression(pattern: #"(\w+)="([^"]*)""#)

    private static func inlineArtifacts(_ text: String, _ add: ([String: Any]) -> String) -> String {
        let ns = text as NSString
        let hits = inlineRx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !hits.isEmpty else { return text }
        var out = text
        for h in hits.reversed() {
            let attrs = ns.substring(with: h.range(at: 1)) as NSString
            var input: [String: Any] = ["content": ns.substring(with: h.range(at: 2)).trimmingCharacters(in: .newlines)]
            for a in attrRx.matches(in: attrs as String, range: NSRange(location: 0, length: attrs.length)) {
                let k = attrs.substring(with: a.range(at: 1)), v = attrs.substring(with: a.range(at: 2))
                input[k == "identifier" ? "id" : k] = v
            }
            let title = add(input)
            out = (out as NSString).replacingCharacters(in: h.range, with: "[Artifact: \(title)]")
        }
        return out
    }

    static func ext(type: String, lang: String) -> String {
        let byLang = ["python": "py", "javascript": "js", "typescript": "ts", "html": "html", "css": "css", "swift": "swift",
                      "json": "json", "bash": "sh", "shell": "sh", "sh": "sh", "sql": "sql", "java": "java", "cpp": "cpp",
                      "c++": "cpp", "c": "c", "go": "go", "rust": "rs", "ruby": "rb", "markdown": "md", "yaml": "yml",
                      "jsx": "jsx", "tsx": "tsx", "kotlin": "kt", "r": "r", "php": "php", "latex": "tex", "csv": "csv"]
        if let e = byLang[lang.lowercased()] { return e }
        switch type {
        case "text/markdown": return "md"
        case "text/html": return "html"
        case "image/svg+xml": return "svg"
        case "application/vnd.ant.react": return "jsx"
        case "application/vnd.ant.mermaid": return "mmd"
        default: return "txt"
        }
    }

    // MARK: writing a chat's folder

    /// prompts.md, conversation.md, artifacts/ and attachments/ in `dir`.
    static func write(_ c: ExportedChat, title: String, to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func when(_ s: String) -> String {
            guard let d = Clock.parseAny(s) else { return "" }
            return Clock.format(d, "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm")
        }
        var prompts = "# " + tr("提示词", "Prompts") + " · \(title)\n"
        var convo = "# \(title)\n"
        var n = 0
        for m in c.messages {
            let files = m.files.isEmpty ? "" : "\n\n" + m.files.map { "📎 " + $0 }.joined(separator: "\n")
            if m.human {
                n += 1
                prompts += "\n## \(n) · \(when(m.time))\n\n\(m.text)\(files)\n"
            }
            convo += "\n---\n\n**\(m.human ? tr("我", "Me") : "Claude")** · \(when(m.time))\n\n\(m.text)\(files)\n"
        }
        try prompts.write(to: dir.appendingPathComponent("prompts.md"), atomically: true, encoding: .utf8)
        try convo.write(to: dir.appendingPathComponent("conversation.md"), atomically: true, encoding: .utf8)
        func put(_ list: [ExportedChat.File], _ sub: String, suffix: String = "") throws {
            guard !list.isEmpty else { return }
            let d = dir.appendingPathComponent(sub)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            var used = Set<String>()
            for f in list {
                var name = safeName(f.name) + suffix
                if used.contains(name) { name = "\(used.count + 1)-" + name }
                used.insert(name)
                try f.content.write(to: d.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        try put(c.artifacts, "artifacts")
        try put(c.attachments, "attachments", suffix: ".txt")
    }

    /// A name every disk takes: besides / and :, what FAT, exFAT and SMB shares refuse (? * < > | " \ and control
    /// characters), so an export onto a USB stick or a network drive doesn't fail on a title like "Why?".
    static func safeName(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"[/:\\?*<>|"\p{Cc}]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix(".") { t = "_" + t }
        if t.isEmpty { t = "untitled" }
        return t.count > 90 ? String(t.prefix(90)) : t
    }
}

/// A zip read in KIKUmap's own process: the list of what's in it, and one entry's contents (stored or deflated;
/// zip64 too). What's picked in an open panel is KIKUmap's to read, not a helper program's.
enum ZipFile {
    struct Entry { let name: String; let method: Int; let flags: Int; let compressed: UInt64; let size: UInt64; let offset: UInt64 }

    /// Everything in the zip, from its central directory (nil: not a zip, or one cut short).
    static func entries(_ url: URL) -> [Entry]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd(), end >= 22 else { return nil }
        // the end record is in the last 22 bytes, or before a comment of up to 64 KB
        let from = end - min(end, 22 + 65535)
        guard let tail = read(h, at: from, count: Int(end - from)) else { return nil }
        guard let at = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            sig(tail, $0, 0x0605_4b50) && $0 + 22 + u16(tail, $0 + 20) <= tail.count
        }) else { return nil }
        var count = UInt64(u16(tail, at + 10)), size = UInt64(u32(tail, at + 12)), start = UInt64(u32(tail, at + 16))
        // zip64: the real numbers are in an end record of its own, which a locator right before this one points to
        if count == 0xFFFF || size == 0xFFFF_FFFF || start == 0xFFFF_FFFF {
            guard from + UInt64(at) >= 20, let loc = read(h, at: from + UInt64(at) - 20, count: 20), sig(loc, 0, 0x0706_4b50),
                  let rec = read(h, at: u64(loc, 8), count: 56), sig(rec, 0, 0x0606_4b50) else { return nil }
            count = u64(rec, 32); size = u64(rec, 40); start = u64(rec, 48)
        }
        guard count < 1 << 24, size < 1 << 31, let dir = read(h, at: start, count: Int(size)) else { return nil }
        var out: [Entry] = [], p = 0
        for _ in 0..<count {
            guard p + 46 <= dir.count, sig(dir, p, 0x0201_4b50) else { return nil }
            let n = u16(dir, p + 28), x = u16(dir, p + 30), c = u16(dir, p + 32)
            guard p + 46 + n + x + c <= dir.count else { return nil }
            var comp = UInt64(u32(dir, p + 20)), size = UInt64(u32(dir, p + 24)), offset = UInt64(u32(dir, p + 42))
            // zip64: those that didn't fit are in its extra field, in this order
            var e = p + 46 + n
            while e + 4 <= p + 46 + n + x {
                // (a length running past the field, in a damaged zip, is cut to it)
                let id = u16(dir, e), stop = min(e + 4 + u16(dir, e + 2), p + 46 + n + x)
                var q = e + 4
                func next(_ v: inout UInt64) { if v == 0xFFFF_FFFF && q + 8 <= stop { v = u64(dir, q); q += 8 } }
                if id == 1 { next(&size); next(&comp); next(&offset) }
                e = stop
            }
            out.append(Entry(name: String(decoding: dir[(p + 46)..<(p + 46 + n)], as: UTF8.self), method: u16(dir, p + 10),
                             flags: u16(dir, p + 8), compressed: comp, size: size, offset: offset))
            p += 46 + n + x + c
        }
        return out
    }

    /// One entry's contents, inflated a megabyte at a time (nil: it can't be read: locked with a password, packed some
    /// other way than stored or deflated, or cut short).
    static func read(_ url: URL, _ e: Entry) -> Data? {
        guard e.flags & 1 == 0, e.method == 0 || e.method == 8, let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = read(h, at: e.offset, count: 30), sig(head, 0, 0x0403_4b50),
              (try? h.seek(toOffset: e.offset + 30 + UInt64(u16(head, 26)) + UInt64(u16(head, 28)))) != nil else { return nil }
        var out = Data()
        var inflate: OutputFilter?
        if e.method == 8 {
            guard let f = try? OutputFilter(.decompress, using: .zlib, writingTo: { if let d = $0 { out.append(d) } }) else { return nil }
            inflate = f
        }
        var left = e.compressed
        while left > 0 {
            guard let chunk = try? h.read(upToCount: Int(min(left, 1 << 20))), !chunk.isEmpty else { return nil }
            if let f = inflate { guard (try? f.write(chunk)) != nil else { return nil } } else { out.append(chunk) }
            left -= UInt64(chunk.count)
        }
        if let f = inflate { guard (try? f.finalize()) != nil else { return nil } }
        return UInt64(out.count) == e.size ? out : nil
    }

    private static func read(_ h: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard (try? h.seek(toOffset: offset)) != nil, let d = try? h.read(upToCount: count), d.count == count else { return count == 0 ? [] : nil }
        return [UInt8](d)
    }
    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }
    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }
    private static func sig(_ b: [UInt8], _ i: Int, _ s: UInt32) -> Bool { i >= 0 && i + 4 <= b.count && UInt32(u32(b, i)) == s }
}
