import AppKit

/// The New Automation / Edit Automation sheet: a Folio floating surface on
/// the main window with the automation's name, prompt, agent, folder, where
/// runs work, session, schedule, grace, precheck, model and whether it is
/// enabled. Save stays disabled until the prompt, folder and schedule are
/// valid; Return in a one-line field saves and Esc cancels.
final class AutomationEditorPanel: NSPanel, NSTextFieldDelegate, NSTextViewDelegate {
    /// Writes the automation; false keeps the sheet open.
    var onSave: ((Automation) -> Bool)?
    /// The sheet is done, saved or cancelled; the presenter ends it.
    var onClose: (() -> Void)?

    private static let width: CGFloat = 620
    private static let padding: CGFloat = 20
    private static let labelWidth: CGFloat = 96
    private static let promptHeight: CGFloat = 148

    private enum Cadence: Int, CaseIterable {
        case hourly
        case daily
        case weekdays
        case weekly
        case custom

        var title: String {
            switch self {
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekdays: "Weekdays"
            case .weekly: "Weekly"
            case .custom: "Custom"
            }
        }
    }

    private static let graceOptions: [(minutes: Int, title: String)] = [
        (0, "No grace"), (30, "30 minutes"), (60, "1 hour"), (180, "3 hours"),
        (720, "12 hours"), (1_440, "24 hours"), (2_880, "48 hours"),
    ]
    private static let timeoutOptions: [(seconds: Int, title: String)] = [
        (30, "30 sec"), (60, "1 min"), (120, "2 min"), (300, "5 min"), (600, "10 min"),
    ]
    private static let chooseFolderTag = -1

    private var theme: AppTheme
    private let existing: Automation?
    private let existingIds: Set<String>
    private var folderChoices: [String]
    private var selectedFolder: String?

    private let surface = AutomationEditorSurfaceView()
    private let contentStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var formLabels: [NSTextField] = []
    private var fieldSurfaces: [ChromeFieldView] = []
    private var styledFields: [(field: NSTextField, font: NSFont, placeholder: String)] = []

    private let nameField = NSTextField(string: "")
    private let promptSurface: ChromeFieldView
    private let promptView = AutomationPromptTextView()
    private let promptNote = NSTextField(labelWithString: "")
    private let agentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folderNote = NSTextField(labelWithString: "")
    private let workspaceControl: ChromeSegmentedControl
    private let baseBranchField = NSTextField(string: "")
    private var baseBranchSurface: ChromeFieldView!
    private let sessionControl: ChromeSegmentedControl
    private let cadencePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let minuteLabel = NSTextField(labelWithString: "")
    private let minuteField = NSTextField(string: "")
    private var minuteSurface: ChromeFieldView!
    private let weekdayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var weekdaySurface: ChromeFieldView!
    private let timePicker = NSDatePicker()
    private var timeSurface: ChromeFieldView!
    private let cronField = NSTextField(string: "")
    private var cronSurface: ChromeFieldView!
    private let scheduleNote = NSTextField(labelWithString: "")
    private let gracePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let precheckField = NSTextField(string: "")
    private let timeoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelField = NSTextField(string: "")
    private let enabledSwitch: ChromeSwitch
    private let rule: ChromeRuleView
    private let footerLabel = NSTextField(labelWithString: "")
    private let cancelButton: ChromeButton
    private let saveButton: ChromeButton

