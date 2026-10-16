import AppKit
import Testing
@testable import Soprano

@MainActor
struct RetroChromeHoverTests {
    @Test func aButtonDetachedWhileHoveredComesBackWithItsRestingFill() throws {
        let theme = ThemeManager(themeId: "gruvbox-dark").currentTheme
        let button = RetroButton(title: "Reload", theme: theme)
        button.frame = NSRect(x: 0, y: 0, width: 120, height: 26)
        let window = makeWindow()
        let host = try #require(window.contentView)
        host.addSubview(button)
        defer { window.contentView = nil }
        let entered = try enterEvent(in: window)

        button.mouseEntered(with: entered)
        let hovered = try #require(fillColor(of: button))

        // Cached tab contents are swapped by detaching the old view, which
        // delivers no mouse-exit event.
        button.removeFromSuperview()
        host.addSubview(button)

        let fresh = RetroButton(title: "Reload", theme: theme)
        fresh.frame = button.frame
        let resting = try #require(fillColor(of: fresh))
        #expect(hovered != resting)
        #expect(fillColor(of: button) == resting)

        button.mouseEntered(with: entered)
        #expect(fillColor(of: button) == hovered)
        button.mouseExited(with: entered)
        #expect(fillColor(of: button) == resting)
    }

    @Test func hidingAButtonWhileHoveredClearsItsHoverState() throws {
        let themeManager = ThemeManager(themeId: "gruvbox-dark")
        let colors = themeManager.currentTheme.colors
        let window = makeWindow()
        let host = try #require(window.contentView)
        defer { window.contentView = nil }
        let entered = try enterEvent(in: window)

        let icon = RetroIconButton(
            symbolName: "eye", accessibilityLabel: "Probe", target: nil, action: nil
        )
        icon.setTints(normal: colors.textMuted, hover: colors.accent)
        host.addSubview(icon)
        icon.mouseEntered(with: entered)
        #expect(icon.contentTintColor == colors.accent)
        icon.isHidden = true
        icon.isHidden = false
        #expect(icon.contentTintColor == colors.textMuted)

        let button = RetroButton(title: "Reload", theme: themeManager.currentTheme)
        button.frame = NSRect(x: 0, y: 0, width: 120, height: 26)
        host.addSubview(button)
        button.mouseEntered(with: entered)
        let hovered = try #require(fillColor(of: button))
        button.isHidden = true
        button.isHidden = false
        #expect(fillColor(of: button) != hovered)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        return window
    }

    private func enterEvent(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
    }

    /// Renders the button offscreen and samples its fill near the corner,
    /// inside the frame stroke.
    private func fillColor(of button: RetroButton) -> NSColor? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 26, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        button.draw(button.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB)
    }
}
