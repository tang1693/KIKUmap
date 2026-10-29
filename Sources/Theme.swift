import Cocoa
import Carbon

/// Chinese / English text, picked by the language setting.
func tr(_ zh: String, _ en: String) -> String { Prefs.english ? en : zh }

/// User settings (UserDefaults).
enum Prefs {
    private static var d: UserDefaults { .standard }

    enum Appearance: String, CaseIterable { case system, light, dark }
    enum Language: String, CaseIterable { case system, zh, en }

    static var appearance: Appearance {
        get { Appearance(rawValue: d.string(forKey: "Appearance") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "Appearance"); MainActor.assumeIsolated { applyAppearance() } }
    }

    static var language: Language {
        get { Language(rawValue: d.string(forKey: "Language") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "Language"); english = computeEnglish() }
    }

    nonisolated(unsafe) static var english = computeEnglish()

    private static func computeEnglish() -> Bool {
        switch language {
        case .zh: return false
        case .en: return true
        case .system: return !(Locale.preferredLanguages.first ?? "zh").hasPrefix("zh")
        }
    }

    static var onboarded: Bool {
        get { d.bool(forKey: "Onboarded") }
        set { d.set(newValue, forKey: "Onboarded") }
    }

    /// Global shortcut that shows / hides the map (Carbon key code + modifiers).
    static var hotKeyCode: UInt32 {
        get { d.object(forKey: "HotKeyCode") as? UInt32 ?? UInt32(kVK_ANSI_C) }
        set { d.set(newValue, forKey: "HotKeyCode") }
    }
    static var hotKeyMods: UInt32 {
        get { d.object(forKey: "HotKeyMods") as? UInt32 ?? UInt32(controlKey | optionKey) }
        set { d.set(newValue, forKey: "HotKeyMods") }
    }
    static var hotKeyEnabled: Bool {
        get { d.object(forKey: "HotKeyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "HotKeyEnabled") }
    }

    static var soundDone: String {
        get { d.string(forKey: "SoundDone") ?? "Glass" }
        set { d.set(newValue, forKey: "SoundDone") }
    }
    static var soundInput: String {
        get { d.string(forKey: "SoundInput") ?? "Hero" }
        set { d.set(newValue, forKey: "SoundInput") }
    }
    /// No sound while you're already looking at the Claude app.
    static var quietWhenClaudeFront: Bool {
        get { d.object(forKey: "QuietWhenFront") as? Bool ?? true }
        set { d.set(newValue, forKey: "QuietWhenFront") }
    }
    /// The map window's left column (width, or tucked away) and timeline.
    static var sideWidth: CGFloat {
        get { let v = d.double(forKey: "SideWidth"); return v > 0 ? CGFloat(v) : 270 }
        set { d.set(Double(newValue), forKey: "SideWidth") }
    }
    static var sideHidden: Bool {
        get { d.bool(forKey: "SideHidden") }
        set { d.set(newValue, forKey: "SideHidden") }
    }
    /// ⌘+ / ⌘-: how big everything in the map window is drawn (1 = normal).
    static var uiScale: CGFloat {
        get { let v = d.double(forKey: "UIScale"); return v > 0 ? CGFloat(v) : 1 }
        set { d.set(Double(newValue), forKey: "UIScale") }
    }
    static var timelineHidden: Bool {
        get { d.bool(forKey: "TimelineHidden") }
        set { d.set(newValue, forKey: "TimelineHidden") }
    }
    /// After the sound, say which chat it was ("Pricing plan is done"). Off until you turn it on:
    /// the names are spoken out loud.
    static var speak: Bool {
        get { d.bool(forKey: "Speak") }
        set { d.set(newValue, forKey: "Speak") }
    }
    /// A voice identifier; nil picks one that matches the language of what's said.
    static var speakVoice: String? {
        get { d.string(forKey: "SpeakVoice") }
        set { d.set(newValue, forKey: "SpeakVoice") }
    }
    static let speakRates: [Float] = [0.42, 0.5, 0.56, 0.62]
    static var speakRate: Float {
        get { (d.object(forKey: "SpeakRate") as? NSNumber)?.floatValue ?? 0.5 }
        set { d.set(newValue, forKey: "SpeakRate") }
    }
    /// What's said; {name} is the chat.
    static var speakDone: String {
        get { d.string(forKey: "SpeakDone") ?? tr("{name} 做完了", "{name} is done") }
        set { d.set(newValue, forKey: "SpeakDone") }
    }
    static var speakInput: String {
        get { d.string(forKey: "SpeakInput") ?? tr("{name} 在等你", "{name} needs you") }
        set { d.set(newValue, forKey: "SpeakInput") }
    }

    @MainActor
    static func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Light ↔ dark, starting from whatever is showing now.
    @MainActor
    static func toggleLights() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appearance = dark ? .light : .dark
    }

    /// "⌃⌥C"
    static func hotKeyLabel(code: UInt32 = hotKeyCode, mods: UInt32 = hotKeyMods) -> String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName(code)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
                                      kVK_Delete: "⌫", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                      kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2",
                                      kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
                                      kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let s = special[Int(code)] { return s }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let r = data.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return r == noErr && len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "?"
    }
}

