import Foundation

/// Application-wide preferences.
///
/// `settings.json` is the source of truth (see `ConfigStore`); the UserDefaults
/// copy below is only read once, to seed that file for users who configured the
/// app before it existed.
struct AppSettings: Codable, Equatable {
    var restoreLastSession: Bool
    var themeId: String
    var projectDirectories: [String]

    static let defaultSettings = AppSettings(
        restoreLastSession: true,
        themeId: "gruvbox-dark",
        projectDirectories: []
    )

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
