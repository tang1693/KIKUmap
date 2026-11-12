import Cocoa
import Carbon

extension L10n {
    /// "1 chat" / "3 chats" in the current language (keys "1 chat" and "%@ chats"), for counts inside a sentence.
    static func count(_ k: Int, _ one: String, _ many: String) -> String {
        let key = k == 1 ? TrKey("1 " + one) : TrKey(key: "%@ " + many, args: ["\(k)"], value: "\(k) " + many)
        return text(key, zh: "", in: Prefs.lang)
    }

}

/// The text in the language setting's language: written in Chinese and English, the rest from the table (L10n.swift).
func tr(_ zh: String, _ en: TrKey) -> String { L10n.text(en, zh: zh, in: Prefs.lang) }

/// User settings (UserDefaults).
enum Prefs {
    private static var d: UserDefaults { .standard }

    enum Appearance: String, CaseIterable { case system, light, dark }
    enum Language: String, CaseIterable { case system, zh, zhHant = "zh-Hant", en, ja, ko, es, pt = "pt-BR", de, fr }

    static var appearance: Appearance {
        get { Appearance(rawValue: d.string(forKey: "Appearance") ?? "") ?? .system }
        set {
            d.set(newValue.rawValue, forKey: "Appearance")
            // (Settings → General shows the choice: it follows one made elsewhere, the ☾ / ☀︎ button's too)
            MainActor.assumeIsolated { applyAppearance(); NotificationCenter.default.post(name: appearanceChanged, object: nil) }
        }
    }
    static let appearanceChanged = Notification.Name("KIKUmapAppearanceChanged")

    static var language: Language {
        get { Language(rawValue: d.string(forKey: "Language") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "Language"); lang = computeLang() }
    }

    /// The language KIKUmap speaks now (the setting, or the Mac's when it's "System").
    nonisolated(unsafe) static var lang = computeLang()
    /// Not Chinese: names that only come in Chinese and English (a folder's, say) take the English one. (Setting it
    /// picks English or Simplified Chinese, as the checks do.)
    static var english: Bool {
        get { !lang.isChinese }
        set { lang = newValue ? .en : .zhHans }
    }

