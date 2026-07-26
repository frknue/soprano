import AppKit
import Testing
@testable import Soprano

@MainActor
struct TerminalThemeTests {
    @Test func builtInThemeCatalogIncludesTheFivePopularAdditions() {
        #expect(AppTheme.allThemes.map(\.id) == [
            "gruvbox-dark",
            "catppuccin-mocha",
            "dracula",
            "solarized-dark",
            "nord",
            "tokyo-night",
            "atom-one-dark",
        ])
    }

    @Test func everyAppThemeProducesACompleteGhosttyTerminalPalette() {
        for theme in AppTheme.allThemes {
            let lines = theme.terminalColors.ghosttyConfiguration.split(separator: "\n")

            #expect(lines.count == 21)
            #expect(lines.contains { $0.hasPrefix("background = ") })
            #expect(lines.contains { $0.hasPrefix("foreground = ") })
            #expect(lines.contains { $0.hasPrefix("cursor-color = ") })
            #expect(lines.contains { $0.hasPrefix("cursor-text = ") })
            #expect(lines.contains { $0.hasPrefix("selection-background = ") })
            for index in 0..<16 {
                #expect(lines.contains { $0.hasPrefix("palette = \(index)=") })
            }
        }
    }

    @Test func builtInTerminalThemesUseTheirDeclaredBackgroundColors() {
        #expect(
            AppTheme.gruvboxDark.terminalColors.ghosttyConfiguration
                .contains("background = 282828")
        )
        #expect(
            AppTheme.catppuccinMocha.terminalColors.ghosttyConfiguration
                .contains("background = 1e1e2e")
        )
        #expect(
            AppTheme.dracula.terminalColors.ghosttyConfiguration
                .contains("background = 282a36")
        )
        #expect(
            AppTheme.solarizedDark.terminalColors.ghosttyConfiguration
                .contains("background = 002b36")
        )
        #expect(
            AppTheme.nord.terminalColors.ghosttyConfiguration
                .contains("background = 2e3440")
        )
        #expect(
            AppTheme.tokyoNight.terminalColors.ghosttyConfiguration
                .contains("background = 1a1b26")
        )
        #expect(
            AppTheme.atomOneDark.terminalColors.ghosttyConfiguration
                .contains("background = 21252b")
        )
    }
}
