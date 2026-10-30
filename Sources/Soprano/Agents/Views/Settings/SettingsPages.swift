import AppKit
import SopranoAgentsCore

/// The pages. Each control shows the resolved setting and writes one key; a row offers reset
/// when settings.json sets its key to something other than the default.
extension SettingsController {
    func buildPage(_ page: SettingsPage, form: SettingsForm) -> [NSView] {
        switch page {
        case .general: generalPage(form)
        case .providers: providersPage(form)
        case .accounts: accountsPage(form)
        case .textGeneration: textGenerationPage(form)
        case .worktrees: worktreesPage(form)
        case .notifications: notificationsPage(form)
        case .keybindings: keybindingsPage(form)
        case .archive: archivePage(form)
        case .about: aboutPage(form)
        }
    }

    private var settings: AppSettings { center.settings }
    private var defaults: AppSettings { .defaults }

    /// Reset action for `path` when its value differs from the default, else nil.
    private func reset(_ path: [String], isDefault: Bool) -> (() -> Void)? {
        isDefault ? nil : { [weak self] in self?.remove(path) }
    }

    // MARK: General

    static func themeOptions() -> [SelectOption] {
        var options = [SelectOption(title: "Follow Soprano", value: "soprano")]
        for (index, theme) in AppTheme.options.enumerated() {
            options.append(SelectOption(title: theme.name, value: theme.id, separatorBefore: index == 0))
        }
        return options
    }

    private func generalPage(_ form: SettingsForm) -> [NSView] {
        var sections: [NSView] = []
        let issues = center.issues
        if !issues.isEmpty {
            sections.append(form.section("settings.json", issues.map { issue in
                form.row(
                    issue.severity == .error ? "Error" : "Warning",
                    description: issue.line.map { "Line \($0): \(issue.message)" } ?? issue.message,
                    descriptionRole: issue.severity == .error ? { $0.errorForeground } : { $0.warningForeground },
                    control: form.button("Open settings.json") { [weak self] in self?.center.openInEditor() }
                )
            }))
        }

        let theme = form.select(Self.themeOptions(), selected: settings.theme, width: 224, label: "Theme") { [weak self] value in
            self?.write(value, at: ["theme"])
        }
        let widths = [
            SelectOption(title: "Comfortable (default)", value: AppSettings.ChatWidth.normal.rawValue),
            SelectOption(title: "Wide", value: AppSettings.ChatWidth.wide.rawValue),
            SelectOption(title: "Full", value: AppSettings.ChatWidth.full.rawValue),
        ]
        let width = form.select(widths, selected: settings.chatWidth.rawValue, width: 192, label: "Chat width") { [weak self] value in
            self?.write(value, at: ["chat", "width"])
        }
        sections.append(form.section("Appearance", [
            form.row(
                "Theme",
                description: "Follow Soprano uses Soprano's theme and appearance. Folio follows the macOS appearance; the other themes pin one.",
                reset: reset(["theme"], isDefault: settings.theme == defaults.theme),
                control: theme
            ),
            form.row(
                "Chat width",
                description: "Set how wide messages and the composer can grow on large screens.",
                reset: reset(["chat", "width"], isDefault: settings.chatWidth == defaults.chatWidth),
                control: width
            ),
        ]))

        let followUp = form.select(
            [SelectOption(title: "Queue", value: "queue"), SelectOption(title: "Steer", value: "steer")],
            selected: settings.followUp.rawValue, width: 112, label: "Follow-up behavior"
        ) { [weak self] value in
            self?.write(value, at: ["chat", "followUp"])
        }
        sections.append(form.section("Follow-ups", [
            form.row(
                "Follow-up behavior",
                description: "Queue follow-ups while the agent runs or steer the current run. Press ⌘ + Enter to do the opposite for one message.",
                reset: reset(["chat", "followUp"], isDefault: settings.followUp == defaults.followUp),
                control: followUp
            ),
        ]))
        return sections
    }

    // MARK: Providers

    static func healthLabel(_ status: ProviderStatus) -> (text: String, role: (Palette) -> NSColor) {
        switch status.health {
        case .ready: ("Ready", { $0.successForeground })
        case .notInstalled: ("Not installed", { $0.warningForeground })
        case .unauthenticated: ("Signed out", { $0.warningForeground })
        case .error: ("Error", { $0.errorForeground })
        case .unknown: ("Checking…", { $0.mutedForeground })
        }
    }

