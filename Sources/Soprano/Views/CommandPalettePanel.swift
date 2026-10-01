import AppKit

struct CommandItem {
    let id: String
    let icon: String
    let label: String
    let description: String
    let shortcut: String?
    let searchText: String?
    let action: () -> Void

    init(
        id: String,
        icon: String,
        label: String,
        description: String,
        shortcut: String?,
        searchText: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.icon = icon
        self.label = label
        self.description = description
        self.shortcut = shortcut
        self.searchText = searchText
        self.action = action
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
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
}

final class CommandPalettePanel: NSPanel {
    private static let paletteSize = NSSize(width: 620, height: 480)

    private let themeManager: ThemeManager
    private let contentVC: CommandPaletteViewController

    init(themeManager: ThemeManager) {
        self.themeManager = themeManager
        self.contentVC = CommandPaletteViewController(theme: themeManager.currentTheme)
        let frame = NSRect(origin: .zero, size: Self.paletteSize)
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        contentViewController = contentVC
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow

        contentVC.onDismiss = { [weak self] in
            self?.dismiss()
        }
        contentVC.onExecute = { [weak self] item in
            item.action()
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

    func show(
        relativeTo parentWindow: NSWindow,
        commands: [CommandItem],
        placeholder: String = "Type a command..."
    ) {
        let theme = themeManager.currentTheme
        contentVC.apply(theme: theme)
        contentVC.setCommands(commands, placeholder: placeholder)
        setContentSize(Self.paletteSize)

        let parentFrame = parentWindow.frame
        let x = parentFrame.origin.x + (parentFrame.width - frame.width) / 2
        let y = parentFrame.maxY - frame.height - 72
        let visibleFrame = parentWindow.screen?.visibleFrame ?? parentFrame
        let origin = NSPoint(
            x: min(max(x, visibleFrame.minX + 12), visibleFrame.maxX - frame.width - 12),
            y: min(max(y, visibleFrame.minY + 12), visibleFrame.maxY - frame.height - 12)
        )
        setFrameOrigin(origin)

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
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

final class CommandPaletteViewController: NSViewController, NSTextFieldDelegate {
    var commands: [CommandItem] = []
    var filtered: [CommandItem] = []
    var selectedIndex: Int = 0

    var onDismiss: (() -> Void)?
    var onExecute: ((CommandItem) -> Void)?

    private var currentTheme: AppTheme
    private var headerLabel: NSTextField!
    private var headerStripe: RetroStripeView!
    private var headerRule: RetroRuleView!
    private var searchContainer: NSView!
    private var promptLabel: NSTextField!
    private var searchField: NSTextField!
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var footerView: NSView!
    private var resultCountLabel: NSTextField!
    private var keyboardHintLabel: NSTextField!
    private var resultRows: [CommandPaletteRowView] = []

    init(theme: AppTheme) {
        self.currentTheme = theme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = Retro.cornerRadius
        root.layer?.borderWidth = Retro.hairline
        root.layer?.masksToBounds = true

        headerLabel = NSTextField(labelWithString: "COMMAND")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerLabel)

        headerStripe = RetroStripeView(layout: .slanted)
        root.addSubview(headerStripe)

        headerRule = RetroRuleView(axis: .horizontal, style: .double)
        root.addSubview(headerRule)

        searchContainer = NSView()
        searchContainer.wantsLayer = true
        searchContainer.layer?.cornerRadius = Retro.cornerRadius
        searchContainer.layer?.borderWidth = Retro.hairline
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchContainer)

        promptLabel = NSTextField(labelWithString: "❯")
        promptLabel.setAccessibilityElement(false)
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(promptLabel)

        searchField = NSTextField(string: "")
        searchField.placeholderString = "Type a command..."
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = RetroFont.body(13)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchContainer.addSubview(searchField)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        let documentView = CommandPaletteDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 3
        stackView.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        footerView = NSView()
        footerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerView)

        resultCountLabel = NSTextField(labelWithString: "")
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(resultCountLabel)

        keyboardHintLabel = NSTextField(labelWithString: "↑↓  Navigate    ↵  Run    esc  Close")
        keyboardHintLabel.alignment = .right
        keyboardHintLabel.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(keyboardHintLabel)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            headerLabel.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 11),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerStripe.leadingAnchor, constant: -12),

            headerStripe.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            headerStripe.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            headerStripe.widthAnchor.constraint(equalToConstant: 22),
            headerStripe.heightAnchor.constraint(equalToConstant: 12),

            headerRule.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            headerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            searchContainer.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 12),
            searchContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            searchContainer.heightAnchor.constraint(equalToConstant: 44),