    private static func computeLang() -> Lang {
        if language == .system { return Lang.system }
        return Lang(rawValue: language.rawValue) ?? .en
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
    /// macOS refused the shortcut when it was last registered (another app or a system shortcut has it): its error.
    nonisolated(unsafe) static var hotKeyError: OSStatus?
    /// The shortcut really works: switched on and taken by macOS. Everywhere it's offered goes by this.
    static var hotKeyWorks: Bool { hotKeyEnabled && hotKeyError == nil }

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
    /// No sound while you're looking at the ChatGPT app (off unless asked for).
    static var quietWhenGPTFront: Bool {
        get { d.bool(forKey: "QuietWhenGPTFront") }
        set { d.set(newValue, forKey: "QuietWhenGPTFront") }
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
    /// The tag shelf at the foot of the left column: tucked away, and the height it was dragged to (0: as tall as its
    /// tags need, up to about half the column).
    static var tagsHidden: Bool {
        get { d.bool(forKey: "TagsHidden") }
        set { d.set(newValue, forKey: "TagsHidden") }
    }
    static var tagsHeight: CGFloat {
        get { CGFloat(d.double(forKey: "TagsHeight")) }
        set { d.set(Double(newValue), forKey: "TagsHeight") }
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
    /// A sentence you wrote yourself stays; one that's a default (in any language, or an older version's) follows the
    /// app's language, so switching it doesn't leave the voice reading the old language's words.
    static var speakDone: String {
        get { spoken("SpeakDone", zh: "{name} 做完了", en: "{name} is done", older: ["{name} 做完了"]) }
        set { setSpoken(newValue, "SpeakDone", zh: "{name} 做完了", en: "{name} is done", older: []) }
    }
    static var speakInput: String {
        get { spoken("SpeakInput", zh: "{name} 在等你确认", en: "{name} is waiting for you", older: ["{name} 在等你", "{name} needs you"]) }
        set { setSpoken(newValue, "SpeakInput", zh: "{name} 在等你确认", en: "{name} is waiting for you", older: ["{name} 在等你", "{name} needs you"]) }
    }
    /// Every default the sentence has had: Chinese (both scripts), English and each translation, now and before.
    private static func defaults(zh: String, en: String, older: [String]) -> Set<String> {
        var all = Set([zh, en, L10n.traditional(zh)] + older + older.map(L10n.traditional))
        all.formUnion((L10n.entries[en] ?? []).filter { !$0.isEmpty })
        return Set(all.map { $0.trimmingCharacters(in: .whitespaces) })
    }
    private static func spoken(_ key: String, zh: String, en: String, older: [String]) -> String {
        let now = tr(zh, TrKey(en))
        guard let s = d.string(forKey: key), !defaults(zh: zh, en: en, older: older).contains(s.trimmingCharacters(in: .whitespaces)) else { return now }
        return s
    }
    private static func setSpoken(_ v: String, _ key: String, zh: String, en: String, older: [String]) {
        if defaults(zh: zh, en: en, older: older).contains(v.trimmingCharacters(in: .whitespaces)) { d.removeObject(forKey: key) }   // a default: not kept
        else { d.set(v, forKey: key) }
    }

    @MainActor
    static func applyAppearance() {
        // a color set that's always dark (or light) wins over the choice here
        switch Theme.palette.mode {
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua); return
        case .light: NSApp.appearance = NSAppearance(named: .aqua); return
        case .both: break
        }
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Light ↔ dark, starting from whatever is showing now.
    @MainActor
    static func toggleLights() {
        guard Theme.palette.mode == .both else { NSSound.beep(); return }     // this color set is always dark (or light)
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
    /// The ring round a picked item, on the map and in the left column alike: blue (clear of the orange "running" and
    /// the red "unread" whatever the Mac's accent colour), paler while the keys go elsewhere.
    static func pickRing(focused: Bool) -> NSColor { pick.withAlphaComponent(focused ? 1 : 0.5) }

    /// System Settings → Accessibility → Display, as set now: Increase Contrast draws grey text and lines stronger,
    /// Reduce Motion moves things on the map without sliding them. Kept up to date by `followDisplayOptions`.
    nonisolated(unsafe) static var moreContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    nonisolated(unsafe) static var lessMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private nonisolated(unsafe) static var following = false

    /// Once, at launch: when those settings change, every window draws itself again.
    @MainActor
    static func followDisplayOptions() {
        guard !following else { return }
        following = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                moreContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                lessMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                func redraw(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(redraw) }
                for w in NSApp.windows { w.contentView.map(redraw) }
            }
        }
    }

    /// `more`: the light and dark hexes for Increase Contrast (otherwise it looks the same).
    static func dyn(_ light: UInt32, _ dark: UInt32, more: (UInt32, UInt32)? = nil) -> NSColor {
        NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if let m = more, moreContrast { return rgb(isDark ? m.1 : m.0) }
            return rgb(isDark ? dark : light)
        }
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The color set in use (Settings → Colors). Every color below is looked up in it each time it's drawn, so a
    /// change shows as soon as the windows draw again (`setPalette`).
    nonisolated(unsafe) static var palette = Palette.saved()
    nonisolated(unsafe) static var paletteKey = Palette.savedKey()
    static let paletteChanged = Notification.Name("KIKUmapPaletteChanged")

    /// One part of the interface in the color set, for the appearance it's drawn in. A set with one look draws that
    /// look wherever it's drawn: the menu bar can have the other one, and the menu-bar icon uses these colors too.
    static func role(_ pick: @escaping (Palette) -> Palette.Pair, more: ((Palette) -> Palette.Pair)? = nil) -> NSColor {
        NSColor(name: nil) { ap in
            let p = palette
            let isDark = p.mode == .both ? ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua : p.mode == .dark
            let pair = (moreContrast ? more : nil).map { $0(p) } ?? pick(p)
            return rgb(isDark ? pair.dark : pair.light)
        }
    }

    static let bg = role { $0.bg }
    static let paper = role { $0.paper }
    static let ink = role { $0.ink }
    /// Increase Contrast: stronger, toward the text (Classic: at least 5.6:1 on every background here).
    static let muted = role({ $0.muted }, more: { $0.strongerMuted })
    static let faint = role { $0.faint }
    static let hover = role { $0.hover }
    /// Connectors and underlines of branches that have no color (Increase Contrast: 3:1 or more, as for lines).
    static let line = role({ $0.line }, more: { $0.strongerLine })
    /// The ring round a picked item; a running chat's moving line and rings; an unread chat's dot.
    static let pick = role { $0.pick }
    static let running = role { $0.running }
    static let unread = role { $0.unread }

    /// Black or white for text on `c` (on a filled "running" button, a chat's name on its timeline bar): white, unless
    /// it would read under 3:1 there (a light fill: yellow, a pale gray), then near-black, which reads 6:1 or more on
    /// it. `under`: what `c` is drawn over when it's see-through (a finished run's faded bar on the panel), so the color
    /// judged is the one seen.
    static func onColor(_ c: NSColor, over under: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { ap in
            var out = NSColor.white
            ap.performAsCurrentDrawingAppearance {
                out = luminance(c, over: under) > 0.3 ? NSColor(white: 0.08, alpha: 1) : .white
            }
            return out
        }
    }

    /// How light `c` is as drawn now (WCAG relative luminance, 0 black to 1 white), over `under` (white if none) where
    /// it's see-through. White text reads 3:1 on 0.3, and better on anything darker.
    static func luminance(_ c: NSColor, over under: NSColor? = nil) -> CGFloat {
        let s = c.usingColorSpace(.sRGB) ?? c, u = (under ?? .white).usingColorSpace(.sRGB) ?? .white
        let a = s.alphaComponent
        func lin(_ f: CGFloat, _ b: CGFloat) -> CGFloat {
            let v = max(0, min(1, f * a + b * (1 - a)))
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(s.redComponent, u.redComponent) + 0.7152 * lin(s.greenComponent, u.greenComponent)
            + 0.0722 * lin(s.blueComponent, u.blueComponent)
    }

    /// Uses `p` (saved under `key`: a preset's, or "custom"), and draws everything again.
    @MainActor
    static func setPalette(_ p: Palette, key: String) {
        palette = p; paletteKey = key
        Palette.save(p, key: key)
        Prefs.applyAppearance()
        func redraw(_ v: NSView) { v.needsDisplay = true; v.subviews.forEach(redraw) }
        for w in NSApp.windows { w.contentView.map(redraw) }
        NotificationCenter.default.post(name: paletteChanged, object: nil)
    }

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

    /// A highlight colour, or nil for "no color" (also the old "black" / "gray").
    static func highlight(_ key: String?) -> NSColor? { key.flatMap { byKey[$0]?.color } }
    static func highlightName(_ key: String) -> String { byKey[key].map { tr($0.zh, TrKey($0.en)) } ?? key }

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

    /// Where a running count's arc is now (0…1): by the clock, so every ring turns at the same calm pace, in step,
    /// however often it's redrawn.
    static func turn(period: Double = 2.4) -> CGFloat {
        CGFloat(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period)
    }
    /// How often a turning ring is redrawn.
    static let turnFrame = 1.0 / 24

    /// A small boxed tag saying where a chat lives: "Claude" for the Claude app's, "GPT" for ChatGPT's (a terminal
    /// marks Claude Code sessions).
    static func appTag(_ text: String, _ color: NSColor, height: CGFloat = 12) -> NSImage {
        let font = NSFont.systemFont(ofSize: height * 0.62, weight: .heavy)
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: -0.2])
        let w = ceil(s.size().width) + 4
        return NSImage(size: NSSize(width: w, height: height), flipped: false) { r in
            color.setStroke()
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.6, dy: 0.6), xRadius: 2.5, yRadius: 2.5)
            box.lineWidth = 1
            box.stroke()
            let ts = s.size()
            s.draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2 + 0.3))
            return true
        }
    }
    static func claudeTag(_ color: NSColor, height: CGFloat = 12) -> NSImage { appTag("Claude", color, height: height) }

    /// A running chat's outline: a stretch of `color` going slowly round it, clockwise on screen, like the arc round
    /// a running count. `perimeter` is the outline's length; the stretch is at most a third of it.
    static func drawSnake(_ p: NSBezierPath, perimeter: CGFloat, color: NSColor, lineWidth: CGFloat, length: CGFloat = 70, speed: CGFloat = 40) {
        guard perimeter > 0 else { return }
        let l = min(length, perimeter / 3)
        let at = CGFloat((Date().timeIntervalSinceReferenceDate * Double(speed)).truncatingRemainder(dividingBy: Double(perimeter)))
        let s = p.copy() as! NSBezierPath
        s.lineWidth = lineWidth; s.lineCapStyle = .round
        // (the rounded rect's path runs clockwise on screen in a flipped view: the dash moves on along it)
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        s.setLineDash([l, perimeter - l], count: 2, phase: flipped ? -at : at)
        color.setStroke(); s.stroke()
    }

    /// How many are running: the number in a ring. With `phase` (0…1, one turn) an arc goes round it clockwise,
    /// meaning they're running now as far as KIKUmap can see; without, the ring stands still. The same in the menu
    /// bar, the window's header and the map's topics.
    static func drawRunCount(_ text: String, in r: NSRect, ink: NSColor, arc: NSColor, font: NSFont, phase: CGFloat?, lineWidth: CGFloat = 1.5) {
        let d = min(r.width, r.height)
        let c = NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let ring = NSBezierPath(ovalIn: c)
        ring.lineWidth = lineWidth
        if let p = phase {
            ink.withAlphaComponent(0.2).setStroke(); ring.stroke()
            // (a flipped view counts angles the other way round: clockwise from the top either way)
            let flipped = NSGraphicsContext.current?.isFlipped ?? false
            let head = flipped ? -90 + p * 360 : 90 - p * 360
            let a = NSBezierPath()
            a.appendArc(withCenter: NSPoint(x: c.midX, y: c.midY), radius: c.width / 2,
                        startAngle: head, endAngle: flipped ? head - 120 : head + 120, clockwise: flipped)
            a.lineWidth = lineWidth; a.lineCapStyle = .round
            arc.setStroke(); a.stroke()
        } else {
            ink.setStroke(); ring.stroke()
        }
        // a longer number gets a smaller font, so it stays inside
        var f = font
        let room = c.width - 2 * lineWidth - 3
        let w = text.size(f).width
        if w > room { f = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * room / w) ?? font }
        let ts = text.size(f)
        (text as NSString).draw(at: NSPoint(x: c.midX - ts.width / 2, y: c.midY - ts.height / 2),
                                withAttributes: [.font: f, .foregroundColor: ink])
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
    static func parse(_ s: String) -> Date? { s.isEmpty ? nil : (fast(s) ?? isoFormatter.date(from: s)) }

    private static let monthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// "yyyy-MM-ddTHH:mm:ssZ", the one shape `iso` writes, read without a DateFormatter: statistics and the timeline
    /// read thousands of these on every redraw. Anything else goes to the formatter.
    private static func fast(_ s: String) -> Date? {
        func read(_ p: UnsafeBufferPointer<UInt8>) -> Date? {
            guard p.count == 20, p[4] == 45, p[7] == 45, p[10] == 84, p[13] == 58, p[16] == 58, p[19] == 90 else { return nil }
            func n(_ a: Int, _ k: Int) -> Int? {
                var v = 0
                for i in a..<(a + k) { let c = Int(p[i]) - 48; guard (0...9).contains(c) else { return nil }; v = v * 10 + c }
                return v
            }
            guard let y = n(0, 4), let mo = n(5, 2), let d = n(8, 2), let h = n(11, 2), let mi = n(14, 2), let se = n(17, 2),
                  (1...12).contains(mo), h < 24, mi < 60, se < 60 else { return nil }
            let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
            guard d >= 1, d <= (mo == 2 && leap ? 29 : monthDays[mo - 1]) else { return nil }
            // days since 1970-01-01 (Howard Hinnant's days_from_civil)
            let yy = mo <= 2 ? y - 1 : y
            let era = (yy >= 0 ? yy : yy - 399) / 400, yoe = yy - era * 400
            let doy = (153 * ((mo + 9) % 12) + 2) / 5 + d - 1
            let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
            return Date(timeIntervalSince1970: TimeInterval(days * 86400 + h * 3600 + mi * 60 + se))
        }
        return s.utf8.withContiguousStorageIfAvailable(read) ?? Array(s.utf8).withUnsafeBufferPointer(read)
    }

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
        f.locale = Prefs.lang.locale
        let l = Prefs.lang
        if l != .en && !l.isChinese && (en.contains("MMM") || en.contains("EEE")) {
            // month and weekday names in the language's own order ("Mi., 11. Nov."), not the English one; a trailing
            // ", " (a time follows) becomes a space
            f.setLocalizedDateFormatFromTemplate(en.filter { $0.isLetter })
            return f.string(from: d) + (en.hasSuffix(" ") ? " " : "")
        }
        f.dateFormat = tr(zh, TrKey(en))
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

    /// Calendar days from `a` to `b`, as the wall calendar counts them (noon to noon: a day 23 or 25 hours long, or
    /// one whose midnight is skipped, is one day).
    static func days(from a: Date, to b: Date, _ cal: Calendar = .current) -> Int {
        func noon(_ d: Date) -> Date { cal.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d }
        return cal.dateComponents([.day], from: noon(a), to: noon(b)).day ?? 0
    }

    /// "3分钟前", "昨天", "10/21"
    static func ago(_ s: String) -> String {
        guard let d = parse(s) else { return "" }
        let sec = Date().timeIntervalSince(d)
        if sec < 60 { return tr("刚刚", "just now") }
        if sec < 3600 { return tr("\(Int(sec / 60))分钟前", "\(Int(sec / 60))m ago") }
        // older: calendar days (two days ago at a later hour is not "yesterday"), as the other date texts count them
        let days = Clock.days(from: d, to: Date())
        if sec < 86400 || days < 1 { return tr("\(Int(sec / 3600))小时前", "\(Int(sec / 3600))h ago") }
        if days == 1 { return tr("昨天", "yesterday") }
        if days < 7 { return tr("\(days)天前", "\(days)d ago") }
        // (another year: with it, or a chat from last October reads as this one)
        if Calendar.current.component(.year, from: d) != Calendar.current.component(.year, from: Date()) { return format(d, "yyyy/M/d", "M/d/yy") }
        return format(d, "M/d", "M/d")
    }

    /// "今天 18:40 重置" / "resets today 18:40"
    static func resets(_ d: Date?) -> String {
        guard let d = d, d > Date() else { return "" }      // a reset that has passed says nothing about the next one
        let cal = Calendar.current
        let t = format(d, "HH:mm", "HH:mm")
        if cal.isDateInToday(d) { return tr("今天 \(t) 重置", "resets today \(t)") }
        if cal.isDateInTomorrow(d) { return tr("明天 \(t) 重置", "resets tomorrow \(t)") }
        let w = format(d, "EEE HH:mm", "EEE HH:mm")
        return tr("\(w) 重置", "resets \(w)")
    }

    /// "2小时后", "周四 09:00"
    static func until(_ d: Date) -> String {
        let sec = d.timeIntervalSinceNow
        if sec <= 0 { return tr("现在", "now") }
        if sec < 86400 { return countdown(d) }
        return format(d, "EEE HH:mm", "EEE HH:mm")
    }
}