    static func statusDescription(_ status: ProviderStatus) -> String {
        if status.health == .ready {
            return [status.version.map { "Version \($0)" }, status.accountLabel].compactMap { $0 }.joined(separator: " · ")
        }
        if let message = status.message, !message.isEmpty { return message }
        let command = status.kind.executableName
        return switch status.health {
        case .notInstalled: "\(command) was not found. Install it or set its path below."
        case .unauthenticated: "Sign in with \(command) in a terminal, then check again."
        case .error: "The CLI did not answer as expected."
        case .ready, .unknown: "Looking for \(command)…"
        }
    }

    private func models(for kind: ProviderKind) -> [ProviderModel] {
        let live = engine.status(of: kind).models
        return live.isEmpty ? ProviderCatalog.fallback(kind) : live
    }

    private func modelOptions(for kind: ProviderKind, defaultSlug: String) -> [SelectOption] {
        let models = models(for: kind)
        let defaultName = models.first { $0.slug == defaultSlug }?.name ?? defaultSlug
        var options = [SelectOption(title: "Default (\(defaultName))", value: "")]
        // omp's "default" entry is the same choice as the empty value above.
        for (index, model) in models.filter({ $0.slug != ModelSelection.ompDefaultModel }).enumerated() {
            options.append(SelectOption(title: model.name, value: model.slug, separatorBefore: index == 0))
        }
        return options
    }

    private func providerOptions() -> [SelectOption] {
        ProviderKind.allCases.map { SelectOption(title: $0.displayName, value: $0.rawValue) }
    }

    private func providersPage(_ form: SettingsForm) -> [NSView] {
        var sections: [NSView] = []
        for kind in ProviderKind.allCases {
            let status = engine.status(of: kind)
            let health = Self.healthLabel(status)
            let badge = ThemedLabel(health.text, size: Typography.smallSize, weight: .medium, role: health.role)
            let check = form.button("Check again", size: .xs) { [weak self] in
                guard let engine = self?.engine else { return }
                Task { await engine.refreshProviders() }
            }
            let key = "\(kind.rawValue)Path"
            let command = kind.executableName
            let configured = center.configuredValue(at: ["providers", key]) as? String
            let path = form.field(configured ?? "", placeholder: "\(command) on PATH", width: 256, identifier: "providers.\(key)", mono: true) { [weak self] value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { self?.remove(["providers", key]) } else { self?.write(trimmed, at: ["providers", key]) }
            }
            sections.append(form.section(kind.displayName, [
                form.row("Status", description: Self.statusDescription(status), control: form.group([badge, check], spacing: 10)),
                form.row(
                    "Executable",
                    description: "Path to the \(command) CLI. Leave empty to find it on PATH.",
                    reset: reset(["providers", key], isDefault: configured == nil),
                    control: path
                ),
            ]))
        }

        let provider = form.select(providerOptions(), selected: settings.defaultProvider.rawValue, width: 192, label: "Default provider") { [weak self] value in
            self?.write(value, at: ["agents", "defaultProvider"])
            self?.remove(["agents", "defaultModel"])
        }
        let model = form.select(
            modelOptions(for: settings.defaultProvider, defaultSlug: settings.defaultProvider.defaultModel),
            selected: settings.defaultModel ?? "", width: 224, label: "Default model"
        ) { [weak self] value in
            if value.isEmpty { self?.remove(["agents", "defaultModel"]) } else { self?.write(value, at: ["agents", "defaultModel"]) }
        }
        let modes = RuntimeMode.allCases.map { SelectOption(title: $0.title, value: $0.rawValue) }
        let permissions = form.select(modes, selected: settings.defaultRuntimeMode.rawValue, width: 192, label: "Permissions") { [weak self] value in
            self?.write(value, at: ["agents", "defaultRuntimeMode"])
        }
        sections.append(form.section("New threads", [
            form.row(
                "Default provider",
                description: "The agent new threads start with. Each thread keeps its provider.",
                reset: reset(["agents", "defaultProvider"], isDefault: settings.defaultProvider == defaults.defaultProvider),
                control: provider
            ),
            form.row(
                "Default model",
                description: "Model new threads start with; the composer's model picker changes it per thread.",
                reset: reset(["agents", "defaultModel"], isDefault: settings.defaultModel == nil),
                control: model
            ),
            form.row(
                "Permissions",
                description: "\(settings.defaultRuntimeMode.title): \(settings.defaultRuntimeMode.summary)",
                reset: reset(["agents", "defaultRuntimeMode"], isDefault: settings.defaultRuntimeMode == defaults.defaultRuntimeMode),
                control: permissions
            ),
        ]))
        return sections
    }