    /// - Parameters:
    ///   - automation: the automation to edit; nil creates one.
    ///   - template: a template card's prefill for a new automation.
    ///   - automations: every automation, for unique ids and the folder list.
    ///   - projectDirectories: roots whose child folders the folder list offers.
    init(
        theme: AppTheme,
        automation: Automation?,
        template: AutomationTemplate?,
        automations: [Automation],
        projectDirectories: [String]
    ) {
        self.theme = theme
        existing = automation
        existingIds = Set(automations.map(\.id))
        folderChoices = Self.folderChoices(automations: automations, projectDirectories: projectDirectories)
        selectedFolder = automation?.folder
        promptSurface = ChromeFieldView(theme: theme)
        workspaceControl = ChromeSegmentedControl(titles: ["Folder", "New worktree"], theme: theme)
        sessionControl = ChromeSegmentedControl(titles: ["Fresh", "Reuse"], theme: theme)
        enabledSwitch = ChromeSwitch(isOn: automation?.enabled ?? true, theme: theme)
        rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        cancelButton = ChromeButton(title: "Cancel", theme: theme)
        saveButton = ChromeButton(title: automation == nil ? "Create" : "Save Changes", theme: theme, kind: .ink)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        autorecalculatesKeyViewLoop = true

        build()
        load(automation: automation, template: template)
        apply(theme: theme)
        refreshScheduleControls()
        refreshValidation()
        initialFirstResponder = nameField
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Folders

    /// Folders of existing automations first, then every child folder of the
    /// project directories, as Open Project lists them.
    private static func folderChoices(automations: [Automation], projectDirectories: [String]) -> [String] {
        var seen = Set<String>()
        var choices: [String] = []
        for folder in automations.map(\.folder) where seen.insert(folder).inserted {
            choices.append(folder)
        }
        var projects: [String] = []
        for root in projectDirectories {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                projects.append(child.standardizedFileURL.path)
            }
        }
        projects.sort {
            let order = ($0 as NSString).lastPathComponent.localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        for folder in projects where seen.insert(folder).inserted {
            choices.append(folder)
        }
        return choices
    }

    private func populateFolders() {
        folderPopup.removeAllItems()
        let menu = folderPopup.menu ?? NSMenu()
        if let selectedFolder, !folderChoices.contains(selectedFolder) {
            folderChoices.insert(selectedFolder, at: 0)
        }
        if selectedFolder == nil {
            let placeholder = NSMenuItem(title: "Choose a folder", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        }
        for folder in folderChoices {
            let item = NSMenuItem(title: AutomationFormat.path(folder), action: nil, keyEquivalent: "")
            item.representedObject = folder
            item.toolTip = folder
            menu.addItem(item)
        }
        if !folderChoices.isEmpty {
            menu.addItem(.separator())
        }
        let choose = NSMenuItem(title: "Choose Folder…", action: nil, keyEquivalent: "")
        choose.tag = Self.chooseFolderTag
        menu.addItem(choose)

        if let selectedFolder,
           let index = menu.items.firstIndex(where: { $0.representedObject as? String == selectedFolder }) {
            folderPopup.selectItem(at: index)
        } else {
            folderPopup.selectItem(at: 0)
        }
    }

    @objc private func folderChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        if item.tag == Self.chooseFolderTag {
            chooseFolder()
            return
        }
        selectedFolder = item.representedObject as? String
        populateFolders()
        refreshValidation()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder the automation's runs work in"
        if let selectedFolder {
            panel.directoryURL = URL(fileURLWithPath: selectedFolder, isDirectory: true)
        }
        panel.beginSheetModal(for: self) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK, let url = panel.url {
                    self.selectedFolder = url.standardizedFileURL.path
                }
                self.populateFolders()
                self.refreshValidation()
            }
        }
    }

    // MARK: - Building

    private func build() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = true
        root.autoresizingMask = [.width, .height]
        contentView = root

        surface.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(surface)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Chrome.Space.s12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(contentStack)

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(titleLabel)
        contentStack.setCustomSpacing(Chrome.Space.s16, after: titleLabel)

        // Name
        nameField.identifier = NSUserInterfaceItemIdentifier("automation-editor-name")
        addRow("Name", fieldSurface(nameField, font: ChromeFont.row, placeholder: "Weekday repo audit"), fills: true)

        // Prompt
        promptView.delegate = self
        promptView.placeholder = "Review the repository health and summarize what needs attention."
        promptView.onCancel = { [weak self] in self?.cancel() }
        promptView.onFocusChange = { [weak self] focused in self?.promptSurface.isFocused = focused }
        promptView.isRichText = false
        promptView.allowsUndo = true
        promptView.drawsBackground = false
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.textContainerInset = NSSize(width: 4, height: 6)
        promptView.isVerticallyResizable = true
        promptView.isHorizontallyResizable = false
        promptView.autoresizingMask = [.width]
        promptView.minSize = .zero
        promptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        promptView.textContainer?.widthTracksTextView = true
        promptView.setAccessibilityLabel("Prompt")
        let promptScroll = NSScrollView()
        promptScroll.drawsBackground = false
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = true
        promptScroll.borderType = .noBorder
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptView.frame = NSRect(x: 0, y: 0, width: Self.width - Self.labelWidth - 60, height: Self.promptHeight)
        promptScroll.documentView = promptView
        promptSurface.addSubview(promptScroll)
        NSLayoutConstraint.activate([
            promptSurface.heightAnchor.constraint(equalToConstant: Self.promptHeight),
            promptScroll.leadingAnchor.constraint(equalTo: promptSurface.leadingAnchor, constant: 2),
            promptScroll.trailingAnchor.constraint(equalTo: promptSurface.trailingAnchor, constant: -2),
            promptScroll.topAnchor.constraint(equalTo: promptSurface.topAnchor, constant: 2),
            promptScroll.bottomAnchor.constraint(equalTo: promptSurface.bottomAnchor, constant: -2),
        ])
        fieldSurfaces.append(promptSurface)
        addRow("Prompt", column([promptSurface, note(promptNote)]), fills: true)

        // Agent
        agentPopup.setAccessibilityLabel("Agent")
        addRow("Agent", popupSurface(agentPopup, width: 220, action: #selector(agentChanged(_:))), fills: false)

        // Folder
        folderPopup.setAccessibilityLabel("Folder")
        let folderSurface = popupSurface(folderPopup, width: nil, font: ChromeFont.mono, action: #selector(folderChanged(_:)))
        addRow("Folder", column([folderSurface, note(folderNote)]), fills: true)

        // Runs in
        workspaceControl.target = self
        workspaceControl.action = #selector(workspaceChanged(_:))
        workspaceControl.setAccessibilityLabel("Runs in")
        baseBranchSurface = fieldSurface(baseBranchField, font: ChromeFont.mono, placeholder: "origin's default branch", width: 220)
        baseBranchField.setAccessibilityLabel("Base branch")
        baseBranchField.toolTip = "The branch each run's worktree starts from"
        addRow("Runs in", line([workspaceControl, baseBranchSurface]), fills: false)

        // Session
        sessionControl.target = self
        sessionControl.action = #selector(sessionChanged(_:))
        sessionControl.setAccessibilityLabel("Session")
        addRow("Session", sessionControl, fills: false)

        // Schedule
        cadencePopup.setAccessibilityLabel("Schedule")
        cadencePopup.addItems(withTitles: Cadence.allCases.map(\.title))
        let cadenceSurface = popupSurface(cadencePopup, width: 128, action: #selector(cadenceChanged(_:)))
        minuteLabel.setContentHuggingPriority(.required, for: .horizontal)
        minuteSurface = fieldSurface(minuteField, font: ChromeFont.sans(size: 12, tabular: true), placeholder: "0", width: 52)
        minuteField.setAccessibilityLabel("Minute past the hour")
        minuteField.toolTip = "0–59"
        weekdayPopup.setAccessibilityLabel("Day")
        weekdayPopup.addItems(withTitles: Calendar.current.weekdaySymbols)
        weekdaySurface = popupSurface(weekdayPopup, width: 128, action: #selector(scheduleInputChanged(_:)))
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.isBezeled = false
        timePicker.isBordered = false
        timePicker.drawsBackground = false
        timePicker.font = ChromeFont.sans(size: 12, tabular: true)
        timePicker.target = self
        timePicker.action = #selector(scheduleInputChanged(_:))
        timePicker.setAccessibilityLabel("Time")
        timePicker.translatesAutoresizingMaskIntoConstraints = false
        timeSurface = ChromeFieldView(theme: theme)
        timeSurface.addSubview(timePicker)
        NSLayoutConstraint.activate([
            timeSurface.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            timePicker.leadingAnchor.constraint(equalTo: timeSurface.leadingAnchor, constant: 6),
            timePicker.trailingAnchor.constraint(equalTo: timeSurface.trailingAnchor, constant: -2),
            timePicker.centerYAnchor.constraint(equalTo: timeSurface.centerYAnchor),
        ])
        fieldSurfaces.append(timeSurface)
        cronSurface = fieldSurface(cronField, font: ChromeFont.mono, placeholder: "0 9 * * 1-5", width: 260)
        cronField.setAccessibilityLabel("Cron schedule")
        let scheduleLine = line([cadenceSurface, minuteLabel, minuteSurface, weekdaySurface, timeSurface, cronSurface])
        addRow("Schedule", column([scheduleLine, note(scheduleNote)]), fills: true)

        // Grace
        gracePopup.setAccessibilityLabel("Grace")
        gracePopup.toolTip = "How late a run due while the Mac slept or Soprano was closed may still start"
        addRow("Grace", popupSurface(gracePopup, width: 160, action: #selector(scheduleInputChanged(_:))), fills: false)

        // Precheck
        precheckField.setAccessibilityLabel("Precheck")
        precheckField.toolTip = "A shell command run in the folder before each scheduled run; the run starts only when it exits 0"
        timeoutPopup.setAccessibilityLabel("Precheck timeout")
        timeoutPopup.toolTip = "How long the precheck may take"
        let precheckSurface = fieldSurface(precheckField, font: ChromeFont.mono, placeholder: "gh pr list --json number -q '.[0].number'")
        precheckSurface.setContentHuggingPriority(.init(1), for: .horizontal)
        let precheckLine = line([precheckSurface, popupSurface(timeoutPopup, width: 104, action: #selector(scheduleInputChanged(_:)))])
        precheckLine.distribution = .fill
        addRow("Precheck", precheckLine, fills: true)

        // Model
        modelField.setAccessibilityLabel("Model")
        addRow("Model", fieldSurface(modelField, font: ChromeFont.label, placeholder: "CLI default", width: 220), fills: false)

        // Enabled
        enabledSwitch.setAccessibilityLabel("Enabled")
        addRow("Enabled", enabledSwitch, fills: false)

        // Footer
        contentStack.setCustomSpacing(Chrome.Space.s16, after: contentStack.arrangedSubviews.last ?? titleLabel)
        contentStack.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = AutomationViews.spreadRow(leading: [footerLabel], trailing: [cancelButton, saveButton])
        contentStack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: Self.padding),
            contentStack.topAnchor.constraint(equalTo: surface.topAnchor, constant: Self.padding),
            contentStack.widthAnchor.constraint(equalToConstant: Self.width - Self.padding * 2),
        ])
    }

    /// `Name   [field          ]`: a muted label column and the control,
    /// which either fills the row or keeps its own width.
    private func addRow(_ title: String, _ control: NSView, fills: Bool) {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        formLabels.append(label)
        // The label sits on the control's first line, whatever its height.
        let labelBox = NSView()
        labelBox.translatesAutoresizingMaskIntoConstraints = false
        labelBox.addSubview(label)
        NSLayoutConstraint.activate([
            labelBox.widthAnchor.constraint(equalToConstant: Self.labelWidth),
            labelBox.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            label.leadingAnchor.constraint(equalTo: labelBox.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: labelBox.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: labelBox.centerYAnchor),
        ])
        var views = [labelBox, control]
        if fills {
            control.setContentHuggingPriority(.init(1), for: .horizontal)
        } else {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            views.append(spacer)
        }
        let wrapper = NSStackView(views: views)
        wrapper.orientation = .horizontal
        wrapper.alignment = .top
        wrapper.distribution = .fill
        wrapper.spacing = Chrome.Space.s12
        contentStack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    /// A control above its validation note. Field surfaces take the full
    /// width; a line of controls keeps its own.
    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Chrome.Space.s4
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views where view is ChromeFieldView {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for view in views where view is NSTextField {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// Controls side by side; hidden ones drop out.
    private func line(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Chrome.Space.s8
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func note(_ label: NSTextField) -> NSTextField {
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func fieldSurface(_ field: NSTextField, font: NSFont, placeholder: String, width: CGFloat? = nil) -> ChromeFieldView {
        let fieldSurface = ChromeFieldView(theme: theme)
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldSurface.addSubview(field)
        var constraints = [
            fieldSurface.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            field.leadingAnchor.constraint(equalTo: fieldSurface.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: fieldSurface.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: fieldSurface.centerYAnchor),
        ]
        if let width {
            constraints.append(fieldSurface.widthAnchor.constraint(equalToConstant: width))
        }
        NSLayoutConstraint.activate(constraints)
        fieldSurfaces.append(fieldSurface)
        styledFields.append((field, font, placeholder))
        return fieldSurface
    }

    /// A borderless popup on a field surface, as Settings draws its selects.
    private func popupSurface(
        _ popup: NSPopUpButton,
        width: CGFloat?,
        font: NSFont = ChromeFont.label,
        action: Selector
    ) -> ChromeFieldView {
        popup.target = self
        popup.action = action
        popup.isBordered = false
        popup.font = font
        popup.autoenablesItems = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        let select = ChromeFieldView(theme: theme)
        select.addSubview(popup)
        var constraints = [
            select.heightAnchor.constraint(equalToConstant: Chrome.fieldHeight),
            popup.leadingAnchor.constraint(equalTo: select.leadingAnchor, constant: 6),
            popup.trailingAnchor.constraint(equalTo: select.trailingAnchor, constant: -4),
            popup.centerYAnchor.constraint(equalTo: select.centerYAnchor),
        ]
        if let width {
            constraints.append(select.widthAnchor.constraint(equalToConstant: width))
        }
        NSLayoutConstraint.activate(constraints)
        fieldSurfaces.append(select)
        return select
    }

    // MARK: - Values

    private func load(automation: Automation?, template: AutomationTemplate?) {
        nameField.stringValue = automation?.name ?? template?.name ?? ""
        promptView.string = automation?.prompt ?? template?.prompt ?? ""

        let agentIds = Automation.agentIds.filter { AgentCatalog.profile(for: $0) != nil }
        var choices = agentIds
        if let agentId = automation?.agentId, !choices.contains(agentId) {
            choices.insert(agentId, at: 0)
        }
        for agentId in choices {
            agentPopup.addItem(withTitle: AutomationFormat.agentName(agentId))
            agentPopup.lastItem?.representedObject = agentId
        }
        let agentId = automation?.agentId ?? (choices.contains("omp") ? "omp" : choices.first)
        if let index = agentPopup.itemArray.firstIndex(where: { $0.representedObject as? String == agentId }) {
            agentPopup.selectItem(at: index)
        }

        populateFolders()

        switch automation?.workspace ?? .folder {
        case .folder:
            workspaceControl.select(0)
        case .worktree(let baseBranch):
            workspaceControl.select(1)
            baseBranchField.stringValue = baseBranch ?? ""
        }
        sessionControl.select(automation?.session == .reuse ? 1 : 0)

        let cadence = automation?.cadence ?? template?.cadence ?? .weekdays(hour: 9, minute: 0)
        var hour = 9
        var minute = 0
        var weekday = 1
        switch cadence {
        case .hourly(let value):
            cadencePopup.selectItem(at: Cadence.hourly.rawValue)
            minute = value
        case .daily(let h, let m):
            cadencePopup.selectItem(at: Cadence.daily.rawValue)
            (hour, minute) = (h, m)
        case .weekdays(let h, let m):
            cadencePopup.selectItem(at: Cadence.weekdays.rawValue)
            (hour, minute) = (h, m)
        case .weekly(let day, let h, let m):
            cadencePopup.selectItem(at: Cadence.weekly.rawValue)
            (weekday, hour, minute) = (day % 7, h, m)
        case .custom(let expression):
            cadencePopup.selectItem(at: Cadence.custom.rawValue)
            cronField.stringValue = expression
        }
        minuteField.stringValue = "\(minute)"
        weekdayPopup.selectItem(at: weekday)
        setTime(hour: hour, minute: minute)

        let grace = automation?.graceMinutes ?? template?.graceMinutes ?? Automation.defaultGraceMinutes
        var graceOptions = Self.graceOptions
        if !graceOptions.contains(where: { $0.minutes == grace }) {
            graceOptions.append((grace, AutomationFormat.grace(grace)))
            graceOptions.sort { $0.minutes < $1.minutes }
        }
        for option in graceOptions {
            gracePopup.addItem(withTitle: option.title)
            gracePopup.lastItem?.tag = option.minutes
        }
        gracePopup.selectItem(withTag: grace)

        precheckField.stringValue = automation?.precheck ?? ""
        let timeout = automation?.precheckTimeoutSeconds ?? Automation.defaultPrecheckTimeoutSeconds
        var timeoutOptions = Self.timeoutOptions
        if !timeoutOptions.contains(where: { $0.seconds == timeout }) {
            timeoutOptions.append((timeout, AutomationFormat.timeout(timeout)))
            timeoutOptions.sort { $0.seconds < $1.seconds }
        }
        for option in timeoutOptions {
            timeoutPopup.addItem(withTitle: option.title)
            timeoutPopup.lastItem?.tag = option.seconds
        }
        timeoutPopup.selectItem(withTag: timeout)

        modelField.stringValue = automation?.model ?? ""
        refreshSessionControl()
    }

    private func setTime(hour: Int, minute: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        timePicker.dateValue = Calendar.current.date(from: components) ?? Date()
    }

    private var cadence: Cadence {
        Cadence(rawValue: cadencePopup.indexOfSelectedItem) ?? .weekdays
    }

    private var isWorktree: Bool { workspaceControl.selectedSegment == 1 }

    /// The schedule the controls describe, or why they describe none.
    private func schedule() -> Result<CronSchedule, CronSchedule.ParseError> {
        let time = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        let hour = time.hour ?? 9
        let minute = time.minute ?? 0
        let expression: String
        switch cadence {
        case .hourly:
            guard let value = Int(minuteField.stringValue.trimmingCharacters(in: .whitespaces)), (0...59).contains(value) else {
                return .failure(CronSchedule.ParseError(message: "Enter a minute from 0 to 59."))
            }
            expression = AutomationCadence.hourly(minute: value).expression
        case .daily:
            expression = AutomationCadence.daily(hour: hour, minute: minute).expression
        case .weekdays:
            expression = AutomationCadence.weekdays(hour: hour, minute: minute).expression
        case .weekly:
            expression = AutomationCadence.weekly(weekday: max(0, weekdayPopup.indexOfSelectedItem), hour: hour, minute: minute).expression
        case .custom:
            let text = cronField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                return .failure(CronSchedule.ParseError(message: "Enter a five-field cron, e.g. 0 9 * * 1-5."))
            }
            expression = text
        }
        do {
            return .success(try CronSchedule(parsing: expression))
        } catch let error as CronSchedule.ParseError {
            return .failure(error)
        } catch {
            return .failure(CronSchedule.ParseError(message: error.localizedDescription))
        }
    }

    private var trimmedPrompt: String {
        promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var folderExists: Bool {
        guard let selectedFolder else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: selectedFolder, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Refreshing

    private func refreshScheduleControls() {
        let cadence = cadence
        minuteLabel.isHidden = cadence != .hourly
        minuteSurface.isHidden = cadence != .hourly
        weekdaySurface.isHidden = cadence != .weekly
        timeSurface.isHidden = cadence == .hourly || cadence == .custom
        cronSurface.isHidden = cadence != .custom
    }

    /// Reuse hands a run to the previous run's agent in the same folder, so a
    /// worktree run is always fresh.
    private func refreshSessionControl() {
        baseBranchSurface.isHidden = !isWorktree
        sessionControl.setEnabled(!isWorktree, forSegment: 1)
        if isWorktree {
            sessionControl.select(0)
        }
        sessionControl.toolTip = isWorktree
            ? "Worktree runs always start a fresh agent"
            : "Reuse hands the prompt to the previous run's agent while it is open and idle"
    }

    private func refreshValidation() {
        let colors = theme.colors
        let promptValid = !trimmedPrompt.isEmpty
        promptNote.isHidden = promptValid
        promptNote.setChromeText("Enter the prompt the agent gets on every run.", font: ChromeFont.meta, color: colors.textMuted)

        if selectedFolder == nil {
            folderNote.isHidden = false
            folderNote.setChromeText("Choose the folder its runs work in.", font: ChromeFont.meta, color: colors.textMuted)
        } else if !folderExists {
            folderNote.isHidden = false
            folderNote.setChromeText("This folder doesn't exist.", font: ChromeFont.meta, color: colors.danger)
        } else {
            folderNote.isHidden = true
        }

        let schedule = schedule()
        switch schedule {
        case .success(let schedule):
            cronSurface.isInvalid = false
            minuteSurface.isInvalid = false
            if cadence != .custom {
                lastPresetExpression = schedule.expression
            }
            let next = schedule.nextOccurrence(after: Date()).map { "Next run \(AutomationFormat.dateTime($0))" }
            scheduleNote.setChromeText(next ?? "This schedule never runs.", font: ChromeFont.meta, color: colors.textMuted)
        case .failure(let error):
            cronSurface.isInvalid = cadence == .custom && !cronField.stringValue.isEmpty
            minuteSurface.isInvalid = cadence == .hourly
            scheduleNote.setChromeText(error.message, font: ChromeFont.meta, color: cadence == .custom && cronField.stringValue.isEmpty ? colors.textMuted : colors.danger)
        }

        var isValid = promptValid && folderExists
        if case .failure = schedule { isValid = false }
        saveButton.isEnabled = isValid
        resizeToFit()
    }

    /// Keeps the sheet as tall as its rows as notes and controls come and go,
    /// with its top edge where it is.
    private func resizeToFit() {
        contentStack.layoutSubtreeIfNeeded()
        let height = ceil(contentStack.fittingSize.height) + Self.padding * 2
        guard abs(height - frame.height) > 0.5 else { return }
        var newFrame = frame
        newFrame.origin.y += newFrame.height - height
        newFrame.size = NSSize(width: Self.width, height: height)
        setFrame(newFrame, display: true)
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        surface.colors = colors
        titleLabel.setChromeText(existing == nil ? "New Automation" : "Edit Automation", font: ChromeFont.headline, color: colors.textPrimary)
        for label in formLabels {
            label.setChromeText(label.stringValue, font: ChromeFont.label, color: colors.textMuted)
        }
        for fieldSurface in fieldSurfaces {
            fieldSurface.apply(theme: theme)
        }
        for (field, font, placeholder) in styledFields {
            ChromeFieldView.styleEmbedded(field, colors: colors, font: font)
            ChromeFieldView.styleEditor(of: field, colors: colors)
            field.placeholderAttributedString = ChromeText.attributed(placeholder, font: font, color: colors.textMuted)
        }
        promptView.font = ChromeFont.row
        promptView.textColor = colors.textPrimary
        promptView.insertionPointColor = colors.caret
        promptView.selectedTextAttributes = [.backgroundColor: colors.textSelection]
        promptView.typingAttributes = [.font: ChromeFont.row, .foregroundColor: colors.textPrimary]
        promptView.placeholderColor = colors.textMuted
        timePicker.textColor = colors.textPrimary
        minuteLabel.setChromeText("at minute", font: ChromeFont.label, color: colors.textMuted)
        workspaceControl.apply(theme: theme)
        sessionControl.apply(theme: theme)
        enabledSwitch.apply(theme: theme)
        rule.color = colors.borderSubtle
        footerLabel.setChromeText("Runs on its own while Soprano is open, until you pause it.", font: ChromeFont.meta, color: colors.textMuted)
        cancelButton.apply(theme: theme)
        saveButton.apply(theme: theme)
        refreshValidation()
    }

    // MARK: - Actions

    @objc private func agentChanged(_ sender: NSPopUpButton) {
        refreshValidation()
    }

    @objc private func workspaceChanged(_ sender: ChromeSegmentedControl) {
        refreshSessionControl()
        refreshValidation()
    }

    @objc private func sessionChanged(_ sender: ChromeSegmentedControl) {
        refreshSessionControl()
    }

    @objc private func cadenceChanged(_ sender: NSPopUpButton) {
        // Custom starts from the preset it replaces, so a small change is easy.
        if cadence == .custom, cronField.stringValue.isEmpty {
            cronField.stringValue = lastPresetExpression ?? ""
        }
        refreshScheduleControls()
        refreshValidation()
    }

    /// The cron the preset controls described last, to seed Custom with.
    private var lastPresetExpression: String?

    @objc private func scheduleInputChanged(_ sender: Any?) {
        refreshValidation()
    }

    @objc private func cancelClicked() {
        cancel()
    }

    @objc private func saveClicked() {
        submit()
    }

    private func cancel() {
        onClose?()
    }

    private func submit() {
        guard saveButton.isEnabled,
              case .success(let schedule) = schedule(),
              let folder = selectedFolder,
              let agentId = agentPopup.selectedItem?.representedObject as? String
        else {
            NSSound.beep()
            return
        }
        func optional(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let name = optional(nameField.stringValue) ?? "Untitled automation"
        let workspace: Automation.Workspace = isWorktree ? .worktree(baseBranch: optional(baseBranchField.stringValue)) : .folder
        let automation = Automation(
            id: existing?.id ?? Automation.makeId(from: name, existing: existingIds),
            name: name,
            agentId: agentId,
            folder: folder,
            prompt: trimmedPrompt,
            schedule: schedule,
            enabled: enabledSwitch.isOn,
            workspace: workspace,
            session: !isWorktree && sessionControl.selectedSegment == 1 ? .reuse : .fresh,
            graceMinutes: gracePopup.selectedTag(),
            precheck: optional(precheckField.stringValue),
            precheckTimeoutSeconds: timeoutPopup.selectedTag(),
            model: optional(modelField.stringValue)
        )
        if onSave?(automation) == true {
            onClose?()
        }
    }

    // MARK: - Keyboard

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    /// Esc cancels and ⌘Return saves from any control, the prompt included.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown, event.keyCode == 53, flags.isEmpty, attachedSheet == nil {
            cancel()
            return true
        }
        if event.type == .keyDown, flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            submit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === minuteField || notification.object as? NSTextField === cronField {
            scheduleInputChanged(nil)
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        (field.superview as? ChromeFieldView)?.isFocused = true
        ChromeFieldView.styleEditor(of: field, colors: theme.colors)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        (field.superview as? ChromeFieldView)?.isFocused = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        refreshValidation()
    }
}

// MARK: - Surface

/// The sheet's floating surface: raised fill, 12 pt radius, the elevation
/// shadow's contact ring. It restyles its layer on every update, because
/// AppKit resets a backing layer's shadow when the appearance changes.
private final class AutomationEditorSurfaceView: NSView {
    var colors: ThemeColors? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer, let colors else { return }
        ChromeSurface.applyFloating(to: layer, colors: colors, radius: Chrome.Radius.panel, shadow: colors.shadowE3)
        layer.borderWidth = Chrome.hairline
        layer.borderColor = colors.borderSubtle.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Prompt

/// The multi-line prompt: a muted placeholder while empty, Tab moving on to
/// the next control instead of typing a tab, and Esc cancelling the sheet.
private final class AutomationPromptTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var placeholderColor: NSColor = .placeholderTextColor {
        didSet { needsDisplay = true }
    }
    var onCancel: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        let width = bounds.width - origin.x * 2
        ChromeText.attributed(
            placeholder,
            font: font ?? ChromeFont.row,
            color: placeholderColor,
            lineBreakMode: .byWordWrapping
        ).draw(in: NSRect(x: origin.x, y: origin.y, width: max(0, width), height: bounds.height - origin.y))
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
