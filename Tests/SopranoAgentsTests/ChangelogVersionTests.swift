import AppKit
import Testing
@testable import SopranoAgents

struct ChangelogVersionTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Support/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    private static func changelog() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    }

    @Test func bundleVersionAndShortVersionStringAgree() throws {
        let info = try Self.infoPlist()
        let short = try #require(info["CFBundleShortVersionString"] as? String)
        #expect(info["CFBundleVersion"] as? String == short)
    }

    @Test func changelogKeepsAnUnreleasedSection() throws {
        #expect(try Self.changelog().contains("\n## [Unreleased]\n"))
    }

    @Test func newestReleasedHeadingMatchesTheBundleVersionOnceAReleaseExists() throws {
        let short = try #require(try Self.infoPlist()["CFBundleShortVersionString"] as? String)
        let released = try Self.changelog()
            .split(separator: "\n")
            .first { $0.hasPrefix("## [") && !$0.hasPrefix("## [Unreleased]") }
        guard let released else { return }
        #expect(released.hasPrefix("## [\(short)] - "))
    }

    @Test func appVersionReadsTheBundleVersion() throws {
        let info = try Self.infoPlist()
        #expect(AppVersion.resolve(from: info) == info["CFBundleShortVersionString"] as? String)
    }
}
