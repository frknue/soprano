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
    private let themeManager: ThemeManager
    private let contentVC: CommandPaletteViewController

    init(themeManager: ThemeManager) {
        self.themeManager = themeManager
        self.contentVC = CommandPaletteViewController(theme: themeManager.currentTheme)
        let frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        contentViewController = contentVC
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = true

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

    func show(relativeTo parentWindow: NSWindow, commands: [CommandItem]) {
        let theme = themeManager.currentTheme
        contentVC.apply(theme: theme)
        contentVC.setCommands(commands)

        let parentFrame = parentWindow.frame
        let x = parentFrame.origin.x + (parentFrame.width - frame.width) / 2
        let y = parentFrame.maxY - frame.height - 100
        setFrameOrigin(NSPoint(x: x, y: y))

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
    private var searchField: NSTextField!
    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
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

        searchField = NSTextField(string: "")
        searchField.placeholderString = "Type a command..."
        searchField.isBordered = true
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13, weight: .medium)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        root.addSubview(searchField)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 34),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        view = root
        apply(theme: currentTheme)
    }

    func apply(theme: AppTheme) {
        currentTheme = theme
        guard isViewLoaded else { return }

        view.layer?.backgroundColor = theme.colors.bgPanel.withAlphaComponent(0.95).cgColor
        view.layer?.borderColor = theme.colors.borderSubtle.cgColor

        searchField.backgroundColor = theme.colors.bgRaised
        searchField.textColor = theme.colors.textPrimary
        searchField.drawsBackground = true
        searchField.wantsLayer = true
        searchField.layer?.cornerRadius = 8
        searchField.layer?.borderWidth = 1
        searchField.layer?.borderColor = theme.colors.borderSubtle.cgColor

        refreshRows()
    }

    func setCommands(_ commands: [CommandItem]) {
        self.commands = commands
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
    }

    private func refreshRows() {
        for row in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        resultRows.removeAll(keepingCapacity: true)

        if filtered.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "No matching commands")
            emptyLabel.font = .systemFont(ofSize: 12, weight: .regular)
            emptyLabel.textColor = currentTheme.colors.textMuted
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(emptyLabel)
            return
        }

        for (index, item) in filtered.enumerated() {
            let row = CommandPaletteRowView(theme: currentTheme)
            row.configure(item: item, highlighted: index == selectedIndex)
            row.onClick = { [weak self] in
                self?.selectedIndex = index
                self?.executeSelection()
            }
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            stackView.addArrangedSubview(row)
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
        guard selectedIndex >= 0, selectedIndex < resultRows.count else { return }
        let clipView = scrollView.contentView

        let rowFrame = resultRows[selectedIndex].frame
        clipView.scrollToVisible(rowFrame)
        scrollView.reflectScrolledClipView(clipView)
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

    private let iconLabel = NSTextField(labelWithString: "")
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
        iconLabel.font = .systemFont(ofSize: 18, weight: .regular)
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconLabel)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(descriptionLabel)

        shortcutContainer.wantsLayer = true
        shortcutContainer.layer?.cornerRadius = 6
        shortcutContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutContainer)

        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.alignment = .center
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutContainer.addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),

            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconLabel.widthAnchor.constraint(equalToConstant: 24),

            shortcutContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcutContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutContainer.heightAnchor.constraint(equalToConstant: 20),

            shortcutLabel.leadingAnchor.constraint(equalTo: shortcutContainer.leadingAnchor, constant: 6),
            shortcutLabel.trailingAnchor.constraint(equalTo: shortcutContainer.trailingAnchor, constant: -6),
            shortcutLabel.centerYAnchor.constraint(equalTo: shortcutContainer.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutContainer.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickGesture)
    }

    func configure(item: CommandItem, highlighted: Bool) {
        iconLabel.stringValue = item.icon
        titleLabel.stringValue = item.label
        descriptionLabel.stringValue = item.description
        shortcutLabel.stringValue = item.shortcut ?? ""
        shortcutContainer.isHidden = item.shortcut == nil

        titleLabel.textColor = theme.colors.textPrimary
        descriptionLabel.textColor = theme.colors.textMuted
        shortcutLabel.textColor = theme.colors.textMuted
        shortcutContainer.layer?.backgroundColor = theme.colors.bgRaised.cgColor

        setHighlighted(highlighted)
    }

    func setHighlighted(_ highlighted: Bool) {
        layer?.backgroundColor = highlighted
            ? theme.colors.bgRaised.cgColor
            : NSColor.clear.cgColor
    }

    @objc private func handleClick() {
        onClick?()
    }
}
