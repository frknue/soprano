import AppKit

/// The Automations list: a search field and New Automation over a table of
/// every automation (Name, Schedule, Folder, Next run, Last run, Agent and a
/// ⋯ menu). Without automations it offers Orca's four templates instead.
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
    /// selected row then carries the pencil tick.
    var isListFocused = false {
        didSet {
            guard isListFocused != oldValue else { return }
            updateRowSelection(scrollIntoView: false)
        }
    }

    private(set) var selectedId: String?
    private var theme: AppTheme
    private var items: [Item] = []
    private var visibleItems: [Item] = []
    private var now = Date()
    /// An automation just saved from the editor: selected once it shows up,
    /// which is after settings.json has been read back.
    private var pendingSelectionId: String?

    private let searchSurface: ChromeFieldView
    private let searchIcon = NSImageView()
    private let searchField = NSTextField(string: "")
    private let newButton: ChromeButton
    private let toolbarRule: ChromeRuleView
    private let headerView: AutomationListHeaderView
    private let headerRule: ChromeRuleView
    private let scrollView = NSScrollView()
    private let rowsStack = NSStackView()
    private var rows: [String: AutomationListRowView] = [:]
    private var orderedRows: [AutomationListRowView] = []
    private var emptyStateView: NSView?
    private var noMatchesLabel: NSTextField?

    private static let toolbarHeight: CGFloat = 52

    init(theme: AppTheme) {
        self.theme = theme
        searchSurface = ChromeFieldView(theme: theme)
        newButton = ChromeButton(title: "New Automation", theme: theme, kind: .ink, keycap: "⌘N")
        toolbarRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        headerView = AutomationListHeaderView(theme: theme)
        headerRule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("automations-list")
        build()
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build() {
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        searchIcon.setAccessibilityElement(false)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchSurface.addSubview(searchIcon)

        searchField.identifier = NSUserInterfaceItemIdentifier("automations-search")
        searchField.delegate = self
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.setAccessibilityLabel("Search automations")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchSurface.addSubview(searchField)
        addSubview(searchSurface)

        newButton.target = self
        newButton.action = #selector(newClicked)
        newButton.toolTip = "New Automation (⌘N)"
        addSubview(newButton)

        addSubview(toolbarRule)
        addSubview(headerView)
        addSubview(headerRule)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let document = AutomationFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: Chrome.Space.page, right: 0)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)

        NSLayoutConstraint.activate([
            searchSurface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.page),
            searchSurface.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.toolbarHeight / 2),
            searchSurface.widthAnchor.constraint(equalToConstant: 280),
            searchSurface.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            searchIcon.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 8),
            searchIcon.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),

            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.page),
            newButton.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            newButton.leadingAnchor.constraint(greaterThanOrEqualTo: searchSurface.trailingAnchor, constant: Chrome.Space.s16),

            toolbarRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarRule.topAnchor.constraint(equalTo: topAnchor, constant: Self.toolbarHeight),

            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: toolbarRule.bottomAnchor),
            headerView.heightAnchor.constraint(equalToConstant: AutomationListHeaderView.height),

            headerRule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.page),
            headerRule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.page),
            headerRule.topAnchor.constraint(equalTo: headerView.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        searchSurface.apply(theme: theme)
        newButton.apply(theme: theme)
        headerView.apply(theme: theme)
        applyColors()
        // Rows, cards and the empty state take their colors when they are
        // built, so a theme change rebuilds them.
        rowsStack.setArrangedSubviews([])
        rows.removeAll()
        orderedRows.removeAll()
        emptyStateView = nil
        noMatchesLabel = nil
        render()
    }

    private func applyColors() {
        let colors = theme.colors
        searchIcon.contentTintColor = colors.textMuted
        ChromeFieldView.styleEmbedded(searchField, colors: colors, font: ChromeFont.label)
        ChromeFieldView.styleEditor(of: searchField, colors: colors)
        searchField.placeholderAttributedString = ChromeText.attributed(
            "Search automations",
            font: ChromeFont.label,
            color: colors.textMuted
        )
        toolbarRule.color = colors.borderSubtle
        headerRule.color = colors.borderSubtle
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

        let isEmpty = items.isEmpty
        headerView.isHidden = isEmpty
        headerRule.isHidden = isEmpty
        if isEmpty {
            orderedRows = []
            rows.removeAll()
            noMatchesLabel = nil
            let empty = emptyStateView ?? makeEmptyState()
            emptyStateView = empty
            setArrangedViews([empty])
            return
        }
        emptyStateView = nil
        if visibleItems.isEmpty {
            orderedRows = []
            let label = noMatchesLabel ?? makeNoMatchesLabel()
            noMatchesLabel = label
            setArrangedViews([label])
            return
        }
        noMatchesLabel = nil

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
        setArrangedViews(orderedRows)
        updateRowSelection(scrollIntoView: false)
    }

    private func setArrangedViews(_ views: [NSView]) {
        guard rowsStack.arrangedSubviews != views else { return }
        rowsStack.setArrangedSubviews(views) { view in
            view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
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
        let row = AutomationListRowView(theme: theme)
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
        searchSurface.isFocused = true
        ChromeFieldView.styleEditor(of: searchField, colors: theme.colors)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        searchSurface.isFocused = false
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

    private func makeNoMatchesLabel() -> NSTextField {
        let label = AutomationViews.label("", font: ChromeFont.empty, color: theme.colors.textMuted)
        label.alignment = .center
        label.setChromeText("No automations match", font: ChromeFont.empty, color: theme.colors.textMuted)
        label.heightAnchor.constraint(equalToConstant: 120).isActive = true
        return label
    }

    /// "No automations yet" over Orca's four templates and a blank card.
    private func makeEmptyState() -> NSView {
        let colors = theme.colors
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("automations-empty")
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = AutomationViews.label("No automations yet", font: ChromeFont.empty, color: colors.textMuted)
        container.addSubview(title)

        let heading = ChromeEyebrowView(title: "Start from a template", theme: theme)
        container.addSubview(heading)

        var cards: [NSView] = AutomationTemplate.all.map { template in
            AutomationTemplateCardView(template: template, theme: theme) { [weak self] in
                self?.onNew?(template)
            }
        }
        cards.append(AutomationTemplateCardView(template: nil, theme: theme) { [weak self] in
            self?.onNew?(nil)
        })
        cards.append(NSView())
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = Chrome.Space.s12
        grid.translatesAutoresizingMaskIntoConstraints = false
        for start in stride(from: 0, to: cards.count, by: 3) {
            let row = NSStackView(views: Array(cards[start..<min(start + 3, cards.count)]))
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.alignment = .top
            row.spacing = Chrome.Space.s12
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        container.addSubview(grid)

        let fill = grid.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -Chrome.Space.page * 2)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: Chrome.Space.s48),
            title.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            heading.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Chrome.Space.s32),
            heading.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Chrome.Space.s12),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.widthAnchor.constraint(lessThanOrEqualToConstant: 780),
            fill,
            container.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: Chrome.Space.s24),
        ])
        return container
    }
}

