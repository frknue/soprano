import AppKit
import Testing
@testable import Soprano

struct AccountLaunchTests {
    private func makeState() throws -> (state: AccountLaunchState, home: URL, overlay: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-launch-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("dot-codex", isDirectory: true)
        let home = root.appendingPathComponent("account/home", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("model = \"x\"".utf8).write(to: source.appendingPathComponent("config.toml"))
        let overlay = root.appendingPathComponent("omp-accounts.yml")
        let state = AccountLaunchState()
        state.update(codexHome: home, codexSource: source, ompOverlay: overlay)
        return (state, home, overlay, root)
    }

    private func profile(_ id: String) -> AgentProfile {
        DefaultAgents.profile(for: id)!
    }

    @Test func aCodexPaneStartsInTheChosenAccountsHomeEvenIfTheShellProfileSetsAnother() throws {
        let (state, home, _, root) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }

        let config = TerminalConfig.forAgent(profile("codex"), paneId: "p", tabId: "t", accounts: state)

        #expect(config.env["CODEX_HOME"] == home.path)
        // Exported again inside the -lic script, after the rc files ran.
        let command = try #require(config.command)
        #expect(command.contains("export CODEX_HOME="))
        // The home was linked up on the way, so codex finds the shared config.
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("config.toml").path))
    }

    @Test func anOmpPaneLoadsThePreferenceOverlayOnlyOnceItExists() throws {
        let (state, _, overlay, root) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = TerminalConfig.forAgent(profile("omp"), paneId: "p", tabId: "t", accounts: state)
        #expect(before.command?.contains("--config") == false)

        try Data("{}\n".utf8).write(to: overlay)
        let after = TerminalConfig.forAgent(profile("omp"), paneId: "p", tabId: "t", accounts: state)
        let command = try #require(after.command)
        #expect(command.contains("--config"))
        #expect(command.contains(overlay.path))
    }

    @Test func otherAgentsStartUntouchedByAccountChoices() throws {
        let (state, _, overlay, root) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}\n".utf8).write(to: overlay)

        let config = TerminalConfig.forAgent(profile("claude-code"), paneId: "p", tabId: "t", accounts: state)

        let command = try #require(config.command)
        #expect(!command.contains("--config"))
        #expect(!command.contains("export "))
        #expect(config.env["CODEX_HOME"] == nil)
    }
}