    // MARK: Text generation

    private func textGenerationPage(_ form: SettingsForm) -> [NSView] {
        let kind = settings.textGenerationProvider
        let provider = form.select(providerOptions(), selected: kind.rawValue, width: 192, label: "Text generation provider") { [weak self] value in
            self?.write(value, at: ["textGeneration", "provider"])
            self?.remove(["textGeneration", "model"])
        }
        let model = form.select(
            modelOptions(for: kind, defaultSlug: kind.textGenerationModel),
            selected: settings.textGenerationModel ?? "", width: 224, label: "Text generation model"
        ) { [weak self] value in
            if value.isEmpty { self?.remove(["textGeneration", "model"]) } else { self?.write(value, at: ["textGeneration", "model"]) }
        }
        let titles = form.toggle(settings.generateTitles, label: "Generate thread titles") { [weak self] isOn in
            self?.write(isOn, at: ["textGeneration", "titles"])
        }
        return [form.section("Text generation", [
            form.row(
                "Provider",
                description: "The agent CLI that writes thread titles, commit messages and branch names.",
                reset: reset(["textGeneration", "provider"], isDefault: kind == defaults.textGenerationProvider),
                control: provider
            ),
            form.row(
                "Text generation model",
                description: "Used for thread titles, commit messages and branch names. A small, fast model works best.",
                reset: reset(["textGeneration", "model"], isDefault: settings.textGenerationModel == nil),
                control: model
            ),
            form.row(
                "Generate thread titles",
                description: "Name new threads from their first message. Off keeps the first 50 characters of the message.",
                reset: reset(["textGeneration", "titles"], isDefault: settings.generateTitles == defaults.generateTitles),
                control: titles
            ),
        ])]
    }

    // MARK: Worktrees

    private func worktreesPage(_ form: SettingsForm) -> [NSView] {
        let configured = center.configuredValue(at: ["worktrees", "directory"]) as? String
        let shown = configured ?? SettingsFile.displayPath(for: URL(fileURLWithPath: defaults.worktreesDirectory))
        let location = form.field(shown, placeholder: "~/.soprano-agents/worktrees", width: 288, identifier: "worktrees.directory", mono: true) { [weak self] value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { self?.remove(["worktrees", "directory"]) } else { self?.write(trimmed, at: ["worktrees", "directory"]) }
        }
        let prefix = form.field(settings.branchPrefix, placeholder: "soprano", width: 160, identifier: "worktrees.branchPrefix", mono: true) { [weak self] value in
            self?.write(value.trimmingCharacters(in: .whitespacesAndNewlines), at: ["worktrees", "branchPrefix"])
        }
        let example = settings.branchPrefix.isEmpty ? "add-search" : "\(settings.branchPrefix)/add-search"
        return [form.section("Worktrees", [
            form.row(
                "Worktree location",
                description: "New worktrees go to <location>/<repository>/<branch>.",
                reset: reset(["worktrees", "directory"], isDefault: settings.worktreesDirectory == defaults.worktreesDirectory),
                control: location
            ),
            form.row(
                "Branch prefix",
                description: "New worktree branches start with it: \(example).",
                reset: reset(["worktrees", "branchPrefix"], isDefault: settings.branchPrefix == defaults.branchPrefix),
                control: prefix
            ),
        ])]
    }

    // MARK: Notifications

    private func notificationsPage(_ form: SettingsForm) -> [NSView] {
        let enabled = form.toggle(settings.notificationsEnabled, label: "Thread notifications") { [weak self] isOn in
            self?.write(isOn, at: ["notifications", "enabled"])
        }
        let sound = form.toggle(settings.notificationSound, label: "Notification sound", enabled: settings.notificationsEnabled) { [weak self] isOn in
            self?.write(isOn, at: ["notifications", "sound"])
        }
        return [form.section("Notifications", [
            form.row(
                "Thread notifications",
                description: "Notify when a thread finishes, fails, or needs input or approval while Soprano Agents is in the background. The Dock icon counts threads waiting for you.",
                reset: reset(["notifications", "enabled"], isDefault: settings.notificationsEnabled == defaults.notificationsEnabled),
                control: enabled
            ),
            form.row(
                "Notification sound",
                description: "Play the system sound with each notification.",
                reset: reset(["notifications", "sound"], isDefault: settings.notificationSound == defaults.notificationSound),
                control: sound
            ),
        ])]
    }

