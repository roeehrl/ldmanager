// Renders a caption pill (white text on a translucent dark pill) as a transparent PNG.
//   swift demo/caption.swift "Fixed." out.png [width]
import AppKit

let args = CommandLine.arguments
let text = args[1], out = args[2]
let width = args.count > 3 ? CGFloat(Double(args[3]) ?? 1600) : 1600
let font = NSFont.systemFont(ofSize: width / 32, weight: .semibold)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
let size = (text as NSString).size(withAttributes: attrs)
let padX = font.pointSize * 0.9, padY = font.pointSize * 0.45
let pill = NSSize(width: ceil(size.width + 2 * padX), height: ceil(size.height + 2 * padY))
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pill.width), pixelsHigh: Int(pill.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.08, alpha: 0.82).setFill()
NSBezierPath(roundedRect: NSRect(origin: .zero, size: pill), xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
(text as NSString).draw(at: NSPoint(x: padX, y: padY), withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
