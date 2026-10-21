import AppKit

private enum SettingsTab: Int, CaseIterable {
    case general
    case keyboardShortcuts
    case agentProfiles
    case accounts
    case about

    var title: String {
        switch self {
        case .general: return "General"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .agentProfiles: return "Agent Profiles"
        case .accounts: return "Accounts"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .keyboardShortcuts: return "keyboard"
        case .agentProfiles: return "cpu"
        case .accounts: return "person.2"
        case .about: return "info.circle"
        }
    }
}

/// Folio settings metrics (direction §8, `soprano-settings.html`).
private enum SettingsLayout {
    static let navWidth: CGFloat = 200
    static let navItemHeight: CGFloat = 30
    /// The page starts this far from the nav.
    static let pageLeading: CGFloat = 48
    static let pageTrailing: CGFloat = 24
    /// Eyebrow and note column beside each card.
    static let marginColumn: CGFloat = 232
    static let columnGap: CGFloat = 40
    static let cardColumn: CGFloat = 680
    static let pageWidth = marginColumn + columnGap + cardColumn
    /// Narrower than this, each margin column moves above its card.
    static let sideBySideMinimumWidth = marginColumn + columnGap + 440
    static let sectionSpacing: CGFloat = 28
    static let rowHeight: CGFloat = 36
    static let tallRowHeight: CGFloat = 44
    static let rowInset: CGFloat = 12
    static let rowPadding: CGFloat = 8
}

final class SettingsViewController: NSViewController, NSTextFieldDelegate {
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
    private var sidebarRule: ChromeRuleView!
    private var tabStack: NSStackView!
    private var contentBackgroundView: NSView!
    private var scrollView: NSScrollView!
    private var scrollDocumentView: NSView!
    private var contentStack: NSStackView!
    private var tabButtons: [SettingsTab: SettingsTabButton] = [:]
    /// The current tab's sections, so a width change can move every margin
    /// column above its card at once.
    private var sections: [SettingsSectionView] = []
    private var sectionsAreStacked = false

