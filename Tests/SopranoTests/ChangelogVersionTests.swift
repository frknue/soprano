import AppKit
import Testing
@testable import Soprano

/// Guards the release workflow described in `AGENTS.md`: the newest released heading in
/// `CHANGELOG.md` and the version declared in `Support/Info.plist` have to move together,
/// and `Support/Info.plist` stays the only place the number is written down.
struct ChangelogVersionTests {
    @Test func theNewestReleasedChangelogHeadingMatchesTheDeclaredBundleVersion() throws {
        let declared = try #require(try infoPlist()["CFBundleShortVersionString"] as? String)

        #expect(try latestReleasedChangelogVersion() == declared)
    }

    @Test func theBundleBuildNumberTracksTheMarketingVersion() throws {
        let info = try infoPlist()

        #expect(info["CFBundleVersion"] as? String == info["CFBundleShortVersionString"] as? String)
    }

    @Test func theChangelogKeepsAnUnreleasedSectionForFinishedButUnshippedWork() throws {
        #expect(try changelogLines().contains("## [Unreleased]"))
    }

    @Test func theAboutTabReportsWhateverVersionThePackagedBundleDeclares() throws {
        let info = try infoPlist()

        #expect(AppVersion.resolve(from: info) == info["CFBundleShortVersionString"] as? String)
    }

    // MARK: - Repository files

    /// `Tests/SopranoTests/ChangelogVersionTests.swift` → repository root.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func infoPlist() throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("Support/Info.plist")
        let contents = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url),
            format: nil
        )

        return try #require(contents as? [String: Any])
    }

    private func changelogLines() throws -> [Substring] {
        let url = repositoryRoot.appendingPathComponent("CHANGELOG.md")

        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    }

    /// Version from the first `## [X.Y.Z] - date` heading below `## [Unreleased]`.
    private func latestReleasedChangelogVersion() throws -> String {
        let heading = try #require(
            changelogLines().first { $0.hasPrefix("## [") && $0 != "## [Unreleased]" }
        )

        return String(heading.dropFirst("## [".count).prefix { $0 != "]" })
    }
}
