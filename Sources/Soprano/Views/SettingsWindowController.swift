import AppKit

/// The settings pages, in navigation order.
enum SettingsTab: Int, CaseIterable {
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

    /// SF Symbol for the navigation.
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

/// The settings screen, laid out as Soprano Agents' settings modal: a 240 pt
/// navigation on the left, the "Settings › Page" breadcrumb header, and the
/// page as titled sections of grouped rows (`SettingsForm`).
///
/// The screen keeps no settings state of its own: every control writes one
/// key into `settings.json` through `ConfigStore`, and the page re-renders
/// when the file (or the accounts) change.
final class SettingsViewController: NSViewController {
    static let pageMaxWidth: CGFloat = 768
    static let filterIdentifier = NSUserInterfaceItemIdentifier("keybindings.filter")

    private let themeManager: ThemeManager
    private var settings: AppSettings
    private var keybindingConfig: KeyBindingConfig

    /// Where edits go. Every control on this screen writes one key into
    /// `settings.json`; nothing here owns state of its own.
    private let configStore: ConfigStore
    /// What the Accounts page reads and acts through; `AccountsController`
    /// in the app.
    private let accounts: any SettingsAccountsSource
    /// What is currently drawn on screen but is not part of `settings` or
    /// `keybindingConfig`, so a change in either alone still triggers a
    /// rebuild: config problems, and the agent catalog.
    private var renderedIssues: [ConfigIssue] = []
    private var renderedAgents: [AgentProfile] = []

    private(set) var currentTab: SettingsTab = .general
    /// The close button and Esc: the owner takes the screen away.
    var onClose: (() -> Void)?

    private let nav = SettingsNavView()
    private let header = SettingsHeaderView()
    private let scrollView = NSScrollView()
    private let document = SettingsDocumentView()
    private var renderedPageWidth: CGFloat = 0
    private var renderedClipWidth: CGFloat = -1
    private var rebuildScheduled = false
    private var isRebuilding = false
    /// The Keyboard Shortcuts page's filter text.
    private(set) var shortcutQuery = ""

    private var notificationRow: SettingsRowView?
    private var notificationFixButton: SettingsButton?
    private var projectDirectoriesGroup: SettingsGroupView?
    private var projectDirectoryAddRow: NSView?
    private var projectDirectoryInput: NSTextField?
    private var projectDirectoriesForm: SettingsForm?
    private static let accountsObserverId = "SettingsViewController.accounts"

    init(
        themeManager: ThemeManager,
        settings: AppSettings,
        keybindingConfig: KeyBindingConfig,
        configStore: ConfigStore = .shared,
        accounts: any SettingsAccountsSource = AccountsController.shared
    ) {
        self.themeManager = themeManager
        self.settings = settings
        self.keybindingConfig = keybindingConfig
        self.configStore = configStore
        self.accounts = accounts
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

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        scheduleRebuild()
    }

    // MARK: - Layout

