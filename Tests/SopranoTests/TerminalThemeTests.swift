import AppKit
import Testing
@testable import Soprano

@MainActor
struct TerminalThemeTests {
    @Test func builtInThemeCatalogLeadsWithFolioPaperAndInkAndKeepsTheThirdPartyIds() {
        #expect(AppTheme.allThemes.map(\.id) == [
            "folio-paper",
            "folio-ink",
            "gruvbox-dark",
            "catppuccin-mocha",
            "dracula",
            "solarized-dark",
            "nord",
            "tokyo-night",
            "atom-one-dark",
        ])
        #expect(AppTheme.options.first?.id == "folio")
        #expect(AppTheme.options.dropFirst().map(\.id) == AppTheme.allThemes.map(\.id))
    }

    @Test func folioResolvesToPaperWhenLightAndInkWhenDark() {
        #expect(AppTheme.theme(for: "folio", appearance: .light).id == "folio-paper")
        #expect(AppTheme.theme(for: "folio", appearance: .dark).id == "folio-ink")
        #expect(AppTheme.theme(for: "folio-ink", appearance: .light).id == "folio-ink")
        #expect(AppTheme.theme(for: "mission-control", appearance: .light).id == "folio-paper")
    }

    @Test func onlyFolioPaperIsLight() {
        let light = AppTheme.allThemes.filter { $0.appearance == .light }.map(\.id)
        #expect(light == ["folio-paper"])
    }

    @Test func aFolioThemeManagerReResolvesWhenTheAppearanceChanges() {
        let manager = ThemeManager(themeId: "folio", appearance: .light)
        var changes: [String] = []
        manager.onThemeChanged = { changes.append($0.id) }
        #expect(manager.currentTheme.id == "folio-paper")

        manager.setAppearance(.dark)
        #expect(manager.currentTheme.id == "folio-ink")

        manager.setTheme(id: "nord")
        manager.setAppearance(.light)
        #expect(manager.currentTheme.id == "nord")
        #expect(changes == ["folio-ink", "nord"])
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

    @Test func folioTerminalPalettesMatchTheTokens() {
        let paper = AppTheme.folioPaper.terminalColors.ghosttyConfiguration
        #expect(paper.contains("background = f6f2ea"))
        #expect(paper.contains("cursor-color = a34a17"))
        #expect(paper.contains("selection-background = e4cdbc"))
        #expect(paper.contains("palette = 7=6f665a"))
        let ink = AppTheme.folioInk.terminalColors.ghosttyConfiguration
        #expect(ink.contains("background = 1d1b18"))
        #expect(ink.contains("cursor-color = e08a52"))
        #expect(ink.contains("palette = 15=f4efe5"))
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
