// Renders a Soprano-family app icon (Folio "Paper") straight into an .iconset directory.
// Usage: swift scripts/render-app-icon.swift <soprano|git|cast|tab> <iconset-dir>
//
// Single source for all four apps: Soprano owns this file, Soprano Git / Cast / Tab vendor
// it unchanged through scripts/sync-soprano-chrome.sh, and each repo's
// scripts/render-app-icon.sh runs it and packs the result with `iconutil -c icns`.
//
// The geometry and colours transcribe docs/design/2026-10-21-calm-family/b/icons/<app>.svg
// (1024 viewBox): a paper ground (824 body on Apple's 100 px grid, vertical gradient
// #f3eee4 → #e9e2d4, soft drop shadow dy 12 / σ 14 / 22 %, hairline rim), an ink #2b2620
// glyph with round caps and joins, and exactly one sienna #a34a17 element. Every iconset
// size is a fresh vector redraw of the same 1024-unit geometry, not a downscale.
//
// One deliberate difference from the SVGs: the ground uses Apple's continuous-curvature
// corner (the squircle macOS draws its own icons with) instead of the SVG's circular rx 185,
// so macOS 26+ recognises the icon shape and does not put it on a grey backing plate.
//
// Paper only: an .icns has no dark-appearance slot (that needs an Icon Composer .icon /
// asset catalog, which the Command Line Tools build cannot produce). The Ink variant
// exists as <app>-dark.svg for the website.
import AppKit

enum App: String, CaseIterable {
    case soprano, git, cast, tab
}

// Folio Paper tokens (b/tokens.css --icon-*).
enum Paper {
    static let groundTop = srgb(0xf3eee4)
    static let groundBottom = srgb(0xe9e2d4)
    static let shadow = srgb(0x000000, alpha: 0.22)
    static let rim = srgb(0x2b2620, alpha: 0.10)
    static let ink = srgb(0x2b2620)
    static let sheet = srgb(0xfbf8f2)
    static let mark = srgb(0xa34a17)
}

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185
let glyphStroke: CGFloat = 48

// (file name, pixel size) for every member iconutil expects.
let iconsetMembers: [(String, Int)] = [16, 32, 128, 256, 512].flatMap { size in
    [("icon_\(size)x\(size).png", size), ("icon_\(size)x\(size)@2x.png", size * 2)]
}

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

