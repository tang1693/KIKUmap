import Cocoa

// The status of ChatGPT's ordinary chats, read off its window. The app keeps none of it on this Mac and tells no
// one (its hooks and notify settings are Codex's, for Codex threads only), but its sidebar shows a status by a
// chat's name while the reply comes ("Working"; gone once it's done), and a yellow dot on one whose reply you
// haven't read through yet (with "Unread" for screen readers; not on every finish). The window only
// updates while some of it is on screen: covered whole, minimized, hidden or on another desktop, it keeps showing
// what it showed then. So it's read only while it can be seen, and what's out of sight is said to be.

/// A pinned chat's row in ChatGPT's sidebar: whether it shows a status (the reply is coming), and its words; and
/// whether it shows ChatGPT's unread dot.
struct GPTSidebarRow: Equatable {
    var working: Bool
    var status = ""
    var unread = false
}

/// Why ChatGPT's ordinary chats can't be read right now.
enum GPTSidebarIssue: Equatable {
    case noAccess, notRunning, notVisible, sidebarHidden, notFound

    /// One short line.
    var note: String {
        switch self {
        case .noAccess: return tr("辅助功能关着", "Accessibility is off")
        case .notRunning: return tr("ChatGPT 没打开", "ChatGPT isn't open")
        case .notVisible: return tr("ChatGPT 的窗口看不见", "ChatGPT's window can't be seen")
        case .sidebarHidden: return tr("ChatGPT 的左栏收起来了", "ChatGPT's sidebar is hidden")
        case .notFound: return tr("ChatGPT 左栏里找不到置顶的对话", "ChatGPT's sidebar doesn't show the pinned chats")
        }
    }

    /// What waits meanwhile (said in the header's help for Claude, too, when Accessibility is off for both).
    static var paused: String {
        tr("暂停：ChatGPT 普通对话的进行中、做完和未读（Codex 对话不受影响）。在跑的显示「在跑？」，看不到的这段时长是估算的（标 ≈）。\n",
           "Paused: running, finished and unread for ChatGPT's ordinary chats (Codex chats aren't affected). Those that were running show \"running?\"; the time KIKUmap can't see is estimated (marked ≈).\n")
    }

    /// What it means and what to do.
    var help: String {
        let paused = GPTSidebarIssue.paused
        switch self {
        case .noAccess:
            return tr("ChatGPT 的普通对话在不在跑、有没有未读，只能从它的窗口里看，这要「辅助功能」权限。\n", "Whether a ChatGPT ordinary chat is running or unread shows only in its window, which takes Accessibility access.\n")
                + paused + fix
        case .notRunning:
            return tr("ChatGPT 没在运行，看不到它的窗口。\n", "ChatGPT isn't running, so there's no window to read.\n") + paused + fix
        case .notVisible:
            return tr("ChatGPT 的窗口被整个挡住、最小化、隐藏（⌘H）、关了，或者在别的桌面上（开了几个 ChatGPT 窗口的话，说的是带左栏的那个）。这时 ChatGPT 自己也不更新窗口，读到的会是旧的，所以先不读。\n",
                      "ChatGPT's window is covered whole, minimized, hidden (⌘H), closed, or on another desktop (with several ChatGPT windows open: the one with the sidebar). ChatGPT doesn't update its window then, so what it shows would be old: it isn't read meanwhile.\n")
                + paused + fix
        case .sidebarHidden:
            return tr("ChatGPT 窗口的左栏收起来了，看不到置顶的对话。\n", "ChatGPT's sidebar is hidden, so its pinned chats can't be seen.\n") + paused + fix
        case .notFound:
            return tr("ChatGPT 的左栏里没找到 KIKUmap 列出的置顶对话：「置顶」那一组折叠了、对话刚改了名字，或者 ChatGPT 换了界面。\n",
                      "ChatGPT's sidebar doesn't show the pinned chats KIKUmap lists: its Pinned group is folded, a chat was just renamed, or ChatGPT changed its layout.\n")
                + paused + fix
        }
    }