/// A color set: light and dark values for each part of the interface (Settings → Colors). Some sets are always
/// dark or always light; then the window keeps that look whatever the Mac or the ☾ / ☀︎ button says.
struct Palette: Codable, Equatable {
    struct Pair: Codable, Equatable { var light: UInt32; var dark: UInt32 }
    enum Mode: String, Codable { case both, dark, light }
    var mode: Mode
    var bg, paper, ink, muted, line, pick, running, unread: Pair
    /// Fills for empty areas and hover: a small step from the background toward the text.
    var faint, hover: Pair

    init(_ mode: Mode, bg: Pair, paper: Pair, ink: Pair, muted: Pair, line: Pair, pick: Pair, running: Pair, unread: Pair,
         faint: Pair? = nil, hover: Pair? = nil) {
        self.mode = mode; self.bg = bg; self.paper = paper; self.ink = ink; self.muted = muted; self.line = line
        self.pick = pick; self.running = running; self.unread = unread
        self.faint = faint ?? Palette.step(bg, ink, 0.08, 0.115)
        self.hover = hover ?? Palette.step(bg, ink, 0.037, 0.076)
    }

    /// `a` moved toward `b`: by `l` in light, `d` in dark.
    static func step(_ a: Pair, _ b: Pair, _ l: Double, _ d: Double) -> Pair {
        Pair(light: mix(a.light, b.light, l), dark: mix(a.dark, b.dark, d))
    }
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ x: UInt32, _ s: UInt32) -> UInt32 {
            let p = Double((a >> s) & 0xFF), q = Double((b >> s) & 0xFF)
            return UInt32(max(0, min(255, (p + (q - p) * t).rounded()))) << s
        }
        return ch(a, 16) | ch(a, 8) | ch(a, 0)
    }
    /// Increase Contrast: secondary text and lines closer to the text color (Classic keeps its own values), at least
    /// 4.5:1 for secondary text and 3:1 for lines on the background and on panels, in every set.
    var strongerMuted: Pair { self == Palette.classic ? Pair(light: 0x56565B, dark: 0xB8B8BD) : stronger(muted, from: 0.45, reaching: 4.5) }
    var strongerLine: Pair { self == Palette.classic ? Pair(light: 0x7C7C82, dark: 0x85858B) : stronger(line, from: 0.35, reaching: 3) }

    /// `c` moved toward the text color by `t`, and further in steps until it reads `ratio`:1 on the background and on
    /// panels (as far as the text color itself), in light and in dark.
    private func stronger(_ c: Pair, from t: Double, reaching ratio: Double) -> Pair {
        func side(_ c: UInt32, _ ink: UInt32, _ backs: [UInt32]) -> UInt32 {
            var t = t
            while t < 1, backs.contains(where: { Palette.contrast(Palette.mix(c, ink, t), $0) < ratio }) { t = min(1, t + 0.05) }
            return Palette.mix(c, ink, t)
        }
        return Pair(light: side(c.light, ink.light, [bg.light, paper.light]), dark: side(c.dark, ink.dark, [bg.dark, paper.dark]))
    }

    /// How two colors read against each other (WCAG's contrast ratio, 1…21).
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ h: UInt32) -> Double {
            func f(_ c: UInt32) -> Double { let v = Double(c & 0xFF) / 255; return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * f(h >> 16) + 0.7152 * f(h >> 8) + 0.0722 * f(h)
        }
        let x = lum(a), y = lum(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// One part set by hand (Settings → Colors), in light or in dark. A set with one look takes it on both sides, so it
    /// is the same wherever it's drawn; a new background or text color brings the fills along.
    func with(_ part: WritableKeyPath<Palette, Pair>, _ hex: UInt32, dark: Bool) -> Palette {
        var p = self
        if mode != .both { p[keyPath: part] = Pair(light: hex, dark: hex) } else if dark { p[keyPath: part].dark = hex } else { p[keyPath: part].light = hex }
        if part == \Palette.bg || part == \Palette.ink { p.refill() }
        return p
    }

    /// After one part was changed by hand: the fills that follow from the background and text again.
    mutating func refill() {
        faint = Palette.step(bg, ink, 0.08, 0.115); hover = Palette.step(bg, ink, 0.037, 0.076)
    }

    /// The parts you can set by hand, in the order Settings shows them.
    static let parts: [(zh: String, en: String, key: WritableKeyPath<Palette, Pair>)] = [
        ("背景", "Background", \.bg), ("面板", "Panels", \.paper), ("文字", "Text", \.ink), ("次要文字", "Secondary text", \.muted),
        ("线条", "Lines", \.line), ("选中", "Selection", \.pick), ("在跑", "Running", \.running), ("未读", "Unread", \.unread),
    ]

    struct Preset { let key: String; let zh: String; let en: String; let palette: Palette }
    private static func p(_ l: UInt32, _ d: UInt32) -> Pair { Pair(light: l, dark: d) }
    private static func one(_ c: UInt32) -> Pair { Pair(light: c, dark: c) }

    /// How KIKUmap has always looked: grays, the system's blue and red, Claude's orange.
    static let classic = Palette(.both, bg: p(0xF4F4F3, 0x161617), paper: p(0xFFFFFF, 0x1F1F21), ink: p(0x1C1C1E, 0xE9E9EA),
                                 muted: p(0x86868B, 0x8E8E93), line: p(0xBDBDC0, 0x4A4A4F), pick: p(0x007AFF, 0x0A84FF),
                                 running: p(0xD97757, 0xD97757), unread: p(0xFF3B30, 0xFF453A),
                                 faint: p(0xE3E3E1, 0x2E2E31), hover: p(0xECECEA, 0x262628))
    static let presets: [Preset] = [
        Preset(key: "classic", zh: "经典黑白", en: "Classic", palette: classic),
        // the icon's flower: yellow, blue and red on cream (a warm black in dark mode)
        Preset(key: "kiku", zh: "KIKU 花", en: "KIKU flower", palette: Palette(.both,
            bg: p(0xFDF4ED, 0x1A1918), paper: p(0xFFFDF9, 0x262422), ink: p(0x212120, 0xEDE9E3), muted: p(0x7E756C, 0xA39D94),
            line: p(0xD8CCBF, 0x4A4540), pick: p(0x187DFE, 0x4D9BFF), running: p(0xB98200, 0xFEC503), unread: p(0xE8392E, 0xFE453A))),
        // black, with the Bauhaus primaries: red, yellow, blue
        Preset(key: "bauhaus", zh: "包豪斯黑", en: "Bauhaus black", palette: Palette(.dark,
            bg: one(0x0D0D0D), paper: one(0x1A1A1A), ink: one(0xF2EDE4), muted: one(0x9C978F), line: one(0x474747),
            pick: one(0x3D6BFF), running: one(0xF7C600), unread: one(0xE8312A))),
        // old paper and ink, with teal, burnt orange and brick
        Preset(key: "retro", zh: "复古", en: "Retro", palette: Palette(.both,
            bg: p(0xEFE6D2, 0x211C17), paper: p(0xF8F1E3, 0x2B251E), ink: p(0x3B2F25, 0xEADFC8), muted: p(0x7A6A58, 0xA79883),
            line: p(0xC9B99C, 0x5A4E40), pick: p(0x2F7173, 0x5FA8A8), running: p(0xB5621F, 0xE39A4E), unread: p(0xB23A2E, 0xDE5E50))),
        // from Color Hunt (colorhunt.co): #222831 #393E46 #00ADB5 #EEEEEE
        Preset(key: "deepsea", zh: "深海", en: "Deep sea", palette: Palette(.dark,
            bg: one(0x222831), paper: one(0x2C323B), ink: one(0xEEEEEE), muted: one(0xA3A8AF), line: one(0x4F565F),
            pick: one(0x00ADB5), running: one(0xF2A65A), unread: one(0xFF6B6B))),
        // from Color Hunt: #08D9D6 #252A34 #FF2E63 #EAEAEA
        Preset(key: "neon", zh: "霓虹", en: "Neon", palette: Palette(.dark,
            bg: one(0x252A34), paper: one(0x2E3440), ink: one(0xEAEAEA), muted: one(0x9AA0AA), line: one(0x454C5A),
            pick: one(0x08D9D6), running: one(0xFFC93C), unread: one(0xFF2E63))),
        // from Color Hunt: #2D4059 #EA5455 #F07B3F #FFD460
        Preset(key: "sunset", zh: "日落", en: "Sunset", palette: Palette(.dark,
            bg: one(0x243349), paper: one(0x2D4059), ink: one(0xF5EFE6), muted: one(0xAAB5C5), line: one(0x46597A),
            pick: one(0xFFD460), running: one(0xF07B3F), unread: one(0xF05A5B))),
        // from Color Hunt: #364F6B #3FC1C9 #F5F5F5 #FC5185
        Preset(key: "candy", zh: "糖果", en: "Candy", palette: Palette(.light,
            bg: one(0xF5F5F5), paper: one(0xFFFFFF), ink: one(0x364F6B), muted: one(0x6E7F94), line: one(0xC9D1DB),
            pick: one(0x178E95), running: one(0xD9702B), unread: one(0xE83E75))),
    ]
    static func preset(_ key: String) -> Preset? { presets.first { $0.key == key } }

    // saved: the key ("classic", …, or "custom") and, for "custom", the colors themselves
    static func savedKey() -> String { UserDefaults.standard.string(forKey: "Palette") ?? "classic" }
    static func saved() -> Palette {
        let key = savedKey()
        if key == "custom", let d = UserDefaults.standard.data(forKey: "PaletteCustom"),
           let p = try? JSONDecoder().decode(Palette.self, from: d) { return p }
        return preset(key)?.palette ?? classic
    }
    static func save(_ p: Palette, key: String) {
        UserDefaults.standard.set(key, forKey: "Palette")
        if key == "custom", let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: "PaletteCustom") }
    }
    /// The custom set, in use or not: picking a preset keeps it, to go back to (nil: none made yet).
    static func savedCustom() -> Palette? {
        UserDefaults.standard.data(forKey: "PaletteCustom").flatMap { try? JSONDecoder().decode(Palette.self, from: $0) }
    }
    /// The preset a custom set was made from (to name it, and to go back to).
    static var customBase: String {
        get { UserDefaults.standard.string(forKey: "PaletteBase") ?? "classic" }
        set { UserDefaults.standard.set(newValue, forKey: "PaletteBase") }
    }
}
