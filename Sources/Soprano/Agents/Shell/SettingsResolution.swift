import Foundation
import SopranoAgentsCore

/// A problem found while resolving settings.json. Issues never block startup:
/// a bad value keeps its default and is logged (Soprano's `ConfigIssue`).
struct ConfigIssue: Equatable, Identifiable, Sendable {
    enum Severity: Equatable, Sendable {
        /// The document could not be read at all; the last good settings stay in force.
        case error
        /// One key was ignored; everything else applied.
        case warning
    }

    let severity: Severity
    let message: String
    /// 1-based line in settings.json, when the problem has a position.
    var line: Int?

    var id: String { "\(severity)-\(line ?? 0)-\(message)" }
}

/// A `keybindings.bindings` value: one chord, several, or `null` to unbind.
enum BindingOverride: Equatable, Sendable {
    case chords([String])
    case disabled
}

/// Raw keybinding settings, applied to the command registry by `Keymap.resolve`.
struct KeybindingSettings: Equatable, Sendable {
    var prefixKey = "a"
    var prefixTimeoutMs = 1500
    var overrides: [String: BindingOverride] = [:]
}

/// settings.json applied on top of the defaults.
struct ResolvedSettings: Equatable, Sendable {
    var settings = AppSettings.defaults
    var keybindings = KeybindingSettings()
    var issues: [ConfigIssue] = []

    static let defaults = ResolvedSettings()
}

enum SettingsResolver {
    enum Limits {
        static let prefixTimeoutMs = 300...5000
    }

    /// Parses JSONC text. Throws `JSONCText.ParseError` (or a decoding error)
    /// when the document is not a JSON object.
    static func resolve(text: String) throws -> ResolvedSettings {
        let data = try JSONCText.strictJSONData(from: text)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let root = object as? [String: Any] else {
            throw JSONCText.ParseError(message: "The settings document must be a JSON object", line: 1, column: 1)
        }
        return resolve(root)
    }

    static func resolve(_ root: [String: Any]) -> ResolvedSettings {
        var result = ResolvedSettings()
        var issues: [ConfigIssue] = []
        func warn(_ message: String) {
            issues.append(ConfigIssue(severity: .warning, message: message))
        }

        let knownTopLevel: Set<String> = ["theme", "agents", "providers", "textGeneration", "worktrees", "chat", "notifications", "editor", "keybindings"]
        for key in root.keys.sorted() where !knownTopLevel.contains(key) {
            warn("Unknown setting \"\(key)\".")
        }

        if let value = root["theme"] {
            if let theme = value as? String, PaletteCenter.t3ThemeIDs.contains(theme) || theme == "soprano" || AppTheme.isKnownId(theme) {
                result.settings.theme = theme
            } else {
                let known = (PaletteCenter.t3ThemeIDs + ["soprano"] + AppTheme.options.map(\.id)).joined(separator: ", ")
                warn("Unknown theme \(describe(value)). Known themes: \(known).")
            }
        }

        if let agents = section("agents", in: root, warn: warn) {
            for key in agents.keys.sorted() where !["defaultProvider", "defaultModel", "defaultRuntimeMode"].contains(key) {
                warn("Unknown setting \"agents.\(key)\".")
            }
            if let value = agents["defaultProvider"] {
                if let raw = value as? String, let provider = ProviderKind(rawValue: raw) {
                    result.settings.defaultProvider = provider
                } else {
                    warn("agents.defaultProvider must be \"omp\", \"codex\" or \"claude\".")
                }
            }
            if let value = agents["defaultModel"] {
                if let model = value as? String, !model.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.settings.defaultModel = model
                } else {
                    warn("agents.defaultModel must be a model id string.")
                }
            }
            if let value = agents["defaultRuntimeMode"] {
                if let raw = value as? String, let mode = RuntimeMode(rawValue: raw) {
                    result.settings.defaultRuntimeMode = mode
                } else {
                    let known = RuntimeMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                    warn("agents.defaultRuntimeMode must be one of \(known).")
                }
            }
        }

        if let providers = section("providers", in: root, warn: warn) {
            for key in providers.keys.sorted() where !["ompPath", "codexPath", "claudePath"].contains(key) {
                warn("Unknown setting \"providers.\(key)\".")
            }
            result.settings.ompPath = optionalPath(providers["ompPath"], key: "providers.ompPath", warn: warn) ?? result.settings.ompPath
            result.settings.codexPath = optionalPath(providers["codexPath"], key: "providers.codexPath", warn: warn) ?? result.settings.codexPath
            result.settings.claudePath = optionalPath(providers["claudePath"], key: "providers.claudePath", warn: warn) ?? result.settings.claudePath
        }

        if let generation = section("textGeneration", in: root, warn: warn) {
            for key in generation.keys.sorted() where !["provider", "model", "titles"].contains(key) {
                warn("Unknown setting \"textGeneration.\(key)\".")
            }
            if let value = generation["provider"] {
                if let raw = value as? String, let provider = ProviderKind(rawValue: raw) {
                    result.settings.textGenerationProvider = provider
                } else {
                    warn("textGeneration.provider must be \"omp\", \"codex\" or \"claude\".")
                }
            }
            if let value = generation["model"] {
                if let model = value as? String, !model.isEmpty {
                    result.settings.textGenerationModel = model
                } else {
                    warn("textGeneration.model must be a model id string.")
                }
            }
            if let value = generation["titles"] {
                if let enabled = value as? Bool {
                    result.settings.generateTitles = enabled
                } else {
                    warn("textGeneration.titles must be true or false.")
                }
            }
        }

