// Writes a Soprano-family app icon as an Icon Composer document (`.icon`).
// Usage: swift scripts/render-app-icon.swift <soprano|git|cast|tab> <AppIcon.icon>
//
// Single source for all four apps: Soprano owns this file, Soprano Git / Cast / Tab vendor
// it unchanged through scripts/sync-soprano-chrome.sh. Each repo's
// scripts/render-app-icon.sh runs it, renders the AppIcon.icns fallback (macOS 14 and 15)
// from the document with Icon Composer's ictool and, where the app ships one, compiles
// Assets.car with Xcode's actool (Paper, Ink and the tinted/clear variants macOS derives
// from them).
//
// The geometry and colours transcribe soprano-site assets/icons/<app>.svg and
// <app>-dark.svg (1024 viewBox, an 824 body at 100): an ink glyph with round caps and joins
// on a paper ground, and exactly one sienna element. The document holds the ground as the
// icon fill (Paper gradient #f3eee4 → #e9e2d4, Ink #2a2622 → #1a1815) and the glyph as one
// layer per appearance; macOS draws the tile shape, rim and shadow itself. The Ink glyph
// also serves the tinted appearance: macOS tints a light-on-dark glyph, so the Paper one
// (dark strokes) would vanish into the tinted ground.
import AppKit

enum App: String, CaseIterable {
    case soprano, git, cast, tab
}

struct Palette {
    let groundTop: CGColor
    let groundBottom: CGColor
    let ink: CGColor
    let sheet: CGColor
    let mark: CGColor

    // b/tokens.css --icon-*.
    static let paper = Palette(
        groundTop: srgb(0xf3eee4), groundBottom: srgb(0xe9e2d4),
        ink: srgb(0x2b2620), sheet: srgb(0xfbf8f2), mark: srgb(0xa34a17)
    )
    static let ink = Palette(
        groundTop: srgb(0x2a2622), groundBottom: srgb(0x1a1815),
        ink: srgb(0xe2dacb), sheet: srgb(0x24211d), mark: srgb(0xe08a52)
    )
}

/// The design's body inside its 1024 viewBox; an Icon Composer canvas is the body itself.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let layerPixels = 1024
let glyphStroke: CGFloat = 48

func srgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

/// Icon Composer colour literal.
func literal(_ color: CGColor) -> String {
    let c = color.components ?? [0, 0, 0, 1]
    return "srgb:" + c.map { String(format: "%.5f", $0) }.joined(separator: ",")
}

/// Draws SVG shapes in 1024-viewBox units, SVG paint order (fill, then a centred stroke).
struct Pen {
    let ctx: CGContext
    let palette: Palette

    private func paint(_ path: CGPath, fill: CGColor?, stroke: CGColor?, width: CGFloat) {
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

    /// Ink outline unless `stroked: false` (fill only).
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat,
              fill: CGColor?, stroked: Bool = true, width: CGFloat = glyphStroke) {
        let path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        paint(path, fill: fill, stroke: stroked ? palette.ink : nil, width: width)
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat,
                fill: CGColor?, stroked: Bool = true, width: CGFloat = glyphStroke) {
        let path = CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil)
        paint(path, fill: fill, stroke: stroked ? palette.ink : nil, width: width)
    }

    func line(_ points: [(CGFloat, CGFloat)], stroke: CGColor? = nil, width: CGFloat = glyphStroke) {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        paint(path, fill: nil, stroke: stroke ?? palette.ink, width: width)
    }

    func curve(from start: (CGFloat, CGFloat), _ c1: (CGFloat, CGFloat), _ c2: (CGFloat, CGFloat),
               to end: (CGFloat, CGFloat), width: CGFloat = glyphStroke) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start.0, y: start.1))
        path.addCurve(to: CGPoint(x: end.0, y: end.1),
                      control1: CGPoint(x: c1.0, y: c1.1), control2: CGPoint(x: c2.0, y: c2.1))
        paint(path, fill: nil, stroke: palette.ink, width: width)
    }
}