    // MARK: Keybindings

    /// "In composer", "Not in terminal", nil for global commands.
    static func scopeText(_ scopes: Set<FocusRegion>) -> String? {
        guard !scopes.isEmpty else { return nil }
        if scopes == [.sidebar, .timeline, .composer, .rightPanel] { return "Not in terminal" }
        let names: [FocusRegion: String] = [
            .sidebar: "sidebar", .timeline: "timeline", .composer: "composer",
            .terminal: "terminal", .rightPanel: "right panel", .settings: "settings",
        ]
        return "In " + FocusRegion.allCases.filter(scopes.contains).compactMap { names[$0] }.joined(separator: ", ")
    }

    /// Commands matching the Keybindings filter: title, id or shortcut text.
    static func keybindingMatches(_ command: AppCommand, query: String, chords: [KeyChord], prefixKey: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let shortcuts = chords.flatMap { [$0.displayString, $0.keycaps(prefixKey: prefixKey).joined(separator: " ")] }
        return ([command.title, command.id] + shortcuts).contains { $0.lowercased().contains(needle) }
    }

    private func keybindingsPage(_ form: SettingsForm) -> [NSView] {
        var sections: [NSView] = []
        let filter = InputField(value: keybindingQuery, placeholder: "Search keybindings")
        filter.field.identifier = Self.filterIdentifier
        filter.widthAnchor.constraint(equalToConstant: form.width).isActive = true
        filter.onChange = { [weak self] text in self?.setKeybindingQuery(text) }
        sections.append(filter)

        let bindings = center.keybindingSettings
        let keymap = center.keymap
        if keybindingQuery.isEmpty {
            let limits = SettingsResolver.Limits.prefixTimeoutMs
            let key = form.field(bindings.prefixKey, placeholder: "a", width: 48, identifier: "keybindings.prefixKey") { [weak self] value in
                guard let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first else { return }
                self?.write(String(first).lowercased(), at: ["keybindings", "prefixKey"])
            }
            key.field.alignment = .center
            let timeout = form.field(String(bindings.prefixTimeoutMs), placeholder: "1500", width: 80, identifier: "keybindings.prefixTimeoutMs") { [weak self] value in
                guard let number = Int(value.trimmingCharacters(in: .whitespaces)) else { return }
                self?.write(min(max(limits.lowerBound, number), limits.upperBound), at: ["keybindings", "prefixTimeoutMs"])
            }
            sections.append(form.section("Prefix", [
                form.row(
                    "Prefix key",
                    description: "⌃ + this key starts a prefix chord: ⌃\(bindings.prefixKey.uppercased()), then the key.",
                    reset: reset(["keybindings", "prefixKey"], isDefault: bindings.prefixKey == KeybindingSettings().prefixKey),
                    control: key
                ),
                form.row(
                    "Prefix timeout",
                    description: "Milliseconds the prefix waits for its key (\(limits.lowerBound)–\(limits.upperBound)).",
                    reset: reset(["keybindings", "prefixTimeoutMs"], isDefault: bindings.prefixTimeoutMs == KeybindingSettings().prefixTimeoutMs),
                    control: timeout
                ),
            ]))
        }

        let commands = center.registry.commands
        var anyMatch = false
        for category in CommandCategory.allCases {
            let matching = commands.filter {
                $0.category == category
                    && Self.keybindingMatches($0, query: keybindingQuery, chords: keymap.chords(for: $0.id), prefixKey: keymap.prefixKey)
            }
            guard !matching.isEmpty else { continue }
            anyMatch = true
            sections.append(form.section(category.rawValue, matching.map { keybindingRow($0, keymap: keymap, form: form) }))
        }
        if !anyMatch {
            sections.append(form.section(nil, [form.row("No matching keybindings", description: "Try a command name, id or shortcut.")]))
        }
        return sections
    }