    /// What to do: the last line of `help` (a running chat's row in the menu bar ends with it too).
    var fix: String {
        switch self {
        case .noAccess: return tr("怎么办：设置 → 授权 → 辅助功能。", "Fix: Settings → Access → Accessibility.")
        case .notRunning: return tr("怎么办：打开 ChatGPT，会自动接上。", "Fix: open ChatGPT; KIKUmap picks it up by itself.")
        case .notVisible:
            return tr("怎么办：让 ChatGPT 的窗口露出一部分（左栏露出来最好），马上就会同步。", "Fix: let part of ChatGPT's window show (its sidebar, ideally); it syncs right away.")
        case .sidebarHidden: return tr("怎么办：在 ChatGPT 窗口左上角把左栏打开。", "Fix: show the sidebar in ChatGPT's window (top left).")
        case .notFound:
            return tr("怎么办：在 ChatGPT 左栏里把「置顶」展开。还不行的话，写一份诊断报告（设置 → 授权）发给开发者。",
                      "Fix: unfold Pinned in ChatGPT's sidebar. If that doesn't help, write a diagnostic report (Settings → Access) and send it.")
        }
    }

    /// Only out of sight for now (it comes back by itself): said only while a chat that was running can't be seen.
    var passing: Bool { self == .notVisible || self == .notRunning }
}

enum GPTSidebar {
    /// A name as the sidebar and KIKUmap both write it: runs of spaces as one.
    nonisolated static func norm(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    /// A status on a row that says something other than "working" (an unread or error mark, should ChatGPT add one).
    nonisolated private static let notWorking = try! NSRegularExpression(pattern: "(?i)(unread|new|error|fail|未读|未讀|错误|失败)")
    /// ChatGPT's words for its unread dot (said to screen readers), in the languages it's likely in.
    nonisolated private static let unreadWords = try! NSRegularExpression(pattern: "(?i)(unread|未读|未讀|未読|non lu|ungelesen|no leído|não lid|non lett|읽지 않|belum dibaca|непрочитан)")
    nonisolated private static func matches(_ rx: NSRegularExpression, _ s: String) -> Bool {
        rx.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// What a read found: the rows of the chats asked for (by name), the name of the chat open in the window, and that
    /// window; or why there's nothing to go by (`covered`: the window with the sidebar is out of sight, whatever another
    /// of ChatGPT's windows shows).
    enum Found { case rows([String: GPTSidebarRow], open: String, window: AXUIElement), sidebarHidden, notFound, covered, noWindow }

    /// One of ChatGPT's windows on screen: its number in the window list, where it is, whether some of it can be seen.
    struct Shown { var number: CGWindowID; var frame: CGRect; var inSight: Bool }

    /// Some of a ChatGPT window is on screen: not every point of it is under another app's window in front of it (or
    /// KIKUmap's own). Minimized, hidden and other-desktop windows aren't on screen at all.
    nonisolated static func onScreen(pid: pid_t) -> Bool { windowsOnScreen(pid: pid).contains { $0.inSight } }

    /// ChatGPT's windows on screen, front to back, and whether some of each can be seen. `list`: every window on
    /// screen, front to back (as CGWindowListCopyWindowInfo gives them; looked up when not given).
    nonisolated static func windowsOnScreen(pid: pid_t, list given: [[String: Any]]? = nil) -> [Shown] {
        guard let list = given ?? CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var front: [CGRect] = [], out: [Shown] = []
        for w in list {                                         // front to back
            guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let d = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d),
                  r.width > 40, r.height > 40 else { continue }
            let owner = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if owner == pid {
                if r.width > 200 && r.height > 200 {
                    out.append(Shown(number: (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0, frame: r, inSight: !covered(r, by: front)))
                }
            } else if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.5 {
                continue
            } else if owner != me, NSRunningApplication(processIdentifier: owner)?.activationPolicy != .regular {
                continue                                        // an overlay or a helper's window, not something in the way
            }
            front.append(r)
        }
        return out
    }

    /// Which of ChatGPT's windows, as Accessibility lists them (each one's number in the window list, if known, and
    /// where it is), can be seen. With its number, it's the one of `shown` with that number. Without, it's the one of
    /// `shown` nearest to where it is (it may have moved a little between the two looks), unless which is which can't
    /// be told: another about as near can't be seen, or another of the windows listed is about as near that one (one
    /// window over another of one size, say). Then it isn't taken to be in sight.
    nonisolated static func inSight(_ windows: [(number: CGWindowID?, frame: CGRect?)], _ shown: [Shown]) -> [Bool] {
        func gap(_ a: CGRect, _ b: CGRect) -> CGFloat { abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height) }
        let known = Set(windows.compactMap(\.number))
        return windows.indices.map { i in
            if let n = windows[i].number { return shown.first { $0.number == n }?.inSight ?? false }
            guard let f = windows[i].frame else { return false }
            let near = shown.filter { !known.contains($0.number) && gap($0.frame, f) < 80 }.sorted { gap($0.frame, f) < gap($1.frame, f) }
            guard let c = near.first, c.inSight else { return false }
            let close = gap(c.frame, f) + 40
            if near.contains(where: { !$0.inSight && gap($0.frame, f) < close }) { return false }
            return !windows.indices.contains { j in j != i && windows[j].number == nil && windows[j].frame.map { gap($0, c.frame) < close } == true }
        }
    }

    /// A window's number in the window list, from Accessibility (nil: not known). macOS has no documented way to tell,
    /// but has long had this function (window switchers use it); it's looked up as KIKUmap runs, so a macOS without it
    /// only falls back on where the windows are.
    nonisolated private static let getWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")      // (-2: RTLD_DEFAULT)
            .map { unsafeBitCast($0, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self) }

    nonisolated private static func number(_ w: AXUIElement) -> CGWindowID? {
        var n: CGWindowID = 0
        guard let get = getWindow, get(w, &n) == .success, n != 0 else { return nil }
        return n
    }

    /// Where a window is on screen, from Accessibility (top-left origin, as the window list gives it).
    nonisolated private static func frame(_ w: AXUIElement) -> CGRect? {
        guard let p = AXScan.attr(w, "AXPosition"), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = AXScan.attr(w, "AXSize"), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var o = CGPoint.zero, z = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &o), AXValueGetValue(s as! AXValue, .cgSize, &z) else { return nil }
        return CGRect(origin: o, size: z)
    }

