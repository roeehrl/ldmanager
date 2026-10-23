// The LD Manager disk-image window background: a light panel, the line
// "Drag LD Manager to Applications", and an arrow drawn the way the app icon draws a job:
// a dotted run line that starts at a status dot and lands on Applications.
//
//   swiftc -O packaging/dmg/DMGBackground.swift -o build/DMGBackground
//   build/DMGBackground <out-dir>   → background.png (1x) and background@2x.png
//
// The icons are real Finder icons placed by dmgbuild (settings.py), never drawn here.
// Finder draws their labels in black over a background picture, so the panel stays light
// in dark mode too. Keep the geometry in step with settings.py.
import AppKit

let W: CGFloat = 640, H: CGFloat = 420              // window, in points
let appCenter = CGPoint(x: 170, y: 212)             // icon centres, in points (y from top)
let appsCenter = CGPoint(x: 470, y: 212)

let blue: UInt32 = 0x296BF2, deep: UInt32 = 0x0D2E85
let green: UInt32 = 0x34C759, orange: UInt32 = 0xFF9E33

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

func render(scale: CGFloat, to url: URL) throws {
    let pw = Int(W * scale), ph = Int(H * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 32)!
    rep.size = NSSize(width: W, height: H)          // 72 dpi at 1x, 144 dpi at 2x
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: H); cg.scaleBy(x: 1, y: -1)   // y from the top, like Finder
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // A cool white panel with a faint blue glow behind the arrow, and a thin rule of the
    // icon's gradient along the top edge.
    cg.setFillColor(hex(0xF5F7FB)); cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let glow = CGGradient(colorsSpace: space, colors: [hex(blue, 0.10), hex(blue, 0)] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: 225), startRadius: 0,
                          endCenter: CGPoint(x: W / 2, y: 225), endRadius: 310, options: [])
    let rule = CGGradient(colorsSpace: space, colors: [hex(blue), hex(deep)] as CFArray, locations: [0, 1])!
    cg.saveGState(); cg.clip(to: CGRect(x: 0, y: 0, width: W, height: 4))
    cg.drawLinearGradient(rule, start: .zero, end: CGPoint(x: W, y: 0), options: [])
    cg.restoreGState()

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, y: CGFloat, accent: String? = nil) {
        let p = NSMutableParagraphStyle(); p.alignment = .center
        let a = NSMutableAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(cgColor: color)!,
            .paragraphStyle: p, .kern: -0.2])
        if let accent, let r = s.range(of: accent) {
            a.addAttribute(.foregroundColor, value: NSColor(cgColor: hex(blue))!, range: NSRange(r, in: s))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        a.draw(with: CGRect(x: 40, y: y, width: W - 80, height: size * 1.6), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }
    text("Drag LD Manager to Applications", size: 25, weight: .semibold, color: hex(0x16181D), y: 46, accent: "Applications")
    text("Then open it from Applications. The ldm command installs from Settings.", size: 13, weight: .regular,
         color: hex(0x6B7180), y: 356)

    // The arrow: a dotted run line arcing from a green status dot by the app to the folder,
    // the dots growing from pale to the full accent, with a rounded chevron at the end.
    let p0 = CGPoint(x: appCenter.x + 76, y: appCenter.y - 4)
    let p3 = CGPoint(x: appsCenter.x - 80, y: appsCenter.y - 4)
    let c1 = CGPoint(x: p0.x + 46, y: p0.y - 50), c2 = CGPoint(x: p3.x - 46, y: p3.y - 50)
    func bez(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p3.x,
                       y: u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p3.y)
    }
    // Status dot at the start: the job is running.
    cg.setFillColor(hex(green, 0.22)); cg.fillEllipse(in: CGRect(x: p0.x - 9, y: p0.y - 9, width: 18, height: 18))
    cg.setFillColor(hex(green)); cg.fillEllipse(in: CGRect(x: p0.x - 5, y: p0.y - 5, width: 10, height: 10))
    let dots = 13
    for i in 1..<dots {
        let t = CGFloat(i) / CGFloat(dots)
        let q = bez(t)
        let r = 1.6 + 1.4 * t
        cg.setFillColor(hex(blue, 0.35 + 0.65 * t))
        cg.fillEllipse(in: CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2))
    }
    let tip = bez(1), before = bez(0.96)
    let ang = atan2(tip.y - before.y, tip.x - before.x)
    cg.setStrokeColor(hex(blue)); cg.setLineWidth(3.8); cg.setLineCap(.round); cg.setLineJoin(.round)
    let back = ang + .pi
    cg.move(to: CGPoint(x: tip.x + cos(back + 0.6) * 15, y: tip.y + sin(back + 0.6) * 15))
    cg.addLine(to: tip)
    cg.addLine(to: CGPoint(x: tip.x + cos(back - 0.6) * 15, y: tip.y + sin(back - 0.6) * 15))
    cg.strokePath()

    NSGraphicsContext.current = nil
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try render(scale: 1, to: out.appendingPathComponent("background.png"))
try render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
print("wrote background.png and background@2x.png in \(out.path)")
