import AppKit
import Testing
@testable import Soprano

@MainActor
struct InputFieldTests {
    @Test func returnInAnUntouchedFieldWritesNothingAndAnEditWritesOnce() {
        // Settings fields show the resolved default; Return without typing must not pin it.
        let input = InputField(value: "~/.soprano-agents/worktrees")
        var commits: [String] = []
        input.onCommit = { commits.append($0) }
        let newline = #selector(NSResponder.insertNewline(_:))

        _ = input.control(input.field, textView: NSTextView(), doCommandBy: newline)
        #expect(commits.isEmpty)

        input.stringValue = "~/worktrees"
        _ = input.control(input.field, textView: NSTextView(), doCommandBy: newline)
        #expect(commits.isEmpty)

        input.field.stringValue = "~/elsewhere"
        _ = input.control(input.field, textView: NSTextView(), doCommandBy: newline)
        _ = input.control(input.field, textView: NSTextView(), doCommandBy: newline)
        #expect(commits == ["~/elsewhere"])
    }
}