    /// Every point of a grid over `r` lies in one of `rects`.
    nonisolated static func covered(_ r: CGRect, by rects: [CGRect]) -> Bool {
        guard !rects.isEmpty else { return false }
        let n = 12, inner = r.insetBy(dx: 2, dy: 2)
        for i in 0...n {
            for j in 0...n {
                let p = CGPoint(x: inner.minX + inner.width * CGFloat(i) / CGFloat(n), y: inner.minY + inner.height * CGFloat(j) / CGFloat(n))
                if !rects.contains(where: { $0.contains(p) }) { return false }
            }
        }
        return true
    }

    /// The Mac's screen can't be looked at: locked, its display asleep, or the screen saver on.
    nonisolated static var screenAway: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        if let s = CGSessionCopyCurrentDictionary() as? [String: Any], s["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.ScreenSaver.Engine"
    }

    private static func classes(_ el: AXUIElement) -> [String] { AXScan.attr(el, "AXDOMClassList") as? [String] ?? [] }

    /// The first element under `root` (depth first, at most `budget` looked at) whose classes include `cls`, not
    /// looking inside the page's main part or its title bar.
    nonisolated private static func find(_ root: AXUIElement, _ cls: String, budget: Int) -> AXUIElement? {
        var stack = [root], seen = 0
        while let el = stack.popLast(), seen < budget {
            seen += 1
            if classes(el).contains(cls) { return el }
            let sub = AXScan.str(el, "AXSubrole")
            if sub == "AXLandmarkMain" || sub == "AXLandmarkBanner" { continue }
            stack.append(contentsOf: AXScan.children(el).reversed())
        }
        return nil
    }

