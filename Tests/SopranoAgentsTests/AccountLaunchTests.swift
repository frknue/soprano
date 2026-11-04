import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

struct AccountLaunchTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sa-accounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
        #expect(OmpProtocol.environment(.none) == ExecutableLocator.childEnvironment())
    }

    @Test func adjustmentsOverrideTheAppsOwnEnvironment() {
        let adjustments = ProviderLaunchAdjustments(environment: ["SOPRANO_EXAMPLE": "other"])
        #expect(adjustments.environment(over: ["SOPRANO_EXAMPLE": "app", "KEEP": "yes"]) == ["SOPRANO_EXAMPLE": "other", "KEEP": "yes"])
    }

    @Test func theBridgeHandsOmpItsOverlay() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let overlay = directory.appendingPathComponent("omp-accounts.yml")
        try "providers: {}\n".write(to: overlay, atomically: true, encoding: .utf8)
        let state = AccountLaunchState()
        state.update(codexHome: nil, codexSource: directory, ompOverlay: overlay)

        #expect(AccountLaunchBridge.ompAdjustments(state: state) == ProviderLaunchAdjustments(arguments: ["--config", overlay.path]))
    }

    @Test func withoutAnOverlayTheBridgeChangesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AccountLaunchState()
        #expect(AccountLaunchBridge.ompAdjustments(state: state) == .none)

        // An overlay omp would fail on (not written yet) is never passed.
        state.update(codexHome: nil, codexSource: directory, ompOverlay: directory.appendingPathComponent("missing.yml"))
        #expect(AccountLaunchBridge.ompAdjustments(state: state) == .none)
    }
}