    override func loadView() {
        let root = SettingsRootView()

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        nav.onSelect = { [weak self] tab in self?.switchTab(to: tab) }
        nav.onOpenFile = { [weak self] in self?.configStore.openInEditor() }
        header.onClose = { [weak self] in self?.onClose?() }

        for view in [nav, header, scrollView] as [NSView] {
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            nav.topAnchor.constraint(equalTo: root.topAnchor),
            nav.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            nav.widthAnchor.constraint(equalToConstant: SettingsNavView.width),

            header.leadingAnchor.constraint(equalTo: nav.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: nav.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        rebuildCurrentTab(resetScroll: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The controller keeps the handler by id; capturing weakly lets this
        // screen go away without unregistering, which a deinit could not do.
        accounts.addObserver(id: Self.accountsObserverId) { [weak self] _ in
            guard let self, currentTab == .accounts else { return }
            // A snapshot can change from inside a button's own action; let
            // that event finish before the button is torn down.
            scheduleRebuild()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The page column follows the card's width; a change re-renders it
        // once this layout pass is over.
        if !isRebuilding,
           Self.pageWidth(for: view.bounds.width) != renderedPageWidth
            || scrollView.contentView.bounds.width != renderedClipWidth {
            scheduleRebuild()
        }
    }

    /// Width of the page column for a card `width` wide.
    static func pageWidth(for width: CGFloat) -> CGFloat {
        max(320, min(pageMaxWidth, width - SettingsNavView.width - 48))
    }

    /// The view that takes the keyboard when the screen opens.
    var initialFirstResponder: NSView { document }

    // MARK: - Pages

    /// Opens the Accounts page, e.g. from the status bar's usage readout.
    func showAccountsTab() {
        switchTab(to: .accounts)
    }

    func switchTab(to tab: SettingsTab) {
        guard isViewLoaded else {
            currentTab = tab
            return
        }
        view.window?.endEditing(for: nil)
        let changed = tab != currentTab
        currentTab = tab
        rebuildCurrentTab(resetScroll: changed)
        if tab == .accounts {
            // Throttled by the controller, so flipping tabs does not refetch.
            accounts.refresh(force: false)
        }
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        // Rebuilding tears down the control that fired or is mid-edit; let
        // the current event finish first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            rebuildScheduled = false
            rebuildCurrentTab(resetScroll: false)
        }
    }

    /// Rebuilds the page from settings, keeping the scroll position and the
    /// focused text field (by identifier, with its selection) unless the page
    /// changed.
    private func rebuildCurrentTab(resetScroll: Bool) {
        guard isViewLoaded else { return }
        // Stamped here rather than in `update`, because this is where issues
        // actually reach the screen — every other entry point (tab switch,
        // Reload) lands here too.
        renderedIssues = configStore.issues
        renderedAgents = configStore.resolved.agents
        let focused = focusedFieldState()
        let origin = scrollView.contentView.bounds.origin
        isRebuilding = true
        defer { isRebuilding = false }

        nav.update(selected: currentTab)
        header.pageTitle = currentTab.title
        notificationRow = nil
        notificationFixButton = nil
        projectDirectoriesGroup = nil
        projectDirectoryAddRow = nil
        projectDirectoryInput = nil
        projectDirectoriesForm = nil

        let width = Self.pageWidth(for: view.bounds.width)
        let form = SettingsForm(width: width)
        let sections: [NSView]
        switch currentTab {
        case .general: sections = generalPage(form)
        case .keyboardShortcuts: sections = keyboardShortcutsPage(form)
        case .agentProfiles: sections = agentProfilesPage(form)
        case .accounts: sections = accountsPage(form)
        case .about: sections = aboutPage(form)
        }
        document.setSections(sections, width: width)
        renderedPageWidth = width
        view.layoutSubtreeIfNeeded()
        fitDocument()

        let clip = scrollView.contentView
        let target = resetScroll ? .zero : clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
        refreshNotificationAuthorizationRow()
        restoreFocus(focused)
    }

    private func fitDocument() {
        let clipWidth = scrollView.contentView.bounds.width
        document.fit(to: clipWidth)
        renderedClipWidth = clipWidth
    }

    private func focusedFieldState() -> (identifier: NSUserInterfaceItemIdentifier, selection: NSRange)? {
        guard let editor = view.window?.firstResponder as? NSTextView,
              let field = editor.delegate as? NSTextField,
              field.isDescendant(of: document),
              let identifier = field.identifier
        else { return nil }
        return (identifier, editor.selectedRange())
    }

    private func restoreFocus(_ state: (identifier: NSUserInterfaceItemIdentifier, selection: NSRange)?) {
        guard let window = view.window else { return }
        if let state, let field = document.field(withIdentifier: state.identifier) {
            window.makeFirstResponder(field)
            let length = field.stringValue.utf16.count
            let location = min(state.selection.location, length)
            field.currentEditor()?.selectedRange = NSRange(location: location, length: min(state.selection.length, length - location))
        } else if window.firstResponder == nil || window.firstResponder === window
                    || (window.firstResponder as? NSView)?.window == nil {
            window.makeFirstResponder(document)
        }
    }

    /// Esc while the shortcut filter edits a query clears the query first.
    func handleEscape() -> Bool {
        guard currentTab == .keyboardShortcuts, !shortcutQuery.isEmpty,
              focusedFieldState()?.identifier == Self.filterIdentifier
        else { return false }
        shortcutQuery = ""
        rebuildCurrentTab(resetScroll: false)
        return true
    }

    private func write(_ value: Any, at path: [String]) {
        configStore.write(value, at: path)
    }

    /// Reset action for `path` when its value differs from the default, else nil.
    private func reset(_ path: [String], isDefault: Bool) -> (() -> Void)? {
        isDefault ? nil : { [weak self] in self?.configStore.remove(at: path) }
    }

    private func switchControl(_ isOn: Bool, label: String, action: Selector) -> SettingsSwitch {
        SettingsSwitch(isOn: isOn, label: label, target: self, action: action)
    }

    private func openFileButton(_ form: SettingsForm) -> SettingsButton {
        form.button("Open settings.json") { [weak self] in self?.configStore.openInEditor() }
    }

    // MARK: - General

    private func generalPage(_ form: SettingsForm) -> [NSView] {
        let defaults = AppSettings.defaultSettings
        var sections: [NSView] = []

        // Without this, a typo in the file would fail silently.
        let issues = configStore.issues
        if !issues.isEmpty {
            sections.append(form.section("settings.json", issues.map { issue in
                form.row(
                    issue.severity == .error ? "Error" : "Warning",
                    description: issue.line.map { "Line \($0): \(issue.message)" } ?? issue.message,
                    descriptionRole: issue.severity == .error ? { $0.errorForeground } : { $0.warningForeground },
                    control: openFileButton(form)
                )
            }))
        }

        let theme = SettingsSelectButton(
            options: AppTheme.options.map { ($0.name, $0.id) },
            selected: settings.themeId,
            width: 224,
            accessibilityLabel: "Theme",
            separatorAfterFirst: true
        )
        theme.target = self
        theme.action = #selector(themeChanged(_:))
        let appearances = AppearancePreference.allCases
        let appearance = SettingsSegmentedControl(
            titles: appearances.map(\.title),
            selectedSegment: appearances.firstIndex(of: settings.appearance) ?? 0,
            target: self,
            action: #selector(appearanceChanged(_:))
        )
        appearance.setAccessibilityLabel("Appearance")
        sections.append(form.section("Appearance", [
            form.row(
                "Theme",
                description: "Folio follows the appearance below; the other themes pin their own palette.",
                reset: reset(["theme"], isDefault: settings.themeId == defaults.themeId),
                control: theme
            ),
            form.row(
                "Appearance",
                description: "Light or dark for Folio. System follows the macOS appearance.",
                reset: reset(["appearance"], isDefault: settings.appearance == defaults.appearance),
                control: appearance
            ),
            form.row(
                "Hide window bar",
                description: "Hide the title bar and traffic-light controls so panes use the full window.",
                reset: reset(["hideWindowBar"], isDefault: settings.hideWindowBar == defaults.hideWindowBar),
                control: switchControl(settings.hideWindowBar, label: "Hide window bar", action: #selector(hideWindowBarChanged(_:)))
            ),
            form.row(
                "Hide window tabs",
                description: "Hide the numbered window tabs; the tab row moves up. Switch windows from the sidebar, ⌃1…⌃9, or ⌘F.",
                reset: reset(["hideWindowTabs"], isDefault: settings.hideWindowTabs == defaults.hideWindowTabs),
                control: switchControl(settings.hideWindowTabs, label: "Hide window tabs", action: #selector(hideWindowTabsChanged(_:)))
            ),
            form.row(
                "Show uptime in status bar",
                description: "How long Soprano has been running, as Up h:mm:ss at the end of the status bar.",
                reset: reset(["statusBar", "uptime"], isDefault: settings.statusBarUptime == defaults.statusBarUptime),
                control: switchControl(settings.statusBarUptime, label: "Show uptime in status bar", action: #selector(statusBarUptimeChanged(_:)))
            ),
        ]))

        sections.append(form.section("Session", [
            form.row(
                "Restore workspace",
                description: "Reopen the workspace from the previous launch when Soprano starts.",
                reset: reset(["restoreLastSession"], isDefault: settings.restoreLastSession == defaults.restoreLastSession),
                control: switchControl(settings.restoreLastSession, label: "Restore last session", action: #selector(restoreSessionChanged(_:)))
            ),
        ]))

        sections.append(notificationsSection(form, defaults: defaults))
        sections.append(projectDirectoriesSection(form))
        sections.append(keybindingBehaviorSection(form))
        return sections
    }

    private func notificationsSection(_ form: SettingsForm, defaults: AppSettings) -> NSView {
        let sound = form.row(
            "Play a sound",
            description: "Play the system sound with each notification.",
            reset: reset(["notifications", "sound"], isDefault: settings.notificationSound == defaults.notificationSound),
            control: switchControl(settings.notificationSound, label: "Play a sound", action: #selector(notificationSoundChanged(_:)))
        )
        // Permission lives in System Settings, and macOS only ever prompts
        // once. The row says where it stands and offers the way there.
        let fix = form.button("Open System Settings") {
            AgentNotificationManager.openSystemNotificationSettings()
        }
        let status = form.row("Checking permission", description: "Checking notification permission…", control: fix)
        notificationRow = status
        notificationFixButton = fix
        return form.section(
            "Notifications",
            note: "Banners for panes that are not focused, named window ▸ pane.",
            [sound, status]
        )
    }

    /// Describes the current permission and offers the way to System Settings
    /// where that can change anything.
    func refreshNotificationAuthorizationRow() {
        guard let notificationRow, let notificationFixButton else { return }
        let title: String
        let message: String
        var role: (Palette) -> NSColor = { $0.foreground }
        let offersSystemSettings: Bool
        switch AgentNotificationManager.authorization {
        case .authorized:
            title = "Notifications allowed"
            message = "macOS is allowed to show Soprano notifications."
            role = { $0.successForeground }
            offersSystemSettings = true
        case .denied:
            title = "Notifications blocked"
            message = "macOS is blocking Soprano notifications. Panes still show status "
                + "and an unread ring, but no banner appears."
            role = { $0.errorForeground }
            offersSystemSettings = true
        case .notDetermined:
            title = "Not asked yet"
            message = "macOS has not been asked yet. The prompt appears the first time "
                + "an unfocused pane wants you."
            offersSystemSettings = false
        case .unavailable:
            title = "Notifications unavailable"
            message = "Notifications need the packaged app; unbundled builds cannot post them."
            offersSystemSettings = false
        case nil:
            title = "Checking permission"
            message = "Checking notification permission…"
            offersSystemSettings = false
        }
        notificationRow.titleLabel.stringValue = title
        notificationRow.titleLabel.role = role
        notificationRow.setDescription(message)
        notificationFixButton.isHidden = !offersSystemSettings
    }

    private func projectDirectoriesSection(_ form: SettingsForm) -> NSView {
        let input = SettingsInputField(placeholder: "Folder path", font: Typography.mono(Typography.rowSize))
        input.field.identifier = NSUserInterfaceItemIdentifier("projects.add")
        input.field.target = self
        input.field.action = #selector(addProjectDirectory)
        input.field.cell?.sendsActionOnEndEditing = false
        input.field.setAccessibilityLabel("Folder path")
        input.setContentHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectDirectoryInput = input.field

        let browse = SettingsButton("Browse…") { [weak self] in self?.browseProjectDirectory() }
        let add = SettingsButton("Add", variant: .primary) { [weak self] in self?.addProjectDirectory() }
        projectDirectoryAddRow = SettingsActionsRowView(views: [input, browse, add], fills: true)

        let group = SettingsGroupView(rows: [])
        projectDirectoriesGroup = group
        projectDirectoriesForm = form
        rebuildProjectDirectoriesList()
        return form.section(
            "Project directories",
            note: "Directories available to project-aware features.",
            group: group
        )
    }

    /// Re-lists the directories in place, keeping the add row (and what is
    /// typed into it) instead of rebuilding the page.
    private func rebuildProjectDirectoriesList() {
        guard let group = projectDirectoriesGroup, let form = projectDirectoriesForm, let addRow = projectDirectoryAddRow else { return }

        // The list shows what the FILE says, not the resolved result: a root
        // on an unmounted volume is dropped during resolution, and rendering
        // the resolved list would make "Remove" renumber onto the wrong entry
        // and a later write delete the missing root for good.
        let directories = configuredProjectDirectories
        var rows: [NSView] = []
        if directories.isEmpty {
            rows.append(form.row(
                "No project directories",
                description: "Add a folder below, or list them under \"projectDirectories\" in settings.json."
            ))
        }
        for (index, directory) in directories.enumerated() {
            var isDirectory: ObjCBool = false
            let isReachable = FileManager.default.fileExists(
                atPath: SopranoConfig.expandPath(directory),
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
            let remove = form.button("Remove", size: .xs) { [weak self] in self?.removeProjectDirectory(at: index) }
            let row = form.row(
                directory,
                description: isReachable ? nil : "Not found",
                descriptionRole: { $0.warningForeground },
                control: remove
            )
            row.titleLabel.font = Typography.mono(Typography.rowSize, weight: .medium)
            row.titleLabel.lineBreakMode = .byTruncatingMiddle
            rows.append(row)
        }
        rows.append(addRow)
        group.setRows(rows)
        if view.window != nil {
            view.layoutSubtreeIfNeeded()
            fitDocument()
        }
    }

    private func keybindingBehaviorSection(_ form: SettingsForm) -> NSView {
        let defaults = DefaultKeybindings.config
        let prefix = SettingsPrefixKeyControl(
            key: keybindingConfig.prefixKey,
            target: self,
            action: #selector(prefixKeyRecorded(_:))
        )

        let timeoutLimits = SopranoConfig.Limits.prefixTimeoutMs
        let timeout = numberField(
            "\(keybindingConfig.prefixTimeoutMs)",
            width: 80,
            identifier: "keybindings.prefixTimeoutMs",
            label: "Prefix timeout in milliseconds",
            action: #selector(prefixTimeoutCommitted(_:))
        )
        let resizeLimits = SopranoConfig.Limits.resizeTickPercent
        let resize = numberField(
            "\(Int(keybindingConfig.resizeTickPercent))",
            width: 64,
            identifier: "keybindings.resizeTickPercent",
            label: "Resize step in percent",
            action: #selector(resizeStepCommitted(_:))
        )
        let legend = SettingsKeycaps.prefixLegend(keybindingConfig.prefixKey)
        return form.section("Keybindings", [
            form.row(
                "Prefix key",
                description: "⌃ + this key starts a prefix chord: \(legend), then the key. Click it and press a key to change it.",
                reset: reset(["keybindings", "prefixKey"], isDefault: keybindingConfig.prefixKey == defaults.prefixKey),
                control: prefix
            ),
            form.row(
                "Prefix timeout",
                description: "Milliseconds the prefix waits for its key (\(timeoutLimits.lowerBound)–\(timeoutLimits.upperBound)).",
                reset: reset(["keybindings", "prefixTimeoutMs"], isDefault: keybindingConfig.prefixTimeoutMs == defaults.prefixTimeoutMs),
                control: timeout
            ),
            form.row(
                "Resize step",
                description: "Percent of the window a pane grows or shrinks per resize key (\(resizeLimits.lowerBound)–\(resizeLimits.upperBound)).",
                reset: reset(["keybindings", "resizeTickPercent"], isDefault: keybindingConfig.resizeTickPercent == defaults.resizeTickPercent),
                control: resize
            ),
        ])
    }

    private func numberField(_ value: String, width: CGFloat, identifier: String, label: String, action: Selector) -> SettingsInputField {
        let input = SettingsInputField(value: value, width: width, font: Typography.tabular(Typography.bodySize))
        let field = input.field
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
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
        field.target = self
        field.action = action
        field.cell?.sendsActionOnEndEditing = true
        field.setAccessibilityLabel(label)
        return input
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

    @objc private func themeChanged(_ sender: SettingsSelectButton) {
        guard let id = sender.selectedValue, AppTheme.isKnownId(id) else { return }
        settings.themeId = id
        configStore.write(id, at: ["theme"])

        // The shared store observer normally applies the theme during write().
        // Standalone settings controllers used in tests and previews have no
        // observer, so retain the local fallback without applying it twice.
        if themeManager.themeId != id {
            themeManager.setTheme(id: id)
        }
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
    }

    @objc private func restoreSessionChanged(_ sender: SettingsSwitch) {
        settings.restoreLastSession = sender.state == .on
        configStore.write(settings.restoreLastSession, at: ["restoreLastSession"])
    }

    @objc private func hideWindowBarChanged(_ sender: SettingsSwitch) {
        settings.hideWindowBar = sender.state == .on
        configStore.write(settings.hideWindowBar, at: ["hideWindowBar"])
    }

    @objc private func hideWindowTabsChanged(_ sender: SettingsSwitch) {
        settings.hideWindowTabs = sender.state == .on
        configStore.write(settings.hideWindowTabs, at: ["hideWindowTabs"])
    }

    @objc private func statusBarUptimeChanged(_ sender: SettingsSwitch) {
        settings.statusBarUptime = sender.state == .on
        configStore.write(settings.statusBarUptime, at: ["statusBar", "uptime"])
    }

    @objc private func notificationSoundChanged(_ sender: SettingsSwitch) {
        settings.notificationSound = sender.state == .on
        configStore.write(settings.notificationSound, at: ["notifications", "sound"])
    }

    private func browseProjectDirectory() {
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
        // Adopt the change before the store echoes it back, so `update` sees
        // nothing new and leaves the page (and its scroll position) alone.
        settings.projectDirectories.append(path)
        writeProjectDirectories(directories)
        projectDirectoryInput?.stringValue = ""
        rebuildProjectDirectoriesList()
    }

    private func removeProjectDirectory(at index: Int) {
        var directories = configuredProjectDirectories
        guard directories.indices.contains(index) else { return }
        let removed = SopranoConfig.expandPath(directories.remove(at: index))
        if !directories.contains(where: { SopranoConfig.expandPath($0) == removed }) {
            settings.projectDirectories.removeAll { $0 == removed }
        }
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

    private func keyboardShortcutsPage(_ form: SettingsForm) -> [NSView] {
        var sections: [NSView] = []
        let filter = SettingsInputField(value: shortcutQuery, placeholder: "Search shortcuts", width: form.width, height: 32)
        filter.field.identifier = Self.filterIdentifier
        filter.field.setAccessibilityLabel("Search shortcuts")
        filter.onChange = { [weak self] text in self?.setShortcutQuery(text) }
        sections.append(filter)

        if shortcutQuery.isEmpty {
            sections.append(form.section(nil, [
                form.row(
                    "Keyboard shortcuts",
                    description: "The shortcuts in effect. Rebind any of them by id under \"keybindings.bindings\" in settings.json — for example \"\(exampleBindingId)\": \"\(exampleBindingChord)\" — or set one to null to turn it off.",
                    control: openFileButton(form)
                ),
            ]))
        }

        let groups: [(title: String, category: KeyBindingCategory)] = [
            ("Navigation", .navigation),
            ("Layout & splits", .layout),
            ("Agent launchers", .agents),
            ("General", .general),
        ]
        let customized = configStore.resolved.customizedBindingIds
        let disabledIds = configStore.resolved.disabledBindingIds
        var anyMatch = false
        for (groupTitle, category) in groups {
            let active = keybindingConfig.bindings.filter { $0.category == category }
            // Disabled bindings still belong on this list: a shortcut that is
            // missing because the file switched it off should be visibly off,
            // not simply absent.
            let disabled = DefaultKeybindings.config.bindings.filter {
                $0.category == category && disabledIds.contains($0.id)
            }
            let entries = (active.map { ($0, false) } + disabled.map { ($0, true) })
                .filter { shortcutMatches($0.0, isDisabled: $0.1) }
            guard !entries.isEmpty else { continue }
            anyMatch = true
            sections.append(form.section(groupTitle, entries.map { binding, isDisabled in
                shortcutRow(binding, isCustomized: customized.contains(binding.id), isDisabled: isDisabled, form: form)
            }))
        }
        if !anyMatch {
            sections.append(form.section(nil, [
                form.row("No matching shortcuts", description: "Try an action name, id or shortcut."),
            ]))
        }
        return sections
    }

    private func setShortcutQuery(_ query: String) {
        guard query != shortcutQuery else { return }
        shortcutQuery = query
        scheduleRebuild()
    }

    /// Bindings matching the filter: label, id, description or keys.
    private func shortcutMatches(_ binding: KeyBinding, isDisabled: Bool) -> Bool {
        let needle = shortcutQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let caps = isDisabled ? [] : SettingsKeycaps.alternatives(for: binding, prefixKey: keybindingConfig.prefixKey)
            .map { $0.joined(separator: " ") }
        return ([binding.label, binding.id, binding.description] + caps).contains { $0.lowercased().contains(needle) }
    }

    private func shortcutRow(_ binding: KeyBinding, isCustomized: Bool, isDisabled: Bool, form: SettingsForm) -> NSView {
        let control: NSView = isDisabled
            ? SettingsLabel("Off", size: Typography.smallSize) { $0.mutedForeground.withAlphaComponent(0.7) }
            : SettingsKeycapsView(alternatives: SettingsKeycaps.alternatives(for: binding, prefixKey: keybindingConfig.prefixKey))
        let id = binding.id
        let row = form.row(
            binding.label,
            description: "\(binding.id) · \(binding.description)",
            titleRole: isDisabled ? { $0.mutedForeground } : nil,
            reset: isCustomized || isDisabled ? { [weak self] in self?.configStore.remove(at: ["keybindings", "bindings", id]) } : nil,
            control: control
        )
        if isCustomized { row.toolTip = "Customized in settings.json" }
        return row
    }

    /// A real, currently-bound action to show in the page's instructions, so
    /// the example always names something the reader can find in the list.
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

    // MARK: - Agent Profiles

    private func agentProfilesPage(_ form: SettingsForm) -> [NSView] {
        let intro = form.section(nil, [
            form.row(
                "Agent profiles",
                description: "The agents Soprano can launch. Add your own under \"agents\" in settings.json — for example { \"id\": \"aider\", \"name\": \"Aider\", \"command\": \"aider\", \"launchKey\": \"cmd+4\" }. Reusing a built-in id patches that profile instead of creating a new one.",
                control: openFileButton(form)
            ),
        ])
        let configured = configStore.resolved.configuredAgentIds
        let rows = AgentCatalog.all.map { profile in
            let ready = profile.patterns?.ready?.joined(separator: ", ") ?? "–"
            let error = profile.patterns?.error?.joined(separator: ", ") ?? "–"
            return SettingsAgentProfileRowView(
                name: profile.name,
                color: profile.nsColor,
                description: profile.description,
                command: "$ \(([profile.command] + profile.args).joined(separator: " "))",
                patterns: "Ready: \(ready)  ·  Error: \(error)",
                badge: configured.contains(profile.id) ? "settings.json" : nil,
                width: form.width
            )
        }
        return [intro, form.section("Profiles", rows)]
    }

    // MARK: - Accounts

    private static let accountsIntro = "Sign in to several Claude and Codex accounts. omp balances across its accounts; Claude Code and the Codex CLI use the one you choose."

    private func accountsPage(_ form: SettingsForm) -> [NSView] {
        let snapshot = accounts.snapshot
        let refresh = form.button(snapshot.isRefreshing ? "Refreshing…" : "Refresh", size: .xs) { [accounts] in
            accounts.refresh(force: true)
        }
        refresh.isEnabled = !snapshot.isRefreshing
        let updated = SettingsLabel(Self.accountsRefreshText(snapshot), size: Typography.smallSize) { $0.mutedForeground }
        var sections = [form.section(nil, [
            form.row("Accounts", description: Self.accountsIntro, control: form.group([updated, refresh], spacing: 10)),
        ])]
        for listID in AccountListID.all {
            sections.append(accountListSection(listID, snapshot: snapshot, form: form))
        }
        return sections
    }

    /// "Updated 4m ago": recomputed on every rebuild, which each refresh
    /// triggers, so it never needs a timer of its own.
    static func accountsRefreshText(_ snapshot: AccountsSnapshot, now: Date = Date()) -> String {
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

    private func accountListSection(_ listID: AccountListID, snapshot: AccountsSnapshot, form: SettingsForm) -> NSView {
        var rows: [NSView] = []
        if let error = snapshot.errors[listID] {
            let dismiss = form.button("Dismiss", variant: .ghost, size: .xs) { [accounts] in
                accounts.dismissError(in: listID)
            }
            rows.append(form.row("Something went wrong", description: error, descriptionRole: { $0.errorForeground }, control: dismiss))
        }

        let list = snapshot.lists[listID]
        if let list, let reason = list.unavailableReason {
            rows.append(form.row("Unavailable", description: reason))
        } else if let list {
            rows.append(defaultAccountRow(list, form: form))
            for account in list.accounts {
                rows.append(accountRow(account, in: list, snapshot: snapshot, form: form))
            }
        } else {
            rows.append(form.row(snapshot.isRefreshing ? "Loading accounts…" : "Accounts not loaded yet."))
        }
        rows.append(accountListFooter(listID, list: list, snapshot: snapshot, form: form))

        return form.section(
            "\(listID.provider.displayName) · \(listID.tool.displayName)",
            note: Self.accountListNote(listID.tool),
            rows
        )
    }

    private static func accountListNote(_ tool: AccountTool) -> String {
        switch tool {
        case .omp:
            return "omp uses every account and fails over when one runs out. New omp panes try the preferred account first."
        case .claudeCode:
            return "Choosing an account signs Claude Code in with it on this Mac; running claude sessions switch too. System default is the login Claude Code had before."
        case .codexCLI:
            return "New codex panes use the chosen account; running panes keep theirs. History, config and skills stay shared."
        }
    }

    /// "Automatic" for omp, "System default" for the CLIs: the choice that
    /// leaves the tool to its own login.
    private func defaultAccountRow(_ list: AccountList, form: SettingsForm) -> NSView {
        let isSelected = list.selectedAccountId == nil
        let listID = list.id
        let title: String
        let detail: String
        var problem: String?
        if listID.tool == .omp {
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
        var buttons: [NSView] = []
        if !isSelected {
            buttons.append(form.button(listID.tool == .omp ? "Automatic" : "Use", size: .xs) { [accounts] in
                accounts.select(accountId: nil, in: listID)
            })
        }
        return SettingsAccountEntryRowView(
            title: title,
            isSelected: isSelected,
            badge: isSelected ? "Active" : nil,
            detail: detail,
            problem: problem,
            control: buttons.isEmpty ? nil : form.group(buttons),
            width: form.width
        )
    }

    private func accountRow(_ account: AccountRow, in list: AccountList, snapshot: AccountsSnapshot, form: SettingsForm) -> NSView {
        let listID = list.id
        let accountId = account.id
        let isSelected = list.selectedAccountId == accountId
        var buttons: [NSView] = []
        if !isSelected {
            buttons.append(form.button(listID.tool == .omp ? "Prefer" : "Use", size: .xs) { [accounts] in
                accounts.select(accountId: accountId, in: listID)
            })
        }
        let reauthenticate = form.button("Re-authenticate", size: .xs) { [accounts] in
            accounts.reauthenticate(accountId: accountId, in: listID)
        }
        // One browser sign-in at a time, across every list.
        reauthenticate.isEnabled = snapshot.pendingLogin == nil
        buttons.append(reauthenticate)
        buttons.append(form.button("Remove", variant: .destructiveOutline, size: .xs) { [weak self] in
            self?.confirmRemoveAccount(account, from: listID)
        })
        return SettingsAccountEntryRowView(
            title: account.identity.email,
            isSelected: isSelected,
            badge: isSelected ? (listID.tool == .omp ? "Preferred" : "Active") : nil,
            detail: Self.accountDetailParts(account).joined(separator: "  ·  "),
            problem: account.problem,
            control: form.group(buttons),
            width: form.width
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

    /// The running sign-in for this list, or the button that starts one.
    private func accountListFooter(_ listID: AccountListID, list: AccountList?, snapshot: AccountsSnapshot, form: SettingsForm) -> NSView {
        if let pending = snapshot.pendingLogin, pending.list == listID {
            let email = pending.accountId.flatMap { id in list?.accounts.first { $0.id == id }?.identity.email }
            let text = email.map { "Waiting for sign-in in your browser to re-authenticate \($0)…" }
                ?? "Waiting for sign-in in your browser…"
            var buttons: [NSView] = []
            if let url = pending.signInURL {
                buttons.append(form.button("Open Sign-in Page", size: .xs) {
                    _ = NSWorkspace.shared.open(url)
                })
            }
            buttons.append(form.button("Cancel", variant: .ghost, size: .xs) { [accounts] in
                accounts.cancelLogin()
            })
            return form.row(
                text,
                description: pending.signInURL == nil
                    ? "Finish signing in in the browser window that opened."
                    : "If no browser window opened, open the sign-in page yourself.",
                control: form.group(buttons)
            )
        }
        let add = form.button("Add Account", symbol: "plus", variant: .primary, size: .xs) { [accounts] in
            accounts.addAccount(to: listID)
        }
        // One browser sign-in at a time, across every list.
        add.isEnabled = snapshot.pendingLogin == nil
        return SettingsActionsRowView(views: [add])
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
        let accountId = account.id
        let source = accounts
        ShellDialogs.confirm(
            title: "Remove \(account.identity.email)?",
            message: Self.accountRemovalExplanation(listID.tool),
            confirmTitle: "Remove",
            isDestructive: true,
            in: view.window
        ) { confirmed in
            guard confirmed else { return }
            source.remove(accountId: accountId, from: listID)
        }
    }

    // MARK: - About

    private func aboutPage(_ form: SettingsForm) -> [NSView] {
        let about = form.section("About", [
            form.row("Version", description: "Current version of the application.", control: form.value(AppVersion.current)),
            form.row("Runtime", description: "AI agent orchestration platform.", control: form.value("Swift + AppKit + libghostty")),
            form.row(
                "Settings file",
                description: configStore.displayPath,
                mono: true,
                control: form.group([
                    openFileButton(form),
                    form.button("Show in Finder", variant: .ghost) { [weak self] in self?.configStore.revealInFinder() },
                    form.button("Reload", variant: .ghost) { [weak self] in
                        self?.configStore.reloadFromDisk()
                        self?.rebuildCurrentTab(resetScroll: false)
                    },
                ])
            ),
        ])
        let quickReference = form.section("Quick reference", quickReferenceBindings().map { binding in
            form.row(
                binding.label,
                control: SettingsKeycapsView(alternatives: SettingsKeycaps.alternatives(for: binding, prefixKey: keybindingConfig.prefixKey))
            )
        })
        return [about, quickReference]
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
}

/// The settings screen's root: flipped, so the page reads from the top.
private final class SettingsRootView: NSView {
    override var isFlipped: Bool { true }
}

/// An agent profile row: a color dot and the name (with a `settings.json`
/// badge when the file configures it), the description, then the command and
/// the status patterns in mono.
final class SettingsAgentProfileRowView: NSView {
    init(name: String, color: NSColor, description: String, command: String, patterns: String, badge: String?, width: CGFloat) {
        super.init(frame: .zero)
        let dot = SettingsColorDot(color: color)
        let title = SettingsLabel(name, size: Typography.bodySize, weight: .medium)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [dot, title])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        if let badge { titleRow.addArrangedSubview(ComposerBadge(badge)) }

        let textWidth = max(120, width - 32)
        let descriptionLabel = SettingsLabel(description, size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
        descriptionLabel.preferredMaxLayoutWidth = textWidth
        let commandLabel = SettingsLabel(command, size: Typography.smallSize) { $0.foreground }
        commandLabel.font = Typography.mono(Typography.smallSize)
        commandLabel.lineBreakMode = .byTruncatingMiddle
        commandLabel.isSelectable = true
        let patternsLabel = SettingsLabel(patterns, size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
        patternsLabel.font = Typography.mono(Typography.tinySize)
        patternsLabel.preferredMaxLayoutWidth = textWidth

        let stack = NSStackView(views: [titleRow, descriptionLabel, commandLabel, patternsLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(6, after: descriptionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            commandLabel.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}

/// An 8 pt dot in a fixed color (an agent profile's color).
private final class SettingsColorDot: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8),
            heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Keycaps for Settings, built from the `KeyBinding` itself through the
/// palette's `MainWindowController.keycaps(for:prefixKey:)`, so a shortcut
/// reads the same in both places (`⌃⇥`, `⌘esc`, `↵`).
enum SettingsKeycaps {
    /// One cap list per alternative. Only a built-in binding whose
    /// `defaultKeys` lists several chords (`⌘+ / ⌘=`) has more than one; the
    /// bound chord keeps its place among them.
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
