import AppKit
import Testing
@testable import Soprano
import SopranoAgentsCore

@MainActor
struct ComposerListViewTests {
    /// An offscreen window holding `content` and a text view that has the keyboard.
    private func host(_ content: NSView) -> (window: NSWindow, editor: NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = NSTextView(frame: NSRect(x: 0, y: 500, width: 300, height: 40))
        window.contentView?.addSubview(editor)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(content)
        content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor).isActive = true
        content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 120).isActive = true
        window.orderFrontRegardless()
        window.makeFirstResponder(editor)
        render(window)
        return (window, editor)
    }

    private func render(_ window: NSWindow) {
        window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func shownRow(_ title: String, in view: NSView) -> ComposerListRow? {
        if let row = view as? ComposerListRow, row.accessibilityLabel() == title { return row }
        return view.subviews.lazy.compactMap { shownRow(title, in: $0) }.first
    }

    /// Shown rows' frames in the list's coordinates, top to bottom.
    private func rowFrames(in list: ComposerListView) -> [NSRect] {
        func rows(_ view: NSView) -> [ComposerListRow] {
            (view as? ComposerListRow).map { [$0] } ?? view.subviews.flatMap(rows)
        }
        return rows(list).map { $0.convert($0.bounds, to: list) }.sorted { $0.minY < $1.minY }
    }

    /// A list `width` wide, its rows set, in an offscreen window.
    private func layOut(_ models: [ComposerListRow.Model], insets: NSEdgeInsets, width: CGFloat) -> (list: ComposerListView, width: NSLayoutConstraint, window: NSWindow) {
        let list = ComposerListView(maxHeight: 400, insets: insets)
        list.setRows(models, actions: models.map { _ in {} }, highlight: nil)
        let widthConstraint = list.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        let (window, _) = host(list)
        return (list, widthConstraint, window)
    }

    /// Mouse down and up at the row's center, delivered to whatever the window hit-tests there,
    /// as an active window would deliver them.
    private func click(_ row: NSView, in window: NSWindow) {
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        guard let hit = window.contentView?.hitTest(window.contentView!.convert(point, from: nil)) else { return }
        #expect(hit.isDescendant(of: row))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
        }
    }

    @Test func clickingACommandPicksItOnceAndLeavesTheKeyboardWithTheEditor() throws {
        let commands = (0..<145).map { ProviderCommand(name: "cmd\($0)", kind: .command, description: "Command \($0)", source: "Built-in", insertText: "/cmd\($0) ") }
        var picked: [String] = []
        let menu = SlashCommandMenuContent(width: 640) { picked.append($0.name) }
        menu.show(commands, emptyText: "")
        let (window, editor) = host(menu)
        defer { window.orderOut(nil) }

        click(try #require(shownRow("/cmd2", in: menu)), in: window)
        #expect(picked == ["cmd2"])

        for _ in 0..<99 { menu.moveHighlight(by: 1) }
        render(window)
        click(try #require(shownRow("/cmd99", in: menu)), in: window)
        #expect(picked == ["cmd2", "cmd99"])
        #expect(window.firstResponder === editor)
    }

    @Test func clickingAPickerRowRunsThatRowsActionOnce() throws {
        var picked: [Int] = []
        let list = ComposerListView(maxHeight: 280, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 4))
        let models = (0..<20).map { ComposerListRow.Model(title: "Model \($0)", kbd: $0 < 9 ? "⌘\($0 + 1)" : nil, showsCheck: true, isChecked: $0 == 1) }
        list.setRows(models, actions: models.indices.map { index in { picked.append(index) } }, highlight: 1)
        list.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let (window, editor) = host(list)
        defer { window.orderOut(nil) }

        click(try #require(shownRow("Model 3", in: list)), in: window)

        #expect(picked == [3])
        #expect(window.firstResponder === editor)
    }

    @Test func aCommandListBuildsOnlyTheRowsOnScreen() {
        let commands = (0..<145).map { ProviderCommand(name: "cmd\($0)", kind: .command, description: "Command \($0)", source: "Built-in", insertText: "/cmd\($0) ") }
        let menu = SlashCommandMenuContent(width: 640) { _ in }
        menu.show(commands, emptyText: "")
        let (window, _) = host(menu)
        defer { window.orderOut(nil) }

        let shown = rowFrames(in: menu.subviews.compactMap { $0 as? ComposerListView }.first!)
        #expect(!shown.isEmpty && shown.count < 20)
    }

    @Test func wrappingSubtitlesWrapAtTheListsWidthAndRewrapWhenItChanges() throws {
        let long = "Thinks much longer before answering. Hard multi-step problems come out right. Replies get slower and cost more."
        let models = [
            ComposerListRow.Model(title: "One line", subtitle: "Short.", subtitleLines: 1),
            ComposerListRow.Model(title: "Low", subtitle: "Short."),
            ComposerListRow.Model(title: "High", subtitle: long),
        ]
        let (list, width, window) = layOut(models, insets: NSEdgeInsets(), width: 600)
        defer { window.orderOut(nil) }
        let wide = rowFrames(in: list)
        try #require(wide.count == 3)
        #expect(wide[1].height == wide[0].height)
        #expect(zip(wide, wide.dropFirst()).allSatisfy { abs($1.minY - $0.maxY - 2) < 0.5 })

        width.constant = 220
        render(window)
        let narrow = rowFrames(in: list)
        try #require(narrow.count == 3)
        #expect(narrow[1].height == narrow[0].height)
        #expect(narrow[2].height > wide[2].height)
        #expect(zip(narrow, narrow.dropFirst()).allSatisfy { abs($1.minY - $0.maxY - 2) < 0.5 })
    }

    @Test func aListWithoutTopPaddingStartsAtItsEdgeAndShowsEveryRowWithoutScrolling() throws {
        let models = [ComposerListRow.Model(title: "Current checkout", showsCheck: true), ComposerListRow.Model(title: "New worktree", showsCheck: true)]
        let (list, _, window) = layOut(models, insets: NSEdgeInsets(top: 0, left: 4, bottom: 4, right: 4), width: 200)
        defer { window.orderOut(nil) }
        let rows = rowFrames(in: list)
        try #require(rows.count == 2)
        let top = list.isFlipped ? rows[0].minY : list.bounds.maxY - rows[0].maxY
        let bottom = list.isFlipped ? list.bounds.maxY - rows[1].maxY : rows[1].minY
        #expect(abs(top) < 0.5)
        #expect(abs(bottom - 4) < 0.5)
    }
}
