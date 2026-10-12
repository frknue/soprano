import Foundation

/// Application-wide preferences.
///
/// `settings.json` is the source of truth (see `ConfigStore`); the UserDefaults
/// copy below is only read once, to seed that file for users who configured the
/// app before it existed.
struct AppSettings: Codable, Equatable {
    var restoreLastSession: Bool
    var themeId: String
    var hideWindowBar: Bool
    /// Hides the numbered window tabs; the tab row moves up into their place.
    /// On by default: the sidebar, `⌃1`…`⌃9`, and `⌘F` already switch windows.
    var hideWindowTabs: Bool
    /// Scanlines and phosphor glow over terminal panes. Off by default: it is
    /// a look, and a shader on every pane is not free.
    var crtEffect: Bool
    var projectDirectories: [String]
    /// Off by default. A pane that wants you is already announced by the banner,
    /// the unread ring, and the pane header; adding a chime to every finished
    /// turn is the kind of thing people disable once and never turn back on.
    var notificationSound: Bool

    static let defaultSettings = AppSettings(
        restoreLastSession: true,
        themeId: "mission-control",
        hideWindowBar: false,
        hideWindowTabs: true,
        crtEffect: false,
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
        hideWindowBar = try container.decodeIfPresent(Bool.self, forKey: .hideWindowBar)
            ?? defaults.hideWindowBar
        hideWindowTabs = try container.decodeIfPresent(Bool.self, forKey: .hideWindowTabs)
            ?? defaults.hideWindowTabs
        crtEffect = try container.decodeIfPresent(Bool.self, forKey: .crtEffect)
            ?? defaults.crtEffect
        projectDirectories = try container.decodeIfPresent([String].self, forKey: .projectDirectories)
            ?? defaults.projectDirectories
        notificationSound = try container.decodeIfPresent(Bool.self, forKey: .notificationSound)
            ?? defaults.notificationSound
    }

    init(
        restoreLastSession: Bool,
        themeId: String,
        hideWindowBar: Bool,
        hideWindowTabs: Bool,
        crtEffect: Bool,
        projectDirectories: [String],
        notificationSound: Bool
    ) {
        self.restoreLastSession = restoreLastSession
        self.themeId = themeId
        self.hideWindowBar = hideWindowBar
        self.hideWindowTabs = hideWindowTabs
        self.crtEffect = crtEffect
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
