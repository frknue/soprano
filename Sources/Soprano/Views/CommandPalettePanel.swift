import AppKit

struct CommandItem {
    let id: String
    let icon: String
    let label: String
    let description: String
    /// K1 keycaps, one per chord step: `["⌘D"]`, `["⇧⌘P"]`, `["⌃A", "G"]`.
    /// Empty when the command has no shortcut.
    let shortcut: [String]
    let searchText: String?
    /// Runs the command with the query it was picked under.
    let action: (_ query: String) -> Void

    init(
        id: String,
        icon: String,
        label: String,
        description: String,
        shortcut: [String] = [],
        searchText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            id: id,
            icon: icon,
            label: label,
            description: description,
            shortcut: shortcut,
            searchText: searchText,
            queryAction: { _ in action() }
        )
    }

    init(
        id: String,
        icon: String,
        label: String,
        description: String,
        shortcut: [String] = [],
        searchText: String? = nil,
        queryAction: @escaping (_ query: String) -> Void
    ) {
        self.id = id
        self.icon = icon
        self.label = label
        self.description = description
        self.shortcut = shortcut
        self.searchText = searchText
        self.action = queryAction
    }
}

enum CommandPaletteSearch {
    private struct Match {
        let item: CommandItem
        let originalIndex: Int
        let fieldPriority: Int
        let matchPriority: Int
        let matchOffset: Int
    }

