import Foundation

/// Location, creation, and reading/writing of `settings.json`.
///
/// The file lives where a terminal user expects a dotfile — `~/.config/soprano/`,
/// honoring `XDG_CONFIG_HOME` — so it can be symlinked out of a dotfiles repo
/// the same way `~/.config/ghostty/config` is.
enum ConfigFile {
    /// Escape hatch used by tests and by anyone running two configurations.
    static let pathEnvironmentKey = "SOPRANO_CONFIG"

    static var directoryURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[pathEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
                .standardizedFileURL
                .deletingLastPathComponent()
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: NSString(string: xdg).expandingTildeInPath)
                .standardizedFileURL
                .appendingPathComponent("soprano", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/soprano", isDirectory: true)
    }

    static var url: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[pathEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
                .standardizedFileURL
        }
        return directoryURL.appendingPathComponent("settings.json", isDirectory: false)
    }

    /// The path as a user would type it, with `$HOME` folded back to `~`.
    static func displayPath(for url: URL = ConfigFile.url) -> String {
        abbreviatingHome(url.path)
    }

    static func exists(at url: URL = ConfigFile.url) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Returns the file's text, or nil when it does not exist yet.
    static func read(at url: URL = ConfigFile.url) throws -> String? {
        guard exists(at: url) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes atomically so a watcher never observes a half-written document.
    ///
    /// Writes through a symlink rather than over it: an atomic write is a
    /// rename onto the path, which would replace the link with a regular file
    /// and quietly detach `settings.json` from the dotfiles repo it points
    /// into — the exact setup the README recommends.
    static func write(_ text: String, to url: URL = ConfigFile.url) throws {
        let target = resolvingSymlink(url)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: target, atomically: true, encoding: .utf8)
    }

    /// The file a symlink points at, following chains, or the path itself.
    private static func resolvingSymlink(_ url: URL) -> URL {
        var resolved = url
        var hops = 0
        // Bounded so a link cycle cannot spin here.
        while hops < 8,
              let destination = try? FileManager.default.destinationOfSymbolicLink(
                  atPath: resolved.path
              ) {
            let next = URL(fileURLWithPath: destination, relativeTo: resolved.deletingLastPathComponent())
            resolved = next.standardizedFileURL
            hops += 1
        }
        return resolved
    }

    // MARK: - First run

    /// Creates the file if it is missing, seeded from whatever the user had
    /// already configured through the UI, and returns its text.
    ///
    /// Seeding matters: this feature moves the source of truth off
    /// `UserDefaults`, and silently resetting someone's theme and keybindings
    /// on upgrade would be a bug, not a fresh start.
    @discardableResult
    static func createIfMissing(
        settings: AppSettings,
        keybindings: KeyBindingConfig,
        at url: URL = ConfigFile.url
    ) throws -> String {
        if let existing = try read(at: url) {
            return existing
        }
        let text = template(settings: settings, keybindings: keybindings)
        try write(text, to: url)
        return text
    }

    /// A fully commented starter document — the schema *is* the documentation,
    /// so the file explains itself without a trip to the README.
    static func template(
        settings: AppSettings,
        keybindings: KeyBindingConfig
    ) -> String {
        let themes = AppTheme.allThemes.map { "\"\($0.id)\"" }.joined(separator: " | ")
        let projectDirectories = jsonArrayLiteral(
            settings.projectDirectories.map(abbreviatingHome),
            indent: "  "
        )
        let bindingOverrides = seededBindingOverrides(keybindings)

        return """
        // Soprano settings.
        //
        // This file is the source of truth: the in-app Settings screen reads and
        // writes it, and saving here applies immediately — no restart. Comments,
        // key order, and formatting survive edits made from the UI.
        //
        // Every key is optional. Delete one to fall back to the default.
        {
          // Color theme: \(themes)
          "theme": "\(settings.themeId)",

          // Restore the previous workspace on launch.
          "restoreLastSession": \(settings.restoreLastSession),

          // Roots offered by "Open Project…" (⇧⌘P). "~" is expanded.
          "projectDirectories": \(projectDirectories),

          "notifications": {
            // Play a sound with each banner. Off by default: a pane that wants
            // you already shows a banner, an unread ring, and a status.
            // Whether banners appear at all is macOS's call — see
            // System Settings ▸ Notifications ▸ Soprano.
            "sound": \(settings.notificationSound)
          },

          "keybindings": {
            // The tmux-style prefix is Ctrl+<prefixKey>.
            "prefixKey": "\(keybindings.prefixKey)",
            "prefixTimeoutMs": \(keybindings.prefixTimeoutMs),

            // How much one prefix-resize step moves a split, in percent.
            "resizeTickPercent": \(Int(keybindings.resizeTickPercent)),

            // Rebind any action by its id — see Settings ▸ Keyboard Shortcuts
            // for the full list. Modifiers: "cmd", "ctrl", "shift", "prefix".
            // Set an action to null to turn it off.
            //
            //   "split-vertical": "prefix+v",
            //   "new-browser": "cmd+shift+b",
            //   "zoom-reset": null
            "bindings": \(bindingOverrides)
          },

          // Your own agents. Reusing a built-in id ("codex", "claude-code",
          // "opencode") patches that profile field by field; a new id defines a
          // new agent and needs at least "command". Plain terminal panes are
          // not configured here — they run your login shell.
          //
          //   {
          //     "id": "aider",
          //     "name": "Aider",
          //     "command": "aider",
          //     "args": ["--no-auto-commits"],
          //     "color": "#8bd5ca",
          //     "launchKey": "cmd+4"
          //   }
          "agents": []
        }

        """
    }

    /// Carries UI-made keybinding changes into the new file so an upgrade does
    /// not quietly revert them.
    private static func seededBindingOverrides(_ keybindings: KeyBindingConfig) -> String {
        let defaultsById = Dictionary(
            uniqueKeysWithValues: DefaultKeybindings.config.bindings.map { ($0.id, $0) }
        )
        let changed = keybindings.bindings
            .filter { binding in
                guard let fallback = defaultsById[binding.id] else { return true }
                return KeyChord(binding: binding) != KeyChord(binding: fallback)
            }
            .sorted { $0.id < $1.id }

        guard !changed.isEmpty else { return "{}" }
        let entries = changed.map { binding in
            "      \"\(binding.id)\": \"\(KeyChord(binding: binding).canonicalString)\""
        }
        return "{\n" + entries.joined(separator: ",\n") + "\n    }"
    }

    private static func jsonArrayLiteral(_ values: [String], indent: String) -> String {
        guard !values.isEmpty else { return "[]" }
        let entries = values.map { "\(indent)  \(jsonStringLiteral($0))" }
        return "[\n" + entries.joined(separator: ",\n") + "\n\(indent)]"
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// `$HOME`-relative form, so paths written by the UI read the way a person
    /// would have typed them.
    static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

// MARK: - Watching

/// Watches `settings.json` for edits made outside the app.
///
/// It watches the containing **directory** as well as the file: editors save
/// atomically by writing a temp file and renaming it over the target, which
/// destroys the original vnode and silences a file-only watch after the first
/// save. On such an event the file source is re-armed against the new inode.
///
/// `@unchecked Sendable` is sound here because every mutable property is read
/// and written only from `queue`, the serial queue that also runs both dispatch
/// sources and the debounce work item.
final class ConfigFileWatcher: @unchecked Sendable {
    private let url: URL
    private let debounceInterval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "com.soprano.config-watcher")
    private let onChange: @Sendable () -> Void

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingWork: DispatchWorkItem?
    private var pendingRearm: DispatchWorkItem?
    private var isStopped = false

    /// How long to wait before trying to watch a directory that does not exist
    /// yet. Only ever scheduled while the config directory is missing, which is
    /// a transient state (a dotfiles checkout replacing it), so this never
    /// becomes a steady-state poll.
    private let rearmInterval: DispatchTimeInterval

    init(
        url: URL = ConfigFile.url,
        debounceInterval: DispatchTimeInterval = .milliseconds(120),
        rearmInterval: DispatchTimeInterval = .seconds(2),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.debounceInterval = debounceInterval
        self.rearmInterval = rearmInterval
        self.onChange = onChange
    }

    deinit {
        fileSource?.cancel()
        directorySource?.cancel()
        pendingWork?.cancel()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = false
            self.armDirectorySource()
            self.armFileSource()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.pendingRearm?.cancel()
            self.pendingRearm = nil
            self.pendingWork?.cancel()
            self.pendingWork = nil
            self.fileSource?.cancel()
            self.fileSource = nil
            self.directorySource?.cancel()
            self.directorySource = nil
        }
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = nil
        guard !isStopped else { return }

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                // The path now points at a different inode (atomic save) or is
                // gone. Re-arm before reporting so the next save is seen too.
                self.armFileSource()
            }
            self.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        fileSource = source
    }

    private func armDirectorySource() {
        directorySource?.cancel()
        directorySource = nil
        guard !isStopped else { return }

        let directory = url.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The config directory does not exist right now. Keep trying, or
            // the watch stays dead for the rest of the session.
            scheduleRearm()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                // The directory itself was replaced — every descriptor we hold
                // now points at the old inode. Rebuild both watches against the
                // new one (a dotfiles checkout does exactly this).
                self.armDirectorySource()
                self.armFileSource()
            } else if self.fileSource == nil {
                // A rename into the directory can create the file we never
                // managed to open (first save, or `mv` from a template).
                self.armFileSource()
            }
            self.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }

    /// Retries the directory watch until the directory exists again, then
    /// reports a change so any edit made while we were blind is picked up.
    private func scheduleRearm() {
        guard !isStopped, pendingRearm == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.pendingRearm = nil
            self.armDirectorySource()
            if self.directorySource != nil {
                self.armFileSource()
                self.scheduleChange()
            }
        }
        pendingRearm = work
        queue.asyncAfter(deadline: .now() + rearmInterval, execute: work)
    }

    /// Editors emit several events per save; coalesce them into one reload.
    private func scheduleChange() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.onChange()
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
