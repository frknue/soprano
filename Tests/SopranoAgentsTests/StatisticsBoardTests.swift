import AppKit
import Testing
@testable import Soprano

@MainActor
struct StatisticsBoardTests {
    private func window() throws -> (AgentsWindowController, WorkspaceState) {
        let built = try DemoFixtures.build("demo")
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = AgentsWindowController(engine: built.engine, state: state, defaults: UserDefaults(suiteName: UUID().uuidString)!, persistsFrame: false)
        _ = controller.window
        return (controller, state)
    }

    private func run(_ id: String, _ controller: AgentsWindowController) throws {
        let command = try #require((ShellCommands.all + PanelCommands.all + ComposerCommands.all).first { $0.id == id })
        command.perform(controller.commandContext())
    }

    @Test func aToggleForASurfaceUnderTheBoardShowsItInsteadOfHidingIt() throws {
        let (controller, state) = try window()
        let cases: [(String, (WorkspaceState) -> Bool)] = [
            ("view.toggleRightPanel", { $0.isRightPanelVisible }),
            ("view.toggleTerminal", { $0.isTerminalVisible }),
            ("view.toggleThreadDetails", { $0.isThreadDetailsVisible }),
            ("diff.toggle", { $0.isRightPanelVisible && $0.rightPanelSurface == .diff }),
            ("files.toggle", { $0.isRightPanelVisible && $0.rightPanelSurface == .files }),
        ]
        for (id, isShown) in cases {
            // Open the surface (a toggle may first hide what an earlier case left showing).
            if !isShown(state) { try run(id, controller) }
            if !isShown(state) { try run(id, controller) }
            #expect(isShown(state), "\(id) opens it first")
            state.setStatisticsVisible(true)
            try run(id, controller)
            #expect(!state.isStatisticsVisible, "\(id)")
            #expect(isShown(state), "\(id) keeps it shown")
        }

        state.setRightPanelMaximized(true)
        state.setStatisticsVisible(true)
        try run("rightPanel.toggleMaximized", controller)
        #expect(!state.isStatisticsVisible)
        #expect(state.isRightPanelVisible && state.isRightPanelMaximized)
    }

    @Test func closingTheBoardItFocusedReturnsTheKeyboardToTheComposer() throws {
        let (controller, state) = try window()
        let workspace = controller.workspace
        state.setStatisticsVisible(true)
        #expect(workspace.statistics.hasFocus)

        state.setStatisticsVisible(false)

        let responder = try #require(controller.window?.firstResponder as? NSView)
        #expect(responder.isDescendant(of: workspace.chat.composer.view))
    }

    @Test func closingTheBoardOverAMaximizedPanelFocusesThePanel() throws {
        let (controller, state) = try window()
        let workspace = controller.workspace
        state.showRightPanel(.files)
        state.setRightPanelMaximized(true)
        state.setStatisticsVisible(true)
        #expect(workspace.statistics.hasFocus)

        state.setStatisticsVisible(false)

        let responder = try #require(controller.window?.firstResponder as? NSView)
        #expect(!responder.isDescendant(of: workspace.chat.view))
        #expect(responder.isDescendant(of: workspace.rightPanel.view))
    }

    @Test func aSelectionTheAppMakesItselfKeepsTheBoardAndItsFocus() throws {
        let (controller, state) = try window()
        let workspace = controller.workspace
        let other = try #require(controller.engine.threads.first { $0.id != state.selectedThreadID && $0.archivedAt == nil })
        state.setStatisticsVisible(true)
        #expect(workspace.statistics.hasFocus)

        state.select(.thread(other.id), closingOverlays: false)

        #expect(state.isStatisticsVisible)
        #expect(state.selectedThreadID == other.id)
        #expect(workspace.chat.view.isHidden)
        #expect(workspace.statistics.hasFocus)
    }

