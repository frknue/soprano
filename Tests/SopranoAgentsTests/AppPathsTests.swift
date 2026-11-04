import AppKit
import Testing
@testable import Soprano

struct AppPathsTests {
    @Test func installedSopranoKeepsTheFolderTheStandaloneAppStoredThreadsIn() {
        let directory = AppPaths.dataDirectory(environment: [:], bundleIdentifier: "com.soprano.app")
        #expect(directory.lastPathComponent == "Soprano Agents")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Application Support")
    }

    @Test func everyOtherBuildUsesTheDevelopmentFolderSoItNeverTouchesRealThreads() {
        for identifier in ["com.soprano.dev", nil] {
            let directory = AppPaths.dataDirectory(environment: [:], bundleIdentifier: identifier)
            #expect(directory.lastPathComponent == "Soprano Agents Dev", "\(identifier ?? "unbundled")")
        }
    }

    @Test func anAbsoluteOverrideWinsAndARelativeOneIsIgnored() {
        let override = AppPaths.dataDirectory(
            environment: ["SOPRANO_AGENTS_DATA_DIR": "/tmp/agents-data"],
            bundleIdentifier: "com.soprano.app"
        )
        #expect(override.path == "/tmp/agents-data")

        let relative = AppPaths.dataDirectory(
            environment: ["SOPRANO_AGENTS_DATA_DIR": "agents-data"],
            bundleIdentifier: "com.soprano.app"
        )
        #expect(relative.lastPathComponent == "Soprano Agents")
    }
}
