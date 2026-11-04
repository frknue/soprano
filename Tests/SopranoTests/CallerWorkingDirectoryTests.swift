import AppKit
import Testing
@testable import Soprano

struct CallerWorkingDirectoryTests {
    @Test func anInheritedPWDNamingAnotherDirectoryLosesToTheRealWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("caller-cwd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let child = root.appendingPathComponent("child")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)

        #expect(CallerWorkingDirectory.resolve(
            environment: ["PWD": parent.path],
            currentDirectoryPath: child.path
        ) == child.path)
        #expect(CallerWorkingDirectory.resolve(
            environment: ["PWD": alias.path],
            currentDirectoryPath: child.path
        ) == alias.path)
        #expect(CallerWorkingDirectory.resolve(
            environment: [:],
            currentDirectoryPath: child.path
        ) == child.path)
    }
}
