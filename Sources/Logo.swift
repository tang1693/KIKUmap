import Cocoa

/// The mark: a little flower of six petals in the icon's yellow, blue and red (kiku, 菊). With `spin` it turns, like
/// a loading spinner: that's "running". The app icon is the K that branches into three chats. Both are drawn in code,
/// so the app icon, menu bar, header and intro all match.
enum Logo {
    /// The interface's accent (running arcs, the timeline's "now").
    static let orange = Theme.rgb(0xD97757)

    // The icon's colours.
    static let cream = Theme.rgb(0xFDF4ED), ink = Theme.rgb(0x212120)
    static let yellow = Theme.rgb(0xFEC503), blue = Theme.rgb(0x187DFE), red = Theme.rgb(0xFE453A)
    /// The petals, clockwise from the top: yellow, blue, red, and round again.
    static let petals: [NSColor] = [yellow, blue, red]

    private static func ease(_ t: CGFloat) -> CGFloat { let c = min(max(t, 0), 1); return c * c * (3 - 2 * c) }

    /// Draws the flower into `r`. `color` draws it in one colour (for small marks next to text); without, the petals
    /// take the icon's colours. `progress` 0…1 grows it in petal by petal; `spin` (any number, 1 = one turn) turns it
    /// clockwise.
    static func draw(in r: NSRect, color: NSColor? = nil, progress: CGFloat = 1, spin: CGFloat = 0) {
        // the flower's own units: petals 8.6 × 12.6 from 6.4 to 31.6 off the centre
        let s = min(r.width, r.height) / 63.2
        let c = NSPoint(x: r.midX, y: r.midY)
        let up: CGFloat = (NSGraphicsContext.current?.isFlipped ?? false) ? -1 : 1
        for i in 0..<6 {
            let t = ease((progress - 0.08 * CGFloat(i)) / 0.5)
            guard t > 0 else { continue }
            let rx = 8.6 * s * t, ry = 12.6 * s * t, d = 6.4 * s + ry
            let petal = NSBezierPath(ovalIn: NSRect(x: -rx, y: up * d - ry, width: 2 * rx, height: 2 * ry))
            var at = AffineTransform(translationByX: c.x, byY: c.y)
            at.rotate(byDegrees: -up * 360 * (CGFloat(i) / 6 + spin))      // clockwise on screen
            petal.transform(using: at)
            (color ?? petals[i % 3]).setFill()
            petal.fill()
        }
    }

    // MARK: the app icon

    // The K and its three chats, in the master artwork's units (its tile is 519 wide, from 2, 2; y runs down).
    private static let chats: [(String, NSColor)] = [
        ("M 337 104 L 384 104 C 410.51 104 432 125.49 432 152 L 432 155 C 432 181.51 410.51 203 384 203 L 318 203 C 307 203 300 205 295 209 C 297 201 297 192 296 184 C 292 176 289 166 289 152 C 289 125.49 310.49 104 337 104 Z", yellow),
        ("M 340 222 L 389 222 C 417.17 222 440 244.83 440 273 C 440 301.17 417.17 324 389 324 L 340 324 C 318.42 323.96 299.19 310.35 292 290 C 286 283 279 280 270 279.5 L 270 267.5 C 279 267 286 263 292 256 C 299.19 235.65 318.42 222.04 340 222 Z", blue),
        ("M 340 343 L 391 343 C 418.06 343 440 364.94 440 392 C 440 419.06 418.06 441 391 441 L 318 441 C 307 441 300 444 294 451 C 296 442 296 432 295 418 C 292 410 291 401 291 392 C 291 364.94 312.94 343 340 343 Z", red),
    ]
    private static let branches = ["M 186 267 C 232 267 238 159 292 159", "M 186 273.5 L 274 273.5", "M 186 280 C 232 280 240 391 294 391"]
    private static let dots: [(CGFloat, CGFloat)] = [(333, 152.5), (361, 152.5), (389, 152.5), (339, 273.5), (367, 273.5),
                                                     (395, 273.5), (337, 392), (365, 392), (393, 392)]

