import AppKit
import Testing
@testable import Soprano

private let oneAutomation = """
{ "audit": { "name": "Weekday repo audit", "agent": "omp", "folder": "$FOLDER",
  "prompt": "Review the repository health and summarize what needs attention.",
  "schedule": "0 9 * * 1-5", "precheck": "gh pr list --json number -q '.[0].number'" } }
"""

/// The Automations page covers the workspace inside the window as it is; it
/// must never make the window grow or shrink to fit itself.
@MainActor
struct AutomationsPageTests {
    private func makeController(automations: String) throws -> (AutomationController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-automations-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configStore = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        try ConfigFile.write(
            "{ \"automations\": \(automations.replacingOccurrences(of: "$FOLDER", with: directory.path)) }",
            to: configStore.fileURL
        )
        configStore.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)
        let controller = AutomationController(
            store: AutomationStore(fileURL: nil),
            agentManager: AgentManager(),
            configStore: configStore,
            environment: .init(
                startTerminal: { _ in true },
                submitPrompt: { _, _ in false },
                visibleText: { _ in nil },
                notify: { _, _, _ in }
            )
        )
        return (controller, directory)
    }

    private func makeContent(defaults: UserDefaults, agentManager: AgentManager = AgentManager()) -> MainContentViewController {
        MainContentViewController(
            agentManager: agentManager,
            sessionManager: SessionManager(agentManager: agentManager, defaults: defaults),
            themeManager: ThemeManager(themeId: "folio"),
            gitBranchMonitor: GitBranchMonitor(),
            defaults: defaults,
            splitTreeViewFactory: { agentManager, themeManager in
                SplitTreeView(
                    agentManager: agentManager,
                    themeManager: themeManager,
                    terminalViewFactory: { target, config, _ in
                        TerminalSurfaceView(paneId: target.paneId, tabId: target.tabId, config: config, startsSurface: false)
                    },
                    terminalViewHasLiveSurface: { _ in false }
                )
            }
        )
    }

    @Test func clickingTheFocusedPanesSidebarRowClosesThePageAndGivesThatPaneTheKeyboard() throws {
        let suiteName = "AutomationsPageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (automationController, directory) = try makeController(automations: "{}")
        defer { try? FileManager.default.removeItem(at: directory) }
        let agentManager = AgentManager()
        let content = makeContent(defaults: defaults, agentManager: agentManager)
        content.automationController = automationController
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = content
        window.layoutIfNeeded()
        content.showAutomations()
        #expect(window.firstResponder is AutomationsRootView)

        let paneId = agentManager.activePaneId
        let row = try #require(allSubviews(in: content.view).first {
            $0.identifier?.rawValue == "sidebar-pane-\(paneId)"
        })
        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: row.convert(NSPoint(x: 4, y: row.bounds.midY), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        row.mouseDown(with: click)

        #expect(!content.isShowingAutomations)
        #expect((window.firstResponder as? TerminalSurfaceView)?.paneId == paneId)
    }

    @Test func refreshingAnAutomationsPageWithNothingNewKeepsItsViewsAndSoTheSelection() throws {
        let (controller, directory) = try makeController(automations: oneAutomation)
        defer { try? FileManager.default.removeItem(at: directory) }
        let automation = try #require(controller.automations.first)
        let detail = AutomationDetailView(theme: ThemeManager(themeId: "folio").currentTheme)
        let now = Date()
        let nextRun = now.addingTimeInterval(15.5 * 3_600)
        detail.update(automation: automation, runs: [], nextRun: nextRun, now: now)
        let before = allSubviews(in: detail).map(ObjectIdentifier.init)

        // The page refreshes every half minute; "in 15 hr" reads the same.
        detail.update(automation: automation, runs: [], nextRun: nextRun, now: now.addingTimeInterval(30))
        #expect(allSubviews(in: detail).map(ObjectIdentifier.init) == before)

        // A time it states that changed is shown.
        detail.update(automation: automation, runs: [], nextRun: nextRun, now: now.addingTimeInterval(3 * 3_600))
        #expect(allSubviews(in: detail).map(ObjectIdentifier.init) != before)
    }

    @Test(arguments: [
        (900.0, 560.0, "{}"),
        (1800.0, 1100.0, "{}"),
        (900.0, 560.0, oneAutomation),
        (1200.0, 760.0, oneAutomation),
        (1800.0, 1100.0, oneAutomation),
    ])
    func openingThePageLeavesTheWindowFrameAlone(width: Double, height: Double, automations: String) throws {
        let suiteName = "AutomationsPageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (automationController, directory) = try makeController(automations: automations)
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = makeContent(defaults: defaults)
        content.automationController = automationController
        let originalFrame = NSRect(x: 120, y: 80, width: width, height: height)
        let window = NSWindow(
            contentRect: originalFrame,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = content
        window.setFrame(originalFrame, display: false)
        window.layoutIfNeeded()

        content.showAutomations()
        // The window's own layout pass is where AppKit resizes a window to
        // satisfy its content's constraints, after the page's open returns.
        window.layoutIfNeeded()
        #expect(window.frame == originalFrame)
        // A page that pins a size also holds the window there when dragged.
        let resized = NSRect(x: 120, y: 80, width: width + 140, height: height + 90)
        window.setFrame(resized, display: false)
        window.layoutIfNeeded()
        #expect(window.frame == resized)
        window.setFrame(originalFrame, display: false)
        window.layoutIfNeeded()

        if let id = automationController.automations.first?.id {
            automationController.runNow(id)
            content.showAutomations(selectingRun: try #require(automationController.lastRun(for: id)?.id))
            window.layoutIfNeeded()
            #expect(window.frame == originalFrame)
            // Esc steps back from the run's report to its automation's page.
            let page = try #require(allSubviews(in: content.view).compactMap { $0 as? AutomationsRootView }.first)
            page.onEscape?()
            let detail = try #require(allSubviews(in: content.view).first { $0.identifier?.rawValue == "automations-detail" })
            window.layoutIfNeeded()
            #expect(window.frame == originalFrame)
            // The column still fills the page, up to its reading width. The
            // visible width leaves out a scroller when the system shows one.
            let scrollView = try #require(allSubviews(in: detail).compactMap { $0 as? NSScrollView }.first)
            let column = try #require(scrollView.documentView?.subviews.first)
            let available = scrollView.contentView.bounds.width - 2 * Chrome.Space.page
            #expect(column.frame.width == min(available, 1_040))
        }

        content.closeAutomations()
        window.layoutIfNeeded()
        #expect(window.frame == originalFrame)
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(in:))
    }
}
