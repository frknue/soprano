import AppKit

/// The Automations list, in Soprano Agents' board language: a search field
/// and New Automation over a card of rows, one per automation (name and
/// prompt, schedule and next run, last run, agent and folder, its state pill
/// and a ⋯ menu). Without automations it offers Orca's four templates instead.
final class AutomationListView: NSView, NSTextFieldDelegate {
    struct Item: Equatable {
        var automation: Automation
        var nextRun: Date?
        var lastRun: AutomationRun?
    }

    var onOpen: ((String) -> Void)?
    var onAction: ((AutomationAction, String) -> Void)?
    /// New Automation, optionally from a template card.
    var onNew: ((AutomationTemplate?) -> Void)?
    /// A row was clicked; the page takes the keyboard back from the search field.
    var onRowClicked: (() -> Void)?
    /// Esc in the search field with nothing to clear.
    var onEscape: (() -> Void)?
    /// Whether the page, which drives this list, has the keyboard; the
    /// selected row then shows the active row fill.
    var isListFocused = false {
        didSet {
            guard isListFocused != oldValue else { return }
            updateRowSelection(scrollIntoView: false)
        }
    }

    private(set) var selectedId: String?
    private var items: [Item] = []
    private var visibleItems: [Item] = []
    private var now = Date()
    /// An automation just saved from the editor: selected once it shows up,
    /// which is after settings.json has been read back.
    private var pendingSelectionId: String?

    private let searchBox = AutomationSearchBox()
    private var searchField: NSTextField { searchBox.field }
    private let newButton = ShellTextButton(title: "New Automation", keycap: "⌘N", variant: .primary)
    private let scrollView = NSScrollView()
    private let pageStack = NSStackView()
    private let rowsStack = NSStackView()
    private var listCard: AutoUICardView!
    private var rows: [String: AutomationListRowView] = [:]
    private var orderedRows: [AutomationListRowView] = []
    private var emptyStateView: NSView?
    private var noMatchesView: NSView?

