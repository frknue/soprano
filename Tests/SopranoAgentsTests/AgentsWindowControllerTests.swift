import AppKit
import Testing
@testable import Soprano

@MainActor
struct AgentsWindowControllerTests {
    private func controller() throws -> AgentsWindowController {
        _ = NSApplication.shared
        let built = try DemoFixtures.build("demo")
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = AgentsWindowController(
            engine: built.engine,
            state: state,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistsFrame: false,
            frame: NSRect(x: -30000, y: -30000, width: 1200, height: 800)
        )
        controller.mainWindow?.allowsOffscreenFrame = true
        return controller
    }

    @Test func reopeningTheWindowGivesTheKeyboardBackToTheDialogStillOpenOverIt() throws {
        let controller = try controller()
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        #expect(controller.keyTarget === window)
        let overlay = OverlayWindow()
        overlay.present(over: window)
        defer { overlay.dismiss() }

        window.close()
        controller.showAndMakeKey()

        // The overlay came back with its window; a test process is never active, so the key
        // status itself is not observable here.
        #expect(overlay.isVisible)
        #expect(controller.keyTarget === overlay)
    }

    @Test func theDetailsCardStopsPollingGitWhileTheWindowIsClosedAndStaysOpenForTheReopen() throws {
        let controller = try controller()
        let window = try #require(controller.window)
        let details = controller.workspace.chat.details
        controller.showWindow(nil)
        defer { window.close() }
        controller.state.setThreadDetailsVisible(true)
        #expect(details.isPollingStatus)

        window.close()
        #expect(!details.isPollingStatus)
        #expect(controller.state.isThreadDetailsVisible)

        controller.showWindow(nil)
        #expect(details.isPollingStatus)
    }
}
