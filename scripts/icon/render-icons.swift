// Renders the app-icon concepts ("Said." style): flat, two colours, no letters (the name may change).
//   swift scripts/icon/render-icons.swift <out-dir> [concept-number]
// Writes concept-N.png (1024×1024) and contact-sheet.png.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let only = args.count > 2 ? Int(args[2]) : nil
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Apple's icon grid: an 824 pt rounded square centred on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let corner: CGFloat = 185

func tile(_ c: CGContext, _ color: CGColor) {
    let path = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.28))
    c.addPath(path); c.setFillColor(color); c.fillPath()
    c.restoreGState()
}

func stroke(_ c: CGContext, _ p: CGPath, _ color: CGColor, _ width: CGFloat) {
    c.saveGState()
    c.addPath(p); c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
    c.strokePath()
    c.restoreGState()
}

func fill(_ c: CGContext, _ p: CGPath, _ color: CGColor) {
    c.saveGState(); c.addPath(p); c.setFillColor(color); c.fillPath(); c.restoreGState()
}

func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGPath {
    let p = CGMutablePath(); p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2)); return p
}

// MARK: concepts (CoreGraphics y points up)
//
// House style "Said.": bold rounded voice bars that end in punctuation, on a flat tile.

let cream = rgb(0xF3EBDD), paper = rgb(0xF4F1EA), ink = rgb(0x151515)
let forest = rgb(0x1F3B2D), oxblood = rgb(0x4A1D24), night = rgb(0x18191B)

func bar(_ x: CGFloat, _ cy: CGFloat, _ h: CGFloat) -> CGPath { line(x, cy - h / 2, x, cy + h / 2) }
func dot(_ cx: CGFloat, _ cy: CGFloat, _ d: CGFloat = 100) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d), transform: nil)
}

/// The original "Said." mark: two bars and a full stop.
func said(_ c: CGContext, bg: CGColor, fg: CGColor, dotColor: CGColor? = nil) {
    tile(c, bg)
    stroke(c, bar(400, 540, 300), fg, 92)
    stroke(c, bar(530, 540, 440), fg, 92)
    fill(c, dot(660, 320), dotColor ?? fg)
}

/// 1. Said., forest: exactly "Said, in ink" on the forest green tile.
func saidForest(_ c: CGContext) { said(c, bg: forest, fg: cream) }
/// 2. Said., forest ink on paper.
func saidPaperForest(_ c: CGContext) { said(c, bg: paper, fg: forest) }
/// 3. Said., oxblood.
func saidOxblood(_ c: CGContext) { said(c, bg: oxblood, fg: cream) }
/// 4. Said., night: cream on near-black.
func saidNight(_ c: CGContext) { said(c, bg: night, fg: cream) }
/// 5. Accent dot: ink bars on paper, the full stop in forest green.
func saidAccent(_ c: CGContext) { said(c, bg: paper, fg: ink, dotColor: forest) }

/// 6. Say it!: one tall bar over a dot, an exclamation mark made of voice.
func sayIt(_ c: CGContext) {
    tile(c, forest)
    stroke(c, bar(512, 620, 280), cream, 104)
    fill(c, dot(512, 320, 112), cream)
}

/// 7. Rising: three bars growing, then the full stop.
func rising(_ c: CGContext) {
    tile(c, forest)
    let base: CGFloat = 330
    for (x, h) in [(330.0, 170.0), (450.0, 290.0), (570.0, 410.0)] as [(CGFloat, CGFloat)] {
        stroke(c, bar(x, base + h / 2 + 40, h), cream, 84)
    }
    fill(c, dot(690, 330, 92), cream)
}

/// 8. Comma: the thought continues. Two bars and a comma.
func comma(_ c: CGContext) {
    tile(c, paper)
    stroke(c, bar(400, 560, 300), ink, 92)
    stroke(c, bar(530, 560, 440), ink, 92)
    let q = CGMutablePath()
    let cx: CGFloat = 660, cy: CGFloat = 340, r: CGFloat = 50
    q.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .pi * 0.1, endAngle: .pi * 1.6, clockwise: false)
    q.addCurve(to: CGPoint(x: cx - 55, y: cy - 150), control1: CGPoint(x: cx + 20, y: cy - 80), control2: CGPoint(x: cx - 15, y: cy - 125))
    q.addCurve(to: CGPoint(x: cx + r * cos(.pi * 0.1), y: cy + r * sin(.pi * 0.1)),
               control1: CGPoint(x: cx + 45, y: cy - 115), control2: CGPoint(x: cx + 72, y: cy - 45))
    q.closeSubpath()
    fill(c, q, ink)
}

/// 9. Still listening: two bars and an ellipsis.
func ellipsis(_ c: CGContext) {
    tile(c, forest)
    stroke(c, bar(360, 560, 300), cream, 88)
    stroke(c, bar(480, 560, 440), cream, 88)
    for x in [590.0, 670.0, 750.0] as [CGFloat] { fill(c, dot(x, 330, 60), cream) }
}

/// 10. Monogram-free badge: the "Said." mark inside a cream circle on forest.
func badge(_ c: CGContext) {
    tile(c, forest)
    fill(c, dot(512, 512, 600), cream)
    stroke(c, bar(440, 530, 190), forest, 64)
    stroke(c, bar(530, 530, 290), forest, 64)
    fill(c, dot(615, 395, 68), forest)
}

let concepts: [(String, (CGContext) -> Void)] = [
    ("Said., forest", saidForest), ("Said., on paper", saidPaperForest), ("Said., oxblood", saidOxblood),
    ("Said., night", saidNight), ("Accent dot", saidAccent), ("Say it!", sayIt),
    ("Rising", rising), ("Comma", comma), ("Still listening", ellipsis), ("Badge", badge),
]

func render(_ draw: (CGContext) -> Void) -> CGImage {
    let c = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(c)
    return c.makeImage()!
}

func save(_ img: CGImage, _ name: String) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}

var images: [CGImage] = []
for (i, (_, draw)) in concepts.enumerated() where only == nil || only == i + 1 {
    let img = render(draw)
    save(img, "concept-\(i + 1).png")
    images.append(img)
}

if only == nil {
    // Contact sheet: rows of 5, each icon with a Dock-size preview underneath.
    let cell: CGFloat = 400, pad: CGFloat = 40, rowH: CGFloat = 620
    let perRow = 5
    let rows = (images.count + perRow - 1) / perRow
    let w = Int(CGFloat(perRow) * cell + pad * 2), h = Int(CGFloat(rows) * rowH)
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(rgb(0xE9E6E0)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    for (i, img) in images.enumerated() {
        let x = pad + CGFloat(i % perRow) * cell
        let y0 = CGFloat(rows - 1 - i / perRow) * rowH
        c.draw(img, in: CGRect(x: x + 10, y: y0 + 200, width: cell - 20, height: cell - 20))
        c.draw(img, in: CGRect(x: x + cell / 2 - 32, y: y0 + 110, width: 64, height: 64))
        let label = "\(i + 1). \(concepts[i].0)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26, weight: .semibold),
                                                    .foregroundColor: NSColor(white: 0.12, alpha: 1)]
        let sz = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: x + (cell - sz.width) / 2, y: y0 + 50), withAttributes: attrs)
    }
    save(c.makeImage()!, "contact-sheet.png")
}
print("wrote \(images.count) concept(s) to \(outDir.path)")