    /// Elements under `root` whose classes include `cls`, in order (not looking inside one found, nor inside `skip`).
    nonisolated private static func all(_ root: AXUIElement, _ cls: String, skip: String? = nil, budget: Int) -> [AXUIElement] {
        var out: [AXUIElement] = [], stack = [root], seen = 0
        while let el = stack.popLast(), seen < budget {
            seen += 1
            let c = classes(el)
            if el != root && c.contains(cls) { out.append(el); continue }
            if let s = skip, c.contains(s) { continue }
            stack.append(contentsOf: AXScan.children(el).reversed())
        }
        return out
    }

    /// Reads the rows of the chats named in ChatGPT's sidebar: the first of its sections (Pinned, then the others)
    /// that shows any of them, in a window that can be seen. Takes a few hundredths of a second; run it off the main
    /// thread.
    nonisolated static func read(pid: pid_t, names: [String]) -> Found {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let wanted = Set(names.map(norm))
        let windows = AXScan.list(AXScan.attr(app, "AXWindows")).filter {
            AXScan.str($0, "AXSubrole") == "AXStandardWindow" && (AXScan.attr($0, "AXMinimized") as? Bool) != true
        }
        guard !windows.isEmpty else { return .noWindow }
        // which of them can be seen: each one's number and place, looked up right after the list of what's on screen
        // (before a window can move far)
        let shown = windowsOnScreen(pid: pid)
        let seen = inSight(windows.map { (number($0), frame($0)) }, shown)
        var hidden = false, behind = false
        for (w, inView) in zip(windows, seen) {
            guard let panel = find(w, "app-shell-left-panel", budget: 600) else { continue }
            // covered whole, it shows what it showed then (ChatGPT doesn't update it), whatever another of its windows
            // on screen shows
            guard inView else { behind = true; continue }
            guard let nav = find(panel, "sidebar-navigation", budget: 200),
                  AXScan.str(nav, "AXSubrole") != "AXEmptyGroup", !AXScan.children(nav).isEmpty else { hidden = true; continue }
            for section in all(nav, "group/nav-section", budget: 400) {
                var rows: [String: GPTSidebarRow] = [:]
                // a chat's row (a project's folder rows aren't chats)
                for row in all(section, "sidebar-item", skip: "group/cwd", budget: 2000) where AXScan.str(row, "AXRole") == "AXButton" {
                    let name = norm(AXScan.str(row, "AXTitle"))
                    guard wanted.contains(name), rows[name] == nil else { continue }
                    var status = "", said = ""
                    for part in AXScan.children(row) {
                        // words only for screen readers ("Unread", with the yellow dot)
                        if classes(part).contains("sr-only") {
                            for el in [part] + AXScan.children(part) {
                                let w = [AXScan.str(el, "AXValue"), AXScan.str(el, "AXTitle"), AXScan.str(el, "AXDescription")].first { !$0.isEmpty } ?? ""
                                if said.isEmpty && !w.isEmpty { said = w }
                            }
                            continue
                        }
                        for el in [part] + AXScan.children(part) where AXScan.str(el, "AXSubrole") == "AXApplicationStatus" {
                            let words = [AXScan.str(el, "AXDescription"), AXScan.str(el, "AXTitle"), AXScan.str(el, "AXValue")].first { !$0.isEmpty } ?? ""
                            if status.isEmpty { status = words.isEmpty ? "•" : words }
                        }
                    }
                    let working = !status.isEmpty && !matches(notWorking, status)
                    let unread = matches(unreadWords, said) || (!working && matches(unreadWords, status))
                    // words KIKUmap doesn't know: kept for the diagnostic report, not taken for anything
                    let other = !said.isEmpty && !unread ? said : (!status.isEmpty && !working && !unread ? status : "")
                    rows[name] = GPTSidebarRow(working: working, status: other.isEmpty ? status : other, unread: unread)
                }
                if !rows.isEmpty { return .rows(rows, open: norm(AXScan.str(w, "AXTitle")), window: w) }
            }
            return .notFound
        }
        return hidden ? .sidebarHidden : behind ? .covered : .notFound
    }
}

