import AppKit

@MainActor
enum AssetRenderer {
    static func bitmap(width: Int, height: Int, draw: (NSRect) -> Void) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw DesktopError.message("Could not allocate the image canvas")
        }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func renderAssets(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for screen in NSScreen.screens {
            let width = Int(screen.frame.width * screen.backingScaleFactor)
            let height = Int(screen.frame.height * screen.backingScaleFactor)
            let name = "wallpaper-\(width)x\(height).png"
            try Desktop.writePNG(wallpaper(width: width, height: height), to: directory.appendingPathComponent(name))
        }
        try Desktop.writePNG(wallpaper(width: 3840, height: 2160), to: directory.appendingPathComponent("wallpaper.png"))
        try Desktop.writePNG(icon(mark: "MC", width: 1024), to: directory.appendingPathComponent("desktop-icon.png"))
        for launcher in Launcher.available {
            try Desktop.writePNG(icon(mark: launcher.mark, width: 512), to: directory.appendingPathComponent("\(launcher.id).png"))
        }
        let colors = Desktop.theme.colors
        let palette: [String: String] = [
            "BASE": hex(colors.bgBase), "PANEL": hex(colors.bgPanel),
            "RAISED": hex(colors.bgRaised), "TEXT": hex(colors.textPrimary),
            "MUTED": hex(colors.textMuted), "ORANGE": hex(colors.accent),
            "MUSTARD": hex(colors.accentStrong), "BORDER": hex(colors.borderStrong),
            "RED": hex(colors.danger), "GREEN": hex(colors.success)
        ]
        let script = palette.keys.sorted().map { "\($0)=0xff\(palette[$0]!)" }.joined(separator: "\n") + "\n"
        try script.write(to: directory.appendingPathComponent("palette.sh"), atomically: true, encoding: .utf8)
    }

    private static func hex(_ color: NSColor) -> String {
        let color = color.usingColorSpace(.sRGB)!
        return String(format: "%02x%02x%02x", Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }

    static func wallpaper(width: Int, height: Int) throws -> NSBitmapImageRep {
        try bitmap(width: width, height: height) { rect in
            let colors = Desktop.theme.colors
            colors.bgBase.setFill()
            rect.fill()
            let grid = NSBezierPath()
            let spacing: CGFloat = 88
            var x: CGFloat = 0
            while x < rect.width { grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: rect.height)); x += spacing }
            var y: CGFloat = 0
            while y < rect.height { grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: rect.width, y: y)); y += spacing }
            colors.borderSubtle.withAlphaComponent(0.35).setStroke()
            grid.lineWidth = 1
            grid.stroke()
            let center = NSPoint(x: rect.width * 0.72, y: rect.height * 0.51)
            colors.borderStrong.withAlphaComponent(0.55).setStroke()
            for radius in [CGFloat(170), 340, 510] {
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).stroke()
            }
            let axes = NSBezierPath()
            axes.move(to: NSPoint(x: center.x - 650, y: center.y)); axes.line(to: NSPoint(x: center.x + 650, y: center.y))
            axes.move(to: NSPoint(x: center.x, y: center.y - 650)); axes.line(to: NSPoint(x: center.x, y: center.y + 650))
            axes.stroke()
            let orbit = NSBezierPath(ovalIn: NSRect(x: center.x - 530, y: center.y - 215, width: 1060, height: 430))
            colors.accent.withAlphaComponent(0.23).setStroke()
            orbit.lineWidth = 2
            orbit.stroke()
            for (index, color) in colors.stripe.enumerated() {
                color.setFill()
                NSRect(x: 96 + CGFloat(index) * 18, y: rect.height - 194, width: 12, height: 84).fill()
            }
            RetroText.display("soprano", color: colors.textPrimary, size: 33, tracking: 3).draw(at: NSPoint(x: 172, y: rect.height - 153))
            RetroText.display("mission control / personal workstation", color: colors.textMuted).draw(at: NSPoint(x: 172, y: rect.height - 181))
            colors.borderStrong.setFill()
            NSRect(x: 96, y: 96, width: rect.width - 192, height: 1).fill()
            RetroText.display("systems nominal", color: colors.success).draw(at: NSPoint(x: 96, y: 67))
            RetroText.display("⌃⌥space  window overview     ⌃⌥d  dashboard", color: colors.textMuted).draw(at: NSPoint(x: rect.width - 650, y: 67))
            // Very low-contrast, static phosphor lines; no continuously redrawn wallpaper.
            colors.bgPanel.withAlphaComponent(0.12).setFill()
            var line: CGFloat = 0
            while line < rect.height { NSRect(x: 0, y: line, width: rect.width, height: 1).fill(); line += 4 }
        }
    }

    static func icon(mark: String, width: Int) throws -> NSBitmapImageRep {
        try bitmap(width: width, height: width) { rect in
            let colors = Desktop.theme.colors
            colors.bgPanel.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08), xRadius: rect.width * 0.12, yRadius: rect.height * 0.12).fill()
            let frame = rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18)
            colors.borderStrong.setStroke()
            let edge = NSBezierPath(rect: frame)
            edge.lineWidth = rect.width * 0.006
            edge.stroke()
            for (index, color) in colors.stripe.enumerated() {
                color.setFill()
                NSRect(x: frame.minX, y: frame.maxY - CGFloat(index + 1) * rect.height * 0.023,
                    width: frame.width, height: rect.height * 0.017).fill()
            }
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            let scale = rect.width / 128
            context.scaleBy(x: scale, y: scale)
            let text = RetroText.display(mark, color: colors.textPrimary, size: 33, tracking: 1, glow: true)
            let size = text.size()
            text.draw(at: NSPoint(x: (128 - size.width) / 2, y: (128 - size.height) / 2 - 6))
            context.restoreGState()
            colors.accent.setFill()
            NSRect(x: frame.minX, y: frame.minY, width: frame.width * 0.24, height: rect.height * 0.013).fill()
        }
    }
}

@MainActor
struct Launcher {
    let id: String
    let name: String
    let mark: String

    static var available: [Launcher] {
        [Launcher(id: "com.soprano.app", name: "Soprano", mark: "SP"),
         Launcher(id: "com.apple.finder", name: "Finder", mark: "FI"),
         Launcher(id: "com.apple.Safari", name: "Safari", mark: "SA"),
         Launcher(id: "com.google.Chrome", name: "Chrome", mark: "CH"),
         Launcher(id: "dev.zed.Zed", name: "Zed", mark: "ZE")]
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    func open() throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            throw DesktopError.message("\(name) is not installed")
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { NSLog("Soprano Desktop launch: %@", error.localizedDescription) }
        }
    }
}
