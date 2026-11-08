import Foundation

/// ChatGPT's plan usage straight from OpenAI, asked the way Codex asks it (GET chatgpt.com/backend-api/wham/usage),
/// with the sign-in Codex keeps on this Mac (~/.codex/auth.json). Off until you say yes (Settings → Access).
/// It only reads that sign-in, never refreshes or changes it (Codex keeps it fresh).
///
/// Without it, ChatGPT's usage comes from Codex's own logs, which carry it only when you run a Codex task: after a
/// reset nothing is known until the next one. Not a public API: if its answer changes shape, the logs are still read.
@MainActor
final class GPTUsageMonitor {
    /// `refused`: turned away, not for the sign-in (blocked on the way, or not allowed); `offline`: no answer, or
    /// OpenAI's servers in trouble; `error`: an answer it can't read.
    enum Status { case unknown, ok, noLogin, expired, refused, limited, offline, error }

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
    /// Codex's sign-in, read off the main thread; and the request sent, its status code, answer and Retry-After handed
    /// back on the main thread (nil: to chatgpt.com). A test stands in for both.
    var readSignIn: @Sendable () -> (token: String, account: String?)? = { GPTUsageMonitor.readAuth() }
    var send: ((URLRequest, @escaping (Int, Any?, Double?) -> Void) -> Void)?