    private var notificationStatusIcon: NSImageView?
    private var notificationStatusTitle: NSTextField?
    private var notificationStatusLabel: NSTextField?
    private var notificationFixButton: NSButton?
    private var projectDirectoriesStack: NSStackView?
    private var projectDirectoryInput: NSTextField?
    /// Handlers for the Accounts tab's buttons, keyed by button tag: each row
    /// acts on its own list and account, which a shared selector cannot carry.
    /// Refilled on every rebuild of that tab.
    private var accountActions: [Int: () -> Void] = [:]
    private static let accountsObserverId = "SettingsViewController.accounts"

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
        tabStack.spacing = 2
        tabStack.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 16, right: 10)
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(tabStack)

        for tab in SettingsTab.allCases {
            let button = makeTabButton(for: tab)
            tabButtons[tab] = button
            tabStack.addArrangedSubview(button)
        }

        sidebarRule = ChromeRuleView(
            axis: .vertical,
            color: currentTheme.colors.borderSubtle
        )
        sidebar.addSubview(sidebarRule)

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
        contentStack.spacing = SettingsLayout.sectionSpacing
        contentStack.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 40, right: 0)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollDocumentView.addSubview(contentStack)

        let fillDocumentWidth = contentStack.widthAnchor.constraint(
            equalTo: scrollDocumentView.widthAnchor,
            constant: -(SettingsLayout.pageLeading + SettingsLayout.pageTrailing)
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
            sidebar.widthAnchor.constraint(equalToConstant: SettingsLayout.navWidth),

            contentBackgroundView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentBackgroundView.trailingAnchor.constraint(equalTo: rootContainer.trailingAnchor),
            contentBackgroundView.topAnchor.constraint(equalTo: rootContainer.topAnchor),
            contentBackgroundView.bottomAnchor.constraint(equalTo: rootContainer.bottomAnchor),

            tabStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            tabStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabStack.topAnchor.constraint(equalTo: sidebar.topAnchor),

            sidebarRule.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarRule.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarRule.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarRule.widthAnchor.constraint(equalToConstant: Chrome.hairline),

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

            // The page hangs from the nav at a fixed distance, the way a
            // printed page hangs from its spine, rather than floating centred.
            contentStack.leadingAnchor.constraint(
                equalTo: scrollDocumentView.leadingAnchor,
                constant: SettingsLayout.pageLeading
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: scrollDocumentView.trailingAnchor,
                constant: -SettingsLayout.pageTrailing
            ),
            // A settings form is a reading column, not a canvas: capping the
            // measure keeps labels and their controls near each other.
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsLayout.pageWidth),
            fillDocumentWidth,
            contentStack.topAnchor.constraint(equalTo: scrollDocumentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollDocumentView.bottomAnchor),
        ])

        view = rootContainer
        rebuildCurrentTab()
        apply(theme: currentTheme)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The controller keeps the handler by id; capturing weakly lets this
        // screen go away without unregistering, which a deinit could not do.
        AccountsController.shared.addObserver(id: Self.accountsObserverId) { [weak self] _ in
            guard let self else { return }
            // A snapshot can change from inside a button's own action; let
            // that event finish before the button is torn down.
            DispatchQueue.main.async { [weak self] in
                self?.accountsSnapshotDidChange()
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateSectionArrangement()
    }

    /// Margin columns sit beside their cards while the page is wide enough
    /// for both, and move above them once it is not. Measured from this
    /// view's own bounds: in `viewDidLayout` the page itself may not be laid
    /// out yet.
    private func updateSectionArrangement() {
        let pageWidth = min(
            SettingsLayout.pageWidth,
            view.bounds.width - SettingsLayout.navWidth - SettingsLayout.pageLeading - SettingsLayout.pageTrailing
        )
        guard pageWidth > 0 else { return }
        let stacked = pageWidth < SettingsLayout.sideBySideMinimumWidth
        guard stacked != sectionsAreStacked else { return }
        sectionsAreStacked = stacked
        for section in sections {
            section.isStacked = stacked
        }
    }

    private func accountsSnapshotDidChange() {
        guard isViewLoaded, currentTab == .accounts else { return }
        // Usage refreshes arrive while the user reads further down; keep
        // their place instead of jumping back to the top.
        let clipView = scrollView.contentView
        let origin = clipView.bounds.origin
        rebuildCurrentTab()
        let restored = clipView.constrainBoundsRect(
            NSRect(origin: origin, size: clipView.bounds.size)
        ).origin
        clipView.scroll(to: restored)
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Opens the Accounts tab, e.g. from the status bar's usage readout.
    func showAccountsTab() {
        switchTab(to: .accounts)
    }

    func apply(theme: AppTheme) {
        currentTheme = theme
        guard isViewLoaded else { return }

        view.layer?.backgroundColor = theme.colors.bgBase.cgColor
        sidebar.layer?.backgroundColor = theme.colors.bgPanel.cgColor
        contentBackgroundView.layer?.backgroundColor = theme.colors.bgBase.cgColor
        sidebarRule.color = theme.colors.borderSubtle

        for (tab, button) in tabButtons {
            button.apply(theme: theme)
            button.isActive = tab == currentTab
        }

        rebuildCurrentTab()
    }

    private func makeTabButton(for tab: SettingsTab) -> SettingsTabButton {
        let button = SettingsTabButton(
            tab: tab,
            theme: currentTheme,
            target: self,
            action: #selector(tabClicked(_:))
        )
        button.tag = tab.rawValue
        button.isActive = tab == currentTab

        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: SettingsLayout.navItemHeight),
            button.widthAnchor.constraint(equalToConstant: SettingsLayout.navWidth - 20),
        ])
        return button
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let tab = SettingsTab(rawValue: sender.tag) else { return }
        switchTab(to: tab)
    }

    private func switchTab(to tab: SettingsTab) {
        if isViewLoaded {
            view.window?.endEditing(for: nil)
        }
        currentTab = tab
        for (item, button) in tabButtons {
            button.isActive = item == tab
        }
        rebuildCurrentTab()
        if tab == .accounts {
            // Throttled by the controller, so flipping tabs does not refetch.
            AccountsController.shared.refresh()
        }
    }

    private func clearContent() {
        for subview in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        sections.removeAll()
        notificationStatusIcon = nil
        notificationStatusTitle = nil
        notificationStatusLabel = nil
        notificationFixButton = nil
        projectDirectoriesStack = nil
        projectDirectoryInput = nil
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
        case .accounts:
            buildAccountsTab()
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
        updateSectionArrangement()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Page building blocks

    /// The page head: a New York page title over a muted line saying what
    /// the tab is for.
    private func addPageHeader(title: String, subtitle: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.setChromeText(title, font: ChromeFont.screen, color: currentTheme.colors.textPrimary)

        let subtitleLabel = makeWrappingLabel(subtitle, font: ChromeFont.row, color: currentTheme.colors.textMuted)

        let head = NSStackView(views: [titleLabel, subtitleLabel])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 4
        head.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.widthAnchor.constraint(equalTo: head.widthAnchor).isActive = true
        addContentSubview(head)
    }

    private func addContentSubview(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    /// A section: an eyebrow and optional note in the margin column, beside
    /// (or, on a narrow page, above) a card. Returns the card's row stack.
    @discardableResult
    private func addSection(title: String?, note: NSAttributedString? = nil) -> NSStackView {
        let card = NSView()
        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer?.cornerRadius = Chrome.Radius.card
        card.layer?.borderWidth = Chrome.hairline
        card.layer?.backgroundColor = currentTheme.colors.raised.cgColor
        card.layer?.borderColor = currentTheme.colors.borderSubtle.cgColor

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rows.topAnchor.constraint(equalTo: card.topAnchor),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        addSection(title: title, note: note, content: card)
        return rows
    }

    private func addSection(title: String?, note: NSAttributedString?, content: NSView) {
        var sideViews: [NSView] = []
        if let title {
            sideViews.append(ChromeEyebrowView(title: title, theme: currentTheme))
        }
        if let note {
            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = note
            label.maximumNumberOfLines = 0
            label.isSelectable = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            sideViews.append(label)
        }
        let section = SettingsSectionView(side: sideViews, content: content, isStacked: sectionsAreStacked)
        sections.append(section)
        addContentSubview(section)
    }

    /// A margin note: 11 pt muted text on a 16 pt line, with optional
    /// inline mono runs (paths) in ink.
    private func note(_ parts: [(String, isMono: Bool)]) -> NSAttributedString {
        let colors = currentTheme.colors
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 16
        paragraph.maximumLineHeight = 16
        let text = NSMutableAttributedString()
        for (string, isMono) in parts {
            text.append(NSAttributedString(string: string, attributes: [
                .font: isMono ? ChromeFont.monoSmall : ChromeFont.meta,
                .foregroundColor: isMono ? colors.textPrimary : colors.textMuted,
                .paragraphStyle: paragraph,
            ]))
        }
        return text
    }

    private func note(_ string: String) -> NSAttributedString {
        note([(string, isMono: false)])
    }

    /// One form row: `leading` at the left, `trailing` pinned to the card's
    /// right edge. Rows after the first carry a hairline inset from the left.
    private func makeFormRow(
        leading: NSView,
        trailing: NSView? = nil,
        minHeight: CGFloat = SettingsLayout.rowHeight,
        leadingFills: Bool = false
    ) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        leading.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(leading)

        let inset = SettingsLayout.rowInset
        let padding = SettingsLayout.rowPadding
        var constraints = [
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: inset),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leading.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: padding),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: leading.bottomAnchor, constant: padding),
        ]
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addSubview(trailing)
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -inset),
                trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                trailing.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: padding),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: trailing.bottomAnchor, constant: padding),
                leadingFills
                    ? trailing.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 16)
                    : trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 16),
            ]
        } else if leadingFills {
            constraints.append(leading.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -inset))
        } else {
            constraints.append(leading.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -inset))
        }
        NSLayoutConstraint.activate(constraints)

        // Rows hug their content so the trailing flexible space, not a row,
        // absorbs the slack on tabs shorter than the viewport.
        let hugContent = row.heightAnchor.constraint(equalToConstant: minHeight)
        hugContent.priority = .defaultLow
        hugContent.isActive = true
        return row
    }

    /// A labeled control row: 13 pt ink label, control on the right edge.
    private func makeSettingRow(label: String, control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setChromeText(label, font: ChromeFont.row, color: currentTheme.colors.textPrimary)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return makeFormRow(leading: labelField, trailing: control)
    }

    /// Appends `row` to a card's row stack, ruled off from the row above it.
    private func addRow(_ row: NSView, to stack: NSStackView) {
        if !stack.arrangedSubviews.isEmpty {
            let rule = ChromeRuleView(axis: .horizontal, color: currentTheme.colors.borderSubtle)
            rule.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(rule)
            NSLayoutConstraint.activate([
                rule.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SettingsLayout.rowInset),
                rule.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                rule.topAnchor.constraint(equalTo: row.topAnchor),
                rule.heightAnchor.constraint(equalToConstant: Chrome.hairline),
            ])
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addRows(_ rows: [NSView], to stack: NSStackView) {
        for row in rows {
            addRow(row, to: stack)
        }
    }

    /// An SF Symbol in front of a row's text (`.lead > .icon`): 14 pt, muted.
    private func makeIcon(_ symbolName: String, color: NSColor? = nil) -> NSImageView {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        let icon = NSImageView()
        icon.image = image
        icon.contentTintColor = color ?? currentTheme.colors.textMuted
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
        ])
        return icon
    }

    /// Icon then content, 10 pt apart (`.lead`).
    private func makeLead(icon: NSView, content: NSView) -> NSStackView {
        let lead = NSStackView(views: [icon, content])
        lead.orientation = .horizontal
        lead.alignment = .centerY
        lead.spacing = 10
        lead.setHuggingPriority(.defaultLow, for: .horizontal)
        lead.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return lead
    }

    private func makeMonoLabel(_ text: String, color: NSColor? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = ChromeFont.mono
        label.textColor = color ?? currentTheme.colors.textPrimary
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeWrappingLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeButtonGroup(_ buttons: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let group = NSStackView(views: buttons)
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = spacing
        group.setHuggingPriority(.required, for: .horizontal)
        return group
    }

    private func makeSwitch(action: Selector, isOn: Bool, accessibilityLabel: String) -> ChromeSwitch {
        let control = ChromeSwitch(isOn: isOn, theme: currentTheme, target: self, action: action)
        control.setAccessibilityLabel(accessibilityLabel)
        return control
    }

    /// A text field on a Folio field surface. The surface's edge follows
    /// editing focus through the delegate callbacks below.
    private func makeFieldSurface(
        _ field: NSTextField,
        width: CGFloat? = nil,
        unit: String? = nil
    ) -> ChromeFieldView {
        let surface = ChromeFieldView(theme: currentTheme)
        ChromeFieldView.styleEmbedded(field, colors: currentTheme.colors, font: ChromeFont.label)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(field)

        var constraints = [
            surface.heightAnchor.constraint(equalToConstant: Chrome.controlHeight),
            field.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
        ]
        if let unit {
            let unitLabel = NSTextField(labelWithString: unit)
            unitLabel.setChromeText(unit, font: ChromeFont.label, color: currentTheme.colors.textMuted)
            unitLabel.translatesAutoresizingMaskIntoConstraints = false
            unitLabel.setContentHuggingPriority(.required, for: .horizontal)
            unitLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            surface.addSubview(unitLabel)
            constraints += [
                unitLabel.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
                unitLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8),
                unitLabel.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
            ]
        } else {
            constraints.append(field.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8))
        }
        if let width {
            constraints.append(surface.widthAnchor.constraint(equalToConstant: width))
        }
        NSLayoutConstraint.activate(constraints)
        return surface
    }

    private func makeTextField(value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.font = ChromeFont.label
        field.textColor = currentTheme.colors.textPrimary
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeNumberField(value: String) -> NSTextField {
        let field = makeTextField(value: value)
        field.font = ChromeFont.sans(size: 12, tabular: true)
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

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        (field.superview as? ChromeFieldView)?.isFocused = true
        ChromeFieldView.styleEditor(of: field, colors: currentTheme.colors)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        (field.superview as? ChromeFieldView)?.isFocused = false
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

    private func makeActionButton(
        title: String,
        action: Selector,
        kind: ChromeButton.Kind = .standard
    ) -> NSButton {
        ChromeButton(title: title, theme: currentTheme, kind: kind, target: self, action: action)
    }

    /// A tinted notice inside a card: a config problem or a failed account
    /// action. The status wash carries the severity; there is no box.
    private func makeNotice(_ message: String, isError: Bool, button: NSButton? = nil) -> NSView {
        let colors = currentTheme.colors
        let notice = NSView()
        notice.wantsLayer = true
        notice.layer?.cornerRadius = Chrome.Radius.control
        notice.layer?.backgroundColor = (isError ? colors.errorWash : colors.needsInputWash).cgColor
        notice.translatesAutoresizingMaskIntoConstraints = false

        let mark = ChromeStatusMark(
            shape: isError ? .diamond : .dot,
            color: isError ? colors.danger : colors.yellow
        )
        notice.addSubview(mark)

        let label = makeWrappingLabel(message, font: ChromeFont.label, color: colors.textPrimary)
        label.translatesAutoresizingMaskIntoConstraints = false
        notice.addSubview(label)

        var constraints = [
            mark.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: 10),
            mark.topAnchor.constraint(equalTo: label.topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: notice.topAnchor, constant: 7),
            notice.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor, constant: 7),
        ]
        if let button {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            notice.addSubview(button)
            constraints += [
                button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
                button.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -6),
                button.centerYAnchor.constraint(equalTo: notice.centerYAnchor),
                button.topAnchor.constraint(greaterThanOrEqualTo: notice.topAnchor, constant: 4),
                notice.bottomAnchor.constraint(greaterThanOrEqualTo: button.bottomAnchor, constant: 4),
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -10))
        }
        NSLayoutConstraint.activate(constraints)
        let hugContent = notice.heightAnchor.constraint(equalToConstant: 28)
        hugContent.priority = .defaultLow
        hugContent.isActive = true
        return notice
    }

    // MARK: - General

    private func buildGeneralTab() {
        addPageHeader(
            title: "General",
            subtitle: "Theme, persistence, project roots, and keybinding behavior. Every setting here is stored in settings.json."
        )

        addConfigFileSection()
        addAppearanceSection()

        let sessionRows = addSection(title: "Session")
        addRow(
            makeSettingRow(
                label: "Restore workspace from the previous launch",
                control: makeSwitch(
                    action: #selector(restoreSessionChanged(_:)),
                    isOn: settings.restoreLastSession,
                    accessibilityLabel: "Restore last session"
                )
            ),
            to: sessionRows
        )

        addNotificationsSection()
        addProjectDirectoriesSection()
        addKeybindingBehaviorSection()
    }

    /// The file section is the bridge between the two ways to configure
    /// Soprano: it names the file the UI is editing, opens it, and reports
    /// anything wrong with it. Without this, a typo in the file would fail
    /// silently.
    private func addConfigFileSection() {
        let rows = addSection(
            title: "Configuration File",
            note: note([
                ("This screen edits ", isMono: false),
                (configStore.displayPath, isMono: true),
                (". Hand edits apply as soon as you save — comments and key order are preserved.", isMono: false),
            ])
        )

        for issue in configStore.issues {
            let location = issue.line.map { "Line \($0): " } ?? ""
            let notice = makeNotice(location + issue.message, isError: issue.severity == .error)
            addRow(makeFormRow(leading: notice, leadingFills: true), to: rows)
        }

        let buttons = makeButtonGroup([
            makeActionButton(title: "Open settings.json", action: #selector(openConfigFile)),
            makeActionButton(title: "Reveal in Finder", action: #selector(revealConfigFile)),
            makeActionButton(title: "Reload", action: #selector(reloadConfigFile)),
        ])
        let lead = makeLead(icon: makeIcon("doc.text"), content: makeMonoLabel(configStore.displayPath))
        addRow(
            makeFormRow(
                leading: lead,
                trailing: buttons,
                minHeight: SettingsLayout.tallRowHeight,
                leadingFills: true
            ),
            to: rows
        )
    }

    private func addAppearanceSection() {
        let rows = addSection(title: "Appearance")

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.target = self
        popup.action = #selector(themeChanged(_:))
        popup.isBordered = false
        popup.font = ChromeFont.label
        popup.removeAllItems()
        popup.addItems(withTitles: AppTheme.options.map(\.name))
        if let selectedIndex = AppTheme.options.firstIndex(where: { $0.id == settings.themeId }) {
            popup.selectItem(at: selectedIndex)
        }
        popup.setAccessibilityLabel("Theme")
        let select = ChromeFieldView(theme: currentTheme)
        popup.translatesAutoresizingMaskIntoConstraints = false
        select.addSubview(popup)
        NSLayoutConstraint.activate([
            select.widthAnchor.constraint(equalToConstant: 190),
            select.heightAnchor.constraint(equalToConstant: Chrome.controlHeight),
            popup.leadingAnchor.constraint(equalTo: select.leadingAnchor, constant: 6),
            popup.trailingAnchor.constraint(equalTo: select.trailingAnchor, constant: -4),
            popup.centerYAnchor.constraint(equalTo: select.centerYAnchor),
        ])

        let appearances = AppearancePreference.allCases
        let appearanceControl = SettingsSegmentedControl(
            items: appearances.map { ($0.title, $0.symbolName) },
            selectedSegment: appearances.firstIndex(of: settings.appearance) ?? 0,
            theme: currentTheme,
            target: self,
            action: #selector(appearanceChanged(_:))
        )
        appearanceControl.setAccessibilityLabel("Appearance")

        let hideWindowBarRow = makeSettingRow(
            label: "Hide window bar",
            control: makeSwitch(
                action: #selector(hideWindowBarChanged(_:)),
                isOn: settings.hideWindowBar,
                accessibilityLabel: "Hide window bar"
            )
        )
        hideWindowBarRow.toolTip =
            "Hide the title bar and traffic-light controls so panes use the full window"

        let hideWindowTabsRow = makeSettingRow(
            label: "Hide window tabs",
            control: makeSwitch(
                action: #selector(hideWindowTabsChanged(_:)),
                isOn: settings.hideWindowTabs,
                accessibilityLabel: "Hide window tabs"
            )
        )
        hideWindowTabsRow.toolTip =
            "Hide the numbered window tabs; the tab row moves up. Switch windows from the sidebar, ⌃1…⌃9, or ⌘F"

        let uptimeRow = makeSettingRow(
            label: "Show uptime in status bar",
            control: makeSwitch(
                action: #selector(statusBarUptimeChanged(_:)),
                isOn: settings.statusBarUptime,
                accessibilityLabel: "Show uptime in status bar"
            )
        )

        addRows(
            [
                makeSettingRow(label: "Theme", control: select),
                makeSettingRow(label: "Appearance", control: appearanceControl),
                hideWindowBarRow,
                hideWindowTabsRow,
                uptimeRow,
            ],
            to: rows
        )
    }

    private func addNotificationsSection() {
        let rows = addSection(
            title: "Notifications",
            note: note("Banners for panes that are not focused, named window ▸ pane.")
        )

        let soundRow = makeSettingRow(
            label: "Play a sound",
            control: makeSwitch(
                action: #selector(notificationSoundChanged(_:)),
                isOn: settings.notificationSound,
                accessibilityLabel: "Play a sound"
            )
        )

        // Permission lives in System Settings, and macOS only ever prompts
        // once. The row says where it stands and offers the way there.
        let icon = makeIcon("checkmark.circle")
        notificationStatusIcon = icon

        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        notificationStatusTitle = title

        let message = makeWrappingLabel("", font: ChromeFont.meta, color: currentTheme.colors.textMuted)
        notificationStatusLabel = message

        let text = NSStackView(views: [title, message])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        message.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true

        let fixButton = makeActionButton(
            title: "Open System Settings",
            action: #selector(openNotificationSystemSettings)
        )
        notificationFixButton = fixButton

        let statusRow = makeFormRow(
            leading: makeLead(icon: icon, content: text),
            trailing: fixButton,
            minHeight: SettingsLayout.tallRowHeight,
            leadingFills: true
        )

        addRows([soundRow, statusRow], to: rows)
        refreshNotificationAuthorizationRow()
    }

    private func addProjectDirectoriesSection() {
        let rows = addSection(
            title: "Project Directories",
            note: note("Directories available to project-aware features.")
        )

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        projectDirectoriesStack = listStack
        rows.addArrangedSubview(listStack)
        listStack.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        rebuildProjectDirectoriesList()

        let input = makeTextField(value: "")
        input.placeholderAttributedString = ChromeText.attributed(
            "Folder path",
            font: ChromeFont.label,
            color: currentTheme.colors.textMuted
        )
        input.target = self
        input.action = #selector(addProjectDirectory)
        input.cell?.sendsActionOnEndEditing = false
        projectDirectoryInput = input
        let inputSurface = makeFieldSurface(input)
        inputSurface.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let addRowContent = NSStackView(views: [
            inputSurface,
            makeActionButton(title: "Browse…", action: #selector(browseProjectDirectory)),
            makeActionButton(title: "Add", action: #selector(addProjectDirectory), kind: .ink),
        ])
        addRowContent.orientation = .horizontal
        addRowContent.alignment = .centerY
        addRowContent.spacing = 8

        addRow(
            makeFormRow(leading: addRowContent, minHeight: SettingsLayout.tallRowHeight, leadingFills: true),
            to: rows
        )
    }

    private func addKeybindingBehaviorSection() {
        let rows = addSection(
            title: "Keybinding Behavior",
            note: note("Adjust prefix trigger and pane resize granularity.")
        )

        let prefixControl = SettingsPrefixKeyControl(
            key: keybindingConfig.prefixKey,
            theme: currentTheme,
            target: self,
            action: #selector(prefixKeyRecorded(_:))
        )

        let timeoutField = makeNumberField(value: "\(keybindingConfig.prefixTimeoutMs)")
        timeoutField.alignment = .right
        timeoutField.target = self
        timeoutField.action = #selector(prefixTimeoutCommitted(_:))
        timeoutField.cell?.sendsActionOnEndEditing = true
        timeoutField.setAccessibilityLabel("Prefix timeout in milliseconds")

        let resizeField = makeNumberField(value: "\(Int(keybindingConfig.resizeTickPercent))")
        resizeField.alignment = .right
        resizeField.target = self
        resizeField.action = #selector(resizeStepCommitted(_:))
        resizeField.cell?.sendsActionOnEndEditing = true
        resizeField.setAccessibilityLabel("Resize step in percent")

        addRows(
            [
                makeSettingRow(label: "Prefix key", control: prefixControl),
                makeSettingRow(
                    label: "Prefix timeout",
                    control: makeFieldSurface(timeoutField, width: 84, unit: "ms")
                ),
                makeSettingRow(
                    label: "Resize step",
                    control: makeFieldSurface(resizeField, width: 56, unit: "%")
                ),
            ],
            to: rows
        )
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
            empty.setChromeText(
                "No project directories configured",
                font: ChromeFont.row,
                color: currentTheme.colors.textMuted
            )
            addRow(makeFormRow(leading: empty), to: list)
            return
        }

        for (index, directory) in directories.enumerated() {
            var isDirectory: ObjCBool = false
            let isReachable = FileManager.default.fileExists(
                atPath: SopranoConfig.expandPath(directory),
                isDirectory: &isDirectory
            ) && isDirectory.boolValue

            let pathLabel = makeMonoLabel(
                isReachable ? directory : "\(directory)  ·  not found",
                color: isReachable ? currentTheme.colors.textPrimary : currentTheme.colors.textMuted
            )

            let removeButton = makeActionButton(
                title: "Remove",
                action: #selector(removeProjectDirectory(_:))
            )
            removeButton.tag = index

            addRow(
                makeFormRow(
                    leading: makeLead(icon: makeIcon("folder"), content: pathLabel),
                    trailing: removeButton,
                    leadingFills: true
                ),
                to: list
            )
        }
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < AppTheme.options.count else { return }
        let option = AppTheme.options[index]

        settings.themeId = option.id
        configStore.write(option.id, at: ["theme"])

        // The shared store observer normally applies the theme during write().
        // Standalone settings controllers used in tests and previews have no
        // observer, so retain the local fallback without applying it twice.
        if themeManager.themeId != option.id {
            themeManager.setTheme(id: option.id)
        }
        apply(theme: themeManager.currentTheme)
    }

    @objc private func appearanceChanged(_ sender: SettingsSegmentedControl) {
        let options = AppearancePreference.allCases
        guard options.indices.contains(sender.selectedSegment) else { return }
        let preference = options[sender.selectedSegment]

        settings.appearance = preference
        configStore.write(preference.rawValue, at: ["appearance"])

        // Same fallback as `themeChanged`: the store observer normally does it.
        if themeManager.appearance != preference {
            themeManager.setAppearance(preference)
        }
        apply(theme: themeManager.currentTheme)
    }

    @objc private func restoreSessionChanged(_ sender: ChromeSwitch) {
        settings.restoreLastSession = sender.state == .on
        configStore.write(settings.restoreLastSession, at: ["restoreLastSession"])
    }

    @objc private func hideWindowBarChanged(_ sender: ChromeSwitch) {
        settings.hideWindowBar = sender.state == .on
        configStore.write(settings.hideWindowBar, at: ["hideWindowBar"])
    }

    @objc private func hideWindowTabsChanged(_ sender: ChromeSwitch) {
        settings.hideWindowTabs = sender.state == .on
        configStore.write(settings.hideWindowTabs, at: ["hideWindowTabs"])
    }

    @objc private func statusBarUptimeChanged(_ sender: ChromeSwitch) {
        settings.statusBarUptime = sender.state == .on
        configStore.write(settings.statusBarUptime, at: ["statusBar", "uptime"])
    }

    @objc private func notificationSoundChanged(_ sender: ChromeSwitch) {
        settings.notificationSound = sender.state == .on
        configStore.write(settings.notificationSound, at: ["notifications", "sound"])
    }

    @objc private func openNotificationSystemSettings() {
        AgentNotificationManager.openSystemNotificationSettings()
    }

    /// Describes the current permission and offers the way to System Settings
    /// where that can change anything.
    func refreshNotificationAuthorizationRow() {
        guard let notificationStatusIcon,
              let notificationStatusTitle,
              let notificationStatusLabel,
              let notificationFixButton
        else { return }

        let colors = currentTheme.colors
        let title: String
        let message: String
        let symbolName: String
        let tint: NSColor
        let offersSystemSettings: Bool

        switch AgentNotificationManager.authorization {
        case .authorized:
            title = "Notifications allowed"
            message = "macOS is allowed to show Soprano notifications."
            symbolName = "checkmark.circle"
            tint = colors.success
            offersSystemSettings = true
        case .denied:
            title = "Notifications blocked"
            message = "macOS is blocking Soprano notifications. Panes still show status "
                + "and an unread ring, but no banner appears."
            symbolName = "xmark.circle"
            tint = colors.danger
            offersSystemSettings = true
        case .notDetermined:
            title = "Not asked yet"
            message = "macOS has not been asked yet. The prompt appears the first time "
                + "an unfocused pane wants you."
            symbolName = "questionmark.circle"
            tint = colors.textMuted
            offersSystemSettings = false
        case .unavailable:
            title = "Notifications unavailable"
            message = "Notifications need the packaged app; unbundled builds cannot post them."
            symbolName = "minus.circle"
            tint = colors.textMuted
            offersSystemSettings = false
        case nil:
            title = "Checking permission"
            message = "Checking notification permission…"
            symbolName = "clock"
            tint = colors.textMuted
            offersSystemSettings = false
        }

        notificationStatusIcon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        notificationStatusIcon.contentTintColor = tint
        notificationStatusTitle.setChromeText(
            title,
            font: ChromeFont.row,
            color: tint == colors.danger ? colors.danger : colors.textPrimary
        )
        notificationStatusLabel.stringValue = message
        notificationFixButton.isHidden = !offersSystemSettings
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

    @objc private func prefixKeyRecorded(_ sender: SettingsPrefixKeyControl) {
        keybindingConfig.prefixKey = sender.key
        configStore.write(sender.key, at: ["keybindings", "prefixKey"])
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

    // MARK: - Keyboard Shortcuts

    private func buildKeyboardShortcutsTab() {
        addPageHeader(
            title: "Keyboard Shortcuts",
            subtitle: "The shortcuts in effect. Rebind any of them by id under \"keybindings.bindings\" in settings.json — for example \"\(exampleBindingId)\": \"\(exampleBindingChord)\" — or set one to null to turn it off."
        )

        let fileRows = addSection(
            title: "Editing shortcuts",
            note: note([
                ("Shortcuts are configured in ", isMono: false),
                (configStore.displayPath, isMono: true),
                (". Ids shown here are the keys to use.", isMono: false),
            ])
        )
        addRow(
            makeFormRow(
                leading: makeLead(icon: makeIcon("doc.text"), content: makeMonoLabel(configStore.displayPath)),
                trailing: makeActionButton(title: "Open settings.json", action: #selector(openConfigFile)),
                minHeight: SettingsLayout.tallRowHeight,
                leadingFills: true
            ),
            to: fileRows
        )

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
            let entries = active.map { ($0, false) } + disabled.map { ($0, true) }
            guard !entries.isEmpty else { continue }

            let rows = addSection(title: groupTitle)
            for (binding, isDisabled) in entries {
                addRow(
                    makeShortcutRow(
                        action: binding.label,
                        description: "\(binding.id) · \(binding.description)",
                        binding: binding,
                        isCustomized: customized.contains(binding.id),
                        isDisabled: isDisabled
                    ),
                    to: rows
                )
            }
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
        binding: KeyBinding,
        isCustomized: Bool = false,
        isDisabled: Bool = false
    ) -> NSView {
        let colors = currentTheme.colors
        let actionLabel = NSTextField(labelWithString: action)
        actionLabel.lineBreakMode = .byTruncatingTail
        actionLabel.setChromeText(
            action,
            font: ChromeFont.row,
            color: isDisabled ? colors.textMuted : colors.textPrimary
        )
        actionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let descriptionLabel = NSTextField(labelWithString: description)
        descriptionLabel.font = ChromeFont.meta
        descriptionLabel.textColor = colors.textMuted
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [actionLabel, descriptionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keysView: NSView
        if isDisabled {
            keysView = ChromeChip(text: "Off", theme: currentTheme, style: .outline)
        } else if isCustomized {
            // Same chip as a configured agent profile: this one comes from the file.
            let chip = ChromeChip(text: "settings.json", theme: currentTheme)
            keysView = makeButtonGroup([chip, makeKeycaps(binding)], spacing: 8)
            keysView.toolTip = "Customized in settings.json"
        } else {
            keysView = makeKeycaps(binding)
        }

        return makeFormRow(
            leading: text,
            trailing: keysView,
            minHeight: SettingsLayout.tallRowHeight,
            leadingFills: true
        )
    }

    /// A binding's keys as K1 keycaps, the same caps the command palette
    /// shows: one cap per chord, a prefix sequence as separate caps (`⌃A`
    /// then `P`). Alternatives ("⌘+ / ⌘=") keep their muted slash between them.
    private func makeKeycaps(_ binding: KeyBinding) -> NSView {
        let alternatives = SettingsKeycaps.alternatives(for: binding, prefixKey: keybindingConfig.prefixKey)
        var views: [NSView] = []
        for (index, caps) in alternatives.enumerated() {
            if index > 0 {
                let slash = NSTextField(labelWithString: "/")
                slash.setChromeText("/", font: ChromeFont.meta, color: currentTheme.colors.textMuted)
                views.append(slash)
            }
            views.append(ChromeKeycapGroupView(caps: caps, theme: currentTheme))
        }
        return makeButtonGroup(views, spacing: 4)
    }

    // MARK: - Agent Profiles

    private func buildAgentProfilesTab() {
        addPageHeader(
            title: "Agent Profiles",
            subtitle: "The agents Soprano can launch. Add your own — or patch a built-in — under \"agents\" in settings.json."
        )

        let fileRows = addSection(
            title: "Adding an agent",
            note: note("Reusing a built-in id patches that profile instead of creating a new one.")
        )
        let example = makeWrappingLabel(
            "{ \"id\": \"aider\", \"name\": \"Aider\", \"command\": \"aider\", \"launchKey\": \"cmd+4\" }",
            font: ChromeFont.monoSmall,
            color: currentTheme.colors.textPrimary
        )
        addRow(
            makeFormRow(
                leading: example,
                trailing: makeActionButton(title: "Open settings.json", action: #selector(openConfigFile)),
                minHeight: SettingsLayout.tallRowHeight,
                leadingFills: true
            ),
            to: fileRows
        )

        let gridStack = NSStackView()
        gridStack.orientation = .vertical
        gridStack.alignment = .leading
        gridStack.spacing = 12
        gridStack.translatesAutoresizingMaskIntoConstraints = false

        var currentRow: NSStackView?
        for (index, profile) in AgentCatalog.all.enumerated() {
            if index % 2 == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.distribution = .fillEqually
                row.alignment = .top
                row.spacing = 12
                row.translatesAutoresizingMaskIntoConstraints = false
                gridStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: gridStack.widthAnchor).isActive = true
                currentRow = row
            }

            let card = makeAgentCard(profile)
            currentRow?.addArrangedSubview(card)
        }
        // An odd last card keeps its column width instead of spanning both.
        if AgentCatalog.all.count % 2 == 1 {
            currentRow?.addArrangedSubview(NSView())
        }

        addSection(title: nil, note: nil, content: gridStack)
    }

    private func makeAgentCard(_ profile: AgentProfile) -> NSView {
        let colors = currentTheme.colors
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = Chrome.Radius.card
        card.layer?.borderWidth = Chrome.hairline
        card.layer?.backgroundColor = colors.raised.cgColor
        card.layer?.borderColor = colors.borderSubtle.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let title = NSTextField(labelWithString: profile.name)
        title.lineBreakMode = .byTruncatingTail
        title.setChromeText(profile.name, font: ChromeFont.row, color: colors.textPrimary)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var titleViews: [NSView] = [ChromeStatusMark(shape: .dot, color: profile.nsColor)]
        // Profile icons are SF Symbol names; a custom one that is not
        // resolves to no glyph rather than to its raw name.
        if NSImage(systemSymbolName: profile.icon, accessibilityDescription: nil) != nil {
            titleViews.append(makeIcon(profile.icon))
        }
        titleViews.append(title)
        if configStore.resolved.configuredAgentIds.contains(profile.id) {
            titleViews.append(ChromeChip(text: "settings.json", theme: currentTheme))
        }
        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        stack.addArrangedSubview(titleRow)

        let description = makeWrappingLabel(profile.description, font: ChromeFont.meta, color: colors.textMuted)
        stack.addArrangedSubview(description)

        let command = NSTextField(labelWithString: "$ \(profile.command) \(profile.args.joined(separator: " "))")
        command.font = ChromeFont.monoSmall
        command.textColor = colors.textPrimary
        command.lineBreakMode = .byTruncatingMiddle
        command.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(command)

        let ready = profile.patterns?.ready?.joined(separator: ", ") ?? "-"
        let error = profile.patterns?.error?.joined(separator: ", ") ?? "-"
        let patterns = makeWrappingLabel("Patterns\nReady: \(ready)\nError: \(error)", font: ChromeFont.meta, color: colors.textMuted)
        stack.addArrangedSubview(patterns)

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            patterns.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            command.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -24),
            titleRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -24),
        ])

        return card
    }

    // MARK: - Accounts

    private func buildAccountsTab() {
        accountActions.removeAll()
        let snapshot = AccountsController.shared.snapshot

        addPageHeader(
            title: "Accounts",
            subtitle: "Sign in to several Claude and Codex accounts. omp balances across its accounts; Claude Code and the Codex CLI use the one you choose."
        )

        let refreshButton = makeAccountButton(title: "Refresh") {
            AccountsController.shared.refresh(force: true)
        }
        refreshButton.isEnabled = !snapshot.isRefreshing
        let refreshLabel = NSTextField(labelWithString: Self.accountsRefreshText(snapshot))
        refreshLabel.setChromeText(
            Self.accountsRefreshText(snapshot),
            font: ChromeFont.meta,
            color: currentTheme.colors.textMuted
        )
        let refreshRow = makeButtonGroup([refreshButton, refreshLabel], spacing: 10)
        refreshRow.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(refreshRow)

        for list in AccountListID.all {
            addAccountListSection(list, snapshot: snapshot)
        }
    }

    /// "Updated 4m ago": recomputed on every rebuild, which each refresh
    /// triggers, so it never needs a timer of its own.
    private static func accountsRefreshText(_ snapshot: AccountsSnapshot, now: Date = Date()) -> String {
        if snapshot.isRefreshing { return "Updating…" }
        guard let lastRefresh = snapshot.lastRefresh else { return "Not updated yet" }
        let seconds = max(0, now.timeIntervalSince(lastRefresh))
        if seconds < 60 { return "Updated just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours)h ago" }
        return "Updated \(hours / 24)d ago"
    }

    private func addAccountListSection(_ listID: AccountListID, snapshot: AccountsSnapshot) {
        let rows = addSection(
            title: "\(listID.provider.displayName) · \(listID.tool.displayName)",
            note: note(Self.accountListSubtitle(listID.tool))
        )

        if let error = snapshot.errors[listID] {
            let dismiss = makeAccountButton(title: "Dismiss") {
                AccountsController.shared.dismissError(in: listID)
            }
            addRow(
                makeFormRow(leading: makeNotice(error, isError: true, button: dismiss), leadingFills: true),
                to: rows
            )
        }

        let list = snapshot.lists[listID]
        if let list, let reason = list.unavailableReason {
            addAccountsNote(reason, to: rows)
        } else if let list {
            addRow(makeDefaultAccountRow(list), to: rows)
            for account in list.accounts {
                addRow(makeAccountRow(account, in: list, snapshot: snapshot), to: rows)
            }
        } else {
            addAccountsNote(snapshot.isRefreshing ? "Loading accounts…" : "Accounts not loaded yet.", to: rows)
        }

        addAccountListFooter(listID, list: list, snapshot: snapshot, to: rows)
    }

    private static func accountListSubtitle(_ tool: AccountTool) -> String {
        switch tool {
        case .omp:
            return "omp uses every account and fails over when one runs out. New omp panes try the preferred account first."
        case .claudeCode:
            return "Choosing an account signs Claude Code in with it on this Mac; running claude sessions switch too. System default is the login Claude Code had before."
        case .codexCLI:
            return "New codex panes use the chosen account; running panes keep theirs. History, config and skills stay shared."
        }
    }

    private func addAccountsNote(_ text: String, to stack: NSStackView) {
        let label = makeWrappingLabel(text, font: ChromeFont.label, color: currentTheme.colors.textMuted)
        addRow(makeFormRow(leading: label, leadingFills: true), to: stack)
    }

    /// "Automatic" for omp, "System default" for the CLIs: the choice that
    /// leaves the tool to its own login.
    private func makeDefaultAccountRow(_ list: AccountList) -> NSView {
        let isSelected = list.selectedAccountId == nil
        let title: String
        let detail: String
        var problem: String?
        if list.id.tool == .omp {
            title = "Automatic"
            detail = "Balance by usage"
        } else {
            title = "System default"
            if let systemDefault = list.systemDefault {
                let email = systemDefault.identity.email
                detail = ([email].filter { !$0.isEmpty } + Self.accountDetailParts(systemDefault))
                    .joined(separator: "  ·  ")
                problem = systemDefault.problem
            } else {
                detail = "Not signed in"
            }
        }

        var buttons: [NSButton] = []
        if !isSelected {
            let listID = list.id
            buttons.append(makeAccountButton(title: listID.tool == .omp ? "Automatic" : "Use") {
                AccountsController.shared.select(accountId: nil, in: listID)
            })
        }
        return makeAccountEntryRow(
            title: title,
            isSelected: isSelected,
            badge: isSelected ? "Active" : nil,
            detail: detail,
            problem: problem,
            buttons: buttons
        )
    }

    private func makeAccountRow(_ account: AccountRow, in list: AccountList, snapshot: AccountsSnapshot) -> NSView {
        let listID = list.id
        let accountId = account.id
        let isSelected = list.selectedAccountId == accountId

        var buttons: [NSButton] = []
        if !isSelected {
            buttons.append(makeAccountButton(title: listID.tool == .omp ? "Prefer" : "Use") {
                AccountsController.shared.select(accountId: accountId, in: listID)
            })
        }
        let reauthenticate = makeAccountButton(title: "Re-authenticate") {
            AccountsController.shared.reauthenticate(accountId: accountId, in: listID)
        }
        // One browser sign-in at a time, across every list.
        reauthenticate.isEnabled = snapshot.pendingLogin == nil
        buttons.append(reauthenticate)
        buttons.append(makeAccountButton(title: "Remove") { [weak self] in
            self?.confirmRemoveAccount(account, from: listID)
        })

        let detailParts = Self.accountDetailParts(account)
        return makeAccountEntryRow(
            title: account.identity.email,
            isSelected: isSelected,
            badge: isSelected ? (listID.tool == .omp ? "Preferred" : "Active") : nil,
            detail: detailParts.joined(separator: "  ·  "),
            problem: account.problem,
            buttons: buttons
        )
    }

    /// Organization, plan and usage. Windows are joined with a wider gap than
    /// the " · " inside each one, so "5h 9% · 3h 54m" still reads as a unit.
    private static func accountDetailParts(_ account: AccountRow) -> [String] {
        // omp names a personal ChatGPT workspace after its plan, so org and
        // plan can be the same word; say it once.
        var parts: [String] = []
        for part in [account.organizationName, account.plan].compactMap({ $0 })
        where !part.isEmpty && !parts.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            parts.append(part)
        }
        if let usage = account.usage, !usage.windows.isEmpty {
            parts.append(usage.windows.map { UsageFormat.window($0) }.joined(separator: "  ·  "))
        } else {
            parts.append("No usage data")
        }
        return parts
    }

    /// Mark, title with an optional chip, a wrapping detail line, and the
    /// row's buttons on the right edge. The chosen login sits on the muted
    /// selection pill with a filled mark; a login with a problem gets the
    /// error diamond.
    private func makeAccountEntryRow(
        title: String,
        isSelected: Bool,
        badge: String?,
        detail: String,
        problem: String?,
        buttons: [NSButton]
    ) -> NSView {
        let colors = currentTheme.colors
        let hasProblem = !(problem ?? "").isEmpty

        let mark = ChromeStatusMark(
            shape: hasProblem ? .diamond : (isSelected ? .dot : .ring),
            color: hasProblem ? colors.danger : (isSelected ? colors.textPrimary : colors.textMuted)
        )

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setChromeText(title, font: ChromeFont.row, color: colors.textPrimary)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var titleViews: [NSView] = [titleLabel]
        if let badge {
            let chip = ChromeChip(text: badge, theme: currentTheme)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleViews.append(chip)
        }
        let titleRow = NSStackView(views: titleViews)
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        let textStack = NSStackView(views: [titleRow])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleRow.widthAnchor.constraint(lessThanOrEqualTo: textStack.widthAnchor).isActive = true

        let detailLabel = makeWrappingLabel(detail, font: ChromeFont.meta, color: colors.textMuted)
        textStack.addArrangedSubview(detailLabel)
        detailLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        if let problem, hasProblem {
            let problemLabel = makeWrappingLabel(problem, font: ChromeFont.meta, color: colors.danger)
            textStack.addArrangedSubview(problemLabel)
            problemLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }

        // The mark sits on the title's line, not the block's centre: an
        // 18 pt slot (the title's line height) centres it there.
        let markSlot = NSView()
        markSlot.translatesAutoresizingMaskIntoConstraints = false
        markSlot.addSubview(mark)
        NSLayoutConstraint.activate([
            markSlot.widthAnchor.constraint(equalToConstant: Chrome.statusMark),
            markSlot.heightAnchor.constraint(equalToConstant: 18),
            mark.centerXAnchor.constraint(equalTo: markSlot.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: markSlot.centerYAnchor),
        ])

        let lead = NSStackView(views: [markSlot, textStack])
        lead.orientation = .horizontal
        lead.alignment = .top
        lead.spacing = 10
        lead.setHuggingPriority(.defaultLow, for: .horizontal)

        let row = makeFormRow(
            leading: lead,
            trailing: buttons.isEmpty ? nil : makeButtonGroup(buttons),
            minHeight: SettingsLayout.tallRowHeight,
            leadingFills: true
        )

        if isSelected {
            let pill = ChromeRowBackgroundView(theme: currentTheme)
            pill.style = .selectedUnfocused
            pill.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(pill, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                pill.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                pill.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
                pill.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            ])
        }
        return row
    }

    /// The running sign-in for this list, or the button that starts one.
    private func addAccountListFooter(
        _ listID: AccountListID,
        list: AccountList?,
        snapshot: AccountsSnapshot,
        to stack: NSStackView
    ) {
        var buttons: [NSView] = []

        if let pending = snapshot.pendingLogin, pending.list == listID {
            let email = pending.accountId.flatMap { id in
                list?.accounts.first { $0.id == id }?.identity.email
            }
            let text = email.map { "Waiting for sign-in in your browser to re-authenticate \($0)…" }
                ?? "Waiting for sign-in in your browser…"
            addAccountsNote(text, to: stack)

            if let url = pending.signInURL {
                buttons.append(makeAccountButton(title: "Open Sign-in Page") {
                    _ = NSWorkspace.shared.open(url)
                })
            }
            buttons.append(makeAccountButton(title: "Cancel") {
                AccountsController.shared.cancelLogin()
            })
        } else {
            let add = makeAccountButton(title: "Add Account", kind: .ink) {
                AccountsController.shared.addAccount(to: listID)
            }
            // One browser sign-in at a time, across every list.
            add.isEnabled = snapshot.pendingLogin == nil
            buttons.append(add)
        }
        addRow(
            makeFormRow(leading: makeButtonGroup(buttons, spacing: 8), minHeight: SettingsLayout.tallRowHeight),
            to: stack
        )
    }

    private static func accountRemovalExplanation(_ tool: AccountTool) -> String {
        switch tool {
        case .omp:
            return "omp signs this account out on this Mac."
        case .claudeCode:
            return "Soprano forgets this login. If it is active, Claude Code goes back to the System default."
        case .codexCLI:
            return "Soprano deletes this account's sign-in. If it is active, new codex panes use the System default."
        }
    }

    private func confirmRemoveAccount(_ account: AccountRow, from listID: AccountListID) {
        let alert = NSAlert()
        alert.messageText = "Remove \(account.identity.email)?"
        alert.informativeText = Self.accountRemovalExplanation(listID.tool)
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        let accountId = account.id
        guard let window = view.window else {
            if alert.runModal() == .alertFirstButtonReturn {
                AccountsController.shared.remove(accountId: accountId, from: listID)
            }
            return
        }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            AccountsController.shared.remove(accountId: accountId, from: listID)
        }
    }

    private func makeAccountButton(
        title: String,
        kind: ChromeButton.Kind = .standard,
        handler: @escaping () -> Void
    ) -> NSButton {
        let button = makeActionButton(title: title, action: #selector(accountButtonClicked(_:)), kind: kind)
        let tag = accountActions.count + 1
        button.tag = tag
        accountActions[tag] = handler
        return button
    }

    @objc private func accountButtonClicked(_ sender: NSButton) {
        accountActions[sender.tag]?()
    }

    // MARK: - About

    private func buildAboutTab() {
        let colors = currentTheme.colors

        let title = NSTextField(labelWithString: "Soprano")
        title.setChromeText("Soprano", font: ChromeFont.title, color: colors.textPrimary)

        let tagline = NSTextField(labelWithString: "AI Agent Orchestration Platform")
        tagline.setChromeText("AI Agent Orchestration Platform", font: ChromeFont.row, color: colors.textMuted)

        let version = NSTextField(labelWithString: "Version: \(AppVersion.current)")
        version.setChromeText("Version: \(AppVersion.current)", font: ChromeFont.meta, color: colors.textMuted)

        let runtime = NSTextField(labelWithString: "Runtime: Swift + AppKit + libghostty")
        runtime.setChromeText("Runtime: Swift + AppKit + libghostty", font: ChromeFont.meta, color: colors.textMuted)

        let hero = NSStackView(views: [title, tagline, version, runtime])
        hero.orientation = .vertical
        hero.alignment = .leading
        hero.spacing = 2
        hero.setCustomSpacing(6, after: title)
        hero.setCustomSpacing(12, after: tagline)
        hero.translatesAutoresizingMaskIntoConstraints = false
        addContentSubview(hero)

        let rows = addSection(title: "Quick Reference")
        addRows(
            quickReferenceBindings().map { binding in
                makeSettingRow(label: binding.label, control: makeKeycaps(binding))
            },
            to: rows
        )
    }

    private func quickReferenceBindings() -> [KeyBinding] {
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
        return preferredIds.compactMap { id in
            keybindingConfig.bindings.first { $0.id == id }
        }
    }
}

