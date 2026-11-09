//! The account choices an agent pane needs when it starts.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex};

use crate::codex::CodexHomeLinker;

/// What a new agent pane adds to its launch for the chosen accounts.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Adjustments {
    /// Exported for the agent after the login shell's rc files ran.
    pub environment: BTreeMap<String, String>,
    pub arguments: Vec<String>,
}

#[derive(Default)]
struct Choices {
    codex_home: Option<PathBuf>,
    codex_source: Option<PathBuf>,
    omp_overlay: Option<PathBuf>,
}

/// Lock-protected rather than tied to the UI thread: launch configs are
/// built wherever panes are created. `AccountsController` publishes into it
/// after every change.
#[derive(Default)]
pub struct AccountLaunchState {
    choices: Mutex<Choices>,
}

impl AccountLaunchState {
    pub fn new() -> Self {
        Self::default()
    }

    /// The one the app's `AccountsController` publishes into.
    pub fn shared() -> Arc<AccountLaunchState> {
        static SHARED: LazyLock<Arc<AccountLaunchState>> =
            LazyLock::new(|| Arc::new(AccountLaunchState::new()));
        Arc::clone(&SHARED)
    }

    pub fn update(&self, codex_home: Option<PathBuf>, codex_source: PathBuf, omp_overlay: Option<PathBuf>) {
        let mut choices = self.choices.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        *choices = Choices { codex_home, codex_source: Some(codex_source), omp_overlay };
    }

    /// The environment and arguments for an agent pane of `profile_id`
    /// (`codex`, `omp`; every other agent starts untouched).
    pub fn adjustments(&self, profile_id: &str) -> Adjustments {
        let (codex_home, codex_source, omp_overlay) = {
            let choices = self.choices.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            (choices.codex_home.clone(), choices.codex_source.clone(), choices.omp_overlay.clone())
        };
        match profile_id {
            "codex" => {
                let (Some(codex_home), Some(codex_source)) = (codex_home, codex_source) else {
                    return Adjustments::default();
                };
                // Link whatever ~/.codex gained since the account was added, and
                // fold back any shared file Codex replaced while running here.
                let _ = CodexHomeLinker::sync(&codex_home, &codex_source);
                Adjustments {
                    environment: BTreeMap::from([(
                        "CODEX_HOME".to_owned(),
                        codex_home.to_string_lossy().into_owned(),
                    )]),
                    arguments: Vec::new(),
                }
            }
            "omp" => {
                // omp treats a missing --config file as an error, so pass it
                // only once it exists.
                match omp_overlay.filter(|overlay| overlay.exists()) {
                    Some(overlay) => Adjustments {
                        environment: BTreeMap::new(),
                        arguments: vec!["--config".to_owned(), overlay.to_string_lossy().into_owned()],
                    },
                    None => Adjustments::default(),
                }
            }
            _ => Adjustments::default(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use super::*;

    struct Setup {
        state: AccountLaunchState,
        home: PathBuf,
        overlay: PathBuf,
        _root: tempfile::TempDir,
    }

    fn make_state() -> Setup {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("dot-codex");
        let home = root.path().join("account/home");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&home).unwrap();
        fs::write(source.join("config.toml"), "model = \"x\"").unwrap();
        let overlay = root.path().join("omp-accounts.yml");
        let state = AccountLaunchState::new();
        state.update(Some(home.clone()), source, Some(overlay.clone()));
        Setup { state, home, overlay, _root: root }
    }

    #[test]
    fn a_codex_pane_starts_in_the_chosen_accounts_home() {
        let setup = make_state();

        let adjustments = setup.state.adjustments("codex");

        assert_eq!(adjustments.environment.get("CODEX_HOME").map(Path::new), Some(setup.home.as_path()));
        assert!(adjustments.arguments.is_empty());
        // The home was linked up on the way, so codex finds the shared config.
        assert!(setup.home.join("config.toml").exists());
    }

    #[test]
    fn an_omp_pane_loads_the_preference_overlay_only_once_it_exists() {
        let setup = make_state();

        assert!(!setup.state.adjustments("omp").arguments.contains(&"--config".to_owned()));

        fs::write(&setup.overlay, "{}\n").unwrap();
        let after = setup.state.adjustments("omp");
        assert_eq!(after.arguments, ["--config".to_owned(), setup.overlay.to_string_lossy().into_owned()]);
    }

    #[test]
    fn other_agents_start_untouched_by_account_choices() {
        let setup = make_state();
        fs::write(&setup.overlay, "{}\n").unwrap();

        assert_eq!(setup.state.adjustments("claude-code"), Adjustments::default());
    }

    #[test]
    fn a_codex_pane_on_the_system_default_gets_no_codex_home() {
        let state = AccountLaunchState::new();
        state.update(None, PathBuf::from("/nonexistent"), None);
        assert_eq!(state.adjustments("codex"), Adjustments::default());
    }
}
