import Foundation

/// The user-facing configuration decoded from `~/.config/soprano/settings.json`.
///
/// Every field is optional on purpose: an absent key means "keep the built-in
/// default", the same partial-override model VS Code's `settings.json` uses. A
/// user should never have to paste a complete document to change one value.
struct SopranoConfig: Codable, Equatable {
    var theme: String?
    var hideWindowBar: Bool?
    var restoreLastSession: Bool?
    var projectDirectories: [String]?
    var notifications: Notifications?
    var keybindings: Keybindings?
    var agents: [Agent]?

    static let empty = SopranoConfig()

    /// Whether macOS may deliver a banner is the system's decision, not ours, so
    /// the only thing configured here is what Soprano controls about it.
    struct Notifications: Codable, Equatable {
        var sound: Bool?
    }

    struct Keybindings: Codable, Equatable {
        var prefixKey: String?
        var prefixTimeoutMs: Int?
        var resizeTickPercent: Double?
        /// Binding id → chord, where JSON `null` disables the binding.
        var bindings: [String: BindingOverride]?
    }

    /// A user-declared agent. `id` is the only required field: reusing a
    /// built-in id (`codex`, `claude-code`, `opencode`, `terminal`) patches that
    /// profile field by field, while a new id defines a whole new agent and
    /// then requires `command`.
    ///
    /// Deliberately narrower than `AgentProfile`: `autoRestart`,
    /// `restartDelayMs`, and `patterns` are not exposed because nothing reads
    /// them at runtime, and a settings key that does nothing is worse than a
    /// missing one.
    struct Agent: Codable, Equatable {
        var id: String
        var name: String?
        var icon: String?
        var color: String?
        var description: String?
        var command: String?
        var args: [String]?
        var env: [String: String]?
        var cwd: String?
        var launchScript: String?
        var launchKey: String?
    }
}

/// A keybinding override: a chord string, or JSON `null` meaning "turn this
/// shortcut off". Spelled out as its own type because `[String: String?]`
/// round-trips explicit nulls unreliably through synthesized `Codable`.
enum BindingOverride: Equatable {
    case chord(String)
    case disabled
}

extension BindingOverride: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .disabled
            return
        }
        self = .chord(try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .chord(let value):
            try container.encode(value)
        case .disabled:
            try container.encodeNil()
        }
    }
}

// MARK: - Issues

/// A problem found while resolving the config file. Issues never block startup:
/// a bad value falls back to the default and is reported in **Settings**, so a
/// typo can't leave the user without a running app.
struct ConfigIssue: Equatable, Identifiable {
    enum Severity: Equatable {
        /// The document could not be read at all; defaults are in force.
        case error
        /// One key was ignored; everything else applied.
        case warning
    }

    let severity: Severity
    let message: String
    /// 1-based line in `settings.json`, when the problem has a position.
    var line: Int?

    var id: String { "\(severity)-\(line ?? 0)-\(message)" }
}

// MARK: - Resolution

/// The config file applied on top of the built-in defaults.
struct ResolvedConfig {
    var settings: AppSettings
    var keybindings: KeyBindingConfig
    var agents: [AgentProfile]
    var issues: [ConfigIssue]
    /// Binding ids the file overrides — the UI badges these as customized.
    var customizedBindingIds: Set<String>
    /// Binding ids the file turned off with `null`.
    var disabledBindingIds: Set<String>
    /// Agent ids the file declared or patched.
    var configuredAgentIds: Set<String>

    static let defaults = ResolvedConfig(
        settings: .defaultSettings,
        keybindings: DefaultKeybindings.config,
        agents: DefaultAgents.all,
        issues: [],
        customizedBindingIds: [],
        disabledBindingIds: [],
        configuredAgentIds: []
    )
}

extension SopranoConfig {
    /// Bounds that keep a hand-edited file from producing an unusable app.
    /// They mirror the clamps the settings UI already applies to the same
    /// fields, so both entry points behave identically.
    enum Limits {
        static let prefixTimeoutMs = 300...5000
        static let resizeTickPercent = 1...25
    }

