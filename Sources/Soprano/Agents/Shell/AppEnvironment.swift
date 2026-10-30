import AppKit
import OSLog
import SopranoAgentsCore

/// Resolved user settings (from ~/.config/soprano-agents/settings.json).
struct AppSettings: Equatable, Sendable {
    /// What sending while a turn runs does by default (⌘↩ does the other).
    enum FollowUp: String, Equatable, Sendable, CaseIterable {
        case steer
        case queue
    }

    /// Chat lane width: the 46rem lane, 72rem, or the full column.
    enum ChatWidth: String, Equatable, Sendable, CaseIterable {
        case normal
        case wide
        case full

        var maxWidth: CGFloat {
            switch self {
            case .normal: Metrics.chatMaxWidth
            case .wide: 1152
            case .full: .greatestFiniteMagnitude
            }
        }
    }

    /// "soprano" (follow Soprano's own theme and appearance) or an id from `AppTheme.options`.
    var theme: String = "soprano"

    var defaultProvider: ProviderKind = .omp
    /// nil = the provider's default model.
    var defaultModel: String?
    var defaultRuntimeMode: RuntimeMode = .fullAccess
    /// Executable overrides; nil = find on PATH.
    var ompPath: String?
    var codexPath: String?
    var claudePath: String?

    var textGenerationProvider: ProviderKind = .codex
    /// nil = the provider's text-generation default (`gpt-6-luna`, `claude-haiku-5-5`).
    var textGenerationModel: String?
    var generateTitles = true

    var worktreesDirectory: String = NSString(string: "~/.soprano-agents/worktrees").expandingTildeInPath
    var branchPrefix = "soprano"

    var followUp: FollowUp = .steer
    var chatWidth: ChatWidth = .normal

    var notificationsEnabled = true
    var notificationSound = true

    /// Open-in-editor target id (`cursor`, `vscode`, `zed`, `xcode`, `finder`, …); nil = first installed.
    var editorApp: String?

    static let defaults = AppSettings()

    /// The engine's view of these settings.
    var engineSettings: EngineSettings {
        let model = ModelSelection(provider: defaultProvider, model: defaultModel ?? defaultProvider.defaultModel)
        let generation = ModelSelection(
            provider: textGenerationProvider,
            model: textGenerationModel ?? textGenerationProvider.textGenerationModel,
            options: textGenerationProvider == .codex ? [ModelOptionID.effort: "low"] : [:]
        )
        return EngineSettings(
            defaultModel: model,
            defaultRuntimeMode: defaultRuntimeMode,
            textGenerationModel: generation,
            branchPrefix: branchPrefix,
            worktreesDirectory: worktreesDirectory,
            generateTitles: generateTitles,
            ompPath: ompPath,
            codexPath: codexPath,
            claudePath: claudePath
        )
    }
}

private let settingsLog = Logger(subsystem: "com.soprano.agents", category: "settings")

/// How `folio` picks Paper or Ink. Mirrors the `appearance` key of Soprano's
/// settings.json: follow macOS, or pin light (Paper) or dark (Ink).
enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// The live theme. Views read `theme` when they build and re-style in their
/// observer when it changes.
///
/// `theme: "soprano"` follows the `theme` and `appearance` keys of Soprano's
/// settings.json (watched live); Folio when that file, key or id is missing or
/// unknown. `folio` resolves to Folio Paper or Folio Ink by appearance, so a
/// macOS light/dark flip changes the theme too.
@MainActor
final class ThemeCenter {
    static let shared = ThemeCenter()

    /// Vendored manager: resolves id + appearance into the palette and drives
    /// `NSApp.appearance`; Soprano components (CommandPalettePanel) take it.
    let manager = ThemeManager(themeId: AppTheme.folioId)

    var theme: AppTheme { manager.currentTheme }

    /// Soprano's settings.json, read when following Soprano.
    let sopranoSettingsURL: URL
    /// The `theme` setting currently applied ("soprano" or a theme id).
    private(set) var setting = "soprano"
    /// Forced appearance (snapshot `--appearance`); wins over macOS and Soprano's `appearance`.
    /// Folio then resolves to Paper or Ink; single-appearance themes keep their palette.
    var forcedAppearance: AppTheme.Appearance? {
        didSet { applyResolvedTheme() }
    }

    private let observers = ObserverList<AppTheme>()
    private var sopranoWatcher: ConfigFileWatcher?
    private var watchesSoprano = false

    init(sopranoSettingsURL: URL = SettingsFile.sopranoURL()) {
        self.sopranoSettingsURL = sopranoSettingsURL
        manager.onThemeChanged = { [weak self] theme in
            self?.observers.notify(theme)
        }
    }

