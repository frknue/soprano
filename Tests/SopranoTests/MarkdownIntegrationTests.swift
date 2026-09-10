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

    @Test func markdownCommandsReuseAReaderTabInTheCallingPaneAndPreserveTheTerminal() throws {
        let manager = AgentManager()
        let ownerPaneId = manager.activePaneId
        let terminalTabId = try #require(manager.panes[ownerPaneId]?.activeTab?.id)
        let originalLayout = manager.layout
        let firstURL = URL(fileURLWithPath: "/tmp/project/README.md")
        let readerPaneId = try MarkdownCommandController.open(
            MarkdownCommandRequest(fileURL: firstURL, opensNewPane: false),
            callerPaneId: ownerPaneId,
            callerTabId: terminalTabId,
            using: manager
        )
        let readerTab = try #require(manager.panes[readerPaneId]?.activeTab)

        #expect(readerPaneId == ownerPaneId)
        #expect(manager.layout == originalLayout)
        #expect(manager.windows.count == 1)
        #expect(manager.panes[ownerPaneId]?.tabs.map(\.id) == [terminalTabId, readerTab.id])
        #expect(readerTab.isMarkdown)
        #expect(readerTab.previewOwnerPaneId == ownerPaneId)
        #expect(readerTab.url == firstURL.absoluteString)
        #expect(
            manager.markdownPreviewTarget(ownerPaneId: ownerPaneId)
                == TerminalTarget(paneId: readerPaneId, tabId: readerTab.id)
        )

        let secondURL = URL(fileURLWithPath: "/tmp/project/docs/design.md")
        manager.focusTab(paneId: ownerPaneId, tabId: terminalTabId)
        _ = try MarkdownCommandController.open(
            MarkdownCommandRequest(fileURL: secondURL, opensNewPane: false),
            callerPaneId: ownerPaneId,
            callerTabId: terminalTabId,
            using: manager
        )
        let updated = try #require(manager.panes[readerPaneId]?.activeTab)
        #expect(updated.id == readerTab.id)
        #expect(manager.panes[ownerPaneId]?.tabs.count == 2)
        #expect(manager.layout == originalLayout)
        #expect(updated.url == secondURL.absoluteString)
        #expect(updated.title == "design.md")
        #expect(updated.cwd == "/tmp/project/docs")

        manager.removeTabFromPane(ownerPaneId, tabId: readerTab.id)
        #expect(manager.activePaneId == ownerPaneId)
        #expect(manager.panes[ownerPaneId]?.activeTab?.id == terminalTabId)
        #expect(manager.panes[ownerPaneId]?.activeTab?.type == .terminal)
        #expect(manager.layout == originalLayout)
    }

    @Test func markdownReaderMetadataRoundTripsWithoutAddingANewPaneType() throws {
        let source = AgentManager()
        let ownerPaneId = source.activePaneId
        let terminalTabId = try #require(source.panes[ownerPaneId]?.activeTab?.id)
        let fileURL = URL(fileURLWithPath: "/tmp/project/README.md")
        let readerTabId = try #require(
            source.previewMarkdown(fileURL: fileURL, in: ownerPaneId)
        )

        let restored = AgentManager()
        restored.restoreWorkspace(source.snapshotWorkspace())
        let tab = try #require(restored.panes[ownerPaneId]?.activeTab)

        #expect(tab.id == readerTabId)
        #expect(tab.type == .browser)
        #expect(tab.isMarkdown)
        #expect(tab.url == fileURL.absoluteString)
        #expect(tab.previewOwnerPaneId == ownerPaneId)
        #expect(restored.panes[ownerPaneId]?.tabs.first?.id == terminalTabId)
        #expect(restored.previewMarkdown(fileURL: fileURL, in: ownerPaneId) == readerTabId)
        #expect(restored.panes[ownerPaneId]?.tabs.count == 2)
        #expect(restored.layout?.orderedLeafIds == [ownerPaneId])
    }

    @Test func newMarkdownCommandsStillSplitBesideTheCallerInItsOwnWindow() throws {
        let manager = AgentManager()
        let ownerWindowId = manager.activeWindowId
        let ownerPaneId = manager.activePaneId
        let terminalTabId = try #require(manager.panes[ownerPaneId]?.activeTab?.id)
        let fileURL = URL(fileURLWithPath: "/tmp/project/README.md")
        let previewTabId = try #require(manager.previewMarkdown(fileURL: fileURL, in: ownerPaneId))
        let otherWindowId = try #require(manager.createWindow())
        let otherLayout = manager.layout

        let newPaneId = try MarkdownCommandController.open(
            MarkdownCommandRequest(fileURL: fileURL, opensNewPane: true),
            callerPaneId: ownerPaneId,
            callerTabId: terminalTabId,
            using: manager
        )

        #expect(newPaneId != ownerPaneId)
        #expect(manager.activeWindowId == ownerWindowId)
        #expect(manager.layout?.orderedLeafIds == [ownerPaneId, newPaneId])
        #expect(manager.panes[newPaneId]?.activeTab?.isMarkdown == true)
        #expect(manager.panes[newPaneId]?.activeTab?.previewOwnerPaneId == nil)
        #expect(manager.markdownPreviewTarget(ownerPaneId: ownerPaneId)?.tabId == previewTabId)
        #expect(manager.windows[otherWindowId]?.visibleLayout == otherLayout)
    }

    @Test func markdownCommandsRevealTheCallingDepthPaneEvenWhenAnotherWindowIsActive() throws {
        let manager = AgentManager()
        let ownerWindowId = manager.activeWindowId
        let rootPaneId = manager.activePaneId
        let siblingPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: rootPaneId))
        let terminalTabId = try #require(manager.goIn(rootPaneId))
        let ownerPaneId = manager.activePaneId
        let originalLayout = manager.layout
        #expect(manager.goOut(ownerPaneId))
        let otherWindowId = try #require(manager.createWindow())
        let otherLayout = manager.layout

        let paneId = try MarkdownCommandController.open(
            MarkdownCommandRequest(
                fileURL: URL(fileURLWithPath: "/tmp/project/README.md"),
                opensNewPane: false
            ),
            callerPaneId: ownerPaneId,
            callerTabId: terminalTabId,
            using: manager
        )

        #expect(paneId == ownerPaneId)
        #expect(manager.activeWindowId == ownerWindowId)
        #expect(manager.activePaneId == ownerPaneId)
        #expect(manager.activeDepth == 1)
        #expect(manager.layout == originalLayout)
        #expect(manager.panes[siblingPaneId]?.tabs.count == 1)
        #expect(manager.windows[otherWindowId]?.visibleLayout == otherLayout)
    }

    @Test func markdownPreviewKeepsTheCallingPaneMaximized() throws {
        let manager = AgentManager()
        let ownerPaneId = manager.activePaneId
        let terminalTabId = try #require(manager.panes[ownerPaneId]?.activeTab?.id)
        _ = try #require(manager.splitPane(direction: .horizontal, paneId: ownerPaneId))
        manager.focusPane(ownerPaneId)
        manager.toggleMaximize()
        let originalLayout = manager.layout
        let request = MarkdownCommandRequest(
            fileURL: URL(fileURLWithPath: "/tmp/project/README.md"),
            opensNewPane: false
        )

        for _ in 0..<2 {
            _ = try MarkdownCommandController.open(
                request,
                callerPaneId: ownerPaneId,
                callerTabId: terminalTabId,
                using: manager
            )
            #expect(manager.maximizedPaneId == ownerPaneId)
            #expect(manager.layout == originalLayout)
        }
    }

    @Test func markdownPreviewsUseTabCapacityAndCanReuseAReaderWhenThePaneIsFull() throws {
        let manager = AgentManager()
        let ownerPaneId = manager.activePaneId
        let fileURL = URL(fileURLWithPath: "/tmp/project/README.md")
        for _ in 1..<AgentManager.maxPanesPerWindow {
            _ = try #require(manager.spawnTerminal())
        }
        let originalLayout = manager.layout
        let readerTabId = try #require(manager.previewMarkdown(fileURL: fileURL, in: ownerPaneId))
        for _ in 2..<PaneState.maxTabsPerPane {
            _ = try #require(manager.addTabToPane(ownerPaneId, type: .terminal))
        }
        #expect(manager.previewMarkdown(fileURL: fileURL, in: ownerPaneId) == readerTabId)
        #expect(manager.layout == originalLayout)
        #expect(manager.panes[ownerPaneId]?.tabs.count == PaneState.maxTabsPerPane)

        manager.removeTabFromPane(ownerPaneId, tabId: readerTabId)
        _ = try #require(manager.addTabToPane(ownerPaneId, type: .terminal))
        let activeTabId = manager.panes[ownerPaneId]?.activeTab?.id
        #expect(throws: MarkdownCommandError.self) {
            try MarkdownCommandController.open(
                MarkdownCommandRequest(fileURL: fileURL, opensNewPane: false),
                callerPaneId: ownerPaneId,
                callerTabId: activeTabId,
                using: manager
            )
        }
        #expect(manager.panes[ownerPaneId]?.activeTab?.id == activeTabId)
        #expect(manager.layout == originalLayout)
    }

    @Test func restoredStandalonePreviewsDoNotPullNewMarkdownCommandsOutOfTheCallingPane() throws {
        let source = AgentManager()
        let ownerPaneId = source.activePaneId
        let fileURL = URL(fileURLWithPath: "/tmp/project/README.md")
        let oldReaderPaneId = try #require(source.spawnMarkdown(
            fileURL: fileURL,
            previewOwnerPaneId: ownerPaneId
        ))
        let restored = AgentManager()
        restored.restoreWorkspace(source.snapshotWorkspace())
        let originalLayout = restored.layout

        _ = try #require(restored.previewMarkdown(fileURL: fileURL, in: ownerPaneId))

        #expect(restored.activePaneId == ownerPaneId)
        #expect(restored.markdownPreviewTarget(ownerPaneId: ownerPaneId)?.paneId == ownerPaneId)
        #expect(restored.panes[oldReaderPaneId]?.activeTab?.url == fileURL.absoluteString)
        #expect(restored.layout == originalLayout)
    }

    @Test func markdownCommandsRejectStaleCallersAndUseTheActivePaneWhenNoCallerIsSupplied() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        let originalLayout = manager.layout
        let request = MarkdownCommandRequest(
            fileURL: URL(fileURLWithPath: "/tmp/project/README.md"),
            opensNewPane: false
        )
        for (callerPaneId, callerTabId) in [("missing-pane", "tab-2"), (paneId, "missing-tab")] {
            #expect(throws: MarkdownCommandError.self) {
                try MarkdownCommandController.open(
                    request,
                    callerPaneId: callerPaneId,
                    callerTabId: callerTabId,
                    using: manager
                )
            }
            #expect(manager.panes[paneId]?.tabs.count == 1)
            #expect(manager.layout == originalLayout)
        }

        #expect(try MarkdownCommandController.open(
            request,
            callerPaneId: nil,
            callerTabId: nil,
            using: manager
        ) == paneId)
        #expect(manager.panes[paneId]?.activeTab?.isMarkdown == true)
        #expect(manager.layout == originalLayout)
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
