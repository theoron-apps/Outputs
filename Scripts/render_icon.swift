import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Outputs/Assets.xcassets/AppIcon.appiconset"

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let paper = color(0xE3E2DD)
let ink = color(0x151515)
let accent = color(0xFF5A1F)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let canvas = CGFloat(pixels)
    cg.translateBy(x: 0, y: canvas)
    cg.scaleBy(x: 1, y: -1)
    let body = canvas * 824 / 1024
    let inset = (canvas - body) / 2
    let unit = body / 92
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: inset + (x - 4) * unit, y: inset + (y - 4) * unit)
    }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ fill: NSColor) {
        let center = p(x, y)
        cg.setFillColor(fill.cgColor)
        cg.fillEllipse(in: CGRect(x: center.x - r * unit, y: center.y - r * unit, width: r * 2 * unit, height: r * 2 * unit))
    }

    let rect = CGRect(x: inset, y: inset, width: body, height: body)
    let shape = CGPath(roundedRect: rect, cornerWidth: body * 0.2237, cornerHeight: body * 0.2237, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: canvas * 0.012), blur: canvas * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    cg.addPath(shape)
    cg.setFillColor(paper.cgColor)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    cg.setStrokeColor(ink.cgColor)
    cg.setLineWidth(6 * unit)
    cg.setLineCap(.round)
    cg.move(to: p(38, 50))
    cg.addCurve(to: p(70, 30), control1: p(56, 50), control2: p(52, 30))
    cg.move(to: p(38, 50))
    cg.addCurve(to: p(70, 70), control1: p(56, 50), control2: p(52, 70))
    cg.strokePath()
    circle(26, 50, 12, ink)
    circle(26, 50, 4, paper)
    circle(74, 30, 9, ink)
    circle(74, 70, 9, accent)

    if pixels >= 64 {
        let font = NSFont.monospacedSystemFont(ofSize: 10 * unit, weight: .medium)
        let text = NSAttributedString(string: "OUT", attributes: [.font: font, .foregroundColor: ink])
        cg.saveGState()
        cg.translateBy(x: p(16, 24).x, y: p(16, 24).y)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = context
        text.draw(at: CGPoint(x: 0, y: font.descender))
        cg.restoreGState()
    }
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try! render(size * scale).write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: output).appendingPathComponent("Contents.json"))
print("icons written to \(output)")