            promptLabel.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 13),
            promptLabel.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),

            searchField.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: footerView.topAnchor, constant: -6),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            footerView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footerView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footerView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9),
            footerView.heightAnchor.constraint(equalToConstant: 22),

            resultCountLabel.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            resultCountLabel.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

            keyboardHintLabel.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),
            keyboardHintLabel.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            keyboardHintLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: resultCountLabel.trailingAnchor, constant: 12
            ),
        ])

        view = root
        apply(theme: currentTheme)
    }

    func apply(theme: AppTheme) {
        currentTheme = theme
        guard isViewLoaded else { return }

        let colors = theme.colors
        view.layer?.backgroundColor = colors.bgPanel.withAlphaComponent(0.985).cgColor
        view.layer?.borderColor = colors.borderStrong.cgColor

        headerLabel.setRetroText("COMMAND", color: colors.accent, glow: true)
        headerStripe.colors = colors.stripe
        headerRule.color = colors.borderStrong

        searchField.textColor = colors.textPrimary
        searchContainer.layer?.backgroundColor = colors.bgRaised.cgColor
        searchContainer.layer?.borderColor = colors.borderStrong.cgColor
        promptLabel.setRetroText("❯", color: colors.accent)
        keyboardHintLabel.setRetroText(keyboardHintLabel.stringValue, color: colors.textMuted)

        refreshRows()
    }

    func setCommands(_ commands: [CommandItem], placeholder: String) {
        self.commands = commands
        searchField.placeholderString = placeholder
        searchField.stringValue = ""
        updateFilter(query: "")
    }

    func focus() {
        view.window?.makeFirstResponder(searchField)
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

    private func updateFilter(query: String) {
        filtered = CommandPaletteSearch.filter(commands, query: query)

        selectedIndex = 0
        refreshRows()
        view.layoutSubtreeIfNeeded()
        scrollSelectionIntoView()
    }

    private func refreshRows() {
        for row in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        resultRows.removeAll(keepingCapacity: true)
        resultCountLabel.setRetroText(
            "\(filtered.count) result\(filtered.count == 1 ? "" : "s")",
            color: currentTheme.colors.textMuted
        )

        if filtered.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "")
            emptyLabel.alignment = .center
            emptyLabel.setRetroText("No matching results", color: currentTheme.colors.textMuted)
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(emptyLabel)
            emptyLabel.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            emptyLabel.heightAnchor.constraint(equalToConstant: 72).isActive = true
            return
        }

        for (index, item) in filtered.enumerated() {
            let row = CommandPaletteRowView(theme: currentTheme)
            row.configure(item: item, highlighted: index == selectedIndex)
            row.onClick = { [weak self] in
                self?.selectedIndex = index
                self?.executeSelection()
            }
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            resultRows.append(row)
        }

        updateHighlights()
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
        let rowRect = row.convert(row.bounds, to: documentView)
        documentView.scrollToVisible(rowRect)
    }

    private func updateHighlights() {
        for (index, row) in resultRows.enumerated() {
            row.setHighlighted(index == selectedIndex)
        }
    }

    private func executeSelection() {
        guard selectedIndex >= 0, selectedIndex < filtered.count else { return }
        onExecute?(filtered[selectedIndex])
    }
}

private final class CommandPaletteRowView: NSView {
    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let shortcutContainer = NSView()
    private let theme: AppTheme
    private var title = ""
    private var shortcut = ""

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = Retro.cornerRadius
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        iconView.contentTintColor = theme.colors.textMuted
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        descriptionLabel.font = RetroFont.body(11)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(descriptionLabel)

        shortcutContainer.wantsLayer = true
        shortcutContainer.layer?.cornerRadius = Retro.cornerRadius
        shortcutContainer.layer?.borderWidth = Retro.hairline
        shortcutContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutContainer)

        shortcutLabel.alignment = .center
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutContainer.addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            shortcutContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcutContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutContainer.heightAnchor.constraint(equalToConstant: 22),

            shortcutLabel.leadingAnchor.constraint(equalTo: shortcutContainer.leadingAnchor, constant: 7),
            shortcutLabel.trailingAnchor.constraint(equalTo: shortcutContainer.trailingAnchor, constant: -7),
            shortcutLabel.centerYAnchor.constraint(equalTo: shortcutContainer.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutContainer.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcutContainer.leadingAnchor, constant: -8
            ),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickGesture)
    }

    func configure(item: CommandItem, highlighted: Bool) {
        iconView.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.label)
        title = item.label
        shortcut = item.shortcut ?? ""
        descriptionLabel.stringValue = item.description
        shortcutContainer.isHidden = item.shortcut == nil

        setHighlighted(highlighted)
    }

    func setHighlighted(_ highlighted: Bool) {
        let colors = theme.colors
        let ink = highlighted ? colors.bgPanel : colors.textMuted
        layer?.backgroundColor = highlighted ? colors.accent.cgColor : NSColor.clear.cgColor
        iconView.contentTintColor = ink
        titleLabel.setRetroText(title, color: highlighted ? colors.bgPanel : colors.textPrimary)
        descriptionLabel.textColor = ink
        shortcutLabel.setRetroText(shortcut, color: ink)
        shortcutContainer.layer?.backgroundColor = highlighted
            ? NSColor.clear.cgColor
            : colors.bgRaised.cgColor
        shortcutContainer.layer?.borderColor = highlighted
            ? colors.bgPanel.cgColor
            : colors.borderSubtle.cgColor
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