// MARK: - Columns

/// Where the table's columns sit at a given width: Name and Folder share
/// what the fixed columns leave, Name taking the larger part.
enum AutomationListColumns {
    static let gap: CGFloat = 16
    static let menuWidth: CGFloat = Chrome.iconButtonSize
    private static let fixed: [CGFloat] = [170, 150, 160, 110]

    struct Frames {
        var name: ClosedRange<CGFloat>
        var schedule: ClosedRange<CGFloat>
        var folder: ClosedRange<CGFloat>
        var nextRun: ClosedRange<CGFloat>
        var lastRun: ClosedRange<CGFloat>
        var agent: ClosedRange<CGFloat>
        var menu: ClosedRange<CGFloat>
    }

    static func frames(width: CGFloat) -> Frames {
        let gutter = Chrome.Space.page
        let flexible = max(260, width - gutter * 2 - menuWidth - gap * 6 - fixed.reduce(0, +))
        let nameWidth = floor(flexible * 0.6)
        let widths = [nameWidth, fixed[0], flexible - nameWidth, fixed[1], fixed[2], fixed[3], menuWidth]
        var x = gutter
        var ranges: [ClosedRange<CGFloat>] = []
        for width in widths {
            ranges.append(x...(x + width))
            x += width + gap
        }
        return Frames(
            name: ranges[0],
            schedule: ranges[1],
            folder: ranges[2],
            nextRun: ranges[3],
            lastRun: ranges[4],
            agent: ranges[5],
            menu: ranges[6]
        )
    }
}

private extension ClosedRange where Bound == CGFloat {
    var width: CGFloat { upperBound - lowerBound }
}

/// The table's column eyebrows.
final class AutomationListHeaderView: NSView {
    static let height: CGFloat = 32

    private var theme: AppTheme
    private let labels: [NSTextField]
    private static let titles = ["Name", "Schedule", "Folder", "Next run", "Last run", "Agent"]

