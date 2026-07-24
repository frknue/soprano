import Testing
@testable import Soprano

struct BrowserIntegrationTests {
    @Test func browserAddressesPreferHTTPForLocalDevelopment() throws {
        #expect(
            BrowserAddressResolver.resolve("localhost:5173")?.absoluteString
                == "http://localhost:5173"
        )
        #expect(
            BrowserAddressResolver.resolve("127.0.0.1:3000/app")?.absoluteString
                == "http://127.0.0.1:3000/app"
        )
        #expect(
            BrowserAddressResolver.resolve("example.com/docs")?.absoluteString
                == "https://example.com/docs"
        )
        #expect(
            try #require(BrowserAddressResolver.resolve("swift appkit browser"))
                .absoluteString
                .contains("duckduckgo.com/?q=swift%20appkit%20browser")
        )
    }

    @Test func browserCommandParserAcceptsPaneTargetAndNormalizesScreenshotPath() throws {
        let targeted = try #require(try BrowserCommandRequest.parse(
            ["soprano", "browser", "--pane", "pane-8", "click", "@e2"]
        ))
        #expect(targeted == BrowserCommandRequest(
            command: "click",
            arguments: ["@e2"],
            targetPaneId: "pane-8"
        ))

        let screenshot = try #require(try BrowserCommandRequest.parse(
            ["soprano", "browser", "screenshot", "artifacts/page.png"],
            environment: ["PWD": "/tmp/browser-project"]
        ))
        #expect(screenshot.arguments == ["/tmp/browser-project/artifacts/page.png"])
    }

    @Test func browserPaneSpawnsToTheRightAndPreservesItsURLWhenSplit() throws {
        let manager = AgentManager()
        let browserPaneId = try #require(
            manager.spawnBrowser(url: "http://localhost:4173")
        )
        let browserTab = try #require(manager.panes[browserPaneId]?.activeTab)

        #expect(browserTab.type == .browser)
        #expect(browserTab.url == "http://localhost:4173")
        #expect(manager.layout?.orderedLeafIds == ["pane-1", browserPaneId])
        #expect(manager.activePaneId == browserPaneId)

        let splitPaneId = try #require(
            manager.splitPane(direction: .vertical, paneId: browserPaneId)
        )
        let splitTab = try #require(manager.panes[splitPaneId]?.activeTab)
        #expect(splitTab.type == .browser)
        #expect(splitTab.url == browserTab.url)
    }

    @Test func browserURLAndTypeRoundTripThroughWorkspacePersistence() throws {
        let source = AgentManager()
        let paneId = try #require(source.spawnBrowser(url: "https://example.com/first"))
        let tabId = try #require(source.panes[paneId]?.activeTab?.id)
        source.updateBrowserURL(
            paneId: paneId,
            tabId: tabId,
            to: "https://example.com/restored"
        )
        source.renameTab(paneId, tabId: tabId, to: "Example")

        let restored = AgentManager()
        restored.restoreWorkspace(source.snapshotWorkspace())
        let tab = try #require(restored.panes[paneId]?.activeTab)

        #expect(tab.type == .browser)
        #expect(tab.url == "https://example.com/restored")
        #expect(tab.title == "Example")
    }

    @Test func savedKeybindingConfigurationsGainTheBrowserShortcut() throws {
        var saved = DefaultKeybindings.config
        saved.bindings.removeAll { $0.id == "new-browser" }

        let merged = DefaultKeybindings.mergedConfig(with: saved)
        let browser = try #require(merged.bindings.first { $0.id == "new-browser" })

        #expect(browser.key == "b")
        #expect(browser.meta == true)
        #expect(browser.defaultKeys == "⌘B")
    }
}
