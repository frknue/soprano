import AppKit
import Testing
@testable import Soprano

struct TerminalTitleTests {
    private let home = "/Users/furkan"

    private func display(_ title: String, cwd: String? = nil, agent: String? = nil) -> String {
        TerminalTitle.display(title, workingDirectory: cwd, agentName: agent, home: home)
    }

    @Test func aShellsPromptTitleReadsAsTheFolderItIsIn() {
        let cwd = "/Users/furkan/git/private/soprano-cast"
        #expect(display("furkan@MacBook-Pro-3:~/git/private/soprano-cast", cwd: cwd) == "soprano-cast")
        #expect(display("…/git/private/soprano-cast", cwd: cwd) == "soprano-cast")
        #expect(display("furkan@MacBook-Pro-3", cwd: cwd) == "soprano-cast")
        #expect(display("~", cwd: home) == "~")
    }

    @Test func withoutAWorkingDirectoryThePromptsOwnPathNamesTheFolder() {
        #expect(display("furkan@MacBook-Pro-3:~/git/work/valkental-b2c-app") == "valkental-b2c-app")
        #expect(display("…/git/work/valkental-int-frontend") == "valkental-int-frontend")
        #expect(display("~/dotfiles") == "dotfiles")
    }

    @Test func aCommandsTitleIsKept() {
        #expect(display("npm run dev", cwd: "/Users/furkan/git/shop") == "npm run dev")
        #expect(display("vim SidebarView.swift", cwd: "/Users/furkan/git/shop") == "vim SidebarView.swift")
    }

    @Test func ompsBrandAndStateSeparatorGoInEveryState() {
        for title in [
            "π > MIGR: Plan Conversion",
            "π ⠋ MIGR: Plan Conversion",
            "π ! MIGR: Plan Conversion",
            "π : MIGR: Plan Conversion",
            "π: MIGR: Plan Conversion",
            "π - MIGR: Plan Conversion",
        ] {
            #expect(display(title, agent: "omp") == "MIGR: Plan Conversion", "\(title)")
        }
    }

    @Test func nerdFontIconsAreDroppedBecauseTheSystemFontCannotDrawThem() {
        #expect(display("π > \u{F04E1} MIGR: Plan Conversion", agent: "omp") == "MIGR: Plan Conversion")
        #expect(display("\u{E0A0} main", cwd: "/tmp") == "main")
    }

    @Test func claudeCodesSpinnerGlyphInFrontOfItsTaskGoes() {
        for glyph in ["✳", "✶", "✻", "✽", "✢", "·", "⠙"] {
            #expect(display("\(glyph) Fix the sidebar", agent: "Claude Code") == "Fix the sidebar", "\(glyph)")
        }
        #expect(display("🚀\u{FE0F} Deploy", cwd: "/tmp") == "Deploy")
    }

    @Test func anAgentWithoutATaskTitleIsCalledByItsName() {
        #expect(display("π >", agent: "omp") == "omp")
        #expect(display("omp", agent: "omp") == "omp")
        #expect(display("Codex: soprano", cwd: "/Users/furkan/git/soprano", agent: "Codex") == "Codex")
        // The placeholder keeps the folder the agent started in.
        #expect(display("Codex: soprano", cwd: "/Users/furkan/git/soprano/Sources", agent: "Codex") == "Codex")
        #expect(display("Codex: fix the build", agent: "Codex") == "Codex: fix the build")
        // The shell's title lingers until an agent typed into it titles itself.
        #expect(display("furkan@MacBook-Pro-3:~/git/soprano", cwd: "/Users/furkan/git/soprano", agent: "omp") == "omp")
    }

    @Test func aWordThatStartsWithPiIsNotOmpsBrand() {
        #expect(display("πr² calculator", cwd: "/tmp") == "πr² calculator")
    }

    @Test func aPathTitleNotAtTheHomeFolderIsNotNamedTilde() {
        #expect(TerminalTitle.folderName("/Users/furkan/", home: home) == "~")
        #expect(TerminalTitle.folderName("/", home: home) == "/")
        #expect(TerminalTitle.folderName("/Users/furkan/git/", home: home) == "git")
    }
}
