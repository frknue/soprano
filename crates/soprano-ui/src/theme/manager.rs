//! `Controllers/ThemeManager.swift` without AppKit: resolves the configured theme id and the
//! appearance preference into the palette in force, and reports when it changes.
//!
//! `folio` follows the effective appearance, so the resolved theme can change without the
//! settings changing: when the system flips between light and dark (or the `appearance` key
//! does), the theme is re-resolved. Each mutator returns the new theme only when the resolved
//! palette differs, which is when views must refresh.

use super::palettes::{ALL_THEMES, AppTheme, Appearance, AppearancePreference, theme_for};

#[derive(Clone, Debug)]
pub struct ThemeManager {
    theme_id: String,
    appearance: AppearancePreference,
    system_appearance: Appearance,
    current: &'static AppTheme,
}

impl ThemeManager {
    /// `system_appearance` is what the OS shows now (`Appearance::from_window(cx.window_appearance())`).
    pub fn new(
        theme_id: impl Into<String>,
        appearance: AppearancePreference,
        system_appearance: Appearance,
    ) -> Self {
        let theme_id = theme_id.into();
        let current = Self::resolve(&theme_id, appearance, system_appearance);
        Self { theme_id, appearance, system_appearance, current }
    }

    /// The id the user chose (`folio`, `folio-paper`, `gruvbox-dark`, …).
    pub fn theme_id(&self) -> &str {
        &self.theme_id
    }

    /// The `appearance` setting.
    pub fn appearance(&self) -> AppearancePreference {
        self.appearance
    }

    pub fn system_appearance(&self) -> Appearance {
        self.system_appearance
    }

    /// The concrete palette in force.
    pub fn current(&self) -> &'static AppTheme {
        self.current
    }

    pub fn set_theme(&mut self, id: &str) -> Option<&'static AppTheme> {
        self.update(id, self.appearance)
    }

    pub fn set_appearance(&mut self, appearance: AppearancePreference) -> Option<&'static AppTheme> {
        let id = self.theme_id.clone();
        self.update(&id, appearance)
    }

    /// Applies a new id and preference together; the new theme if the resolved palette
    /// differs.
    pub fn update(&mut self, theme_id: &str, appearance: AppearancePreference) -> Option<&'static AppTheme> {
        self.theme_id = theme_id.to_owned();
        self.appearance = appearance;
        self.resolve_and_report()
    }

    /// The OS switched light/dark.
    pub fn set_system_appearance(&mut self, system: Appearance) -> Option<&'static AppTheme> {
        self.system_appearance = system;
        self.resolve_and_report()
    }

    /// Whether the app follows the OS appearance (`folio` under `system`); otherwise windows,
    /// menus and alerts take the resolved theme's appearance.
    pub fn follows_system(&self) -> bool {
        !ALL_THEMES.iter().any(|theme| theme.id == self.theme_id)
            && self.appearance == AppearancePreference::System
    }

    /// The appearance the app's windows, menus and alerts take: None (follow the OS) while
    /// `folio` follows the system, else the resolved theme's (`applyApplicationAppearance`).
    pub fn app_appearance(&self) -> Option<Appearance> {
        (!self.follows_system()).then(|| self.current.appearance())
    }

    fn resolve_and_report(&mut self) -> Option<&'static AppTheme> {
        let resolved = Self::resolve(&self.theme_id, self.appearance, self.system_appearance);
        if resolved.id == self.current.id {
            return None;
        }
        self.current = resolved;
        Some(resolved)
    }

    pub fn resolve(
        theme_id: &str,
        appearance: AppearancePreference,
        system_appearance: Appearance,
    ) -> &'static AppTheme {
        theme_for(theme_id, appearance.resolve(system_appearance))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_folio_theme_manager_re_resolves_when_the_appearance_changes() {
        let mut manager = ThemeManager::new("folio", AppearancePreference::Light, Appearance::Light);
        let mut changes = Vec::new();
        assert_eq!(manager.current().id, "folio-paper");

        changes.extend(manager.set_appearance(AppearancePreference::Dark).map(|t| t.id));
        assert_eq!(manager.current().id, "folio-ink");

        changes.extend(manager.set_theme("nord").map(|t| t.id));
        changes.extend(manager.set_appearance(AppearancePreference::Light).map(|t| t.id));
        assert_eq!(manager.current().id, "nord");
        assert_eq!(changes, ["folio-ink", "nord"]);
    }

    #[test]
    fn folio_under_the_system_preference_follows_the_os() {
        let mut manager = ThemeManager::new("folio", AppearancePreference::System, Appearance::Light);
        assert!(manager.follows_system());
        assert_eq!(manager.set_system_appearance(Appearance::Dark).map(|t| t.id), Some("folio-ink"));
        assert_eq!(manager.set_system_appearance(Appearance::Dark), None);
        manager.set_theme("dracula");
        assert!(!manager.follows_system());
        assert_eq!(manager.set_system_appearance(Appearance::Light), None);
    }

    #[test]
    fn the_app_follows_the_os_only_while_folio_follows_the_system() {
        let mut manager = ThemeManager::new("folio", AppearancePreference::System, Appearance::Light);
        assert_eq!(manager.app_appearance(), None);
        manager.set_appearance(AppearancePreference::Dark);
        assert_eq!(manager.app_appearance(), Some(Appearance::Dark));
        // A dark theme on a light-mode system still gives dark menus and title bars.
        manager.update("dracula", AppearancePreference::System);
        assert_eq!(manager.app_appearance(), Some(Appearance::Dark));
        manager.update("folio-paper", AppearancePreference::Dark);
        assert_eq!(manager.app_appearance(), Some(Appearance::Light));
    }
}
