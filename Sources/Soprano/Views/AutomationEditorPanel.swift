import AppKit

/// The New Automation / Edit Automation dialog: a Soprano Agents form dialog
/// (`OverlayWindow` card over the dimmed window, labelled fields, selects,
/// segmented controls and a switch, Cancel and Save in the footer) with the
/// automation's name, prompt, agent, model, folder, where runs work, schedule,
/// session, grace, precheck and whether it is enabled. Save stays disabled
/// until the prompt, folder and schedule are valid; Return in a one-line
/// field or ⌘Return saves, Esc cancels. A failed write shows above the
/// buttons and keeps the dialog open.
@MainActor
final class AutomationEditorPanel: NSObject {
    /// Writes the automation; false keeps the dialog open with an error.
    var onSave: ((Automation) -> Bool)?
    /// The dialog closed, saved or cancelled.
    var onClose: (() -> Void)?

    static let width: CGFloat = 560
    private static let promptHeight: CGFloat = 96

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
    /// The folder menu's values besides folder paths.
    private static let chooseFolderValue = "\u{1}choose"
    private static let noFolderValue = ""

    let window = ShellDialogOverlayWindow()
    private let existing: Automation?
    private let takenIds: Set<String>
    private var folderChoices: [String]
    private var selectedFolder: String?
    /// The cron the preset controls described last, to seed Custom with.
    private var lastPresetExpression: String?