private extension AppearancePreference {
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "display"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// K1 keycaps for Settings, built from the `KeyBinding` itself through the
/// palette's `MainWindowController.keycaps(for:prefixKey:)`, so a shortcut
/// reads the same in both places (`⌃⇥`, `⌘esc`, `↵`).
enum SettingsKeycaps {
    /// One cap list per alternative. Only a built-in binding whose
    /// `defaultKeys` lists several K1 chords (`⌘+ / ⌘=`) has more than one;
    /// the bound chord keeps its place among them.
    static func alternatives(for binding: KeyBinding, prefixKey: String) -> [[String]] {
        let caps = MainWindowController.keycaps(for: binding, prefixKey: prefixKey)
        guard !caps.isEmpty else { return [] }
        let listed = binding.defaultKeys.components(separatedBy: " / ")
        let bound = caps.joined()
        guard caps.count == 1, listed.count > 1, listed.contains(bound) else { return [caps] }
        return listed.map { $0 == bound ? caps : [$0] }
    }

    /// The prefix chord as one cap: `⌃A`.
    static func prefixLegend(_ prefixKey: String) -> String {
        "⌃" + prefixKey.uppercased()
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

/// One settings section: the margin column (eyebrow and note) beside its
/// card, or above it when the page is too narrow for both.
private final class SettingsSectionView: NSView {
    private let side = NSStackView()
    private var sideBySideConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []

    var isStacked: Bool {
        didSet {
            guard isStacked != oldValue else { return }
            applyArrangement()
        }
    }

    init(side sideViews: [NSView], content: NSView, isStacked: Bool) {
        self.isStacked = isStacked
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6
        side.translatesAutoresizingMaskIntoConstraints = false
        for view in sideViews {
            side.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: side.widthAnchor).isActive = true
        }
        addSubview(side)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: leadingAnchor),
            side.topAnchor.constraint(equalTo: topAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: side.bottomAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor),
        ])
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        hug.isActive = true

