import AppKit

/// Manages the current theme and applies it to the app.
final class ThemeManager {
    private(set) var currentTheme: AppTheme

    /// Callback fired when theme changes, so views can refresh.
    var onThemeChanged: ((AppTheme) -> Void)?

    init(themeId: String) {
        self.currentTheme = AppTheme.theme(for: themeId)
    }

    func setTheme(id: String) {
        currentTheme = AppTheme.theme(for: id)
        onThemeChanged?(currentTheme)
    }
}
