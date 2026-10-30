import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct AccountLaunchTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sa-accounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func codexProcessesCarryTheChosenAccountsCodexHomeAndKeepTheOriginator() {
        let adjustments = ProviderLaunchAdjustments(environment: ["CODEX_HOME": "/tmp/codex-accounts/work"])
        let environment = CodexProtocol.environment(adjustments)

        #expect(environment["CODEX_HOME"] == "/tmp/codex-accounts/work")
        #expect(environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == "Soprano Agents")
        #expect(environment["PATH"] == ExecutableLocator.childEnvironment()["PATH"])
    }

    @Test func ompSpawnsPutTheAccountOverlayBeforeOmpsOwnArguments() {
        let adjustments = ProviderLaunchAdjustments(arguments: ["--config", "/tmp/omp-accounts.yml"])
        let session = OmpProtocol.sessionArguments(cwd: "/tmp/repo", approvalMode: "always-ask", model: nil, thinking: nil, resume: nil)

        #expect(adjustments.arguments(before: session) == ["--config", "/tmp/omp-accounts.yml"] + session)
        #expect(adjustments.arguments(before: OmpProtocol.probeArguments).prefix(2) == ["--config", "/tmp/omp-accounts.yml"])
        #expect(OmpProtocol.environment(adjustments) == ExecutableLocator.childEnvironment())
    }

    @Test func noAdjustmentsChangeNothing() {
        let session = OmpProtocol.sessionArguments(cwd: "/tmp/repo", approvalMode: "always-ask", model: nil, thinking: nil, resume: nil)

        #expect(ProviderLaunchAdjustments.none.arguments(before: session) == session)
        #expect(CodexProtocol.environment(.none) == ExecutableLocator.childEnvironment(overrides: CodexProtocol.originatorEnvironment))
        #expect(CodexProtocol.environment() == CodexProtocol.environment(.none))
        #expect(OmpProtocol.environment(.none) == ExecutableLocator.childEnvironment())
    }

    @Test func adjustmentsOverrideTheAppsOwnEnvironment() {
        let adjustments = ProviderLaunchAdjustments(environment: ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "other"])
        #expect(adjustments.environment(over: CodexProtocol.originatorEnvironment) == ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "other"])
    }

    @Test func theBridgeHandsCodexItsHomeAndOmpItsOverlayButLeavesClaudeAlone() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("codex-accounts/work", isDirectory: true)
        let source = directory.appendingPathComponent("dot-codex", isDirectory: true)
        let overlay = directory.appendingPathComponent("omp-accounts.yml")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "config = true\n".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "providers: {}\n".write(to: overlay, atomically: true, encoding: .utf8)
        let state = AccountLaunchState()
        state.update(codexHome: home, codexSource: source, ompOverlay: overlay)

        #expect(AccountLaunchBridge.adjustments(for: .codex, state: state) == ProviderLaunchAdjustments(environment: ["CODEX_HOME": home.path]))
        #expect(AccountLaunchBridge.adjustments(for: .omp, state: state) == ProviderLaunchAdjustments(arguments: ["--config", overlay.path]))
        #expect(AccountLaunchBridge.adjustments(for: .claude, state: state) == .none)
        // The Codex home links what the shared ~/.codex has, like Soprano's panes.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent("config.toml").path)
            == source.appendingPathComponent("config.toml").path)
    }

    @Test func withoutAChosenAccountTheBridgeChangesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AccountLaunchState()
        #expect(AccountLaunchBridge.adjustments(for: .codex, state: state) == .none)
        #expect(AccountLaunchBridge.adjustments(for: .omp, state: state) == .none)

        // An overlay omp would fail on (not written yet) is never passed.
        state.update(codexHome: nil, codexSource: directory, ompOverlay: directory.appendingPathComponent("missing.yml"))
        #expect(AccountLaunchBridge.adjustments(for: .codex, state: state) == .none)
        #expect(AccountLaunchBridge.adjustments(for: .omp, state: state) == .none)
    }
}
