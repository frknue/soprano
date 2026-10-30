import AppKit
import Testing
@testable import SopranoAgentsCore

struct ExecutableLocatorTests {
    private final class TempHome {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        var path: String { url.path }

        init() throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func makeFile(_ relativePath: String, executable: Bool) throws -> String {
            let file = url.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
            return file.path
        }
    }

    @Test func aGuiAppsMinimalPathStillFindsCLIsInUserToolDirectories() throws {
        let home = try TempHome()
        let codex = try home.makeFile(".local/bin/codex", executable: true)
        let claude = try home.makeFile(".bun/bin/claude", executable: true)
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        #expect(ExecutableLocator.locate("codex", environment: environment, home: home.path) == codex)
        #expect(ExecutableLocator.locate("claude", environment: environment, home: home.path) == claude)
    }

    @Test func theInheritedPathWinsAndNonExecutablesAreSkipped() throws {
        let home = try TempHome()
        try home.makeFile("first/codex", executable: false)
        let second = try home.makeFile("second/codex", executable: true)
        try home.makeFile(".local/bin/codex", executable: true)
        let environment = ["PATH": "\(home.path)/first:\(home.path)/second"]
        #expect(ExecutableLocator.locate("codex", environment: environment, home: home.path) == second)
    }

    @Test func anExplicitPathIsUsedAsIsWithTildeExpansionAndNeverFallsBack() throws {
        let home = try TempHome()
        let custom = try home.makeFile("tools/codex-nightly", executable: true)
        try home.makeFile(".local/bin/codex", executable: true)
        try home.makeFile("tools/not-exec", executable: false)
        #expect(ExecutableLocator.locate("codex", explicitPath: "~/tools/codex-nightly", environment: [:], home: home.path) == custom)
        #expect(ExecutableLocator.locate("codex", explicitPath: "~/tools/not-exec", environment: [:], home: home.path) == nil)
        #expect(ExecutableLocator.locate("codex", explicitPath: "~/tools", environment: [:], home: home.path) == nil)
        #expect(ExecutableLocator.locate("codex", explicitPath: "  ", environment: [:], home: home.path) == "\(home.path)/.local/bin/codex")
    }

    @Test func childEnvironmentsGetTheExtendedPathWithoutDuplicates() {
        let environment = ExecutableLocator.childEnvironment(
            base: ["PATH": "/usr/bin:/opt/homebrew/bin:/usr/bin", "HOME": "/Users/me"],
            home: "/Users/me",
            overrides: ["CODEX_INTERNAL_ORIGINATOR_OVERRIDE": "Soprano Agents"]
        )
        #expect(environment["PATH"] == "/usr/bin:/opt/homebrew/bin:/Users/me/.local/bin:/usr/local/bin:/Users/me/.bun/bin:/Users/me/.cargo/bin:/Users/me/.npm-global/bin")
        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] == "Soprano Agents")
    }
}
