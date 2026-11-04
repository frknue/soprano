import AppKit
import Testing
@testable import Soprano

@MainActor
struct AgentsAppControllerTests {
    @MainActor
    private final class Reports {
        var count = 0
    }

    private func controller(defaults: UserDefaults, reports: Reports) -> AgentsAppController {
        AgentsAppController(
            menuBar: MenuBarSwitcher(soprano: .init(menu: NSMenu())) { _ in nil },
            defaults: defaults,
            standaloneIsRunning: { true },
            reportStandaloneRunning: { reports.count += 1 },
            showTerminals: {}
        )
    }

    @Test func openingTheWindowWhileTheStandaloneAppRunsSaysSoAndStartsNoEngine() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentsAppControllerTests-\(UUID().uuidString)"))
        let reports = Reports()
        let agents = controller(defaults: defaults, reports: reports)

        agents.showWindow()

        #expect(reports.count == 1)
        #expect(agents.engine == nil)
        #expect(agents.windowController == nil)
        #expect(!agents.needsShutdown)
    }

    @Test func aWindowLeftOpenStaysClosedWhileTheStandaloneAppRunsAndIsRestoredLater() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentsAppControllerTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: AgentsAppController.windowOpenKey)
        let reports = Reports()
        let agents = controller(defaults: defaults, reports: reports)

        agents.restoreIfNeeded(behind: nil)
        agents.recordWindowState()

        // Launch restore never interrupts with the alert, and the next launch still reopens it.
        #expect(reports.count == 0)
        #expect(agents.engine == nil)
        #expect(defaults.bool(forKey: AgentsAppController.windowOpenKey))
    }

    @Test func eachBuildChecksTheStandaloneAppThatSharesItsDataFolder() {
        #expect(AgentsAppController.standaloneBundleIdentifier(for: "com.soprano.app") == "com.soprano.agents")
        #expect(AgentsAppController.standaloneBundleIdentifier(for: "com.soprano.dev") == "com.soprano.agents.dev")
        #expect(AgentsAppController.standaloneBundleIdentifier(for: nil) == "com.soprano.agents.dev")
    }
}
