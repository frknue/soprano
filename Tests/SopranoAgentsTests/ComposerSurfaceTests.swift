import AppKit
import Testing
@testable import SopranoAgents

@MainActor
struct ComposerSurfaceTests {
    @Test func clicksInsideTheComposerReachItsControlsInsteadOfTheOutlineDrawnOverThem() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let surface = ComposerSurfaceView(frame: NSRect(x: 100, y: 100, width: 400, height: 120))
        container.addSubview(surface)
        let chip = InteractiveView(frame: NSRect(x: 300, y: 10, width: 80, height: 28))
        surface.content.addSubview(chip)
        container.layoutSubtreeIfNeeded()

        // `hitTest` takes the point in the superview's coordinates, as the window passes it.
        let onChip = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: container)
        #expect(surface.hitTest(onChip) === chip)
        let emptySpace = surface.convert(NSPoint(x: 20, y: surface.bounds.midY), to: container)
        let hit = surface.hitTest(emptySpace)
        #expect(hit === surface || hit === surface.content)
    }
}