        if let worktrees = section("worktrees", in: root, warn: warn) {
            for key in worktrees.keys.sorted() where !["directory", "branchPrefix"].contains(key) {
                warn("Unknown setting \"worktrees.\(key)\".")
            }
            if let value = worktrees["directory"] {
                if let path = value as? String, !path.isEmpty, expandingTilde(path).hasPrefix("/"), expandingTilde(path) != "/" {
                    result.settings.worktreesDirectory = expandingTilde(path)
                } else {
                    warn("worktrees.directory must be an absolute folder (not /).")
                }
            }
            if let value = worktrees["branchPrefix"] {
                if let prefix = value as? String, !prefix.contains(" ") {
                    result.settings.branchPrefix = prefix
                } else {
                    warn("worktrees.branchPrefix must be a string without spaces.")
                }
            }
        }

        if let chat = section("chat", in: root, warn: warn) {
            for key in chat.keys.sorted() where !["followUp", "width"].contains(key) {
                warn("Unknown setting \"chat.\(key)\".")
            }
            if let value = chat["followUp"] {
                if let raw = value as? String, let mode = AppSettings.FollowUp(rawValue: raw) {
                    result.settings.followUp = mode
                } else {
                    warn("chat.followUp must be \"steer\" or \"queue\".")
                }
            }
            if let value = chat["width"] {
                if let raw = value as? String, let width = AppSettings.ChatWidth(rawValue: raw) {
                    result.settings.chatWidth = width
                } else {
                    warn("chat.width must be \"normal\", \"wide\" or \"full\".")
                }
            }
        }

        if let notifications = section("notifications", in: root, warn: warn) {
            for key in notifications.keys.sorted() where !["enabled", "sound"].contains(key) {
                warn("Unknown setting \"notifications.\(key)\".")
            }
            if let value = notifications["enabled"] {
                if let enabled = value as? Bool { result.settings.notificationsEnabled = enabled } else { warn("notifications.enabled must be true or false.") }
            }
            if let value = notifications["sound"] {
                if let enabled = value as? Bool { result.settings.notificationSound = enabled } else { warn("notifications.sound must be true or false.") }
            }
        }

        if let editor = section("editor", in: root, warn: warn) {
            for key in editor.keys.sorted() where key != "app" {
                warn("Unknown setting \"editor.\(key)\".")
            }
            if let value = editor["app"] {
                if let app = value as? String, !app.isEmpty {
                    result.settings.editorApp = app
                } else if value is NSNull {
                    result.settings.editorApp = nil
                } else {
                    warn("editor.app must be an editor id (cursor, vscode, zed, xcode, finder, …) or null.")
                }
            }
        }

        if let keybindings = section("keybindings", in: root, warn: warn) {
            for key in keybindings.keys.sorted() where !["prefixKey", "prefixTimeoutMs", "bindings"].contains(key) {
                warn("Unknown setting \"keybindings.\(key)\".")
            }
            if let value = keybindings["prefixKey"] {
                let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.count == 1 {
                    result.keybindings.prefixKey = trimmed.lowercased()
                } else {
                    warn("keybindings.prefixKey must be a single character; kept \"\(result.keybindings.prefixKey)\".")
                }
            }
            if let value = keybindings["prefixTimeoutMs"] {
                if let timeout = integer(value) {
                    let clamped = clamp(timeout, to: Limits.prefixTimeoutMs)
                    if clamped != timeout {
                        warn("keybindings.prefixTimeoutMs must be \(Limits.prefixTimeoutMs.lowerBound)–\(Limits.prefixTimeoutMs.upperBound); clamped to \(clamped).")
                    }
                    result.keybindings.prefixTimeoutMs = clamped
                } else {
                    warn("keybindings.prefixTimeoutMs must be a number.")
                }
            }
            if let value = keybindings["bindings"] {
                if let bindings = value as? [String: Any] {
                    for id in bindings.keys.sorted() {
                        let entry = bindings[id]
                        if entry is NSNull {
                            result.keybindings.overrides[id] = .disabled
                        } else if let chord = entry as? String {
                            result.keybindings.overrides[id] = .chords([chord])
                        } else if let chords = entry as? [Any], chords.allSatisfy({ $0 is String }) {
                            result.keybindings.overrides[id] = .chords(chords.compactMap { $0 as? String })
                        } else {
                            warn("keybindings.bindings.\(id) must be a chord string, an array of chords, or null.")
                        }
                    }
                } else {
                    warn("keybindings.bindings must be an object of command id → chord.")
                }
            }
        }

        result.issues = issues
        return result
    }

    private static func section(
        _ key: String,
        in root: [String: Any],
        warn: (String) -> Void
    ) -> [String: Any]? {
        guard let value = root[key] else { return nil }
        guard let object = value as? [String: Any] else {
            warn("\"\(key)\" must be an object.")
            return nil
        }
        return object
    }

    private static func integer(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1e9 else { return nil }
        return Int(double)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(range.lowerBound, value), range.upperBound)
    }

    /// A path string, `null` (nil inside `.some`), or a warning (nil).
    private static func optionalPath(_ value: Any?, key: String, warn: (String) -> Void) -> String?? {
        guard let value else { return nil }
        if value is NSNull { return .some(nil) }
        if let path = value as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return .some(expandingTilde(path))
        }
        warn("\(key) must be a path string or null.")
        return nil
    }

    private static func expandingTilde(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func describe(_ value: Any) -> String {
        if let string = value as? String { return "\"\(string)\"" }
        return String(describing: value)
    }
}
