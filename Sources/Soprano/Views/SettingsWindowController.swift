import AppKit

private enum SettingsTab: Int, CaseIterable {
    case general
    case keyboardShortcuts
    case agentProfiles
    case about

    var title: String {
        switch self {
        case .general: return "General"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .agentProfiles: return "Agent Profiles"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .keyboardShortcuts: return "keyboard"
        case .agentProfiles: return "cpu"
        case .about: return "info.circle"
        }
    }
}

final class SettingsViewController: NSViewController {
    private let themeManager: ThemeManager
    private var settings: AppSettings
    private var keybindingConfig: KeyBindingConfig

    var onSettingsChanged: ((AppSettings) -> Void)?
    var onKeybindingConfigChanged: ((KeyBindingConfig) -> Void)?

    private var currentTab: SettingsTab = .general
    private var currentTheme: AppTheme

    private var rootContainer: NSView!
    private var sidebar: NSView!
    private var tabStack: NSStackView!
    private var contentBackgroundView: NSView!
    private var scrollView: NSScrollView!
    private var scrollDocumentView: NSView!
    private var contentStack: NSStackView!
    private var tabButtons: [SettingsTab: NSButton] = [:]

    private var themePopup: NSPopUpButton?
    private var restoreSessionButton: NSButton?
    private var projectDirectoriesStack: NSStackView?
    private var projectDirectoryInput: NSTextField?
    private var prefixKeyField: NSTextField?
    private var prefixTimeoutField: NSTextField?
    private var resizeStepField: NSTextField?