    private static let toolbarHeight: CGFloat = 60

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("automations-list")
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        searchField.identifier = NSUserInterfaceItemIdentifier("automations-search")
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search automations")
        searchBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchBox)

        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.toolTip = "New Automation (⌘N)"
        addSubview(newButton)

        // The page column: centered, up to the reading width, `px-6`.
        let column = NSLayoutGuide()
        addLayoutGuide(column)
        let columnFill = column.widthAnchor.constraint(equalTo: widthAnchor, constant: -AutomationViews.pagePadding * 2)
        columnFill.priority = AutomationViews.fillPriority

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let document = AutomationFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        pageStack.orientation = .vertical
        pageStack.alignment = .leading
        pageStack.spacing = 20
        pageStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(pageStack)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        let header = AutomationListHeaderView()
        let cardStack = NSStackView(views: [header, rowsStack])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 2
        header.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        rowsStack.widthAnchor.constraint(equalTo: cardStack.widthAnchor).isActive = true
        listCard = AutoUICardView(content: cardStack, inset: 8)
        listCard.identifier = NSUserInterfaceItemIdentifier("automations-table")

        let hug = document.bottomAnchor.constraint(equalTo: pageStack.bottomAnchor, constant: 32)
        hug.priority = .init(1)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: AutomationViews.pagePadding),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: AutomationViews.maxWidth),
            columnFill,

            searchBox.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            searchBox.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.toolbarHeight / 2 + 4),
            // 280 when there is room; narrower rather than widening the window.
            searchBox.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            {
                let preferred = searchBox.widthAnchor.constraint(equalToConstant: 280)
                preferred.priority = AutomationViews.fillPriority
                return preferred
            }(),

            newButton.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            newButton.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            newButton.leadingAnchor.constraint(greaterThanOrEqualTo: searchBox.trailingAnchor, constant: 16),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.toolbarHeight),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            pageStack.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            pageStack.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            pageStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            pageStack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -32),
            hug,
        ])
    }

    // MARK: - Content

    func update(items: [Item], now: Date) {
        self.items = items
        self.now = now
        render()
    }

    /// Selects `id` now, or as soon as it shows up in the list.
    func select(_ id: String) {
        if visibleItems.contains(where: { $0.automation.id == id }) {
            selectedId = id
            updateRowSelection(scrollIntoView: true)
        } else {
            pendingSelectionId = id
        }
    }

    /// Empties the search field; false when it was already empty.
    func clearSearch() -> Bool {
        guard !searchField.stringValue.isEmpty else { return false }
        searchField.stringValue = ""
        render()
        return true
    }

    private func render() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleItems = query.isEmpty ? items : items.filter { Self.matches($0, query: query) }
        if let pendingSelectionId, visibleItems.contains(where: { $0.automation.id == pendingSelectionId }) {
            selectedId = pendingSelectionId
            self.pendingSelectionId = nil
        }
        if !visibleItems.contains(where: { $0.automation.id == selectedId }) {
            selectedId = visibleItems.first?.automation.id
        }

        if items.isEmpty {
            orderedRows = []
            rows.removeAll()
            rowsStack.setArrangedSubviews([])
            noMatchesView = nil
            let empty = emptyStateView ?? makeEmptyState()
            emptyStateView = empty
            setPageViews([empty])
            return
        }
        emptyStateView = nil
        if visibleItems.isEmpty {
            orderedRows = []
            let noMatches = noMatchesView ?? makeNoMatches()
            noMatchesView = noMatches
            setPageViews([noMatches])
            return
        }
        noMatchesView = nil

        var reusable = rows
        rows.removeAll()
        orderedRows = visibleItems.map { item in
            let row = reusable.removeValue(forKey: item.automation.id) ?? makeRow()
            row.configure(item: item, now: now)
            rows[item.automation.id] = row
            return row
        }
        // Rows filtered out by the search stay built for when it is cleared.
        for (id, row) in reusable {
            rows[id] = row
        }
        if rowsStack.arrangedSubviews != orderedRows {
            rowsStack.setArrangedSubviews(orderedRows) { [rowsStack] view in
                view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
        }
        setPageViews([listCard])
        updateRowSelection(scrollIntoView: false)
    }

    private func setPageViews(_ views: [NSView]) {
        guard pageStack.arrangedSubviews != views else { return }
        pageStack.setArrangedSubviews(views) { [pageStack] view in
            view.widthAnchor.constraint(equalTo: pageStack.widthAnchor).isActive = true
        }
    }

    private static func matches(_ item: Item, query: String) -> Bool {
        let automation = item.automation
        return [
            automation.name,
            AutomationFormat.agentName(automation.agentId),
            automation.agentId,
            automation.folder,
            AutomationFormat.path(automation.folder),
            automation.prompt,
        ].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func makeRow() -> AutomationListRowView {
        let row = AutomationListRowView()
        row.onOpen = { [weak self, weak row] in
            guard let self, let id = row?.automationId else { return }
            self.selectedId = id
            self.updateRowSelection(scrollIntoView: false)
            self.onRowClicked?()
            self.onOpen?(id)
        }
        row.onAction = { [weak self, weak row] action in
            guard let self, let id = row?.automationId else { return }
            self.onAction?(action, id)
        }
        return row
    }

    // MARK: - Selection

    func moveSelection(by delta: Int) {
        guard !orderedRows.isEmpty else { return }
        let current = orderedRows.firstIndex { $0.automationId == selectedId } ?? 0
        let next = min(max(0, current + delta), orderedRows.count - 1)
        selectedId = orderedRows[next].automationId
        updateRowSelection(scrollIntoView: true)
    }

    func activateSelection() {
        guard let selectedId, rows[selectedId] != nil, !orderedRows.isEmpty else { return }
        onOpen?(selectedId)
    }

    private func updateRowSelection(scrollIntoView: Bool) {
        for row in orderedRows {
            row.setSelected(row.automationId == selectedId, focused: isListFocused)
        }
        guard scrollIntoView, let selectedId, let row = rows[selectedId] else { return }
        layoutSubtreeIfNeeded()
        row.scrollToVisible(row.bounds)
    }

    // MARK: - Search field

    func controlTextDidChange(_ notification: Notification) {
        render()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        searchBox.isEditing = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        searchBox.isEditing = false
    }

    /// The arrows move the selection and Return opens it while the search
    /// field has the keyboard, as in Orca.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            if !clearSearch() {
                onEscape?()
            }
        default:
            return false
        }
        return true
    }

    @objc private func newClicked() {
        onNew?(nil)
    }

    // MARK: - Empty states

    private func makeNoMatches() -> NSView {
        let label = AutoUIThemedLabel("No automations match.", size: Typography.rowSize) { $0.mutedForeground }
        let stack = NSStackView(views: [label])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        return AutoUICardView(content: stack, inset: 8)
    }

    /// "No automations yet" over Orca's four templates and a blank card.
    private func makeEmptyState() -> NSView {
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("automations-empty")
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = AutoUIThemedLabel("No automations yet", size: 16, weight: .semibold)
        let message = AutoUIThemedLabel(
            "An automation sends a prompt to an agent on a schedule while Soprano is open.",
            size: Typography.bodySize
        ) { $0.mutedForeground }
        let heading = AutoUICardHeader.make("Start from a template", inRowCard: false)

        var cards: [NSView] = AutomationTemplate.all.map { template in
            AutomationTemplateCardView(template: template) { [weak self] in
                self?.onNew?(template)
            }
        }
        cards.append(AutomationTemplateCardView(template: nil) { [weak self] in
            self?.onNew?(nil)
        })
        cards.append(NSView())
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        for start in stride(from: 0, to: cards.count, by: 3) {
            let row = NSStackView(views: Array(cards[start..<min(start + 3, cards.count)]))
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = 12
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }

        for view in [title, message, heading, grid] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            message.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            message.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            message.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            heading.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 28),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
        ])
        return container
    }
}