    /// "M x y L x y C x1 y1 x2 y2 x y Z", in the artwork's units, as a path through `pt`.
    private static func artPath(_ d: String, _ pt: (CGFloat, CGFloat) -> NSPoint) -> NSBezierPath {
        let p = NSBezierPath()
        let words = d.split(separator: " ")
        var i = 0
        func n() -> CGFloat { defer { i += 1 }; return i < words.count ? CGFloat(Double(words[i]) ?? 0) : 0 }
        while i < words.count {
            let w = words[i]; i += 1
            switch w {
            case "M": let a = n(), b = n(); p.move(to: pt(a, b))
            case "L": let a = n(), b = n(); p.line(to: pt(a, b))
            case "C":
                let x1 = n(), y1 = n(), x2 = n(), y2 = n(), x = n(), y = n()
                p.curve(to: pt(x, y), controlPoint1: pt(x1, y1), controlPoint2: pt(x2, y2))
            case "Z": p.close()
            default: break
            }
        }
        return p
    }

    /// The artwork inside the icon's tile. `detail` 2 is everything; 1 drops the dots (64 px); 0 also the corners (16–32 px).
    private static func drawIconArt(in body: NSRect, detail: Int) {
        let k = body.width / 519
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: body.minX + (x - 2) * k, y: body.maxY - (y - 2) * k) }
        func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: NSColor) {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: body.minX + (x - 2 - r) * k, y: body.maxY - (y - 2 + r) * k,
                                        width: 2 * r * k, height: 2 * r * k)).fill()
        }
        if detail >= 1 {
            disc(460.6, -100.2, 238.5, yellow)
            disc(18.4, 645, 246.4, blue)
            for (d, _) in chats {                       // a cream rim where a chat meets a corner
                let p = artPath(d, pt)
                p.lineWidth = 22 * k; p.lineJoinStyle = .round
                cream.setStroke(); p.stroke()
            }
        }
        ink.setStroke()
        for d in branches {
            let p = artPath(d, pt)
            p.lineWidth = (detail >= 2 ? 12 : detail == 1 ? 18 : 20) * k
            p.stroke()
        }
        ink.setFill()
        NSBezierPath(rect: NSRect(x: body.minX + 100 * k, y: body.maxY - 382 * k, width: 86 * k, height: 207 * k)).fill()
        for (d, c) in chats { c.setFill(); artPath(d, pt).fill() }
        if detail >= 2 { for (x, y) in dots { disc(x, y, 8, .white) } }
    }

    /// The app icon: the K and its chats on a cream rounded square (macOS icon grid).
    static func appIcon(_ px: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let S = CGFloat(px)
        let body = NSRect(x: S * 0.098, y: S * 0.098, width: S * 0.804, height: S * 0.804)
        let radius = body.width * 0.2237
        let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        // soft drop shadow
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = Theme.rgb(0x3A2A1A).withAlphaComponent(0.26)
        sh.shadowBlurRadius = S * 0.02
        sh.shadowOffset = NSSize(width: 0, height: -S * 0.009)
        sh.set()
        cream.setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        drawIconArt(in: body, detail: px >= 128 ? 2 : px >= 64 ? 1 : 0)
        NSGraphicsContext.restoreGraphicsState()
        // hairline edge
        let edge = NSBezierPath(roundedRect: body.insetBy(dx: S * 0.002, dy: S * 0.002), xRadius: radius, yRadius: radius)
        edge.lineWidth = max(1, S * 0.003)
        NSColor.black.withAlphaComponent(0.06).setStroke(); edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// `ClaudeConsole --make-icns <file>` writes the app icon as an .icns (PNG entries), so building
    /// needs no iconutil.
    static func writeICNS(to path: String) {
        let entries: [(String, Int)] = [("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
                                        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
        func be(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) } }
        var body = Data()
        for (type, px) in entries {
            guard let png = appIcon(px)?.representation(using: .png, properties: [:]) else { continue }
            body.append(Data(type.utf8)); body.append(be(png.count + 8)); body.append(png)
        }
        var out = Data("icns".utf8)
        out.append(be(body.count + 8)); out.append(body)
        try? out.write(to: URL(fileURLWithPath: path))
    }

    /// `ClaudeConsole --make-icon <dir>` writes an .iconset.
    static func writeIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                if let png = appIcon(base * scale)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
            }
        }
    }
}
