import Foundation

/// ChatGPT's plan usage straight from OpenAI, asked the way Codex asks it (GET chatgpt.com/backend-api/wham/usage),
/// with the sign-in Codex keeps on this Mac (~/.codex/auth.json). Off until you say yes (Settings → Access).
/// It only reads that sign-in, never refreshes or changes it (Codex keeps it fresh).
///
/// Without it, ChatGPT's usage comes from Codex's own logs, which carry it only when you run a Codex task: after a
/// reset nothing is known until the next one. Not a public API: if its answer changes shape, the logs are still read.
@MainActor
final class GPTUsageMonitor {
    enum Status { case unknown, ok, noLogin, expired, limited, error }

    /// You said yes to reading Codex's ChatGPT sign-in.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "GPTUsageOn") }
        set { UserDefaults.standard.set(newValue, forKey: "GPTUsageOn") }
    }

    private(set) var status = Status.unknown
    /// The latest answer (nil until one comes).
    private(set) var usage: GPTUsage?
    var onChange: (() -> Void)?
    var log: ((String) -> Void)?

    private var timer: Timer?
    private var busy = false
    private var lastFetch = Date.distantPast
    /// OpenAI said to wait until then.
    private var holdUntil: Date?
    private var lastNote = ""
    /// Not more than every ten minutes on its own, as Claude's (a click: not twice a minute).
    private static let every: TimeInterval = 600

    private lazy var http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        return URLSession(configuration: c)
    }()

    /// One line for Settings when there are no numbers from OpenAI.
    var hint: String {
        switch status {
        case .ok, .unknown: return ""
        case .noLogin: return tr("这台 Mac 上的 Codex 没有用 ChatGPT 账号登录", "Codex on this Mac isn't signed in with a ChatGPT account")
        case .expired: return tr("Codex 的登录过期了，用一下 Codex 就会续上", "Codex's sign-in expired — using Codex renews it")
        case .limited:
            guard let h = holdUntil, h > Date() else { return tr("OpenAI 让晚点再查，马上再试", "OpenAI asked to check less often — trying again shortly") }
            return tr("OpenAI 让晚点再查，\(Clock.format(h, "HH:mm", "HH:mm")) 再试", "OpenAI asked to check less often — trying again at \(Clock.format(h, "HH:mm", "HH:mm"))")
        case .error: return tr("暂时查不到：用的是 OpenAI 没公开的接口，可能改了。用 Codex 时的数字照样会显示。",
                               "Can't get it right now: it's an interface OpenAI hasn't published, which may have changed. The numbers from using Codex still show.")
        }
    }

    func start() {
        guard GPTUsageMonitor.enabled, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Turned off: nothing read with it is kept.
    func stop() {
        timer?.invalidate(); timer = nil
        usage = nil; holdUntil = nil; busy = false
        status = .unknown
        onChange?()
    }

    func refresh(now: Bool = false) {
        guard GPTUsageMonitor.enabled, !busy else { return }
        if !now, let h = holdUntil, h > Date() { return }
        if (0..<(now ? 60 : GPTUsageMonitor.every)).contains(Date().timeIntervalSince(lastFetch)) { return }
        busy = true
        lastFetch = Date()
        DispatchQueue.global(qos: .utility).async {
            let auth = GPTUsageMonitor.readAuth()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.fetch(auth) }
            }
        }
    }

    /// Codex's ChatGPT sign-in: the access token and the account it's for (nil: none, or an API key only).
    nonisolated static func readAuth(home: URL? = nil) -> (token: String, account: String?)? {
        // (where GPTWatcher.home is: ~/.codex)
        let dir = home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let d = FileManager.default.contents(atPath: dir.appendingPathComponent("auth.json").path),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let t = o["tokens"] as? [String: Any],
              let access = (t["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !access.isEmpty else { return nil }
        let account = (t["account_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (access, account?.isEmpty == false ? account : nil)
    }

    private func fetch(_ auth: (token: String, account: String?)?) {
        guard GPTUsageMonitor.enabled else { busy = false; return }
        guard let auth, let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { busy = false; set(.noLogin); return }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.setValue("Bearer " + auth.token, forHTTPHeaderField: "Authorization")
        if let a = auth.account { r.setValue(a, forHTTPHeaderField: "ChatGPT-Account-Id") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("codex", forHTTPHeaderField: "OAI-Product-Sku")
        r.setValue("Kikumap/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1") (macOS menu bar)", forHTTPHeaderField: "User-Agent")
        http.dataTask(with: r) { data, resp, _ in
            let h = resp as? HTTPURLResponse
            let code = h?.statusCode ?? 0
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let after = h?.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.got(code, obj, retryAfter: after) }
            }
        }.resume()
    }

    private func got(_ code: Int, _ obj: Any?, retryAfter: Double?) {
        busy = false
        guard GPTUsageMonitor.enabled else { return }
        switch code {
        case 200:
            guard let u = GPTUsageMonitor.parse(obj, at: Date()) else { note("ChatGPT usage: an answer it can't read"); set(.error); return }
            usage = u
            holdUntil = nil
            lastNote = ""
            set(.ok)
        case 401, 403:
            set(.expired)
        case 429:
            let wait = min(max(retryAfter ?? 600, 60), 3600)
            holdUntil = Date().addingTimeInterval(wait)
            note("ChatGPT usage HTTP 429: waiting \(Int(wait))s")
            set(.limited)
        default:
            note("ChatGPT usage HTTP \(code)")
            set(.error)
        }
    }

    private func set(_ s: Status) {
        status = s
        if s == .noLogin { usage = nil }
        onChange?()
    }

    private func note(_ s: String) {
        if s != lastNote { lastNote = s; log?(s) }
    }

    /// The plan's windows, from either shape the answer has had: `rate_limit` with `primary_window` /
    /// `secondary_window` (`used_percent`, `limit_window_seconds`, `reset_at` or `reset_after_seconds`), or
    /// `rate_limits` with `primary` / `secondary` (`used_percent`, `window_minutes`, `resets_at`), as Codex logs it.
    /// nil: neither is there (a plan without limits answers with empty windows, which is a good answer).
    nonisolated static func parse(_ obj: Any?, at: Date) -> GPTUsage? {
        guard let o = obj as? [String: Any] else { return nil }
        func num(_ d: [String: Any], _ keys: String...) -> Double? {
            for k in keys { if let n = d[k] as? NSNumber { return n.doubleValue } }
            return nil
        }
        func windows(_ r: [String: Any], _ names: [String]) -> [GPTUsage.Window] {
            names.compactMap { k -> GPTUsage.Window? in
                guard let w = r[k] as? [String: Any], let pct = num(w, "used_percent", "usedPercent") else { return nil }
                let minutes = num(w, "limit_window_seconds", "limitWindowSeconds").map { Int($0 / 60) }
                    ?? num(w, "window_minutes", "window_duration_mins", "windowDurationMins").map { Int($0) } ?? 0
                var resets = num(w, "reset_at", "resetAt", "resets_at", "resetsAt").map { Date(timeIntervalSince1970: $0) }
                if resets == nil, let s = num(w, "reset_after_seconds", "resetAfterSeconds") { resets = at.addingTimeInterval(s) }
                return GPTUsage.Window(percent: pct, minutes: minutes, resets: resets)
            }
        }
        // the plan: beside the windows, or among them as Codex logs it
        func plan(_ r: [String: Any]) -> String? { (o["plan_type"] ?? o["planType"] ?? r["plan_type"] ?? r["planType"]) as? String }
        // (present but null: a plan without limits)
        if let k = ["rate_limit", "rateLimit"].first(where: o.keys.contains) {
            let r = o[k] as? [String: Any] ?? [:]
            return GPTUsage(windows: windows(r, ["primary_window", "secondary_window", "primaryWindow", "secondaryWindow"]).sorted { $0.minutes < $1.minutes }, at: at, plan: plan(r))
        }
        if let k = ["rate_limits", "rateLimits"].first(where: o.keys.contains) {
            let r = o[k] as? [String: Any] ?? [:]
            return GPTUsage(windows: windows(r, ["primary", "secondary"]).sorted { $0.minutes < $1.minutes }, at: at, plan: plan(r))
        }
        return nil
    }
}
