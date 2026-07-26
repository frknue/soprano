import AppKit

/// Runtime authority for everything `settings.json` owns.
///
/// The file is the source of truth and this store is its in-memory projection:
/// the UI reads resolved values from here and writes changes back *through*
/// here, so a click in Settings and a hand edit in the file are the same
/// operation. Editing the file applies immediately — the watcher reloads it.
@MainActor
final class ConfigStore {
    static let shared = ConfigStore(fileURL: ConfigFile.url)

    /// The file this store owns. Injectable so tests never touch the real
    /// `~/.config/soprano/settings.json`, the same way persisted types here
    /// accept a `UserDefaults`.
    let fileURL: URL

    /// Raw file text, kept verbatim so surgical writes preserve comments.
    private(set) var text: String = ""
    private(set) var config: SopranoConfig = .empty
    private(set) var resolved: ResolvedConfig = .defaults

    var settings: AppSettings { resolved.settings }
    var keybindings: KeyBindingConfig { resolved.keybindings }
    var displayPath: String { ConfigFile.displayPath(for: fileURL) }

    /// Problems with the file itself — unreadable, unparseable, unwritable.
    ///
    /// Held apart from `resolved.issues` (which describe the *contents* of the
    /// last document that parsed) because the two have different lifetimes: a
    /// syntax error keeps the previous resolution alive, and folding the two
    /// lists together would append a fresh copy of the error on every reload.
    private(set) var fileIssues: [ConfigIssue] = []

    var issues: [ConfigIssue] { fileIssues + resolved.issues }

    private var observers: [String: () -> Void] = [:]
    private var watcher: ConfigFileWatcher?
    /// Text this store just wrote — used to ignore the watcher event our own
    /// save produces, so a UI edit does not round-trip into a redundant reload.
    private var selfWrittenText: String?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Lifecycle

