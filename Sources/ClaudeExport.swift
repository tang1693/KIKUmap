import Foundation

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
    /// so without it nothing is looked for by itself: you pick the zip, and the open panel needs no prompt.
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
        let names = run(["-Z1", zip.path]).out.split(separator: "\n")
        func folder(_ entry: Substring, of file: String) -> Substring? {
            entry == file ? "" : entry.hasSuffix("/" + file) ? entry.dropLast(file.count) : nil
        }
        let convos = Set(names.compactMap { folder($0, of: "conversations.json") })
        return names.contains { folder($0, of: "users.json").map(convos.contains) == true }
    }

    static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func run(_ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (false, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    /// Where conversations.json is unpacked to be read (a test points it at a folder it can write in).
    nonisolated(unsafe) static var scratch = FileManager.default.temporaryDirectory

    /// Unpacks conversations.json and reads every chat, keyed by its id (nil: it can't be read). `claude` is false when
    /// it holds chats but none of Claude's shape (a uuid and chat_messages): another app's export, nothing to use.
    static func load(_ zip: URL) -> (chats: [String: ExportedChat], claude: Bool)? {
        let tmp = scratch.appendingPathComponent("claude-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard run(["-o", "-q", zip.path, "*conversations.json", "-d", tmp.path]).ok else { return nil }
        let found = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "conversations.json" }
        guard let file = found, let data = try? Data(contentsOf: file),
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
