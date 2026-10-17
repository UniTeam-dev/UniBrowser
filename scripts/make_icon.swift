import AppKit
// Regenerate: swift scripts/make_icon.swift <mac-1024.png> <ios-1024.png>, then resize into the asset catalogs.

// Draws the UniBrowser icon (a "U" monogram) at 1024 px. "ios" = full-bleed square (iOS masks it),
// "mac" = squircle inset per macOS icon grid with a soft shadow.
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func draw(mac: Bool, to path: String) {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: (mac ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)! // iOS icons must be opaque
    let tile = mac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let s = tile.width / 1024 // scale of the artwork inside the tile
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { // top-left coords in 1024 artwork space
        CGRect(x: tile.minX + x * s, y: tile.maxY - (y + h) * s, width: w * s, height: h * s)
    }
    let shape = CGPath(roundedRect: tile, cornerWidth: mac ? 185 : 0, cornerHeight: mac ? 185 : 0, transform: nil)

    if mac { // drop shadow under the squircle
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
        ctx.addPath(shape); ctx.setFillColor(color(0x7B53FA)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [color(0x5B5BF5), color(0x9B4BFF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.minX + 260 * s, y: tile.maxY - 200 * s), startRadius: 0,
                           endCenter: CGPoint(x: tile.minX + 260 * s, y: tile.maxY - 200 * s), endRadius: 700 * s, options: [])

    // Monogram "U" with an orbit dot above its opening, plain white.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * s, y: tile.maxY - y * s) } // top-left coords
    let u = CGMutablePath()
    u.move(to: p(344, 288))
    u.addLine(to: p(344, 530))
    u.addArc(center: p(512, 530), radius: 168 * s, startAngle: .pi, endAngle: 0, clockwise: false)
    u.addLine(to: p(680, 288))
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 30 * s, color: color(0x1A0B4D, 0.30))
    ctx.addPath(u.copy(strokingWithWidth: 84 * s, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.addEllipse(in: CGRect(x: p(461, 0).x, y: p(0, 339).y, width: 102 * s, height: 102 * s))
    ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

draw(mac: true, to: CommandLine.arguments[1])
draw(mac: false, to: CommandLine.arguments[2])