        let hasSide = !sideViews.isEmpty
        sideBySideConstraints = [
            side.widthAnchor.constraint(equalToConstant: SettingsLayout.marginColumn),
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsLayout.marginColumn + SettingsLayout.columnGap
            ),
            content.topAnchor.constraint(equalTo: topAnchor),
        ]
        stackedConstraints = [
            side.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            hasSide
                ? content.topAnchor.constraint(equalTo: side.bottomAnchor, constant: 8)
                : content.topAnchor.constraint(equalTo: topAnchor),
        ]
        applyArrangement()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func applyArrangement() {
        NSLayoutConstraint.deactivate(isStacked ? sideBySideConstraints : stackedConstraints)
        NSLayoutConstraint.activate(isStacked ? stackedConstraints : sideBySideConstraints)
        // Beside the card the eyebrow lines up with the first row's label.
        side.edgeInsets = NSEdgeInsets(top: isStacked ? 0 : 11, left: 0, bottom: 0, right: 0)
    }
}

/// A segmented control (`.segmented`): an overlay track with a raised
/// active segment. Each segment is a button, so VoiceOver reads them as a
/// radio group.
private final class SettingsSegmentedControl: NSControl {
    private(set) var selectedSegment: Int
    private var segments: [SettingsSegmentButton] = []
    private var theme: AppTheme