/// Reads ChatGPT's window now and then for its pinned ordinary chats (only while there are some): often while
/// ChatGPT is in front or one of them runs, seldom otherwise, never while the window can't be seen.
@MainActor
final class GPTSidebarWatcher {
    /// Why it can't be read now (nil: read fine, or there's nothing to read).
    private(set) var issue: GPTSidebarIssue?
    /// When it was last read with the window in sight.
    private(set) var lastRead: Date?
    /// A row's status KIKUmap doesn't take for "working", as last read (for the diagnostic report).
    private(set) var otherStatus: String?
    /// The names of the pinned ordinary chats; whether one of them runs.
    var names: (() -> [String])?
    var anyRunning: (() -> Bool)?
    /// Rows by name and the chat open in the window (nil: out of sight, see `issue`).
    var onRead: (([String: GPTSidebarRow]?, String?) -> Void)?
    var onIssue: (() -> Void)?

    private var timer: Timer?
    private var busy = false
    /// The window last read, and since when reads have found it in sight (nil: none, or out of sight since). Back in
    /// sight, a window shows what it showed meanwhile until it catches up: its rows count once it's been in sight a
    /// moment. (Another of ChatGPT's windows in sight says nothing about this one.)
    private var sighted: (window: AXUIElement, since: Date)?
    /// The ChatGPT process asked to build its accessibility tree, and when (it takes a moment to).
    private var askedPID: pid_t = 0
    private var askedAt = Date.distantPast

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                  NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                  NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(0.3) }
            }
        }
        schedule(1)
    }

    func schedule(_ delay: TimeInterval) {
        if let t = timer, t.fireDate.timeIntervalSinceNow <= delay { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func set(_ i: GPTSidebarIssue?) {
        guard i != issue else { return }
        issue = i
        onIssue?()
    }

    /// Out of sight: said, and passed on.
    private func unseen(_ i: GPTSidebarIssue) {
        sighted = nil
        set(i)
        onRead?(nil, nil)
    }

    private var front: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == GPTWatcher.bundleID }

    private func tick() {
        timer = nil
        let names = GPTWatcher.enabled ? (self.names?() ?? []) : []
        // (not read meanwhile: whether its window stays in sight isn't known)
        guard !names.isEmpty else { sighted = nil; set(nil); schedule(15); return }
        let busyNow = anyRunning?() == true
        let next: TimeInterval = front ? 2 : busyNow ? 3 : 10
        guard !busy else { schedule(next); return }
        guard AXIsProcessTrusted() else { unseen(.noAccess); schedule(next); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: GPTWatcher.bundleID).first else {
            unseen(.notRunning); schedule(next); return
        }
        let pid = app.processIdentifier
        guard !app.isHidden, !GPTSidebar.screenAway, GPTSidebar.onScreen(pid: pid) else { unseen(.notVisible); schedule(next); return }
        if askedPID != pid {
            // (an Electron app builds its accessibility tree only once asked, and takes a moment to)
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
            askedPID = pid
            askedAt = Date()
        }
        if Date().timeIntervalSince(askedAt) < 1.5 { schedule(0.8); return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let found = GPTSidebar.read(pid: pid, names: names)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    self.schedule(self.take(found, next: next))
                }
            }
        }
    }

    /// What a read found, taken in; returns when to read next. Rows count only from a window reads have found in sight
    /// for a moment: the first read of one (just back in sight, or another of ChatGPT's windows just brought up) may
    /// show what it showed while it couldn't be seen, so it's read again once the moment is up.
    func take(_ found: GPTSidebar.Found, at date: Date = Date(), next: TimeInterval) -> TimeInterval {
        switch found {
        case .rows(let rows, let open, let window):
            guard let s = sighted, s.window == window else { sighted = (window, date); return 1.5 }
            let wait = 1.5 - date.timeIntervalSince(s.since)
            if wait > 0 { return wait }
            lastRead = date
            otherStatus = rows.values.first { !$0.working && !$0.unread && !$0.status.isEmpty }?.status
            set(nil)
            onRead?(rows, open)
        case .covered, .noWindow: unseen(.notVisible)
        case .sidebarHidden: unseen(.sidebarHidden)
        case .notFound: unseen(.notFound)
        }
        return next
    }
}
