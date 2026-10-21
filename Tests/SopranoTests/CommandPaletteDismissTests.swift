import AppKit
import Testing
@testable import Soprano

@MainActor
struct CommandPaletteDismissTests {
    @Test func aClickInTheShadowMarginClosesThePalette() throws {
        let (window, controller) = makePalette()
        var dismissals = 0
        controller.onDismiss = { dismissals += 1 }

        let margin = CommandPaletteViewController.shadowMargin
        try deliver(click(at: NSPoint(x: margin.left / 2, y: 20), in: window), to: window)

        #expect(dismissals == 1)
    }

    @Test func aClickOnThePaletteSurfaceKeepsItOpen() throws {
        let (window, controller) = makePalette()
        var dismissals = 0
        controller.onDismiss = { dismissals += 1 }

        // The footer strip, just above the surface's bottom edge.
        let margin = CommandPaletteViewController.shadowMargin
        let point = NSPoint(x: controller.view.bounds.midX, y: margin.bottom + 6)
        try deliver(click(at: point, in: window), to: window)

        #expect(dismissals == 0)
    }

    /// Sends the click where AppKit would: the deepest view under it. An
    /// offscreen, non-key panel ignores `sendEvent` clicks.
    private func deliver(_ event: NSEvent, to window: NSWindow) throws {
        let content = try #require(window.contentView)
        let target = try #require(content.hitTest(event.locationInWindow))
        target.mouseDown(with: event)
    }

    private func makePalette() -> (NSWindow, CommandPaletteViewController) {
        let controller = CommandPaletteViewController(theme: AppTheme.folioPaper)
        controller.setCommands(
            [CommandItem(id: "one", icon: "terminal", label: "Open Terminal", description: "Open a new terminal pane", action: {})],
            placeholder: "Type a command..."
        )
        let window = NSPanel(
            contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: controller.preferredContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        return (window, controller)
    }

    private func click(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
