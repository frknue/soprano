import AppKit
import Testing
@testable import Soprano

/// The status bar and the usage popover color a usage figure the same way:
/// ink while there is room, yellow from 70 %, danger from 90 %.
struct AccountUsageSeverityTests {
    private let colors = AppTheme.folioPaper.colors

    @Test func usageBelowSeventyPercentStaysInk() {
        #expect(UsageSeverity.color(for: 0, colors: colors) == colors.textPrimary)
        #expect(UsageSeverity.color(for: 0.69, colors: colors) == colors.textPrimary)
    }

    @Test func usageFromSeventyPercentTurnsYellowBelowNinety() {
        #expect(UsageSeverity.color(for: 0.7, colors: colors) == colors.yellow)
        #expect(UsageSeverity.color(for: 0.89, colors: colors) == colors.yellow)
    }

    @Test func usageFromNinetyPercentTurnsDanger() {
        #expect(UsageSeverity.color(for: 0.9, colors: colors) == colors.danger)
        #expect(UsageSeverity.color(for: 0.93, colors: colors) == colors.danger)
        #expect(UsageSeverity.color(for: 1.2, colors: colors) == colors.danger)
    }
}
