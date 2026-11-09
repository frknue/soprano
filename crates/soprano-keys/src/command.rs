//! What a binding id means: the Swift `KeybindingManager.executeBinding` table, as data the host
//! executes.

use soprano_types::{AgentCatalog, NavigationDirection, SplitDirection};

use crate::event::Modifiers;

/// The command a binding id runs.
#[derive(Clone, Debug, PartialEq)]
pub enum BindingCommand {
    /// `select-window-<n>`: activate logical window `n` (1-based).
    SelectWindow(i64),
    /// `launch-<agent>`: spawn this agent (resolved against the live catalog).
    LaunchAgent(String),
    /// `split-horizontal` / `split-vertical`: split the active pane.
    Split(SplitDirection),
    /// Open a chat with the first chat-capable agent profile beside the focused pane.
    NewChat,
    Navigate(NavigationDirection),
    PreviousWindow,
    NextWindow,
    LastWindow,
    /// Resize the active pane by the config's `resizeTickPercent`.
    Resize(NavigationDirection),
    ClosePane,
    /// Close the active pane's active tab; its last tab (or a pane without tabs) takes the pane
    /// with it.
    CloseActivePaneTab,
    ToggleMaximize,
    StartCopyMode,
    /// `new-window-current-directory` and `new-window`: create a logical window.
    NewWindow,
    NewSession,
    FindSession,
    NewTab,
    CloseTab,
    NextTab,
    PreviousTab,
    /// Add a terminal tab to the active pane.
    NewPaneTab,
    NextPaneTab,
    PreviousPaneTab,
    CommandPalette,
    FindWindow,
    OpenProject,
    OpenInSopranoGit,
    RenameWindow,
    CloseWindow,
    NewTerminal,
    NewBrowser,
    SaveSession,
    ToggleSidebar,
    ToggleRightSidebar,
    ToggleExplorer,
    ToggleSourceControl,
    OpenSettings,
    OpenAgentDashboard,
    /// Font zoom by this many steps (`zoom-in` +1, `zoom-out` -1).
    Zoom(i32),
    ZoomReset,
}

impl BindingCommand {
    /// The command `binding_id` runs, or `None` for an id that runs nothing (an unknown id, or a
    /// `launch-<agent>` whose agent is no longer configured).
    pub fn from_binding_id(binding_id: &str, catalog: &AgentCatalog) -> Option<Self> {
        if let Some(number) = binding_id.strip_prefix("select-window-").and_then(|raw| raw.parse().ok()) {
            return Some(Self::SelectWindow(number));
        }
        // Agent launchers are addressed by id (`launch-<agent>`) so an agent defined in
        // settings.json gets a working shortcut without a new case here.
        if let Some(agent_id) = launched_agent_id(binding_id, catalog) {
            return Some(Self::LaunchAgent(agent_id));
        }
        if let Some(direction) = split_direction(binding_id) {
            return Some(Self::Split(direction));
        }
        use NavigationDirection::{Down, Left, Right, Up};
        let command = match binding_id {
            "new-chat" => Self::NewChat,
            "nav-left" => Self::Navigate(Left),
            "nav-down" => Self::Navigate(Down),
            "nav-up" => Self::Navigate(Up),
            "nav-right" => Self::Navigate(Right),
            "previous-window" | "previous-window-direct" => Self::PreviousWindow,
            "next-window" | "next-window-direct" => Self::NextWindow,
            "last-window" => Self::LastWindow,
            "resize-left" => Self::Resize(Left),
            "resize-down" => Self::Resize(Down),
            "resize-up" => Self::Resize(Up),
            "resize-right" => Self::Resize(Right),
            "close-pane" => Self::ClosePane,
            "kill-pane" | "close-active" => Self::CloseActivePaneTab,
            "maximize-pane" => Self::ToggleMaximize,
            "copy-mode" | "copy-mode-right-bracket" => Self::StartCopyMode,
            "new-window-current-directory" | "new-window" => Self::NewWindow,
            "new-session" => Self::NewSession,
            "find-session" => Self::FindSession,
            "new-tab" | "new-tab-direct" => Self::NewTab,
            "close-tab" => Self::CloseTab,
            "next-tab" => Self::NextTab,
            "previous-tab" => Self::PreviousTab,
            "new-pane-tab" | "new-pane-tab-direct" => Self::NewPaneTab,
            "next-pane-tab" | "next-pane-tab-direct" => Self::NextPaneTab,
            "prev-pane-tab" | "prev-pane-tab-direct" => Self::PreviousPaneTab,
            "close-pane-tab" | "close-pane-tab-direct" => Self::CloseActivePaneTab,
            "command-palette" => Self::CommandPalette,
            "find-window" => Self::FindWindow,
            "open-project" => Self::OpenProject,
            "open-in-soprano-git" => Self::OpenInSopranoGit,
            "rename-window" => Self::RenameWindow,
            "close-window" => Self::CloseWindow,
            "new-terminal" => Self::NewTerminal,
            "new-browser" => Self::NewBrowser,
            "save-session" => Self::SaveSession,
            "toggle-sidebar" => Self::ToggleSidebar,
            "toggle-right-sidebar" => Self::ToggleRightSidebar,
            "toggle-explorer" => Self::ToggleExplorer,
            "toggle-source-control" => Self::ToggleSourceControl,
            "open-settings" => Self::OpenSettings,
            "agent-dashboard" => Self::OpenAgentDashboard,
            "zoom-in" => Self::Zoom(1),
            "zoom-out" => Self::Zoom(-1),
            "zoom-reset" => Self::ZoomReset,
            _ => return None,
        };
        Some(command)
    }
}

