import AppKit
import Testing
@testable import Soprano

@MainActor
struct ComposerAttachmentDropTests {
    @Test func foldersAndPackagesOnThePasteboardAreNeverAttached() throws {
        let root = EngineHarness.temporaryDirectory()
        let file = root.appendingPathComponent("notes.txt")
        try "hi".write(to: file, atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let package = root.appendingPathComponent("Tool.app", isDirectory: true)
        for directory in [folder, package] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ComposerAttachmentDropTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let editor = ComposerTextView()
        var attached: [[URL]] = []
        editor.onFiles = { attached.append($0) }

        pasteboard.clearContents()
        pasteboard.writeObjects([folder, file, package] as [NSURL])
        #expect(ComposerTextView.carriesAttachments(pasteboard))
        #expect(editor.consumeAttachments(from: pasteboard))
        #expect(attached.map { $0.map(\.lastPathComponent) } == [["notes.txt"]])

        pasteboard.clearContents()
        pasteboard.writeObjects([folder, package] as [NSURL])
        #expect(!ComposerTextView.carriesAttachments(pasteboard))
        #expect(!editor.consumeAttachments(from: pasteboard))
        #expect(attached.count == 1)
    }
}