/// Rounded rectangle with continuous curvature (the iOS 7+/macOS 11+ squircle): each corner
/// spans 1.528665 × radius along both edges and blends into the straight edge without the
/// curvature jump of a circular arc. Control points are the published reverse-engineering of
/// UIBezierPath(roundedRect:cornerRadius:).
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let extent: CGFloat = 1.52866483
    let r = min(radius, min(rect.width, rect.height) / 2 / extent)
    // One corner, in units of r: `a` runs back along the incoming edge, `b` along the
    // outgoing edge, both measured from the sharp corner point.
    let segments: [[(a: CGFloat, b: CGFloat)]] = [
        [(1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600)],
        [(0.63149399, 0.07491100)],
        [(0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491176, 0.63149399)],
        [(0, 0.86840701), (0, 1.08849299), (0, extent)],
    ]
    // Clockwise in top-left (y-down) coordinates: top-right, bottom-right, bottom-left, top-left.
    let corners: [(corner: CGPoint, incoming: CGVector, outgoing: CGVector)] = [
        (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    func point(_ c: (corner: CGPoint, incoming: CGVector, outgoing: CGVector), _ a: CGFloat, _ b: CGFloat) -> CGPoint {
        CGPoint(
            x: c.corner.x - a * r * c.incoming.dx + b * r * c.outgoing.dx,
            y: c.corner.y - a * r * c.incoming.dy + b * r * c.outgoing.dy
        )
    }
    let path = CGMutablePath()
    path.move(to: point(corners[3], 0, extent))
    for c in corners {
        path.addLine(to: point(c, extent, 0))
        for segment in segments {
            let p = segment.map { point(c, $0.a, $0.b) }
            if p.count == 3 {
                path.addCurve(to: p[2], control1: p[0], control2: p[1])
            } else {
                path.addLine(to: p[0])
            }
        }
    }
    path.closeSubpath()
    return path
}

/// SVG paint order: fill first, then a centred stroke. `stroke: nil` = fill only.
func paint(_ ctx: CGContext, _ path: CGPath, fill: CGColor? = nil, stroke: CGColor? = nil, width: CGFloat = 0) {
    if let fill {
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
    }
    if let stroke {
        ctx.addPath(path)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }
}

/// Draws glyph shapes given in 1024 units, hinted to the device pixel grid: stroke widths
/// round to whole pixels (at least one), stroke centre lines and fill edges snap to pixel
/// boundaries (odd widths to pixel centres), and no shape shrinks below one pixel. That keeps
/// the 16 and 32 px members crisp instead of a grey smear of 0.75 px strokes. Every SVG
/// coordinate is even, so at 512 and 1024 px the hinting is the identity.
struct Pen {
    let ctx: CGContext
    /// Device pixels per 1024-grid unit.
    let scale: CGFloat

    private var pixel: CGFloat { 1 / scale }

    private func hintedWidth(_ units: CGFloat) -> CGFloat {
        max(1, (units * scale).rounded()) / scale
    }

    /// Grid offset in device pixels for a stroke of `width` units: 0.5 centres odd widths on
    /// a pixel; fills (`nil`) and even widths land on pixel boundaries.
    private func offset(_ width: CGFloat?) -> CGFloat {
        guard let width else { return 0 }
        return Int((width * scale).rounded()) % 2 == 1 ? 0.5 : 0
    }

    private func snap(_ v: CGFloat, _ offset: CGFloat) -> CGFloat {
        ((v * scale - offset).rounded() + offset) / scale
    }

    private func snap(_ p: (CGFloat, CGFloat), _ offset: CGFloat) -> CGPoint {
        CGPoint(x: snap(p.0, offset), y: snap(p.1, offset))
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat,
              fill: CGColor?, stroke: CGColor? = Paper.ink, width: CGFloat = glyphStroke) {
        let lineWidth = stroke.map { _ in hintedWidth(width) }
        let o = offset(lineWidth)
        let minX = snap(x, o), minY = snap(y, o)
        let maxX = max(snap(x + w, o), minX + pixel), maxY = max(snap(y + h, o), minY + pixel)
        let r = min(radius, (maxX - minX) / 2, (maxY - minY) / 2)
        let path = CGPath(
            roundedRect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            cornerWidth: r, cornerHeight: r, transform: nil
        )
        paint(ctx, path, fill: fill, stroke: stroke, width: lineWidth ?? 0)
    }

    /// The centre snaps like a line end (so a trunk through it stays aligned) and the radius
    /// rounds to whole pixels, which keeps both edges on the same grid.
    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
                fill: CGColor?, stroke: CGColor? = Paper.ink, width: CGFloat = glyphStroke) {
        let lineWidth = stroke.map { _ in hintedWidth(width) }
        let centre = snap((cx, cy), offset(lineWidth))
        let radius = max(1, (r * scale).rounded()) / scale
        let path = CGPath(
            ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius),
            transform: nil
        )
        paint(ctx, path, fill: fill, stroke: stroke, width: lineWidth ?? 0)
    }

    func line(_ points: [(CGFloat, CGFloat)], stroke: CGColor = Paper.ink, width: CGFloat = glyphStroke) {
        let lineWidth = hintedWidth(width)
        let path = CGMutablePath()
        path.addLines(between: points.map { snap($0, offset(lineWidth)) })
        paint(ctx, path, stroke: stroke, width: lineWidth)
    }

    /// Cubic Bézier; each control point moves with its snapped end point so the tangents hold.
    func curve(from start: (CGFloat, CGFloat), _ c1: (CGFloat, CGFloat), _ c2: (CGFloat, CGFloat),
               to end: (CGFloat, CGFloat), stroke: CGColor = Paper.ink, width: CGFloat = glyphStroke) {
        let lineWidth = hintedWidth(width)
        let o = offset(lineWidth)
        let from = snap(start, o), to = snap(end, o)
        let path = CGMutablePath()
        path.move(to: from)
        path.addCurve(
            to: to,
            control1: CGPoint(x: c1.0 + from.x - start.0, y: c1.1 + from.y - start.1),
            control2: CGPoint(x: c2.0 + to.x - end.0, y: c2.1 + to.y - end.1)
        )
        paint(ctx, path, stroke: stroke, width: lineWidth)
    }
}

