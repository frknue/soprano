import AppKit

/// Resolves the configured theme id and appearance preference into the
/// palette every view draws with, and keeps it current.
///
/// `folio` follows the effective appearance, so the resolved theme can change
/// without the settings changing: when the system flips between light and
/// dark (or the `appearance` key does), `currentTheme` is re-resolved and
/// `onThemeChanged` fires.
@MainActor
final class ThemeManager {
    /// The id the user chose (`folio`, `folio-paper`, `gruvbox-dark`, …).
    private(set) var themeId: String
    /// The `appearance` setting: system, light or dark.
    private(set) var appearance: AppearancePreference
    /// The concrete palette in force.
    private(set) var currentTheme: AppTheme

    /// Callback fired when the resolved theme changes, so views can refresh.
    var onThemeChanged: ((AppTheme) -> Void)?

    private var appearanceObservation: NSKeyValueObservation?
    private var isDrivingApplication = false

    init(themeId: String, appearance: AppearancePreference = .system) {
        self.themeId = themeId
        self.appearance = appearance
        self.currentTheme = Self.resolve(
            themeId: themeId,
            appearance: appearance,
            systemAppearance: Self.systemAppearance()
        )
    }

    func setTheme(id: String) {
        update(themeId: id, appearance: appearance)
    }

    func setAppearance(_ appearance: AppearancePreference) {
        update(themeId: themeId, appearance: appearance)
    }

    /// Applies a new id and preference together, firing `onThemeChanged` once
    /// if the resolved palette differs.
    func update(themeId: String, appearance: AppearancePreference) {
        self.themeId = themeId
        self.appearance = appearance
        applyApplicationAppearance()
        resolveAndNotify()
    }

    /// Makes this manager drive `NSApp.appearance` and follow system
    /// appearance changes. Called once by the app; tests never call it, so a
    /// test-made manager never touches global state.
    func startDrivingApplicationAppearance() {
        guard !isDrivingApplication else { return }
        isDrivingApplication = true
        applyApplicationAppearance()
        resolveAndNotify()
        appearanceObservation = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.resolveAndNotify()
            }
        }
    }

    /// `NSApp.appearance` follows the resolved theme so alerts, menus and
    /// panels match it. It is cleared only while `folio` follows the system,
    /// which is what lets the effective appearance report system changes.
    private func applyApplicationAppearance() {
        guard isDrivingApplication else { return }
        let followsSystem = !AppTheme.allThemes.contains { $0.id == themeId }
            && appearance == .system
        if followsSystem {
            NSApplication.shared.appearance = nil
        } else {
            let resolved = Self.resolve(
                themeId: themeId,
                appearance: appearance,
                systemAppearance: Self.systemAppearance()
            )
            NSApplication.shared.appearance = resolved.appearance.nsAppearance
        }
    }

    private func resolveAndNotify() {
        let resolved = Self.resolve(
            themeId: themeId,
            appearance: appearance,
            systemAppearance: Self.systemAppearance()
        )
        guard resolved.id != currentTheme.id else { return }
        currentTheme = resolved
        onThemeChanged?(resolved)
    }

    static func resolve(
        themeId: String,
        appearance: AppearancePreference,
        systemAppearance: AppTheme.Appearance
    ) -> AppTheme {
        let effective: AppTheme.Appearance = switch appearance {
        case .system: systemAppearance
        case .light: .light
        case .dark: .dark
        }
        return AppTheme.theme(for: themeId, appearance: effective)
    }

    /// The appearance `folio` follows under the `system` preference. While
    /// `NSApp.appearance` is nil this is the system's own setting.
    private static func systemAppearance() -> AppTheme.Appearance {
        AppTheme.Appearance(NSApplication.shared.effectiveAppearance)
    }
}