    /// Handlers fire after the theme changes, until `owner` is deallocated.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (AppTheme) -> Void) {
        observers.add(owner, handler)
    }

    /// Applies the `theme` setting. `watch` keeps following Soprano's file live.
    func apply(setting: String, watch: Bool = true) {
        self.setting = setting
        watchesSoprano = watch && setting == "soprano"
        updateSopranoWatcher()
        applyResolvedTheme()
    }

    /// Re-reads Soprano's settings (called by the watcher).
    func reloadSopranoTheme() {
        applyResolvedTheme()
    }

    /// Lets the theme drive `NSApp.appearance` and follow macOS light/dark
    /// changes. Called once by the app at launch; snapshots and tests never do.
    func startDrivingApplicationAppearance() {
        manager.startDrivingApplicationAppearance()
    }

    /// The concrete palette id `setting` resolves to, given Soprano's settings
    /// text and the system appearance (`folio` → `folio-paper` / `folio-ink`).
    nonisolated static func resolveThemeID(
        setting: String,
        sopranoSettingsText: String?,
        systemAppearance: AppTheme.Appearance
    ) -> String {
        let source = themeSource(setting: setting, sopranoSettingsText: sopranoSettingsText)
        let effective: AppTheme.Appearance = switch source.appearance {
        case .system: systemAppearance
        case .light: .light
        case .dark: .dark
        }
        return AppTheme.theme(for: source.themeId, appearance: effective).id
    }

    /// The theme id and appearance preference handed to the manager: Soprano's
    /// `theme` + `appearance` for "soprano", otherwise the own id under the
    /// system appearance. Unknown ids become `folio`.
    private nonisolated static func themeSource(
        setting: String,
        sopranoSettingsText: String?
    ) -> (themeId: String, appearance: AppearancePreference) {
        guard setting == "soprano" else {
            return (AppTheme.isKnownId(setting) ? setting : AppTheme.folioId, .system)
        }
        guard let text = sopranoSettingsText,
              let data = try? JSONCText.strictJSONData(from: text),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (AppTheme.folioId, .system)
        }
        let themeId = (root["theme"] as? String).flatMap { AppTheme.isKnownId($0) ? $0 : nil } ?? AppTheme.folioId
        let appearance = (root["appearance"] as? String).flatMap(AppearancePreference.init(rawValue:)) ?? .system
        return (themeId, appearance)
    }

    /// Hands the resolved source to the manager, which notifies observers
    /// (through `onThemeChanged`) only when the concrete palette changes.
    private func applyResolvedTheme() {
        let text = setting == "soprano" ? (try? SettingsFile.read(at: sopranoSettingsURL)) ?? nil : nil
        let source = Self.themeSource(setting: setting, sopranoSettingsText: text)
        let appearance: AppearancePreference = switch forcedAppearance {
        case .light: .light
        case .dark: .dark
        case nil: source.appearance
        }
        manager.update(themeId: source.themeId, appearance: appearance)
    }

    private func updateSopranoWatcher() {
        if watchesSoprano {
            guard sopranoWatcher == nil else { return }
            let watcher = ConfigFileWatcher(url: sopranoSettingsURL) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reloadSopranoTheme()
                }
            }
            watcher.start()
            sopranoWatcher = watcher
        } else {
            sopranoWatcher?.stop()
            sopranoWatcher = nil
        }
    }
}

/// Settings and key bindings, live-reloaded from settings.json.
///
/// A syntax error keeps the last good settings running and is reported as an
/// error issue; bad values become warnings (logged), never launch failures.
@MainActor
final class SettingsCenter {
    static let shared = SettingsCenter()

    let fileURL: URL
    /// Commands the keymap resolves against.
    let registry: CommandRegistry

    private(set) var settings = AppSettings.defaults
    private(set) var keybindingSettings = KeybindingSettings()
    /// Problems reading the file (syntax errors); the last good resolution stays.
    private(set) var fileIssues: [ConfigIssue] = []
    private(set) var settingsIssues: [ConfigIssue] = []
    var issues: [ConfigIssue] { fileIssues + settingsIssues + keymap.issues }

    private var cachedKeymap: Keymap?
    private var cachedKeymapCommandCount = -1
    private var lastText: String?
    private var watcher: ConfigFileWatcher?
    private let observers = ObserverList<Void>()

    init(fileURL: URL = SettingsFile.url(), registry: CommandRegistry? = nil) {
        self.fileURL = fileURL
        self.registry = registry ?? .shared
    }

    var displayPath: String { SettingsFile.displayPath(for: fileURL) }