    init(
        items: [(title: String, symbolName: String)],
        selectedSegment: Int,
        theme: AppTheme,
        target: AnyObject,
        action: Selector
    ) {
        self.selectedSegment = selectedSegment
        self.theme = theme
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Chrome.Radius.control
        layer?.backgroundColor = theme.colors.bgOverlay.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Chrome.controlHeight),
        ])

        for (index, item) in items.enumerated() {
            let segment = SettingsSegmentButton(
                title: item.title,
                symbolName: item.symbolName,
                theme: theme,
                target: self,
                action: #selector(segmentClicked(_:))
            )
            segment.tag = index
            segment.isActive = index == selectedSegment
            segments.append(segment)
            stack.addArrangedSubview(segment)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard sender.tag != selectedSegment else { return }
        selectedSegment = sender.tag
        for segment in segments {
            segment.isActive = segment.tag == selectedSegment
        }
        sendAction(action, to: target)
    }
}

private final class SettingsSegmentButton: NSButton {
    private static let padding: CGFloat = 10
    private static let iconSide: CGFloat = 12
    private static let gap: CGFloat = 5

    var isActive = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isActive)
        }
    }
    private let theme: AppTheme
    private let symbol: NSImage?

    init(title: String, symbolName: String, theme: AppTheme, target: AnyObject, action: Selector) {
        self.theme = theme
        self.symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var label: NSAttributedString {
        ChromeText.attributed(
            title,
            font: isActive ? ChromeFont.labelStrong : ChromeFont.label,
            color: isActive ? theme.colors.textPrimary : theme.colors.textMuted
        )
    }

    override var intrinsicContentSize: NSSize {
        let textWidth = ceil(ChromeText.attributed(title, font: ChromeFont.labelStrong, color: .labelColor).size().width)
        return NSSize(width: Self.padding * 2 + Self.iconSide + Self.gap + textWidth, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        if isActive {
            let shape = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Chrome.Radius.cap,
                yRadius: Chrome.Radius.cap
            )
            colors.bgRaised.setFill()
            shape.fill()
            colors.borderSubtle.setStroke()
            shape.lineWidth = Chrome.hairline
            shape.stroke()
        }
        let ink = isActive ? colors.textPrimary : colors.textMuted
        let label = label
        let textSize = label.size()
        let contentWidth = Self.iconSide + Self.gap + ceil(textSize.width)
        var x = floor((bounds.width - contentWidth) / 2)
        if let symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
            let tinted = symbol.withSymbolConfiguration(configuration) ?? symbol
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: x + floor((Self.iconSide - size.width) / 2),
                    y: floor((bounds.height - size.height) / 2),
                    width: size.width,
                    height: size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
        x += Self.iconSide + Self.gap
        label.draw(at: NSPoint(x: x, y: floor((bounds.height - textSize.height) / 2)))
    }
}