    private var timer: Timer?
    /// The next lookup on its own, ten minutes after the last one (the 5-minute timer alone often comes a moment short
    /// of that and leaves it to the tick after: 15 minutes).
    private var nextLookup: Timer?
    private var busy = false
    private var lastFetch = Date.distantPast
    /// OpenAI said to wait until then.
    private var holdUntil: Date?
    private var lastNote = ""
    /// No answer (or a server error) this many times in a row: tried again in a minute a few times, as Claude's is.
    private(set) var failures = 0
    /// A try in a minute is on its way.
    private var retrying = false
    /// How many times it was turned off: a try planned before that, or an answer on its way then, is dropped.
    private var turnedOff = 0
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
        case .refused: return tr("用量查询被拒绝了，可能是被拦下了。用 Codex 时的数字照样会显示。",
                                 "The usage request was refused — it may be blocked. The numbers from using Codex still show.")
        case .limited:
            guard let h = holdUntil, h > Date() else { return tr("OpenAI 让晚点再查，马上再试", "OpenAI asked to check less often — trying again shortly") }
            return tr("OpenAI 让晚点再查，\(Clock.format(h, "HH:mm", "HH:mm")) 再试", "OpenAI asked to check less often — trying again at \(Clock.format(h, "HH:mm", "HH:mm"))")
        case .offline:
            return retrying
                ? tr("连不上 OpenAI（没联网，或者它那边出了问题），一分钟后再试。用 Codex 时的数字照样会显示。",
                     "Can't reach OpenAI (offline, or trouble on its side); trying again in a minute. The numbers from using Codex still show.")
                : tr("连不上 OpenAI（没联网，或者它那边出了问题），十来分钟后再试。用 Codex 时的数字照样会显示。",
                     "Can't reach OpenAI (offline, or trouble on its side); trying again in 10 minutes or so. The numbers from using Codex still show.")
        case .error: return tr("OpenAI 的回答读不懂：这个接口没有公开，可能改了。用 Codex 时的数字照样会显示。",
                               "OpenAI's answer couldn't be read: the interface isn't public and may have changed. The numbers from using Codex still show.")
        }
    }

    /// The same in one short line, for the menu and the To-do (`hint` says more, in Settings). "" while it reads fine.
    var brief: String {
        switch status {
        case .refused: return tr("ChatGPT 用量查询被拒绝了，可能是被拦下了", "The ChatGPT usage request was refused — it may be blocked")
        case .offline: return tr("连不上 OpenAI，查不到 ChatGPT 用量", "Can't reach OpenAI to look up ChatGPT usage")
        case .error: return tr("OpenAI 回的 ChatGPT 用量读不懂", "OpenAI's answer on ChatGPT usage couldn't be read")
        default: return hint
        }
    }

    func start() {
        guard GPTUsageMonitor.enabled, timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Turned off: nothing read with it is kept, nor when it last asked (turned on again, it asks at once, not up to
    /// ten minutes later); a try planned or an answer on its way is dropped.
    func stop() {
        timer?.invalidate(); timer = nil
        nextLookup?.invalidate(); nextLookup = nil
        usage = nil; holdUntil = nil; busy = false; failures = 0
        lastFetch = .distantPast; retrying = false; turnedOff += 1
        status = .unknown
        onChange?()
    }

    /// The refresh button (Refresh, ⌘R, ⟳ in the left column, the To-do's Try now): read now, but not twice a minute,
    /// and not while OpenAI asked to wait (Claude's waits for Anthropic the same way).
    func refreshNow() { refresh(click: true) }

    /// Settings' Read again, and turning it on: read now (not twice a minute), even while OpenAI asked to wait.
    func reconnect() { refresh(userAction: true) }

    /// On its own (the 5-minute timer, the next lookup): not more than every ten minutes, and not while OpenAI asked
    /// to wait. `click`: see `refreshNow`; `userAction`: see `reconnect`.
    func refresh(click: Bool = false, userAction: Bool = false) {
        guard GPTUsageMonitor.enabled, !busy else { return }
        if !userAction, let h = holdUntil, h > Date() { return }
        if (0..<(click || userAction ? 60 : GPTUsageMonitor.every)).contains(Date().timeIntervalSince(lastFetch)) { return }
        busy = true
        lastFetch = Date()
        planNext()
        let read = readSignIn, off = turnedOff
        DispatchQueue.global(qos: .utility).async {
            let auth = read()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.turnedOff == off else { return }       // turned off meanwhile
                    self.fetch(auth)
                }
            }
        }
    }

    /// The next lookup on its own: ten minutes after this one, and a second (so it never comes short of them).
    private func planNext() {
        nextLookup?.invalidate()
        let t = Timer(fire: lastFetch.addingTimeInterval(GPTUsageMonitor.every + 1), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        nextLookup = t
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
        let off = turnedOff
        let done: (Int, Any?, Double?) -> Void = { [weak self] code, obj, after in
            guard let self, self.turnedOff == off else { return }        // turned off meanwhile: not this answer
            self.got(code, obj, retryAfter: after)
        }
        if let send { send(r, done); return }
        http.dataTask(with: r) { data, resp, _ in
            let h = resp as? HTTPURLResponse
            let code = h?.statusCode ?? 0
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            let after = h?.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(code, obj, after) }
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
            failures = 0
            lastNote = ""
            set(.ok)
        case 401:
            set(.expired)
        case 403:
            note("ChatGPT usage HTTP 403")
            set(.refused)
        case 429:
            let wait = UsageMonitor.hold(retryAfter)              // (the same as Claude's)
            let until = Date().addingTimeInterval(wait), sent = lastFetch
            holdUntil = until
            note("ChatGPT usage HTTP 429: waiting \(Int(wait))s")
            set(.limited)
            // asked again when the wait is over, the time the hint gives (not at the first 10-minute tick after it),
            // unless a newer answer or turning it off changed the wait meanwhile, or the next lookup already went
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 1) { [weak self] in
                MainActor.assumeIsolated {
                    if let self, self.holdUntil == until, self.lastFetch == sent { self.lastFetch = .distantPast; self.refresh() }
                }
            }
        case 0, 500...599:
            // no answer (offline, blocked on the way) or OpenAI's servers in trouble: again in a minute, a few times;
            // with numbers to show, nothing is said unless it keeps happening
            failures += 1
            note("ChatGPT usage HTTP \(code)")
            if failures < 3 { retrySoon() }
            if usage == nil || failures >= 3 { set(.offline) } else { onChange?() }
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

    private func retrySoon() {
        guard !retrying else { return }
        retrying = true
        let off = turnedOff
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.turnedOff == off else { return }           // turned off since: not this try
                self.retrying = false; self.lastFetch = .distantPast; self.refresh()
            }
        }
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
