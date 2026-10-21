import AppKit
import Testing
@testable import Soprano

struct GraphLaneTests {
    @Test func everyThemeHasEightPairwiseDistinctLanesWithAGraphiteTrunkAndNoAccent() {
        for theme in AppTheme.allThemes {
            let lanes = theme.graphLanes
            #expect(lanes.count == 8, "\(theme.id)")
            #expect(lanes.first == theme.colors.textMuted, "\(theme.id) trunk")
            for (index, lane) in lanes.enumerated() {
                #expect(
                    lane.labDistance(to: theme.colors.accent) >= AppTheme.minimumLaneDistance,
                    "\(theme.id) lane \(index) reads as the accent"
                )
                for other in lanes.indices where other > index {
                    #expect(
                        lane.labDistance(to: lanes[other]) >= AppTheme.minimumLaneDistance,
                        "\(theme.id) lanes \(index) and \(other) read as one color"
                    )
                }
            }
        }
    }

    @Test func folioKeepsTheSpecifiedLaneOrder() {
        for theme in [AppTheme.folioPaper, AppTheme.folioInk] {
            let terminal = theme.terminalColors
            #expect(theme.graphLanes == [
                theme.colors.textMuted,
                theme.colors.blue,
                theme.colors.success,
                terminal.magenta,
                theme.colors.cyan,
                theme.colors.yellow,
                terminal.brightMagenta,
                terminal.brightBlue,
            ])
        }
    }

    @Test func nordSkipsItsRepeatedBluesAndPurplesAndItsAccentCyan() {
        let lanes = AppTheme.nord.graphLanes
        let hexes = lanes.map(Self.hex)
        #expect(Set(hexes).count == 8)
        #expect(!hexes.contains(Self.hex(AppTheme.nord.colors.accent)))
    }

    private static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(
            format: "%02x%02x%02x",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
