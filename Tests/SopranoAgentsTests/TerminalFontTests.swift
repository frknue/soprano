import AppKit
import Testing
@testable import Soprano

struct TerminalFontTests {
    @Test func jetBrainsMonoWinsOverOtherNerdFonts() {
        let families = ["MesloLGS Nerd Font Mono", "Helvetica", "JetBrainsMono Nerd Font Mono", "FiraCode Nerd Font Mono"]
        #expect(Typography.terminalFontFamily(among: families) == "JetBrainsMono Nerd Font Mono")
    }

    @Test func onlyMonoVariantsWithLettersQualify() {
        let families = ["Symbols Nerd Font Mono", "Hack Nerd Font", "Hack Nerd Font Propo", "MesloLGS Nerd Font Mono", "FiraCode Nerd Font Mono"]
        #expect(Typography.terminalFontFamily(among: families) == "FiraCode Nerd Font Mono")
    }

    @Test func powerlevel10kMesloIsUsedWhenNoMonoFamilyIsInstalled() {
        #expect(Typography.terminalFontFamily(among: ["Menlo", "MesloLGS NF", "Hack Nerd Font"]) == "MesloLGS NF")
        #expect(Typography.terminalFontFamily(among: ["MesloLGS NF", "Hack Nerd Font Mono"]) == "Hack Nerd Font Mono")
    }

    @Test func noNerdFontLeavesTheSystemMonospace() {
        #expect(Typography.terminalFontFamily(among: ["Symbols Nerd Font Mono", "Menlo", "Hack Nerd Font"]) == nil)
    }
}