    /// Apply this config on top of the built-in defaults.
    ///
    /// Resolution never throws: every rejected value becomes a `ConfigIssue`
    /// and leaves the default in place.
    func resolved(
        baseSettings: AppSettings = .defaultSettings,
        baseKeybindings: KeyBindingConfig = DefaultKeybindings.config,
        baseAgents: [AgentProfile] = DefaultAgents.all
    ) -> ResolvedConfig {
        var issues: [ConfigIssue] = []
        var settings = baseSettings

        if let theme {
            if AppTheme.allThemes.contains(where: { $0.id == theme }) {
                settings.themeId = theme
            } else {
                let known = AppTheme.allThemes.map(\.id).joined(separator: ", ")
                issues.append(.init(
                    severity: .warning,
                    message: "Unknown theme \"\(theme)\". Known themes: \(known)."
                ))
            }
        }

        if let restoreLastSession {
            settings.restoreLastSession = restoreLastSession
        }

        if let hideWindowBar {
            settings.hideWindowBar = hideWindowBar
        }

        if let sound = notifications?.sound {
            settings.notificationSound = sound
        }

        if let projectDirectories {
            var resolvedDirectories: [String] = []
            for rawPath in projectDirectories {
                let path = Self.expandPath(rawPath)
                guard !path.isEmpty else { continue }
                guard !resolvedDirectories.contains(path) else { continue }
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: path,
                    isDirectory: &isDirectory
                )
                if !exists || !isDirectory.boolValue {
                    issues.append(.init(
                        severity: .warning,
                        message: "projectDirectories: \"\(rawPath)\" is not a directory."
                    ))
                    continue
                }
                resolvedDirectories.append(path)
            }
            settings.projectDirectories = resolvedDirectories
        }

        let agentResolution = Self.resolveAgents(
            agents ?? [],
            baseAgents: baseAgents,
            issues: &issues
        )

        let keybindingResolution = Self.resolveKeybindings(
            keybindings,
            baseKeybindings: baseKeybindings,
            agentLaunchKeys: agentResolution.launchKeys,
            agentIds: Set(agentResolution.profiles.map(\.id)),
            issues: &issues
        )

