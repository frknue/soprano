import AppKit
import Testing
@testable import Soprano

struct TerminalDropContentTests {
    @Test func shellEscapesCharactersThatWouldChangeACommandLine() {
        let path = "/tmp/Screen Shot [draft] #1.png"

        #expect(
            TerminalDropContent.shellEscape(path)
                == "/tmp/Screen\\ Shot\\ \\[draft\\]\\ \\#1.png"
        )
    }

    @Test func droppedFileURLsBecomeEscapedSpaceSeparatedPaths() {
        let pasteboard = NSPasteboard(name: .init("terminal-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([
            NSURL(fileURLWithPath: "/tmp/Screen Shot 1.png"),
            NSURL(fileURLWithPath: "/tmp/Screen Shot 2.png"),
        ])

        #expect(
            TerminalDropContent.text(from: pasteboard)
                == "/tmp/Screen\\ Shot\\ 1.png /tmp/Screen\\ Shot\\ 2.png"
        )
    }

    @Test func droppedPlainTextIsInsertedWithoutShellEscaping() {
        let pasteboard = NSPasteboard(name: .init("terminal-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("git status && git diff", forType: .string)

        #expect(TerminalDropContent.text(from: pasteboard) == "git status && git diff")
    }
}
