// Draws the disk image window's background: an arrow from the app to Applications.
// swift dmg/background.swift <out.png> <scale>
import AppKit

let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
// Matches window_rect in dmg/settings.py. Finder's title bar and status bar cover about 50 points
// of that, at the top and bottom, so nothing important goes in the bottom 60.
let size = CGSize(width: 600, height: 400)

let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: scale, y: scale)
// Work in window coordinates (origin top left), as the icon positions in settings.py are.
ctx.translateBy(x: 0, y: size.height)
ctx.scaleBy(x: 1, y: -1)

let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
                                   CGColor(srgbRed: 0.91, green: 0.93, blue: 0.96, alpha: 1)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

// The arrow, between the two icons (centred at x 150 and 450, y 150).
let arrow = CGColor(srgbRed: 0.55, green: 0.60, blue: 0.68, alpha: 1)
ctx.setStrokeColor(arrow)
ctx.setFillColor(arrow)
ctx.setLineWidth(6)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 245, y: 150))
ctx.addLine(to: CGPoint(x: 335, y: 150))
ctx.strokePath()
ctx.move(to: CGPoint(x: 357, y: 150))
ctx.addLine(to: CGPoint(x: 331, y: 132))
ctx.addLine(to: CGPoint(x: 331, y: 168))
ctx.closePath()
ctx.fillPath()

// The caption, drawn right side up.
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
let style = NSMutableParagraphStyle()
style.alignment = .center
let caption = NSAttributedString(string: "Drag DroidCopy to Applications to install it", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.33, green: 0.37, blue: 0.43, alpha: 1),
    .paragraphStyle: style,
])
caption.draw(in: CGRect(x: 0, y: 268, width: size.width, height: 24))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
rep.size = size  // so the @2x file is marked 144 dpi
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