    init(
        themeManager: ThemeManager,
        settings: AppSettings,
        keybindingConfig: KeyBindingConfig
    ) {
        self.themeManager = themeManager
        self.settings = settings
        self.keybindingConfig = keybindingConfig
        self.currentTheme = themeManager.currentTheme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        rootContainer = NSView()
        rootContainer.wantsLayer = true

        sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(sidebar)

        tabStack = NSStackView()
        tabStack.orientation = .vertical
        tabStack.spacing = 6
        tabStack.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(tabStack)

        for tab in SettingsTab.allCases {
            let button = makeTabButton(for: tab)
            tabButtons[tab] = button
            tabStack.addArrangedSubview(button)
        }

        contentBackgroundView = NSView()
        contentBackgroundView.wantsLayer = true
        contentBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        rootContainer.addSubview(contentBackgroundView)

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentBackgroundView.addSubview(scrollView)

        scrollDocumentView = SettingsScrollDocumentView(frame: .zero)
        scrollDocumentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = scrollDocumentView

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollDocumentView.addSubview(contentStack)

        let fillDocumentWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollDocumentView.widthAnchor
        )
        fillDocumentWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: rootContainer.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 180),

            contentBackgroundView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentBackgroundView.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            contentBackgroundView.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            contentBackgroundView.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),

            tabStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tabStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabStack.topAnchor.constraint(equalTo: sidebar.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: contentBackgroundView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentBackgroundView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentBackgroundView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentBackgroundView.bottomAnchor),

            scrollDocumentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            scrollDocumentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            scrollDocumentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            // The document may be taller than the viewport. Equality here makes
            // the full shortcuts list become the window's minimum height.
            scrollDocumentView.bottomAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.bottomAnchor
            ),
            scrollDocumentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.centerXAnchor.constraint(equalTo: scrollDocumentView.centerXAnchor),
            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: scrollDocumentView.leadingAnchor
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollDocumentView.trailingAnchor
            ),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 960),
            fillDocumentWidth,
            contentStack.topAnchor.constraint(equalTo: scrollDocumentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollDocumentView.bottomAnchor),
        ])

        view = rootContainer
        rebuildCurrentTab()
        apply(theme: currentTheme)
    }

    func apply(theme: AppTheme) {
        currentTheme = theme
        guard isViewLoaded else { return }

        view.layer?.backgroundColor = theme.colors.bgBase.cgColor
        sidebar.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        contentBackgroundView.layer?.backgroundColor = theme.colors.bgBase.cgColor

        for (tab, button) in tabButtons {
            styleTabButton(button, tab: tab, active: tab == currentTab)
        }

        rebuildCurrentTab()
    }

    private func makeTabButton(for tab: SettingsTab) -> NSButton {
        let button = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
        button.tag = tab.rawValue
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.contentTintColor = currentTheme.colors.textMuted
        button.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
        button.image?.size = NSSize(width: 14, height: 14)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 34),
            button.widthAnchor.constraint(equalToConstant: 160),
        ])
        styleTabButton(button, tab: tab, active: tab == currentTab)
        return button
    }

    private func styleTabButton(_ button: NSButton, tab: SettingsTab, active: Bool) {
        let theme = currentTheme
        button.layer?.backgroundColor = active ? theme.colors.accent.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
        button.contentTintColor = active ? theme.colors.accent : theme.colors.textMuted
        button.attributedTitle = NSAttributedString(
            string: tab.title,
            attributes: [
                .foregroundColor: active ? theme.colors.textPrimary : theme.colors.textMuted,
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            ]
        )
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let tab = SettingsTab(rawValue: sender.tag) else { return }
        view.window?.endEditing(for: nil)
        currentTab = tab
        for (item, button) in tabButtons {
            styleTabButton(button, tab: item, active: item == tab)
        }
        rebuildCurrentTab()
    }

    private func clearContent() {
        for subview in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
    }

    private func rebuildCurrentTab() {
        guard isViewLoaded else { return }
        clearContent()
        switch currentTab {
        case .general:
            buildGeneralTab()
        case .keyboardShortcuts:
            buildKeyboardShortcutsTab()
        case .agentProfiles:
            buildAgentProfilesTab()
        case .about:
            buildAboutTab()
        }

        // Keep settings cards at their natural height when the window is taller
        // than the content. This spacer absorbs the remaining viewport space.
        let flexibleSpace = NSView()
        flexibleSpace.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(flexibleSpace)
        flexibleSpace.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true

        view.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func makeTabHeader(title: String, subtitle: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = currentTheme.colors.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = currentTheme.colors.textMuted
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func addTabHeader(title: String, subtitle: String) {
        addContentSubview(
            makeTabHeader(title: title, subtitle: subtitle),
            widthInset: -36
        )
    }

    private func makeSectionCard(title: String, subtitle: String? = nil) -> (NSView, NSStackView) {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.backgroundColor = currentTheme.colors.bgPanel.cgColor
        card.layer?.borderColor = currentTheme.colors.borderSubtle.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = currentTheme.colors.textPrimary
        stack.addArrangedSubview(titleLabel)

        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            subtitleLabel.textColor = currentTheme.colors.textMuted
            subtitleLabel.maximumNumberOfLines = 0
            stack.addArrangedSubview(subtitleLabel)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return (card, stack)
    }

    private func addContentSubview(_ view: NSView, widthInset: CGFloat? = nil) {
        contentStack.addArrangedSubview(view)
        if let widthInset {
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: widthInset).isActive = true
        }
    }

    private func makeFieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = currentTheme.colors.textMuted
        return label
    }

    private func makeTextField(value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.isBordered = true
        field.focusRingType = .none
        field.drawsBackground = true
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.borderWidth = 1
        field.layer?.borderColor = currentTheme.colors.borderSubtle.cgColor
        field.backgroundColor = currentTheme.colors.bgRaised
        field.textColor = currentTheme.colors.textPrimary
        field.font = .systemFont(ofSize: 12, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeNumberField(value: String) -> NSTextField {
        let field = makeTextField(value: value)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = false
        formatter.minimum = 0
        field.formatter = formatter
        return field
    }

    private func makeActionButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func buildGeneralTab() {
        addTabHeader(
            title: "General",
            subtitle: "Theme, persistence, project roots, and keybinding behavior."
        )

        let (appearanceCard, appearanceStack) = makeSectionCard(title: "Appearance", subtitle: "Switch between available app themes.")
        let themeRow = NSStackView()
        themeRow.orientation = .horizontal
        themeRow.alignment = .centerY
        themeRow.distribution = .fill
        themeRow.spacing = 10

        let themeLabel = makeFieldLabel("Theme")
        themeLabel.setContentHuggingPriority(.required, for: .horizontal)
        themeRow.addArrangedSubview(themeLabel)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(themeChanged(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.removeAllItems()
        popup.addItems(withTitles: AppTheme.allThemes.map(\.name))
        if let selectedIndex = AppTheme.allThemes.firstIndex(where: { $0.id == settings.themeId }) {
            popup.selectItem(at: selectedIndex)
        }
        themePopup = popup
        themeRow.addArrangedSubview(popup)
        popup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        appearanceStack.addArrangedSubview(themeRow)
        addContentSubview(appearanceCard, widthInset: -36)

        let (sessionCard, sessionStack) = makeSectionCard(title: "Session", subtitle: "Restore workspace state from the previous app launch.")
        let restoreButton = NSButton(checkboxWithTitle: "Restore Last Session", target: self, action: #selector(restoreSessionChanged(_:)))
        restoreButton.state = settings.restoreLastSession ? .on : .off
        restoreButton.contentTintColor = currentTheme.colors.accent
        restoreButton.attributedTitle = NSAttributedString(
            string: "Restore Last Session",
            attributes: [
                .foregroundColor: currentTheme.colors.textPrimary,
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            ]
        )
        restoreSessionButton = restoreButton
        sessionStack.addArrangedSubview(restoreButton)
        addContentSubview(sessionCard, widthInset: -36)

        let (projectCard, projectStack) = makeSectionCard(title: "Project Directories", subtitle: "Directories available to project-aware features.")
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        projectDirectoriesStack = listStack
        projectStack.addArrangedSubview(listStack)
        rebuildProjectDirectoriesList()

        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.alignment = .centerY
        addRow.spacing = 8

        let input = makeTextField(value: "")
        input.placeholderString = "Folder path"
        input.target = self
        input.action = #selector(addProjectDirectory)
        input.cell?.sendsActionOnEndEditing = false
        projectDirectoryInput = input
        addRow.addArrangedSubview(input)

        let browseButton = makeActionButton(title: "Browse", action: #selector(browseProjectDirectory))
        addRow.addArrangedSubview(browseButton)

        let addButton = makeActionButton(title: "Add", action: #selector(addProjectDirectory))
        addRow.addArrangedSubview(addButton)
        projectStack.addArrangedSubview(addRow)

        addContentSubview(projectCard, widthInset: -36)

        let (keybindingCard, keybindingStack) = makeSectionCard(title: "Keybinding Behavior", subtitle: "Adjust prefix trigger and pane resize granularity.")
        let grid = NSGridView(views: [
            [makeFieldLabel("Prefix Key"), makeTextField(value: keybindingConfig.prefixKey)],
            [makeFieldLabel("Prefix Timeout (ms)"), makeNumberField(value: "\(keybindingConfig.prefixTimeoutMs)")],
            [makeFieldLabel("Resize Step (%)"), makeNumberField(value: "\(Int(keybindingConfig.resizeTickPercent))")],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        keybindingStack.addArrangedSubview(grid)

        if let prefixField = (grid.cell(atColumnIndex: 1, rowIndex: 0).contentView as? NSTextField),
           let timeoutField = (grid.cell(atColumnIndex: 1, rowIndex: 1).contentView as? NSTextField),
           let resizeField = (grid.cell(atColumnIndex: 1, rowIndex: 2).contentView as? NSTextField) {
            prefixKeyField = prefixField
            prefixTimeoutField = timeoutField
            resizeStepField = resizeField

            prefixField.target = self
            prefixField.action = #selector(prefixKeyCommitted(_:))
            prefixField.cell?.sendsActionOnEndEditing = true
            timeoutField.target = self
            timeoutField.action = #selector(prefixTimeoutCommitted(_:))
            timeoutField.cell?.sendsActionOnEndEditing = true
            resizeField.target = self
            resizeField.action = #selector(resizeStepCommitted(_:))
            resizeField.cell?.sendsActionOnEndEditing = true
        }

        addContentSubview(keybindingCard, widthInset: -36)
    }

    private func rebuildProjectDirectoriesList() {
        guard let list = projectDirectoriesStack else { return }
        for row in list.arrangedSubviews {
            list.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        if settings.projectDirectories.isEmpty {
            let empty = NSTextField(labelWithString: "No project directories configured")
            empty.font = .systemFont(ofSize: 11, weight: .regular)
            empty.textColor = currentTheme.colors.textMuted
            list.addArrangedSubview(empty)
            return
        }

        for (index, directory) in settings.projectDirectories.enumerated() {
            let row = NSView()
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            row.layer?.borderWidth = 1
            row.layer?.backgroundColor = currentTheme.colors.bgRaised.cgColor
            row.layer?.borderColor = currentTheme.colors.borderSubtle.cgColor
            row.translatesAutoresizingMaskIntoConstraints = false

            let pathLabel = NSTextField(labelWithString: directory)
            pathLabel.font = .systemFont(ofSize: 11, weight: .regular)
            pathLabel.textColor = currentTheme.colors.textPrimary
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(pathLabel)

            let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeProjectDirectory(_:)))
            removeButton.bezelStyle = .inline
            removeButton.tag = index
            removeButton.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(removeButton)

            list.addArrangedSubview(row)

            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: list.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 32),

                pathLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                pathLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -8),

                removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])

        }
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < AppTheme.allThemes.count else { return }
        let selectedTheme = AppTheme.allThemes[index]

        settings.themeId = selectedTheme.id
        settings.save()
        onSettingsChanged?(settings)

        themeManager.setTheme(id: selectedTheme.id)
        apply(theme: themeManager.currentTheme)
    }

    @objc private func restoreSessionChanged(_ sender: NSButton) {
        settings.restoreLastSession = sender.state == .on
        settings.save()
        onSettingsChanged?(settings)
    }

    @objc private func browseProjectDirectory() {
        guard let window = view.window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose a project directory"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            self?.storeProjectDirectory(path)
        }
    }

    @objc private func addProjectDirectory() {
        guard let input = projectDirectoryInput else { return }
        storeProjectDirectory(input.stringValue)
    }

    private func storeProjectDirectory(_ rawPath: String) {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }

        let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
        let path = URL(fileURLWithPath: expandedPath, isDirectory: true)
            .standardizedFileURL.path

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            NSSound.beep()
            return
        }

        guard !settings.projectDirectories.contains(path) else {
            projectDirectoryInput?.stringValue = ""
            return
        }

        settings.projectDirectories.append(path)
        settings.save()
        onSettingsChanged?(settings)
        projectDirectoryInput?.stringValue = ""
        rebuildProjectDirectoriesList()
    }

    @objc private func removeProjectDirectory(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < settings.projectDirectories.count else { return }
        settings.projectDirectories.remove(at: sender.tag)
        settings.save()
        onSettingsChanged?(settings)
        rebuildProjectDirectoriesList()
    }

    @objc private func prefixKeyCommitted(_ sender: NSTextField) {
        let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            sender.stringValue = keybindingConfig.prefixKey
            return
        }
        let value = String(first).lowercased()
        sender.stringValue = value
        keybindingConfig.prefixKey = value
        DefaultKeybindings.save(keybindingConfig)
        onKeybindingConfigChanged?(keybindingConfig)
    }

    @objc private func prefixTimeoutCommitted(_ sender: NSTextField) {
        guard let intValue = Int(sender.stringValue) else {
            sender.stringValue = "\(keybindingConfig.prefixTimeoutMs)"
            return
        }
        let clamped = min(max(300, intValue), 5000)
        sender.stringValue = "\(clamped)"
        keybindingConfig.prefixTimeoutMs = clamped
        DefaultKeybindings.save(keybindingConfig)
        onKeybindingConfigChanged?(keybindingConfig)
    }

    @objc private func resizeStepCommitted(_ sender: NSTextField) {
        guard let intValue = Int(sender.stringValue) else {
            sender.stringValue = "\(Int(keybindingConfig.resizeTickPercent))"
            return
        }
        let clamped = min(max(1, intValue), 25)
        sender.stringValue = "\(clamped)"
        keybindingConfig.resizeTickPercent = Double(clamped)
        DefaultKeybindings.save(keybindingConfig)
        onKeybindingConfigChanged?(keybindingConfig)
    }

    private func buildKeyboardShortcutsTab() {
        addTabHeader(
            title: "Keyboard Shortcuts",
            subtitle: "Read-only keybinding reference grouped by category."
        )

        let groups: [(title: String, category: KeyBindingCategory)] = [
            ("Navigation", .navigation),
            ("Layout & Splits", .layout),
            ("Agent Launchers", .agents),
            ("General", .general),
        ]

        for (groupTitle, category) in groups {
            let bindings = keybindingConfig.bindings.filter { $0.category == category }
            let (card, stack) = makeSectionCard(title: groupTitle)
            stack.spacing = 0
            if let titleLabel = stack.arrangedSubviews.first {
                stack.setCustomSpacing(8, after: titleLabel)
            }

            for (index, binding) in bindings.enumerated() {
                if index > 0 {
                    let separator = makeShortcutSeparator()
                    stack.addArrangedSubview(separator)
                    separator.widthAnchor.constraint(
                        equalTo: stack.widthAnchor,
                        constant: -24
                    ).isActive = true
                }
                let row = makeShortcutRow(
                    action: binding.label,
                    description: binding.description,
                    mode: binding.mode == .direct ? "DIRECT" : "PREFIX",
                    keys: binding.defaultKeys
                )
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            addContentSubview(card, widthInset: -36)
        }
    }

    private func makeShortcutRow(
        action: String,
        description: String,
        mode: String,
        keys: String
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let actionLabel = NSTextField(labelWithString: action)
        actionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        actionLabel.textColor = currentTheme.colors.textPrimary
        actionLabel.lineBreakMode = .byTruncatingTail
        actionLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(actionLabel)

        let descriptionLabel = NSTextField(labelWithString: description)
        descriptionLabel.font = .systemFont(ofSize: 10, weight: .regular)
        descriptionLabel.textColor = currentTheme.colors.textMuted
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(descriptionLabel)

        let modeLabel = NSTextField(labelWithString: mode)
        modeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        modeLabel.textColor = currentTheme.colors.textMuted
        modeLabel.alignment = .center
        modeLabel.wantsLayer = true
        modeLabel.layer?.cornerRadius = 5
        modeLabel.layer?.backgroundColor = currentTheme.colors.bgRaised.cgColor
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(modeLabel)

        let keyBadge = NSTextField(labelWithString: keys)
        keyBadge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        keyBadge.textColor = currentTheme.colors.textPrimary
        keyBadge.alignment = .center
        keyBadge.wantsLayer = true
        keyBadge.layer?.cornerRadius = 6
        keyBadge.layer?.borderWidth = 1
        keyBadge.layer?.borderColor = currentTheme.colors.accent.withAlphaComponent(0.35).cgColor
        keyBadge.layer?.backgroundColor = currentTheme.colors.accent.withAlphaComponent(0.12).cgColor
        keyBadge.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(keyBadge)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 48),

            actionLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            actionLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            actionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: modeLabel.leadingAnchor,
                constant: -12
            ),

            descriptionLabel.leadingAnchor.constraint(equalTo: actionLabel.leadingAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: actionLabel.bottomAnchor, constant: 2),
            descriptionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: modeLabel.leadingAnchor,
                constant: -12
            ),
            descriptionLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7),

            modeLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: keyBadge.leadingAnchor, constant: -8),
            modeLabel.widthAnchor.constraint(equalToConstant: 58),
            modeLabel.heightAnchor.constraint(equalToConstant: 20),

            keyBadge.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            keyBadge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            keyBadge.widthAnchor.constraint(equalToConstant: 112),
            keyBadge.heightAnchor.constraint(equalToConstant: 24),
        ])
        return row
    }

    private func makeShortcutSeparator() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = currentTheme.colors.borderSubtle.withAlphaComponent(0.7).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func buildAgentProfilesTab() {
        addTabHeader(
            title: "Agent Profiles",
            subtitle: "Read-only profile registry loaded from DefaultAgents."
        )

        let gridStack = NSStackView()
        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = 10
        gridStack.translatesAutoresizingMaskIntoConstraints = false

        var currentRow: NSStackView?
        for (index, profile) in DefaultAgents.all.enumerated() {
            if index % 2 == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.distribution = .fillEqually
                row.alignment = .top
                row.spacing = 10
                row.translatesAutoresizingMaskIntoConstraints = false
                gridStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
                currentRow = row
            }

            let card = makeAgentCard(profile)
            currentRow?.addArrangedSubview(card)
        }

        addContentSubview(gridStack, widthInset: -36)
    }

    private func makeAgentCard(_ profile: AgentProfile) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.backgroundColor = currentTheme.colors.bgPanel.cgColor
        card.layer?.borderColor = currentTheme.colors.borderSubtle.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = profile.nsColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        titleRow.addArrangedSubview(dot)

        let title = NSTextField(labelWithString: "\(profile.icon)  \(profile.name)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = currentTheme.colors.textPrimary
        titleRow.addArrangedSubview(title)
        stack.addArrangedSubview(titleRow)

        let description = NSTextField(wrappingLabelWithString: profile.description)
        description.font = .systemFont(ofSize: 11, weight: .regular)
        description.textColor = currentTheme.colors.textMuted
        description.maximumNumberOfLines = 0
        stack.addArrangedSubview(description)

        let command = NSTextField(labelWithString: "Command: \(profile.command) \(profile.args.joined(separator: " "))")
        command.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        command.textColor = currentTheme.colors.textPrimary
        command.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(command)

        let ready = profile.patterns?.ready?.joined(separator: ", ") ?? "-"
        let error = profile.patterns?.error?.joined(separator: ", ") ?? "-"
        let patterns = NSTextField(wrappingLabelWithString: "Patterns\nReady: \(ready)\nError: \(error)")
        patterns.font = .systemFont(ofSize: 10, weight: .regular)
        patterns.textColor = currentTheme.colors.textMuted
        patterns.maximumNumberOfLines = 0
        stack.addArrangedSubview(patterns)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        return card
    }

    private func buildAboutTab() {
        let hero = NSView()
        hero.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Soprano")
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.textColor = currentTheme.colors.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(title)

        let tagline = NSTextField(labelWithString: "AI Agent Orchestration Platform")
        tagline.font = .systemFont(ofSize: 14, weight: .medium)
        tagline.textColor = currentTheme.colors.textMuted
        tagline.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(tagline)

        let version = NSTextField(labelWithString: "Version: 0.2.0")
        version.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        version.textColor = currentTheme.colors.textPrimary
        version.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(version)

        let runtime = NSTextField(labelWithString: "Runtime: Swift + AppKit + libghostty")
        runtime.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        runtime.textColor = currentTheme.colors.textMuted
        runtime.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(runtime)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            title.topAnchor.constraint(equalTo: hero.topAnchor),
            title.trailingAnchor.constraint(equalTo: hero.trailingAnchor),

            tagline.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            tagline.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            tagline.trailingAnchor.constraint(equalTo: hero.trailingAnchor),

            version.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            version.topAnchor.constraint(equalTo: tagline.bottomAnchor, constant: 12),
            version.trailingAnchor.constraint(equalTo: hero.trailingAnchor),

            runtime.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            runtime.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 4),
            runtime.trailingAnchor.constraint(equalTo: hero.trailingAnchor),
            runtime.bottomAnchor.constraint(equalTo: hero.bottomAnchor),
        ])

        contentStack.addArrangedSubview(hero)

        let (quickRefCard, quickRefStack) = makeSectionCard(title: "Quick Reference")
        let quickRows = quickReferenceBindings()
        for (key, label) in quickRows {
            let row = NSView()
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            row.layer?.backgroundColor = currentTheme.colors.bgRaised.cgColor
            row.translatesAutoresizingMaskIntoConstraints = false

            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            keyLabel.textColor = currentTheme.colors.textPrimary
            keyLabel.alignment = .center
            keyLabel.wantsLayer = true
            keyLabel.layer?.cornerRadius = 5
            keyLabel.layer?.backgroundColor = currentTheme.colors.bgOverlay.cgColor
            keyLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(keyLabel)

            let actionLabel = NSTextField(labelWithString: label)
            actionLabel.font = .systemFont(ofSize: 11, weight: .medium)
            actionLabel.textColor = currentTheme.colors.textMuted
            actionLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(actionLabel)

            quickRefStack.addArrangedSubview(row)

            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: quickRefStack.widthAnchor, constant: -24),
                row.heightAnchor.constraint(equalToConstant: 28),

                keyLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
                keyLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                keyLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
                keyLabel.heightAnchor.constraint(equalToConstant: 18),

                actionLabel.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 8),
                actionLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                actionLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            ])

        }
        addContentSubview(quickRefCard, widthInset: -36)
    }

    private func quickReferenceBindings() -> [(String, String)] {
        let preferredIds = [
            "command-palette",
            "open-settings",
            "new-window",
            "new-terminal",
            "split-horizontal",
            "split-vertical",
            "toggle-sidebar",
            "save-session",
        ]
        var rows: [(String, String)] = []
        for id in preferredIds {
            if let binding = keybindingConfig.bindings.first(where: { $0.id == id }) {
                rows.append((binding.defaultKeys, binding.label))
            }
        }
        return rows
    }
}

/// A top-anchored document view whose height can exceed the settings viewport.
private final class SettingsScrollDocumentView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
