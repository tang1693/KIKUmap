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
    /// Notification: what it's about ("permission_prompt", "idle_prompt"…); StopFailure: the API error.
    var kind = ""
    var error = ""
    /// How Claude Code was started ("cli", "claude-vscode", "claude-desktop"; "sdk-…" for `claude -p` and scripts).
    var entry = ""
}

/// Installs / removes the hook entries in ~/.claude/settings.json.
@MainActor
enum CodeHooks {
    static let marker = "ClaudeConsole/cc-hook.sh"
    /// StopFailure comes instead of Stop when an API error (a limit, an outage) ended the turn.
    static let events = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "StopFailure", "SessionEnd"]

    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaudeConsole")
    }
    static var script: URL { dir.appendingPathComponent("cc-hook.sh") }
    static var eventsFile: URL { dir.appendingPathComponent("code-events.jsonl") }
    static var settings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }

    /// Pulls a few top-level fields out of the hook's JSON with grep (no jq needed) and writes one
    /// short line. It never fails, so it can't get in Claude Code's way. The file it writes is started over past
    /// 10 MB (Kikumap may not run for a long time).
    static let scriptText = """
    #!/bin/sh
    # Kikumap (menu-bar app): note what this Claude Code session is doing. Always succeeds.
    d="$HOME/Library/Application Support/ClaudeConsole"
    o="$d/code-events.jsonl"
    in=$(tr -d '\\n\\r' | cut -c 1-65536)
    f() { printf '%s' "$in" | grep -o -E "\\"$1\\" *: *\\"([^\\"\\\\\\\\]|\\\\\\\\.)*\\"" | head -n 1; }
    s=$(f session_id); [ -n "$s" ] || exit 0
    e=$(f hook_event_name)
    line="$s,$e"
    for k in cwd transcript_path; do v=$(f $k); [ -n "$v" ] && line="$line,$v"; done
    case "$e" in
      *'"Notification"'*) for k in message notification_type; do v=$(f $k); [ -n "$v" ] && line="$line,$v"; done;;
      *'"StopFailure"'*) for k in error agent_id; do v=$(f $k); [ -n "$v" ] && line="$line,$v"; done;;
    esac
    mkdir -p "$d" 2>/dev/null
    [ "$(stat -f %z "$o" 2>/dev/null || echo 0)" -gt 10000000 ] 2>/dev/null && : > "$o"
    ep=$(printf '%s' "$CLAUDE_CODE_ENTRYPOINT" | tr -cd 'A-Za-z0-9_.-')
    printf '{"t":%s,"app":"%s","ep":"%s",%s}\\n' "$(date +%s)" "${__CFBundleIdentifier:-$TERM_PROGRAM}" "$ep" "$line" >> "$o" 2>/dev/null
    exit 0

    """

    static var command: String { "\"\(script.path)\"" }

    /// ~/.claude/settings.json: not there yet, read, or there but not readable / not valid JSON (then it's never
    /// touched).
    private enum Read { case missing, ok([String: Any]), unreadable, invalid }

    private static func readSettings() -> Read {
        let fm = FileManager.default, path = settings.path
        // a link, even a broken one, counts as there
        if !fm.fileExists(atPath: path) && (try? fm.destinationOfSymbolicLink(atPath: path)) == nil { return .missing }
        guard let d = try? Data(contentsOf: settings) else { return .unreadable }
        if d.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return .ok([:]) }
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .invalid }
        return .ok(o)
    }

    private static func settingsObject() -> [String: Any]? {
        if case .ok(let o) = readSettings() { return o }
        return nil
    }

    private static func ours(_ entry: Any) -> Bool {
        guard let e = entry as? [String: Any], let hs = e["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    static var installed: Bool {
        guard let s = settingsObject(), let hooks = s["hooks"] as? [String: Any],
              let stop = hooks["Stop"] as? [Any] else { return false }
        return stop.contains(where: ours) && FileManager.default.isExecutableFile(atPath: script.path)
    }

    /// Connected by an older Kikumap: the script and the hook list brought up to date (no prompt: it's the same
    /// connection you made, just current).
    static func upgradeIfNeeded() {
        guard installed else { return }
        let current = (try? String(contentsOf: script, encoding: .utf8)) == scriptText
        let hooks = settingsObject()?["hooks"] as? [String: Any] ?? [:]
        let complete = events.allSatisfy { ((hooks[$0] as? [Any]) ?? []).contains(where: ours) }
        if !current || !complete { _ = install() }
    }

    /// Why Claude Code won't run the hooks although they're in its settings (nil: nothing stops them).
    static func blockedReason() -> String? {
        func object(_ path: String) -> [String: Any]? {
            guard let d = FileManager.default.contents(atPath: path) else { return nil }
            if path.hasSuffix(".plist") { return (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        let base = "/Library/Application Support/ClaudeCode"
        var managed: [[String: Any]] = []
        if let o = object(base + "/managed-settings.json") { managed.append(o) }
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: base + "/managed-settings.d")) ?? []).sorted()
            where !n.hasPrefix(".") && n.hasSuffix(".json") {
            if let o = object(base + "/managed-settings.d/" + n) { managed.append(o) }
        }
        for p in ["/Library/Managed Preferences/\(NSUserName())/com.anthropic.claudecode.plist", "/Library/Managed Preferences/com.anthropic.claudecode.plist"] {
            if let o = object(p) { managed.append(o) }
        }
        // the organization's settings from its server: Claude Code keeps a copy next to yours
        if let o = object(settings.deletingLastPathComponent().appendingPathComponent("remote-settings.json").path) { managed.append(o) }
        return blockedReason(managed: managed, user: settingsObject())
    }

    /// The same from settings already read: your organization's (`managed`) and yours.
    static func blockedReason(managed: [[String: Any]], user: [String: Any]?) -> String? {
        // hooks only from managed settings and plugins: strictPluginOnlyCustomization true or naming "hooks" (Claude
        // Code takes a value it can't read as true)
        func strict(_ v: Any?) -> Bool {
            guard let v = v, !(v is NSNull) else { return false }
            if let on = v as? Bool { return on }
            if let list = v as? [Any] { return list.contains { $0 as? String == "hooks" } }
            return true
        }
        if managed.contains(where: { $0["disableAllHooks"] as? Bool == true || $0["allowManagedHooksOnly"] as? Bool == true
            || strict($0["strictPluginOnlyCustomization"]) }) {
            return tr("你的组织在 Claude Code 里关掉了自定义 hook，会话没法报告给 Kikumap", "Your organization has turned off custom hooks in Claude Code, so sessions can't report to Kikumap")
        }
        if user?["disableAllHooks"] as? Bool == true {
            return tr("Claude Code 的设置里关掉了所有 hook（~/.claude/settings.json 里的 disableAllHooks）", "Claude Code's settings turn all hooks off (disableAllHooks in ~/.claude/settings.json)")
        }
        return nil
    }

    /// Adds our entries next to whatever hooks you already have. Returns an error message, or nil.
    static func install() -> String? {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try scriptText.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch { return error.localizedDescription }
        var s: [String: Any]
        switch readSettings() {
        case .missing: s = [:]
        case .ok(let o):
            s = o
            // a copy of how it was before Kikumap ever touched it; no copy, no change
            let backup = settings.deletingLastPathComponent().appendingPathComponent("settings.json.before-claude-console")
            if !FileManager.default.fileExists(atPath: backup.path) {
                do { try FileManager.default.copyItem(at: settings.resolvingSymlinksInPath(), to: backup) }
                catch { return tr("没法先备份 ~/.claude/settings.json，所以没有改动它：", "Couldn't back up ~/.claude/settings.json first, so it was left alone: ") + error.localizedDescription }
            }
        case .unreadable:
            return tr("读不了 ~/.claude/settings.json（权限？），没有改动它。", "Couldn't read ~/.claude/settings.json (permissions?), so it was left alone.")
        case .invalid:
            return tr("~/.claude/settings.json 不是有效的 JSON，没有改动它。", "~/.claude/settings.json isn't valid JSON, so it was left alone.")
        }
        let before = s["hooks"] as? [String: Any] ?? [:]
        var hooks = before
        for ev in events {
            var list = (hooks[ev] as? [Any] ?? []).filter { !ours($0) }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            if ev == "PostToolUse" { entry["matcher"] = "*" }
            list.append(entry)
            hooks[ev] = list
        }
        if NSDictionary(dictionary: hooks).isEqual(to: before) { return nil }        // already as it should be
        s["hooks"] = hooks
        return write(s)
    }

    static func uninstall() -> String? {
        guard var s = settingsObject() else { return nil }
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
            try d.write(to: settings.resolvingSymlinksInPath(), options: .atomic)     // a linked file stays linked
            return nil
        } catch { return error.localizedDescription }
    }

}

