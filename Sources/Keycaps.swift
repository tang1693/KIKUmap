import Cocoa

/// One piece of a shortcut as it's shown: a chord of keys ("⌥⇥", "⇧⌘Z", "F2", "Space"), a word between chords
/// ("or", "then"), or a mouse / trackpad action, drawn as a pill so it never looks like a key.
enum KeyPart: Equatable {
    case keys(String)
    case word(String)
    case chip(String, symbol: String?)
}

/// Shortcuts drawn as keycaps: one cap per key, ⌥ and ⇥ apart as on the keyboard. The modifier, arrow, tab, return
/// and delete keys are SF Symbols: SF Pro has no ⇥ ↩ ⌤ glyphs (they fall back to other fonts), and a monospaced font
/// squeezes ⌘ ⌥ ⇧ into narrow cells. Drawn for flipped views (y grows downwards), as every view here is.
enum Keycaps {
    struct Size {
        let height, minWidth, radius, lip, gap, symbol, text, pad: CGFloat
        /// In a list of shortcuts.
        static let list = Size(height: 20, minWidth: 20, radius: 5, lip: 1.5, gap: 3, symbol: 11, text: 12, pad: 6)
        /// Shown large, as the key being pressed in a demo.
        static let large = Size(height: 26, minWidth: 26, radius: 6.5, lip: 2, gap: 4, symbol: 13.5, text: 14, pad: 8)
    }

    // raised on the Settings background and on the map's, in light and dark (and with Increase Contrast)
    static let capFill = Theme.dyn(0xFFFFFF, 0x3A3A3D)
    static let capEdge = Theme.dyn(0xC7C7CA, 0x56565B, more: (0x7C7C82, 0x8E8E93))
    static let capLip = Theme.dyn(0xAEAEB2, 0x0E0E0F, more: (0x6E6E73, 0x000000))

    private static let symbols: [Character: String] = [
        "⌘": "command", "⌥": "option", "⌃": "control", "⇧": "shift", "⇥": "arrow.right.to.line",
        "⏎": "return", "↩": "return", "⌫": "delete.left", "⌦": "delete.right",
        "↑": "arrow.up", "↓": "arrow.down", "←": "arrow.left", "→": "arrow.right",
    ]