func drawGround(_ ctx: CGContext, scale: CGFloat) {
    let ground = continuousRoundedRect(body, radius: bodyRadius)

    // feDropShadow dx 0 dy 12 stdDeviation 14. CG shadows live in device space (unscaled,
    // y-up): blur ≈ 2σ, and "down" is a negative offset.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: Paper.shadow)
    ctx.addPath(ground)
    ctx.setFillColor(Paper.groundBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(ground)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [Paper.groundTop, Paper.groundBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    ctx.restoreGState()

    // Hairline rim: 2 units, centred half a unit inside the body edge.
    paint(ctx, continuousRoundedRect(body.insetBy(dx: 0.5, dy: 0.5), radius: bodyRadius - 0.5), stroke: Paper.rim, width: 2)
}

func drawGlyph(_ pen: Pen, app: App) {
    pen.ctx.setLineCap(.round)
    pen.ctx.setLineJoin(.round)
    switch app {
    case .soprano:
        // Two paper sheets (tall pane, small pane) and the sienna tab above the small one.
        pen.rect(296, 288, 176, 448, radius: 40, fill: Paper.sheet)
        pen.rect(576, 560, 152, 176, radius: 40, fill: Paper.sheet)
        pen.rect(552, 264, 200, 248, radius: 64, fill: Paper.mark, stroke: nil)
    case .git:
        // Trunk with three commits, a branch curving off to a sienna tip.
        pen.line([(392, 268), (392, 756)])
        pen.curve(from: (392, 640), (392, 540), (640, 560), to: (640, 420))
        pen.circle(392, 324, 44, fill: srgb(0xf3eee4))
        pen.circle(392, 512, 44, fill: srgb(0xf3eee4))
        pen.circle(392, 700, 44, fill: srgb(0xe9e2d4))
        pen.circle(640, 340, 72, fill: Paper.mark, stroke: nil)
    case .cast:
        // Search pill with a magnifier and the sienna caret.
        pen.rect(236, 404, 552, 216, radius: 108, fill: Paper.sheet)
        pen.circle(352, 500, 40, fill: nil, width: 32)
        pen.line([(382, 530), (412, 560)], width: 32)
        pen.rect(556, 452, 40, 120, radius: 20, fill: Paper.mark, stroke: nil)
    case .tab:
        // Two overlapping windows and the sienna "switch to" arrow.
        pen.rect(264, 288, 384, 288, radius: 44, fill: Paper.sheet)
        pen.rect(376, 440, 384, 288, radius: 44, fill: Paper.sheet)
        pen.line([(452, 584), (640, 584)], stroke: Paper.mark, width: 44)
        pen.line([(584, 528), (640, 584), (584, 640)], stroke: Paper.mark, width: 44)
        pen.line([(692, 520), (692, 648)], stroke: Paper.mark, width: 44)
    }
}

func render(_ app: App, pixels: Int) -> Data? {
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let scale = CGFloat(pixels) / canvas
    // Top-left origin in 1024 units, so the SVG coordinates apply verbatim.
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawGround(ctx, scale: scale)
    drawGlyph(Pen(ctx: ctx, scale: scale), app: app)
    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let app = App(rawValue: arguments[1]) else {
    let apps = App.allCases.map(\.rawValue).joined(separator: "|")
    FileHandle.standardError.write(Data("Usage: render-app-icon.swift <\(apps)> <iconset-dir>\n".utf8))
    exit(2)
}
let iconset = URL(fileURLWithPath: arguments[2], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (name, pixels) in iconsetMembers {
        guard let png = render(app, pixels: pixels) else {
            FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
            exit(1)
        }
        try png.write(to: iconset.appendingPathComponent(name), options: .atomic)
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
