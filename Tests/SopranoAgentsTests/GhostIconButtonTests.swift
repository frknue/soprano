import AppKit
import Testing
@testable import SopranoAgents

@MainActor
struct GhostIconButtonTests {
    @Test func aRestingFillComesBackAfterTheHoverEnds() {
        let button = GhostIconButton(symbol: Icon.close, size: 18, symbolSize: 8)
        let backdrop = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.85)
        button.restingFill = backdrop

        button.setHoveredForTesting(true)
        #expect(button.layer?.backgroundColor == button.palette.accent.cgColor)
        button.setHoveredForTesting(false)

        #expect(button.layer?.backgroundColor == backdrop.cgColor)
    }

    @Test func anOnButtonKeepsItsOnFillWhileHoveredAndAfter() {
        let button = GhostIconButton(symbol: Icon.close, size: 24, symbolSize: 11)
        let selected = NSColor(srgbRed: 0.9, green: 0.8, blue: 0.7, alpha: 1)
        button.onFill = selected
        button.isOn = true

        button.setHoveredForTesting(true)
        #expect(button.layer?.backgroundColor == selected.cgColor)
        button.setHoveredForTesting(false)

        #expect(button.layer?.backgroundColor == selected.cgColor)
    }
}
