import AppKit

struct CommandItem {
    let id: String
    let icon: String
    let label: String
    let description: String
    let shortcut: String?
    let action: () -> Void
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
    private var searchContainer: NSView!
    private var searchIcon: NSImageView!
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
        root.layer?.cornerRadius = 12
        root.layer?.borderWidth = 1
        root.layer?.masksToBounds = true

        searchContainer = NSView()
        searchContainer.wantsLayer = true
        searchContainer.layer?.cornerRadius = 9
        searchContainer.layer?.borderWidth = 1
        searchContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchContainer)

        searchIcon = NSImageView()
        searchIcon.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: "Search"
        )
        searchIcon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(searchIcon)

        searchField = NSTextField(string: "")
        searchField.placeholderString = "Type a command..."
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 14, weight: .medium)
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
        resultCountLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(resultCountLabel)

        keyboardHintLabel = NSTextField(labelWithString: "↑↓  Navigate    ↵  Run    esc  Close")
        keyboardHintLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        keyboardHintLabel.alignment = .right
        keyboardHintLabel.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(keyboardHintLabel)

        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            searchContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            searchContainer.heightAnchor.constraint(equalToConstant: 44),

            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 13),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 9),
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

        view.layer?.backgroundColor = theme.colors.bgPanel.withAlphaComponent(0.985).cgColor
        view.layer?.borderColor = theme.colors.borderStrong.cgColor

        searchField.textColor = theme.colors.textPrimary
        searchContainer.layer?.backgroundColor = theme.colors.bgRaised.cgColor
        searchContainer.layer?.borderColor = theme.colors.borderStrong.cgColor
        searchIcon.contentTintColor = theme.colors.textMuted
        resultCountLabel.textColor = theme.colors.textMuted
        keyboardHintLabel.textColor = theme.colors.textMuted

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
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty {
            filtered = commands
        } else {
            filtered = commands.filter { item in
                let haystack = "\(item.label) \(item.description)".lowercased()
                return haystack.contains(needle)
            }
        }

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
        resultCountLabel.stringValue = "\(filtered.count) result\(filtered.count == 1 ? "" : "s")"

        if filtered.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No matching commands")
            emptyLabel.font = .systemFont(ofSize: 12, weight: .regular)
            emptyLabel.textColor = currentTheme.colors.textMuted
            emptyLabel.alignment = .center
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
    private var theme: AppTheme

    init(theme: AppTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 8
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

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(descriptionLabel)

        shortcutContainer.wantsLayer = true
        shortcutContainer.layer?.cornerRadius = 6
        shortcutContainer.layer?.borderWidth = 1
        shortcutContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutContainer)

        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
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
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: shortcutContainer.leadingAnchor, constant: -8
            ),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickGesture)
    }

    func configure(item: CommandItem, highlighted: Bool) {
        iconView.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.label)
        titleLabel.stringValue = item.label
        descriptionLabel.stringValue = item.description
        shortcutLabel.stringValue = item.shortcut ?? ""
        shortcutContainer.isHidden = item.shortcut == nil

        iconView.contentTintColor = theme.colors.textMuted
        titleLabel.textColor = theme.colors.textPrimary
        descriptionLabel.textColor = theme.colors.textMuted
        shortcutLabel.textColor = theme.colors.textMuted
        shortcutContainer.layer?.backgroundColor = theme.colors.bgRaised.cgColor
        shortcutContainer.layer?.borderColor = theme.colors.borderSubtle.cgColor

        setHighlighted(highlighted)
    }

    func setHighlighted(_ highlighted: Bool) {
        layer?.backgroundColor = highlighted
            ? theme.colors.accent.withAlphaComponent(0.13).cgColor
            : NSColor.clear.cgColor
        iconView.contentTintColor = highlighted ? theme.colors.accent : theme.colors.textMuted
        shortcutLabel.textColor = highlighted ? theme.colors.accent : theme.colors.textMuted
        shortcutContainer.layer?.backgroundColor = highlighted
            ? theme.colors.accent.withAlphaComponent(0.1).cgColor
            : theme.colors.bgRaised.cgColor
        shortcutContainer.layer?.borderColor = highlighted
            ? theme.colors.accent.withAlphaComponent(0.35).cgColor
            : theme.colors.borderSubtle.cgColor
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