    private let nameField = AutoUIInputField(placeholder: "Weekday repo audit")
    private let promptView: AutomationPromptTextView
    private let promptBox: AutoUITextBox
    private let promptNote = AutoUIThemedLabel("", size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
    private let agentSelect: AutoUISelectButton
    private let modelField = AutoUIInputField(placeholder: "CLI default", monospaced: true)
    private let folderSelect: AutoUISelectButton
    private let folderNote = AutoUIThemedLabel("", size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
    private let workspaceControl: AutoUISegmentedControl
    private let baseBranchField = AutoUIInputField(placeholder: "origin's default branch", monospaced: true)
    private let sessionControl: AutoUISegmentedControl
    private let cadenceSelect: AutoUISelectButton
    private let minuteLabel = AutoUIThemedLabel("at minute", size: Typography.rowSize) { $0.mutedForeground }
    private let minuteField = AutoUIInputField(placeholder: "0")
    private let weekdaySelect: AutoUISelectButton
    private let timeBox = AutomationTimeBox()
    private let cronField = AutoUIInputField(placeholder: "0 9 * * 1-5", monospaced: true)
    private let scheduleNote = AutoUIThemedLabel("", size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
    private let graceSelect: AutoUISelectButton
    private let precheckField = AutoUIInputField(placeholder: "gh pr list --json number -q '.[0].number'", monospaced: true)
    private let timeoutSelect: AutoUISelectButton
    private let enabledSwitch: AutoUISwitchControl
    private let errorLabel = AutoUIThemedLabel("", size: Typography.smallSize, wrapping: true) { $0.errorForeground }
    private let cancelButton = TextButton("Cancel", variant: .outline, size: .regular)
    private let saveButton: TextButton

    /// - Parameters:
    ///   - automation: the automation to edit; nil creates one.
    ///   - template: a template card's prefill for a new automation.
    ///   - automations: every automation, for the folder list.
    ///   - takenIds: every id in settings.json, valid or not, for a new id.
    ///   - projectDirectories: roots whose child folders the folder list offers.
    init(
        automation: Automation?,
        template: AutomationTemplate?,
        automations: [Automation],
        takenIds: Set<String>,
        projectDirectories: [String]
    ) {
        existing = automation
        self.takenIds = takenIds
        folderChoices = Self.folderChoices(automations: automations, projectDirectories: projectDirectories)
        selectedFolder = automation?.folder
        let promptView = AutomationPromptTextView()
        self.promptView = promptView
        promptBox = AutoUITextBox(textView: promptView, width: Self.width - 50)
        agentSelect = AutoUISelectButton(options: [], selected: "", width: nil, accessibilityLabel: "Agent")
        folderSelect = AutoUISelectButton(options: [], selected: "", width: nil, accessibilityLabel: "Folder", monospaced: true)
        workspaceControl = AutoUISegmentedControl(titles: ["Folder", "New worktree"], selectedIndex: 0, accessibilityLabel: "Runs in")
        sessionControl = AutoUISegmentedControl(titles: ["Fresh", "Reuse"], selectedIndex: 0, accessibilityLabel: "Session")
        cadenceSelect = AutoUISelectButton(
            options: Cadence.allCases.map { AutoUISelectOption(title: $0.title, value: "\($0.rawValue)") },
            selected: "\(Cadence.weekdays.rawValue)",
            width: 124,
            accessibilityLabel: "Schedule"
        )
        weekdaySelect = AutoUISelectButton(
            options: Calendar.current.weekdaySymbols.enumerated().map { AutoUISelectOption(title: $1, value: "\($0)") },
            selected: "1",
            width: 132,
            accessibilityLabel: "Day"
        )
        graceSelect = AutoUISelectButton(options: [], selected: "", width: nil, accessibilityLabel: "Grace")
        timeoutSelect = AutoUISelectButton(options: [], selected: "", width: 100, accessibilityLabel: "Precheck timeout")
        enabledSwitch = AutoUISwitchControl(isOn: automation?.enabled ?? true, label: "Enabled")
        saveButton = TextButton(automation == nil ? "Create" : "Save Changes", variant: .primary, size: .regular)
        super.init()

        load(automation: automation, template: template)
        build()
        refreshScheduleControls()
        refreshSessionControl()
        refreshValidation()
    }

    /// The dialog's card, for tests and the snapshot harness.
    private(set) var card: ShellDialogCardView?

    /// Shows the dialog over `parent` with the keyboard in the name field.
    func present(over parent: NSWindow) {
        window.owner = self
        window.present(over: parent, focus: nameField.field)
    }

    /// Sizes the dialog to `parent` without showing it (tests, snapshots).
    func layout(over parent: NSWindow) {
        window.cover(parent)
    }

    /// Closes the dialog without saving.
    func dismiss() {
        window.dismiss()
    }

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
        if let selectedFolder, !folderChoices.contains(selectedFolder) {
            folderChoices.insert(selectedFolder, at: 0)
        }
        var options: [AutoUISelectOption] = []
        if selectedFolder == nil {
            options.append(AutoUISelectOption(title: "Choose a folder", value: Self.noFolderValue, isEnabled: false))
        }
        for folder in folderChoices {
            options.append(AutoUISelectOption(title: AutomationFormat.path(folder), value: folder, toolTip: folder))
        }
        options.append(AutoUISelectOption(title: "Choose Folder…", value: Self.chooseFolderValue, separatorBefore: !options.isEmpty))
        folderSelect.setOptions(options, selected: selectedFolder ?? Self.noFolderValue)
        folderSelect.toolTip = selectedFolder
    }

    private func folderChanged(_ value: String) {
        if value == Self.chooseFolderValue {
            chooseFolder()
            return
        }
        selectedFolder = value.isEmpty ? nil : value
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
        panel.beginSheetModal(for: window) { [weak self] response in
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
        let card = ShellDialogCardView()
        self.card = card
        card.translatesAutoresizingMaskIntoConstraints = false
        window.backdrop.addSubview(card)
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: Self.width)
        preferredWidth.priority = .shellDialogPreferred
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: window.backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: window.backdrop.centerYAnchor),
            preferredWidth,
            card.widthAnchor.constraint(lessThanOrEqualTo: window.backdrop.widthAnchor, constant: -32),
            card.heightAnchor.constraint(lessThanOrEqualTo: window.backdrop.heightAnchor, constant: -32),
        ])
        let container = card.content
        window.autorecalculatesKeyViewLoop = true
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        let body = makeBody()

        // The form scrolls when the window is too short for it; the footer stays.
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        let document = AutomationFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        let fitsBody = scrollView.heightAnchor.constraint(equalTo: document.heightAnchor)
        fitsBody.priority = NSLayoutConstraint.Priority(440)

