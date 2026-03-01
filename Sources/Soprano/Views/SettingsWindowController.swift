import AppKit

final class SettingsWindowController: NSWindowController {
    private let themeManager: ThemeManager
    private let mcpManager: McpManager
    private let contentVC: SettingsViewController

    private(set) var settings: AppSettings
    private(set) var keybindingConfig: KeyBindingConfig

    var onSettingsChanged: ((AppSettings) -> Void)?
    var onKeybindingConfigChanged: ((KeyBindingConfig) -> Void)?

    init(
        themeManager: ThemeManager,
        settings: AppSettings,
        keybindingConfig: KeyBindingConfig,
        mcpManager: McpManager
    ) {
        self.themeManager = themeManager
        self.settings = settings
        self.keybindingConfig = keybindingConfig
        self.mcpManager = mcpManager

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.minSize = NSSize(width: 700, height: 500)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)

        contentVC = SettingsViewController(
            themeManager: themeManager,
            settings: settings,
            keybindingConfig: keybindingConfig,
            mcpManager: mcpManager
        )

        super.init(window: window)

        window.contentViewController = contentVC
        contentVC.onSettingsChanged = { [weak self] nextSettings in
            guard let self else { return }
            self.settings = nextSettings
            self.onSettingsChanged?(nextSettings)
            self.applyTheme()
        }
        contentVC.onKeybindingConfigChanged = { [weak self] nextConfig in
            guard let self else { return }
            self.keybindingConfig = nextConfig
            self.onKeybindingConfigChanged?(nextConfig)
        }

        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showSettingsWindow() {
        guard let window else { return }
        applyTheme()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyTheme() {
        guard let window else { return }
        let theme = themeManager.currentTheme
        window.backgroundColor = theme.colors.bgBase
        window.appearance = NSAppearance(named: .darkAqua)
        contentVC.apply(theme: theme)
    }
}

private enum SettingsTab: Int, CaseIterable {
    case general
    case keyboardShortcuts
    case agentProfiles
    case mcpServers
    case about

    var title: String {
        switch self {
        case .general: return "General"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .agentProfiles: return "Agent Profiles"
        case .mcpServers: return "MCP Servers"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .keyboardShortcuts: return "keyboard"
        case .agentProfiles: return "cpu"
        case .mcpServers: return "network"
        case .about: return "info.circle"
        }
    }
}

private final class SettingsViewController: NSViewController {
    private let themeManager: ThemeManager
    private let mcpManager: McpManager
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

    private var addServerButton: NSButton?
    private var serverCardsStack: NSStackView?
    private var addServerFormContainer: NSView?
    private var addServerNameField: NSTextField?
    private var addServerCommandField: NSTextField?
    private var addServerArgsField: NSTextField?
    private var addServerTransportPopup: NSPopUpButton?
    private var addServerPortField: NSTextField?
    private var addServerAutoStartButton: NSButton?
    private var isAddServerFormVisible = false

    init(
        themeManager: ThemeManager,
        settings: AppSettings,
        keybindingConfig: KeyBindingConfig,
        mcpManager: McpManager
    ) {
        self.themeManager = themeManager
        self.settings = settings
        self.keybindingConfig = keybindingConfig
        self.mcpManager = mcpManager
        self.currentTheme = themeManager.currentTheme
        super.init(nibName: nil, bundle: nil)

        mcpManager.addObserver(id: "SettingsViewController-mcp") { [weak self] in
            self?.handleMcpChange()
        }
    }

