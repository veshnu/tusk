import Foundation
import CoreGraphics
import ImageIO

// Tusk app icon: an ivory tusk (the Postgres elephant, distilled) on the brand
// azure gradient, in the macOS rounded-square style. Drawn natively at each size.

func hex(_ v: UInt32) -> [CGFloat] {
    [CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255]
}

func drawIcon(size S: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // Top-left semantics helper (CG origin is bottom-left).
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * S, y: S * (1 - y)) }

    // Rounded-square body with margin, matching macOS icon proportions.
    let inset = S * 0.09
    let body = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let radius = body.width * 0.2237
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Azure gradient background (lighter top → deeper bottom).
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let top = hex(0x2E93FF), bot = hex(0x0057C4)
    let grad = CGGradient(colorSpace: cs,
                          colorComponents: [top[0], top[1], top[2], 1, bot[0], bot[1], bot[2], 1],
                          locations: [0, 1], count: 2)!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

    // Subtle glossy highlight across the top.
    let hi = CGGradient(colorSpace: cs,
                        colorComponents: [1, 1, 1, 0.16, 1, 1, 1, 0], locations: [0, 1], count: 2)!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: S * 0.55), options: [])
    ctx.restoreGState()

    // The tusk: a tapered crescent, thick rounded base (lower-left) → sharp tip (upper-right).
    let tusk = CGMutablePath()
    tusk.move(to: P(0.585, 0.200))                                   // tip
    tusk.addCurve(to: P(0.335, 0.740), control1: P(0.360, 0.280), control2: P(0.280, 0.520)) // outer edge
    tusk.addCurve(to: P(0.485, 0.775), control1: P(0.370, 0.830), control2: P(0.450, 0.830)) // rounded base
    tusk.addCurve(to: P(0.585, 0.200), control1: P(0.475, 0.520), control2: P(0.550, 0.300)) // inner edge
    tusk.closeSubpath()

    // Soft shadow under the tusk for depth.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.02,
                  color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.28])!)
    ctx.addPath(tusk)
    ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
    ctx.fillPath()
    ctx.restoreGState()

    // Faint blue-white shading on the tusk (top-left lighter → lower-right cooler).
    ctx.saveGState()
    ctx.addPath(tusk)
    ctx.clip()
    let tg = CGGradient(colorSpace: cs,
                        colorComponents: [1, 1, 1, 1, 0.82, 0.89, 1.0, 1], locations: [0, 1], count: 2)!
    ctx.drawLinearGradient(tg, start: P(0.40, 0.20), end: P(0.55, 0.80), options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments[1]
// (filename, pixel size)
let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, s) in variants {
    writePNG(drawIcon(size: s), to: outDir + "/" + name)
}
writePNG(drawIcon(size: 1024), to: outDir + "/preview_1024.png")
print("wrote \(variants.count) icon sizes to \(outDir)")