/// The session's name as Claude Code shows it (your rename if any, otherwise its own title), and whether it's
/// linked to the Claude app (Remote Control) — then the Claude app's pinned chat stands for it. Transcripts only
/// grow (to hundreds of MB), so each read goes on from where the last one ended. Used on `queue` only.
final class TranscriptReader: @unchecked Sendable {
    static let shared = TranscriptReader()
    let queue = DispatchQueue(label: "kikumap.transcripts", qos: .utility)
    private struct Seen { var end: UInt64 = 0; var custom: String?; var ai: String?; var linked = false }
    private var cache: [String: Seen] = [:]

    func info(_ path: String) -> (title: String?, linked: Bool) {
        guard !path.isEmpty, let h = FileHandle(forReadingAtPath: path) else { return (nil, false) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var c = cache[path] ?? Seen()
        if size < c.end { c = Seen() }                                     // written anew: start over
        var at = c.end > 65_536 ? c.end - 65_536 : 0                      // with a little overlap, for a key cut in two
        while at < size {
            try? h.seek(toOffset: at)
            guard let data = try? h.read(upToCount: 8 << 20), !data.isEmpty else { break }
            if let t = TranscriptReader.last("customTitle", in: data) { c.custom = t }
            if let t = TranscriptReader.last("aiTitle", in: data) { c.ai = t }
            if !c.linked, let k = "\"type\":\"bridge-session\"".data(using: .utf8), data.range(of: k) != nil { c.linked = true }
            let next = at + UInt64(data.count)
            at = next >= size || data.count <= 65_536 ? size : next - 65_536
        }
        c.end = size
        cache[path] = c
        if cache.count > 400 { cache = [path: c] }
        return (c.custom ?? c.ai, c.linked)
    }

    /// The last `"key":"…"` string in `data` (it may contain escapes).
    private static func last(_ key: String, in data: Data) -> String? {
        guard let k = "\"\(key)\":\"".data(using: .utf8), let r = data.range(of: k, options: .backwards) else { return nil }
        var end = r.upperBound
        var escaped = false
        while end < data.endIndex {
            let b = data[end]
            if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { break }
            end += 1
        }
        guard end < data.endIndex else { return nil }                      // cut off: the next read has it whole
        let raw = Data([0x22]) + data[r.upperBound..<end] + Data([0x22])
        let s = (try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)) as? String
        return s?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
        // a long backlog (Kikumap wasn't running): only its last 2 MB (a line cut in two is skipped)
        if size - offset > 2_000_000 { offset = size - 2_000_000 }
        try? h.seek(toOffset: offset)
        guard let data = try? h.read(upToCount: Int(size - offset)),
              let lastNL = data.lastIndex(of: 0x0A) else { return }  // only whole lines
        let chunk = data[data.startIndex...lastNL]
        offset += UInt64(chunk.count)
        let out = chunk.split(separator: 0x0A).compactMap { CodeWatcher.event(Data($0)) }
        // keep the file small: once everything is read, start it over
        if offset == size && size > 2_000_000 {
            try? Data().write(to: url)
            offset = 0
        }
        UserDefaults.standard.set(Int(offset), forKey: offsetKey)
        if !out.isEmpty { onEvents?(out) }
    }

    /// One line of the events file (nil: not an event). A subagent's API error (StopFailure with its agent_id) isn't
    /// the end of the session's turn: the main agent goes on, or had already finished.
    static func event(_ line: Data) -> CodeEvent? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let s = o["session_id"] as? String, let n = o["hook_event_name"] as? String else { return nil }
        if n == "StopFailure", !(o["agent_id"] as? String ?? "").isEmpty { return nil }
        return CodeEvent(time: Date(timeIntervalSince1970: (o["t"] as? Double) ?? Date().timeIntervalSince1970),
                         app: o["app"] as? String ?? "", name: n, session: s,
                         cwd: o["cwd"] as? String ?? "", transcript: o["transcript_path"] as? String ?? "",
                         message: o["message"] as? String ?? "",
                         kind: o["notification_type"] as? String ?? "", error: o["error"] as? String ?? "", entry: o["ep"] as? String ?? "")
    }
}
