import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct TimelineChecksRowTests {
    private let turnID = "turn-rechecked-1"

    /// The "rechecked" thread whose last check reply is a long report, shown by a timeline in an
    /// offscreen window too short for the opened checks.
    private func timeline() throws -> (controller: TimelineViewController, window: NSWindow) {
        let built = try DemoFixtures.build("rechecked")
        let report = "The second pass found no further problems.\n\n| Requirement | Status |\n|---|---|\n"
            + (1...60).map { "| Requirement \($0) | verified |" }.joined(separator: "\n")
        built.engine.updateThread(DemoFixtures.ID.rechecked) { thread in
            guard let index = thread.turns[0].items.firstIndex(where: { $0.id == "rc9" }) else { return }
            thread.turns[0].items[index].kind = .assistantMessage(text: report, isFinal: true)
        }
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = TimelineViewController(engine: built.engine, state: state)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFrontRegardless()
        render(window)
        controller.reload(scrollToEnd: true)
        render(window)
        return (controller, window)
    }

    private func render(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func checksRow(in view: NSView) -> ChecksRowView? {
        if let row = view as? ChecksRowView, !row.isHidden { return row }
        return view.subviews.lazy.compactMap { checksRow(in: $0) }.first
    }

    /// Mouse down and up at `point` (in `row`), delivered to whatever the window hit-tests there
    /// when that is the row or inside it (anything else would start its own tracking loop).
    private func click(_ row: NSView, at point: NSPoint, in window: NSWindow) -> NSView? {
        let location = row.convert(point, to: nil)
        // `hitTest` takes a point in the receiver's superview's coordinates (the timeline's root view is flipped).
        guard let content = window.contentView, let frameView = content.superview,
              let hit = content.hitTest(frameView.convert(location, from: nil)) else { return nil }
        guard hit === row || hit.isDescendant(of: row) else { return hit }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
        }
        return hit
    }

    @Test func clickingACheckLineOpensTheChecksAndKeepsTheirHeaderInView() throws {
        let (controller, window) = try timeline()
        defer { window.orderOut(nil) }
        let closed = try #require(checksRow(in: controller.view))
        #expect(!controller.expansion.checks.contains(turnID))

        // A click on the reply lines, below the header, reaches the row itself.
        let hit = click(closed, at: NSPoint(x: closed.bounds.midX, y: closed.bounds.maxY - 12), in: window)
        #expect(hit === closed)
        render(window)
        #expect(controller.expansion.checks.contains(turnID))

        // The timeline was pinned to its end; opening a long report keeps the header on screen.
        let open = try #require(checksRow(in: controller.view))
        let clip = try #require(open.enclosingScrollView?.contentView)
        let header = open.convert(NSRect(x: 0, y: 0, width: open.bounds.width, height: 24), to: clip)
        #expect(clip.bounds.contains(header))

        // The header closes it again.
        _ = click(open, at: NSPoint(x: 40, y: 12), in: window)
        render(window)
        #expect(!controller.expansion.checks.contains(turnID))
    }
}