/// Neutral, low-saturation interface. Colour is kept for what *you* mark: branches and tags.
enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return rgb(hex)
        }
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let bg = dyn(0xF4F4F3, 0x161617)
    static let paper = dyn(0xFFFFFF, 0x1F1F21)
    static let ink = dyn(0x1C1C1E, 0xE9E9EA)
    static let muted = dyn(0x86868B, 0x8E8E93)
    static let faint = dyn(0xE3E3E1, 0x2E2E31)
    static let hover = dyn(0xECECEA, 0x262628)
    /// Connectors and underlines of branches that have no colour.
    static let line = dyn(0xBDBDC0, 0x4A4A4F)

    /// Highlight colours you can give to branches and tags. Same hue order in both modes.
    struct Highlight { let key: String; let zh: String; let en: String; let color: NSColor }
    static let highlights: [Highlight] = [
        Highlight(key: "red", zh: "红", en: "Red", color: dyn(0xD5524C, 0xE8675F)),
        Highlight(key: "orange", zh: "橙", en: "Orange", color: dyn(0xDB7633, 0xEF8B48)),
        Highlight(key: "yellow", zh: "黄", en: "Yellow", color: dyn(0xC99A10, 0xE2B52C)),
        Highlight(key: "green", zh: "绿", en: "Green", color: dyn(0x46955A, 0x5FB473)),
        Highlight(key: "teal", zh: "青", en: "Teal", color: dyn(0x2B948E, 0x3DB2AA)),
        Highlight(key: "blue", zh: "蓝", en: "Blue", color: dyn(0x3A78D0, 0x5A92E4)),
        Highlight(key: "indigo", zh: "靛", en: "Indigo", color: dyn(0x5A5DC4, 0x7C7FDF)),
        Highlight(key: "violet", zh: "紫", en: "Violet", color: dyn(0x8B58BA, 0xA67AD5)),
        Highlight(key: "pink", zh: "粉", en: "Pink", color: dyn(0xCF5789, 0xE5739F)),
        Highlight(key: "brown", zh: "棕", en: "Brown", color: dyn(0x93704F, 0xAE8A69)),
    ]
    private static let byKey: [String: Highlight] = Dictionary(uniqueKeysWithValues: highlights.map { ($0.key, $0) })

    /// A highlight colour, or nil for "no colour" (also the old "black" / "gray").
    static func highlight(_ key: String?) -> NSColor? { key.flatMap { byKey[$0]?.color } }
    static func highlightName(_ key: String) -> String { byKey[key].map { tr($0.zh, $0.en) } ?? key }

    /// Colour of a branch's lines: its highlight, or neutral grey.
    static func branch(_ key: String?) -> NSColor { highlight(key) ?? line }

    static func geo(_ size: CGFloat, bold: Bool = false) -> NSFont {
        .systemFont(ofSize: size, weight: bold ? .bold : .medium)
    }

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// Status marks — shapes, not colours. Running: open ring. Waiting for you: solid dot.
    static func drawStatus(_ state: Int, in r: NSRect, color: NSColor = ink, phase: CGFloat = 0) {
        let c = r.insetBy(dx: 1, dy: 1)
        if state == 2 {
            let ring = NSBezierPath(ovalIn: c.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            color.withAlphaComponent(0.3).setStroke(); ring.stroke()
            let arc = NSBezierPath()
            let mid = NSPoint(x: c.midX, y: c.midY), rad = c.width / 2 - 0.75
            let a0 = -phase * 360
            arc.appendArc(withCenter: mid, radius: rad, startAngle: a0, endAngle: a0 + 110)
            arc.lineWidth = 1.5; arc.lineCapStyle = .round
            color.setStroke(); arc.stroke()
        } else if state == 1 {
            color.setFill(); NSBezierPath(ovalIn: c.insetBy(dx: 1, dy: 1)).fill()
        }
    }

    static func swatch(_ c: NSColor?, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            if let c = c { c.setFill(); p.fill() } else {
                NSColor.secondaryLabelColor.setStroke(); p.lineWidth = 1; p.stroke()
            }
            return true
        }
    }
}

