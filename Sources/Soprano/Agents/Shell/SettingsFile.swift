import Foundation

/// Where Soprano Agents's settings live: the object under `"threads"` in Soprano's
/// own `settings.json` (`ConfigFile.url`), which Soprano creates and watches.
///
/// Two settings are Soprano's own top-level keys instead: the project folders
/// (`projectDirectories`) and the theme (`theme` + `appearance`, which the Agents
/// window always follows). Reading and writing the file goes through `ConfigFile`.
enum SettingsFile {
    /// Top-level key of Soprano's document holding the Agents settings.
    static let namespace = "threads"

    /// The standalone app's old settings file, still honored by its environment key.
    static let legacyPathEnvironmentKey = "SOPRANO_AGENTS_CONFIG"

    /// `threads` is present but not an object, so no Agents setting can be read.
    struct NamespaceError: LocalizedError, Equatable {
        var errorDescription: String? { "\"\(SettingsFile.namespace)\" must be an object." }
    }

    static func url() -> URL {
        ConfigFile.url
    }

    /// The standalone app's `settings.json`: `$SOPRANO_AGENTS_CONFIG`, else
    /// `$XDG_CONFIG_HOME/soprano-agents/settings.json`, else `~/.config/soprano-agents/settings.json`.
    static func legacyURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[legacyPathEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath).standardizedFileURL
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: NSString(string: xdg).expandingTildeInPath)
                .standardizedFileURL
                .appendingPathComponent("soprano-agents/settings.json", isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/soprano-agents/settings.json", isDirectory: false)
    }

    /// Where an Agents settings path (`["chat", "width"]`) sits in Soprano's document:
    /// under `threads`, except the project folders and the theme, which are Soprano's.
    static func documentPath(for path: [String]) -> [String] {
        switch path {
        case ["projects", "directories"]: ["projectDirectories"]
        case ["theme"]: ["theme"]
        default: [namespace] + path
        }
    }

    /// The Agents settings document `SettingsResolver.resolve(text:)` reads, derived from
    /// Soprano's whole document: the `threads` object without `theme`, with
    /// `projects.directories` taken from Soprano's `projectDirectories`.
    /// Throws `JSONCText.ParseError` for a syntax error in Soprano's text (positioned in it)
    /// and `NamespaceError` when `threads` is not an object.
    static func agentsDocument(fromSopranoText text: String) throws -> String {
        let root = try object(from: text)
        var agents: [String: Any] = [:]
        if let value = root[namespace] {
            guard let threads = value as? [String: Any] else { throw NamespaceError() }
            agents = threads
        }
        agents["theme"] = nil
        agents["projects"] = root["projectDirectories"].map { ["directories": $0] }
        let data = try JSONSerialization.data(withJSONObject: agents, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Importing the standalone app's settings

    /// Soprano's document with the standalone app's settings moved in, or nil when
    /// there is nothing to do because Soprano's `threads` already holds the user's own
    /// choices (the import marker). The `threads` block Soprano's template writes is
    /// only the defaults, so it does not count. The old object minus `theme` and
    /// `projects` becomes `threads`; its `projects.directories` becomes Soprano's
    /// `projectDirectories` only when Soprano has none. Soprano's comments and key
    /// order are kept.
    static func importing(legacyText: String, into sopranoText: String?) throws -> String? {
        let current = sopranoText ?? "{}"
        let soprano = try object(from: current)
        if let threads = soprano[namespace], !isTemplateDefault(threads) { return nil }

        var legacy = try object(from: legacyText)
        let directories = (legacy["projects"] as? [String: Any])?["directories"] as? [Any]
        legacy["theme"] = nil
        legacy["projects"] = nil

        var updated = try JSONCText.setting(legacy, at: [namespace], in: current)
        let existing = soprano["projectDirectories"]
        let sopranoHasFolders = existing != nil && (existing as? [Any])?.isEmpty != true
        if let directories, !directories.isEmpty, !sopranoHasFolders {
            updated = try JSONCText.setting(directories, at: ["projectDirectories"], in: updated)
        }
        return updated
    }

    /// Imports the standalone app's settings file into Soprano's once; the old file
    /// stays untouched. Returns whether Soprano's file was written.
    @discardableResult
    static func importLegacySettings(into url: URL = url(), from legacyURL: URL = legacyURL()) throws -> Bool {
        guard let legacy = try ConfigFile.read(at: legacyURL),
              let updated = try importing(legacyText: legacy, into: ConfigFile.read(at: url))
        else { return false }
        // Old settings equal to the template's block produce the same text: nothing to write.
        guard try updated != ConfigFile.read(at: url) else { return false }
        try ConfigFile.write(updated, to: url)
        return true
    }

    /// Whether `threads` is the block Soprano's template writes: the defaults, not a
    /// user's choice.
    private static func isTemplateDefault(_ threads: Any) -> Bool {
        let template = ConfigFile.template(settings: .defaultSettings, keybindings: DefaultKeybindings.config)
        guard let templateThreads = (try? object(from: template))?[namespace] as? NSDictionary,
              let threads = threads as? NSDictionary
        else { return false }
        return threads.isEqual(templateThreads)
    }

    private static func object(from text: String) throws -> [String: Any] {
        let data = try JSONCText.strictJSONData(from: text)
        guard let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw JSONCText.ParseError(message: "The settings document must be a JSON object", line: 1, column: 1)
        }
        return root
    }
}
