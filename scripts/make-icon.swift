// Renders the app icon. Run: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = s / 1024

    // Squircle body on the standard macOS grid (824pt in a 1024 canvas).
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let path = CGPath(roundedRect: body, cornerWidth: 186 * k, cornerHeight: 186 * k, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(red: 0.07, green: 0.20, blue: 0.48, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 0.16, green: 0.42, blue: 0.95, alpha: 1).cgColor,
                                   NSColor(red: 0.05, green: 0.18, blue: 0.52, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 924 * k), end: CGPoint(x: 0, y: 100 * k), options: [])

    // Three stacked job rows, each with a status mark.
    let rowW = 560 * k, rowH = 132 * k, x = 232 * k
    let rows: [(CGFloat, NSColor, String)] = [
        (628, NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1), "dot"),
        (446, NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1), "dot"),
        (264, NSColor(red: 1.0, green: 0.62, blue: 0.20, alpha: 1), "tri"),
    ]
    for (y, color, mark) in rows {
        let r = CGRect(x: x, y: y * k, width: rowW, height: rowH)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 34 * k, cornerHeight: 34 * k, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.fillPath()
        let cx = x + 78 * k, cy = y * k + rowH / 2
        ctx.setFillColor(color.cgColor)
        if mark == "dot" {
            ctx.fillEllipse(in: CGRect(x: cx - 30 * k, y: cy - 30 * k, width: 60 * k, height: 60 * k))
        } else {
            ctx.move(to: CGPoint(x: cx, y: cy + 34 * k))
            ctx.addLine(to: CGPoint(x: cx + 36 * k, y: cy - 28 * k))
            ctx.addLine(to: CGPoint(x: cx - 36 * k, y: cy - 28 * k))
            ctx.closePath()
            ctx.fillPath()
        }
        // Label bar
        ctx.addPath(CGPath(roundedRect: CGRect(x: x + 150 * k, y: cy - 14 * k, width: 300 * k, height: 28 * k), cornerWidth: 14 * k, cornerHeight: 14 * k, transform: nil))
        ctx.setFillColor(NSColor(red: 0.07, green: 0.20, blue: 0.48, alpha: 0.35).cgColor)
        ctx.fillPath()
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: out.appendingPathComponent(name))
        images.append(#"{ "idiom" : "mac", "size" : "\#(pt)x\#(pt)", "scale" : "\#(scale)x", "filename" : "\#(name)" }"#)
    }
}
let json = "{ \"images\" : [\n  " + images.joined(separator: ",\n  ") + "\n], \"info\" : { \"author\" : \"xcode\", \"version\" : 1 } }\n"
try! json.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) icons to \(out.path)")
