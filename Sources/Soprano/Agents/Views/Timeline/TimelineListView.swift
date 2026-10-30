import AppKit
import SopranoAgentsCore

/// The timeline's document view: a virtualized column of rows in the centered chat lane.
///
/// - Heights come from per-kind sizing views (`layoutRow(width:)`), cached by row value and width,
///   so a streaming delta re-measures only the row that changed.
/// - Only rows near the visible rect get views; views are reused per row kind.
/// - It stays pinned to the bottom while the user has not scrolled up; otherwise the first visible
///   row keeps its place when rows above it change.
@MainActor
final class TimelineListView: NSView {
    weak var rowDelegate: TimelineRowDelegate?
    /// The pinned state changed (the controller shows or hides the jump pill).
    var onPinnedChange: ((Bool) -> Void)?

    /// Top strip a floating overlay covers (the find bar); revealing keeps matches below it.
    var revealTopInset: CGFloat = 0

    /// `h-3 sm:h-4` top spacer.
    var topPadding: CGFloat = 16
    /// Space the floating composer covers.
    var bottomInset: CGFloat = 0 {
        didSet {
            guard bottomInset != oldValue else { return }
            updateDocumentHeight()
            if isPinnedToBottom { scrollToEnd() }
            tile()
        }
    }

    private(set) var rows: [TimelineRow] = []
    private(set) var isPinnedToBottom = true
    private var heights: [CGFloat] = []
    private var offsets: [CGFloat] = []
    private var measuredWidth: CGFloat = -1

    private struct HeightKey: Hashable {
        var row: TimelineRow
        var width: CGFloat
    }

    private var heightCache: [HeightKey: CGFloat] = [:]
    private var visibleViews: [String: TimelineRowView] = [:]
    private var configuredRows: [String: (row: TimelineRow, width: CGFloat)] = [:]
    private var pool: [String: [TimelineRowView]] = [:]
    private var viewKinds: [ObjectIdentifier: String] = [:]
    private var sizers: [String: TimelineRowView] = [:]
    private var isScrollingProgrammatically = false