    private func keybindingRow(_ command: AppCommand, keymap: Keymap, form: SettingsForm) -> NSView {
        let id = command.id
        let chords = keymap.chords(for: id)
        let isRecording = recordingCommandID == id
        var controls: [NSView] = []
        if isRecording {
            controls.append(ThemedLabel(recordingPrompt, size: Typography.smallSize, weight: .medium) { $0.primary })
            controls.append(form.button("Cancel", size: .xs) { [weak self] in self?.stopRecording(rerender: true) })
        } else {
            if chords.isEmpty {
                controls.append(ThemedLabel("Unassigned", size: Typography.smallSize) { $0.mutedForeground.withAlphaComponent(0.7) })
            }
            for (index, chord) in chords.enumerated() {
                if index > 0 { controls.append(ThemedLabel("or", size: Typography.smallSize) { $0.mutedForeground.withAlphaComponent(0.7) }) }
                let caps = chord.keycaps(prefixKey: keymap.prefixKey).map { KbdView($0) as NSView }
                controls.append(form.group(caps, spacing: 3))
            }
            controls.append(form.button("Record", size: .xs) { [weak self] in self?.startRecording(id) })
            if !chords.isEmpty {
                controls.append(form.button("Off", variant: .ghost, size: .xs) { [weak self] in
                    self?.write(NSNull(), at: ["keybindings", "bindings", id])
                })
            }
        }
        var description = id
        if let scope = Self.scopeText(command.scopes) { description += " · \(scope)" }
        var role: ((Palette) -> NSColor)?
        if keymap.conflictingIDs.contains(id) {
            let messages = keymap.issues.filter { $0.message.contains("\"\(id)\"") }.map(\.message)
            if !messages.isEmpty { description += "\n" + messages.joined(separator: "\n") }
            role = { $0.warningForeground }
        }
        return form.row(
            command.title,
            description: description,
            descriptionRole: role,
            reset: keymap.customizedIDs.contains(id) ? { [weak self] in self?.remove(["keybindings", "bindings", id]) } : nil,
            control: form.group(controls, spacing: 6)
        )
    }

    // MARK: Archive

    static func archivedText(_ thread: AgentThread, now: Date) -> String {
        func ago(_ date: Date) -> String {
            let relative = DurationText.relative(date, now: now)
            return relative == "now" ? "just now" : "\(relative) ago"
        }
        return "Archived \(ago(thread.archivedAt ?? thread.createdAt)) · Created \(ago(thread.createdAt))"
    }

    private func archivePage(_ form: SettingsForm) -> [NSView] {
        let archived = engine.threads
            .filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        guard !archived.isEmpty else {
            return [form.section("Archive", [
                form.row("No archived threads", description: "Archived threads will appear here."),
            ])]
        }
        let now = engine.environment.now()
        var order: [String?] = []
        var byProject: [String?: [AgentThread]] = [:]
        for thread in archived {
            if byProject[thread.projectID] == nil { order.append(thread.projectID) }
            byProject[thread.projectID, default: []].append(thread)
        }
        return order.map { projectID in
            let title = engine.project(projectID)?.title ?? "No project"
            let rows = (byProject[projectID] ?? []).map { thread in
                let unarchive = form.button("Unarchive") { [weak self] in self?.engine.setArchived(thread.id, false) }
                let delete = form.button("Delete", variant: .destructiveOutline) { [weak self] in self?.confirmDelete(thread) }
                return form.row(thread.title, description: Self.archivedText(thread, now: now), control: form.group([unarchive, delete]))
            }
            return form.section(title, rows)
        }
    }

    private func confirmDelete(_ thread: AgentThread) {
        let engine = engine
        let host = parentWindow
        Task { @MainActor in
            let confirmed = await Dialogs.confirm(
                title: "Delete thread \"\(thread.title)\"?",
                message: "This permanently clears conversation history for this thread.",
                confirmTitle: "Delete",
                isDestructive: true,
                in: host
            )
            if confirmed { await engine.deleteThread(thread.id) }
        }
    }

    // MARK: About

    private func aboutPage(_ form: SettingsForm) -> [NSView] {
        let data = AppPaths.dataDirectory()
        return [form.section("About", [
            form.row("Version", description: "Current version of the application.", control: form.value(AppVersion.current)),
            form.row(
                "Settings file",
                description: center.displayPath,
                mono: true,
                control: form.group([
                    form.button("Open settings.json") { [weak self] in self?.center.openInEditor() },
                    form.button("Show in Finder", variant: .ghost) { [weak self] in self?.center.revealInFinder() },
                ])
            ),
            form.row(
                "App data",
                description: SettingsFile.displayPath(for: data),
                mono: true,
                control: form.button("Show in Finder", variant: .ghost) {
                    NSWorkspace.shared.activateFileViewerSelecting([data])
                }
            ),
        ])]
    }
}