/// Small text helpers.
extension String {
    func size(_ font: NSFont) -> NSSize {
        (self as NSString).size(withAttributes: [.font: font])
    }

    /// "[个人] Mac mini" → "Mac mini"
    var strippedPrefix: String {
        let s = replacingOccurrences(of: #"^\s*[\[【][^\]】]*[\]】]\s*"#, with: "", options: .regularExpression)
        return s.isEmpty ? self : s
    }
}

enum Clock {
    static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    static func iso(_ d: Date = Date()) -> String { isoFormatter.string(from: d) }
    static func parse(_ s: String) -> Date? { s.isEmpty ? nil : isoFormatter.date(from: s) }

    /// Any ISO-8601 timestamp ("…T17:41:26.072910Z", "…+00:00").
    static func parseAny(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        let plain = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: plain)
    }

    static func format(_ d: Date, _ zh: String, _ en: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: Prefs.english ? "en_US" : "zh_CN")
        f.dateFormat = tr(zh, en)
        return f.string(from: d)
    }

    private static func hm(_ sec: Double) -> (Int, Int) { (Int(sec / 3600), Int(sec.truncatingRemainder(dividingBy: 3600) / 60)) }

    /// "1小时20分" / "1h 20m" (at least a minute)
    static func duration(_ sec: Double) -> String {
        let (h, m) = hm(max(sec, 60))
        if h == 0 { return tr("\(m)分钟", "\(m)m") }
        return m == 0 ? tr("\(h)小时", "\(h)h") : tr("\(h)小时\(m)分", "\(h)h \(m)m")
    }

    /// "3小时12分后" / "in 3h 12m"
    static func countdown(_ d: Date) -> String {
        let sec = d.timeIntervalSinceNow
        if sec <= 60 { return tr("马上", "now") }
        if sec < 3600 { return tr("\(Int(sec / 60))分钟后", "in \(Int(sec / 60))m") }
        if sec < 86400 { let (h, m) = hm(sec); return tr("\(h)小时\(m)分后", "in \(h)h \(m)m") }
        let days = Int(sec / 86400), h = Int(sec.truncatingRemainder(dividingBy: 86400) / 3600)
        return tr("\(days)天\(h)小时后", "in \(days)d \(h)h")
    }

    /// "3分钟前", "昨天", "10/21"
    static func ago(_ s: String) -> String {
        guard let d = parse(s) else { return "" }
        let sec = Date().timeIntervalSince(d)
        if sec < 60 { return tr("刚刚", "just now") }
        if sec < 3600 { return tr("\(Int(sec / 60))分钟前", "\(Int(sec / 60))m ago") }
        if sec < 86400 { return tr("\(Int(sec / 3600))小时前", "\(Int(sec / 3600))h ago") }
        let days = Int(sec / 86400)
        if days == 1 { return tr("昨天", "yesterday") }
        if days < 7 { return tr("\(days)天前", "\(days)d ago") }
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// "今天 18:40 重置" / "resets today 18:40"
    static func resets(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let cal = Calendar.current
        let t = format(d, "HH:mm", "HH:mm")
        if cal.isDateInToday(d) { return tr("今天 \(t) 重置", "resets today \(t)") }
        if cal.isDateInTomorrow(d) { return tr("明天 \(t) 重置", "resets tomorrow \(t)") }
        let w = format(d, "EEE HH:mm", "EEE HH:mm")
        return tr(w + " 重置", "resets " + w)
    }

    /// "2小时后", "周四 09:00"
    static func until(_ d: Date) -> String {
        let sec = d.timeIntervalSinceNow
        if sec <= 0 { return tr("现在", "now") }
        if sec < 86400 { return countdown(d) }
        return format(d, "EEE HH:mm", "EEE HH:mm")
    }
}
