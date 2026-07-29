import AppKit
import Testing
@testable import Soprano

struct MarkdownIntegrationTests {
    @Test func markdownCommandResolvesCallerRelativePathsAndAcceptsTheShortAlias() throws {
        let request = try #require(try MarkdownCommandRequest.parse(
            ["soprano", "markdown", "--new", "docs/architecture.md"],
            environment: ["PWD": "/tmp/soprano-project"]
        ))
        #expect(request.fileURL.path == "/tmp/soprano-project/docs/architecture.md")
        #expect(request.opensNewPane)

        let short = try #require(try MarkdownCommandRequest.parse(
            ["soprano", "md", "README.md"],
            environment: ["PWD": "/tmp/soprano-project"]
        ))
        #expect(short.fileURL.path == "/tmp/soprano-project/README.md")
        #expect(!short.opensNewPane)

        let direct = try #require(try MarkdownCommandRequest.parse(
            ["soprano", "README.md"],
            environment: ["PWD": "/tmp/soprano-project"]
        ))
        #expect(direct.fileURL.path == "/tmp/soprano-project/README.md")
        #expect(!direct.opensNewPane)

        let directNew = try #require(try MarkdownCommandRequest.parse(
            ["soprano", "--new", "docs/design.MARKDOWN"],
            environment: ["PWD": "/tmp/soprano-project"]
        ))
        #expect(directNew.fileURL.path == "/tmp/soprano-project/docs/design.MARKDOWN")
        #expect(directNew.opensNewPane)

        #expect(try MarkdownCommandRequest.parse(
            ["soprano", "not-a-markdown-command"],
            environment: ["PWD": "/tmp/soprano-project"]
        ) == nil)
    }

    @Test func terminalOwnedMarkdownReadersCanBeFoundAndReused() throws {
        let manager = AgentManager()
        let ownerPaneId = manager.activePaneId
        let firstURL = URL(fileURLWithPath: "/tmp/project/README.md")
        let readerPaneId = try #require(
            manager.spawnMarkdown(
                fileURL: firstURL,
                previewOwnerPaneId: ownerPaneId
            )
        )
        let readerTab = try #require(manager.panes[readerPaneId]?.activeTab)

        #expect(readerTab.isMarkdown)
        #expect(readerTab.previewOwnerPaneId == ownerPaneId)
        #expect(readerTab.url == firstURL.absoluteString)
        #expect(
            manager.markdownPreviewTarget(ownerPaneId: ownerPaneId)
                == TerminalTarget(paneId: readerPaneId, tabId: readerTab.id)
        )

        let secondURL = URL(fileURLWithPath: "/tmp/project/docs/design.md")
        manager.updateMarkdownDocument(
            paneId: readerPaneId,
            tabId: readerTab.id,
            to: secondURL
        )
        let updated = try #require(manager.panes[readerPaneId]?.activeTab)
        #expect(updated.url == secondURL.absoluteString)
        #expect(updated.title == "design.md")
        #expect(updated.cwd == "/tmp/project/docs")
    }

    @Test func markdownReaderMetadataRoundTripsWithoutAddingANewPaneType() throws {
        let source = AgentManager()
        let ownerPaneId = source.activePaneId
        let fileURL = URL(fileURLWithPath: "/tmp/project/README.md")
        let paneId = try #require(
            source.spawnMarkdown(
                fileURL: fileURL,
                previewOwnerPaneId: ownerPaneId
            )
        )

        let restored = AgentManager()
        restored.restoreWorkspace(source.snapshotWorkspace())
        let tab = try #require(restored.panes[paneId]?.activeTab)

        #expect(tab.type == .browser)
        #expect(tab.isMarkdown)
        #expect(tab.url == fileURL.absoluteString)
        #expect(tab.previewOwnerPaneId == ownerPaneId)
    }

    @Test func olderSavedBrowserTabsDecodeWithoutMarkdownMetadata() throws {
        let data = Data(
            #"{"id":"tab-4","type":"browser","url":"https://example.com"}"#.utf8
        )
        let tab = try JSONDecoder().decode(
            WorkspaceSession.SavedTab.self,
            from: data
        )
        #expect(tab.contentKind == nil)
        #expect(tab.previewOwnerPaneId == nil)
    }

    @Test func markdownRenderingSupportsGFMAndEscapesDocumentProvidedHTML() {
        let html = MarkdownHTMLRenderer.render(
            """
            # Hello & Goodbye
            # Hello & Goodbye

            - [x] shipped

            | Name | State |
            | --- | ---: |
            | Reader | ready |

            <script>alert("no")</script>

            [unsafe](javascript:alert(1))
            [safe](https://example.com)

            ```html
            <button onclick="bad()">Run</button>
            ```
            """
        )

        #expect(html.contains(#"id="hello-goodbye""#))
        #expect(html.contains(#"id="hello-goodbye-1""#))
        #expect(html.contains("<table>"))
        #expect(html.contains(#"type="checkbox" disabled checked"#))
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains(#"href="javascript:"#))
        #expect(html.contains(#"href="https://example.com""#))
        #expect(html.contains("&lt;button onclick=\"bad()\"&gt;"))
        #expect(html.contains("Hello &amp; Goodbye"))
    }
}