        return ResolvedConfig(
            settings: settings,
            keybindings: keybindingResolution.config,
            agents: agentResolution.profiles,
            issues: issues,
            customizedBindingIds: keybindingResolution.customized,
            disabledBindingIds: keybindingResolution.disabled,
            configuredAgentIds: agentResolution.configuredIds
        )
    }

    static func expandPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    // MARK: - Agents

    private struct AgentResolution {
        var profiles: [AgentProfile]
        var configuredIds: Set<String>
        /// Agent id → chord for agents that declared a `launchKey`.
        var launchKeys: [String: String]
    }

    private static func resolveAgents(
        _ configured: [SopranoConfig.Agent],
        baseAgents: [AgentProfile],
        issues: inout [ConfigIssue]
    ) -> AgentResolution {
        var profiles = baseAgents
        var configuredIds: Set<String> = []
        var launchKeys: [String: String] = [:]

        for entry in configured {
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                issues.append(.init(
                    severity: .warning,
                    message: "agents: an entry is missing \"id\" and was ignored."
                ))
                continue
            }
            guard !configuredIds.contains(id) else {
                issues.append(.init(
                    severity: .warning,
                    message: "agents: duplicate id \"\(id)\"; the later entry was ignored."
                ))
                continue
            }

            if let existingIndex = profiles.firstIndex(where: { $0.id == id }) {
                profiles[existingIndex] = patched(profiles[existingIndex], with: entry)
            } else {
                guard let command = entry.command?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !command.isEmpty
                else {
                    issues.append(.init(
                        severity: .warning,
                        message: "agents: \"\(id)\" defines a new agent but has no \"command\"; it was ignored."
                    ))
                    continue
                }
                profiles.append(newProfile(id: id, command: command, entry: entry))
            }

            configuredIds.insert(id)
            if let launchKey = entry.launchKey {
                launchKeys[id] = launchKey
            }
        }

        return AgentResolution(
            profiles: profiles,
            configuredIds: configuredIds,
            launchKeys: launchKeys
        )
    }

    /// Field-wise patch of a built-in profile: unset keys keep the built-in
    /// value, so `{"id": "codex", "args": ["--model", "o3"]}` is a legal,
    /// minimal override.
    private static func patched(
        _ profile: AgentProfile,
        with entry: SopranoConfig.Agent
    ) -> AgentProfile {
        AgentProfile(
            id: profile.id,
            name: entry.name ?? profile.name,
            icon: entry.icon ?? profile.icon,
            color: entry.color ?? profile.color,
            description: entry.description ?? profile.description,
            command: entry.command ?? profile.command,
            args: entry.args ?? profile.args,
            env: entry.env ?? profile.env,
            cwd: entry.cwd.map(expandPath) ?? profile.cwd,
            launchScript: entry.launchScript ?? profile.launchScript,
            autoRestart: profile.autoRestart,
            restartDelayMs: profile.restartDelayMs,
            patterns: profile.patterns
        )
    }

    private static func newProfile(
        id: String,
        command: String,
        entry: SopranoConfig.Agent
    ) -> AgentProfile {
        AgentProfile(
            id: id,
            name: entry.name ?? defaultName(for: id),
            icon: entry.icon ?? "bot",
            color: entry.color ?? defaultColor(for: id),
            description: entry.description ?? "Configured in settings.json",
            command: command,
            args: entry.args ?? [],
            env: entry.env,
            cwd: entry.cwd.map(expandPath),
            launchScript: entry.launchScript
        )
    }

    private static func defaultName(for id: String) -> String {
        id.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Custom agents get a stable color derived from their id so several of
    /// them stay distinguishable in pane headers without anyone picking hexes.
    private static func defaultColor(for id: String) -> String {
        let palette = [
            "#83a598", "#b16286", "#8ec07c", "#d3869b",
            "#458588", "#d79921", "#689d6a", "#a89984",
        ]
        let hash = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[hash % palette.count]
    }

    // MARK: - Keybindings

    private struct KeybindingResolution {
        var config: KeyBindingConfig
        var customized: Set<String>
        var disabled: Set<String>
    }

    private static func resolveKeybindings(
        _ configured: SopranoConfig.Keybindings?,
        baseKeybindings: KeyBindingConfig,
        agentLaunchKeys: [String: String],
        agentIds: Set<String>,
        issues: inout [ConfigIssue]
    ) -> KeybindingResolution {
        var config = baseKeybindings
        var customized: Set<String> = []
        var disabled: Set<String> = []

        if let prefixKey = configured?.prefixKey {
            let trimmed = prefixKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count == 1 {
                config.prefixKey = trimmed.lowercased()
            } else {
                issues.append(.init(
                    severity: .warning,
                    message: "keybindings.prefixKey must be a single character; kept \"\(config.prefixKey)\"."
                ))
            }
        }

        if let timeout = configured?.prefixTimeoutMs {
            let clamped = min(max(Limits.prefixTimeoutMs.lowerBound, timeout), Limits.prefixTimeoutMs.upperBound)
            if clamped != timeout {
                issues.append(.init(
                    severity: .warning,
                    message: "keybindings.prefixTimeoutMs must be \(Limits.prefixTimeoutMs.lowerBound)–\(Limits.prefixTimeoutMs.upperBound); clamped to \(clamped)."
                ))
            }
            config.prefixTimeoutMs = clamped
        }

        if let resize = configured?.resizeTickPercent {
            let lower = Double(Limits.resizeTickPercent.lowerBound)
            let upper = Double(Limits.resizeTickPercent.upperBound)
            let clamped = min(max(lower, resize), upper)
            if clamped != resize {
                issues.append(.init(
                    severity: .warning,
                    message: "keybindings.resizeTickPercent must be \(Limits.resizeTickPercent.lowerBound)–\(Limits.resizeTickPercent.upperBound); clamped to \(Int(clamped))."
                ))
            }
            config.resizeTickPercent = clamped
        }

        // An agent's `launchKey` synthesizes (or retargets) its `launch-<id>`
        // binding. An explicit `keybindings.bindings` entry for the same id
        // wins, so there is exactly one place to look when both are set.
        var overrides: [String: BindingOverride] = [:]
        // Where each override came from, so a complaint points at the key the
        // user actually typed rather than at a `keybindings.bindings` entry
        // they never wrote.
        var origins: [String: String] = [:]
        for (agentId, chord) in agentLaunchKeys {
            overrides["launch-\(agentId)"] = .chord(chord)
            origins["launch-\(agentId)"] = "agents[\(agentId)].launchKey"
        }
        let explicitOverrides = configured?.bindings ?? [:]
        for (id, override) in explicitOverrides {
            overrides[id] = override
            origins[id] = "keybindings.bindings.\(id)"
        }

        var bindingsById = Dictionary(
            uniqueKeysWithValues: config.bindings.map { ($0.id, $0) }
        )
        var appended: [KeyBinding] = []

        for id in overrides.keys.sorted() {
            guard let override = overrides[id] else { continue }
            let origin = origins[id] ?? "keybindings.bindings.\(id)"
            // A `launch-<agent>` action exists for every agent in the catalog,
            // whether the agent declared a launchKey or not — otherwise binding
            // a launcher purely from `keybindings.bindings` would be rejected
            // as unknown.
            let isSynthesizable = id.hasPrefix("launch-")
                && agentIds.contains(String(id.dropFirst("launch-".count)))

            guard let existing = bindingsById[id] ?? synthesizedLaunchBinding(
                id: id,
                enabled: isSynthesizable
            ) else {
                issues.append(.init(
                    severity: .warning,
                    message: "keybindings.bindings: unknown action \"\(id)\"."
                ))
                continue
            }

            switch override {
            case .disabled:
                disabled.insert(id)
                bindingsById[id] = nil
                appended.removeAll { $0.id == id }
            case .chord(let text):
                guard let chord = KeyChord.parse(text) else {
                    issues.append(.init(
                        severity: .warning,
                        message: "\(origin): \"\(text)\" is not a valid chord."
                    ))
                    continue
                }
                let updated = chord.applied(to: existing)
                if bindingsById[id] != nil {
                    bindingsById[id] = updated
                } else {
                    appended.append(updated)
                    bindingsById[id] = updated
                }
                customized.insert(id)
            }
        }

        var bindings = config.bindings.compactMap { bindingsById[$0.id] }
        bindings.append(contentsOf: appended.filter { bindingsById[$0.id] != nil })
        config.bindings = bindings

        issues.append(contentsOf: conflictIssues(in: bindings))
        issues.append(contentsOf: prefixKeyConflictIssues(in: bindings, prefixKey: config.prefixKey))
        issues.append(contentsOf: zoomAliasConflictIssues(in: bindings))
        return KeybindingResolution(config: config, customized: customized, disabled: disabled)
    }

    /// A `launch-<agent>` binding for an agent the built-ins never knew about.
    private static func synthesizedLaunchBinding(id: String, enabled: Bool) -> KeyBinding? {
        guard enabled else { return nil }
        let agentId = String(id.dropFirst("launch-".count))
        return KeyBinding(
            id: id,
            label: "Launch \(defaultName(for: agentId))",
            description: "Launch the \(agentId) agent",
            category: .agents,
            defaultKeys: "",
            mode: .direct,
            key: ""
        )
    }

    /// `zoom-in` deliberately answers to both `=` and `+`, since the character
    /// depends on the keyboard layout. That alias is invisible to the chord
    /// comparison, so a binding on the other spelling would be shadowed with no
    /// warning at all.
    private static func zoomAliasConflictIssues(in bindings: [KeyBinding]) -> [ConfigIssue] {
        guard let zoomIn = bindings.first(where: { $0.id == "zoom-in" }),
              zoomIn.mode == .direct,
              zoomIn.key == "="
        else { return [] }

        return bindings
            .filter { $0.id != "zoom-in" && $0.mode == .direct && $0.key == "+" && $0.meta == zoomIn.meta }
            .map { binding in
                .init(
                    severity: .warning,
                    message: "\"\(binding.id)\" is bound to \(KeyChord(binding: binding).displayString), which \"zoom-in\" also answers to; only \"zoom-in\" will fire."
                )
            }
    }

    /// The prefix is matched before any direct binding, so choosing a prefix
    /// key that some Ctrl chord already uses takes that shortcut away — which
    /// looks like a broken keyboard rather than a settings choice.
    private static func prefixKeyConflictIssues(
        in bindings: [KeyBinding],
        prefixKey: String
    ) -> [ConfigIssue] {
        bindings
            .filter {
                $0.mode == .direct
                    && $0.key == prefixKey
                    && $0.ctrl == true
                    && $0.meta != true
                    && $0.shift != true
            }
            .map { binding in
                .init(
                    severity: .warning,
                    message: "keybindings.prefixKey \"\(prefixKey)\" takes over Ctrl+\(prefixKey.uppercased()), so \"\(binding.id)\" will never fire."
                )
            }
    }

    /// Two shortcuts on the same chord means one of them silently never fires
    /// (`first(where:)` wins in KeybindingManager), so say so out loud.
    private static func conflictIssues(in bindings: [KeyBinding]) -> [ConfigIssue] {
        var seen: [KeyChord: String] = [:]
        var issues: [ConfigIssue] = []
        for binding in bindings {
            let chord = KeyChord(binding: binding)
            if let owner = seen[chord] {
                issues.append(.init(
                    severity: .warning,
                    message: "\"\(binding.id)\" and \"\(owner)\" are both bound to \(chord.displayString); only \"\(owner)\" will fire."
                ))
            } else {
                seen[chord] = binding.id
            }
        }
        return issues
    }
}