/// The Prefix key control: the configured prefix as an accent field keycap
/// (`⌃A`). Click it (or press Space) and type a key to make Control plus that
/// key the prefix.
private final class SettingsPrefixKeyControl: NSControl, EscapeConsumingControl {
    private let cap: ChromeKeycapView
    private(set) var key: String
    private var isRecording = false {
        didSet { refresh() }
    }

    var consumesEscape: Bool { isRecording }

    init(key: String, theme: AppTheme, target: AnyObject, action: Selector) {
        self.key = key
        cap = ChromeKeycapView(
            legend: SettingsKeycaps.prefixLegend(key),
            theme: theme,
            style: .field,
            tone: .accent
        )
        super.init(frame: .zero)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        addSubview(cap)
        NSLayoutConstraint.activate([
            cap.leadingAnchor.constraint(equalTo: leadingAnchor),
            cap.trailingAnchor.constraint(equalTo: trailingAnchor),
            cap.topAnchor.constraint(equalTo: topAnchor),
            cap.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = "Click, then press the key to use with Control"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Prefix key")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A key view only under Full Keyboard Access, like the Chrome switch;
    /// a click or an accessibility press still takes focus for the length
    /// of one recording.
    override var canBecomeKeyView: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }

    override var acceptsFirstResponder: Bool { isEnabled && (isRecording || canBecomeKeyView) }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        ).fill()
    }