    var findHighlights: [String: [FindHighlight]] = [:] {
        didSet {
            for (id, view) in visibleViews {
                view.applyFind(findHighlights[id] ?? [])
            }
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var clipView: NSClipView? { enclosingScrollView?.contentView }

    /// Width of the chat lane: `--chat-content-max-width` with the page gutters.
    var laneWidth: CGFloat { max(0, min(Metrics.chatMaxWidth, bounds.width - Metrics.gutter * 2)) }
    private var laneX: CGFloat { floor((bounds.width - laneWidth) / 2) }

    // MARK: Rows

    func setRows(_ newRows: [TimelineRow], scrollToEnd forceEnd: Bool = false) {
        let anchor = forceEnd || isPinnedToBottom ? nil : currentAnchor()
        // Unchanged rows keep their height without re-hashing their (possibly long) text.
        var previous: [String: (row: TimelineRow, height: CGFloat)] = [:]
        if abs(laneWidth - measuredWidth) < 0.5, heights.count == rows.count {
            for (row, height) in zip(rows, heights) { previous[row.id] = (row, height - row.bottomSpacing) }
        }
        rows = newRows
        recomputeHeights(reusing: previous)
        if forceEnd || isPinnedToBottom {
            setPinned(true)
            scrollToEnd()
        } else if let anchor, let index = rows.firstIndex(where: { $0.id == anchor.id }) {
            scroll(toY: offsets[index] + anchor.delta)
        }
        tile()
    }

    func index(ofRow id: String) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    func view(forRow id: String) -> TimelineRowView? {
        visibleViews[id]
    }

    var visibleRowViews: [TimelineRowView] { Array(visibleViews.values) }

    private func currentAnchor() -> (id: String, delta: CGFloat)? {
        guard let clip = clipView, !rows.isEmpty, offsets.count == rows.count else { return nil }
        let top = clip.bounds.minY
        guard let index = firstIndex(atOrBelow: top) else { return nil }
        return (rows[index].id, top - offsets[index])
    }

    // MARK: Measuring

    /// Reuse key of the view kind that shows `content`.
    static func kind(of content: TimelineRowContent) -> String {
        switch content {
        case .user: "user"
        case .fold: "fold"
        case .working: "working"
        case .assistant: "assistant"
        case .workGroup: "workGroup"
        case .workEntry: "workEntry"
        case .liveWork, .thinking: "liveWork"
        case .approval: "approval"
        case .plan: "plan"
        case .todo: "todo"
        case .error: "error"
        case .notice: "notice"
        case .changedFiles: "changedFiles"
        case .queued: "queued"
        case .empty: "empty"
        }
    }

    static func makeView(for content: TimelineRowContent) -> TimelineRowView {
        switch content {
        case .user: UserMessageRowView(frame: .zero)
        case .fold: FoldRowView(frame: .zero)
        case .working: WorkingRowView(frame: .zero)
        case .assistant: AssistantRowView(frame: .zero)
        case .workGroup: WorkGroupRowView(frame: .zero)
        case .workEntry: WorkEntryRowView(frame: .zero)
        case .liveWork, .thinking: LiveWorkRowView(frame: .zero)
        case .approval: ApprovalRowView(frame: .zero)
        case .plan: PlanRowView(frame: .zero)
        case .todo: TodoRowView(frame: .zero)
        case .error: ErrorRowView(frame: .zero)
        case .notice: NoticeRowView(frame: .zero)
        case .changedFiles: ChangedFilesRowView(frame: .zero)
        case .queued: QueuedMessageRowView(frame: .zero)
        case .empty: EmptyRowView(frame: .zero)
        }
    }

    private func measure(_ row: TimelineRow, width: CGFloat) -> CGFloat {
        let key = HeightKey(row: row, width: width)
        if let cached = heightCache[key] { return cached }
        let kind = Self.kind(of: row.content)
        let sizer = sizers[kind] ?? {
            let view = Self.makeView(for: row.content)
            sizers[kind] = view
            return view
        }()
        sizer.configure(row)
        let height = ceil(sizer.layoutRow(width: width))
        if heightCache.count > 5000 { heightCache.removeAll() }
        heightCache[key] = height
        return height
    }

    private func recomputeHeights(reusing previous: [String: (row: TimelineRow, height: CGFloat)] = [:]) {
        let width = laneWidth
        measuredWidth = width
        guard width > 0 else {
            heights = rows.map { _ in 0 }
            offsets = rows.map { _ in topPadding }
            return
        }
        heights = rows.map { row in
            if let known = previous[row.id], known.row.content == row.content { return known.height + row.bottomSpacing }
            return measure(row, width: width) + row.bottomSpacing
        }
        var y = topPadding
        offsets = heights.map { height in
            defer { y += height }
            return y
        }
        updateDocumentHeight()
    }

    private var contentHeight: CGFloat {
        topPadding + heights.reduce(0, +) + bottomInset
    }

    private func updateDocumentHeight() {
        let visible = clipView?.bounds.height ?? bounds.height
        let height = max(contentHeight, visible)
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged, abs(laneWidth - measuredWidth) > 0.5 {
            let anchor = isPinnedToBottom ? nil : currentAnchor()
            recomputeHeights()
            if isPinnedToBottom {
                scrollToEnd()
            } else if let anchor, let index = rows.firstIndex(where: { $0.id == anchor.id }) {
                scroll(toY: offsets[index] + anchor.delta)
            }
            tile()
        }
    }

    /// The clip view resized (window or composer change).
    func clipDidResize() {
        updateDocumentHeight()
        if isPinnedToBottom { scrollToEnd() }
        tile()
    }

    // MARK: Tiling

    private func firstIndex(atOrBelow y: CGFloat) -> Int? {
        guard !offsets.isEmpty else { return nil }
        var low = 0
        var high = offsets.count - 1
        while low < high {
            let middle = (low + high) / 2
            if offsets[middle] + heights[middle] <= y { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Places views for the rows near the visible rect and recycles the rest.
    func tile() {
        guard let clip = clipView, heights.count == rows.count else { return }
        let visible = clip.bounds.insetBy(dx: 0, dy: -320)
        var wanted: Set<String> = []
        if let first = firstIndex(atOrBelow: max(0, visible.minY)) {
            var index = first
            while index < rows.count, offsets[index] < visible.maxY {
                wanted.insert(rows[index].id)
                place(index)
                index += 1
            }
        }
        for (id, view) in visibleViews where !wanted.contains(id) {
            view.removeFromSuperview()
            view.setHovered(false)
            pool[viewKinds[ObjectIdentifier(view)] ?? "", default: []].append(view)
            visibleViews[id] = nil
            configuredRows[id] = nil
        }
    }

    private func place(_ index: Int) {
        let row = rows[index]
        let kind = Self.kind(of: row.content)
        var view = visibleViews[row.id]
        if let existing = view, viewKinds[ObjectIdentifier(existing)] != kind {
            existing.removeFromSuperview()
            visibleViews[row.id] = nil
            configuredRows[row.id] = nil
            view = nil
        }
        let width = laneWidth
        let rowView: TimelineRowView
        if let view {
            rowView = view
        } else {
            rowView = pool[kind]?.popLast() ?? Self.makeView(for: row.content)
            viewKinds[ObjectIdentifier(rowView)] = kind
            rowView.delegate = rowDelegate
            addSubview(rowView)
            visibleViews[row.id] = rowView
        }
        let height = heights[index] - row.bottomSpacing
        let frame: NSRect
        if case .empty = row.content {
            let visibleHeight = (clipView?.bounds.height ?? bounds.height) - bottomInset - topPadding
            frame = NSRect(x: laneX, y: topPadding, width: width, height: max(height, visibleHeight))
        } else {
            frame = NSRect(x: laneX, y: offsets[index], width: width, height: height)
        }
        if let configured = configuredRows[row.id], configured.row == row, configured.width == width {
            if rowView.frame != frame { rowView.frame = frame }
            return
        }
        rowView.frame = frame
        rowView.configure(row)
        _ = rowView.layoutRow(width: width)
        rowView.applyFind(findHighlights[row.id] ?? [])
        configuredRows[row.id] = (row, width)
    }

    // MARK: Scrolling

    func scrollToEnd() {
        guard let clip = clipView else { return }
        let target = max(0, frame.height - clip.bounds.height)
        scroll(toY: target)
    }

    private func scroll(toY y: CGFloat) {
        guard let clip = clipView, let scrollView = enclosingScrollView else { return }
        let maxY = max(0, frame.height - clip.bounds.height)
        isScrollingProgrammatically = true
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
        isScrollingProgrammatically = false
    }

    /// Scrolls so `rect` (in a row's coordinates, or the whole row) sits in view.
    func reveal(rowID: String, rect: NSRect? = nil) {
        guard let index = index(ofRow: rowID), let clip = clipView else { return }
        let rowTop = offsets[index]
        let target: NSRect = rect.map { $0.offsetBy(dx: laneX, dy: rowTop) } ?? NSRect(x: laneX, y: rowTop, width: laneWidth, height: heights[index])
        let visibleHeight = clip.bounds.height - bottomInset - revealTopInset
        let visibleTop = clip.bounds.minY + revealTopInset
        if target.minY >= visibleTop + 8, target.maxY <= visibleTop + visibleHeight - 8 { return }
        let y = target.midY - visibleHeight / 2 - revealTopInset
        setPinned(false)
        scroll(toY: y)
        updatePinnedFromScroll()
        tile()
    }

    /// The clip view scrolled: retile, and track whether the user left the bottom.
    func didScroll() {
        if !isScrollingProgrammatically { updatePinnedFromScroll() }
        tile()
    }

    private func updatePinnedFromScroll() {
        guard let clip = clipView else { return }
        let distance = frame.height - clip.bounds.maxY
        setPinned(distance <= 8)
    }

    private func setPinned(_ pinned: Bool) {
        guard pinned != isPinnedToBottom else { return }
        isPinnedToBottom = pinned
        onPinnedChange?(pinned)
    }

    /// Jump to latest.
    func jumpToEnd() {
        setPinned(true)
        scrollToEnd()
        tile()
    }

    // MARK: Keys

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let clip = clipView else { return super.keyDown(with: event) }
        let page = max(40, clip.bounds.height - bottomInset - 60)
        let y = clip.bounds.minY
        switch event.keyCode {
        case 125: scrollUser(toY: y + 48) // down
        case 126: scrollUser(toY: y - 48) // up
        case 121, 49: scrollUser(toY: event.modifierFlags.contains(.shift) && event.keyCode == 49 ? y - page : y + page) // page down, space
        case 116: scrollUser(toY: y - page) // page up
        case 115: scrollUser(toY: 0) // home
        case 119: jumpToEnd() // end
        default: super.keyDown(with: event)
        }
    }

    private func scrollUser(toY y: CGFloat) {
        guard let clip = clipView, let scrollView = enclosingScrollView else { return }
        let maxY = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }
}

// MARK: - Find

/// A find match: a row, one of its searchable units (Markdown segments), a range in that unit.
struct TimelineFindMatch: Hashable {
    var rowID: String
    var unit: Int
    var range: NSRange
}

/// Find in thread: searches the rendered text of messages and plans (what T3 Code marks
/// `data-thread-find-text`), case- and diacritic-insensitive.
enum TimelineFind {
    /// Searchable units of a row, in order (one per rendered Markdown segment).
    @MainActor
    static func units(of row: TimelineRow) -> [String] {
        switch row.content {
        case let .user(model): MarkdownRenderer.render(model.message.text, style: .user).searchableTexts
        case let .assistant(model): MarkdownRenderer.render(model.text, style: .assistant).searchableTexts
        case let .plan(model): MarkdownRenderer.render(MarkdownDocument.strippingTitle(model.markdown), style: .plan).searchableTexts
        default: []
        }
    }

    static func matches(of query: String, in rows: [(id: String, units: [String])]) -> [TimelineFindMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var result: [TimelineFindMatch] = []
        for row in rows {
            for (unit, text) in row.units.enumerated() {
                let haystack = text as NSString
                var searchRange = NSRange(location: 0, length: haystack.length)
                while searchRange.length > 0 {
                    let found = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                    guard found.location != NSNotFound, found.length > 0 else { break }
                    result.append(TimelineFindMatch(rowID: row.id, unit: unit, range: found))
                    let next = NSMaxRange(found)
                    searchRange = NSRange(location: next, length: haystack.length - next)
                }
            }
        }
        return result
    }

    /// "2/5", "0/0" (T3 Code's `formatThreadFindCount`).
    static func countLabel(index: Int, total: Int) -> String {
        total <= 0 ? "0/0" : "\(min(max(index, 0), total - 1) + 1)/\(total)"
    }
}
