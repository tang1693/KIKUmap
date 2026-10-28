// Draws the disk-image window's background: Kikumap on the left, an arrow, Applications on the right.
// Usage: swift scripts/dmg-background.swift <out.tiff>   → one TIFF holding the 1× and 2× (Retina) pictures,
// which Finder picks between by itself.
// Positions match scripts/dmg-layout.py (icons centred at x 140 and 420, y 165 from the top).
import Cocoa

let W: CGFloat = 560, H: CGFloat = 380
let ink = NSColor(srgbRed: 0x1F / 255, green: 0x1E / 255, blue: 0x1D / 255, alpha: 1)
let ink2 = NSColor(srgbRed: 0x6B / 255, green: 0x65 / 255, blue: 0x5D / 255, alpha: 1)
let orange = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)

func y(_ fromTop: CGFloat) -> CGFloat { H - fromTop }

func centred(_ s: String, _ font: NSFont, _ color: NSColor, top: CGFloat) {
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    let size = a.size()
    a.draw(at: NSPoint(x: (W - size.width) / 2, y: y(top) - size.height))
}

func draw() {
    NSGradient(starting: NSColor(srgbRed: 0xFB / 255, green: 0xF8 / 255, blue: 0xF3 / 255, alpha: 1),
               ending: NSColor(srgbRed: 0xEE / 255, green: 0xE5 / 255, blue: 0xD7 / 255, alpha: 1))!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    centred("Drag Kikumap into Applications", .systemFont(ofSize: 17, weight: .semibold), ink, top: 30)
    centred("把 Kikumap 拖进「应用程序」", .systemFont(ofSize: 13), ink2, top: 56)

    // the arrow, between the two icons (their edges are at x 204 and 356)
    let cy = y(165)
    let a = NSBezierPath()
    a.move(to: NSPoint(x: 228, y: cy))
    a.curve(to: NSPoint(x: 326, y: cy), controlPoint1: NSPoint(x: 258, y: cy + 22), controlPoint2: NSPoint(x: 296, y: cy + 22))
    a.lineWidth = 4
    a.lineCapStyle = .round
    a.setLineDash([2, 9], count: 2, phase: 0)
    orange.setStroke()
    a.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 318, y: cy + 12))
    head.line(to: NSPoint(x: 332, y: cy - 2))
    head.line(to: NSPoint(x: 314, y: cy - 6))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    centred("First launch: System Settings → Privacy & Security → Open Anyway",
            .systemFont(ofSize: 11.5), ink2, top: 290)
    centred("第一次打开：系统设置 → 隐私与安全性 → 仍要打开", .systemFont(ofSize: 11.5), ink2, top: 309)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.tiff"
let reps = [1, 2].map { scale -> NSBitmapImageRep in
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
try! NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .lzw, factor: 0)!.write(to: URL(fileURLWithPath: out))
