import Foundation

/// Application-wide preferences persisted to UserDefaults.
struct AppSettings: Codable {
    var restoreLastSession: Bool
    var themeId: String
    var projectDirectories: [String]

    static let defaultSettings = AppSettings(
        restoreLastSession: true,
        themeId: "gruvbox-dark",
        projectDirectories: []
    )

    // MARK: - Persistence

    private static let key = "soprano-app-settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .defaultSettings
        }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
