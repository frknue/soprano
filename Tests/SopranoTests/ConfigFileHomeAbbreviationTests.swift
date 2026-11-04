import AppKit
import Testing
@testable import Soprano

struct ConfigFileHomeAbbreviationTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    @Test func homeAndPathsInsideItBecomeTildeRelative() {
        #expect(ConfigFile.abbreviatingHome(home) == "~")
        #expect(ConfigFile.abbreviatingHome(home + "/git") == "~/git")
    }

    @Test func aSiblingDirectorySharingTheHomeNamePrefixStaysAbsolute() {
        #expect(ConfigFile.abbreviatingHome(home + "2/git") == home + "2/git")
        #expect(ConfigFile.abbreviatingHome("/tmp/x") == "/tmp/x")
    }
}
