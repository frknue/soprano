import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

/// Answers "st" for every prediction, each once the test releases it; records feedback.
private final class GatedAssistant: TextAssistant, @unchecked Sendable {
    struct Feedback: Equatable {
        var text: String
        var cursor: Int
        var suggestion: String
        var accepted: Bool
    }

    private let gate: AsyncStream<Void>
    private let opener: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var received: [Feedback] = []
    var feedback: [Feedback] { lock.withLock { received } }

    init() {
        (gate, opener) = AsyncStream.makeStream(of: Void.self)
    }

    func release() { opener.yield() }
    func preferences() async -> TextAssistPreferences { TextAssistPreferences() }
    func predictWord(text: String, cursor: Int) async -> String? {
        for await _ in gate { break }
        return "st"
    }
    func wordFeedback(text: String, cursor: Int, suggestion: String, accepted: Bool) async {
        lock.withLock { received.append(Feedback(text: text, cursor: cursor, suggestion: suggestion, accepted: accepted)) }
    }
    func close() async {}
}

struct ComposerTextAssistTests {
    @MainActor
    private func typeAndAsk(_ assistant: GatedAssistant) -> (NSWindow, ComposerTextView, ComposerWordCompletion) {
        let environment = EngineEnvironment(
            drivers: [:], git: FixtureGitService(), store: InMemoryThreadStore(StoreSnapshot()),
            dataDirectory: FileManager.default.temporaryDirectory, textAssistants: [.omp: assistant]
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let textView = ComposerTextView()
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)
        let completion = ComposerWordCompletion(textView: textView, engine: AgentEngine(environment: environment))
        completion.isEnabled = true
        textView.insertText("fix te", replacementRange: textView.selectedRange())
        completion.textChanged()
        return (window, textView, completion)
    }

    @MainActor
    @Test func aPredictionAnsweredAfterTheEditorLostFocusNeverShows() async throws {
        let shown = GatedAssistant()
        let (window, textView, completion) = typeAndAsk(shown)
        shown.release()
        for _ in 0..<100 where textView.ghostText == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(textView.ghostText == "st")

        let late = GatedAssistant()
        let (lateWindow, lateView, lateCompletion) = typeAndAsk(late)
        lateWindow.makeFirstResponder(nil)
        late.release()
        try await Task.sleep(for: .milliseconds(300))
        #expect(lateView.ghostText == nil)
        _ = (window, completion, lateCompletion)
    }

    @MainActor
    @Test func typingThroughTheGhostKeepsItsRestAndTypingPastOrAcceptingItIsReported() async throws {
        let assistant = GatedAssistant()
        let (window, textView, completion) = typeAndAsk(assistant)
        assistant.release()
        for _ in 0..<100 where textView.ghostText == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(textView.ghostText == "st")

        // Typing the ghost's first letter shows its rest at once, before the provider answers.
        textView.insertText("S", replacementRange: textView.selectedRange())
        completion.textChanged()
        #expect(textView.ghostText == "t")
        // Diverging from it reports the shown ghost as typed past, for the text it was made for.
        textView.insertText("x", replacementRange: textView.selectedRange())
        completion.textChanged()
        #expect(textView.ghostText == nil)
        for _ in 0..<100 where assistant.feedback.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(assistant.feedback == [.init(text: "fix teS", cursor: 7, suggestion: "t", accepted: false)])

        let accepting = GatedAssistant()
        let (acceptWindow, acceptView, acceptCompletion) = typeAndAsk(accepting)
        accepting.release()
        for _ in 0..<100 where acceptView.ghostText == nil { try await Task.sleep(for: .milliseconds(10)) }
        acceptView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(acceptView.string == "fix test ")
        for _ in 0..<100 where accepting.feedback.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(accepting.feedback == [.init(text: "fix te", cursor: 6, suggestion: "st", accepted: true)])
        _ = (window, acceptWindow, acceptCompletion)
    }

    private func prose(_ text: String, _ word: String) -> Bool {
        let string = text as NSString
        return ComposerProse.isProse(string, range: string.range(of: word))
    }

    @Test func plainWordsAndPunctuatedOnesKeepTheirMarks() {
        #expect(prose("please fixx the bug", "fixx"))
        #expect(prose("is this teh one?", "teh"))
        #expect(prose("(seperately) done", "seperately"))
        #expect(prose("don't recieve, well-known", "recieve"))
        #expect(prose("this is **importnat** and *recieve* here", "importnat"))
        #expect(prose("this is **importnat** and *recieve* here", "recieve"))
    }

    @Test func codeSpansAndFencesLoseTheirMarks() {
        #expect(!prose("run `fixx` now", "fixx"))
        #expect(!prose("look:\n```\nlet fooo = 1\n```\nthen", "fooo"))
        #expect(!prose("open fence\n```swift\nlet barr", "barr"))
        #expect(!prose("~~~\nfoo recieve bar\n~~~\nafter", "recieve"))
        #expect(prose("`one` and twoo `three`", "twoo"))
    }

    @Test func wordsThatReadAsCodeOrReferencesLoseTheirMarks() {
        for word in ["textVeiw", "Sources/Foo.swift", "snake_casee", "--no-lsp", "/revieww", "@fiel", "h31", "foo()", "skill:prr", "https://exmple.com"] {
            #expect(ComposerProse.isCodeLike(word), "\(word)")
        }
        for word in ["Recieve", "recieve.", "\"quoted\"", "well-known", "don't", "OK"] {
            #expect(!ComposerProse.isCodeLike(word), "\(word)")
        }
    }

    @Test func aGrammarRangeTouchingCodeLosesItsMark() {
        let text = "this are textView wrong" as NSString
        #expect(!ComposerProse.isProse(text, range: text.range(of: "this are textView")))
        #expect(ComposerProse.isProse(text, range: text.range(of: "this are")))
    }

    @Test func ghostTextOnlyFollowsALetterAtTheEndOfItsLine() {
        func cursor(_ text: String, _ location: Int, length: Int = 0) -> Int? {
            ComposerWordCompletion.cursor(in: text as NSString, selection: NSRange(location: location, length: length))
        }
        #expect(cursor("fix te", 6) == 6)
        #expect(cursor("fix te\nnext", 6) == 6)
        #expect(cursor("fix te now", 6) == nil)
        #expect(cursor("fix te ", 7) == nil)
        #expect(cursor("fix te", 6, length: 2) == nil)
        #expect(cursor("", 0) == nil)
        #expect(cursor("über", 4) == 4)
        #expect(cursor("v2", 2) == nil)
    }
}
