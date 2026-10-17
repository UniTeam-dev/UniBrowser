import AppKit
// Regenerate: swift scripts/make_icon.swift <mac-1024.png> <ios-1024.png>, then resize into the asset catalogs.

// Draws the UniBrowser icon at 1024 px. "ios" = full-bleed square (iOS masks it),
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
        ctx.addPath(shape); ctx.setFillColor(color(0x2563C9)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [color(0x3B82F6), color(0x2563C9), color(0x5B3FD0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.minX + 260 * s, y: tile.maxY - 200 * s), startRadius: 0,
                           endCenter: CGPoint(x: tile.minX + 260 * s, y: tile.maxY - 200 * s), endRadius: 700 * s, options: [])

    // The browser window card.
    let card = r(196, 236, 632, 552)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * s), blur: 50 * s, color: color(0x0B1B4D, 0.45))
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 72 * s, cornerHeight: 72 * s, transform: nil))
    ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()

    // Space rail: a soft column with three space dots, the top one ringed (active).
    ctx.addPath(CGPath(roundedRect: r(232, 272, 120, 480), cornerWidth: 44 * s, cornerHeight: 44 * s, transform: nil))
    ctx.setFillColor(color(0xE8E8EC)); ctx.fillPath()
    let dots: [(UInt32, CGFloat)] = [(0x2563C9, 320), (0xE8833A, 436), (0x2E9E5B, 552)]
    for (i, (hex, y)) in dots.enumerated() {
        ctx.setFillColor(color(hex)); ctx.fillEllipse(in: r(260, y, 64, 64))
        if i == 0 { ctx.setStrokeColor(color(hex)); ctx.setLineWidth(9 * s); ctx.strokeEllipse(in: r(246, y - 14, 92, 92)) }
    }

    // Tab rows: the selected one is an accent pill, the rest grey bars.
    ctx.addPath(CGPath(roundedRect: r(384, 300, 408, 92), cornerWidth: 30 * s, cornerHeight: 30 * s, transform: nil))
    ctx.setFillColor(color(0x2563C9, 0.14)); ctx.fillPath()
    ctx.setFillColor(color(0x2563C9)); ctx.fillEllipse(in: r(408, 322, 48, 48))
    ctx.addPath(CGPath(roundedRect: r(476, 334, 252, 24), cornerWidth: 12 * s, cornerHeight: 12 * s, transform: nil))
    ctx.setFillColor(color(0x2563C9, 0.85)); ctx.fillPath()
    for (i, y) in [CGFloat(428), 528, 628].enumerated() {
        ctx.setFillColor(color(0xC7C7CF)); ctx.fillEllipse(in: r(408, y + 4, 44, 44))
        ctx.addPath(CGPath(roundedRect: r(476, y + 14, [228, 268, 188][i], 24), cornerWidth: 12 * s, cornerHeight: 12 * s, transform: nil))
        ctx.setFillColor(color(0xD9D9DF)); ctx.fillPath()
    }
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

draw(mac: true, to: CommandLine.arguments[1])
draw(mac: false, to: CommandLine.arguments[2])
