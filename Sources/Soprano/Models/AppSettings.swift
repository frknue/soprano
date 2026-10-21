import Foundation

/// The `appearance` key: follow macOS, or pin light or dark.
enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// Application-wide preferences.
///
/// `settings.json` is the source of truth (see `ConfigStore`); the UserDefaults
/// copy below is only read once, to seed that file for users who configured the
/// app before it existed.
struct AppSettings: Codable, Equatable {
    var restoreLastSession: Bool
    var themeId: String
    /// `system` follows macOS; `light` and `dark` pin the app appearance.
    /// The `folio` theme resolves to Paper or Ink from the result.
    var appearance: AppearancePreference
    var hideWindowBar: Bool
    /// Hides the numbered window tabs; the tab row moves up into their place.
    /// On by default: the sidebar, `⌃1`…`⌃9`, and `⌘F` already switch windows.
    var hideWindowTabs: Bool
    /// Shows how long Soprano has been running (`Up 2:14:07`) in the status
    /// bar. Off by default: an always-ticking clock is noise.
    var statusBarUptime: Bool
    var projectDirectories: [String]
    /// Off by default. A pane that wants you is already announced by the banner,
    /// the unread ring, and the pane header; adding a chime to every finished
    /// turn is the kind of thing people disable once and never turn back on.
    var notificationSound: Bool

    static let defaultSettings = AppSettings(
        restoreLastSession: true,
        themeId: AppTheme.folioId,
        appearance: .system,
        hideWindowBar: false,
        hideWindowTabs: true,
        statusBarUptime: false,
        projectDirectories: [],
        notificationSound: false
    )

    /// Decoded by hand so a stored payload written before a key existed still
    /// loads. The synthesized initializer would throw on the missing key, and
    /// the caller's `try?` would silently discard every other setting with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaultSettings

        restoreLastSession = try container.decodeIfPresent(Bool.self, forKey: .restoreLastSession)
            ?? defaults.restoreLastSession
        themeId = try container.decodeIfPresent(String.self, forKey: .themeId)
            ?? defaults.themeId
        appearance = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearance)
            ?? defaults.appearance
        hideWindowBar = try container.decodeIfPresent(Bool.self, forKey: .hideWindowBar)
            ?? defaults.hideWindowBar
        hideWindowTabs = try container.decodeIfPresent(Bool.self, forKey: .hideWindowTabs)
            ?? defaults.hideWindowTabs
        statusBarUptime = try container.decodeIfPresent(Bool.self, forKey: .statusBarUptime)
            ?? defaults.statusBarUptime
        projectDirectories = try container.decodeIfPresent([String].self, forKey: .projectDirectories)
            ?? defaults.projectDirectories
        notificationSound = try container.decodeIfPresent(Bool.self, forKey: .notificationSound)
            ?? defaults.notificationSound
    }

    init(
        restoreLastSession: Bool,
        themeId: String,
        appearance: AppearancePreference,
        hideWindowBar: Bool,
        hideWindowTabs: Bool,
        statusBarUptime: Bool,
        projectDirectories: [String],
        notificationSound: Bool
    ) {
        self.restoreLastSession = restoreLastSession
        self.themeId = themeId
        self.appearance = appearance
        self.hideWindowBar = hideWindowBar
        self.hideWindowTabs = hideWindowTabs
        self.statusBarUptime = statusBarUptime
        self.projectDirectories = projectDirectories
        self.notificationSound = notificationSound
    }

    // MARK: - Legacy persistence

    private static let key = "soprano-app-settings"

    /// Reads the pre-`settings.json` preferences, used once to seed that file
    /// so an upgrade does not reset someone's configuration.
    ///
    /// There is deliberately no `save` counterpart: settings are written to
    /// `settings.json` through `ConfigStore`, and a second store that could
    /// drift out of sync would be a bug waiting to happen.
    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .defaultSettings
        }
        return settings
    }
}
