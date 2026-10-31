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
        let omp = try home.makeFile(".bun/bin/omp", executable: true)
        let node = try home.makeFile(".local/bin/node", executable: true)
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        #expect(ExecutableLocator.locate("omp", environment: environment, home: home.path) == omp)
        #expect(ExecutableLocator.locate("node", environment: environment, home: home.path) == node)
    }

    @Test func theInheritedPathWinsAndNonExecutablesAreSkipped() throws {
        let home = try TempHome()
        try home.makeFile("first/omp", executable: false)
        let second = try home.makeFile("second/omp", executable: true)
        try home.makeFile(".local/bin/omp", executable: true)
        let environment = ["PATH": "\(home.path)/first:\(home.path)/second"]
        #expect(ExecutableLocator.locate("omp", environment: environment, home: home.path) == second)
    }

    @Test func anExplicitPathIsUsedAsIsWithTildeExpansionAndNeverFallsBack() throws {
        let home = try TempHome()
        let custom = try home.makeFile("tools/omp-nightly", executable: true)
        try home.makeFile(".local/bin/omp", executable: true)
        try home.makeFile("tools/not-exec", executable: false)
        #expect(ExecutableLocator.locate("omp", explicitPath: "~/tools/omp-nightly", environment: [:], home: home.path) == custom)
        #expect(ExecutableLocator.locate("omp", explicitPath: "~/tools/not-exec", environment: [:], home: home.path) == nil)
        #expect(ExecutableLocator.locate("omp", explicitPath: "~/tools", environment: [:], home: home.path) == nil)
        #expect(ExecutableLocator.locate("omp", explicitPath: "  ", environment: [:], home: home.path) == "\(home.path)/.local/bin/omp")
    }

    @Test func childEnvironmentsGetTheExtendedPathWithoutDuplicates() {
        let environment = ExecutableLocator.childEnvironment(
            base: ["PATH": "/usr/bin:/opt/homebrew/bin:/usr/bin", "HOME": "/Users/me"],
            home: "/Users/me",
            overrides: ["SOPRANO_TEST_OVERRIDE": "Soprano Agents"]
        )
        #expect(environment["PATH"] == "/usr/bin:/opt/homebrew/bin:/Users/me/.local/bin:/usr/local/bin:/Users/me/.bun/bin:/Users/me/.cargo/bin:/Users/me/.npm-global/bin")
        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["SOPRANO_TEST_OVERRIDE"] == "Soprano Agents")
    }
}