    static func filter(_ commands: [CommandItem], query: String) -> [CommandItem] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return commands }

        return commands.enumerated().compactMap { index, item -> Match? in
            let fields = [
                (priority: 0, text: item.label),
                (priority: 1, text: item.description),
                (priority: 2, text: item.searchText ?? ""),
            ]

            for field in fields {
                let haystack = field.text.lowercased()
                guard let range = haystack.range(of: needle) else { continue }
                let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                let matchPriority: Int
                if haystack == needle {
                    matchPriority = 0
                } else if offset == 0 {
                    matchPriority = 1
                } else {
                    matchPriority = 2
                }
                return Match(
                    item: item,
                    originalIndex: index,
                    fieldPriority: field.priority,
                    matchPriority: matchPriority,
                    matchOffset: offset
                )
            }
            return nil
        }.sorted { lhs, rhs in
            if lhs.fieldPriority != rhs.fieldPriority {
                return lhs.fieldPriority < rhs.fieldPriority
            }
            if lhs.matchPriority != rhs.matchPriority {
                return lhs.matchPriority < rhs.matchPriority
            }
            if lhs.matchOffset != rhs.matchOffset {
                return lhs.matchOffset < rhs.matchOffset
            }
            return lhs.originalIndex < rhs.originalIndex
        }.map(\.item)
    }

    /// The first case-insensitive occurrence of `query` in `text`: the
    /// characters a row draws Semibold. Nil for an empty query or no match.
    static func matchRange(in text: String, query: String) -> Range<String.Index>? {
        let needle = normalized(query)
        guard !needle.isEmpty else { return nil }
        return text.range(of: needle, options: .caseInsensitive)
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The ⌘P palette: a raised, rounded e3 panel centered on its parent window,
/// over a scrim that dims the parent until it closes.
final class CommandPalettePanel: NSPanel {
    /// The surface's top edge sits at least this far below the parent
    /// window's top edge, clear of the titlebar, tab row and pane headers.
    static let minimumTopOffset: CGFloat = 100

    private let themeManager: ThemeManager
    private let contentVC: CommandPaletteViewController
    private let scrim = CommandPaletteScrimView()
    private var activationObservers: [NSObjectProtocol] = []

    init(themeManager: ThemeManager) {
        self.themeManager = themeManager
        self.contentVC = CommandPaletteViewController(theme: themeManager.currentTheme)
        super.init(
            contentRect: NSRect(origin: .zero, size: contentVC.preferredContentSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        contentViewController = contentVC
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        // The surface layer draws the e3 shadow inside the panel's margin.
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow

        contentVC.onDismiss = { [weak self] in
            self?.dismiss()
        }
        contentVC.onExecute = { [weak self] item, query in
            item.action(query)
            self?.dismiss()
        }
        contentVC.onSizeChange = { [weak self] size in
            self?.resize(keepingTopEdge: size)
        }
        scrim.onClick = { [weak self] in
            self?.dismiss()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Shows `commands` over `parentWindow`. `searchShortcut` is the K1 caps
    /// shown at the end of the search row (the shortcut that opened this
    /// palette); empty shows none.
    func show(
        relativeTo parentWindow: NSWindow,
        commands: [CommandItem],
        placeholder: String = "Type a command...",
        searchShortcut: [String] = []
    ) {
        let theme = themeManager.currentTheme
        contentVC.apply(theme: theme)
        contentVC.setCommands(commands, placeholder: placeholder, searchShortcut: searchShortcut)
        setFrame(Self.frame(for: contentVC.preferredContentSize, over: parentWindow), display: true)
        showScrim(over: parentWindow, colors: theme.colors)

        if let currentParent = parent, currentParent !== parentWindow {
            currentParent.removeChildWindow(self)
        }
        if parent == nil {
            parentWindow.addChildWindow(self, ordered: .above)
        }
        makeKeyAndOrderFront(nil)
        contentVC.focus()
    }

    func dismiss() {
        hideScrim()
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    /// The panel frame (surface plus its shadow margin) for a palette of
    /// `size`: centered on the parent, the surface's top edge at least
    /// `minimumTopOffset` below the parent's top, kept on screen.
    private static func frame(for size: NSSize, over parentWindow: NSWindow) -> NSRect {
        let margin = CommandPaletteViewController.shadowMargin
        let parentFrame = parentWindow.frame
        let titlebarHeight = parentFrame.height - parentWindow.contentLayoutRect.maxY
        let surfaceTop = parentFrame.maxY - max(minimumTopOffset, titlebarHeight + 72)
        let surfaceWidth = size.width - margin.left - margin.right
        let surfaceHeight = size.height - margin.top - margin.bottom
        let visibleFrame = parentWindow.screen?.visibleFrame ?? parentFrame
        let surfaceX = min(
            max(parentFrame.midX - surfaceWidth / 2, visibleFrame.minX + 12),
            visibleFrame.maxX - surfaceWidth - 12
        )
        let surfaceY = min(
            max(surfaceTop - surfaceHeight, visibleFrame.minY + 12),
            visibleFrame.maxY - surfaceHeight - 12
        )
        return NSRect(
            x: surfaceX - margin.left,
            y: surfaceY - margin.bottom,
            width: size.width,
            height: size.height
        )
    }

    private func resize(keepingTopEdge size: NSSize) {
        guard frame.size != size else { return }
        var resized = frame
        resized.origin.y = frame.maxY - size.height
        resized.size = size
        setFrame(resized, display: isVisible)
    }

    /// Dims the parent window's content (`colors.scrim`) while the palette is
    /// up; a click on it closes the palette. Like the panel, it hides while
    /// the app is inactive. The observers live only until `dismiss()`.
    private func showScrim(over parentWindow: NSWindow, colors: ThemeColors) {
        scrim.layer?.backgroundColor = colors.scrim.cgColor
        guard let host = parentWindow.contentView else { return }
        if scrim.superview !== host {
            hideScrim()
            scrim.frame = host.bounds
            host.addSubview(scrim, positioned: .above, relativeTo: nil)
        }
        scrim.isHidden = false
        guard activationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        activationObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.scrim.isHidden = true }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.scrim.isHidden = false }
            },
        ]
    }

    private func hideScrim() {
        scrim.removeFromSuperview()
        activationObservers.forEach(NotificationCenter.default.removeObserver)
        activationObservers.removeAll()
    }
}

/// The scrim behind the palette. It swallows clicks so the window under it
/// stays put, and reports them so the palette can close.
private final class CommandPaletteScrimView: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

final class CommandPaletteViewController: NSViewController, NSTextFieldDelegate {
    static let width: CGFloat = 620
    /// The surface never grows past this; longer lists scroll.
    static let maxHeight: CGFloat = 480
    static let searchHeight: CGFloat = 44
    static let rowHeight: CGFloat = 44
    static let rowGap: CGFloat = 1
    static let listPadding: CGFloat = 6
    static let footerHeight: CGFloat = 28
    static let emptyHeight: CGFloat = 72
    /// Room around the surface for the e3 shadow, which the surface layer
    /// draws itself (the panel has no system shadow).
    static let shadowMargin = NSEdgeInsets(top: 28, left: 40, bottom: 56, right: 40)

    var commands: [CommandItem] = []
    var filtered: [CommandItem] = []
    var selectedIndex: Int = 0

    var onDismiss: (() -> Void)?
    var onExecute: ((CommandItem, String) -> Void)?
    /// The panel size (surface plus shadow margin) changed with the results.
    var onSizeChange: ((NSSize) -> Void)?

    private var currentTheme: AppTheme
    private var query = ""
    private var surface: CommandPaletteSurfaceView!
    private var searchIcon: NSImageView!
    private var searchField: NSTextField!
    private var searchKeycaps: ChromeKeycapGroupView!
    private var searchRule: ChromeRuleView!
    private var scrollView: NSScrollView!
    private var listHeightConstraint: NSLayoutConstraint!
    private var stackView: NSStackView!
    private var footerRule: ChromeRuleView!
    private var resultCountLabel: NSTextField!
    private var hintKeycaps: [ChromeKeycapView] = []
    private var hintLabels: [NSTextField] = []
    private var resultRows: [CommandPaletteRowView] = []

    private static let hints: [(cap: String, word: String)] = [
        ("↑↓", "Navigate"),
        ("↵", "Run"),
        ("esc", "Close"),
    ]

    init(theme: AppTheme) {
        self.currentTheme = theme
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.panelSize(listHeight: Self.listHeight(rows: 0))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The list height for `rows` results, capped so the surface stays within
    /// `maxHeight`. No results shows the empty state.
    static func listHeight(rows: Int) -> CGFloat {
        let content = rows == 0
            ? emptyHeight
            : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap
        return min(content + listPadding * 2, maxHeight - searchHeight - footerHeight)
    }

    private static func panelSize(listHeight: CGFloat) -> NSSize {
        NSSize(
            width: width + shadowMargin.left + shadowMargin.right,
            height: searchHeight + listHeight + footerHeight + shadowMargin.top + shadowMargin.bottom
        )
    }

    override func loadView() {
        let root = CommandPaletteRootView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.wantsLayer = true

        // The surface carries the fill, radius, shadow and contact ring; it
        // must not clip, or the shadow goes. `clip` rounds the content.
        surface = CommandPaletteSurfaceView(colors: currentTheme.colors)
        root.addSubview(surface)
        root.surface = surface
        root.onClickOutsideSurface = { [weak self] in
            self?.onDismiss?()
        }

        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Chrome.Radius.panel
        clip.layer?.masksToBounds = true
        clip.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(clip)

        searchIcon = NSImageView()
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        searchIcon.imageScaling = .scaleNone
        searchIcon.setAccessibilityElement(false)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(searchIcon)

        searchField = NSTextField(string: "")
        searchField.delegate = self
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(searchField)

        searchKeycaps = ChromeKeycapGroupView(caps: [], theme: currentTheme, style: .standard, tone: .muted)
        clip.addSubview(searchKeycaps)

        searchRule = ChromeRuleView(axis: .horizontal)
        clip.addSubview(searchRule)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(scrollView)

        let documentView = CommandPaletteDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = Self.rowGap
        stackView.edgeInsets = NSEdgeInsets(
            top: Self.listPadding,
            left: 0,
            bottom: Self.listPadding,
            right: 0
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        footerRule = ChromeRuleView(axis: .horizontal)
        clip.addSubview(footerRule)

        resultCountLabel = NSTextField(labelWithString: "")
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(resultCountLabel)

        let hintStack = NSStackView()
        hintStack.orientation = .horizontal
        hintStack.alignment = .centerY
        hintStack.spacing = 14
        hintStack.translatesAutoresizingMaskIntoConstraints = false
        for hint in Self.hints {
            let cap = ChromeKeycapView(legend: hint.cap, theme: currentTheme, style: .small, tone: .muted)
            let word = NSTextField(labelWithString: hint.word)
            let pair = NSStackView(views: [cap, word])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = 5
            hintStack.addArrangedSubview(pair)
            hintKeycaps.append(cap)
            hintLabels.append(word)
        }
        clip.addSubview(hintStack)

        let margin = Self.shadowMargin
        listHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: Self.listHeight(rows: 0))

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: root.topAnchor, constant: margin.top),
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin.left),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin.right),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin.bottom),

            clip.topAnchor.constraint(equalTo: surface.topAnchor),
            clip.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: surface.bottomAnchor),

            // Search row: 44, padding 0 12 0 16, gap 10, hairline at its foot.
            searchIcon.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: clip.topAnchor, constant: Self.searchHeight / 2),
            searchIcon.widthAnchor.constraint(equalToConstant: 15),
            searchIcon.heightAnchor.constraint(equalToConstant: 15),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: searchKeycaps.leadingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),

            searchKeycaps.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -12),
            searchKeycaps.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),

            searchRule.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            searchRule.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            searchRule.bottomAnchor.constraint(equalTo: clip.topAnchor, constant: Self.searchHeight),

            scrollView.topAnchor.constraint(equalTo: clip.topAnchor, constant: Self.searchHeight),
            scrollView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            listHeightConstraint,

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            // Footer: 28 with a hairline on top, padding 0 16.
            footerRule.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footerRule.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: clip.trailingAnchor),

            resultCountLabel.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 16),
            resultCountLabel.centerYAnchor.constraint(
                equalTo: clip.bottomAnchor, constant: -Self.footerHeight / 2 + Chrome.hairline / 2
            ),

            hintStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -16),
            hintStack.centerYAnchor.constraint(equalTo: resultCountLabel.centerYAnchor),
            hintStack.leadingAnchor.constraint(greaterThanOrEqualTo: resultCountLabel.trailingAnchor, constant: 14),
        ])

        view = root
        apply(theme: currentTheme)
    }

    func apply(theme: AppTheme) {
        currentTheme = theme
        guard isViewLoaded else { return }

        let colors = theme.colors
        surface.colors = colors

        searchIcon.contentTintColor = colors.textMuted
        ChromeFieldView.styleEmbedded(searchField, colors: colors, font: ChromeFont.paletteQuery)
        ChromeFieldView.styleEditor(of: searchField, colors: colors)
        applyPlaceholder(searchField.placeholderString ?? "")
        searchKeycaps.apply(theme: theme)
        searchRule.color = colors.borderSubtle
        footerRule.color = colors.borderSubtle
        for cap in hintKeycaps {
            cap.apply(theme: theme)
        }
        for label in hintLabels {
            label.setChromeText(label.stringValue, font: ChromeFont.meta, color: colors.textMuted)
        }

        refreshRows()
    }

    func setCommands(_ commands: [CommandItem], placeholder: String, searchShortcut: [String] = []) {
        _ = view
        self.commands = commands
        applyPlaceholder(placeholder)
        searchKeycaps.caps = searchShortcut
        searchKeycaps.isHidden = searchShortcut.isEmpty
        searchField.stringValue = ""
        updateFilter(query: "")
    }

    func focus() {
        view.window?.makeFirstResponder(searchField)
        ChromeFieldView.styleEditor(of: searchField, colors: currentTheme.colors)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        ChromeFieldView.styleEditor(of: searchField, colors: currentTheme.colors)
    }

    func controlTextDidChange(_ obj: Notification) {
        updateFilter(query: searchField.stringValue)
    }

    func control(_ control: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveSelection(delta: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            moveSelection(delta: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            executeSelection()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onDismiss?()
            return true
        }
        return false
    }

    private func applyPlaceholder(_ placeholder: String) {
        searchField.placeholderAttributedString = ChromeText.attributed(
            placeholder,
            font: ChromeFont.paletteQuery,
            color: currentTheme.colors.textMuted
        )
    }

    private func updateFilter(query: String) {
        self.query = query
        filtered = CommandPaletteSearch.filter(commands, query: query)

        selectedIndex = 0
        refreshRows()
        updateSize()
        view.layoutSubtreeIfNeeded()
        scrollSelectionIntoView()
    }

    private func updateSize() {
        let listHeight = Self.listHeight(rows: filtered.count)
        listHeightConstraint.constant = listHeight
        let size = Self.panelSize(listHeight: listHeight)
        guard size != preferredContentSize else { return }
        preferredContentSize = size
        onSizeChange?(size)
    }

    private func refreshRows() {
        for row in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        resultRows.removeAll(keepingCapacity: true)
        let colors = currentTheme.colors
        resultCountLabel.setChromeText(
            "\(filtered.count) result\(filtered.count == 1 ? "" : "s")",
            font: ChromeFont.count,
            color: colors.textMuted
        )

        if filtered.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "")
            emptyLabel.alignment = .center
            emptyLabel.setChromeText("No matching results", font: ChromeFont.empty, color: colors.textMuted)
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            let emptyState = NSView()
            emptyState.translatesAutoresizingMaskIntoConstraints = false
            emptyState.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            ])
            stackView.addArrangedSubview(emptyState)
            emptyState.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            emptyState.heightAnchor.constraint(equalToConstant: Self.emptyHeight).isActive = true
            return
        }

        for (index, item) in filtered.enumerated() {
            let row = CommandPaletteRowView(theme: currentTheme)
            row.configure(item: item, query: query, selected: index == selectedIndex)
            row.onClick = { [weak self] in
                self?.selectedIndex = index
                self?.executeSelection()
            }
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            resultRows.append(row)
        }
    }

    private func moveSelection(delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), filtered.count - 1)
        updateHighlights()
        scrollSelectionIntoView()
    }

    private func scrollSelectionIntoView() {
        guard selectedIndex >= 0,
              selectedIndex < resultRows.count,
              let documentView = scrollView.documentView
        else { return }

        let row = resultRows[selectedIndex]
        var rowRect = row.convert(row.bounds, to: documentView)
        // Keep the list padding visible at either end.
        rowRect = rowRect.insetBy(dx: 0, dy: -Self.listPadding)
        documentView.scrollToVisible(rowRect)
    }

    private func updateHighlights() {
        for (index, row) in resultRows.enumerated() {
            row.setSelected(index == selectedIndex)
        }
    }

    private func executeSelection() {
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return }
        onExecute?(filtered[selectedIndex], query)
    }
}

