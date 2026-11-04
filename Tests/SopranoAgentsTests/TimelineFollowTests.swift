import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

/// When the timeline follows its end: a user scroll, however small, stops it; opening a row
/// keeps that row in view; Collapse all closes everything, also inside closed groups.
@MainActor
struct TimelineFollowTests {
    private let turnID = "turn-rechecked-1"

    /// The "rechecked" thread with a recap long enough to scroll, in a short offscreen window.
    private func timeline() throws -> (controller: TimelineViewController, window: NSWindow, clip: NSClipView) {
        let built = try DemoFixtures.build("rechecked")
        let recap = (1...40).map { "Line \($0) of the recap." }.joined(separator: "\n\n")
        built.engine.updateThread(DemoFixtures.ID.rechecked) { thread in
            guard let index = thread.turns[0].items.firstIndex(where: { $0.id == "rc11" }) else { return }
            thread.turns[0].items[index].kind = .assistantMessage(text: recap, isFinal: true)
        }
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = TimelineViewController(engine: built.engine, state: state)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFrontRegardless()
        render(window)
        controller.reload(scrollToEnd: true)
        render(window)
        let scrollView = try #require(controller.view.subviews.first { $0 is NSScrollView } as? NSScrollView)
        return (controller, window, scrollView.contentView)
    }

    private func render(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func endY(_ clip: NSClipView) -> CGFloat {
        (clip.documentView?.frame.height ?? 0) - clip.bounds.height
    }

    @Test func aSmallUserScrollUpStopsFollowingTheEndSoTheNextUpdateLeavesItWhereItIs() throws {
        let (controller, window, clip) = try timeline()
        defer { window.orderOut(nil) }
        let end = endY(clip)
        #expect(end > 100)
        #expect(abs(clip.bounds.minY - end) < 1)

        // A slow trackpad scroll moves only a few points per event.
        clip.scroll(to: NSPoint(x: 0, y: end - 3))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        controller.reload()
        render(window)

        #expect(abs(clip.bounds.minY - (end - 3)) < 1)

        // Back at the end, it follows again.
        clip.scroll(to: NSPoint(x: 0, y: endY(clip)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        controller.reload()
        #expect(abs(clip.bounds.minY - endY(clip)) < 1)
    }

    @Test func openingTheFoldWhileFollowingTheEndKeepsTheFoldInView() throws {
        let (controller, window, clip) = try timeline()
        // The detailed work log (`chat.workLog`) opens folds by default.
        if controller.expansion.isTurnOpen(turnID) { controller.timelineToggleFold(turnID: turnID) }
        defer { window.orderOut(nil) }
        // A window just tall enough to show the closed fold at its top, following the end.
        let list = try #require(clip.documentView as? TimelineListView)
        window.setContentSize(NSSize(width: 900, height: 3000))
        render(window)
        let closed = try #require(list.view(forRow: "fold:\(turnID)"))
        let contentHeight = list.subviews.map(\.frame.maxY).max() ?? 0
        window.setContentSize(NSSize(width: 900, height: contentHeight - closed.frame.minY + 30))
        render(window)
        #expect(abs(clip.bounds.minY - endY(clip)) < 1)
        #expect(clip.bounds.contains(closed.convert(closed.bounds, to: clip)))

        controller.timelineToggleFold(turnID: turnID)
        render(window)
        #expect(controller.expansion.isTurnOpen(turnID))
        let fold = try #require(list.view(forRow: "fold:\(turnID)"))
        let header = fold.convert(NSRect(x: 0, y: 0, width: fold.bounds.width, height: 24), to: clip)
        #expect(clip.bounds.contains(header))
    }

    @Test func collapseAllClosesEntriesAndDiffsInsideGroupsThatAreAlreadyClosed() throws {
        let (controller, window, _) = try timeline()
        defer { window.orderOut(nil) }
        controller.expandAll()
        let rows = controller.currentRows
        let entries = rows.compactMap { row -> String? in
            if case let .workEntry(model) = row.content, model.grouped { return model.entry.id } else { return nil }
        }
        let group = try #require(rows.compactMap { row -> String? in
            if case let .workGroup(model) = row.content { return model.groupID } else { return nil }
        }.first)
        let entry = try #require(entries.first)
        controller.timelineToggleEntry(entry)
        #expect(controller.expansion.entries.contains(entry))
        controller.timelineToggleGroup(group)
        #expect(!controller.expansion.isGroupOpen(group))

        controller.collapseAll()

        #expect(!controller.expansion.entries.contains(entry))
        #expect(!controller.expansion.isTurnOpen(turnID))
    }
}
