import AppKit

// Usage:
//   icon-renderer appicon <output.iconset>
//   icon-renderer preview <output-dir>   (1024px PNG, for review)
//
// A sound wave runs into a track switch that routes it to one of two devices:
// headphones (active branch, lit) or a speaker (inactive branch, dimmed).

func renderPNG(pixels: Int, to url: URL, draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func circle(_ c: NSPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

func stroked(_ path: NSBezierPath, width: CGFloat) -> NSBezierPath {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

func withShadow(_ draw: () -> Void) {
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

let junction = NSPoint(x: 400, y: 512)
let headphonesCenter = NSPoint(x: 735, y: 690)
let speakerCenter = NSPoint(x: 720, y: 335)

func soundWave() -> NSBezierPath {
    let p = NSBezierPath()
    let startX: CGFloat = 165, endX = junction.x
    p.move(to: NSPoint(x: startX, y: junction.y))
    var x = startX
    while x <= endX {
        // Three half-cycles; amplitude swells toward the middle.
        let t = (x - startX) / (endX - startX)
        p.line(to: NSPoint(x: x, y: junction.y + 70 * sin(t * .pi) * sin(t * 3 * .pi)))
        x += 2
    }
    return p
}

func branch(to end: NSPoint) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: junction)
    p.curve(to: end,
            controlPoint1: NSPoint(x: junction.x + 120, y: junction.y),
            controlPoint2: NSPoint(x: end.x - 120, y: end.y))
    return p
}

func drawHeadphones(color: NSColor) {
    let c = headphonesCenter
    color.set()
    let band = NSBezierPath()
    band.appendArc(withCenter: NSPoint(x: c.x, y: c.y - 10), radius: 98, startAngle: 180, endAngle: 0, clockwise: true)
    stroked(band, width: 30).stroke()
    for dx in [-98.0, 98.0] {
        NSBezierPath(roundedRect: NSRect(x: c.x + dx - 34, y: c.y - 120, width: 68, height: 120), xRadius: 28, yRadius: 28).fill()
    }
}

func drawSpeaker(color: NSColor) {
    let c = speakerCenter
    color.set()
    NSBezierPath(roundedRect: NSRect(x: c.x - 70, y: c.y - 38, width: 52, height: 76), xRadius: 10, yRadius: 10).fill()
    let cone = NSBezierPath()
    cone.move(to: NSPoint(x: c.x - 26, y: c.y - 38))
    cone.line(to: NSPoint(x: c.x + 40, y: c.y - 92))
    cone.line(to: NSPoint(x: c.x + 40, y: c.y + 92))
    cone.line(to: NSPoint(x: c.x - 26, y: c.y + 38))
    cone.close()
    cone.lineJoinStyle = .round
    cone.lineWidth = 16
    cone.fill()
    cone.stroke()
    for r in [CGFloat(62), 108] {
        let wave = NSBezierPath()
        wave.appendArc(withCenter: NSPoint(x: c.x + 40, y: c.y), radius: r, startAngle: 40, endAngle: -40, clockwise: true)
        stroked(wave, width: 22).stroke()
    }
}

func drawAppIcon(side: CGFloat) {
    let scale = NSAffineTransform()
    scale.scale(by: side / 1024)
    scale.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: rgb(0.55, 0.15, 0.55), ending: rgb(1.0, 0.45, 0.36))?.draw(in: tile, angle: 90)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    NSGradient(starting: NSColor(white: 1, alpha: 0.2), ending: NSColor(white: 1, alpha: 0))?
        .draw(fromCenter: NSPoint(x: 280, y: 850), radius: 0, toCenter: NSPoint(x: 280, y: 850), radius: 640, options: [])

    let lit = NSColor.white

    // Inactive route first, so the active one sits on top at the junction.
    // Drawn opaque inside a transparency layer so overlapping shapes don't show seams.
    let cg = NSGraphicsContext.current!.cgContext
    cg.saveGState()
    cg.setAlpha(0.38)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    lit.set()
    stroked(branch(to: NSPoint(x: speakerCenter.x - 110, y: speakerCenter.y)), width: 26).stroke()
    drawSpeaker(color: lit)
    cg.endTransparencyLayer()
    cg.restoreGState()

    withShadow {
        lit.set()
        stroked(soundWave(), width: 26).stroke()
        stroked(branch(to: NSPoint(x: headphonesCenter.x - 160, y: headphonesCenter.y - 60)), width: 26).stroke()
        drawHeadphones(color: lit)

        // Switch point.
        rgb(1, 0.84, 0.30).set()
        circle(junction, 40).fill()
    }
    rgb(0.62, 0.22, 0.45).set()
    circle(junction, 15).fill()

    NSGraphicsContext.restoreGraphicsState()
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: icon-renderer appicon|preview <output>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

switch args[1] {
case "appicon":
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let pixels = points * factor
            let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try renderPNG(pixels: pixels, to: out.appendingPathComponent(name)) { drawAppIcon(side: CGFloat(pixels)) }
        }
    }
case "preview":
    try renderPNG(pixels: 1024, to: out.appendingPathComponent("appicon.png")) { drawAppIcon(side: 1024) }
default:
    exit(2)
}
