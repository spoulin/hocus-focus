// Draws the app icon as a 1024 px PNG.
// Usage: swift Icon/make-icon.swift <output.png>
//
// Two windows, one in front of the other. The one behind has the focus: a golden glow
// around it and a text caret in it, while it stays behind. The mouse cursor rests on it,
// with a few sparkles (hocus pocus).
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// Draw with a top-left origin.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// MARK: - Helpers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func sparkle(_ c: CGPoint, _ r: CGFloat, alpha: CGFloat = 1) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x, y: c.y - r))
    path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
    path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r * 0.6, color: color(0xFFB000, 0.8))
    ctx.addPath(path)
    ctx.setFillColor(color(0xFFC21A, alpha))
    ctx.fillPath()
    ctx.restoreGState()
}

/// A light macOS window: title bar with traffic lights, and content lines.
func drawWindow(_ window: CGRect, lines: [(CGFloat, CGFloat)], body: UInt32, bar: UInt32, ink: UInt32) {
    let radius: CGFloat = 34
    let titleHeight: CGFloat = 64
    let path = roundedRect(window, radius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: color(0x000000, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(color(body))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setFillColor(color(bar))
    ctx.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: titleHeight))
    ctx.restoreGState()

    let dot: CGFloat = 24
    for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        let cx = window.minX + 44 + CGFloat(i) * dot * 1.6
        ctx.setFillColor(color(hex))
        ctx.fillEllipse(in: CGRect(x: cx - dot / 2, y: window.minY + titleHeight / 2 - dot / 2, width: dot, height: dot))
    }

    ctx.setFillColor(color(ink))
    for (y, width) in lines {
        ctx.addPath(roundedRect(CGRect(x: window.minX + 44, y: window.minY + y, width: width, height: 22), 11))
        ctx.fillPath()
    }
}

// MARK: - Background

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = roundedRect(tile, 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x1B1E66))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.drawLinearGradient(
    gradient([color(0x4B55E0), color(0x2A2F9E), color(0x151859)], [0, 0.55, 1]),
    start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)
// A soft light behind the focused window.
ctx.drawRadialGradient(
    gradient([color(0xFFD86B, 0.35), color(0xFFD86B, 0)], [0, 1]),
    startCenter: CGPoint(x: 600, y: 600), startRadius: 0,
    endCenter: CGPoint(x: 600, y: 600), endRadius: 420, options: []
)

// MARK: - The focused window, behind

let back = CGRect(x: 330, y: 360, width: 500, height: 420)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 46, color: color(0xFFC83D, 0.95))
ctx.addPath(roundedRect(back.insetBy(dx: -10, dy: -10), 44))
ctx.setStrokeColor(color(0xFFD45C))
ctx.setLineWidth(16)
ctx.strokePath()
ctx.restoreGState()
drawWindow(back, lines: [(150, 300), (204, 360), (258, 250)], body: 0xFFFFFF, bar: 0xECEAF7, ink: 0xC9C6E4)
// The text caret: typing goes to this window.
ctx.setFillColor(color(0xFF9F1C))
ctx.fill(CGRect(x: back.minX + 44 + 250 + 14, y: back.minY + 246, width: 12, height: 46))

// MARK: - The other window, in front

let front = CGRect(x: 180, y: 220, width: 420, height: 330)
drawWindow(front, lines: [(128, 280), (182, 220), (236, 300)], body: 0xDCDDF0, bar: 0xC7C9E4, ink: 0xA9ACCF)

ctx.restoreGState()  // end of the tile clip

// MARK: - The cursor, resting on the focused window

let tip = CGPoint(x: 668, y: 560)
let arrow: [(CGFloat, CGFloat)] = [(0, 0), (0, 100), (24, 77), (41, 115), (57, 108), (40, 71), (72, 71)]
let scale: CGFloat = 2.05
let cursor = CGMutablePath()
cursor.addLines(between: arrow.map { CGPoint(x: tip.x + $0.0 * scale, y: tip.y + $0.1 * scale) })
cursor.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 6, height: 12), blur: 18, color: color(0x000000, 0.45))
ctx.addPath(cursor)
ctx.setFillColor(color(0x111111))
ctx.fillPath()
ctx.restoreGState()
ctx.setLineJoin(.round)
ctx.addPath(cursor)
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(13)
ctx.strokePath()
ctx.addPath(cursor)
ctx.setFillColor(color(0x111111))
ctx.fillPath()

// MARK: - Sparkles around the cursor's tip

sparkle(CGPoint(x: 606, y: 492), 50)
sparkle(CGPoint(x: 728, y: 478), 30)
sparkle(CGPoint(x: 580, y: 606), 24)
sparkle(CGPoint(x: 782, y: 552), 17)

// MARK: - Save

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <output.png>\n".utf8))
    exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
CGImageDestinationFinalize(destination)
