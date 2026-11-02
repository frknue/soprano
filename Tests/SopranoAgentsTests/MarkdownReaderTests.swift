import AppKit
import Testing
@testable import SopranoAgents

/// Markdown file tabs: where links lead, and what the document rendering gives the reader
/// (heading anchors, image blocks).
@MainActor
struct MarkdownReaderTests {
    private static func resolve(_ destination: String, from path: String = "docs/guides/setup.md") -> MarkdownReaderLink? {
        URL(string: destination).map { MarkdownReaderLink.resolve($0, from: path) }
    }

    @Test func relativeLinksResolveAgainstTheDocumentsFolderLikeGitHub() {
        #expect(Self.resolve("deep-links.md") == .file(path: "docs/guides/deep-links.md", anchor: nil))
        #expect(Self.resolve("./deep-links.md#routes") == .file(path: "docs/guides/deep-links.md", anchor: "routes"))
        #expect(Self.resolve("../architecture.md") == .file(path: "docs/architecture.md", anchor: nil))
        #expect(Self.resolve("/Sources/App/main.swift") == .file(path: "Sources/App/main.swift", anchor: nil))
        #expect(Self.resolve("docs/guides/deep-links.md", from: "README.md") == .file(path: "docs/guides/deep-links.md", anchor: nil))
        #expect(Self.resolve("My%20Notes.md") == .file(path: "docs/guides/My Notes.md", anchor: nil))
    }

    @Test func linksNeverLeaveTheWorkspace() {
        #expect(Self.resolve("../../../secrets.md") == .blocked)
        #expect(Self.resolve("..", from: "README.md") == .blocked)
        #expect(Self.resolve("file:///etc/hosts") == .blocked)
        #expect(Self.resolve("javascript:alert(1)") == .blocked)
    }

    @Test func fragmentsStayInTheDocumentAndWebLinksGoToTheBrowser() {
        #expect(Self.resolve("#getting-started") == .anchor("getting-started"))
        #expect(Self.resolve("https://example.com/docs") == .external)
        #expect(Self.resolve("mailto:team@example.com") == .external)
    }

    @Test func documentHeadingsCarryUniqueGitHubStyleAnchors() {
        let rendering = MarkdownRenderer.render("# Sign-in flow\n\n## Setup\n\ntext\n\n## Setup\n\n### Café & Co.", style: .document)
        var anchors: [String] = []
        for piece in rendering.pieces {
            guard case let .text(text) = piece.segment else { continue }
            text.enumerateAttribute(.markdownAnchor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let anchor = value as? String { anchors.append(anchor) }
            }
        }
        #expect(anchors == ["sign-in-flow", "setup", "setup-1", "cafe-co"])
    }

    @Test func aParagraphOfOnlyImagesBecomesImageBlocksWhileInlineImagesStayText() {
        let rendering = MarkdownRenderer.render("![Login flow](images/login.png)\n![](a.png)\n\nSee ![icon](i.png) here.", style: .document)
        let images = rendering.pieces.compactMap { piece -> String? in
            if case let .image(source, alt, _) = piece.segment { return "\(alt)|\(source)" }
            return nil
        }
        #expect(images == ["Login flow|images/login.png", "|a.png"])
        #expect(rendering.plainText.contains("See icon here."))
        let chat = MarkdownRenderer.render("![Login flow](images/login.png)", style: .assistant)
        #expect(chat.pieces.allSatisfy { if case .image = $0.segment { false } else { true } })
    }

    @Test func blocksUnderADocumentHeadingSitAtTheHeadingsOwnMarginAsInSopranosReader() throws {
        let rendering = MarkdownRenderer.render("# Title\n\nIntro.\n\n## Setup\n\n```sh\nmake\n```", style: .document)
        guard case let .text(title) = rendering.pieces[0].segment else { Issue.record("expected prose"); return }
        let intro = (title.string as NSString).range(of: "Intro.")
        let style = try #require(title.attribute(.paragraphStyle, at: intro.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.paragraphSpacingBefore == 12)
        // "## Setup", its rule, then the code block 10 pt under the rule.
        guard rendering.pieces.count == 3, case .rule = rendering.pieces[1].segment, case .code = rendering.pieces[2].segment else {
            Issue.record("expected heading, rule, code")
            return
        }
        #expect(rendering.pieces[2].spacingBefore == 10)
    }

    @Test func theReaderScrollsALinkedHeadingToTheTop() {
        _ = NSApplication.shared
        let reader = MarkdownReaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        reader.layoutSubtreeIfNeeded()
        let filler = (1...40).map { "Paragraph \($0) of the guide." }.joined(separator: "\n\n")
        reader.show("# Guide\n\n\(filler)\n\n## Deep links\n\nThe end.", path: "docs/guide.md", keepScroll: false)
        #expect(reader.scrollOffset == 0)
        #expect(reader.scroll(toAnchor: "deep-links"))
        let offset = reader.scrollOffset
        #expect(offset > 500)
        #expect(!reader.scroll(toAnchor: "missing"))
        #expect(reader.scrollOffset == offset)
    }

    private static let filler = (1...40).map { "Paragraph \($0) of the guide." }.joined(separator: "\n\n")

    @Test func imagesArrivingAfterAHeadingJumpKeepThatHeadingAtTheTop() async {
        _ = NSApplication.shared
        let reader = MarkdownReaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        reader.layoutSubtreeIfNeeded()
        var loads = 0
        reader.loadImage = { _ in
            loads += 1
            return NSImage(size: NSSize(width: 200, height: 400))
        }
        reader.show("![Flow](flow.png)\n\n## Deep links\n\n\(Self.filler)", path: "docs/guide.md", keepScroll: false)
        #expect(reader.scroll(toAnchor: "deep-links"))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        #expect(await EngineHarness.eventually(timeout: .seconds(15)) {
            loads == 1 && descendants(reader).contains { ($0 as? NSImageView)?.image != nil && !$0.isHidden && $0.superview is MarkdownImageView }
        })
        let afterImages = reader.scrollOffset
        #expect(reader.scroll(toAnchor: "deep-links"))
        #expect(reader.scrollOffset == afterImages)
    }

    @Test func reRenderingKeepsTheKeyboardInTheReader() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let reader = MarkdownReaderView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        window.contentView = reader
        reader.layoutSubtreeIfNeeded()
        reader.show("# Guide\n\n\(Self.filler)", path: "docs/guide.md", keepScroll: false)
        // A click in the text: that text view holds the keyboard, and the next render removes it.
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let text = try #require(descendants(reader).compactMap { $0 as? MarkdownTextView }.first)
        window.makeFirstResponder(text)
        #expect(window.firstResponder === text)
        reader.show("# Other\n\nText.", path: "docs/other.md", keepScroll: false)
        #expect((window.firstResponder as? NSView)?.isDescendant(of: reader) == true)
    }
}
