// Draws the Play Store graphics from the launcher icon's design (res/drawable/ic_quoth_mark.xml):
//   swift scripts/store-assets.swift store
// Writes icon-512.png (the store icon; Play rounds the corners) and feature-graphic.png (1024×500).
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
let paper = rgb(0xF4EFE6), ink = rgb(0x1F1E1C), green = rgb(0x2F5D45), muted = rgb(0x6B675F)

/// The mark in the vector's 108-unit space, drawn at `origin` (top-left) and `scale` units → pixels. y grows down.
func mark(_ c: CGContext, origin: CGPoint, scale s: CGFloat, height: CGFloat) {
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: origin.x + x * s, y: height - (origin.y + (y + h) * s), width: w * s, height: h * s)
    }
    c.setFillColor(ink)
    c.addPath(CGPath(roundedRect: r(25, 40, 58, 10), cornerWidth: 5 * s, cornerHeight: 5 * s, transform: nil))
    c.addPath(CGPath(roundedRect: r(25, 58, 40, 10), cornerWidth: 5 * s, cornerHeight: 5 * s, transform: nil))
    c.fillPath()
    c.setFillColor(green)
    c.fillEllipse(in: r(67, 56, 14, 14))
}

func render(_ name: String, _ w: Int, _ h: Int, _ draw: (CGContext) -> Void) {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(paper); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    draw(c)
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name))
}

render("icon-512.png", 512, 512) { c in mark(c, origin: .zero, scale: 512 / 108, height: 512) }

render("feature-graphic.png", 1024, 500) { c in
    mark(c, origin: CGPoint(x: 40, y: 28), scale: 4.1, height: 500)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    func text(_ s: String, _ size: CGFloat, _ color: CGColor, _ y: CGFloat, weight: NSFont.Weight) {
        NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: NSColor(cgColor: color)!])
            .draw(at: CGPoint(x: 520, y: y))
    }
    text("Quoth", 96, ink, 250, weight: .semibold)
    text("Speak, and it types.", 40, muted, 190, weight: .regular)
    text("Private: runs on your phone.", 32, muted, 140, weight: .regular)
}
