import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

/// The header's thread title: in a subagent it opens the thread, in the thread it renames.
@MainActor
struct ChatHeaderTitleTests {
    private func click(_ view: NSView, count: Int, in window: NSWindow) {
        let location = view.convert(NSPoint(x: 4, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    @Test func doubleClickingTheTitleInASubagentOpensTheThreadWithoutStartingARename() throws {
        let built = try DemoFixtures.build("subagent")
        let state = WorkspaceState()
        state.select(built.selection)
        #expect(state.selectedSubagentID != nil)
        let header = ChatHeaderView(engine: built.engine, state: state)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: Metrics.topbarHeight), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = header
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        header.layoutSubtreeIfNeeded()
        let title = try #require(header.subviews.first { $0 is HeaderTitleButton })

        click(title, count: 1, in: window)
        click(title, count: 2, in: window)

        #expect(state.selectedSubagentID == nil)
        #expect(!header.isRenaming)

        // In the thread itself a double-click still renames.
        click(title, count: 1, in: window)
        click(title, count: 2, in: window)
        #expect(header.isRenaming)
    }
}
