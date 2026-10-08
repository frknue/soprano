import AppKit
import Testing
@testable import Soprano

@MainActor
struct SidebarResizeTests {
    @Test func widthClampsToTheAllowedRange() {
        let store = SidebarWidthStore.left
        #expect(store.clamp(300) == 300)
        #expect(store.clamp(10) == store.minimumWidth)
        #expect(store.clamp(5000) == store.maximumWidth)
        #expect(store.clamp(.nan) == store.defaultWidth)
        #expect(store.clamp(.infinity) == store.defaultWidth)
    }

    @Test func widthLeavesRoomForPanesInNarrowWindows() {
        let store = SidebarWidthStore.left
        // 700 wide window: the reserve binds before the absolute maximum does.
        #expect(store.clamp(800, availableWidth: 700) == 380)
        #expect(store.clamp(200, availableWidth: 700) == 200)

        // Wide window: the absolute maximum is what stops the drag.
        #expect(store.clamp(800, availableWidth: 1800) == store.maximumWidth)

        // Narrower than minimum + reserved: the minimum still wins.
        #expect(store.clamp(400, availableWidth: 300) == store.minimumWidth)
    }

    @Test func widthRoundTripsThroughDefaultsAndFallsBackWhenUnset() throws {
        try withIsolatedDefaults { defaults in
            let store = SidebarWidthStore.left
            #expect(store.load(from: defaults) == store.defaultWidth)

            store.save(340, to: defaults)
            #expect(store.load(from: defaults) == 340)

            // Values outside the current bounds are clamped on the way back in.
            store.save(9000, to: defaults)
            #expect(store.load(from: defaults) == store.maximumWidth)

            // Each sidebar keeps its own width.
            #expect(SidebarWidthStore.right.load(from: defaults) == SidebarWidthStore.right.defaultWidth)
        }
    }

    @Test func draggingTheHandleResizesTheSidebarAndItsContent() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let sidebar = try #require(firstSidebar(in: controller.view))
            let handle = try #require(resizeHandle(in: controller.view))
            let startingWidth = sidebar.frame.width
            #expect(startingWidth == SidebarWidthStore.left.defaultWidth)

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
            #expect(sidebar.frame.width == SidebarWidthStore.left.minimumWidth)

            drag(handle, byX: 5000)
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width == SidebarWidthStore.left.maximumWidth)
        }
    }

    @Test func aDraggedWidthSurvivesIntoTheNextLaunch() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let handle = try #require(resizeHandle(in: controller.view))
            drag(handle, byX: 60)

            let relaunched = makeController(defaults: defaults)
            let restoredSidebar = try #require(firstSidebar(in: relaunched.view))
            #expect(restoredSidebar.frame.width == SidebarWidthStore.left.defaultWidth + 60)
        }
    }

    @Test func doubleClickingTheHandleRestoresTheDefaultWidth() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let sidebar = try #require(firstSidebar(in: controller.view))
            let handle = try #require(resizeHandle(in: controller.view))

            drag(handle, byX: 120)
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width != SidebarWidthStore.left.defaultWidth)

            handle.mouseDown(with: mouseEvent(at: .zero, clickCount: 2))
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width == SidebarWidthStore.left.defaultWidth)
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
            #expect(SidebarWidthStore.left.load(from: defaults) == SidebarWidthStore.left.defaultWidth)
        }
    }

    @Test func draggingTheRightSidebarsEdgeLeftWidensIt() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let sidebar = try #require(rightSidebar(in: controller.view))
            let handle = try #require(resizeHandle(in: controller.view, identifier: "right-sidebar-resize-handle"))
            #expect(sidebar.frame.width == SidebarWidthStore.right.defaultWidth)

            drag(handle, byX: -100)
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width == SidebarWidthStore.right.defaultWidth + 100)
            // It stays pinned to the window's trailing edge.
            #expect(sidebar.frame.maxX == controller.view.bounds.maxX)

            drag(handle, byX: 500)
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width == SidebarWidthStore.right.minimumWidth)

            let relaunched = makeController(defaults: defaults)
            let restored = try #require(rightSidebar(in: relaunched.view))
            #expect(restored.frame.width == SidebarWidthStore.right.minimumWidth)
        }
    }

    @Test func bothSidebarsTogetherStillLeavePanesTheReservedWidth() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults, width: 1000)
            let left = try #require(firstSidebar(in: controller.view))
            let right = try #require(rightSidebar(in: controller.view))
            let handle = try #require(resizeHandle(in: controller.view))

            drag(handle, byX: 5000)
            controller.view.layoutSubtreeIfNeeded()

            #expect(left.frame.width == 1000 - right.frame.width - SidebarWidthStore.reservedContentWidth)
        }
    }

    @Test func hidingTheRightSidebarCollapsesItAndReopensAtItsWidth() throws {
        try withIsolatedDefaults { defaults in
            let controller = makeController(defaults: defaults)
            let sidebar = try #require(rightSidebar(in: controller.view))
            let handle = try #require(resizeHandle(in: controller.view, identifier: "right-sidebar-resize-handle"))
            drag(handle, byX: -40)

            controller.toggleRightSidebar()
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width == 0)
            #expect(handle.isHidden)

            // The closed state survives a relaunch.
            let relaunched = makeController(defaults: defaults)
            #expect(try #require(rightSidebar(in: relaunched.view)).frame.width == 0)

            controller.toggleRightSidebar()
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.frame.width == SidebarWidthStore.right.defaultWidth + 40)
            #expect(!handle.isHidden)
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

    private func makeController(defaults: UserDefaults, width: CGFloat = 1400) -> MainContentViewController {
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
                    restartTerminalView: { _, _ in true },
                    terminalViewHasLiveSurface: { _ in false },
                    scheduleCodexReadiness: { _ in }
                )
            }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
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

    private func rightSidebar(in view: NSView) -> RightSidebarView? {
        descendants(of: view, as: RightSidebarView.self).first
    }

    private func resizeHandle(in view: NSView, identifier: String = "sidebar-resize-handle") -> NSView? {
        descendants(of: view, as: NSView.self).first { $0.identifier?.rawValue == identifier }
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
