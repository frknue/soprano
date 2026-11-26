//! The settings pages, in navigation order.

use soprano_ui::IconName;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum SettingsTab {
    #[default]
    General,
    ChatUi,
    Machines,
    Mobile,
    KeyboardShortcuts,
    AgentProfiles,
    Accounts,
    About,
}

impl SettingsTab {
    pub const ALL: [SettingsTab; 8] = [
        SettingsTab::General,
        SettingsTab::ChatUi,
        SettingsTab::Machines,
        SettingsTab::Mobile,
        SettingsTab::KeyboardShortcuts,
        SettingsTab::AgentProfiles,
        SettingsTab::Accounts,
        SettingsTab::About,
    ];

    /// The page's name in the navigation and above the page.
    pub fn title(self) -> &'static str {
        match self {
            Self::General => "General",
            Self::ChatUi => "Chat UI",
            Self::Machines => "Machines",
            Self::Mobile => "Mobile",
            Self::KeyboardShortcuts => "Keyboard Shortcuts",
            Self::AgentProfiles => "Agent Profiles",
            Self::Accounts => "Accounts",
            Self::About => "About",
        }
    }

    /// The navigation glyph (the Swift SF Symbols' Lucide equivalents).
    pub fn icon(self) -> IconName {
        match self {
            Self::General => IconName::Settings,
            Self::ChatUi => IconName::MessageSquare,
            Self::Machines => IconName::Server,
            Self::Mobile => IconName::Globe,
            Self::KeyboardShortcuts => IconName::Keyboard,
            Self::AgentProfiles => IconName::Cpu,
            Self::Accounts => IconName::ACCOUNT,
            Self::About => IconName::Info,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pages_keep_the_navigation_order_and_titles() {
        let titles: Vec<&str> = SettingsTab::ALL.iter().map(|tab| tab.title()).collect();
        assert_eq!(
            titles,
            [
                "General",
                "Chat UI",
                "Machines",
                "Mobile",
                "Keyboard Shortcuts",
                "Agent Profiles",
                "Accounts",
                "About"
            ]
        );
        assert_eq!(SettingsTab::default(), SettingsTab::General);
    }
}
