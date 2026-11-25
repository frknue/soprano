//! The Chat UI settings page: global on/off switch and per-agent default launch mode
//! (`chat` vs `cli`), written under `chatUi` in `settings.json`.

use soprano_config::{ChatLaunchMode, ConfigStore};
use soprano_launch::ChatLaunch;
use soprano_types::AgentProfile;

pub const CHAT_UI_ENABLED_KEY: &[&str] = &["chatUi", "enabled"];
pub const CHAT_UI_AGENTS_KEY: &[&str] = &["chatUi", "agents"];

pub const LEAD: &str = "Choose how chats look and behave.";
pub const AGENTS_SECTION_TITLE: &str = "Default launch mode per agent";
pub const AGENTS_SECTION_NOTE: &str = "Choose whether each agent opens in Chat UI or its CLI.";

pub fn chat_capable_agents(profiles: &[AgentProfile]) -> Vec<&AgentProfile> {
    profiles.iter().filter(|p| ChatLaunch::supports(&p.id)).collect()
}

pub fn mode_title(mode: ChatLaunchMode) -> &'static str {
    match mode {
        ChatLaunchMode::Chat => "Chat",
        ChatLaunchMode::Cli => "CLI",
    }
}

pub fn set_enabled(store: &ConfigStore, enabled: bool) -> bool {
    store.write(enabled, CHAT_UI_ENABLED_KEY)
}

pub fn set_agent_mode(store: &ConfigStore, profile_id: &str, mode: ChatLaunchMode) -> bool {
    store.write(mode.raw_value(), &["chatUi", "agents", profile_id])
}

pub fn reset_agent_modes(store: &ConfigStore) -> bool {
    store.remove(CHAT_UI_AGENTS_KEY)
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_config::{AppSettings, DefaultKeybindings};
    use soprano_types::{AgentCatalog, DefaultAgents};
    use std::sync::Arc;

    fn store() -> (ConfigStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir");
        let store = ConfigStore::with_catalog(
            dir.path().join("settings.json"),
            Arc::new(AgentCatalog::new(DefaultAgents::all())),
        );
        store.start(false, &AppSettings::default(), &DefaultKeybindings::config());
        (store, dir)
    }

    #[test]
    fn toggling_chat_ui_and_per_agent_launch_modes_writes_settings_json() {
        let (store, _dir) = store();
        assert!(!store.resolved().settings.chat_ui.enabled);
        assert!(!store.resolved().settings.chat_ui.default_opens_in_chat("claude-code"));

        assert!(set_enabled(&store, true));
        assert!(store.resolved().settings.chat_ui.enabled);
        assert!(store.resolved().settings.chat_ui.default_opens_in_chat("claude-code"));
        assert!(store.resolved().settings.chat_ui.default_opens_in_chat("codex"));

        assert!(set_agent_mode(&store, "codex", ChatLaunchMode::Cli));
        assert!(!store.resolved().settings.chat_ui.default_opens_in_chat("codex"));
        assert!(store.resolved().settings.chat_ui.default_opens_in_chat("claude-code"));

        assert!(reset_agent_modes(&store));
        assert!(store.resolved().settings.chat_ui.default_opens_in_chat("codex"));

        assert!(set_enabled(&store, false));
        assert!(!store.resolved().settings.chat_ui.default_opens_in_chat("claude-code"));
    }

    #[test]
    fn chat_capable_agents_excludes_plain_terminal() {
        let all = DefaultAgents::all();
        let ids: Vec<&str> = chat_capable_agents(&all).into_iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, ["codex", "claude-code", "opencode", "omp", "agy"]);
    }
}
