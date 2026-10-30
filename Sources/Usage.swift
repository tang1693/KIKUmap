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
    /// `limited`: Anthropic asked to check less often (it's waited out); `locked`: the login keychain is locked.
    enum Status { case unknown, ok, noLogin, denied, expired, noScope, error, limited, locked }
    struct Window {
        var percent: Double
        var resets: Date?
    }

    private(set) var status = Status.unknown
    private(set) var session: Window?
    private(set) var weekly: Window?
    /// This week, Sonnet only: on the plans that have that limit (Max, Team), as Claude Code shows it.
    private(set) var sonnet: Window?
    private(set) var updated: Date?
    private(set) var routines: [Routine] = []
    /// When the scheduled tasks were last read (they're read with the usage, every few minutes).
    private(set) var routinesAt: Date?
    /// Whose usage it is: Claude Code's account ("email · organization"), nil when unknown.
    private(set) var account: String?
    var onChange: (() -> Void)?
    var log: ((String) -> Void)?

    private struct Token {
        let access: String
        let expires: Date?
        let scopes: [String]
        let plan: String?
        var isExpired: Bool { expires.map { $0 < Date().addingTimeInterval(60) } ?? false }
    }
    private enum Read { case token(Token), missing, denied, locked, failed(OSStatus) }
    /// Claude Code's account, from ~/.claude.json: which one (account and organization), and its name.
    private struct Account { let key: String; let label: String; let org: String? }

    private var token: Token?
    private var tokenAccount: String?
    private var tokenOrg: String?
    private var lastRead = Date.distantPast
    private var busy = false
    private var timer: Timer?
    private var routinesNote = ""
    private var lastNote = ""
    /// Anthropic said to wait until then.
    private var holdUntil: Date?
    private var failures = 0
    private var retrying = false
    /// Quiet reads of the sign-in that weren't allowed: after a few, only a click tries again.
    private var quietDenials = 0
    private lazy var http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = true                 // just woken up: wait for the network instead of failing
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        return URLSession(configuration: c)
    }()

    /// One line for the menu / header when there are no numbers (or they're from an earlier read).
    var hint: String {
        switch status {
        case .ok, .unknown: return ""
        case .noLogin: return tr("Claude Code 还没用 Claude 账号登录", "Claude Code isn't signed in with a Claude account")
        case .denied: return tr("没有读取 Claude Code 登录的权限", "Not allowed to read Claude Code's sign-in")
        case .expired: return tr("Claude Code 的登录过期了，用一下 Claude Code 就会续上", "Claude Code's sign-in expired — using Claude Code renews it")
        case .noScope: return tr("Claude Code 的登录不含用量权限，重新 /login 一次", "Claude Code's sign-in can't read usage — run /login again")
        case .error: return tr("用量暂时读取失败", "Couldn't read usage right now")
        case .limited:
            // once that time has come, the read is on its way: a time that has passed isn't shown
            guard let h = holdUntil, h > Date() else { return tr("Anthropic 让晚点再查用量，马上再试", "Anthropic asked to check usage less often — trying again shortly") }
            let at = Clock.format(h, "HH:mm", "HH:mm")
            return tr("Anthropic 让晚点再查用量，\(at) 再试", "Anthropic asked to check usage less often — trying again at \(at)")
        case .locked: return tr("钥匙串锁着，解锁 Mac 后自动再读", "Your login keychain is locked — it reads again once the Mac is unlocked")
        }
    }

    /// A window as it can be shown now. Once its reset has passed, what's used since is unknown until the next read:
    /// 0% while the numbers are current (the next read comes within minutes), otherwise nothing ("–"): reads
    /// failing, or the last one from before a sleep.
    func shown(_ w: Window?, now: Date = Date()) -> Window? {
        guard UsageMonitor.enabled, let w = w else { return nil }
        guard let r = w.resets, r <= now else { return w }
        return status == .ok && asOf == nil ? Window(percent: 0, resets: nil) : nil
    }
    var shownSession: Window? { shown(session) }
    var shownWeekly: Window? { shown(weekly) }
    var shownSonnet: Window? { shown(sonnet) }

    /// The Sonnet-only week where it's what holds you back: nearly used up, or fuller than the all-models week.
    /// The header, the menu-bar tooltip and the widget add it only then; the menu always lists it.
    var bindingSonnet: Window? {
        guard let s = shownSonnet else { return nil }
        return s.percent >= 90 || s.percent.rounded() > (shownWeekly?.percent ?? 100).rounded() ? s : nil
    }

    /// The numbers come from an earlier read (reading stopped working, or Anthropic asked to wait): when it was.
    var asOf: Date? {
        guard let u = updated, session != nil || weekly != nil else { return nil }
        return status != .ok || Date().timeIntervalSince(u) > 900 ? u : nil
    }

    /// `asOf` as the widget says it: "as of 14:05", "as of Mon 14:05" (numbers from days ago don't look like today's).
    var asOfText: String? {
        asOf.map { let t = UsageMonitor.stamp($0); return tr("\(t) 时的数据", "as of \(t)") }
    }

    /// "14:05" today, "周一 14:05" / "Mon 14:05" in the six days before, else "10/21 14:05" (WidgetText.asOf: the same).
    static func stamp(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let days = Clock.days(from: d, to: now, cal)
        let f = days == 0 ? "HH:mm" : (1...6).contains(days) ? "EEE HH:mm" : "M/d HH:mm"
        return Clock.format(d, f, f)
    }

    /// You said yes to reading Claude Code's sign-in (Settings → Access, or the intro).
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "UsageOn") }
        set { UserDefaults.standard.set(newValue, forKey: "UsageOn") }
    }

    /// Claude Code's `claude` command is on this Mac: asking nothing, reading no secret. Not the ~/.claude folder,
    /// which Kikumap's own hooks and the Claude app's Code mode make too.
    static var claudeCodeInstalled: Bool { claudeCommand(home: NSHomeDirectory()) }

    /// Where Claude Code's installers and npm put `claude` (the app has no shell PATH to look along).
    static func claudeCommand(home: String, system: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]) -> Bool {
        let fm = FileManager.default
        var dirs = system + ["/.local/bin", "/.claude/local", "/bin", "/.npm-global/bin", "/.npm-packages/bin", "/.volta/bin", "/.bun/bin",
                             "/.yarn/bin", "/Library/pnpm", "/.asdf/shims", "/.nodenv/shims", "/.local/share/mise/shims"].map { home + $0 }
        // npm under nvm or fnm: a folder per Node version
        for root in ["/.nvm/versions/node", "/.local/share/fnm/node-versions", "/Library/Application Support/fnm/node-versions"].map({ home + $0 }) {
            for v in (try? fm.contentsOfDirectory(atPath: root)) ?? [] { dirs += [root + "/" + v + "/bin", root + "/" + v + "/installation/bin"] }
        }
        // only the editor extension (VS Code, Cursor, Windsurf…): it brings its own, signed in the same way
        for root in ["/.vscode/extensions", "/.vscode-insiders/extensions", "/.vscode-oss/extensions", "/.cursor/extensions", "/.windsurf/extensions"].map({ home + $0 }) {
            for v in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where v.hasPrefix("anthropic.claude-code-") { dirs.append(root + "/" + v + "/resources/native-binary") }
        }
        return dirs.contains { fm.isExecutableFile(atPath: $0 + "/claude") }
    }

    func start() {
        guard UsageMonitor.enabled, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(timeInterval: 300, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        // a locked keychain is read again as soon as the Mac is unlocked
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func tick() { refresh() }
    @objc private func unlocked() { if status == .locked { lastRead = .distantPast; refresh() } }

    func refreshIfStale() {
        if let u = updated, (0..<120).contains(Date().timeIntervalSince(u)) { return }
        refresh()
    }

    /// The refresh button: read now, quietly (never brings up macOS's Keychain dialog).
    func refreshNow() {
        guard UsageMonitor.enabled else { return }
        lastRead = .distantPast
        refresh()
    }

    /// From a click: read the sign-in again (macOS may ask).
    func reconnect() {
        token = nil
        lastRead = .distantPast
        holdUntil = nil
        quietDenials = 0
        refresh(userAction: true)
    }

    func refresh(userAction: Bool = false) {
        guard UsageMonitor.enabled, !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let acct = UsageMonitor.readAccount()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.go(acct, userAction: userAction) }
            }
        }
    }

    private func go(_ acct: Account?, userAction: Bool) {
        busy = false
        guard UsageMonitor.enabled else { return }
        account = acct?.label.isEmpty == false ? acct?.label : nil
        // Claude Code signed in to another account (or organization): what was read belongs to the old one. Read
        // again in a moment (its new sign-in may still be being written).
        if (token != nil || updated != nil) && acct?.key != tokenAccount {
            token = nil; session = nil; weekly = nil; sonnet = nil; routines = []; updated = nil
            holdUntil = nil; failures = 0                    // a wait Anthropic asked for was the old sign-in's
            lastRead = .distantPast
            tokenAccount = acct?.key
            log?("Claude Code's account changed: usage read again")
            set(.unknown)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            return
        }
        // Anthropic asked to wait (the account above is still checked meanwhile)
        if !userAction, let h = holdUntil, h > Date() { return }
        if let t = token, !t.isExpired { fetch(t); return }
        // re-read the sign-in at most every 15 minutes, and after a few quiet refusals only on a click
        if !userAction {
            if status == .denied && quietDenials >= 3 { return }
            if (0..<900).contains(Date().timeIntervalSince(lastRead)) { return }
        }
        busy = true
        lastRead = Date()
        // only a click (after the explanation) may bring up macOS's Keychain dialog; on its own it reads quietly
        DispatchQueue.global(qos: .utility).async {
            let a = UsageMonitor.readAccount()
            let r = UsageMonitor.readCredentials(interactive: userAction)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.got(r, account: a, interactive: userAction) }
            }
        }
    }

    /// Turned off: forget the sign-in and everything read with it.
    func stop() {
        busy = false
        timer?.invalidate()
        timer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        token = nil
        session = nil
        weekly = nil
        sonnet = nil
        routines = []
        updated = nil
        account = nil
        holdUntil = nil
        failures = 0
        quietDenials = 0
        set(.unknown)
    }

    private func got(_ r: Read, account a: Account?, interactive: Bool) {
        busy = false
        guard UsageMonitor.enabled else { return }          // turned off while macOS was asking
        switch r {
        case .token(let t):
            quietDenials = 0
            tokenAccount = a?.key
            tokenOrg = a?.org
            if t.isExpired { token = nil; set(.expired); return }
            if !t.scopes.isEmpty && !t.scopes.contains("user:profile") { token = nil; set(.noScope); return }
            token = t
            fetch(t)
        case .missing: set(.noLogin)
        case .locked: set(.locked)
        case .denied:
            // "Deny" in macOS's dialog: off again, so nothing asks until you choose to turn it on
            if interactive { log?("Keychain access denied: usage turned off"); UsageMonitor.enabled = false; stop(); return }
            quietDenials += 1
            set(.denied)
        case .failed(let s): log?("keychain read failed: \(s)"); set(.error)
        }
    }

    private func set(_ s: Status) {
        status = s
        switch s {
        case .ok: updated = Date()
        // the sign-in is gone or isn't this account's any more: nothing read with it is shown
        case .noLogin, .noScope, .denied: session = nil; weekly = nil; sonnet = nil; routines = []; updated = nil
        default: break                                       // older numbers stay, marked "as of"
        }
        onChange?()
    }

    // MARK: reading Claude Code's sign-in

    /// A Keychain lookup that may not ask the user anything.
    nonisolated private static func quietContext() -> LAContext {
        let c = LAContext()
        c.interactionNotAllowed = true
        return c
    }

    /// The Keychain first, as Claude Code reads it; ~/.claude/.credentials.json only when the Keychain has no
    /// sign-in at all (a file left next to a live Keychain sign-in is an old copy).
    nonisolated private static func readCredentials(interactive: Bool) -> Read {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        let fileToken: () -> Read? = {
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            guard let d = try? Data(contentsOf: file), let t = parseCredentials(d) else { return nil }
            return .token(t)
        }
        // first quietly: this never puts up the Keychain dialog, it fails instead
        let quiet = keychain(q.merging([kSecUseAuthenticationContext as String: UsageMonitor.quietContext()]) { _, b in b }, interactive: false)
        if case .token = quiet { return quiet }
        if case .missing = quiet { return fileToken() ?? .missing }
        // a locked keychain: Apple's tool would put up its own dialog; wait for the Mac to be unlocked instead
        if !interactive && keychainLocked() { return .locked }
        // then the way Claude Code itself reads it, through Apple's `security` tool, which the item trusts.
        // An "Always Allow" given to Kikumap doesn't last: Claude Code rewrites the item whenever it renews its
        // sign-in (a few times a day), and macOS would ask again each time.
        if let r = fromTool(viaSecurityTool()) { return r }
        return interactive ? keychain(q, interactive: true) : quiet
    }

    /// What the `security` tool printed: the sign-in; or none when it read the item and there's no Claude-account
    /// sign-in in it (Claude Code uses an API key or a Console login), since asking macOS again would only give the
    /// same; nil when it couldn't read it.
    nonisolated private static func fromTool(_ d: Data?) -> Read? {
        guard let d = d else { return nil }
        if let t = parseCredentials(d) { return .token(t) }
        return (try? JSONSerialization.jsonObject(with: d)) is [String: Any] ? .missing : nil
    }

    /// The login keychain is locked (asks nothing).
    nonisolated private static func keychainLocked() -> Bool {
        var st: SecKeychainStatus = 0
        guard SecKeychainGetStatus(nil, &st) == errSecSuccess else { return false }
        return st & SecKeychainStatus(kSecUnlockStateStatus) == 0
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
        return Token(access: access, expires: ms.map { Date(timeIntervalSince1970: $0 / 1000) }, scopes: scopes,
                     plan: (a["subscriptionType"] as? String)?.lowercased())
    }

    /// Claude Code's account, from ~/.claude.json (no secret in it).
    nonisolated private static func readAccount() -> Account? {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let d = try? Data(contentsOf: f),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let a = o["oauthAccount"] as? [String: Any] else { return nil }
        let org = a["organizationUuid"] as? String
        let label = [a["emailAddress"] as? String, a["organizationName"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return Account(key: "\(a["accountUuid"] as? String ?? "")/\(org ?? "")", label: label, org: org)
    }

    // MARK: requests

    private func note(_ s: String) {
        if s != lastNote { lastNote = s; log?(s) }
    }

    private func fetch(_ t: Token) {
        busy = true
        get("/api/oauth/usage", t, beta: "oauth-2025-04-20") { [weak self] code, obj, retryAfter in
            guard let self = self else { return }
            self.busy = false
            guard UsageMonitor.enabled else { return }
            switch code {
            case 200 where self.parse(obj, plan: t.plan):
                self.holdUntil = nil
                self.failures = 0
                self.lastNote = ""
                self.set(.ok)
                self.fetchRoutines(t)
            case 401:
                self.token = nil
                self.lastRead = .distantPast
                self.set(.expired)
            case 403 where UsageMonitor.says(obj, "scope"):
                self.token = nil
                self.set(.noScope)
            case 403 where UsageMonitor.says(obj, "revoked") || UsageMonitor.says(obj, "expired"):
                self.token = nil
                self.lastRead = .distantPast
                self.set(.expired)
            case 403, 429:
                // Anthropic asked to check less often (Claude Code waits the same way): the numbers stay, marked
                // "as of", and nothing is asked again until then
                let wait = min(max(retryAfter ?? 300, 60), 3600)
                let until = Date().addingTimeInterval(wait)
                self.holdUntil = until
                self.note("usage HTTP \(code): waiting \(Int(wait))s")
                self.set(.limited)
                // read again at the time the hint gives, not at the first 5-minute tick after it (unless a newer
                // answer, a click or turning usage off changed the wait meanwhile)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait + 1) { [weak self] in
                    MainActor.assumeIsolated { if let self = self, self.holdUntil == until { self.refresh() } }
                }
            default:
                // offline (0), a server error, an answer it can't read: the numbers stay; it tries again in a minute,
                // and only says something is wrong if that keeps happening
                self.failures += 1
                self.note("usage HTTP \(code)")
                if self.updated != nil && self.failures < 3 { self.retrySoon(); self.onChange?() } else { self.set(.error) }
            }
        }
    }

    private func retrySoon() {
        guard !retrying else { return }
        retrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated { self?.retrying = false; self?.refresh() }
        }
    }

    /// The error Anthropic sent mentions this.
    private static func says(_ obj: Any?, _ word: String) -> Bool {
        guard let e = (obj as? [String: Any])?["error"] as? [String: Any] else { return false }
        return "\(e["type"] ?? "") \(e["message"] ?? "")".range(of: word, options: .caseInsensitive) != nil
    }

    /// Scheduled tasks — the same list as claude.ai → Code → Scheduled tasks.
    private func fetchRoutines(_ t: Token) {
        var extra = ["anthropic-version": "2023-06-01"]
        if let o = tokenOrg { extra["x-organization-uuid"] = o }
        get("/v1/code/triggers?limit=100", t, beta: "ccr-triggers-2026-01-30,oauth-2025-04-20", extra: extra) { [weak self] code, obj, _ in
            guard let self = self, UsageMonitor.enabled else { return }
            guard code == 200, let o = obj as? [String: Any], let list = o["data"] as? [[String: Any]] else {
                let note = "scheduled tasks HTTP \(code)"
                if note != self.routinesNote { self.routinesNote = note; self.log?(note) }
                return
            }
            self.routinesNote = ""
            self.routines = list.compactMap(Routine.init)
            self.routinesAt = Date()
            self.onChange?()
        }
    }

    private static let userAgent = "Kikumap/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1") (macOS menu bar)"

    private func get(_ path: String, _ t: Token, beta: String, extra: [String: String] = [:],
                     _ done: @escaping (Int, Any?, Double?) -> Void) {
        guard let url = URL(string: "https://api.anthropic.com" + path) else { done(0, nil, nil); return }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.setValue("Bearer " + t.access, forHTTPHeaderField: "Authorization")
        r.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(UsageMonitor.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in extra { r.setValue(v, forHTTPHeaderField: k) }
        http.dataTask(with: r) { data, resp, _ in
            let h = resp as? HTTPURLResponse
            let code = h?.statusCode ?? 0
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            // Retry-After: seconds, or a date
            var after: Double?
            if let v = h?.value(forHTTPHeaderField: "Retry-After") {
                if let n = Double(v.trimmingCharacters(in: .whitespaces)) { after = n }
                else {
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    after = f.date(from: v).map { $0.timeIntervalSinceNow }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(code, obj, after) }
            }
        }.resume()
    }

    /// The windows from /api/oauth/usage. A window without a number isn't shown (not as 0%); a plan without
    /// either window is still a good answer (nothing to show).
    private func parse(_ obj: Any?, plan: String?) -> Bool {
        guard let o = obj as? [String: Any], o.keys.contains("five_hour") || o.keys.contains("seven_day") else { return false }
        func win(_ k: String) -> Window? {
            guard let w = o[k] as? [String: Any], let p = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Window(percent: p, resets: Clock.parseAny(w["resets_at"] as? String))
        }
        session = win("five_hour")
        weekly = win("seven_day")
        // the Sonnet-only week, where the plan has it (as Claude Code's /usage shows it)
        sonnet = plan == nil || plan == "max" || plan == "team" ? win("seven_day_sonnet") : nil
        return true
    }
}
