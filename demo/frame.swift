// Crops a capture to the window (dropping the wallpaper margin) and rounds its corners into a
// transparent PNG, scaled to the given width.
//   swift demo/frame.swift in.png out.png <margin px> <corner radius px> [width]
import AppKit

let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let m = Int(a[3])!, r = CGFloat(Double(a[4])!)
let crop = src.cropping(to: CGRect(x: m, y: m, width: src.width - 2 * m, height: src.height - 2 * m))!
let w = a.count > 5 ? Int(a[5])! : crop.width
let h = Int((Double(crop.height) * Double(w) / Double(crop.width)).rounded())
let scale = CGFloat(w) / CGFloat(crop.width)
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let rect = CGRect(x: 0, y: 0, width: w, height: h)
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r * scale, cornerHeight: r * scale, transform: nil))
ctx.clip()
ctx.draw(crop, in: rect)
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
