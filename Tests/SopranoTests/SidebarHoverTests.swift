import AppKit
import Testing
@testable import Soprano

/// The sidebar list owns the hover, like the file explorer: AppKit drops the
/// exit event of a row whose tracking area is replaced while it moves, so the
/// rows must not track the pointer themselves.
@MainActor
struct SidebarHoverTests {
    @Test func onlyTheRowUnderThePointerShowsItsHoverPillAndCloseButton() throws {
        try withSidebar { _, sidebar, list in
            let rows = unselectedRows(in: sidebar)
            #expect(rows.count >= 4)
            #expect(hoveredRows(in: sidebar).isEmpty)

            for row in rows {
                list.mouseMoved(with: try mouseEvent(at: center(of: row)))
                #expect(hoveredRows(in: sidebar) == [row])
                #expect(closeButton(of: row)?.alphaValue == 1)
            }

            list.mouseExited(with: try exitEvent(at: center(of: rows[0])))
            #expect(hoveredRows(in: sidebar).isEmpty)
            #expect(rows.allSatisfy { closeButton(of: $0)?.alphaValue == 0 })
        }
    }

    @Test func rowsMovingUnderAStillPointerHandTheHoverToTheRowNowBeneathIt() throws {
        try withSidebar { manager, sidebar, list in
            let firstWindow = try #require(manager.activeSessionWindows.first)
            manager.toggleSidebarWindowCollapsed(firstWindow.id)
            sidebar.layoutSubtreeIfNeeded()
            let target = try #require(unselectedRows(in: sidebar).dropFirst(2).first)
            let pointer = center(of: target)
            list.mouseMoved(with: try mouseEvent(at: pointer))
            #expect(hoveredRows(in: sidebar) == [target])

            // Expanding the window above pushes every row below it down under
            // the resting pointer, as holding ⌃ does.
            manager.toggleSidebarWindowCollapsed(firstWindow.id)
            sidebar.layoutSubtreeIfNeeded()

            let beneath = try #require(row(containing: pointer, in: sidebar))
            #expect(beneath !== target)
            #expect(hoveredRows(in: sidebar) == [beneath])
        }
    }

    @Test func scrollingUnderAStillPointerMovesTheHoverWithTheList() throws {
        try withSidebar { _, sidebar, list in
            let scrollView = try #require(list.enclosingScrollView)
            let first = try #require(unselectedRows(in: sidebar).first)
            let pointer = center(of: first)
            list.mouseMoved(with: try mouseEvent(at: pointer))

            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 90))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            let beneath = try #require(row(containing: pointer, in: sidebar))
            #expect(beneath !== first)
            #expect(hoveredRows(in: sidebar) == [beneath])
        }
    }

    @Test func leavingTheAppDropsTheHover() throws {
        try withSidebar { _, sidebar, list in
            let row = try #require(unselectedRows(in: sidebar).first)
            list.mouseMoved(with: try mouseEvent(at: center(of: row)))
            #expect(hoveredRows(in: sidebar) == [row])

            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            #expect(hoveredRows(in: sidebar).isEmpty)
        }
    }

    // MARK: - Helpers

    private func withSidebar(_ body: (AgentManager, SidebarView, NSView) throws -> Void) throws {
        let suiteName = "SidebarHoverTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = AgentManager()
        for _ in 0..<5 {
            _ = try #require(manager.createWindow())
            _ = try #require(manager.spawnTerminal())
        }
        manager.activateWindow(try #require(manager.activeSessionWindows.first).id)
        let sidebar = SidebarView(
            agentManager: manager,
            sessionManager: SessionManager(agentManager: manager, defaults: defaults),
            themeManager: ThemeManager(themeId: "folio-paper"),
            gitBranchMonitor: GitBranchMonitor()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        content.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SidebarWidthStore.left.defaultWidth),
        ])
        content.layoutSubtreeIfNeeded()
        let scrollView = try #require(descendants(of: sidebar, as: NSScrollView.self).first)
        try body(manager, sidebar, try #require(scrollView.documentView))
    }

    /// Window and pane rows on screen, top to bottom, minus the focused pane,
    /// whose selection pill outranks the hover.
    private func unselectedRows(in sidebar: SidebarView) -> [NSView] {
        descendants(of: sidebar, as: ChromeRowBackgroundView.self)
            .filter { $0.style != .selected && $0.style != .selectedUnfocused }
            .compactMap(\.superview)
            .filter { row in
                guard let scrollView = row.enclosingScrollView, let list = scrollView.documentView else { return false }
                return scrollView.documentVisibleRect.contains(row.convert(row.bounds, to: list))
            }
            .sorted { center(of: $0).y > center(of: $1).y }
    }

    private func hoveredRows(in sidebar: SidebarView) -> [NSView] {
        descendants(of: sidebar, as: ChromeRowBackgroundView.self)
            .filter { $0.style == .hover }
            .compactMap(\.superview)
    }

    private func closeButton(of row: NSView) -> NSButton? {
        descendants(of: row, as: NSButton.self).first {
            ["Close Pane", "Close Window"].contains($0.accessibilityLabel() ?? "")
        }
    }

    private func row(containing windowPoint: NSPoint, in sidebar: SidebarView) -> NSView? {
        descendants(of: sidebar, as: ChromeRowBackgroundView.self).compactMap(\.superview).first { row in
            row.bounds.contains(row.convert(windowPoint, from: nil))
        }
    }

    private func center(of row: NSView) -> NSPoint {
        row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
    }

    private func mouseEvent(at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
    }

    private func exitEvent(at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