/// The list's search field: Agents' input box (`h-8 rounded-lg border-input`,
/// dark `bg-input/32`, a primary ring while editing) with a search icon.
final class AutomationSearchBox: PaletteView {
    let field = NSTextField(string: "")
    private let icon = NSImageView()

    var isEditing = false {
        didSet { applyPalette(palette) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        layer?.borderWidth = 1
        icon.image = NSImage.symbol(Icon.search, size: 13)
        icon.setAccessibilityElement(false)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.font = Typography.ui(Typography.bodySize)
        for view in [icon, field] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.input.shellScaled(by: 0.32) : palette.background).cgColor
        layer?.borderColor = (isEditing ? palette.primary.shellScaled(by: 0.7) : palette.input).cgColor
        icon.contentTintColor = palette.mutedForeground
        field.textColor = palette.foreground
        field.placeholderAttributedString = NSAttributedString(string: "Search automations", attributes: [
            .foregroundColor: palette.placeholder,
            .font: Typography.ui(Typography.bodySize),
        ])
        (field.currentEditor() as? NSTextView)?.insertionPointColor = palette.foreground
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }
}

// MARK: - Columns

/// Where the list's columns sit inside a row: Name takes what the fixed
/// columns leave, after the row's 8 pt padding.
enum AutomationListColumns {
    static let padding: CGFloat = 8
    static let gap: CGFloat = 16
    static let menuWidth: CGFloat = 24
    private static let fixed: [CGFloat] = [170, 120, 160, 92]

    struct Frames {
        var name: ClosedRange<CGFloat>
        var schedule: ClosedRange<CGFloat>
        var lastRun: ClosedRange<CGFloat>
        var agent: ClosedRange<CGFloat>
        var state: ClosedRange<CGFloat>
        var menu: ClosedRange<CGFloat>
    }

    static func frames(width: CGFloat) -> Frames {
        let nameWidth = max(160, width - padding * 2 - menuWidth - gap * 5 - fixed.reduce(0, +))
        let widths = [nameWidth] + fixed + [menuWidth]
        var x = padding
        var ranges: [ClosedRange<CGFloat>] = []
        for width in widths {
            ranges.append(x...(x + width))
            x += width + gap
        }
        return Frames(
            name: ranges[0],
            schedule: ranges[1],
            lastRun: ranges[2],
            agent: ranges[3],
            state: ranges[4],
            menu: ranges[5]
        )
    }
}