/// The agent a `launch-<agent>` binding spawns, or `None` for any other action. Resolved
/// against the live catalog so a shortcut can never spawn an agent that is no longer configured.
pub fn launched_agent_id(binding_id: &str, catalog: &AgentCatalog) -> Option<String> {
    let agent_id = binding_id.strip_prefix("launch-")?;
    catalog.profile(agent_id).map(|_| agent_id.to_owned())
}

/// Split actions are named for the divider they draw, while [`SplitDirection`] describes the
/// axis along which panes are arranged.
pub fn split_direction(binding_id: &str) -> Option<SplitDirection> {
    match binding_id {
        "split-horizontal" => Some(SplitDirection::Vertical),
        "split-vertical" => Some(SplitDirection::Horizontal),
        _ => None,
    }
}

/// Bindings the app menu owns on macOS: the Swift app let AppKit dispatch these standard
/// Command-menu equivalents through the main menu, which is more reliable than swallowing them
/// while a terminal surface is first responder.
pub fn dispatches_through_main_menu(binding_id: &str) -> bool {
    binding_id == "command-palette" || binding_id == "open-project"
}

/// What has the keyboard, for chords a focused pane keeps for itself.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum FocusedContent {
    Terminal,
    Browser,
    Editor,
    Automations,
    #[default]
    Other,
}

