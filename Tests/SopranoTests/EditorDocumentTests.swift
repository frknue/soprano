import AppKit
import Testing
@testable import Soprano

@MainActor
struct EditorDocumentTests {
    // MARK: - Document

    @Test func editingMarksTheDocumentDirtyAndRestoringTheSavedTextCleansIt() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("note.txt")
            try Data("hello".utf8).write(to: url)
            let document = EditorDocument(url: url)
            #expect(document.content == .text)
            #expect(!document.isDirty)

            document.textStorage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "!")
            #expect(document.isDirty)

            document.textStorage.replaceCharacters(in: NSRange(location: 5, length: 1), with: "")
            #expect(!document.isDirty)
        }
    }

    @Test func savingWritesThroughASymlinkAndKeepsTheFilesPermissions() throws {
        try withTemporaryDirectory { root in
            let script = root.appendingPathComponent("run.sh")
            try Data("echo one\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let link = root.appendingPathComponent("link.sh")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)

            let document = EditorDocument(url: link)
            document.textStorage.replaceCharacters(in: NSRange(location: 5, length: 3), with: "two")
            try document.save()

            #expect(!document.isDirty)
            #expect(try String(contentsOf: script, encoding: .utf8) == "echo two\n")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == script.path)
            let permissions = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
            #expect(permissions == 0o755)
        }
    }

    @Test func aCleanDocumentFollowsTheFileWhileUnsavedEditsAreKept() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("config.yml")
            try Data("a: 1\n".utf8).write(to: url)
            let document = EditorDocument(url: url)

            try Data("a: 2\n".utf8).write(to: url)
            document.diskDidChange()
            #expect(document.textStorage.string == "a: 2\n")
            #expect(document.diskState == .inSync)

            document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# mine\n")
            try Data("a: 3\n".utf8).write(to: url)
            document.diskDidChange()
            #expect(document.textStorage.string == "# mine\na: 2\n")
            #expect(document.diskState == .changed)

            document.reloadFromDisk()
            #expect(document.textStorage.string == "a: 3\n")
            #expect(!document.isDirty)

            try FileManager.default.removeItem(at: url)
            document.diskDidChange()
            #expect(document.diskState == .deleted)
        }
    }

    @Test func onlyUTF8TextOpensAsTextImagesAsImagesAndMissingFilesAsEmpty() throws {
        try withTemporaryDirectory { root in
            let binary = root.appendingPathComponent("blob.bin")
            try Data([0x7F, 0x45, 0x00, 0x01]).write(to: binary)
            #expect(isUnavailable(EditorDocument(url: binary).content))

            let latin1 = root.appendingPathComponent("legacy.txt")
            try Data([0x63, 0x61, 0x66, 0xE9]).write(to: latin1)
            #expect(isUnavailable(EditorDocument(url: latin1).content))

            let image = root.appendingPathComponent("dot.png")
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: image)
            let imageDocument = EditorDocument(url: image)
            #expect(imageDocument.content == .image)
            #expect(imageDocument.image?.size == NSSize(width: 3, height: 2))

            let missing = EditorDocument(url: root.appendingPathComponent("gone.txt"))
            #expect(missing.content == .text)
            #expect(missing.diskState == .deleted)
            missing.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "back")
            try missing.save()
            #expect(try String(contentsOf: root.appendingPathComponent("gone.txt"), encoding: .utf8) == "back")
        }
    }

    @Test func lineNumbersCountNewlinesBeforeTheOffset() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("lines.txt")
            try Data("one\ntwo\n\nfour".utf8).write(to: url)
            let document = EditorDocument(url: url)

            #expect(document.lineCount == 4)
            #expect(document.lineNumber(at: 0) == 1)
            #expect(document.lineNumber(at: 4) == 2)
            #expect(document.lineNumber(at: 8) == 3)
            #expect(document.lineNumber(at: 13) == 4)

            document.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "zero\n")
            #expect(document.lineCount == 5)
            #expect(document.lineNumber(at: 5) == 2)
        }
    }

    // MARK: - Store

    @Test func aRebuiltViewKeepsItsDocumentWhenTheOldViewForTheSameTabGoes() throws {
        try withTemporaryDirectory { root in
            let store = EditorDocumentStore()
            var asked = 0
            store.askToSave = { _ in
                asked += 1
                return .cancel
            }
            let url = root.appendingPathComponent("main.swift")
            try Data("a".utf8).write(to: url)
            let target = TerminalTarget(paneId: "pane-1", tabId: "tab-1")
            let document = store.document(for: url)
            let oldView = NSObject()
            let newView = NSObject()
            store.attach(oldView, as: target, to: document)
            store.attach(newView, as: target, to: document)
            document.textStorage.replaceCharacters(in: NSRange(location: 1, length: 0), with: "b")

            store.detach(oldView)

            #expect(store.document(for: url) === document)
            #expect(store.hasUnsavedChanges(url))
            #expect(!store.confirmClosing([target]))
            #expect(asked == 1)
        }
    }

    @Test func aFileOverTheSizeLimitOpensAsANoteWithoutItsBytes() throws {
        try withTemporaryDirectory { root in
            let url = root.appendingPathComponent("huge.log")
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(EditorDocument.maximumTextBytes + 1))
            try handle.close()

            let document = EditorDocument(url: url)

            guard case .unavailable(let message) = document.content else {
                Issue.record("A file over the limit opened as \(document.content)")
                return
            }
            #expect(message.contains("too large"))
            #expect(document.textStorage.length == 0)
        }
    }

    @Test func closingOneOfTwoTabsShowingAnUnsavedFileDoesNotAsk() throws {
        try withTemporaryDirectory { root in
            let store = EditorDocumentStore()
            var questions: [[String]] = []
            store.askToSave = { documents in
                questions.append(documents.map(\.name))
                return .cancel
            }
            let url = root.appendingPathComponent("main.swift")
            try Data("let a = 1\n".utf8).write(to: url)
            let first = TerminalTarget(paneId: "pane-1", tabId: "tab-1")
            let second = TerminalTarget(paneId: "pane-2", tabId: "tab-2")
            let document = store.document(for: url)
            #expect(store.document(for: url) === document)
            let firstView = NSObject()
            let secondView = NSObject()
            store.attach(firstView, as: first, to: document)
            store.attach(secondView, as: second, to: document)
            document.textStorage.replaceCharacters(in: NSRange(location: 8, length: 1), with: "2")

            #expect(store.confirmClosing([first]))
            #expect(questions.isEmpty)

            #expect(!store.confirmClosing([first, second]))
            #expect(questions == [["main.swift"]])
            #expect(document.isDirty)

            store.askToSave = { _ in .discard }
            #expect(store.confirmClosing([first, second]))
            #expect(!document.isDirty)
            #expect(try String(contentsOf: url, encoding: .utf8) == "let a = 1\n")

            document.textStorage.replaceCharacters(in: NSRange(location: 8, length: 1), with: "3")
            store.askToSave = { _ in .save }
            #expect(store.confirmClosingAll())
            #expect(try String(contentsOf: url, encoding: .utf8) == "let a = 3\n")
        }
    }

    @Test func savingOverAnotherProgramsChangeAsksFirst() throws {
        try withTemporaryDirectory { root in
            let store = EditorDocumentStore()
            store.askToOverwrite = { _ in false }
            let url = root.appendingPathComponent("notes.md")
            try Data("mine".utf8).write(to: url)
            let document = store.document(for: url)
            document.textStorage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "!")
            try Data("theirs".utf8).write(to: url)

            #expect(!store.save(document))
            #expect(try String(contentsOf: url, encoding: .utf8) == "theirs")

            store.askToOverwrite = { _ in true }
            #expect(store.save(document))
            #expect(try String(contentsOf: url, encoding: .utf8) == "mine!")
        }
    }

    @Test func renamingAFolderMovesTheDocumentsInsideIt() throws {
        try withTemporaryDirectory { root in
            let store = EditorDocumentStore()
            let folder = root.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("app.ts")
            try Data("const a = 1".utf8).write(to: url)
            let document = store.document(for: url)
            let target = TerminalTarget(paneId: "pane-1", tabId: "tab-1")
            let view = NSObject()
            store.attach(view, as: target, to: document)

            let renamed = root.appendingPathComponent("lib")
            try FileManager.default.moveItem(at: folder, to: renamed)
            store.relocate(from: folder, to: renamed)

            let newURL = renamed.appendingPathComponent("app.ts")
            #expect(document.url == newURL.standardizedFileURL)
            #expect(store.document(for: newURL) === document)

            store.detach(view)
            #expect(store.document(for: newURL) !== document)
        }
    }

    // MARK: - Helpers

    private func isUnavailable(_ content: EditorDocument.Content) -> Bool {
        if case .unavailable = content { return true }
        return false
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