private extension ClosedRange where Bound == CGFloat {
    var width: CGFloat { upperBound - lowerBound }
}

/// The list's column titles.
final class AutomationListHeaderView: NSView {
    static let height: CGFloat = 30

    private let labels: [NSTextField]
    private static let titles = ["Name", "Schedule", "Last run", "Agent", "Status"]

    override init(frame frameRect: NSRect) {
        labels = Self.titles.map(AutomationViews.columnTitle)
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        labels.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let frames = AutomationListColumns.frames(width: bounds.width)
        let columns = [frames.name, frames.schedule, frames.lastRun, frames.agent, frames.state]
        for (label, column) in zip(labels, columns) {
            let height = label.intrinsicContentSize.height
            label.frame = NSRect(x: column.lowerBound, y: floor((bounds.height - height) / 2), width: column.width, height: height)
        }
    }
}

// MARK: - Row

/// One automation, 52 pt, two lines where a column has a detail (the prompt
/// under the name, the next run under the schedule, when under the last run,
/// the folder under the agent), its state pill and the ⋯ button; a rounded
/// row fill on hover and selection. Clicking opens its detail; the ⋯ button
/// and the context menu offer Run Now, Edit, Pause/Resume and Delete.
final class AutomationListRowView: NSView {
    static let height: CGFloat = 52

    var onOpen: (() -> Void)?
    var onAction: ((AutomationAction) -> Void)?
    private(set) var automationId: String?