    /// Seeds the file on first run, loads it, and starts watching.
    ///
    /// The seed values default to what the pre-settings.json build persisted in
    /// `UserDefaults`; tests pass them explicitly to stay off the real domain.
    func start(
        watching: Bool = true,
        seedSettings: AppSettings? = nil,
        seedKeybindings: KeyBindingConfig? = nil
    ) {
        do {
            text = try ConfigFile.createIfMissing(
                settings: seedSettings ?? AppSettings.load(),
                keybindings: seedKeybindings ?? DefaultKeybindings.load(),
                at: fileURL
            )
        } catch {
            text = (try? ConfigFile.read(at: fileURL)) ?? ""
            fileIssues = [.init(
                severity: .error,
                message: "Could not create \(displayPath): \(error.localizedDescription)"
            )]
            applyResolution(SopranoConfig.empty.resolved())
            return
        }

        applyLoadedText(text)
        if watching {
            startWatching()
        }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        let watcher = ConfigFileWatcher(url: fileURL) { [weak self] in
            Task { @MainActor in
                self?.reloadFromDisk()
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: - Loading

    /// Re-reads the file. Called by the watcher and by "Reload" in the UI.
    func reloadFromDisk() {
        let diskText: String
        do {
            // A missing file is a legitimate empty configuration; a file that
            // exists but cannot be read is not. Collapsing the two would
            // silently reset the app to defaults when a permission changes.
            diskText = try ConfigFile.read(at: fileURL) ?? ""
        } catch {
            fileIssues = [.init(
                severity: .error,
                message: "Could not read \(displayPath): \(error.localizedDescription)"
            )]
            notifyObservers()
            return
        }

        if let selfWrittenText, selfWrittenText == diskText {
            // Our own save came back around; state is already current.
            self.selfWrittenText = nil
            return
        }
        selfWrittenText = nil
        // Unchanged text needs no work, unless we are sitting on a file-level
        // problem worth re-attempting (a permission that may have been fixed).
        guard diskText != text || !fileIssues.isEmpty else { return }
        text = diskText
        applyLoadedText(diskText)
        notifyObservers()
    }

    private func applyLoadedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            config = .empty
            fileIssues = []
            applyResolution(SopranoConfig.empty.resolved())
            return
        }

        do {
            let decoded = try JSONCText.decode(SopranoConfig.self, from: text)
            config = decoded
            fileIssues = []
            applyResolution(decoded.resolved())
        } catch let error as JSONCText.ParseError {
            // Keep the last good values running rather than dropping the user
            // into a default workspace because of a missing comma. `resolved`
            // is deliberately left alone: it still describes the document that
            // last parsed, and that is what the app is running on.
            fileIssues = [.init(
                severity: .error,
                message: "\(displayPath): \(error.message)",
                line: error.line
            )]
        } catch let error as DecodingError {
            fileIssues = [.init(
                severity: .error,
                message: "\(displayPath): \(Self.describe(error))"
            )]
        } catch {
            fileIssues = [.init(
                severity: .error,
                message: "\(displayPath): \(error.localizedDescription)"
            )]
        }
    }

    /// Turns a `DecodingError` into something a person can act on.
    ///
    /// The stock `localizedDescription` is "The data couldn't be read because
    /// it isn't in the correct format", which names neither the key nor the
    /// type — useless when the whole document is being rejected over one value.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let components = context.codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? key.stringValue
            }
            return components.isEmpty ? "the document" : components.joined(separator: ".")
        }

        switch error {
        case .typeMismatch(let type, let context):
            return "\(path(context)) should be \(readable(type)). Nothing in the file was applied."
        case .valueNotFound(let type, let context):
            return "\(path(context)) is empty but should be \(readable(type)). Nothing in the file was applied."
        case .keyNotFound(let key, let context):
            let location = context.codingPath.isEmpty ? "the document" : path(context)
            return "\(location) is missing \"\(key.stringValue)\". Nothing in the file was applied."
        case .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func readable(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "text"
        case is Bool.Type: return "true or false"
        case is Int.Type, is Double.Type: return "a number"
        case is [Any].Type: return "a list"
        default: return "of type \(type)"
        }
    }

    private func applyResolution(_ resolution: ResolvedConfig) {
        resolved = resolution
        AgentCatalog.replaceAll(with: resolution.agents)
    }

    // MARK: - Writing

    /// Sets one key, preserving the rest of the document byte for byte.
    ///
    /// `value` takes JSONSerialization-compatible values; `NSNull()` writes a
    /// JSON `null`.
    @discardableResult
    func write(_ value: Any, at path: [String]) -> Bool {
        applyEdit { try JSONCText.setting(value, at: path, in: $0) }
    }

    /// Removes one key so the built-in default takes over again.
    @discardableResult
    func remove(at path: [String]) -> Bool {
        applyEdit { try JSONCText.removing(at: path, in: $0) }
    }

    private func applyEdit(_ edit: (String) throws -> String) -> Bool {
        do {
            // Always edit what is on disk right now, not what we last read.
            // The watcher is debounced, so an external edit can be in flight
            // while a control is clicked; splicing into stale text would
            // rewrite the file and quietly discard the user's own change.
            if let current = try ConfigFile.read(at: fileURL), current != text {
                text = current
                applyLoadedText(current)
            }
            let updated = try edit(text)
            guard updated != text else { return true }
            try ConfigFile.write(updated, to: fileURL)
            selfWrittenText = updated
            text = updated
            applyLoadedText(updated)
            notifyObservers()
            return true
        } catch {
            fileIssues = [.init(
                severity: .error,
                message: "Could not update \(displayPath): \(error.localizedDescription)"
            )]
            notifyObservers()
            return false
        }
    }

    // MARK: - Observers

    func addObserver(id: String, _ handler: @escaping () -> Void) {
        observers[id] = handler
    }

    func removeObserver(id: String) {
        observers[id] = nil
    }

    private func notifyObservers() {
        for handler in observers.values {
            handler()
        }
    }

    // MARK: - Opening

    /// Opens the file in the user's default editor for `.json`.
    func openInEditor() {
        if !ConfigFile.exists(at: fileURL) {
            // Opening a path that does not exist would just fail; write the
            // template first so the editor has something to show.
            _ = try? ConfigFile.createIfMissing(
                settings: settings,
                keybindings: keybindings,
                at: fileURL
            )
        }
        NSWorkspace.shared.open(fileURL)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
