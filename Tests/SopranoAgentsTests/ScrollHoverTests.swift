import AppKit
import Testing
@testable import SopranoAgents

@MainActor
struct ScrollHoverTests {
    /// An offscreen window (the real pointer is never over it) with a scrolling column of rows.
    private func makeList(rows count: Int) -> (window: NSWindow, scroll: NSScrollView, rows: [InteractiveView]) {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: CGFloat(count) * 30))
        let rows = (0..<count).map { index in
            let row = InteractiveView(frame: NSRect(x: 0, y: CGFloat(index) * 30, width: 300, height: 30))
            document.addSubview(row)
            return row
        }
        scroll.documentView = document
        window.contentView = scroll
        return (window, scroll, rows)
    }

    @Test func aRowScrolledOutFromUnderTheRestingPointerLosesItsHover() {
        let list = makeList(rows: 30)
        list.rows[2].setHoveredForTesting(true)

        list.scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))

        #expect(list.rows[2].isHovered == false)
        withExtendedLifetime(list.window) {}
    }

    @Test func aRowThatLeftItsListStopsFollowingThatListsScrolling() {
        let list = makeList(rows: 30)
        let row = list.rows[2]
        row.removeFromSuperview()
        let parked = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        list.window.contentView?.addSubview(parked)
        parked.addSubview(row)
        row.setHoveredForTesting(true)

        list.scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))

        #expect(row.isHovered)
        withExtendedLifetime(list.window) {}
    }
}