    init(theme: AppTheme) {
        self.theme = theme
        labels = Self.titles.map { _ in NSTextField(labelWithString: "") }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for label in labels {
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func apply(theme: AppTheme) {
        self.theme = theme
        for (label, title) in zip(labels, Self.titles) {
            label.setEyebrowText(title, color: theme.colors.textMuted)
        }
    }

    override func layout() {
        super.layout()
        let frames = AutomationListColumns.frames(width: bounds.width)
        let columns = [frames.name, frames.schedule, frames.folder, frames.nextRun, frames.lastRun, frames.agent]
        for (label, column) in zip(labels, columns) {
            let height = label.intrinsicContentSize.height
            label.frame = NSRect(x: column.lowerBound, y: floor((bounds.height - height) / 2), width: column.width, height: height)
        }
    }
}

// MARK: - Row

/// One automation: 52 pt with two lines where a column has a detail (the
/// prompt under the name, the relative time under a date). Clicking opens
/// its detail; the ⋯ button and the context menu offer Run Now, Edit,
/// Pause/Resume and Delete.
final class AutomationListRowView: NSView {
    static let height: CGFloat = 52

    var onOpen: (() -> Void)?
    var onAction: ((AutomationAction) -> Void)?
    private(set) var automationId: String?

    private let theme: AppTheme
    private let background: ChromeRowBackgroundView
    private let nameLabel = NSTextField(labelWithString: "")
    private let promptLabel = NSTextField(labelWithString: "")
    private let scheduleLabel = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "")
    private let nextRunLabel = NSTextField(labelWithString: "")
    private let nextRunDetailLabel = NSTextField(labelWithString: "")
    private let lastRunMark = ChromeStatusMark()
    private let lastRunLabel = NSTextField(labelWithString: "")
    private let lastRunDetailLabel = NSTextField(labelWithString: "")
    private let agentLabel = NSTextField(labelWithString: "")
    private let menuButton: ChromeIconButton
    private var item: AutomationListView.Item?
    private var isSelected = false
    private var isFocused = false
    private var isHovered = false

    init(theme: AppTheme) {
        self.theme = theme
        background = ChromeRowBackgroundView(theme: theme)
        menuButton = ChromeIconButton(symbolName: "ellipsis", accessibilityLabel: "Automation Actions", target: nil, action: nil)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("automations-row")
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true

        background.inset = Chrome.Space.page - Chrome.Space.s8
        background.translatesAutoresizingMaskIntoConstraints = true
        addSubview(background)
        for label in [
            nameLabel, promptLabel, scheduleLabel, folderLabel, nextRunLabel,
            nextRunDetailLabel, lastRunLabel, lastRunDetailLabel, agentLabel,
        ] {
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        folderLabel.lineBreakMode = .byTruncatingHead
        lastRunMark.translatesAutoresizingMaskIntoConstraints = true
        addSubview(lastRunMark)
        menuButton.target = self
        menuButton.action = #selector(menuClicked(_:))
        // Laid out by frame; its own 24 pt size constraints must match from the start.
        menuButton.translatesAutoresizingMaskIntoConstraints = true
        menuButton.frame = NSRect(x: 0, y: 0, width: Chrome.iconButtonSize, height: Chrome.iconButtonSize)
        menuButton.apply(theme: theme)
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
        let colors = theme.colors
        let automation = item.automation

        nameLabel.setChromeText(automation.name, font: ChromeFont.sans(size: 13, weight: .medium), color: colors.textPrimary)
        promptLabel.setChromeText(AutomationFormat.firstLine(of: automation.prompt), font: ChromeFont.meta, color: colors.textMuted)

        switch automation.cadence {
        case .custom(let expression):
            scheduleLabel.setChromeText(expression, font: ChromeFont.mono, color: colors.textPrimary)
        case let cadence:
            scheduleLabel.setChromeText(cadence.summary(), font: ChromeFont.label, color: colors.textPrimary)
        }
        folderLabel.setChromeText(AutomationFormat.path(automation.folder), font: ChromeFont.mono, color: colors.textMuted)
        folderLabel.toolTip = automation.folder

        if let nextRun = item.nextRun {
            nextRunLabel.setChromeText(AutomationFormat.dateTime(nextRun), font: ChromeFont.label, color: colors.textPrimary)
            nextRunDetailLabel.setChromeText(AutomationFormat.relative(nextRun, now: now), font: ChromeFont.meta, color: colors.textMuted)
        } else {
            nextRunLabel.setChromeText(automation.enabled ? "—" : "Paused", font: ChromeFont.label, color: colors.textMuted)
            nextRunDetailLabel.stringValue = ""
        }

        if let lastRun = item.lastRun {
            let color = AutomationStatusStyle.color(for: lastRun.status, in: colors)
            lastRunMark.isHidden = false
            lastRunMark.shape = AutomationStatusStyle.shape(for: lastRun.status)
            lastRunMark.color = color
            lastRunLabel.setStatusText(lastRun.status.label, color: color)
            lastRunDetailLabel.setChromeText(
                AutomationFormat.relative(lastRun.finishedAt ?? lastRun.startedAt, now: now),
                font: ChromeFont.meta,
                color: colors.textMuted
            )
            lastRunLabel.toolTip = lastRun.message
        } else {
            lastRunMark.isHidden = true
            lastRunLabel.setChromeText("Never", font: ChromeFont.label, color: colors.textMuted)
            lastRunDetailLabel.stringValue = ""
            lastRunLabel.toolTip = nil
        }

        agentLabel.setChromeText(AutomationFormat.agentName(automation.agentId), font: ChromeFont.label, color: colors.textPrimary)
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
        let firstLine: CGFloat = 18
        let secondLine: CGFloat = 35
        let middle = bounds.height / 2

        place(nameLabel, in: frames.name, centerY: firstLine)
        place(promptLabel, in: frames.name, centerY: secondLine)
        place(scheduleLabel, in: frames.schedule, centerY: middle)
        place(folderLabel, in: frames.folder, centerY: middle)
        let nextHasDetail = !nextRunDetailLabel.stringValue.isEmpty
        place(nextRunLabel, in: frames.nextRun, centerY: nextHasDetail ? firstLine : middle)
        place(nextRunDetailLabel, in: frames.nextRun, centerY: secondLine)

        let lastHasDetail = !lastRunDetailLabel.stringValue.isEmpty
        let lastLine = lastHasDetail ? firstLine : middle
        var lastRange = frames.lastRun
        if !lastRunMark.isHidden {
            let side = lastRunMark.size
            lastRunMark.frame = NSRect(x: lastRange.lowerBound, y: floor(lastLine - side / 2), width: side, height: side)
            lastRange = (lastRange.lowerBound + side + 6)...lastRange.upperBound
        }
        place(lastRunLabel, in: lastRange, centerY: lastLine)
        place(lastRunDetailLabel, in: frames.lastRun, centerY: secondLine)
        place(agentLabel, in: frames.agent, centerY: middle)

        let side = Chrome.iconButtonSize
        menuButton.frame = NSRect(x: frames.menu.lowerBound, y: floor(middle - side / 2), width: side, height: side)
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
/// template the blank "New automation" card. 8 pt radius, raised fill,
/// `hover` under the pointer.
final class AutomationTemplateCardView: NSView {
    private static let height: CGFloat = 128

    private let theme: AppTheme
    private let action: () -> Void
    private var isHovered = false {
        didSet { refreshFill() }
    }

    init(template: AutomationTemplate?, theme: AppTheme, action: @escaping () -> Void) {
        self.theme = theme
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.card
        layer?.borderWidth = Chrome.hairline
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        build(template: template)
        refreshFill()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(template.map { "\($0.label) template" } ?? "New automation")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func build(template: AutomationTemplate?) {
        let colors = theme.colors
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Chrome.Space.s4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let title: String
        let detail: String
        let footer: String
        if let template {
            let category = NSTextField(labelWithString: "")
            category.setEyebrowText(template.category, color: colors.textMuted)
            stack.addArrangedSubview(category)
            title = template.label
            detail = template.description
            footer = template.cadence.summary()
        } else {
            let icon = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            icon.contentTintColor = colors.textMuted
            stack.addArrangedSubview(icon)
            title = "New automation"
            detail = "Write your own prompt and schedule."
            footer = ""
        }
        stack.addArrangedSubview(AutomationViews.label(title, font: ChromeFont.sans(size: 13, weight: .medium), color: colors.textPrimary))
        let description = AutomationViews.wrappingLabel(ChromeText.attributed(
            detail,
            font: ChromeFont.meta,
            color: colors.textMuted,
            lineBreakMode: .byWordWrapping
        ))
        description.maximumNumberOfLines = 3
        stack.addArrangedSubview(description)
        description.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let footerLabel = AutomationViews.label(footer, font: ChromeFont.meta, color: colors.textMuted)
        addSubview(footerLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.s12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.s12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Chrome.Space.s12),
            footerLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            footerLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Chrome.Space.s12),
        ])
    }

    private func refreshFill() {
        let colors = theme.colors
        layer?.backgroundColor = (isHovered ? colors.hover : colors.raised).cgColor
        layer?.borderColor = colors.borderSubtle.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
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
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