    /// A chord's keys: each modifier, arrow or editing key on its own, the rest as one key
    /// ("⇧⌘Z" → ⇧ ⌘ Z, "⌥." → ⌥ ., "F2" → F2).
    static func keys(_ chord: String) -> [String] {
        var out: [String] = [], rest = ""
        for ch in chord {
            if symbols[ch] != nil {
                if !rest.isEmpty { out.append(rest); rest = "" }
                out.append(String(ch))
            } else if ch == " " {
                if !rest.isEmpty { out.append(rest); rest = "" }
            } else {
                rest.append(ch)
            }
        }
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    private static var symbolCache: [String: NSImage] = [:]
    private static func symbol(_ name: String, _ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
        let k = "\(name)|\(size)|\(weight.rawValue)"
        if let i = symbolCache[k] { return i }
        let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
        symbolCache[k] = i
        return i
    }

    /// A symbol in `color` (tinted when drawn: colours follow light / dark, so they're never cached).
    static func drawSymbol(_ img: NSImage, centredIn r: NSRect, _ color: NSColor, alpha: CGFloat = 1) {
        let s = img.size
        let tinted = NSImage(size: s, flipped: false) { rr in img.draw(in: rr); color.set(); rr.fill(using: .sourceAtop); return true }
        tinted.draw(in: NSRect(x: (r.midX - s.width / 2).rounded(), y: (r.midY - s.height / 2).rounded(), width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    private static func textFont(_ key: String, _ s: Size) -> NSFont {
        // punctuation a point larger and bold, or it all but vanishes on a cap
        key.count == 1 && key.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.union(.symbols).contains($0) })
            ? Theme.ui(s.text + 1, .bold) : Theme.ui(key.count > 2 ? s.text - 1 : s.text, .semibold)
    }

    /// One key's cap width.
    static func capWidth(_ key: String, _ s: Size) -> CGFloat {
        if let ch = key.first, key.count == 1, let name = symbols[ch], let img = symbol(name, s.symbol) {
            return max(s.minWidth, ceil(img.size.width) + s.pad)
        }
        let w = ceil(key.size(withAttributes: [.font: textFont(key, s)]).width) + 2 * s.pad
        return max(s.minWidth, key.count > 3 ? max(w, s.minWidth * 2.2) : w)
    }

    private static func wordFont(_ s: Size) -> NSFont { Theme.ui(s.text - 1) }
    private static func chipFont(_ s: Size) -> NSFont { Theme.ui(s.text - 1, .medium) }

    /// How wide the parts are, drawn in a row.
    static func width(_ parts: [KeyPart], _ s: Size) -> CGFloat {
        var w: CGFloat = 0
        for (i, p) in parts.enumerated() {
            if i > 0 { w += s.gap + 3 }
            switch p {
            case .keys(let c):
                let ks = keys(c)
                w += ks.reduce(0) { $0 + capWidth($1, s) } + CGFloat(max(0, ks.count - 1)) * s.gap
            case .word(let t): w += ceil(t.size(withAttributes: [.font: wordFont(s)]).width)
            case .chip(let t, let sym):
                w += ceil(t.size(withAttributes: [.font: chipFont(s)]).width) + 2 * s.pad + (sym == nil ? 0 : s.symbol + 4)
            }
        }
        return ceil(w)
    }

    /// Which of `parts`' keys are down when `pressed` goes down (by key, per chord): a chord lights whole when all its
    /// keys are down; in an arrow cluster (↑↓←→) only the arrows down light; gestures light when the same one is done.
    static func litKeys(_ parts: [KeyPart], pressed: [KeyPart]) -> [Int: Set<String>] {
        var down = Set<String>(), chips = Set<String>()
        for p in pressed {
            if case .keys(let c) = p { down.formUnion(keys(c)) }
            if case .chip(let t, _) = p { chips.insert(t) }
        }
        var out: [Int: Set<String>] = [:]
        for (i, p) in parts.enumerated() {
            switch p {
            case .keys(let c):
                let ks = keys(c)
                if Set(ks).isSubset(of: down) { out[i] = Set(ks) }
                else if ks.allSatisfy({ "↑↓←→".contains($0) }) { out[i] = Set(ks).intersection(down) }
            case .chip(let t, _): if chips.contains(t) { out[i] = [t] }
            default: break
            }
        }
        return out
    }

    /// Draws the parts left to right from `origin` (their top left). `lit`: every key shown pressed; `litOnly`: just
    /// these keys (by part), as `litKeys` works them out.
    static func draw(_ parts: [KeyPart], at origin: NSPoint, _ s: Size, lit: Bool = false, litOnly: [Int: Set<String>]? = nil, alpha: CGFloat = 1) {
        var x = origin.x
        let top = origin.y
        for (i, p) in parts.enumerated() {
            if i > 0 { x += s.gap + 3 }
            switch p {
            case .keys(let c):
                for (j, k) in keys(c).enumerated() {
                    if j > 0 { x += s.gap }
                    let w = capWidth(k, s)
                    let on = lit || (litOnly?[i]?.contains(k) ?? false)
                    drawCap(k, in: NSRect(x: x, y: top, width: w, height: s.height - s.lip), s, lit: on, alpha: alpha)
                    x += w
                }
            case .word(let t):
                let f = wordFont(s)
                let h = t.size(withAttributes: [.font: f]).height
                (t as NSString).draw(at: NSPoint(x: x, y: top + (s.height - s.lip - h) / 2),
                                     withAttributes: [.font: f, .foregroundColor: Theme.muted.withAlphaComponent(alpha)])
                x += ceil(t.size(withAttributes: [.font: f]).width)
            case .chip(let t, let sym):
                let f = chipFont(s)
                let tw = ceil(t.size(withAttributes: [.font: f]).width)
                let w = tw + 2 * s.pad + (sym == nil ? 0 : s.symbol + 4)
                let r = NSRect(x: x, y: top, width: w, height: s.height - s.lip)
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
                let chipOn = lit || litOnly?[i] != nil
                (chipOn ? Theme.ink.withAlphaComponent(0.14 * alpha) : capFill.withAlphaComponent(alpha)).setFill(); p.fill()
                capEdge.withAlphaComponent(alpha).setStroke(); p.lineWidth = 1; p.stroke()
                var tx = r.minX + s.pad
                if let name = sym, let img = symbol(name, s.symbol - 1.5, weight: .medium) {
                    drawSymbol(img, centredIn: NSRect(x: tx, y: r.minY, width: s.symbol, height: r.height), Theme.muted, alpha: alpha)
                    tx += s.symbol + 4
                }
                let h = t.size(withAttributes: [.font: f]).height
                (t as NSString).draw(at: NSPoint(x: tx, y: r.midY - h / 2), withAttributes: [.font: f, .foregroundColor: Theme.ink.withAlphaComponent(alpha)])
                x += w
            }
        }
    }

    /// One cap: a lip under it (raised), then the cap; pressed, it sits down on its lip and inverts.
    static func drawCap(_ key: String, in rect: NSRect, _ s: Size, lit: Bool, alpha: CGFloat = 1) {
        var r = rect
        if lit {
            r = r.offsetBy(dx: 0, dy: s.lip)
            Theme.ink.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: r, xRadius: s.radius, yRadius: s.radius).fill()
        } else {
            capLip.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: s.lip), xRadius: s.radius, yRadius: s.radius).fill()
            let cap = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: s.radius - 0.5, yRadius: s.radius - 0.5)
            capFill.withAlphaComponent(alpha).setFill(); cap.fill()
            capEdge.withAlphaComponent(alpha).setStroke(); cap.lineWidth = 1; cap.stroke()
        }
        let ink = (lit ? Theme.paper : Theme.ink)
        if let ch = key.first, key.count == 1, let name = symbols[ch], let img = symbol(name, s.symbol) {
            drawSymbol(img, centredIn: r, ink, alpha: alpha)
        } else {
            let f = textFont(key, s)
            let sz = key.size(withAttributes: [.font: f])
            (key as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2),
                                   withAttributes: [.font: f, .foregroundColor: ink.withAlphaComponent(alpha)])
        }
    }

    /// What VoiceOver reads for the parts ("Option Tab or Command Return").
    static func spoken(_ parts: [KeyPart]) -> String {
        let names: [Character: String] = [
            "⌘": tr("Command", "Command"), "⌥": tr("Option", "Option"), "⌃": tr("Control", "Control"), "⇧": tr("Shift", "Shift"),
            "⇥": tr("Tab", "Tab"), "⏎": tr("回车", "Return"), "↩": tr("回车", "Return"), "⌫": tr("删除", "Delete"),
            "⌦": tr("向前删除", "Forward Delete"), "↑": tr("上", "Up"), "↓": tr("下", "Down"), "←": tr("左", "Left"), "→": tr("右", "Right"),
            // punctuation keys by name: a screen reader would only pause on them
            ".": tr("句号", "Period"), ",": tr("逗号", "Comma"), "+": tr("加号", "Plus"), "-": tr("减号", "Minus"), "=": tr("等号", "Equals"),
            "/": tr("斜杠", "Slash"), ";": tr("分号", "Semicolon"), "`": tr("反引号", "Backtick"),
        ]
        return parts.map { p -> String in
            switch p {
            case .keys(let c): return keys(c).map { k in k.count == 1 ? (names[k.first!] ?? k) : k }.joined(separator: " ")
            case .word(let t): return t == "·" ? tr("，", ",") : t
            case .chip(let t, _): return t
            }
        }.joined(separator: " ")
    }
}
