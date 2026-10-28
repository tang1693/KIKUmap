import Cocoa

/// The mark: a little orange burst of short rays (a nod to Claude, not its logo). With `spin` the rays
/// fade in turn like a loading spinner — that's "running". Drawn in code so the app icon, menu bar,
/// header and intro all match.
enum Logo {
    static let orange = Theme.rgb(0xD97757)
    /// Long and short rays, a little uneven so it reads hand-drawn rather than mechanical.
    private static let rays: [CGFloat] = [1.0, 0.66, 0.92, 0.72, 0.97, 0.62, 0.9, 0.7, 0.95, 0.64, 0.88, 0.74]
    static var rayCount: Int { rays.count }

    private static func ease(_ t: CGFloat) -> CGFloat { let c = min(max(t, 0), 1); return c * c * (3 - 2 * c) }

    /// Draws the mark into `r`. `progress` 0…1 grows it in ray by ray; `spin` (any number, 1 = one turn)
    /// makes the rays fade in turn, clockwise.
    static func draw(in r: NSRect, color: NSColor = orange, progress: CGFloat = 1, spin: CGFloat = 0) {
        let s = min(r.width, r.height)
        let c = NSPoint(x: r.midX, y: r.midY)
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let lw = max(1.25, s * 0.072)
        let inner = s * 0.11, outer = s / 2 - lw / 2
        let n = rays.count
        var head = spin.truncatingRemainder(dividingBy: 1)
        if head < 0 { head += 1 }
        for (i, len) in rays.enumerated() {
            let t = ease((progress - 0.05 * CGFloat(i)) / 0.45)
            guard t > 0 else { continue }
            let a = (90 - 360 * CGFloat(i) / CGFloat(n)) * .pi / 180          // clockwise from the top
            let dx = cos(a), dy = flipped ? -sin(a) : sin(a)
            let r1 = inner + (outer - inner) * len * t
            var alpha: CGFloat = 1
            if spin != 0 {
                var behind = head - CGFloat(i) / CGFloat(n)
                if behind < 0 { behind += 1 }
                alpha = 1 - 0.75 * behind
            }
            let p = NSBezierPath()
            p.move(to: NSPoint(x: c.x + dx * inner, y: c.y + dy * inner))
            p.line(to: NSPoint(x: c.x + dx * r1, y: c.y + dy * r1))
            p.lineWidth = lw
            p.lineCapStyle = .round
            color.withAlphaComponent(alpha).setStroke()
            p.stroke()
        }
    }

    /// The app icon: graphite rounded square (macOS icon grid) with the mark.
    static func appIcon(_ px: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let S = CGFloat(px)
        let body = NSRect(x: S * 0.098, y: S * 0.098, width: S * 0.804, height: S * 0.804)
        let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
        // soft drop shadow
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
        sh.shadowBlurRadius = S * 0.02
        sh.shadowOffset = NSSize(width: 0, height: -S * 0.008)
        sh.set()
        Theme.rgb(0x1E1E20).setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: Theme.rgb(0x3C3C40), ending: Theme.rgb(0x18181A))?.draw(in: shape, angle: -90)
        // hairline edge
        let edge = NSBezierPath(roundedRect: body.insetBy(dx: S * 0.002, dy: S * 0.002),
                                xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
        edge.lineWidth = max(1, S * 0.003)
        NSColor.white.withAlphaComponent(0.10).setStroke(); edge.stroke()
        Logo.draw(in: body.insetBy(dx: body.width * 0.17, dy: body.width * 0.17))
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