/// The panel's content: the surface plus its transparent shadow margin. A
/// click in that margin looks like a click on the window behind, so it
/// closes the palette as the scrim does.
private final class CommandPaletteRootView: NSView {
    weak var surface: NSView?
    var onClickOutsideSurface: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let surface, !surface.frame.contains(point) {
            onClickOutsideSurface?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// The palette's raised e3 surface. It restyles its layer on every update,
/// because AppKit resets a backing layer's shadow when the effective
/// appearance changes.
private final class CommandPaletteSurfaceView: NSView {
    var colors: ThemeColors {
        didSet { needsDisplay = true }
    }

    init(colors: ThemeColors) {
        self.colors = colors
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        ChromeSurface.applyFloating(to: layer, colors: colors, radius: Chrome.Radius.panel, shadow: colors.shadowE3)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One result: icon, title over description, trailing K1 keycaps. The
/// selected row is the selection pill with the pencil tick; matched title
/// characters are Semibold, in `matchOnSelection` on the selected row only.
private final class CommandPaletteRowView: NSView {
    /// Rows sit 6 pt in from the surface edges (`margin: 0 6px`).
    static let sideMargin: CGFloat = 6

    var onClick: (() -> Void)?

    private let background: ChromeRowBackgroundView
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let keycaps: ChromeKeycapGroupView
    private let theme: AppTheme
    private var title = ""
    private var matchRange: Range<String.Index>?
    private var isSelected = false

    init(theme: AppTheme) {
        self.theme = theme
        self.background = ChromeRowBackgroundView(theme: theme)
        self.keycaps = ChromeKeycapGroupView(caps: [], theme: theme, style: .standard, tone: .primary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        background.inset = Self.sideMargin
        addSubview(background)

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [titleLabel, descriptionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)

        addSubview(keycaps)

        let leading = Self.sideMargin + 12
        let trailing = Self.sideMargin + 10
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CommandPaletteViewController.rowHeight),

            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: keycaps.leadingAnchor, constant: -12),

            keycaps.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailing),
            keycaps.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickGesture)
    }

    func configure(item: CommandItem, query: String, selected: Bool) {
        iconView.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.label)
        title = item.label
        matchRange = CommandPaletteSearch.matchRange(in: item.label, query: query)
        descriptionLabel.setChromeText(item.description, font: ChromeFont.meta, color: theme.colors.textMuted)
        keycaps.caps = item.shortcut
        keycaps.isHidden = item.shortcut.isEmpty

        isSelected = !selected
        setSelected(selected)
    }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        let colors = theme.colors
        background.style = selected ? .selected : .none
        iconView.contentTintColor = selected ? colors.textPrimary : colors.textMuted
        titleLabel.attributedStringValue = titleText(colors: colors)
    }

    private func titleText(colors: ThemeColors) -> NSAttributedString {
        let text = NSMutableAttributedString(
            attributedString: ChromeText.attributed(
                title,
                font: ChromeFont.row,
                color: colors.textPrimary,
                lineBreakMode: .byTruncatingTail
            )
        )
        if let matchRange {
            text.addAttributes(
                [
                    .font: ChromeFont.sans(size: ChromeFont.row.pointSize, weight: .semibold),
                    .foregroundColor: isSelected ? colors.matchOnSelection : colors.textPrimary,
                ],
                range: NSRange(matchRange, in: title)
            )
        }
        return text
    }

    @objc private func handleClick() {
        onClick?()
    }
}

private final class CommandPaletteDocumentView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
