import AppKit
import Testing
@testable import SopranoAgents

@MainActor
struct OverlayWindowTests {
    /// An overlay with an 800×600 backdrop and a card at (200, 150, 400×300).
    private func makeOverlay() -> (OverlayWindow, OverlayCardView, () -> Int) {
        _ = NSApplication.shared
        let overlay = OverlayWindow()
        let card = OverlayCardView()
        card.frame = NSRect(x: 200, y: 150, width: 400, height: 300)
        overlay.backdrop.addSubview(card)
        var clicks = 0
        overlay.backdrop.onClick = { clicks += 1 }
        return (overlay, card, { clicks })
    }

    private func mouseDown(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    @Test func aClickOnEmptyCardSpaceDoesNotDismiss() throws {
        let (overlay, card, clicks) = makeOverlay()
        let event = try mouseDown(at: NSPoint(x: 400, y: 300), in: overlay)

        // The card handles no clicks itself, so AppKit passes the event up to the backdrop.
        card.mouseDown(with: event)

        #expect(clicks() == 0)
    }

    @Test func aClickOnTheBackdropOutsideTheCardDismisses() throws {
        let (overlay, _, clicks) = makeOverlay()
        let event = try mouseDown(at: NSPoint(x: 50, y: 50), in: overlay)

        overlay.backdrop.mouseDown(with: event)

        #expect(clicks() == 1)
    }
}