    /// Esc ends a recording and keeps the current prefix. The overlay
    /// header's Done steps aside while `consumesEscape`, so Esc reaches this
    /// key-equivalent pass.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording, event.keyCode == 53 {
            endRecording()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if isRecording {
            endRecording()
        } else {
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
        }
    }

    override func mouseDown(with event: NSEvent) {
        beginRecording()
    }

    override func accessibilityPerformPress() -> Bool {
        beginRecording()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if event.charactersIgnoringModifiers == " " {
                beginRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        // Esc keeps the current prefix.
        if event.keyCode == 53 {
            endRecording()
            return
        }
        guard let typed = event.charactersIgnoringModifiers?.lowercased(),
              typed.count == 1,
              let scalar = typed.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.contains(scalar),
              !CharacterSet.controlCharacters.contains(scalar),
              // Function keys (arrows, F-keys) live in the private-use range.
              !(0xF700...0xF8FF).contains(scalar.value)
        else {
            NSSound.beep()
            return
        }
        key = typed
        endRecording()
        sendAction(action, to: target)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    private func beginRecording() {
        guard isEnabled else { return }
        isRecording = true
        if let window, window.firstResponder !== self, !window.makeFirstResponder(self) {
            isRecording = false
        }
    }

    /// Without Full Keyboard Access the control is not a key view, so it
    /// hands focus back once the recording is over.
    private func endRecording() {
        isRecording = false
        if !canBecomeKeyView, window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            isRecording = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func refresh() {
        cap.legend = isRecording ? "⌃…" : SettingsKeycaps.prefixLegend(key)
        setAccessibilityValue(cap.legend)
    }
}

/// A settings nav item (`.nav-item`): a 14 pt symbol and the tab name. The
/// active item is the raised pill with ink Medium text; hover is the hover
/// pill.
private final class SettingsTabButton: NSButton {
    private static let inset: CGFloat = 10
    private static let symbolSlot: CGFloat = 14

    var isActive = false {
        didSet { needsDisplay = true }
    }
    private var theme: AppTheme
    private let symbol: NSImage?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var hoverArea: NSTrackingArea?

    init(tab: SettingsTab, theme: AppTheme, target: AnyObject?, action: Selector) {
        self.theme = theme
        self.symbol = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
        super.init(frame: .zero)
        self.title = tab.title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = theme.colors
        if isActive {
            ChromeSelectionPill.draw(.raisedTab, in: bounds, colors: colors, inset: 0)
        } else if isHovered {
            ChromeSelectionPill.draw(.hover, in: bounds, colors: colors, inset: 0)
        }
        let ink = isActive ? colors.textPrimary : colors.textMuted

        var x = Self.inset
        if let symbol {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))
            let tinted = symbol.withSymbolConfiguration(configuration) ?? symbol
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: x + floor((Self.symbolSlot - size.width) / 2),
                    y: floor((bounds.height - size.height) / 2),
                    width: size.width,
                    height: size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            x += Self.symbolSlot + 8
        }

        let label = ChromeText.attributed(
            title,
            font: isActive ? ChromeFont.labelStrong : ChromeFont.label,
            color: ink
        )
        let height = ceil(label.size().height)
        label.draw(in: NSRect(
            x: x,
            y: floor((bounds.height - height) / 2),
            width: max(0, bounds.width - x - Self.inset),
            height: height
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }
}
