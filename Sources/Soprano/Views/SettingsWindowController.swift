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

    /// Where edits go. Every control on this screen writes one key into
    /// `settings.json`; nothing here owns state of its own.
    private let configStore: ConfigStore
    /// What is currently drawn on screen but is not part of `settings` or
    /// `keybindingConfig`, so a change in either alone still triggers a
    /// rebuild: config problems, and the agent catalog.
    private var renderedIssues: [ConfigIssue] = []
    private var renderedAgents: [AgentProfile] = []

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
    private var hideWindowBarButton: NSButton?
    private var restoreSessionButton: NSButton?
    private var notificationSoundButton: NSButton?
    private var notificationStatusLabel: NSTextField?
    private var notificationFixButton: NSButton?
    private var projectDirectoriesStack: NSStackView?
    private var projectDirectoryInput: NSTextField?
    private var prefixKeyField: NSTextField?
    private var prefixTimeoutField: NSTextField?
    private var resizeStepField: NSTextField?

    init(
        themeManager: ThemeManager,
        settings: AppSettings,
        keybindingConfig: KeyBindingConfig,
        configStore: ConfigStore = .shared
    ) {
        self.themeManager = themeManager
        self.settings = settings
        self.keybindingConfig = keybindingConfig
        self.configStore = configStore
        self.currentTheme = themeManager.currentTheme
        super.init(nibName: nil, bundle: nil)

        // Permission can change while this screen is open — the user may be
        // sent to System Settings and come straight back. Registered by
        // selector so AppKit drops it on dealloc; a stored block token would
        // need a deinit, which cannot touch actor-isolated state.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(notificationAuthorizationDidChange),
            name: AgentNotificationManager.authorizationDidChange,
            object: nil
        )
    }

    @objc private func notificationAuthorizationDidChange() {
        refreshNotificationAuthorizationRow()
    }

    /// Adopts values that changed underneath the screen — either because the
    /// user edited `settings.json` in another app, or because a control here
    /// wrote to it.
    func update(settings: AppSettings, keybindingConfig: KeyBindingConfig) {
        // Issues are part of what this screen renders, and they move
        // *independently* of the values: a syntax error deliberately leaves the
        // last good settings in place, so comparing only those would leave the
        // error banner unrendered — exactly when the user needs it.
        let isUnchanged = settings == self.settings
            && keybindingConfig == self.keybindingConfig
            && configStore.issues == renderedIssues
            && configStore.resolved.agents == renderedAgents
        self.settings = settings
        self.keybindingConfig = keybindingConfig
        guard isViewLoaded, !isUnchanged else { return }

        // Rebuilding tears down the control that is mid-edit; let the current
        // event finish first so AppKit is not left editing a detached field.
        DispatchQueue.main.async { [weak self] in
            self?.rebuildCurrentTab()
        }
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
        contentStack.spacing = 24
        contentStack.edgeInsets = NSEdgeInsets(top: 24, left: 18, bottom: 28, right: 18)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollDocumentView.addSubview(contentStack)

        let fillDocumentWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollDocumentView.widthAnchor
        )
        // Keep this above content hugging so the settings use the available
        // width, but just below AppKit's `.windowSizeStayPut` priority so the
        // fitting width cannot shrink the main window.
        fillDocumentWidth.priority = NSLayoutConstraint.Priority(
            rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1
        )

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
            // A settings form is a reading column, not a canvas: capping the
            // measure keeps labels and their controls near each other.
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 660),
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
        button.layer?.backgroundColor = active ? theme.colors.bgSelected.cgColor : NSColor.clear.cgColor
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
        // Stamped here rather than in `update`, because this is where issues
        // actually reach the screen — every other entry point (tab switch,
        // theme change, Reload) lands here too.
        renderedIssues = configStore.issues
        renderedAgents = configStore.resolved.agents
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
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
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
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
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

    /// A titled settings section: an uppercase monospaced eyebrow and optional
    /// subtitle sit *above* a flat card, so the section name provides hierarchy
    /// instead of competing with the controls inside the box.
    private func makeSectionCard(title: String, subtitle: String? = nil) -> (NSView, NSStackView) {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let eyebrow = NSTextField(labelWithString: title)
        eyebrow.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: currentTheme.colors.textMuted,
                .kern: 1.3,
            ]
        )
        container.addArrangedSubview(eyebrow)

        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            subtitleLabel.textColor = currentTheme.colors.textMuted
            subtitleLabel.maximumNumberOfLines = 0
            container.addArrangedSubview(subtitleLabel)
            container.setCustomSpacing(3, after: eyebrow)
            subtitleLabel.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.backgroundColor = currentTheme.colors.bgPanel.cgColor
        card.layer?.borderColor = currentTheme.colors.borderSubtle.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return (container, stack)
    }

    private func addContentSubview(_ view: NSView, widthInset: CGFloat? = nil) {
        contentStack.addArrangedSubview(view)
        if let widthInset {
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: widthInset).isActive = true
        }
    }

    /// A System Settings-style form row: label on the left, control pinned to
    /// the trailing edge, so every card shares one alignment line.
    private func makeSettingRow(label: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12.5, weight: .regular)
        labelField.textColor = currentTheme.colors.textPrimary
        labelField.lineBreakMode = .byTruncatingTail
        labelField.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labelField)

        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(control)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            labelField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labelField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(
                greaterThanOrEqualTo: labelField.trailingAnchor,
                constant: 16
            ),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 2),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor, constant: 2),
        ])
        return row
    }

    /// Adds rows to a card stack separated by inset hairlines, each spanning
    /// the card's content width.
    private func addSettingRows(_ rows: [NSView], to stack: NSStackView) {
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = makeHairline()
                stack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(
                    equalTo: stack.widthAnchor,
                    constant: -28
                ).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
    }

    private func makeCheckbox(action: Selector, isOn: Bool, accessibilityLabel: String) -> NSButton {
        let box = NSButton(checkboxWithTitle: "", target: self, action: action)
        box.state = isOn ? .on : .off
        box.contentTintColor = currentTheme.colors.accent
        box.setAccessibilityLabel(accessibilityLabel)
        return box
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
        // A millisecond count is not a quantity anyone wants grouped, and the
        // separator is locale-dependent: with grouping on, a Swiss or German
        // locale renders 1500 as "1'500"/"1.500", which no longer round-trips
        // through `Int(_:)`.
        formatter.usesGroupingSeparator = false
        field.formatter = formatter
        return field
    }

    /// Reads a number the way the field displays it, so a value the formatter
    /// grouped or localized still parses instead of silently reverting.
    private func integerValue(of field: NSTextField) -> Int? {
        if let formatter = field.formatter as? NumberFormatter,
           let number = formatter.number(from: field.stringValue) {
            return number.intValue
        }
        return Int(field.stringValue)
    }

    /// A flat, theme-derived button: the stock Aqua bezel is the one control
    /// that ignores the app theme entirely, so buttons draw their own surface.
    private func makeActionButton(title: String, action: Selector) -> NSButton {
        let button = PaddedFlatButton(title: title, target: self, action: action)
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.borderWidth = 1
        button.layer?.backgroundColor = currentTheme.colors.bgOverlay.withAlphaComponent(0.6).cgColor
        button.layer?.borderColor = currentTheme.colors.borderStrong.withAlphaComponent(0.7).cgColor
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: currentTheme.colors.textPrimary,
            ]
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func makeHairline() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = currentTheme.colors.borderSubtle.withAlphaComponent(0.7).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func buildGeneralTab() {
        addTabHeader(
            title: "General",
            subtitle: "Theme, persistence, project roots, and keybinding behavior. Every setting here is stored in settings.json."
        )

        addConfigFileCard()

        let (appearanceCard, appearanceStack) = makeSectionCard(title: "Appearance")
        appearanceStack.spacing = 4

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
        popup.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let hideWindowBarBox = makeCheckbox(
            action: #selector(hideWindowBarChanged(_:)),
            isOn: settings.hideWindowBar,
            accessibilityLabel: "Hide window bar"
        )
        self.hideWindowBarButton = hideWindowBarBox
        let hideWindowBarRow = makeSettingRow(label: "Hide window bar", control: hideWindowBarBox)
        hideWindowBarRow.toolTip =
            "Hide the title bar and traffic-light controls so panes use the full window"

        addSettingRows(
            [
                makeSettingRow(label: "Theme", control: popup),
                hideWindowBarRow,
            ],
            to: appearanceStack
        )
        addContentSubview(appearanceCard, widthInset: -36)

        let (sessionCard, sessionStack) = makeSectionCard(title: "Session")
        sessionStack.spacing = 4
        let restoreBox = makeCheckbox(
            action: #selector(restoreSessionChanged(_:)),
            isOn: settings.restoreLastSession,
            accessibilityLabel: "Restore last session"
        )
        restoreSessionButton = restoreBox
        addSettingRows(
            [makeSettingRow(label: "Restore workspace from the previous launch", control: restoreBox)],
            to: sessionStack
        )
        addContentSubview(sessionCard, widthInset: -36)

        let (notificationCard, notificationStack) = makeSectionCard(
            title: "Notifications",
            subtitle: "Banners for panes that are not focused, named window ▸ pane."
        )
        notificationStack.spacing = 4

        let soundBox = makeCheckbox(
            action: #selector(notificationSoundChanged(_:)),
            isOn: settings.notificationSound,
            accessibilityLabel: "Play a sound"
        )
        notificationSoundButton = soundBox

        // Permission lives in System Settings, and macOS only ever prompts
        // once. When it has been refused the app can only say so and offer the
        // way back, which is exactly what this row does.
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = currentTheme.colors.textMuted
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        notificationStatusLabel = statusLabel
        statusRow.addArrangedSubview(statusLabel)

        let fixButton = makeActionButton(
            title: "Open System Settings",
            action: #selector(openNotificationSystemSettings)
        )
        fixButton.isHidden = true
        notificationFixButton = fixButton
        statusRow.addArrangedSubview(fixButton)

        addSettingRows(
            [
                makeSettingRow(label: "Play a sound", control: soundBox),
                statusRow,
            ],
            to: notificationStack
        )
        addContentSubview(notificationCard, widthInset: -36)
        refreshNotificationAuthorizationRow()

        let (projectCard, projectStack) = makeSectionCard(
            title: "Project Directories",
            subtitle: "Directories available to project-aware features."
        )
        projectStack.spacing = 4
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        projectDirectoriesStack = listStack
        projectStack.addArrangedSubview(listStack)
        listStack.widthAnchor.constraint(
            equalTo: projectStack.widthAnchor,
            constant: -28
        ).isActive = true
        rebuildProjectDirectoriesList()

        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.alignment = .centerY
        addRow.spacing = 8

        let input = makeTextField(value: "")
        input.placeholderString = "Folder path"
        input.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        input.target = self
        input.action = #selector(addProjectDirectory)
        input.cell?.sendsActionOnEndEditing = false
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        projectDirectoryInput = input
        addRow.addArrangedSubview(input)

        let browseButton = makeActionButton(title: "Browse…", action: #selector(browseProjectDirectory))
        addRow.addArrangedSubview(browseButton)

        let addButton = makeActionButton(title: "Add", action: #selector(addProjectDirectory))
        addRow.addArrangedSubview(addButton)

        projectStack.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: projectStack.widthAnchor, constant: -28).isActive = true
        input.heightAnchor.constraint(equalToConstant: 24).isActive = true

        addContentSubview(projectCard, widthInset: -36)

        let (keybindingCard, keybindingStack) = makeSectionCard(
            title: "Keybinding Behavior",
            subtitle: "Adjust prefix trigger and pane resize granularity."
        )
        keybindingStack.spacing = 4

        let prefixField = makeTextField(value: keybindingConfig.prefixKey)
        prefixField.alignment = .center
        prefixField.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        prefixField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        prefixField.target = self
        prefixField.action = #selector(prefixKeyCommitted(_:))
        prefixField.cell?.sendsActionOnEndEditing = true
        prefixKeyField = prefixField

        let timeoutField = makeNumberField(value: "\(keybindingConfig.prefixTimeoutMs)")
        timeoutField.alignment = .right
        timeoutField.widthAnchor.constraint(equalToConstant: 84).isActive = true
        timeoutField.target = self
        timeoutField.action = #selector(prefixTimeoutCommitted(_:))
        timeoutField.cell?.sendsActionOnEndEditing = true
        prefixTimeoutField = timeoutField

        let resizeField = makeNumberField(value: "\(Int(keybindingConfig.resizeTickPercent))")
        resizeField.alignment = .right
        resizeField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        resizeField.target = self
        resizeField.action = #selector(resizeStepCommitted(_:))
        resizeField.cell?.sendsActionOnEndEditing = true
        resizeStepField = resizeField

        addSettingRows(
            [
                makeSettingRow(label: "Prefix key", control: prefixField),
                makeSettingRow(label: "Prefix timeout (ms)", control: timeoutField),
                makeSettingRow(label: "Resize step (%)", control: resizeField),
            ],
            to: keybindingStack
        )

        addContentSubview(keybindingCard, widthInset: -36)
    }

    /// The file card is the bridge between the two ways to configure Soprano:
    /// it names the file the UI is editing, opens it, and reports anything
    /// wrong with it. Without this, a typo in the file would fail silently.
    private func addConfigFileCard() {
        let (card, stack) = makeSectionCard(
            title: "Configuration File",
            subtitle: "This screen edits \(configStore.displayPath). Hand edits apply as soon as you save — comments and key order are preserved."
        )

        for issue in configStore.issues {
            let row = makeIssueRow(issue)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(
            makeActionButton(title: "Open settings.json", action: #selector(openConfigFile))
        )
        buttonRow.addArrangedSubview(
            makeActionButton(title: "Reveal in Finder", action: #selector(revealConfigFile))
        )
        buttonRow.addArrangedSubview(
            makeActionButton(title: "Reload", action: #selector(reloadConfigFile))
        )
        stack.addArrangedSubview(buttonRow)

        addContentSubview(card, widthInset: -36)
    }

    private func makeIssueRow(_ issue: ConfigIssue) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.borderWidth = 1
        row.translatesAutoresizingMaskIntoConstraints = false

        let tint = issue.severity == .error
            ? currentTheme.colors.danger
            : currentTheme.colors.yellow
        row.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        row.layer?.borderColor = tint.withAlphaComponent(0.45).cgColor

        let location = issue.line.map { "Line \($0): " } ?? ""
        let label = NSTextField(wrappingLabelWithString: location + issue.message)
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = currentTheme.colors.textPrimary
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7),
        ])
        return row
    }

    @objc private func openConfigFile() {
        configStore.openInEditor()
    }

    @objc private func revealConfigFile() {
        configStore.revealInFinder()
    }

    @objc private func reloadConfigFile() {
        configStore.reloadFromDisk()
        rebuildCurrentTab()
    }

    private func rebuildProjectDirectoriesList() {
        guard let list = projectDirectoriesStack else { return }
        for row in list.arrangedSubviews {
            list.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        // The list shows what the FILE says, not the resolved result: a root
        // on an unmounted volume is dropped during resolution, and rendering
        // the resolved list would make "Remove" renumber onto the wrong entry
        // and a later write delete the missing root for good.
        let directories = configuredProjectDirectories
        if directories.isEmpty {
            let empty = NSTextField(labelWithString: "No project directories configured")
            empty.font = .systemFont(ofSize: 11, weight: .regular)
            empty.textColor = currentTheme.colors.textMuted
            list.addArrangedSubview(empty)
            return
        }

        for (index, directory) in directories.enumerated() {
            if index > 0 {
                let separator = makeHairline()
                list.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }

            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            var isDirectory: ObjCBool = false
            let isReachable = FileManager.default.fileExists(
                atPath: SopranoConfig.expandPath(directory),
                isDirectory: &isDirectory
            ) && isDirectory.boolValue

            let pathLabel = NSTextField(
                labelWithString: isReachable ? directory : "\(directory)  ·  not found"
            )
            pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            pathLabel.textColor = isReachable
                ? currentTheme.colors.textPrimary
                : currentTheme.colors.textMuted
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(pathLabel)

            let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeProjectDirectory(_:)))
            removeButton.isBordered = false
            removeButton.setButtonType(.momentaryPushIn)
            removeButton.attributedTitle = NSAttributedString(
                string: "Remove",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: currentTheme.colors.textMuted,
                ]
            )
            removeButton.tag = index
            removeButton.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(removeButton)

            list.addArrangedSubview(row)

            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: list.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 26),

                pathLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                pathLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -8),

                removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        }
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < AppTheme.allThemes.count else { return }
        let selectedTheme = AppTheme.allThemes[index]

        settings.themeId = selectedTheme.id
        configStore.write(selectedTheme.id, at: ["theme"])

        // The shared store observer normally applies the theme during write().
        // Standalone settings controllers used in tests and previews have no
        // observer, so retain the local fallback without applying it twice.
        if themeManager.currentTheme.id != selectedTheme.id {
            themeManager.setTheme(id: selectedTheme.id)
        }
        apply(theme: themeManager.currentTheme)
    }

    @objc private func restoreSessionChanged(_ sender: NSButton) {
        settings.restoreLastSession = sender.state == .on
        configStore.write(settings.restoreLastSession, at: ["restoreLastSession"])
    }

    @objc private func hideWindowBarChanged(_ sender: NSButton) {
        settings.hideWindowBar = sender.state == .on
        configStore.write(settings.hideWindowBar, at: ["hideWindowBar"])
    }

    @objc private func notificationSoundChanged(_ sender: NSButton) {
        settings.notificationSound = sender.state == .on
        configStore.write(settings.notificationSound, at: ["notifications", "sound"])
    }

    @objc private func openNotificationSystemSettings() {
        AgentNotificationManager.openSystemNotificationSettings()
    }

    /// Describes the current permission and offers the only remedy macOS allows.
    func refreshNotificationAuthorizationRow() {
        guard let notificationStatusLabel, let notificationFixButton else { return }

        let message: String
        let needsSystemSettings: Bool

        switch AgentNotificationManager.authorization {
        case .authorized:
            message = "macOS is allowed to show Soprano notifications."
            needsSystemSettings = false
        case .denied:
            message = "macOS is blocking Soprano notifications. Panes still show status "
                + "and an unread ring, but no banner appears."
            needsSystemSettings = true
        case .notDetermined:
            message = "macOS has not been asked yet. The prompt appears the first time "
                + "an unfocused pane wants you."
            needsSystemSettings = false
        case .unavailable:
            message = "Notifications need the packaged app; unbundled builds cannot post them."
            needsSystemSettings = false
        case nil:
            message = "Checking notification permission…"
            needsSystemSettings = false
        }

        notificationStatusLabel.stringValue = message
        notificationStatusLabel.textColor = needsSystemSettings
            ? currentTheme.colors.danger
            : currentTheme.colors.textMuted
        notificationFixButton.isHidden = !needsSystemSettings
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

        var directories = configuredProjectDirectories
        guard !directories.contains(where: { SopranoConfig.expandPath($0) == path }) else {
            projectDirectoryInput?.stringValue = ""
            return
        }

        directories.append(ConfigFile.abbreviatingHome(path))
        writeProjectDirectories(directories)
        projectDirectoryInput?.stringValue = ""
        rebuildProjectDirectoriesList()
    }

    @objc private func removeProjectDirectory(_ sender: NSButton) {
        var directories = configuredProjectDirectories
        guard sender.tag >= 0, sender.tag < directories.count else { return }
        directories.remove(at: sender.tag)
        writeProjectDirectories(directories)
        rebuildProjectDirectoriesList()
    }

    /// The roots exactly as `settings.json` lists them — unexpanded, including
    /// any that are not reachable right now.
    private var configuredProjectDirectories: [String] {
        configStore.config.projectDirectories ?? []
    }

    /// Written home-relative: this list is meant to be read and edited by hand
    /// in settings.json, and `/Users/you/git` reads worse than `~/git`.
    private func writeProjectDirectories(_ directories: [String]) {
        configStore.write(directories, at: ["projectDirectories"])
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
        configStore.write(value, at: ["keybindings", "prefixKey"])
    }

    @objc private func prefixTimeoutCommitted(_ sender: NSTextField) {
        guard let intValue = integerValue(of: sender) else {
            sender.stringValue = "\(keybindingConfig.prefixTimeoutMs)"
            return
        }
        let range = SopranoConfig.Limits.prefixTimeoutMs
        let clamped = min(max(range.lowerBound, intValue), range.upperBound)
        sender.stringValue = "\(clamped)"
        keybindingConfig.prefixTimeoutMs = clamped
        configStore.write(clamped, at: ["keybindings", "prefixTimeoutMs"])
    }

    @objc private func resizeStepCommitted(_ sender: NSTextField) {
        guard let intValue = integerValue(of: sender) else {
            sender.stringValue = "\(Int(keybindingConfig.resizeTickPercent))"
            return
        }
        let range = SopranoConfig.Limits.resizeTickPercent
        let clamped = min(max(range.lowerBound, intValue), range.upperBound)
        sender.stringValue = "\(clamped)"
        keybindingConfig.resizeTickPercent = Double(clamped)
        configStore.write(clamped, at: ["keybindings", "resizeTickPercent"])
    }

    private func buildKeyboardShortcutsTab() {
        addTabHeader(
            title: "Keyboard Shortcuts",
            subtitle: "The shortcuts in effect. Rebind any of them by id under \"keybindings.bindings\" in settings.json — for example \"\(exampleBindingId)\": \"\(exampleBindingChord)\" — or set one to null to turn it off."
        )

        let (fileCard, fileStack) = makeSectionCard(
            title: "Editing shortcuts",
            subtitle: "Shortcuts are configured in \(configStore.displayPath). Ids shown here are the keys to use."
        )
        fileStack.addArrangedSubview(
            makeActionButton(title: "Open settings.json", action: #selector(openConfigFile))
        )
        addContentSubview(fileCard, widthInset: -36)

        let groups: [(title: String, category: KeyBindingCategory)] = [
            ("Navigation", .navigation),
            ("Layout & Splits", .layout),
            ("Agent Launchers", .agents),
            ("General", .general),
        ]

        let customized = configStore.resolved.customizedBindingIds
        let disabledIds = configStore.resolved.disabledBindingIds

        for (groupTitle, category) in groups {
            let active = keybindingConfig.bindings.filter { $0.category == category }
            // Disabled bindings still belong on this list: a shortcut that is
            // missing because the file switched it off should be visibly off,
            // not simply absent.
            let disabled = DefaultKeybindings.config.bindings.filter {
                $0.category == category && disabledIds.contains($0.id)
            }
            let rows = active.map { ($0, false) } + disabled.map { ($0, true) }
            guard !rows.isEmpty else { continue }

            let (card, stack) = makeSectionCard(title: groupTitle)
            stack.spacing = 0

            for (index, entry) in rows.enumerated() {
                let (binding, isDisabled) = entry
                if index > 0 {
                    let separator = makeHairline()
                    stack.addArrangedSubview(separator)
                    separator.widthAnchor.constraint(
                        equalTo: stack.widthAnchor,
                        constant: -28
                    ).isActive = true
                }
                let row = makeShortcutRow(
                    action: binding.label,
                    description: "\(binding.id) · \(binding.description)",
                    keys: binding.defaultKeys,
                    isCustomized: customized.contains(binding.id),
                    isDisabled: isDisabled
                )
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
            }
            addContentSubview(card, widthInset: -36)
        }
    }

    /// A real, currently-bound action to show in the tab's instructions, so the
    /// example always names something the reader can find in the list below.
    private var exampleBindingId: String {
        keybindingConfig.bindings.first { $0.id == "split-vertical" }?.id
            ?? keybindingConfig.bindings.first?.id
            ?? "split-vertical"
    }

    private var exampleBindingChord: String {
        keybindingConfig.bindings.first { $0.id == exampleBindingId }
            .map { KeyChord(binding: $0).canonicalString }
            ?? "prefix+shift+|"
    }

    private func makeShortcutRow(
        action: String,
        description: String,
        keys: String,
        isCustomized: Bool = false,
        isDisabled: Bool = false
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let actionLabel = NSTextField(labelWithString: action)
        actionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        actionLabel.textColor = isDisabled
            ? currentTheme.colors.textMuted
            : currentTheme.colors.textPrimary
        actionLabel.lineBreakMode = .byTruncatingTail
        actionLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(actionLabel)

        let descriptionLabel = NSTextField(labelWithString: description)
        descriptionLabel.font = .systemFont(ofSize: 10, weight: .regular)
        descriptionLabel.textColor = currentTheme.colors.textMuted
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(descriptionLabel)

        let chips = makeKeycapChips(keys, isDisabled: isDisabled, isCustomized: isCustomized)
        row.addSubview(chips)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 46),

            actionLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            actionLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            actionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: chips.leadingAnchor,
                constant: -12
            ),

            descriptionLabel.leadingAnchor.constraint(equalTo: actionLabel.leadingAnchor),
            descriptionLabel.topAnchor.constraint(equalTo: actionLabel.bottomAnchor, constant: 2),
            descriptionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: chips.leadingAnchor,
                constant: -12
            ),
            descriptionLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -7),

            chips.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            chips.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    /// Renders a chord as individual keycaps: "Ctrl+Shift+H" becomes three
    /// caps, "Prefix → P" keeps the arrow between its two steps and tints the
    /// Prefix cap in the accent color, which is what marks a prefix chord —
    /// there is no separate mode badge. Falls back to one cap for chords whose
    /// key itself contains a separator ("⌘+ / ⌘=").
    private func makeKeycapChips(_ keys: String, isDisabled: Bool, isCustomized: Bool) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        if isDisabled {
            let off = NSTextField(labelWithString: "OFF")
            off.attributedStringValue = NSAttributedString(
                string: "OFF",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: currentTheme.colors.textMuted,
                    .kern: 0.6,
                ]
            )
            off.alignment = .center
            off.wantsLayer = true
            off.layer?.cornerRadius = 4
            off.layer?.backgroundColor = currentTheme.colors.gray.withAlphaComponent(0.18).cgColor
            off.translatesAutoresizingMaskIntoConstraints = false
            off.widthAnchor.constraint(
                equalToConstant: off.intrinsicContentSize.width + 12
            ).isActive = true
            off.heightAnchor.constraint(equalToConstant: 17).isActive = true
            stack.addArrangedSubview(off)
            return stack
        }

        if isCustomized {
            stack.toolTip = "Customized in settings.json"
        }

        let sequences = keys.components(separatedBy: " → ")
        for (sequenceIndex, sequence) in sequences.enumerated() {
            if sequenceIndex > 0 {
                let arrow = NSTextField(labelWithString: "→")
                arrow.font = .systemFont(ofSize: 10, weight: .medium)
                arrow.textColor = currentTheme.colors.textMuted
                stack.addArrangedSubview(arrow)
            }
            let parts = sequence.components(separatedBy: "+").filter { !$0.isEmpty }
            let caps = parts.isEmpty || parts.joined(separator: "+") != sequence
                ? [sequence]
                : parts
            for cap in caps {
                stack.addArrangedSubview(makeKeycap(cap, isCustomized: isCustomized))
            }
        }
        return stack
    }

    private func makeKeycap(_ text: String, isCustomized: Bool) -> NSView {
        // The prefix step is the one distinction worth color: an accent-tinted
        // first cap says "wait for the prefix" without a separate badge.
        let isPrefixCap = text == "Prefix"
        let highlighted = isCustomized || isPrefixCap

        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = highlighted
            ? currentTheme.colors.accent
            : currentTheme.colors.textPrimary
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.layer?.borderWidth = 1
        label.layer?.backgroundColor = isPrefixCap
            ? currentTheme.colors.accent.withAlphaComponent(0.10).cgColor
            : currentTheme.colors.bgOverlay.withAlphaComponent(0.7).cgColor
        label.layer?.borderColor = highlighted
            ? currentTheme.colors.accent.withAlphaComponent(0.5).cgColor
            : currentTheme.colors.borderStrong.withAlphaComponent(0.8).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(
                equalToConstant: max(20, label.intrinsicContentSize.width + 12)
            ),
            label.heightAnchor.constraint(equalToConstant: 20),
        ])
        return label
    }

    private func buildAgentProfilesTab() {
        addTabHeader(
            title: "Agent Profiles",
            subtitle: "The agents Soprano can launch. Add your own — or patch a built-in — under \"agents\" in settings.json."
        )

        let (fileCard, fileStack) = makeSectionCard(
            title: "Adding an agent",
            subtitle: "{ \"id\": \"aider\", \"name\": \"Aider\", \"command\": \"aider\", \"launchKey\": \"cmd+4\" }\nReusing a built-in id patches that profile instead of creating a new one."
        )
        fileStack.addArrangedSubview(
            makeActionButton(title: "Open settings.json", action: #selector(openConfigFile))
        )
        addContentSubview(fileCard, widthInset: -36)

        let gridStack = NSStackView()
        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = 10
        gridStack.translatesAutoresizingMaskIntoConstraints = false

        var currentRow: NSStackView?
        for (index, profile) in AgentCatalog.all.enumerated() {
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
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
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

        if configStore.resolved.configuredAgentIds.contains(profile.id) {
            let badge = NSTextField(labelWithString: "settings.json")
            badge.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
            badge.textColor = currentTheme.colors.accent
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 5
            badge.layer?.backgroundColor = currentTheme.colors.accent.withAlphaComponent(0.14).cgColor
            titleRow.addArrangedSubview(badge)
        }

        stack.addArrangedSubview(titleRow)

        let description = NSTextField(wrappingLabelWithString: profile.description)
        description.font = .systemFont(ofSize: 11, weight: .regular)
        description.textColor = currentTheme.colors.textMuted
        description.maximumNumberOfLines = 0
        stack.addArrangedSubview(description)

        let command = NSTextField(labelWithString: "$ \(profile.command) \(profile.args.joined(separator: " "))")
        command.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        command.textColor = currentTheme.colors.textPrimary
        command.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(command)

        let ready = profile.patterns?.ready?.joined(separator: ", ") ?? "-"
        let error = profile.patterns?.error?.joined(separator: ", ") ?? "-"
        let patterns = NSTextField(wrappingLabelWithString: "Patterns\nReady: \(ready)\nError: \(error)")
        patterns.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
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

        let version = NSTextField(labelWithString: "Version: \(AppVersion.current)")
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
        quickRefStack.spacing = 2
        let rows = quickReferenceBindings().map { key, label in
            makeSettingRow(
                label: label,
                control: makeKeycapChips(key, isDisabled: false, isCustomized: false)
            )
        }
        addSettingRows(rows, to: quickRefStack)
        addContentSubview(quickRefCard, widthInset: -36)
    }

    private func quickReferenceBindings() -> [(String, String)] {
        let preferredIds = [
            "command-palette",
            "find-window",
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

/// A borderless button whose intrinsic size includes horizontal padding, so a
/// flat layer-drawn surface still gives the title room to breathe. The cell's
/// default momentary highlight dims the title while pressed.
private final class PaddedFlatButton: NSButton {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 20
        return size
    }
}
