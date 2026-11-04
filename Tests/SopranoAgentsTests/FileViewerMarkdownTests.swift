import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

/// Markdown file tabs in the file viewer: links between files land on the linked heading.
@MainActor
struct FileViewerMarkdownTests {
    private struct Files: WorkspaceFileService {
        static let guide = "# Guide\n\n" + (1...40).map { "Paragraph \($0) of the guide." }.joined(separator: "\n\n")
            + "\n\n## Deep links\n\nThe end."
        static let readme = "# App\n\nSee [deep links](docs/guide.md#deep-links)."
        /// Just over the reader's limit.
        static let huge = String(repeating: "Line of a long changelog.\n\n", count: FileViewerViewController.maximumPreviewBytes / 27 + 1)

        func listFiles(root: String) async throws -> [String] { ["README.md", "docs/guide.md", "HUGE.md"] }

        func readFile(root: String, relativePath: String) async throws -> WorkspaceFileContent {
            switch relativePath {
            case "README.md": .text(Self.readme)
            case "HUGE.md": .text(Self.huge)
            default: .text(Self.guide)
            }
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func reader(in view: NSView) -> MarkdownReaderView? {
        descendants(view).lazy.compactMap { $0 as? MarkdownReaderView }.first { !$0.isHidden }
    }

    private static func makeViewer() -> (FileViewerViewController, WorkspaceState) {
        _ = NSApplication.shared
        let engine = AgentEngine(environment: EngineEnvironment(
            drivers: [:],
            git: RecordingGit(),
            store: InMemoryThreadStore(),
            dataDirectory: EngineHarness.temporaryDirectory(),
            files: Files()
        ))
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let state = WorkspaceState()
        let viewer = FileViewerViewController(engine: engine, state: state)
        viewer.view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        state.select(.draft(projectID: project.id))
        return (viewer, state)
    }

    @Test func aMarkdownFileTooLargeForTheReaderOpensAsSourceWithoutPreview() async throws {
        let (viewer, state) = Self.makeViewer()
        state.showRightPanel(.file("HUGE.md"))
        #expect(Files.huge.utf8.count > FileViewerViewController.maximumPreviewBytes)
        #expect(await EngineHarness.eventually(timeout: .seconds(15)) {
            Self.descendants(viewer.view).contains { type(of: $0) == NSTextView.self && ($0 as? NSTextView)?.string == Files.huge }
        })
        #expect(Self.reader(in: viewer.view) == nil)
        #expect(!viewer.showsMarkdownFile)
        viewer.toggleMarkdownPreview()
        #expect(Self.reader(in: viewer.view) == nil)
    }

    @Test func aLinkToAHeadingOpensItsFileInTheReaderEvenWhenThatTabShowedItsSource() async throws {
        let (viewer, state) = Self.makeViewer()

        // The guide's tab shows its source.
        state.showRightPanel(.file("docs/guide.md"))
        #expect(await EngineHarness.eventually(timeout: .seconds(15)) { Self.reader(in: viewer.view) != nil })
        viewer.toggleMarkdownPreview()
        #expect(Self.reader(in: viewer.view) == nil)

        // The README links to the guide's heading.
        state.showRightPanel(.file("README.md"))
        #expect(await EngineHarness.eventually(timeout: .seconds(15)) { Self.reader(in: viewer.view) != nil })
        let readme = try #require(Self.reader(in: viewer.view))
        let text = try #require(Self.descendants(readme).compactMap { $0 as? MarkdownTextView }.first)
        let link = (text.string as NSString).range(of: "deep links")
        text.clicked(onLink: try #require(URL(string: "docs/guide.md#deep-links")), at: link.location)

        #expect(await EngineHarness.eventually(timeout: .seconds(15)) { state.rightPanelSurface == .file("docs/guide.md") })
        let guide = try #require(Self.reader(in: viewer.view))
        #expect(guide.path == "docs/guide.md")
        #expect(guide.scrollOffset > 500)
    }

    @Test func followingALinkFromTheReadersTextKeepsTheKeyboardInTheViewerWhileTheTargetLoads() async throws {
        let (viewer, state) = Self.makeViewer()
        let window = NSWindow(contentRect: viewer.view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = viewer.view
        state.showRightPanel(.file("README.md"))
        #expect(await EngineHarness.eventually(timeout: .seconds(15)) { Self.reader(in: viewer.view) != nil })
        let readme = try #require(Self.reader(in: viewer.view))
        let text = try #require(Self.descendants(readme).compactMap { $0 as? MarkdownTextView }.first)
        window.makeFirstResponder(text)
        func viewerHasFocus() -> Bool { (window.firstResponder as? NSView)?.isDescendant(of: viewer.view) == true }
        #expect(viewerHasFocus())

        // docs/guide.md was never opened: its tab shows "Loading…" first.
        let link = (text.string as NSString).range(of: "deep links")
        text.clicked(onLink: try #require(URL(string: "docs/guide.md#deep-links")), at: link.location)
        #expect(await EngineHarness.eventually(timeout: .seconds(15)) { state.rightPanelSurface == .file("docs/guide.md") })
        #expect(viewerHasFocus())
        #expect(await EngineHarness.eventually(timeout: .seconds(15)) { Self.reader(in: viewer.view)?.path == "docs/guide.md" })
        #expect(viewerHasFocus())
        #expect((window.firstResponder as? NSView)?.isDescendant(of: try #require(Self.reader(in: viewer.view))) == true)

        // Source and back: the keyboard follows to the visible view each time.
        func visibleFocus() -> Bool { viewerHasFocus() && (window.firstResponder as? NSView)?.isHiddenOrHasHiddenAncestor == false }
        viewer.toggleMarkdownPreview()
        #expect(Self.reader(in: viewer.view) == nil)
        #expect(visibleFocus())
        viewer.toggleMarkdownPreview()
        #expect(visibleFocus())
    }
}
