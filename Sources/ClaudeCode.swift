import Cocoa

// Claude Code sessions (terminal, VS Code, the desktop app's Code mode) report what they do through
// Claude Code hooks: a tiny script appends one line per event to a file this app watches.

struct CodeEvent {
    let time: Date
    let app: String            // bundle id (or TERM_PROGRAM) of the app the session runs in
    let name: String           // hook_event_name
    let session: String
    let cwd: String
    let transcript: String
    let message: String
}

/// Installs / removes the hook entries in ~/.claude/settings.json.
@MainActor
enum CodeHooks {
    static let marker = "ClaudeConsole/cc-hook.sh"
    static let events = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaudeConsole")
    }
    static var script: URL { dir.appendingPathComponent("cc-hook.sh") }
    static var eventsFile: URL { dir.appendingPathComponent("code-events.jsonl") }
    static var settings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }

    /// Pulls a few top-level fields out of the hook's JSON with grep (no jq needed) and writes one
    /// short line. It never fails, so it can't get in Claude Code's way.
    static let scriptText = """
    #!/bin/sh
    # Kikumap (menu-bar app): note what this Claude Code session is doing. Always succeeds.
    d="$HOME/Library/Application Support/ClaudeConsole"
    in=$(tr -d '\\n\\r' | cut -c 1-65536)
    f() { printf '%s' "$in" | grep -o "\\"$1\\" *: *\\"[^\\"]*\\"" | head -n 1; }
    s=$(f session_id); [ -n "$s" ] || exit 0
    line="$s"
    for k in hook_event_name cwd transcript_path message; do v=$(f $k); [ -n "$v" ] && line="$line,$v"; done
    mkdir -p "$d" 2>/dev/null
    printf '{"t":%s,"app":"%s",%s}\\n' "$(date +%s)" "${__CFBundleIdentifier:-$TERM_PROGRAM}" "$line" >> "$d/code-events.jsonl" 2>/dev/null
    exit 0

    """

    static var command: String { "\"\(script.path)\"" }

    private static func readSettings() -> [String: Any]? {
        guard let d = try? Data(contentsOf: settings) else { return [:] }          // no file yet: start one
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]       // nil = not valid JSON: don't touch
    }

    private static func ours(_ entry: Any) -> Bool {
        guard let e = entry as? [String: Any], let hs = e["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    static var installed: Bool {
        guard let s = readSettings(), let hooks = s["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [Any] else { return false }
        return stop.contains(where: ours) && FileManager.default.isExecutableFile(atPath: script.path)
    }

    /// Adds our entries next to whatever hooks you already have. Returns an error message, or nil.
    static func install() -> String? {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try scriptText.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch { return error.localizedDescription }
        guard var s = readSettings() else {
            return tr("~/.claude/settings.json 不是有效的 JSON，没有改动它。", "~/.claude/settings.json isn't valid JSON, so it was left alone.")
        }
        if FileManager.default.fileExists(atPath: settings.path) {
            let backup = settings.deletingLastPathComponent().appendingPathComponent("settings.json.before-claude-console")
            if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: settings, to: backup) }
        }
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var list = (hooks[ev] as? [Any] ?? []).filter { !ours($0) }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            if ev == "PostToolUse" { entry["matcher"] = "*" }
            list.append(entry)
            hooks[ev] = list
        }
        s["hooks"] = hooks
        return write(s)
    }

    static func uninstall() -> String? {
        guard var s = readSettings() else { return nil }
        guard var hooks = s["hooks"] as? [String: Any] else { return nil }
        for ev in events {
            let list = (hooks[ev] as? [Any] ?? []).filter { !ours($0) }
            hooks[ev] = list.isEmpty ? nil : list
        }
        s["hooks"] = hooks.isEmpty ? nil : hooks
        return write(s)
    }

    private static func write(_ s: [String: Any]) -> String? {
        do {
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            let d = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try d.write(to: settings, options: .atomic)
            return nil
        } catch { return error.localizedDescription }
    }

    /// The session's name as Claude Code shows it (your rename if any, otherwise its own title), and
    /// whether it's linked to the Claude app (Remote Control) — then the Claude app's pinned chat stands for it.
    nonisolated static func info(transcript path: String) -> (title: String?, linked: Bool) {
        guard !path.isEmpty, let h = FileHandle(forReadingAtPath: path) else { return (nil, false) }
        defer { try? h.close() }
        guard let data = try? h.readToEnd() else { return (nil, false) }
        func last(_ key: String) -> String? {
            guard let k = "\"\(key)\":\"".data(using: .utf8),
                  let r = data.range(of: k, options: .backwards) else { return nil }
            // read the JSON string that follows (it may contain escapes)
            var end = r.upperBound
            var escaped = false
            while end < data.endIndex {
                let b = data[end]
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { break }
                end += 1
            }
            let raw = Data([0x22]) + data[r.upperBound..<end] + Data([0x22])
            let s = (try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)) as? String
            return s?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let linked = "\"type\":\"bridge-session\"".data(using: .utf8).flatMap { data.range(of: $0) } != nil
        return (last("customTitle") ?? last("aiTitle"), linked)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Reads new lines from the events file as the hooks append them.
@MainActor
final class CodeWatcher {
    var onEvents: (([CodeEvent]) -> Void)?
    private var watcher: FileWatcher?
    private let offsetKey = "CodeEventsOffset"

    func start() {
        let dir = CodeHooks.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // first run: start from now, not from old history
        if UserDefaults.standard.object(forKey: offsetKey) == nil {
            let size = ((try? FileManager.default.attributesOfItem(atPath: CodeHooks.eventsFile.path))?[.size] as? NSNumber)?.intValue ?? 0
            UserDefaults.standard.set(size, forKey: offsetKey)
        }
        watcher = FileWatcher(paths: [dir.path], latency: 0.3) { [weak self] in self?.read() }
        read()
    }

    func read() {
        let url = CodeHooks.eventsFile
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var offset = UInt64(UserDefaults.standard.integer(forKey: offsetKey))
        if size < offset { offset = 0 }                       // the file was cleared
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        guard let data = try? h.read(upToCount: Int(size - offset)),
              let lastNL = data.lastIndex(of: 0x0A) else { return }  // only whole lines
        let chunk = data[data.startIndex...lastNL]
        offset += UInt64(chunk.count)
        var out: [CodeEvent] = []
        for line in chunk.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let s = o["session_id"] as? String, let n = o["hook_event_name"] as? String else { continue }
            out.append(CodeEvent(time: Date(timeIntervalSince1970: (o["t"] as? Double) ?? Date().timeIntervalSince1970),
                                 app: o["app"] as? String ?? "", name: n, session: s,
                                 cwd: o["cwd"] as? String ?? "", transcript: o["transcript_path"] as? String ?? "",
                                 message: o["message"] as? String ?? ""))
        }
        // keep the file small: once everything is read, start it over
        if offset == size && size > 2_000_000 {
            try? Data().write(to: url)
            offset = 0
        }
        UserDefaults.standard.set(Int(offset), forKey: offsetKey)
        if !out.isEmpty { onEvents?(out) }
    }
}