    /// Creates the file from the template when missing (unless `createIfMissing`
    /// is false, e.g. snapshots), loads it, and starts watching it.
    func start(createIfMissing: Bool = true, watching: Bool = true) {
        if createIfMissing {
            do {
                try SettingsFile.createIfMissing(at: fileURL)
            } catch {
                settingsLog.error("Could not create \(self.displayPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        reloadFromDisk(notify: false)
        if watching, watcher == nil {
            let watcher = ConfigFileWatcher(url: fileURL) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reloadFromDisk()
                }
            }
            watcher.start()
            self.watcher = watcher
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    func reloadFromDisk(notify: Bool = true) {
        let text: String?
        do {
            text = try SettingsFile.read(at: fileURL)
        } catch {
            fileIssues = [ConfigIssue(severity: .error, message: "Could not read \(displayPath): \(error.localizedDescription)")]
            logIssues()
            if notify { observers.notify(()) }
            return
        }
        guard text != lastText || lastText == nil else { return }
        lastText = text
        apply(text: text ?? "{}", notify: notify)
    }

    /// Applies a document. A syntax error keeps the last good settings.
    func apply(text: String, notify: Bool = true) {
        do {
            let resolved = try SettingsResolver.resolve(text: text)
            fileIssues = []
            settings = resolved.settings
            keybindingSettings = resolved.keybindings
            settingsIssues = resolved.issues
            cachedKeymap = nil
        } catch let error as JSONCText.ParseError {
            fileIssues = [ConfigIssue(severity: .error, message: "\(displayPath): \(error.message)", line: error.line)]
        } catch {
            fileIssues = [ConfigIssue(severity: .error, message: "\(displayPath): \(error.localizedDescription)")]
        }
        logIssues()
        if notify { observers.notify(()) }
    }

    /// Key bindings resolved against the registry; rebuilt when settings or
    /// the registered commands change.
    var keymap: Keymap {
        if let cachedKeymap, cachedKeymapCommandCount == registry.commands.count {
            return cachedKeymap
        }
        let keymap = Keymap.resolve(commands: registry.commands, settings: keybindingSettings)
        cachedKeymap = keymap
        cachedKeymapCommandCount = registry.commands.count
        return keymap
    }

    /// Re-resolves the keymap after commands were registered, logging its issues.
    func reloadKeymap() {
        cachedKeymap = nil
        logIssues()
        observers.notify(())
    }

    /// Chords bound to a command after settings.json overrides; the first is
    /// the one menus and the palette display. Empty when unbound.
    func chords(for commandID: String) -> [KeyChord] {
        keymap.chords(for: commandID)
    }

    /// Display text of the command's first chord ("⌘B", "Prefix → P", "J"), nil when unbound.
    func shortcutText(for commandID: String) -> String? {
        chords(for: commandID).first?.displayString
    }

    /// K1 keycaps of the command's first chord (`["⌘B"]`, `["⌃A", "P"]`), nil when unbound.
    func keycaps(for commandID: String) -> [String]? {
        chords(for: commandID).first?.keycaps(prefixKey: keymap.prefixKey)
    }

    /// Handlers fire after settings.json changes, until `owner` is deallocated.
    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.add(owner) { _ in handler() }
    }

    /// The value at `path` exactly as settings.json writes it (unexpanded
    /// paths, unknown keys included); nil when absent or unreadable.
    func configuredValue(at path: [String]) -> Any? {
        guard let text = lastText,
              let data = try? JSONCText.strictJSONData(from: text),
              var value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        for key in path {
            guard let object = value as? [String: Any], let child = object[key] else { return nil }
            value = child
        }
        return value
    }

    /// Sets one key in settings.json, keeping comments, key order and
    /// indentation, and applies the result. Missing parent objects are created.
    /// Returns false when the file could not be edited (the error becomes an issue).
    @discardableResult
    func write(_ value: Any, at path: [String]) -> Bool {
        edit { try JSONCText.setting(value, at: path, in: $0) }
    }

    /// Removes one key so its built-in default applies again.
    @discardableResult
    func remove(at path: [String]) -> Bool {
        edit { try JSONCText.removing(at: path, in: $0) }
    }

    private func edit(_ change: (String) throws -> String) -> Bool {
        do {
            // Edit what is on disk now, not the last text read: the watcher is
            // debounced, so a hand edit may not have arrived yet.
            let existing = try SettingsFile.read(at: fileURL)
            let current = existing ?? SettingsFile.template
            let updated = try change(current)
            if updated != current || existing == nil {
                try SettingsFile.write(updated, to: fileURL)
            }
            lastText = updated
            apply(text: updated)
            return true
        } catch let error as JSONCText.ParseError {
            fileIssues = [ConfigIssue(severity: .error, message: "Could not update \(displayPath): \(error.message)", line: error.line)]
        } catch {
            fileIssues = [ConfigIssue(severity: .error, message: "Could not update \(displayPath): \(error.localizedDescription)")]
        }
        logIssues()
        observers.notify(())
        return false
    }

    /// Opens settings.json in the user's editor, creating it first if needed.
    func openInEditor() {
        _ = try? SettingsFile.createIfMissing(at: fileURL)
        let workspace = NSWorkspace.shared
        if let editor = workspace.urlForApplication(toOpen: fileURL) {
            workspace.open([fileURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else if let textEdit = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([fileURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Shows settings.json in Finder, creating it first if needed.
    func revealInFinder() {
        _ = try? SettingsFile.createIfMissing(at: fileURL)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private var loggedIssueIDs: Set<String> = []

    private func logIssues() {
        let current = issues
        for issue in current where !loggedIssueIDs.contains(issue.id) {
            switch issue.severity {
            case .error: settingsLog.error("\(issue.message, privacy: .public)")
            case .warning: settingsLog.warning("\(issue.message, privacy: .public)")
            }
        }
        loggedIssueIDs = Set(current.map(\.id))
    }
}