    private let background = ShellRowSurfaceView()
    private let nameLabel = AutoUIThemedLabel("", size: Typography.rowSize, weight: .medium)
    private let promptLabel = AutoUIThemedLabel("", size: Typography.smallSize) { $0.mutedForeground }
    private let scheduleLabel = AutoUIThemedLabel("", size: Typography.rowSize)
    private let nextRunLabel = AutoUIThemedLabel("", size: Typography.smallSize) { $0.mutedForeground }
    private let lastRunPill = AutoUIPillView()
    private let lastRunLabel = AutoUIThemedLabel("", size: Typography.rowSize) { $0.mutedForeground }
    private let lastRunDetailLabel = AutoUIThemedLabel("", size: Typography.smallSize) { $0.mutedForeground }
    private let agentLabel = AutoUIThemedLabel("", size: Typography.rowSize)
    private let folderLabel = AutoUIThemedLabel("", size: Typography.smallSize) { $0.mutedForeground }
    private let statePill = AutoUIPillView()
    private let menuButton = ShellGhostButton(symbol: "ellipsis", label: "Automation Actions", size: 24, symbolSize: 13)
    private var item: AutomationListView.Item?
    private var isSelected = false
    private var isFocused = false
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("automations-row")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        background.translatesAutoresizingMaskIntoConstraints = true
        background.horizontalInset = 0
        addSubview(background)
        folderLabel.font = Typography.mono(Typography.smallSize)
        folderLabel.lineBreakMode = .byTruncatingHead
        for view in [
            nameLabel, promptLabel, scheduleLabel, nextRunLabel, lastRunPill, lastRunLabel,
            lastRunDetailLabel, agentLabel, folderLabel, statePill,
        ] as [NSView] {
            addSubview(view)
        }
        menuButton.target = self
        menuButton.action = #selector(menuClicked(_:))
        // Laid out by frame.
        menuButton.translatesAutoresizingMaskIntoConstraints = true
        menuButton.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        addSubview(menuButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Shows `item`. Relative times move on without the item changing, so
    /// every update rerenders the row.
    func configure(item: AutomationListView.Item, now: Date) {
        self.item = item
        automationId = item.automation.id
        render(now: now)
    }

    private func render(now: Date) {
        guard let item else { return }
        let automation = item.automation

        nameLabel.stringValue = automation.name
        promptLabel.stringValue = AutomationFormat.firstLine(of: automation.prompt)

        switch automation.cadence {
        case .custom(let expression):
            scheduleLabel.font = Typography.mono(Typography.rowSize)
            scheduleLabel.stringValue = expression
        case let cadence:
            scheduleLabel.font = Typography.ui(Typography.rowSize)
            scheduleLabel.stringValue = cadence.summary()
        }
        if let nextRun = item.nextRun {
            nextRunLabel.stringValue = "Next \(AutomationFormat.relative(nextRun, now: now))"
            nextRunLabel.toolTip = AutomationFormat.dateTime(nextRun)
        } else {
            nextRunLabel.stringValue = automation.enabled ? "No next run" : "Paused"
            nextRunLabel.toolTip = nil
        }

        if let lastRun = item.lastRun {
            lastRunPill.isHidden = false
            lastRunLabel.isHidden = true
            lastRunPill.configure(AutomationPill.run(lastRun.status), now: now)
            lastRunPill.toolTip = lastRun.message
            lastRunDetailLabel.stringValue = AutomationFormat.relative(lastRun.finishedAt ?? lastRun.startedAt, now: now)
        } else {
            lastRunPill.isHidden = true
            lastRunLabel.isHidden = false
            lastRunLabel.stringValue = "Never"
            lastRunDetailLabel.stringValue = ""
        }

        agentLabel.stringValue = AutomationFormat.agentName(automation.agentId)
        folderLabel.stringValue = AutomationFormat.path(automation.folder)
        folderLabel.toolTip = automation.folder
        statePill.configure(AutomationPill.state(of: automation, lastRun: item.lastRun), now: now)

        setAccessibilityLabel("\(automation.name), \(automation.cadence.summary()), \(automation.enabled ? "enabled" : "paused")")
        needsLayout = true
    }

    func setSelected(_ selected: Bool, focused: Bool) {
        guard selected != isSelected || focused != isFocused else { return }
        isSelected = selected
        isFocused = focused
        setAccessibilitySelected(selected)
        updateBackground()
    }

    private func updateBackground() {
        if isSelected {
            background.style = isFocused ? .selected : .selectedUnfocused
        } else {
            background.style = isHovered ? .hover : .none
        }
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let frames = AutomationListColumns.frames(width: bounds.width)
        let firstLine: CGFloat = 17
        let secondLine: CGFloat = 35
        let middle = bounds.height / 2

        place(nameLabel, in: frames.name, centerY: firstLine)
        place(promptLabel, in: frames.name, centerY: secondLine)
        place(scheduleLabel, in: frames.schedule, centerY: firstLine)
        place(nextRunLabel, in: frames.schedule, centerY: secondLine)

        let lastHasDetail = !lastRunDetailLabel.stringValue.isEmpty
        let lastLine = lastHasDetail ? firstLine : middle
        let lastRange = frames.lastRun
        lastRunPill.frame = NSRect(
            x: lastRange.lowerBound,
            y: floor(lastLine - 10),
            width: min(lastRunPill.intrinsicContentSize.width, lastRange.width),
            height: 20
        )
        place(lastRunLabel, in: lastRange, centerY: lastLine)
        place(lastRunDetailLabel, in: lastRange, centerY: secondLine)
        place(agentLabel, in: frames.agent, centerY: firstLine)
        place(folderLabel, in: frames.agent, centerY: secondLine)
        statePill.frame = NSRect(
            x: frames.state.lowerBound,
            y: floor(middle - 10),
            width: min(statePill.intrinsicContentSize.width, frames.state.width),
            height: 20
        )

        menuButton.frame = NSRect(x: frames.menu.lowerBound, y: floor(middle - 12), width: 24, height: 24)
    }

    private func place(_ label: NSTextField, in column: ClosedRange<CGFloat>, centerY: CGFloat) {
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: column.lowerBound, y: floor(centerY - height / 2), width: max(0, column.width), height: height)
    }

    // MARK: Input

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === menuButton ? hit : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            updateBackground()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, !event.modifierFlags.contains(.control) else {
            super.mouseDown(with: event)
            return
        }
        onOpen?()
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        actionMenu()
    }

    private func actionMenu() -> NSMenu? {
        guard let automation = item?.automation else { return nil }
        return AutomationAction.menu(for: automation) { [weak self] action in
            self?.onAction?(action)
        }
    }

    @objc private func menuClicked(_ sender: NSButton) {
        actionMenu()?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
}

// MARK: - Templates

