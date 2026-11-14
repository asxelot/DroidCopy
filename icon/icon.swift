// Draws DroidCopy's app icon and writes an .iconset folder for iconutil.
// swift icon/icon.swift <out.iconset>
import AppKit

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat(hex >> 16 & 0xff) / 255, CGFloat(hex >> 8 & 0xff) / 255,
                                           CGFloat(hex & 0xff) / 255, a])!
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// The design on a 1024-point canvas, in macOS's icon grid: an 824-point rounded square, centred.
func draw(_ ctx: CGContext) {
    // Flip so y grows downwards, which is easier to think in.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = rounded(tile, 185)

    // The tile, with the soft shadow macOS icons have.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1E9E6A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: srgb, colors: [color(0x3DDC84), color(0x0F8F6E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    // A faint sheen across the top half.
    let sheen = CGGradient(colorsSpace: srgb, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 520), options: [])
    ctx.restoreGState()

    // The device: a white handheld, upright.
    let body = CGRect(x: 322, y: 210, width: 380, height: 604)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x003B2A, 0.35))
    ctx.addPath(rounded(body, 64))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Its screen.
    let screen = body.insetBy(dx: 30, dy: 30)
    ctx.saveGState()
    ctx.addPath(rounded(screen, 38))
    ctx.clip()
    let scr = CGGradient(colorsSpace: srgb, colors: [color(0xE9FBF2), color(0xC7F0DC)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(scr, start: CGPoint(x: 0, y: screen.minY), end: CGPoint(x: 0, y: screen.maxY), options: [])
    ctx.restoreGState()

    // Two bold arrows, one down and one up: files going onto the device and coming off it.
    ctx.setFillColor(color(0x0F8F6E))
    func arrow(x: CGFloat, tipY: CGFloat, down: Bool) {
        let dir: CGFloat = down ? 1 : -1
        let head: CGFloat = 112, halfHead: CGFloat = 72, halfShaft: CGFloat = 26, length: CGFloat = 330
        let tail = tipY - dir * length
        let neck = tipY - dir * head
        let shaft = CGRect(x: x - halfShaft, y: min(tail, neck), width: halfShaft * 2, height: abs(neck - tail) + 4)
        ctx.addPath(rounded(shaft, 18))
        ctx.fillPath()
        ctx.move(to: CGPoint(x: x - halfHead, y: neck))
        ctx.addLine(to: CGPoint(x: x + halfHead, y: neck))
        ctx.addLine(to: CGPoint(x: x, y: tipY))
        ctx.closePath()
        ctx.fillPath()
    }
    arrow(x: screen.midX - 76, tipY: 650, down: true)
    arrow(x: screen.midX + 76, tipY: 374, down: false)
}

func render(_ pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
