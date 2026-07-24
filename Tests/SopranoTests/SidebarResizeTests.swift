import AppKit
import Testing
@testable import Soprano

@MainActor
struct SidebarResizeTests {
    @Test func widthClampsToTheAllowedRange() {
        #expect(SidebarWidthStore.clamp(300) == 300)
        #expect(SidebarWidthStore.clamp(10) == SidebarWidthStore.minimumWidth)
        #expect(SidebarWidthStore.clamp(5000) == SidebarWidthStore.maximumWidth)
        #expect(SidebarWidthStore.clamp(.nan) == SidebarWidthStore.defaultWidth)
        #expect(SidebarWidthStore.clamp(.infinity) == SidebarWidthStore.defaultWidth)
    }

    @Test func widthLeavesRoomForPanesInNarrowWindows() {
        // 700 wide window: the reserve binds before the absolute maximum does.
        #expect(SidebarWidthStore.clamp(800, availableWidth: 700) == 380)
        #expect(SidebarWidthStore.clamp(200, availableWidth: 700) == 200)

        // Wide window: the absolute maximum is what stops the drag.
        #expect(
            SidebarWidthStore.clamp(800, availableWidth: 1800)
                == SidebarWidthStore.maximumWidth
        )

        // Narrower than minimum + reserved: the minimum still wins.
        #expect(
            SidebarWidthStore.clamp(400, availableWidth: 300)
                == SidebarWidthStore.minimumWidth
        )
    }

    @Test func widthRoundTripsThroughDefaultsAndFallsBackWhenUnset() throws {
        try withIsolatedDefaults { defaults in
            #expect(SidebarWidthStore.load(from: defaults) == SidebarWidthStore.defaultWidth)

            SidebarWidthStore.save(340, to: defaults)
            #expect(SidebarWidthStore.load(from: defaults) == 340)

            // Values outside the current bounds are clamped on the way back in.
            SidebarWidthStore.save(9000, to: defaults)
            #expect(SidebarWidthStore.load(from: defaults) == SidebarWidthStore.maximumWidth)
        }
    }

    @Test func draggingTheHandleResizesTheSidebarAndItsContent() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let sidebar = try #require(firstSidebar(in: controller.view))
            let handle = try #require(resizeHandle(in: controller.view))
            let startingWidth = sidebar.frame.width
            #expect(startingWidth == SidebarWidthStore.defaultWidth)

            drag(handle, byX: 80)
            controller.view.layoutSubtreeIfNeeded()

            #expect(sidebar.frame.width == startingWidth + 80)
            // The content must follow, or rows stay clipped at the old width.
            #expect(contentWidth(of: sidebar) == startingWidth + 80)
        }
    }

    @Test func draggingBeyondTheAllowedRangeStopsAtTheBound() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let sidebar = try #require(firstSidebar(in: controller.view))
            let handle = try #require(resizeHandle(in: controller.view))

            drag(handle, byX: -500)
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width == SidebarWidthStore.minimumWidth)

            drag(handle, byX: 5000)
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width == SidebarWidthStore.maximumWidth)
        }
    }

    @Test func aDraggedWidthSurvivesIntoTheNextLaunch() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let handle = try #require(resizeHandle(in: controller.view))
            drag(handle, byX: 60)

            let relaunched = makeController(defaults: defaults)
            let restoredSidebar = try #require(firstSidebar(in: relaunched.view))
            #expect(restoredSidebar.frame.width == SidebarWidthStore.defaultWidth + 60)
        }
    }

    @Test func doubleClickingTheHandleRestoresTheDefaultWidth() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let sidebar = try #require(firstSidebar(in: controller.view))
            let handle = try #require(resizeHandle(in: controller.view))

            drag(handle, byX: 120)
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width != SidebarWidthStore.defaultWidth)

            handle.mouseDown(with: mouseEvent(at: .zero, clickCount: 2))
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width == SidebarWidthStore.defaultWidth)
        }
    }

    @Test func hidingTheSidebarWithdrawsItsResizeHandle() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let handle = try #require(resizeHandle(in: controller.view))
            #expect(!handle.isHidden)

            controller.toggleSidebar()
            #expect(handle.isHidden)

            controller.toggleSidebar()
            #expect(!handle.isHidden)
        }
    }

    @Test func draggingAHiddenSidebarDoesNotChangeItsWidth() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let handle = try #require(resizeHandle(in: controller.view))

            controller.toggleSidebar()
            drag(handle, byX: 120)

            // The width the sidebar will reappear at must be untouched.
            #expect(SidebarWidthStore.load(from: defaults) == SidebarWidthStore.defaultWidth)
        }
    }

    // MARK: - Helpers

    /// Runs the body against a private defaults domain, removed afterwards so
    /// concurrent tests and the developer's real preferences stay untouched.
    private func withIsolatedDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let suiteName = "soprano-sidebar-resize-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try body(defaults)
    }

    private func makeController(defaults: UserDefaults) -> MainContentViewController {
        let agentManager = AgentManager()
        let controller = MainContentViewController(
            agentManager: agentManager,
            sessionManager: SessionManager(agentManager: agentManager),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor(),
            defaults: defaults,
            splitTreeViewFactory: { manager, themeManager in
                SplitTreeView(
                    agentManager: manager,
                    themeManager: themeManager,
                    terminalViewFactory: { _, _, _ in NSView() },
                    destroyTerminalView: { _ in },
                    restartTerminalView: { _ in true },
                    terminalViewHasLiveSurface: { _ in false },
                    scheduleCodexReadiness: { _ in }
                )
            }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    /// Presses at the origin, moves by `byX` window points, and releases.
    private func drag(_ handle: NSView, byX deltaX: CGFloat) {
        handle.mouseDown(with: mouseEvent(at: .zero, clickCount: 1))
        handle.mouseDragged(with: mouseEvent(at: NSPoint(x: deltaX, y: 0), clickCount: 1))
        handle.mouseUp(with: mouseEvent(at: NSPoint(x: deltaX, y: 0), clickCount: 1))
    }

    private func mouseEvent(at locationInWindow: NSPoint, clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private func contentWidth(of sidebar: SidebarView) -> CGFloat? {
        sidebar.subviews.first?.frame.width
    }

    private func firstSidebar(in view: NSView) -> SidebarView? {
        descendants(of: view, as: SidebarView.self).first
    }

    private func resizeHandle(in view: NSView) -> NSView? {
        descendants(of: view, as: NSView.self).first {
            String(describing: type(of: $0)) == "SidebarResizeHandleView"
        }
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