    @Test func focusComposerFromTheBoardClosesItAndFocusesAVisibleComposer() throws {
        let (controller, state) = try window()
        let window = try #require(controller.window)
        let workspace = controller.workspace
        state.setStatisticsVisible(true)
        #expect(workspace.chat.view.isHidden)

        let focus = try #require(ComposerCommands.all.first { $0.id == "composer.focus" })
        focus.perform(controller.commandContext())

        #expect(!state.isStatisticsVisible)
        #expect(!workspace.chat.view.isHidden)
        #expect(workspace.statistics.view.isHidden)
        let responder = try #require(window.firstResponder as? NSView)
        #expect(responder.isDescendant(of: workspace.chat.composer.view))
    }

    @Test func choosingAThreadOrDraftClosesTheBoardEvenWhenAlreadySelected() {
        let state = WorkspaceState()
        state.select(.thread("a"))
        let owner = NSObject()
        var changes: [WorkspaceState.Change] = []
        state.addObserver(owner) { changes.append($0) }

        state.setStatisticsVisible(true)
        state.select(.thread("a"))
        #expect(!state.isStatisticsVisible)
        #expect(changes == [.panels, .panels])
        withExtendedLifetime(owner) {}

        state.setStatisticsVisible(true)
        state.select(.draft(projectID: nil))
        #expect(!state.isStatisticsVisible)
        #expect(state.isDraft)
    }

    @Test func openingAChatSurfaceClosesTheBoardButHidingOneDoesNot() {
        let state = WorkspaceState()
        state.select(.thread("a"))
        state.setRightPanelVisible(true)

        state.setStatisticsVisible(true)
        state.setRightPanelVisible(false)
        #expect(state.isStatisticsVisible)

        state.setTerminalVisible(true)
        #expect(!state.isStatisticsVisible)
        #expect(state.isTerminalVisible)

        state.setStatisticsVisible(true)
        state.setTerminalVisible(true)
        #expect(!state.isStatisticsVisible)

        state.setStatisticsVisible(true)
        state.showDiff(.thread)
        #expect(!state.isStatisticsVisible)
        #expect(state.isRightPanelVisible)
    }

    @Test func tokenCountsScaleToThousandsMillionsAndBillions() {
        #expect(StatisticsFormat.tokens(950) == "950")
        #expect(StatisticsFormat.tokens(62_400) == "62.4k")
        #expect(StatisticsFormat.tokens(200_000) == "200k")
        #expect(StatisticsFormat.tokens(5_116_590) == "5.1M")
        #expect(StatisticsFormat.tokens(1_781_725_306) == "1.78B")
        #expect(StatisticsFormat.tokens(3_000_000_000) == "3B")
    }

    @Test func costsKeepCentsUntilAThousandAndFlagTinyAmounts() {
        #expect(StatisticsFormat.cost(0) == "$0")
        #expect(StatisticsFormat.cost(0.004) == "<$0.01")
        #expect(StatisticsFormat.cost(0.09) == "$0.09")
        #expect(StatisticsFormat.cost(701.644) == "$701.64")
        #expect(StatisticsFormat.cost(12_345.6) == "$12,346")
        #expect(StatisticsFormat.axisValue(0, .cost) == "$0")
        #expect(StatisticsFormat.axisValue(2.5, .cost) == "$2.50")
        #expect(StatisticsFormat.axisValue(1500, .cost) == "$1,500")
    }

    @Test func percentagesShowADecimalOnlyNearTheEnds() {
        #expect(StatisticsFormat.percent(0) == "0%")
        #expect(StatisticsFormat.percent(0.004) == "0.4%")
        #expect(StatisticsFormat.percent(0.62) == "62%")
        #expect(StatisticsFormat.percent(0.9975) == "99.8%")
        #expect(StatisticsFormat.percent(1) == "100%")
    }

    @Test func theChartScaleRoundsUpToAReadableStep() {
        #expect(UsageChartView.niceCeiling(0) == 1)
        #expect(UsageChartView.niceCeiling(76.4) == 100)
        #expect(UsageChartView.niceCeiling(140) == 200)
        #expect(UsageChartView.niceCeiling(230) == 250)
        #expect(UsageChartView.niceCeiling(4.2) == 5)
        #expect(UsageChartView.niceCeiling(500) == 500)
    }
}