func drawGlyph(_ pen: Pen, app: App) {
    let p = pen.palette
    pen.ctx.setLineCap(.round)
    pen.ctx.setLineJoin(.round)
    switch app {
    case .soprano:
        // Two sheets (tall pane, small pane) and the sienna tab above the small one.
        pen.rect(296, 288, 176, 448, radius: 40, fill: p.sheet)
        pen.rect(576, 560, 152, 176, radius: 40, fill: p.sheet)
        pen.rect(552, 264, 200, 248, radius: 64, fill: p.mark, stroked: false)
    case .git:
        // Trunk with three commits, a branch curving off to a sienna tip.
        pen.line([(392, 268), (392, 756)])
        pen.curve(from: (392, 640), (392, 540), (640, 560), to: (640, 420))
        pen.circle(392, 324, 44, fill: p.groundTop)
        pen.circle(392, 512, 44, fill: p.groundTop)
        pen.circle(392, 700, 44, fill: p.groundBottom)
        pen.circle(640, 340, 72, fill: p.mark, stroked: false)
    case .cast:
        // Search pill with a magnifier and the sienna caret.
        pen.rect(236, 404, 552, 216, radius: 108, fill: p.sheet)
        pen.circle(352, 500, 40, fill: nil, width: 32)
        pen.line([(382, 530), (412, 560)], width: 32)
        pen.rect(556, 452, 40, 120, radius: 20, fill: p.mark, stroked: false)
    case .tab:
        // Two overlapping windows and the sienna "switch to" arrow.
        pen.rect(264, 288, 384, 288, radius: 44, fill: p.sheet)
        pen.rect(376, 440, 384, 288, radius: 44, fill: p.sheet)
        pen.line([(452, 584), (640, 584)], stroke: p.mark, width: 44)
        pen.line([(584, 528), (640, 584), (584, 640)], stroke: p.mark, width: 44)
        pen.line([(692, 520), (692, 648)], stroke: p.mark, width: 44)
    }
}

/// The glyph alone on a transparent canvas that spans the body.
func renderLayer(_ app: App, palette: Palette) -> Data? {
    guard let ctx = CGContext(
        data: nil,
        width: layerPixels,
        height: layerPixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let scale = CGFloat(layerPixels) / body.width
    // Top-left origin in viewBox units, so the SVG coordinates apply verbatim.
    ctx.translateBy(x: 0, y: CGFloat(layerPixels))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: -body.minX, y: -body.minY)
    drawGlyph(Pen(ctx: ctx, palette: palette), app: app)
    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

func ground(_ palette: Palette) -> [String: Any] {
    [
        "linear-gradient": [literal(palette.groundTop), literal(palette.groundBottom)],
        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
    ]
}

/// Flat Folio paper: no glass, specular highlight or translucency on the glyph.
let document: [String: Any] = [
    "fill-specializations": [
        ["value": ground(.paper)],
        ["appearance": "dark", "value": ground(.ink)],
    ],
    "groups": [[
        "layers": [[
            "name": "glyph",
            "glass": false,
            "image-name-specializations": [
                ["value": "glyph.png"],
                ["appearance": "dark", "value": "glyph-dark.png"],
                ["appearance": "tinted", "value": "glyph-dark.png"],
            ],
        ]],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "specular": false,
        "translucency": ["enabled": false, "value": 0.5],
    ]],
    "supported-platforms": ["squares": ["macOS"]],
]

let arguments = CommandLine.arguments
guard arguments.count == 3, let app = App(rawValue: arguments[1]) else {
    let apps = App.allCases.map(\.rawValue).joined(separator: "|")
    FileHandle.standardError.write(Data("Usage: render-app-icon.swift <\(apps)> <AppIcon.icon>\n".utf8))
    exit(2)
}
let iconDocument = URL(fileURLWithPath: arguments[2], isDirectory: true)
let assets = iconDocument.appendingPathComponent("Assets", isDirectory: true)
do {
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    for (name, palette) in [("glyph.png", Palette.paper), ("glyph-dark.png", Palette.ink)] {
        guard let png = renderLayer(app, palette: palette) else {
            FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
            exit(1)
        }
        try png.write(to: assets.appendingPathComponent(name), options: .atomic)
    }
    let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: iconDocument.appendingPathComponent("icon.json"), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
