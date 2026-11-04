import AppKit
import Testing
@testable import Soprano

/// Rendered chat Markdown: what its links may open, and what survives a streamed update.
@MainActor
struct MarkdownViewTests {
    /// Takes every link click NSTextView would hand to the system, so nothing opens.
    private final class LinkRecorder: NSObject, NSTextViewDelegate {
        var opened: [URL] = []
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { opened.append(url) }
            return true
        }
    }

    @Test func chatLinksOpenOnlyWebAndMailAddressesAndNeverFilesAppsOrCustomSchemes() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView()
        let recorder = LinkRecorder()
        view.delegate = recorder
        let links = [
            "https://example.com", "http://example.com", "mailto:a@example.com", "HTTPS://example.com/upper",
            "file:///Applications/Calculator.app", "x-apple.systempreferences:com.apple.preference.security",
            "javascript:alert(1)", "docs/README.md",
        ]
        for link in links {
            view.clicked(onLink: try #require(URL(string: link)), at: 0)
        }
        #expect(recorder.opened.map(\.absoluteString) == ["https://example.com", "http://example.com", "mailto:a@example.com", "HTTPS://example.com/upper"])
    }

    @Test func aStreamedUpdateKeepsTheSegmentViewsAndTheSelectionOfTheTextAboveIt() throws {
        _ = NSApplication.shared
        let view = MarkdownView(frame: .zero)
        view.apply(MarkdownRenderer.render("First paragraph.\n\n```swift\nlet a = 1\n```\n\nSecond", style: .assistant))
        view.layoutMarkdown(width: 400)
        let before = view.subviews
        let first = try #require(before.first as? MarkdownTextView)
        first.setSelectedRange(NSRange(location: 0, length: 5))

        view.apply(MarkdownRenderer.render("First paragraph.\n\n```swift\nlet a = 1\n```\n\nSecond paragraph, longer.", style: .assistant))
        view.layoutMarkdown(width: 400)

        #expect(view.subviews.count == before.count)
        #expect(zip(view.subviews, before).allSatisfy { $0 === $1 })
        #expect(first.selectedRange() == NSRange(location: 0, length: 5))
        let last = try #require(view.subviews.last as? MarkdownTextView)
        #expect(last.string == "Second paragraph, longer.")
    }

    @Test func aStreamingMessageKeepsNoCopyOfAnEarlierDeltaAlive() {
        weak var earlier: MarkdownRendering?
        weak var earlierText: NSAttributedString?
        autoreleasepool {
            let rendering = MarkdownRenderer.render("Streaming answer, delta \(UUID().uuidString)", style: .assistant, streaming: true)
            if case let .text(text) = rendering.pieces.first?.segment {
                _ = TextMeasure.height(text, width: 300)
                earlierText = text
            }
            earlier = rendering
        }
        _ = MarkdownRenderer.render("Streaming answer, the next delta \(UUID().uuidString)", style: .assistant, streaming: true)
        #expect(earlier == nil)
        #expect(earlierText == nil)
    }
}
