// make-icon.swift. Draws the Stats app icon (a graphite metal tile holding a chip with a pulse line) into an .iconset folder.
// usage: mkicon <out-dir>
import AppKit

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }

// Graphite metal: tile top, middle and bottom, the glow, and the shade under the chip.
let top = rgb(0x8A8E99), mid = rgb(0x3A3D45), bottom = rgb(0x121317), glow = rgb(0xE6E8EE), shade = rgb(0x050506)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor], _ stops: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: stops)!
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
/// Fills `path` softly blurred. The sharp shape is drawn far to the right, off the icon, and only its shadow lands in place.
func blurred(_ c: CGContext, _ path: CGPath, _ color: CGColor, sigma: CGFloat, unit: CGFloat) {
    let away: CGFloat = 400
    c.saveGState()
    c.setShadow(offset: CGSize(width: -away * unit, height: 0), blur: sigma * 2 * unit, color: color)
    c.translateBy(x: away, y: 0)
    c.addPath(path); c.setFillColor(gray: 0, alpha: 1); c.fillPath()
    c.restoreGState()
}
func clipped(_ c: CGContext, _ path: CGPath, _ body: () -> Void) {
    c.saveGState(); c.addPath(path); c.clip(); body(); c.restoreGState()
}

func draw(px: Int) -> CGImage? {
    let s = CGFloat(px)
    guard let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    // Apple's icon grid: the tile is 824 of 1024 wide, centred. Everything below is drawn in a 100-unit box with y pointing down.
    let side = s * 824 / 1024, unit = side / 100, inset = (s - side) / 2
    c.translateBy(x: inset, y: s - inset)
    c.scaleBy(x: unit, y: -unit)

    let tile = rounded(0, 0, 100, 100, 22)
    c.saveGState()   // soft drop shadow under the tile, like other Mac icons
    c.setShadow(offset: CGSize(width: 0, height: -1.2 * unit), blur: 3 * unit, color: CGColor(gray: 0, alpha: 0.3))
    c.addPath(tile); c.setFillColor(bottom); c.fillPath()
    c.restoreGState()
    clipped(c, tile) {
        c.drawLinearGradient(gradient([top, mid, bottom], [0, 0.55, 1]), start: CGPoint(x: 50, y: 0), end: CGPoint(x: 50, y: 100), options: [])
        clipped(c, CGPath(ellipseIn: CGRect(x: -12, y: -26, width: 124, height: 68), transform: nil)) {   // gloss across the top
            c.translateBy(x: 50, y: -19.2); c.scaleBy(x: 1, y: 68.0 / 124)
            c.drawRadialGradient(gradient([white(0.38), white(0)], [0, 1]), startCenter: .zero, startRadius: 0,
                                 endCenter: .zero, endRadius: 111.6, options: [])
        }
        blurred(c, CGPath(ellipseIn: CGRect(x: 0, y: 82, width: 100, height: 44), transform: nil),   // glow rising from the bottom edge
                glow.copy(alpha: 0.28)!, sigma: 3, unit: unit)
    }
    clipped(c, rounded(1, 1, 98, 98, 21).copy(strokingWithWidth: 1.6, lineCap: .butt, lineJoin: .miter, miterLimit: 10)) {   // glass rim
        c.drawLinearGradient(gradient([white(0.85), white(0.05), white(0.35)], [0, 0.45, 1]),
                             start: CGPoint(x: 50, y: 0), end: CGPoint(x: 50, y: 100), options: [])
    }

    blurred(c, rounded(26, 29, 52, 52, 14), shade.copy(alpha: 0.45)!, sigma: 2.2, unit: unit)   // chip casts a shadow
    c.setFillColor(white(0.9))   // two pins on each side
    for p in [36.5, 58.5] as [CGFloat] {
        c.addPath(rounded(p, 13, 5, 11, 2.5)); c.addPath(rounded(p, 76, 5, 11, 2.5))
        c.addPath(rounded(13, p, 11, 5, 2.5)); c.addPath(rounded(76, p, 11, 5, 2.5))
    }
    c.fillPath()
    let chip = rounded(24, 24, 52, 52, 14)
    clipped(c, chip) {
        c.drawLinearGradient(gradient([white(0.34), white(0.06)], [0, 1]), start: CGPoint(x: 50, y: 24), end: CGPoint(x: 50, y: 76), options: [])
    }
    clipped(c, chip.copy(strokingWithWidth: 2.2, lineCap: .butt, lineJoin: .miter, miterLimit: 10)) {
        c.drawLinearGradient(gradient([white(0.95), white(0.25), white(0.6)], [0, 0.5, 1]),
                             start: CGPoint(x: 24, y: 24), end: CGPoint(x: 76, y: 76), options: [])
    }

    let pulse = CGMutablePath()   // heartbeat line across the chip, with a soft glow behind it
    pulse.addLines(between: [CGPoint(x: 32, y: 51), CGPoint(x: 42, y: 51), CGPoint(x: 47.5, y: 37),
                             CGPoint(x: 54.5, y: 64), CGPoint(x: 59.5, y: 51), CGPoint(x: 68, y: 51)])
    blurred(c, pulse.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 10),
            glow.copy(alpha: 0.7)!, sigma: 2.2, unit: unit)
    c.addPath(pulse); c.setStrokeColor(white(1)); c.setLineWidth(3.8)
    c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
    return c.makeImage()
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Stats.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    guard let img = draw(px: px), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("could not draw \(name)\n".data(using: .utf8)!); exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