        let footer = ShellDialogFooterView()
        cancelButton.onClick = { [weak self] in self?.cancel() }
        saveButton.onClick = { [weak self] in self?.submit() }
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for view in [scrollView, footer, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(scrollView)
        container.addSubview(footer)
        footer.addSubview(buttons)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            document.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            fitsBody,

            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.topAnchor.constraint(equalTo: footer.topAnchor, constant: 16),
            buttons.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor, constant: 24),
        ])
    }

    private func makeBody() -> NSStackView {
        let title = AutoUIThemedLabel(existing == nil ? "New Automation" : "Edit Automation", size: 16, weight: .semibold)
        let message = AutoUIThemedLabel(
            "Sends the prompt to an agent on a schedule while Soprano is open, until you pause it.",
            wrapping: true
        ) { $0.mutedForeground }

        nameField.field.identifier = NSUserInterfaceItemIdentifier("automation-editor-name")
        nameField.field.setAccessibilityLabel("Name")
        promptView.placeholder = "Review the repository health and summarize what needs attention."
        promptView.delegate = self
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.setAccessibilityLabel("Prompt")
        promptView.onFocusChange = { [weak self] focused in self?.promptBox.setFocused(focused) }
        promptBox.heightAnchor.constraint(equalToConstant: Self.promptHeight).isActive = true

        agentSelect.onSelect = { [weak self] _ in self?.refreshValidation() }
        modelField.field.setAccessibilityLabel("Model")
        folderSelect.onSelect = { [weak self] value in self?.folderChanged(value) }
        workspaceControl.onSelect = { [weak self] _ in
            self?.refreshSessionControl()
            self?.refreshValidation()
        }
        baseBranchField.field.setAccessibilityLabel("Base branch")
        baseBranchField.toolTip = "The branch each run's worktree starts from"
        sessionControl.onSelect = { [weak self] _ in self?.refreshSessionControl() }
        cadenceSelect.onSelect = { [weak self] _ in self?.cadenceChanged() }
        minuteField.field.setAccessibilityLabel("Minute past the hour")
        minuteField.toolTip = "0–59"
        minuteField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        minuteField.onChange = { [weak self] _ in self?.refreshValidation() }
        minuteLabel.setContentHuggingPriority(.required, for: .horizontal)
        weekdaySelect.onSelect = { [weak self] _ in self?.refreshValidation() }
        timeBox.picker.target = self
        timeBox.picker.action = #selector(scheduleInputChanged(_:))
        cronField.field.setAccessibilityLabel("Cron schedule")
        cronField.onChange = { [weak self] _ in self?.refreshValidation() }
        graceSelect.onSelect = { [weak self] _ in self?.refreshValidation() }
        graceSelect.toolTip = "How late a run due while the Mac slept or Soprano was closed may still start"
        precheckField.field.setAccessibilityLabel("Precheck")
        precheckField.toolTip = "A shell command run in the folder before each scheduled run; the run starts only when it exits 0"
        timeoutSelect.toolTip = "How long the precheck may take"
        for field in [nameField, modelField, baseBranchField, minuteField, cronField, precheckField] {
            field.onCommand = { [weak self] selector in
                guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
                self?.submit()
                return true
            }
        }

        let runsIn = line([workspaceControl, baseBranchField], fill: baseBranchField)
        let schedule = line([cadenceSelect, minuteLabel, minuteField, weekdaySelect, timeBox, cronField], fill: cronField)
        let precheck = line([precheckField, timeoutSelect], fill: precheckField)

        let enabledLabel = AutoUIThemedLabel("Enabled", size: Typography.rowSize)
        let enabledRow = NSStackView(views: [enabledSwitch, enabledLabel])
        enabledRow.orientation = .horizontal
        enabledRow.alignment = .centerY
        enabledRow.spacing = 8

        let rows: [NSView] = [
            Self.labeled("Name", nameField),
            Self.labeled("Prompt", promptBox, note: promptNote),
            Self.pair(Self.labeled("Agent", agentSelect), Self.labeled("Model", modelField)),
            Self.labeled("Folder", folderSelect, note: folderNote),
            Self.labeled("Runs in", runsIn),
            Self.labeled("Schedule", schedule, note: scheduleNote),
            Self.pair(Self.labeled("Session", sessionControl, fillsWidth: false), Self.labeled("Grace", graceSelect)),
            Self.labeled("Precheck", precheck),
            enabledRow,
        ]

        let body = NSStackView()
        body.orientation = .vertical
        // The card's preferred width decides the form's; the stack must not
        // hug its narrowest content against it.
        body.setHuggingPriority(.init(1), for: .horizontal)
        body.alignment = .leading
        body.spacing = 14
        body.detachesHiddenViews = true
        body.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        body.addArrangedSubview(title)
        body.addArrangedSubview(message)
        body.setCustomSpacing(8, after: title)
        body.setCustomSpacing(20, after: message)
        for row in rows {
            body.addArrangedSubview(row)
        }
        body.addArrangedSubview(errorLabel)
        body.setCustomSpacing(16, after: rows[rows.count - 2])
        for view in ([message, errorLabel] as [NSView]) + rows.filter({ $0 !== enabledRow }) {
            view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -48).isActive = true
        }
        for label in [message, promptNote, folderNote, scheduleNote, errorLabel] {
            label.preferredMaxLayoutWidth = Self.width - 48
        }
        errorLabel.isHidden = true
        return body
    }

    /// A field under its label (13 pt medium) with an optional note under it;
    /// the field spans the column unless it keeps its own width.
    private static func labeled(_ title: String, _ control: NSView, note: NSTextField? = nil, fillsWidth: Bool = true) -> NSView {
        let label = AutoUIThemedLabel(title, size: Typography.rowSize, weight: .medium)
        var views: [NSView] = [label, control]
        if let note { views.append(note) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(6, after: control)
        control.translatesAutoresizingMaskIntoConstraints = false
        if fillsWidth { control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        note?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// Two labelled fields side by side, equally wide.
    private static func pair(_ leading: NSView, _ trailing: NSView) -> NSView {
        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 12
        row.setHuggingPriority(.init(1), for: .horizontal)
        return row
    }

    /// Controls side by side; hidden ones drop out. `fill` takes the width the
    /// others leave; while it is hidden a spacer does, so no control stretches.
    private func line(_ views: [NSView], fill: NSView) -> NSStackView {
        let spacer = NSView()
        let stack = NSStackView(views: views + [spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.distribution = .fill
        stack.detachesHiddenViews = true
        // The column sets the width; a line of fixed-width controls must not
        // pull the dialog in to their total.
        stack.setHuggingPriority(.init(1), for: .horizontal)
        let collapsed = spacer.widthAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .init(300)
        let stretched = fill.widthAnchor.constraint(equalToConstant: 2_000)
        stretched.priority = .init(200)
        NSLayoutConstraint.activate([collapsed, stretched])
        stack.setCustomSpacing(0, after: views[views.count - 1])
        return stack
    }

    // MARK: - Values

    private func load(automation: Automation?, template: AutomationTemplate?) {
        nameField.stringValue = automation?.name ?? template?.name ?? ""
        promptView.string = automation?.prompt ?? template?.prompt ?? ""
        promptView.setSelectedRange(NSRange(location: 0, length: 0))

        var agentIds = Automation.agentIds.filter { AgentCatalog.profile(for: $0) != nil }
        if let agentId = automation?.agentId, !agentIds.contains(agentId) {
            agentIds.insert(agentId, at: 0)
        }
        let agentId = automation?.agentId ?? (agentIds.contains("omp") ? "omp" : agentIds.first) ?? ""
        agentSelect.setOptions(
            agentIds.map { AutoUISelectOption(title: AutomationFormat.agentName($0), value: $0) },
            selected: agentId
        )

        populateFolders()

        switch automation?.workspace ?? .folder {
        case .folder:
            workspaceControl.selectedIndex = 0
        case .worktree(let baseBranch):
            workspaceControl.selectedIndex = 1
            baseBranchField.stringValue = baseBranch ?? ""
        }
        sessionControl.selectedIndex = automation?.session == .reuse ? 1 : 0

        let cadence = automation?.cadence ?? template?.cadence ?? .weekdays(hour: 9, minute: 0)
        var hour = 9
        var minute = 0
        var weekday = 1
        let selected: Cadence
        switch cadence {
        case .hourly(let value):
            selected = .hourly
            minute = value
        case .daily(let h, let m):
            selected = .daily
            (hour, minute) = (h, m)
        case .weekdays(let h, let m):
            selected = .weekdays
            (hour, minute) = (h, m)
        case .weekly(let day, let h, let m):
            selected = .weekly
            (weekday, hour, minute) = (day % 7, h, m)
        case .custom(let expression):
            selected = .custom
            cronField.stringValue = expression
        }
        cadenceSelect.select("\(selected.rawValue)")
        minuteField.stringValue = "\(minute)"
        weekdaySelect.select("\(weekday)")
        setTime(hour: hour, minute: minute)

        let grace = automation?.graceMinutes ?? template?.graceMinutes ?? Automation.defaultGraceMinutes
        var graceOptions = Self.graceOptions
        if !graceOptions.contains(where: { $0.minutes == grace }) {
            graceOptions.append((grace, AutomationFormat.grace(grace)))
            graceOptions.sort { $0.minutes < $1.minutes }
        }
        graceSelect.setOptions(graceOptions.map { AutoUISelectOption(title: $0.title, value: "\($0.minutes)") }, selected: "\(grace)")

        precheckField.stringValue = automation?.precheck ?? ""
        let timeout = automation?.precheckTimeoutSeconds ?? Automation.defaultPrecheckTimeoutSeconds
        var timeoutOptions = Self.timeoutOptions
        if !timeoutOptions.contains(where: { $0.seconds == timeout }) {
            timeoutOptions.append((timeout, AutomationFormat.timeout(timeout)))
            timeoutOptions.sort { $0.seconds < $1.seconds }
        }
        timeoutSelect.setOptions(timeoutOptions.map { AutoUISelectOption(title: $0.title, value: "\($0.seconds)") }, selected: "\(timeout)")

        modelField.stringValue = automation?.model ?? ""
    }

    private func setTime(hour: Int, minute: Int) {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        timeBox.picker.dateValue = Calendar.current.date(from: components) ?? Date()
    }

    private var cadence: Cadence {
        Int(cadenceSelect.selectedValue).flatMap(Cadence.init(rawValue:)) ?? .weekdays
    }

    private var isWorktree: Bool { workspaceControl.selectedIndex == 1 }

    /// The schedule the controls describe, or why they describe none.
    private func schedule() -> Result<CronSchedule, CronSchedule.ParseError> {
        let time = Calendar.current.dateComponents([.hour, .minute], from: timeBox.picker.dateValue)
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
            expression = AutomationCadence.weekly(weekday: max(0, Int(weekdaySelect.selectedValue) ?? 1), hour: hour, minute: minute).expression
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
        minuteField.isHidden = cadence != .hourly
        weekdaySelect.isHidden = cadence != .weekly
        timeBox.isHidden = cadence == .hourly || cadence == .custom
        cronField.isHidden = cadence != .custom
    }

    /// Reuse hands a run to the previous run's agent in the same folder, so a
    /// worktree run is always fresh.
    private func refreshSessionControl() {
        baseBranchField.isHidden = !isWorktree
        sessionControl.setEnabled(!isWorktree, forSegment: 1)
        if isWorktree {
            sessionControl.selectedIndex = 0
        }
        sessionControl.toolTip = isWorktree
            ? "Worktree runs always start a fresh agent"
            : "Reuse hands the prompt to the previous run's agent while it is open and idle"
    }

    private func refreshValidation() {
        let promptValid = !trimmedPrompt.isEmpty
        promptNote.isHidden = promptValid
        promptNote.stringValue = "Enter the prompt the agent gets on every run."

        if selectedFolder == nil {
            folderNote.isHidden = false
            folderNote.stringValue = "Choose the folder its runs work in."
            folderNote.role = { $0.mutedForeground }
        } else if !folderExists {
            folderNote.isHidden = false
            folderNote.stringValue = "This folder doesn't exist."
            folderNote.role = { $0.errorForeground }
        } else {
            folderNote.isHidden = true
        }

        let schedule = schedule()
        switch schedule {
        case .success(let schedule):
            cronField.isInvalid = false
            minuteField.isInvalid = false
            if cadence != .custom {
                lastPresetExpression = schedule.expression
            }
            let next = schedule.nextOccurrence(after: Date()).map { "Next run \(AutomationFormat.dateTime($0))" }
            scheduleNote.stringValue = next ?? "This schedule never runs."
            scheduleNote.role = { $0.mutedForeground }
        case .failure(let error):
            cronField.isInvalid = cadence == .custom && !cronField.stringValue.isEmpty
            minuteField.isInvalid = cadence == .hourly
            scheduleNote.stringValue = error.message
            let quiet = cadence == .custom && cronField.stringValue.isEmpty
            scheduleNote.role = { quiet ? $0.mutedForeground : $0.errorForeground }
        }

        var isValid = promptValid && folderExists
        if case .failure = schedule { isValid = false }
        saveButton.isEnabled = isValid
    }

    /// Whether Save would write now; for tests.
    var canSave: Bool { saveButton.isEnabled }

    /// The error shown above the buttons, if any; for tests.
    var shownError: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }

    // MARK: - Actions

    private func cadenceChanged() {
        // Custom starts from the preset it replaces, so a small change is easy.
        if cadence == .custom, cronField.stringValue.isEmpty {
            cronField.stringValue = lastPresetExpression ?? ""
        }
        refreshScheduleControls()
        refreshValidation()
    }

    @objc private func scheduleInputChanged(_ sender: Any?) {
        refreshValidation()
    }

    private func cancel() {
        close()
    }

    private func close() {
        window.dismiss()
        onClose?()
    }

    func submit() {
        guard saveButton.isEnabled,
              case .success(let schedule) = schedule(),
              let folder = selectedFolder,
              !agentSelect.selectedValue.isEmpty
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
            id: existing?.id ?? Automation.makeId(from: name, existing: takenIds),
            name: name,
            agentId: agentSelect.selectedValue,
            folder: folder,
            prompt: trimmedPrompt,
            schedule: schedule,
            enabled: enabledSwitch.isOn,
            workspace: workspace,
            session: !isWorktree && sessionControl.selectedIndex == 1 ? .reuse : .fresh,
            graceMinutes: Int(graceSelect.selectedValue) ?? Automation.defaultGraceMinutes,
            precheck: optional(precheckField.stringValue),
            precheckTimeoutSeconds: Int(timeoutSelect.selectedValue) ?? Automation.defaultPrecheckTimeoutSeconds,
            model: optional(modelField.stringValue)
        )
        if onSave?(automation) == true {
            close()
        } else {
            errorLabel.stringValue = "Soprano couldn't save the automation. Check that \(ConfigStore.shared.displayPath) is writable, then try again."
            errorLabel.isHidden = false
        }
    }

    // MARK: - Keyboard

    /// Esc cancels and ⌘Return saves from any control, the prompt included.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, flags.isEmpty {
            cancel()
            return true
        }
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            submit()
            return true
        }
        return false
    }
}

extension AutomationEditorPanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        refreshValidation()
    }
}

// MARK: - Time

/// The time of day: a stepper date picker in Agents' input box.
final class AutomationTimeBox: PaletteView {
    let picker = NSDatePicker()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.font = Typography.tabular(Typography.bodySize)
        picker.setAccessibilityLabel("Time")
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            widthAnchor.constraint(equalToConstant: 108),
            picker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            picker.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.input.shellScaled(by: 0.32) : palette.background).cgColor
        layer?.borderColor = palette.input.cgColor
        picker.textColor = palette.foreground
        picker.appearance = palette.appearance
    }
}

// MARK: - Prompt

/// The multi-line prompt: a placeholder while empty, and Tab moving on to the
/// next control instead of typing a tab.
final class AutomationPromptTextView: AutoUIPlaceholderTextView {
    var onFocusChange: ((Bool) -> Void)?

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
}
