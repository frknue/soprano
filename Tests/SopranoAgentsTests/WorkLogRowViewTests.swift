import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

/// Work-log rows across streamed updates and view reuse.
@MainActor
struct WorkLogRowViewTests {
    private func command(_ id: String, output: String, status: TurnItemStatus) throws -> TimelineRow {
        let item = TurnItem(id: id, kind: .command(CommandExecution(command: "swift build", cwd: "/tmp", output: output)), status: status, startedAt: Date(timeIntervalSince1970: 0))
        let entry = try #require(WorkLog.entry(for: item))
        return TimelineRow(id: "entry:\(id)", content: .workEntry(WorkEntryRowModel(entry: entry, displayLabel: nil, grouped: false, expanded: true)))
    }

    private func window(showing view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + descendants(of: $0, as: type) }
    }

    /// The sweep (re)starts in the label's layout pass; one that is not invalidated keeps running.
    @Test func aStreamedUpdateOfARunningStepKeepsItsShimmerRunningInsteadOfRestartingIt() {
        let label = ShimmerLabel(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        let window = window(showing: label)
        defer { window.orderOut(nil) }
        let font = Typography.ui(Typography.bodySize)
        label.set("Running swift build", font: font, color: .gray, highlightColor: .white)
        label.isShimmering = true
        label.layoutSubtreeIfNeeded()
        #expect(!label.needsLayout)

        // The same step again, as each streamed delta re-configures the row.
        label.set("Running swift build", font: font, color: .gray, highlightColor: .white)
        label.isShimmering = true
        #expect(!label.needsLayout)

        label.set("Running swift test", font: font, color: .gray, highlightColor: .white)
        #expect(label.needsLayout)
        label.layoutSubtreeIfNeeded()
        label.isShimmering = false
        #expect(label.needsLayout)
    }

    @Test func aReusedEntryRowShowsTheNextEntrysOutputFromItsTop() throws {
        let row = WorkEntryRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let window = window(showing: row)
        defer { window.orderOut(nil) }
        let long = (1...200).map { "line \($0)" }.joined(separator: "\n")
        row.configure(try command("c1", output: long, status: .completed))
        _ = row.layoutRow(width: 600)
        let scroll = try #require(descendants(of: row, as: PassThroughScrollView.self).first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY > 0)

        // The same entry streaming more output keeps its scroll position.
        row.configure(try command("c1", output: long + "\nline 201", status: .completed))
        _ = row.layoutRow(width: 600)
        #expect(scroll.contentView.bounds.minY > 0)

        row.configure(try command("c2", output: long, status: .completed))
        _ = row.layoutRow(width: 600)
        #expect(scroll.contentView.bounds.minY == 0)
    }
}