/// Orca's starting points, verbatim: a name, a prompt, a preset schedule
/// and how late a missed run may still start.
struct AutomationTemplate: Equatable {
    let category: String
    let label: String
    let name: String
    let description: String
    let prompt: String
    let cadence: AutomationCadence
    let graceMinutes: Int

    static let all: [AutomationTemplate] = [
        AutomationTemplate(
            category: "Repo health",
            label: "Weekday repo audit",
            name: "Weekday repo audit",
            description: "Check dependencies, failing tests, and risky open changes each weekday.",
            prompt: "Review the repository health. Check dependency updates, failing tests, lint/typecheck status, and risky open changes. Summarize findings and suggest the next action.",
            cadence: .weekdays(hour: 9, minute: 0),
            graceMinutes: 720
        ),
        AutomationTemplate(
            category: "Release prep",
            label: "Release readiness",
            name: "Release readiness review",
            description: "Prepare a weekly release risk summary from the current project state.",
            prompt: "Prepare a release readiness summary. Look for blockers, unmerged risky changes, missing validation, and documentation gaps. End with a concise release/no-release recommendation.",
            cadence: .weekly(weekday: 4, hour: 14, minute: 0),
            graceMinutes: 1_440
        ),
        AutomationTemplate(
            category: "Recurring review",
            label: "Daily change review",
            name: "Daily change review",
            description: "Scan recent work and call out correctness, UX, and test coverage risks.",
            prompt: "Review recent changes in this workspace. Focus on correctness risks, UX regressions, missing tests, and follow-up tasks. Keep the report short and actionable.",
            cadence: .daily(hour: 16, minute: 30),
            graceMinutes: 180
        ),
        AutomationTemplate(
            category: "Maintenance",
            label: "Hourly queue check",
            name: "Hourly maintenance check",
            description: "Look for stuck work, stale generated files, and failed local validation.",
            prompt: "Check for stuck work, stale generated files, failing validation, and anything that needs human attention. Report only actionable issues.",
            cadence: .hourly(minute: 15),
            graceMinutes: 30
        ),
    ]
}

/// A template card (category, name, description, schedule), or with no
/// template the blank "New automation" card: the board card look
/// (`rounded-xl border-border/60 bg-card/40`) with the accent fill on hover.
final class AutomationTemplateCardView: InteractiveView {
    private static let height: CGFloat = 132

    init(template: AutomationTemplate?, action: @escaping () -> Void) {
        super.init(frame: .zero)
        onClick = action
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = Radius.xl
        layer?.borderWidth = 1
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        build(template: template)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(template.map { "\($0.label) template" } ?? "New automation")
        applyPalette(palette)
    }

    private func build(template: AutomationTemplate?) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let title: String
        let detail: String
        let footer: String
        if let template {
            let category = AutoUIThemedLabel(template.category, size: Typography.smallSize, weight: .medium) { $0.mutedForeground }
            stack.addArrangedSubview(category)
            stack.setCustomSpacing(6, after: category)
            title = template.label
            detail = template.description
            footer = template.cadence.summary()
        } else {
            let image = NSImageView(image: NSImage.symbol("plus", size: 13) ?? NSImage())
            PaletteCenter.shared.addObserver(image) { [weak image] palette in image?.contentTintColor = palette.mutedForeground }
            image.contentTintColor = PaletteCenter.shared.palette.mutedForeground
            stack.addArrangedSubview(image)
            stack.setCustomSpacing(6, after: image)
            title = "New automation"
            detail = "Write your own prompt and schedule."
            footer = ""
        }
        stack.addArrangedSubview(AutoUIThemedLabel(title, size: Typography.bodySize, weight: .semibold))
        let description = AutoUIThemedLabel(detail, size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
        description.maximumNumberOfLines = 3
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(description)
        description.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let footerLabel = AutoUIThemedLabel(footer, size: Typography.smallSize, weight: .medium) { $0.mutedForeground }
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            footerLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered ? palette.accent : palette.card.withAlphaComponent(0.4)).cgColor
        layer?.borderColor = palette.border.withAlphaComponent(palette.border.alphaComponent * 0.6).cgColor
        alphaValue = isPressed ? 0.85 : 1
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