    deinit {
        mcpManager.removeObserver(id: "SettingsViewController-mcp")
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

        scrollDocumentView = NSView()
        scrollDocumentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = scrollDocumentView

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollDocumentView.addSubview(contentStack)

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
            scrollDocumentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            scrollDocumentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollDocumentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollDocumentView.trailingAnchor),
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
        case .mcpServers:
            buildMcpServersTab()
        case .about:
            buildAboutTab()
        }
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
            card.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36),
        ])
        return (card, stack)
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
        contentStack.addArrangedSubview(
            makeTabHeader(
                title: "General",
                subtitle: "Theme, persistence, project roots, and keybinding behavior."
            )
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
        contentStack.addArrangedSubview(appearanceCard)

        let (sessionCard, sessionStack) = makeSectionCard(title: "Session", subtitle: "Restore workspace state from the previous app launch.")
        let restoreButton = NSButton(checkboxWithTitle: "Restore Last Session", target: self, action: #selector(restoreSessionChanged(_:)))
        restoreButton.state = settings.restoreLastSession ? .on : .off
        restoreButton.contentTintColor = currentTheme.colors.textPrimary
        restoreSessionButton = restoreButton
        sessionStack.addArrangedSubview(restoreButton)
        contentStack.addArrangedSubview(sessionCard)

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
        projectDirectoryInput = input
        addRow.addArrangedSubview(input)

        let browseButton = makeActionButton(title: "Browse", action: #selector(browseProjectDirectory))
        addRow.addArrangedSubview(browseButton)

        let addButton = makeActionButton(title: "Add", action: #selector(addProjectDirectory))
        addRow.addArrangedSubview(addButton)
        projectStack.addArrangedSubview(addRow)

        contentStack.addArrangedSubview(projectCard)

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
            timeoutField.target = self
            timeoutField.action = #selector(prefixTimeoutCommitted(_:))
            resizeField.target = self
            resizeField.action = #selector(resizeStepCommitted(_:))
        }

        contentStack.addArrangedSubview(keybindingCard)
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

            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: list.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 32),

                pathLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
                pathLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -8),

                removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])

            list.addArrangedSubview(row)
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            projectDirectoryInput?.stringValue = url.path
        }
    }

    @objc private func addProjectDirectory() {
        guard let input = projectDirectoryInput else { return }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard !settings.projectDirectories.contains(value) else {
            input.stringValue = ""
            return
        }

        settings.projectDirectories.append(value)
        settings.save()
        onSettingsChanged?(settings)
        input.stringValue = ""
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
        contentStack.addArrangedSubview(
            makeTabHeader(
                title: "Keyboard Shortcuts",
                subtitle: "Read-only keybinding reference grouped by category."
            )
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

            let headerRow = makeShortcutRow(
                action: "Action",
                description: "Description",
                mode: "Mode",
                keys: "Binding",
                index: 0,
                isHeader: true
            )
            stack.addArrangedSubview(headerRow)

            for (index, binding) in bindings.enumerated() {
                let row = makeShortcutRow(
                    action: binding.label,
                    description: binding.description,
                    mode: binding.mode == .direct ? "direct" : "prefix",
                    keys: binding.defaultKeys,
                    index: index,
                    isHeader: false
                )
                stack.addArrangedSubview(row)
            }
            contentStack.addArrangedSubview(card)
        }
    }

    private func makeShortcutRow(
        action: String,
        description: String,
        mode: String,
        keys: String,
        index: Int,
        isHeader: Bool
    ) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.backgroundColor = isHeader
            ? currentTheme.colors.bgOverlay.cgColor
            : (index % 2 == 0 ? currentTheme.colors.bgRaised.cgColor : currentTheme.colors.bgPanel.cgColor)
        row.translatesAutoresizingMaskIntoConstraints = false

        let actionLabel = NSTextField(labelWithString: action)
        actionLabel.font = .systemFont(ofSize: 11, weight: isHeader ? .semibold : .medium)
        actionLabel.textColor = currentTheme.colors.textPrimary
        actionLabel.lineBreakMode = .byTruncatingTail
        actionLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(actionLabel)

        let descriptionLabel = NSTextField(labelWithString: description)
        descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        descriptionLabel.textColor = currentTheme.colors.textMuted
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(descriptionLabel)

        let modeLabel = NSTextField(labelWithString: mode)
        modeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        modeLabel.textColor = currentTheme.colors.textMuted
        modeLabel.alignment = .center
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(modeLabel)

        let keyBadge = NSTextField(labelWithString: keys)
        keyBadge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        keyBadge.textColor = currentTheme.colors.textPrimary
        keyBadge.alignment = .center
        keyBadge.wantsLayer = true
        keyBadge.layer?.cornerRadius = 5
        keyBadge.layer?.backgroundColor = currentTheme.colors.bgOverlay.cgColor
        keyBadge.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(keyBadge)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -60),
            row.heightAnchor.constraint(equalToConstant: 30),

            actionLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            actionLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            actionLabel.widthAnchor.constraint(equalToConstant: 130),

            descriptionLabel.leadingAnchor.constraint(equalTo: actionLabel.trailingAnchor, constant: 8),
            descriptionLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: modeLabel.leadingAnchor, constant: -8),

            modeLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            modeLabel.trailingAnchor.constraint(equalTo: keyBadge.leadingAnchor, constant: -8),
            modeLabel.widthAnchor.constraint(equalToConstant: 58),

            keyBadge.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            keyBadge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            keyBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
            keyBadge.heightAnchor.constraint(equalToConstant: 20),
        ])
        return row
    }

    private func buildAgentProfilesTab() {
        contentStack.addArrangedSubview(
            makeTabHeader(
                title: "Agent Profiles",
                subtitle: "Read-only profile registry loaded from DefaultAgents."
            )
        )

        let gridStack = NSStackView()
        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = 10
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36).isActive = true

        var currentRow: NSStackView?
        for (index, profile) in DefaultAgents.all.enumerated() {
            if index % 2 == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.distribution = .fillEqually
                row.alignment = .top
                row.spacing = 10
                row.translatesAutoresizingMaskIntoConstraints = false
                row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
                gridStack.addArrangedSubview(row)
                currentRow = row
            }

            let card = makeAgentCard(profile)
            currentRow?.addArrangedSubview(card)
        }

        contentStack.addArrangedSubview(gridStack)
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

    private func buildMcpServersTab() {
        contentStack.addArrangedSubview(
            makeTabHeader(
                title: "MCP Servers",
                subtitle: "Manage Model Context Protocol server pool and runtime status."
            )
        )

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36).isActive = true

        let addButtonTitle = isAddServerFormVisible ? "Hide Add Form" : "Add Server"
        let addButton = makeActionButton(title: addButtonTitle, action: #selector(toggleAddServerForm))
        addServerButton = addButton
        controls.addArrangedSubview(addButton)
        contentStack.addArrangedSubview(controls)

        let form = buildAddServerForm()
        addServerFormContainer = form
        form.isHidden = !isAddServerFormVisible
        contentStack.addArrangedSubview(form)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36).isActive = true
        serverCardsStack = stack
        contentStack.addArrangedSubview(stack)
        rebuildMcpServerCards()
    }

    private func buildAddServerForm() -> NSView {
        let (card, stack) = makeSectionCard(title: "Add MCP Server")

        let nameField = makeTextField(value: "")
        nameField.placeholderString = "Name"
        addServerNameField = nameField

        let commandField = makeTextField(value: "")
        commandField.placeholderString = "Command"
        addServerCommandField = commandField

        let argsField = makeTextField(value: "")
        argsField.placeholderString = "Args (space separated)"
        addServerArgsField = argsField

        let transportPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        transportPopup.addItems(withTitles: ["stdio", "sse"])
        transportPopup.selectItem(withTitle: "stdio")
        addServerTransportPopup = transportPopup

        let portField = makeNumberField(value: "3000")
        addServerPortField = portField

        let autoStart = NSButton(checkboxWithTitle: "Auto-start", target: nil, action: nil)
        autoStart.state = .off
        addServerAutoStartButton = autoStart

        let grid = NSGridView(views: [
            [makeFieldLabel("Name"), nameField],
            [makeFieldLabel("Command"), commandField],
            [makeFieldLabel("Args"), argsField],
            [makeFieldLabel("Transport"), transportPopup],
            [makeFieldLabel("Port"), portField],
            [makeFieldLabel("Auto-start"), autoStart],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        stack.addArrangedSubview(grid)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let add = makeActionButton(title: "Create Server", action: #selector(addServerCommitted))
        actions.addArrangedSubview(add)

        let cancel = makeActionButton(title: "Cancel", action: #selector(cancelAddServerForm))
        actions.addArrangedSubview(cancel)

        stack.addArrangedSubview(actions)
        return card
    }

    @objc private func toggleAddServerForm() {
        isAddServerFormVisible.toggle()
        addServerButton?.title = isAddServerFormVisible ? "Hide Add Form" : "Add Server"
        addServerFormContainer?.isHidden = !isAddServerFormVisible
    }

    @objc private func cancelAddServerForm() {
        isAddServerFormVisible = false
        addServerFormContainer?.isHidden = true
        addServerButton?.title = "Add Server"
    }

    @objc private func addServerCommitted() {
        guard let nameField = addServerNameField,
              let commandField = addServerCommandField,
              let argsField = addServerArgsField,
              let transportPopup = addServerTransportPopup,
              let portField = addServerPortField,
              let autoStartButton = addServerAutoStartButton
        else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return }

        let args = argsField.stringValue
            .split(separator: " ")
            .map(String.init)
        let portValue = UInt16(Int(portField.stringValue) ?? 3000)
        let transport: McpTransport = transportPopup.titleOfSelectedItem == "sse" ? .sse : .stdio

        let config = McpServerConfig(
            id: "mcp-\(UUID().uuidString.lowercased().prefix(8))",
            name: name,
            icon: "server",
            color: "#58a6ff",
            command: command,
            args: args,
            env: nil,
            transport: transport,
            port: portValue,
            autoStart: autoStartButton.state == .on
        )
        mcpManager.addServer(config)

        nameField.stringValue = ""
        commandField.stringValue = ""
        argsField.stringValue = ""
        portField.stringValue = "3000"
        autoStartButton.state = .off

        isAddServerFormVisible = false
        addServerFormContainer?.isHidden = true
        addServerButton?.title = "Add Server"
        rebuildMcpServerCards()
    }

    private func rebuildMcpServerCards() {
        guard let stack = serverCardsStack else { return }
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        if mcpManager.pool.isEmpty {
            let empty = NSTextField(labelWithString: "No MCP servers configured")
            empty.font = .systemFont(ofSize: 12, weight: .regular)
            empty.textColor = currentTheme.colors.textMuted
            stack.addArrangedSubview(empty)
            return
        }

        for entry in mcpManager.pool {
            let card = makeMcpServerCard(entry)
            stack.addArrangedSubview(card)
        }
    }

    private func makeMcpServerCard(_ entry: McpPoolEntry) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.backgroundColor = currentTheme.colors.bgPanel.cgColor
        card.layer?.borderColor = currentTheme.colors.borderSubtle.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -36).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        let statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.layer?.backgroundColor = mcpStatusColor(entry.instance.status).cgColor
        topRow.addArrangedSubview(statusDot)

        let nameLabel = NSTextField(labelWithString: entry.config.name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = currentTheme.colors.textPrimary
        topRow.addArrangedSubview(nameLabel)

        let statusText = NSTextField(labelWithString: mcpStatusText(entry.instance))
        statusText.font = .systemFont(ofSize: 11, weight: .regular)
        statusText.textColor = currentTheme.colors.textMuted
        statusText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topRow.addArrangedSubview(statusText)
        stack.addArrangedSubview(topRow)

        let commandLabel = NSTextField(labelWithString: "Command: \(entry.config.command) \(entry.config.args.joined(separator: " "))")
        commandLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        commandLabel.textColor = currentTheme.colors.textPrimary
        commandLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(commandLabel)

        let transportLabel = NSTextField(labelWithString: "Transport: \(entry.config.transport.rawValue.uppercased())   Port: \(entry.config.port)")
        transportLabel.font = .systemFont(ofSize: 10, weight: .regular)
        transportLabel.textColor = currentTheme.colors.textMuted
        stack.addArrangedSubview(transportLabel)

        if let url = entry.instance.url, !url.isEmpty {
            let urlLabel = NSTextField(labelWithString: "URL: \(url)")
            urlLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            urlLabel.textColor = currentTheme.colors.blue
            stack.addArrangedSubview(urlLabel)
        }

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let startStopTitle = entry.instance.status == .running || entry.instance.status == .starting ? "Stop" : "Start"
        let startStop = NSButton(title: startStopTitle, target: self, action: #selector(mcpStartStopClicked(_:)))
        startStop.bezelStyle = .rounded
        startStop.identifier = NSUserInterfaceItemIdentifier(entry.config.id)
        actionRow.addArrangedSubview(startStop)

        let restart = NSButton(title: "Restart", target: self, action: #selector(mcpRestartClicked(_:)))
        restart.bezelStyle = .rounded
        restart.identifier = NSUserInterfaceItemIdentifier(entry.config.id)
        actionRow.addArrangedSubview(restart)

        let remove = NSButton(title: "Remove", target: self, action: #selector(mcpRemoveClicked(_:)))
        remove.bezelStyle = .rounded
        remove.identifier = NSUserInterfaceItemIdentifier(entry.config.id)
        actionRow.addArrangedSubview(remove)

        stack.addArrangedSubview(actionRow)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    private func mcpStatusText(_ instance: McpServerInstance) -> String {
        switch instance.status {
        case .running:
            return "running"
        case .starting:
            return "starting"
        case .stopped:
            return "stopped"
        case .error:
            return instance.error ?? "error"
        }
    }

    private func mcpStatusColor(_ status: McpServerStatus) -> NSColor {
        switch status {
        case .running:
            return currentTheme.colors.success
        case .starting:
            return currentTheme.colors.yellow
        case .error:
            return currentTheme.colors.danger
        case .stopped:
            return currentTheme.colors.gray
        }
    }

    @objc private func mcpStartStopClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let entry = mcpManager.pool.first(where: { $0.id == id })
        else { return }

        if entry.instance.status == .running || entry.instance.status == .starting {
            mcpManager.stopServer(id)
        } else {
            mcpManager.startServer(id)
        }
        rebuildMcpServerCards()
    }

    @objc private func mcpRestartClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        mcpManager.restartServer(id)
        rebuildMcpServerCards()
    }

    @objc private func mcpRemoveClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        mcpManager.removeServer(id)
        rebuildMcpServerCards()
    }

    private func handleMcpChange() {
        if currentTab == .mcpServers {
            rebuildMcpServerCards()
        }
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

            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -60),
                row.heightAnchor.constraint(equalToConstant: 28),

                keyLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
                keyLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                keyLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
                keyLabel.heightAnchor.constraint(equalToConstant: 18),

                actionLabel.leadingAnchor.constraint(equalTo: keyLabel.trailingAnchor, constant: 8),
                actionLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                actionLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            ])

            quickRefStack.addArrangedSubview(row)
        }
        contentStack.addArrangedSubview(quickRefCard)
    }

    private func quickReferenceBindings() -> [(String, String)] {
        let preferredIds = [
            "command-palette",
            "open-settings",
            "new-terminal",
            "new-browser",
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
