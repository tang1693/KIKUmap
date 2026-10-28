import Cocoa
import Security
import LocalAuthentication

/// A Claude scheduled task (claude.ai → Code → Scheduled tasks).
struct Routine {
    let id: String
    let name: String
    let cron: String
    let next: Date?
    let enabled: Bool
    let lastFired: Date?
    let lastFinished: Date?
    let lastStatus: String
    let session: String?

    init?(_ o: [String: Any]) {
        guard let id = o["id"] as? String else { return nil }
        self.id = id
        name = (o["name"] as? String) ?? tr("计划任务", "Scheduled task")
        cron = (o["cron_expression"] as? String) ?? ""
        enabled = (o["enabled"] as? Bool) ?? false
        next = Clock.parseAny((o["run_once_at"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (o["next_run_at"] as? String))
        let last = o["last_run"] as? [String: Any]
        lastFired = Clock.parseAny(last?["fired_at"] as? String)
        lastFinished = Clock.parseAny(last?["finished_at"] as? String)
        lastStatus = (last?["status"] as? String) ?? ""
        session = (o["persistent_session_id"] as? String) ?? (last?["session_id"] as? String)
    }

    /// Runs that are still to come.
    var upcoming: Date? { enabled ? next : nil }
}

/// Plan usage (current 5-hour session, this week) and scheduled tasks.
///
/// No second login: it reuses the sign-in Claude Code already keeps on this Mac
/// (Keychain item "Claude Code-credentials"), read the way Claude Code reads it, so macOS normally doesn't ask.
/// The app only reads that sign-in — it never refreshes or changes it; Claude Code keeps it fresh.
/// Off until you turn it on: the Keychain is never touched before you've said yes.
@MainActor
final class UsageMonitor: NSObject {
    enum Status { case unknown, ok, noLogin, denied, expired, noScope, error }
    struct Window {
        var percent: Double
        var resets: Date?
    }

    private(set) var status = Status.unknown
    private(set) var session: Window?
    private(set) var weekly: Window?
    private(set) var updated: Date?
    private(set) var routines: [Routine] = []
    var onChange: (() -> Void)?
    var log: ((String) -> Void)?

    private struct Token {
        let access: String
        let expires: Date?
        let scopes: [String]
        var isExpired: Bool { expires.map { $0 < Date().addingTimeInterval(60) } ?? false }
    }
    private enum Read { case token(Token), missing, denied, failed(OSStatus) }

    private var token: Token?
    private var lastRead = Date.distantPast
    private var busy = false
    private var timer: Timer?
    private var routinesNote = ""

    /// One line for the menu / header when there are no numbers.
    var hint: String {
        switch status {
        case .ok, .unknown: return ""
        case .noLogin: return tr("Claude Code 还没用 Claude 账号登录", "Claude Code isn't signed in with a Claude account")
        case .denied: return tr("没有读取 Claude Code 登录的权限", "Not allowed to read Claude Code's sign-in")
        case .expired: return tr("Claude Code 的登录过期了，用一下 Claude Code 就会续上", "Claude Code's sign-in expired — using Claude Code renews it")
        case .noScope: return tr("Claude Code 的登录不含用量权限，重新 /login 一次", "Claude Code's sign-in can't read usage — run /login again")
        case .error: return tr("用量暂时读取失败", "Couldn't read usage right now")
        }
    }

    /// You said yes to reading Claude Code's sign-in (Settings → Access, or the intro).
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "UsageOn") }
        set { UserDefaults.standard.set(newValue, forKey: "UsageOn") }
    }

    func start() {
        guard UsageMonitor.enabled, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 300, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    @objc private func tick() { refresh() }

    func refreshIfStale() {
        if let u = updated, Date().timeIntervalSince(u) < 120 { return }
        refresh()
    }

    /// From a click: read the sign-in again (macOS may ask).
    func reconnect() {
        token = nil
        lastRead = .distantPast
        refresh(userAction: true)
    }

    func refresh(userAction: Bool = false) {
        guard UsageMonitor.enabled, !busy else { return }
        if let t = token, !t.isExpired { fetch(t); return }
        // Don't keep asking after "Deny"; re-read an expired sign-in at most every 15 minutes.
        if !userAction {
            if status == .denied { return }
            if Date().timeIntervalSince(lastRead) < 900 { return }
        }
        busy = true
        lastRead = Date()
        // only a click (after the explanation) may bring up macOS's Keychain dialog; on its own it reads quietly
        DispatchQueue.global(qos: .utility).async {
            let r = UsageMonitor.readCredentials(interactive: userAction)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.got(r, interactive: userAction) }
            }
        }
    }

    /// Turned off: forget the sign-in and everything read with it.
    func stop() {
        busy = false
        timer?.invalidate()
        timer = nil
        token = nil
        session = nil
        weekly = nil
        routines = []
        updated = nil
        set(.unknown)
    }

    private func got(_ r: Read, interactive: Bool) {
        busy = false
        guard UsageMonitor.enabled else { return }          // turned off while macOS was asking
        switch r {
        case .token(let t):
            if t.isExpired { token = nil; set(.expired); return }
            if !t.scopes.isEmpty && !t.scopes.contains("user:profile") { token = nil; set(.noScope); return }
            token = t
            fetch(t)
        case .missing: set(.noLogin)
        case .denied:
            // "Deny" in macOS's dialog: off again, so nothing asks until you choose to turn it on
            if interactive { UsageMonitor.enabled = false; stop() }
            set(.denied)
        case .failed(let s): log?("keychain read failed: \(s)"); set(.error)
        }
    }

    private func set(_ s: Status) {
        status = s
        if s == .ok { updated = Date() }
        onChange?()
    }

    // MARK: reading Claude Code's sign-in

    /// A Keychain lookup that may not ask the user anything.
    nonisolated private static func quietContext() -> LAContext {
        let c = LAContext()
        c.interactionNotAllowed = true
        return c
    }

    nonisolated private static func readCredentials(interactive: Bool) -> Read {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let d = try? Data(contentsOf: file), let t = parseCredentials(d) { return .token(t) }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        // first quietly: this never puts up the Keychain dialog, it fails instead
        let quiet = keychain(q.merging([kSecUseAuthenticationContext as String: UsageMonitor.quietContext()]) { _, b in b }, interactive: false)
        if case .token = quiet { return quiet }
        if case .missing = quiet { return quiet }
        // then the way Claude Code itself reads it, through Apple's `security` tool, which the item trusts.
        // An "Always Allow" given to Kikumap doesn't last: Claude Code rewrites the item whenever it renews its
        // sign-in (a few times a day), and macOS would ask again each time.
        if let d = viaSecurityTool(), let t = parseCredentials(d) { return .token(t) }
        return interactive ? keychain(q, interactive: true) : quiet
    }

    nonisolated private static func keychain(_ q: [String: Any], interactive: Bool) -> Read {
        if !interactive { SecKeychainSetUserInteractionAllowed(false) }
        defer { if !interactive { SecKeychainSetUserInteractionAllowed(true) } }
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        switch s {
        case errSecSuccess:
            guard let d = out as? Data, let t = parseCredentials(d) else { return .missing }
            return .token(t)
        case errSecItemNotFound: return .missing
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: return .denied
        default: return .failed(s)
        }
    }

    /// `security find-generic-password -w`, as Claude Code runs it (given up on after 10 seconds).
    nonisolated private static func viaSecurityTool() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let stop = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: stop)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        stop.cancel()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("{") { return Data(s.utf8) }
        // not plain text: the tool prints it as hex
        var bytes = [UInt8](), i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex), let b = UInt8(s[i..<j], radix: 16) {
            bytes.append(b); i = j
        }
        return bytes.isEmpty ? nil : Data(bytes)
    }

    nonisolated private static func parseCredentials(_ d: Data) -> Token? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = o["claudeAiOauth"] as? [String: Any],
              let access = a["accessToken"] as? String, !access.isEmpty else { return nil }
        let ms = (a["expiresAt"] as? NSNumber)?.doubleValue
        let scopes: [String]
        if let arr = a["scopes"] as? [String] { scopes = arr }
        else if let s = a["scopes"] as? String { scopes = s.split(separator: " ").map(String.init) }
        else { scopes = [] }
        return Token(access: access, expires: ms.map { Date(timeIntervalSince1970: $0 / 1000) }, scopes: scopes)
    }

    /// Organization of the Claude Code sign-in (for the scheduled-task list).
    nonisolated private static func orgUUID() -> String? {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let d = try? Data(contentsOf: f),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = o["oauthAccount"] as? [String: Any] else { return nil }
        return a["organizationUuid"] as? String
    }

    // MARK: requests

    private func fetch(_ t: Token) {
        busy = true
        get("/api/oauth/usage", t, beta: "oauth-2025-04-20") { [weak self] code, obj in
            guard let self = self else { return }
            self.busy = false
            guard UsageMonitor.enabled else { return }
            switch code {
            case 200 where self.parse(obj):
                self.set(.ok)
                self.fetchRoutines(t)
            case 401:
                self.token = nil
                self.lastRead = .distantPast
                self.set(.expired)
            case 403:
                self.token = nil
                self.set(.noScope)
            case 429:
                self.onChange?()   // keep the last numbers; try again on the next tick
            default:
                self.log?("usage HTTP \(code)")
                self.set(.error)
            }
        }
    }

    /// Scheduled tasks — the same list as claude.ai → Code → Scheduled tasks.
    private func fetchRoutines(_ t: Token) {
        let org = UsageMonitor.orgUUID()
        var extra = ["anthropic-version": "2023-06-01"]
        if let o = org { extra["x-organization-uuid"] = o }
        get("/v1/code/triggers?limit=100", t, beta: "ccr-triggers-2026-01-30,oauth-2025-04-20", extra: extra) { [weak self] code, obj in
            guard let self = self, UsageMonitor.enabled else { return }
            guard code == 200, let o = obj as? [String: Any], let list = o["data"] as? [[String: Any]] else {
                let note = "scheduled tasks HTTP \(code)"
                if note != self.routinesNote { self.routinesNote = note; self.log?(note) }
                return
            }
            self.routinesNote = ""
            self.routines = list.compactMap(Routine.init)
            self.onChange?()
        }
    }

    private func get(_ path: String, _ t: Token, beta: String, extra: [String: String] = [:],
                     _ done: @escaping (Int, Any?) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com" + path) else { done(0, nil); return }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.setValue("Bearer " + t.access, forHTTPHeaderField: "Authorization")
        r.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Kikumap/0.9 (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        for (k, v) in extra { r.setValue(v, forHTTPHeaderField: k) }
        URLSession.shared.dataTask(with: r) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(code, obj) }
            }
        }.resume()
    }

    private func parse(_ obj: Any?) -> Bool {
        guard let o = obj as? [String: Any] else { return false }
        func win(_ k: String) -> Window? {
            guard let w = o[k] as? [String: Any] else { return nil }
            let p = (w["utilization"] as? NSNumber)?.doubleValue ?? 0
            return Window(percent: p, resets: Clock.parseAny(w["resets_at"] as? String))
        }
        let s = win("five_hour"), w = win("seven_day")
        guard s != nil || w != nil else { return false }
        session = s
        weekly = w
        return true
    }
}