impl FocusedContent {
    /// Like Orca's scoped shortcuts: a browser keeps ⌘L (address bar), ⌘[ / ⌘] and ⌘R; an
    /// editor keeps ⌘F / ⌘G / ⇧⌘G (find) and ⌘S; the Automations page keeps ⌘N (New
    /// Automation). Soprano bindings on those chords apply everywhere else.
    ///
    /// `modifiers` are logical (macOS) flags: `cmd` is the binding's ⌘ on every platform.
    pub fn owns_chord(self, key: &str, modifiers: Modifiers) -> bool {
        let command_only = modifiers == Modifiers { cmd: true, ..Modifiers::default() };
        let command_shift = modifiers == Modifiers { cmd: true, shift: true, ..Modifiers::default() };
        match self {
            FocusedContent::Browser => command_only && matches!(key, "l" | "[" | "]" | "r"),
            FocusedContent::Editor => {
                (command_only && matches!(key, "f" | "g" | "s")) || (command_shift && key == "g")
            }
            FocusedContent::Automations => command_only && key == "n",
            FocusedContent::Terminal | FocusedContent::Other => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use soprano_types::DefaultAgents;

    fn command() -> Modifiers {
        Modifiers { cmd: true, ..Modifiers::default() }
    }

    fn command_shift() -> Modifiers {
        Modifiers { cmd: true, shift: true, ..Modifiers::default() }
    }

    #[test]
    fn focused_panes_keep_only_the_chords_they_own() {
        assert!(FocusedContent::Browser.owns_chord("l", command()));
        assert!(!FocusedContent::Browser.owns_chord("l", command_shift()));
        assert!(!FocusedContent::Browser.owns_chord("f", command()));
        assert!(FocusedContent::Editor.owns_chord("f", command()));
        assert!(FocusedContent::Editor.owns_chord("g", command_shift()));
        assert!(!FocusedContent::Editor.owns_chord("l", command()));
        assert!(!FocusedContent::Other.owns_chord("l", command()));
        assert!(!FocusedContent::Terminal.owns_chord("l", command()));
        assert!(FocusedContent::Automations.owns_chord("n", command()));
    }

    #[test]
    fn symbolic_split_bindings_follow_divider_orientation() {
        // SplitDirection describes pane arrangement: stacked panes produce a horizontal divider,
        // while side-by-side panes produce a vertical one.
        assert_eq!(split_direction("split-horizontal"), Some(SplitDirection::Vertical));
        assert_eq!(split_direction("split-vertical"), Some(SplitDirection::Horizontal));
        assert_eq!(split_direction("new-tab"), None);
    }

    #[test]
    fn find_window_executes_before_the_terminal_can_claim_command_f() {
        assert!(!dispatches_through_main_menu("find-window"));
        assert!(dispatches_through_main_menu("command-palette"));
        assert!(dispatches_through_main_menu("open-project"));
        assert!(!dispatches_through_main_menu("agent-dashboard"));
    }

    #[test]
    fn a_settings_defined_agent_gets_a_working_launch_shortcut() {
        let mut aider = DefaultAgents::codex();
        aider.id = "aider".into();
        let mut profiles = DefaultAgents::all();
        profiles.push(aider);
        let catalog = AgentCatalog::new(profiles);

        assert_eq!(launched_agent_id("launch-aider", &catalog).as_deref(), Some("aider"));
        assert_eq!(launched_agent_id("launch-missing", &catalog), None);
        assert_eq!(launched_agent_id("new-chat", &catalog), None);
        assert_eq!(
            BindingCommand::from_binding_id("launch-aider", &catalog),
            Some(BindingCommand::LaunchAgent("aider".into()))
        );
        assert_eq!(BindingCommand::from_binding_id("launch-missing", &catalog), None);
    }

    #[test]
    fn binding_ids_map_to_the_commands_the_swift_manager_ran() {
        let catalog = AgentCatalog::new(DefaultAgents::all());
        let command = |id: &str| BindingCommand::from_binding_id(id, &catalog);
        assert_eq!(command("select-window-3"), Some(BindingCommand::SelectWindow(3)));
        assert_eq!(command("select-window-x"), None);
        assert_eq!(command("launch-codex"), Some(BindingCommand::LaunchAgent("codex".into())));
        assert_eq!(command("split-vertical"), Some(BindingCommand::Split(SplitDirection::Horizontal)));
        assert_eq!(command("kill-pane"), Some(BindingCommand::CloseActivePaneTab));
        assert_eq!(command("close-active"), Some(BindingCommand::CloseActivePaneTab));
        assert_eq!(command("close-pane-tab-direct"), Some(BindingCommand::CloseActivePaneTab));
        assert_eq!(command("close-pane"), Some(BindingCommand::ClosePane));
        assert_eq!(command("new-window-current-directory"), Some(BindingCommand::NewWindow));
        assert_eq!(command("next-window-direct"), Some(BindingCommand::NextWindow));
        assert_eq!(command("copy-mode-right-bracket"), Some(BindingCommand::StartCopyMode));
        assert_eq!(command("resize-up"), Some(BindingCommand::Resize(NavigationDirection::Up)));
        assert_eq!(command("zoom-out"), Some(BindingCommand::Zoom(-1)));
        assert_eq!(command("unknown"), None);
    }
}
