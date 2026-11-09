//! Runtime authority for everything `settings.json` owns (`Config/ConfigStore.swift`).
//!
//! The file is the source of truth and this store is its in-memory projection: the UI reads
//! resolved values from here and writes changes back *through* here, so a click in Settings
//! and a hand edit in the file are the same operation. Editing the file applies immediately —
//! the watcher reloads it.
//!
//! The store is a cheap, cloneable handle (`Arc` inside) that is safe to use from any thread;
//! the watcher reloads on its own thread. Subscribers registered with
//! [`ConfigStore::add_observer`] are called with a [`ConfigSnapshot`] after every change, on
//! the thread that made it — UI code hops to its own executor from there.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, Weak};

use serde_json::Value;
use soprano_platform::StateStore;
use soprano_types::{AgentCatalog, KeyBindingConfig};

use crate::app_settings::AppSettings;
use crate::config::{ConfigIssue, ResolvedConfig, SopranoConfig, install_agents};
use crate::config_file;
use crate::default_keybindings::DefaultKeybindings;
use crate::jsonc::{self, DecodeError};
use crate::watcher::ConfigFileWatcher;

/// Everything an observer needs after a change.
#[derive(Clone, Debug)]
pub struct ConfigSnapshot {
    /// Raw file text, verbatim.
    pub text: String,
    /// The last document that parsed.
    pub config: SopranoConfig,
    /// The configuration in force.
    pub resolved: ResolvedConfig,
    /// Problems with the file itself — unreadable, unparseable, unwritable.
    pub file_issues: Vec<ConfigIssue>,
}

impl ConfigSnapshot {
    /// File problems first, then problems with the contents of the configuration in force.
    pub fn issues(&self) -> Vec<ConfigIssue> {
        self.file_issues.iter().chain(&self.resolved.issues).cloned().collect()
    }
}

type Observer = Arc<dyn Fn(&ConfigSnapshot) + Send + Sync>;

struct State {
    /// Raw file text, kept verbatim so surgical writes preserve comments.
    text: String,
    config: SopranoConfig,
    resolved: ResolvedConfig,
    /// Held apart from `resolved.issues` (which describe the *contents* of the last document
    /// that parsed) because the two have different lifetimes: a syntax error keeps the previous
    /// resolution alive, and folding the two lists together would append a fresh copy of the
    /// error on every reload.
    file_issues: Vec<ConfigIssue>,
    /// Text this store just wrote — used to ignore the watcher event our own save produces, so
    /// a UI edit does not round-trip into a redundant reload.
    self_written_text: Option<String>,
    /// Counts changes published to observers.
    generation: u64,
}

/// Observer delivery (see [`ConfigStore::publish`]).
#[derive(Default)]
struct Delivery {
    /// The newest change not yet handed to observers.
    pending: Option<(u64, ConfigSnapshot)>,
    /// The newest change handed to observers.
    delivered: u64,
    /// A thread is running observers right now.
    delivering: bool,
}

struct Shared {
    file_path: PathBuf,
    /// `None`: [`AgentCatalog::shared`].
    catalog: Option<Arc<AgentCatalog>>,
    state: Mutex<State>,
    observers: Mutex<BTreeMap<String, Observer>>,
    delivery: Mutex<Delivery>,
    watcher: Mutex<Option<ConfigFileWatcher>>,
}

#[derive(Clone)]
pub struct ConfigStore {
    shared: Arc<Shared>,
}

impl ConfigStore {
    /// A store over the real `settings.json` ([`config_file::config_path`]).
    pub fn for_app() -> Self {
        Self::new(config_file::config_path())
    }

    /// A store over `file_path`. Injectable so tests never touch the real
    /// `~/.config/soprano/settings.json`. Resolved agents go to [`AgentCatalog::shared`].
    pub fn new(file_path: impl Into<PathBuf>) -> Self {
        Self::build(file_path.into(), None)
    }

    /// A store that installs resolved agents into `catalog` instead of the shared one.
    pub fn with_catalog(file_path: impl Into<PathBuf>, catalog: Arc<AgentCatalog>) -> Self {
        Self::build(file_path.into(), Some(catalog))
    }

    fn build(file_path: PathBuf, catalog: Option<Arc<AgentCatalog>>) -> Self {
        Self {
            shared: Arc::new(Shared {
                file_path,
                catalog,
                state: Mutex::new(State {
                    text: String::new(),
                    config: SopranoConfig::default(),
                    resolved: ResolvedConfig::defaults(),
                    file_issues: Vec::new(),
                    self_written_text: None,
                    generation: 0,
                }),
                observers: Mutex::new(BTreeMap::new()),
                delivery: Mutex::new(Delivery::default()),
                watcher: Mutex::new(None),
            }),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.shared.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    // MARK: - Reading

    pub fn file_path(&self) -> &Path {
        &self.shared.file_path
    }

    pub fn display_path(&self) -> String {
        config_file::display_path(&self.shared.file_path)
    }

    pub fn text(&self) -> String {
        self.state().text.clone()
    }

    pub fn config(&self) -> SopranoConfig {
        self.state().config.clone()
    }

    pub fn resolved(&self) -> ResolvedConfig {
        self.state().resolved.clone()
    }

    pub fn settings(&self) -> AppSettings {
        self.state().resolved.settings.clone()
    }

    pub fn keybindings(&self) -> KeyBindingConfig {
        self.state().resolved.keybindings.clone()
    }

    pub fn file_issues(&self) -> Vec<ConfigIssue> {
        self.state().file_issues.clone()
    }

    /// File problems first, then problems with the configuration in force.
    pub fn issues(&self) -> Vec<ConfigIssue> {
        let state = self.state();
        state.file_issues.iter().chain(&state.resolved.issues).cloned().collect()
    }

    pub fn snapshot(&self) -> ConfigSnapshot {
        Self::snapshot_of(&self.state())
    }

    fn snapshot_of(state: &State) -> ConfigSnapshot {
        ConfigSnapshot {
            text: state.text.clone(),
            config: state.config.clone(),
            resolved: state.resolved.clone(),
            file_issues: state.file_issues.clone(),
        }
    }

    // MARK: - Lifecycle

    /// Seeds the file on first run from the pre-`settings.json` preferences kept in `state`
    /// (`soprano-app-settings`, `soprano-keybindings`), loads it, and optionally starts
    /// watching.
    pub fn start_with_state(&self, watching: bool, state: &StateStore) {
        self.start(watching, &AppSettings::load(state), &DefaultKeybindings::load(state));
    }

    /// Seeds the file on first run with `seed_settings`/`seed_keybindings`, loads it, and
    /// optionally starts watching.
    pub fn start(&self, watching: bool, seed_settings: &AppSettings, seed_keybindings: &KeyBindingConfig) {
        let path = &self.shared.file_path;
        match config_file::create_if_missing(seed_settings, seed_keybindings, path) {
            Ok(text) => {
                {
                    let mut state = self.state();
                    state.text = text.clone();
                    self.apply_loaded_text(&mut state, &text);
                }
                if watching {
                    self.start_watching();
                }
            }
            Err(error) => {
                let mut state = self.state();
                state.text = config_file::read(path).ok().flatten().unwrap_or_default();
                state.file_issues =
                    vec![ConfigIssue::error(format!("Could not create {}: {error}", self.display_path()))];
                self.apply_resolution(&mut state, SopranoConfig::default().resolved());
            }
        }
    }

    fn start_watching(&self) {
        let mut watcher = self.shared.watcher.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if watcher.is_some() {
            return;
        }
        let weak: Weak<Shared> = Arc::downgrade(&self.shared);
        *watcher = Some(ConfigFileWatcher::start_default(&self.shared.file_path, move || {
            if let Some(shared) = weak.upgrade() {
                ConfigStore { shared }.reload_from_disk();
            }
        }));
    }

    /// Stops watching the file (the store keeps its values).
    pub fn stop_watching(&self) {
        let watcher = self.shared.watcher.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
        if let Some(watcher) = watcher {
            watcher.stop();
        }
    }

    // MARK: - Loading

    /// Re-reads the file. Called by the watcher and by "Reload" in the UI.
    pub fn reload_from_disk(&self) {
        let publication = {
            let mut state = self.state();
            self.reload_locked(&mut state).then(|| Self::publication(&mut state))
        };
        if let Some(publication) = publication {
            self.publish(publication);
        }
    }

    /// Returns whether observers should hear about it.
    fn reload_locked(&self, state: &mut State) -> bool {
        // A missing file is a legitimate empty configuration; a file that exists but cannot be
        // read is not. Collapsing the two would silently reset the app to defaults when a
        // permission changes.
        let disk_text = match config_file::read(&self.shared.file_path) {
            Ok(text) => text.unwrap_or_default(),
            Err(error) => {
                state.file_issues =
                    vec![ConfigIssue::error(format!("Could not read {}: {error}", self.display_path()))];
                return true;
            }
        };

        if state.self_written_text.take().is_some_and(|written| written == disk_text) {
            // Our own save came back around; state is already current.
            return false;
        }
        // Unchanged text needs no work, unless we are sitting on a file-level problem worth
        // re-attempting (a permission that may have been fixed).
        if disk_text == state.text && state.file_issues.is_empty() {
            return false;
        }
        state.text = disk_text.clone();
        self.apply_loaded_text(state, &disk_text);
        true
    }

    fn apply_loaded_text(&self, state: &mut State, text: &str) {
        if text.trim().is_empty() {
            state.config = SopranoConfig::default();
            state.file_issues.clear();
            self.apply_resolution(state, SopranoConfig::default().resolved());
            return;
        }

        match jsonc::decode::<SopranoConfig>(text) {
            Ok(decoded) => {
                let resolution = decoded.resolved();
                state.config = decoded;
                state.file_issues.clear();
                self.apply_resolution(state, resolution);
            }
            // Keep the last good values running rather than dropping the user into a default
            // workspace because of a missing comma. `resolved` is deliberately left alone: it
            // still describes the document that last parsed, and that is what the app is
            // running on.
            Err(DecodeError::Syntax(error)) => {
                state.file_issues = vec![ConfigIssue {
                    line: Some(error.line),
                    ..ConfigIssue::error(format!("{}: {}", self.display_path(), error.message))
                }];
            }
            Err(DecodeError::Shape { path, message }) => {
                state.file_issues = vec![ConfigIssue::error(format!(
                    "{}: {}",
                    self.display_path(),
                    describe_shape_error(&path, &message)
                ))];
            }
        }
    }

    fn apply_resolution(&self, state: &mut State, resolution: ResolvedConfig) {
        let catalog = self.shared.catalog.as_deref().unwrap_or_else(|| AgentCatalog::shared());
        install_agents(catalog, &resolution.agents);
        state.resolved = resolution;
    }

    // MARK: - Writing

    /// Sets one key, preserving the rest of the document byte for byte. `Value::Null` writes a
    /// JSON `null`. Returns whether the file now holds the value.
    ///
    /// Floating-point values go through [`Self::write_number`]: converting NaN or infinity to
    /// a `Value` already turns it into `null`.
    pub fn write(&self, value: impl Into<Value>, path: &[&str]) -> bool {
        let value = value.into();
        self.apply_edit(|text| jsonc::setting(&value, path, text))
    }

    /// Sets one numeric key. A non-finite number is refused (and reported as a file issue)
    /// rather than written as `null`, as the Swift writer threw for it.
    pub fn write_number(&self, value: f64, path: &[&str]) -> bool {
        match jsonc::number_value(value) {
            Ok(value) => self.write(value, path),
            Err(error) => self.apply_edit(|_| Err(error)),
        }
    }

    /// Removes one key so the built-in default takes over again.
    pub fn remove(&self, path: &[&str]) -> bool {
        self.apply_edit(|text| jsonc::removing(path, text))
    }

    fn apply_edit(&self, edit: impl FnOnce(&str) -> Result<String, jsonc::ParseError>) -> bool {
        let (succeeded, publication) = {
            let mut state = self.state();
            match self.edit_locked(&mut state, edit) {
                Ok(changed) => (true, changed.then(|| Self::publication(&mut state))),
                Err(message) => {
                    state.file_issues = vec![ConfigIssue::error(format!(
                        "Could not update {}: {message}",
                        self.display_path()
                    ))];
                    (false, Some(Self::publication(&mut state)))
                }
            }
        };
        if let Some(publication) = publication {
            self.publish(publication);
        }
        succeeded
    }

    /// Returns whether the file changed.
    fn edit_locked(
        &self,
        state: &mut State,
        edit: impl FnOnce(&str) -> Result<String, jsonc::ParseError>,
    ) -> Result<bool, String> {
        let path = &self.shared.file_path;
        // Always edit what is on disk right now, not what we last read. The watcher is
        // debounced, so an external edit can be in flight while a control is clicked; splicing
        // into stale text would rewrite the file and quietly discard the user's own change.
        if let Some(current) = config_file::read(path).map_err(|e| e.to_string())?
            && current != state.text
        {
            state.text = current.clone();
            self.apply_loaded_text(state, &current);
        }
        let updated = edit(&state.text).map_err(|e| e.to_string())?;
        if updated == state.text {
            return Ok(false);
        }
        config_file::write(&updated, path).map_err(|e| e.to_string())?;
        state.self_written_text = Some(updated.clone());
        state.text = updated.clone();
        self.apply_loaded_text(state, &updated);
        Ok(true)
    }

    // MARK: - Observers

    /// Registers `handler` under `id` (replacing an earlier one with the same id). It is called
    /// after every change, on the thread that made it, without the store's lock held.
    pub fn add_observer(
        &self,
        id: impl Into<String>,
        handler: impl Fn(&ConfigSnapshot) + Send + Sync + 'static,
    ) {
        self.observers().insert(id.into(), Arc::new(handler));
    }

    pub fn remove_observer(&self, id: &str) {
        self.observers().remove(id);
    }

    fn observers(&self) -> MutexGuard<'_, BTreeMap<String, Observer>> {
        self.shared.observers.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Numbers each change and snapshots it while the state lock is still held, so the
    /// snapshot is exactly the state that change produced.
    fn publication(state: &mut State) -> (u64, ConfigSnapshot) {
        state.generation += 1;
        (state.generation, Self::snapshot_of(state))
    }

    /// Delivers changes to observers in order, never ending on an older snapshot: a change
    /// older than one already delivered (or queued) is dropped, and while one thread delivers,
    /// later changes — from other threads, or from an observer writing the store — are queued
    /// for it to deliver next instead of racing it. Handlers run without any lock held.
    fn publish(&self, (generation, snapshot): (u64, ConfigSnapshot)) {
        let mut delivery = self.delivery();
        if generation <= delivery.delivered
            || delivery.pending.as_ref().is_some_and(|(g, _)| *g >= generation)
        {
            return;
        }
        delivery.pending = Some((generation, snapshot));
        if delivery.delivering {
            return;
        }
        delivery.delivering = true;
        while let Some((generation, snapshot)) = delivery.pending.take() {
            delivery.delivered = generation;
            drop(delivery);
            let handlers: Vec<Observer> = self.observers().values().cloned().collect();
            for handler in handlers {
                handler(&snapshot);
            }
            delivery = self.delivery();
        }
        delivery.delivering = false;
    }

    fn delivery(&self) -> MutexGuard<'_, Delivery> {
        self.shared.delivery.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    // MARK: - Opening

    /// Opens the file in the user's default editor for `.json`.
    pub fn open_in_editor(&self) -> Result<(), String> {
        let path = &self.shared.file_path;
        if !config_file::exists(path) {
            // Opening a path that does not exist would just fail; write the template first so
            // the editor has something to show.
            let _ = config_file::create_if_missing(&self.settings(), &self.keybindings(), path);
        }
        soprano_platform::system::open_default(&path.display().to_string()).map_err(|e| e.to_string())
    }

    /// Shows the file in Finder / the file manager.
    pub fn reveal_in_file_manager(&self) -> Result<(), String> {
        soprano_platform::system::reveal_in_file_manager(&self.shared.file_path).map_err(|e| e.to_string())
    }
}

/// Turns a decoding failure into something a person can act on: it names the key and the
/// expected type, where the stock message names neither — useless when the whole document is
/// being rejected over one value.
fn describe_shape_error(path: &str, message: &str) -> String {
    let location = if path.is_empty() { "the document" } else { path };
    if let Some(rest) = message.strip_prefix("invalid type: ") {
        let expected = rest.rsplit_once(", expected ").map_or("", |(_, expected)| expected);
        if rest.starts_with("null") {
            return format!(
                "{location} is empty but should be {}. Nothing in the file was applied.",
                readable(expected)
            );
        }
        return format!("{location} should be {}. Nothing in the file was applied.", readable(expected));
    }
    if let Some(rest) = message.strip_prefix("missing field `") {
        let key = rest.trim_end_matches('`');
        return format!("{location} is missing \"{key}\". Nothing in the file was applied.");
    }
    format!("{location}: {message}")
}

/// serde's "expected" text → the words Swift's `readable(_:)` used. A keyed container is
/// what `JSONDecoder` names `Dictionary<String, Any>`.
fn readable(expected: &str) -> String {
    match expected {
        "a string" => "text".into(),
        "a boolean" => "true or false".into(),
        "i64" | "u64" | "i32" | "u32" | "f64" | "f32" | "an integer" | "a number" | "a JSON number" => {
            "a number".into()
        }
        "a sequence" => "a list".into(),
        "a map" => "of type Dictionary<String, Any>".into(),
        other if other.starts_with("struct ") => "of type Dictionary<String, Any>".into(),
        other => format!("of type {other}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Severity;
    use crate::key_chord::KeyChord;
    use soprano_types::DefaultAgents;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    /// A store pointed at a throwaway file and a private agent catalog, so nothing here can
    /// touch the real `settings.json` or race other tests over the shared catalog.
    fn make_store() -> (ConfigStore, tempfile::TempDir) {
        let directory = tempfile::tempdir().expect("tempdir");
        let catalog = Arc::new(AgentCatalog::new(DefaultAgents::all()));
        (ConfigStore::with_catalog(directory.path().join("settings.json"), catalog), directory)
    }

    fn start(store: &ConfigStore) {
        store.start(false, &AppSettings::default(), &DefaultKeybindings::config());
    }

    fn write_file(store: &ConfigStore, text: &str) {
        config_file::write(text, store.file_path()).expect("writes");
    }

    fn file_text(store: &ConfigStore) -> String {
        std::fs::read_to_string(store.file_path()).unwrap_or_default()
    }

    fn errors(store: &ConfigStore) -> usize {
        store.issues().iter().filter(|i| i.severity == Severity::Error).count()
    }

    // MARK: - ConfigStoreTests

    #[test]
    fn starting_with_no_file_writes_a_documented_template_that_parses_cleanly() {
        let (store, _directory) = make_store();
        start(&store);
        assert!(store.file_path().exists());
        assert!(store.text().contains("// Soprano settings."));
        assert!(store.issues().is_empty(), "{:?}", store.issues());
        assert_eq!(store.settings(), AppSettings::default());
        assert_eq!(store.keybindings(), DefaultKeybindings::config());
    }

    #[test]
    fn the_seeded_template_carries_forward_settings_made_before_the_file_existed() {
        let (store, _directory) = make_store();
        let previous = AppSettings {
            theme_id: "catppuccin-mocha".into(),
            restore_last_session: false,
            ..AppSettings::default()
        };
        let mut previous_keys = DefaultKeybindings::config();
        let index = previous_keys.bindings.iter().position(|b| b.id == "new-browser").expect("binding");
        previous_keys.bindings[index] =
            KeyChord::parse("cmd+shift+b").expect("chord").applied(&previous_keys.bindings[index]);
        previous_keys.prefix_key = "b".into();

        store.start(false, &previous, &previous_keys);

        assert_eq!(store.settings().theme_id, "catppuccin-mocha");
        assert!(!store.settings().restore_last_session);
        assert_eq!(store.keybindings().prefix_key, "b");
        assert_eq!(
            store.keybindings().bindings.iter().find(|b| b.id == "new-browser").and_then(|b| b.shift),
            Some(true)
        );
        assert!(store.resolved().customized_binding_ids.contains("new-browser"));
    }

    #[test]
    fn the_first_run_seed_comes_from_the_legacy_state_store_keys() {
        let (store, _directory) = make_store();
        let state = StateStore::in_memory();
        state.set_raw(AppSettings::STATE_KEY, serde_json::json!({"themeId": "nord", "hideWindowBar": true}));
        let mut keys = DefaultKeybindings::config();
        keys.prefix_key = "s".into();
        state.set(DefaultKeybindings::STATE_KEY, &keys);

        store.start_with_state(false, &state);

        assert_eq!(store.settings().theme_id, "nord");
        assert!(store.settings().hide_window_bar);
        assert_eq!(store.keybindings().prefix_key, "s");
    }

    #[test]
    fn writing_one_key_leaves_every_comment_and_unrelated_key_untouched() {
        let (store, _directory) = make_store();
        write_file(
            &store,
            "// My Soprano config\n{\n  // I like the orange one\n  \"theme\": \"gruvbox-dark\",\n  \"restoreLastSession\": false\n}",
        );
        start(&store);

        assert!(store.write("catppuccin-mocha", &["theme"]));

        let text = file_text(&store);
        assert!(text.contains("// My Soprano config"));
        assert!(text.contains("// I like the orange one"));
        assert!(text.contains("\"theme\": \"catppuccin-mocha\""));
        assert!(text.contains("\"restoreLastSession\": false"));
        assert_eq!(store.settings().theme_id, "catppuccin-mocha");
        assert!(!store.settings().restore_last_session);
    }

    /// A trailing block comment that wraps onto the next line looks like plain whitespace once
    /// comments are blanked, so a naive scan finds the newline *inside* it and splices the new
    /// key into the comment body — writing a setting that is commented out, with no error.
    #[test]
    fn a_key_inserted_after_a_multi_line_trailing_comment_lands_outside_that_comment() {
        let (store, _directory) = make_store();
        write_file(
            &store,
            "{\n  \"theme\": \"gruvbox-dark\",\n  \"keybindings\": {\n    \"prefixKey\": \"a\" /* the tmux-style prefix; press this,\n                        then the action key */\n  }\n}",
        );
        start(&store);

        assert!(store.write(2500, &["keybindings", "prefixTimeoutMs"]));

        assert_eq!(store.keybindings().prefix_timeout_ms, 2500);
        let text = file_text(&store);
        assert!(text.contains("then the action key */"));
        let reparsed: SopranoConfig = jsonc::decode(&text).expect("decodes");
        assert_eq!(reparsed.keybindings.and_then(|k| k.prefix_timeout_ms), Some(2500));
    }

    /// The mirror of the insertion case: removing an entry whose trailing block comment wraps
    /// onto the next line must not cut the comment in half.
    #[test]
    fn removing_a_key_with_a_multi_line_trailing_comment_leaves_the_file_parseable() {
        let (store, _directory) = make_store();
        write_file(
            &store,
            "{\n  \"restoreLastSession\": false,\n  \"theme\": \"catppuccin-mocha\" /* the purple one; I keep going\n                                 back and forth on this */\n}",
        );
        start(&store);

        assert!(store.remove(&["theme"]));

        let reparsed: SopranoConfig = jsonc::decode(&file_text(&store)).expect("decodes");
        assert_eq!(reparsed.theme, None);
        assert_eq!(reparsed.restore_last_session, Some(false));
        assert!(store.issues().is_empty());
    }

    #[test]
    fn writing_a_nested_key_creates_the_object_it_lives_in() {
        let (store, _directory) = make_store();
        write_file(&store, "{}");
        start(&store);

        assert!(store.write(2500, &["keybindings", "prefixTimeoutMs"]));

        assert_eq!(store.keybindings().prefix_timeout_ms, 2500);
        let reparsed: SopranoConfig = jsonc::decode(&store.text()).expect("decodes");
        assert_eq!(reparsed.keybindings.and_then(|k| k.prefix_timeout_ms), Some(2500));
    }

    #[test]
    fn a_syntax_error_keeps_the_last_good_values_running_and_reports_the_line() {
        let (store, _directory) = make_store();
        write_file(&store, "{\n  \"theme\": \"catppuccin-mocha\"\n}");
        start(&store);
        assert_eq!(store.settings().theme_id, "catppuccin-mocha");

        write_file(&store, "{\n  \"theme\": \"catppuccin-mocha\",\n  \"restoreLastSession\":\n}");
        store.reload_from_disk();

        // The app keeps working on the values it already had.
        assert_eq!(store.settings().theme_id, "catppuccin-mocha");
        let error = store.issues().into_iter().find(|i| i.severity == Severity::Error).expect("error");
        assert!(error.line.is_some());
    }

    /// Reporting a problem must not be cumulative: three bad saves in a row are still one
    /// problem, and the banner should say so once.
    #[test]
    fn repeated_problems_do_not_pile_up_in_the_issue_list() {
        let (store, _directory) = make_store();
        write_file(&store, r#"{ "theme": "catppuccin-mocha" }"#);
        start(&store);

        for attempt in 1..=3 {
            write_file(&store, &format!(r#"{{ "theme": "catppuccin-mocha", {attempt}"#));
            store.reload_from_disk();
            assert_eq!(errors(&store), 1);
        }

        // And the error clears once the file parses again.
        write_file(&store, r#"{ "theme": "gruvbox-dark" }"#);
        store.reload_from_disk();
        assert!(store.issues().is_empty());
        assert_eq!(store.settings().theme_id, "gruvbox-dark");
    }

    #[test]
    fn a_warning_from_the_last_good_config_survives_alongside_a_syntax_error() {
        let (store, _directory) = make_store();
        write_file(&store, r#"{ "theme": "not-a-theme" }"#);
        start(&store);
        assert_eq!(store.issues().len(), 1);

        write_file(&store, r#"{ "theme": "#);
        store.reload_from_disk();

        // One of each: the file cannot be read, and the config still in force has its own
        // problem.
        assert_eq!(errors(&store), 1);
        assert_eq!(store.issues().iter().filter(|i| i.severity == Severity::Warning).count(), 1);
    }

    #[test]
    fn an_edit_made_outside_the_app_is_picked_up_and_announced_once() {
        let (store, _directory) = make_store();
        start(&store);
        let notifications = Arc::new(AtomicUsize::new(0));
        let counter = notifications.clone();
        store.add_observer("test", move |_| {
            counter.fetch_add(1, Ordering::SeqCst);
        });

        write_file(&store, r#"{ "theme": "catppuccin-mocha", "keybindings": { "prefixKey": "x" } }"#);
        store.reload_from_disk();

        assert_eq!(notifications.load(Ordering::SeqCst), 1);
        assert_eq!(store.settings().theme_id, "catppuccin-mocha");
        assert_eq!(store.keybindings().prefix_key, "x");

        // A reload with no change on disk must not churn the whole app.
        store.reload_from_disk();
        assert_eq!(notifications.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_store_write_does_not_reload_its_own_file_again() {
        let (store, _directory) = make_store();
        write_file(&store, "{}");
        start(&store);
        let notifications = Arc::new(AtomicUsize::new(0));
        let counter = notifications.clone();
        store.add_observer("test", move |snapshot| {
            assert_eq!(snapshot.resolved.settings.theme_id, "catppuccin-mocha");
            counter.fetch_add(1, Ordering::SeqCst);
        });

        assert!(store.write("catppuccin-mocha", &["theme"]));
        assert_eq!(notifications.load(Ordering::SeqCst), 1);

        // This is what the file watcher delivers a moment after our own save.
        store.reload_from_disk();
        assert_eq!(notifications.load(Ordering::SeqCst), 1);

        store.remove_observer("test");
        assert!(store.write("nord", &["theme"]));
        assert_eq!(notifications.load(Ordering::SeqCst), 1);
    }

    /// The whole "hand edits apply immediately" promise rests on the watcher surviving how
    /// editors actually save: write a temp file, rename it over the target. That swaps the
    /// inode and silences a naive file-only watch after exactly one save, so this saves three
    /// times on purpose.
    #[test]
    fn repeated_atomic_saves_from_an_editor_are_each_picked_up_live() {
        let (store, _directory) = make_store();
        store.start(true, &AppSettings::default(), &DefaultKeybindings::config());

        for theme in ["catppuccin-mocha", "gruvbox-dark", "catppuccin-mocha"] {
            // `config_file::write` is the write-temp-then-rename path.
            config_file::write(&format!(r#"{{ "theme": "{theme}" }}"#), store.file_path()).expect("writes");
            let deadline = Instant::now() + Duration::from_secs(15);
            while store.settings().theme_id != theme && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(20));
            }
            assert_eq!(store.settings().theme_id, theme);
        }
        store.stop_watching();
    }

    /// A file that exists but cannot be read is not an empty configuration. Treating it as one
    /// would silently reset the whole app to defaults the moment a permission changed.
    #[cfg(unix)]
    #[test]
    fn an_unreadable_file_reports_an_error_instead_of_resetting_everything() {
        use std::os::unix::fs::PermissionsExt;
        let (store, _directory) = make_store();
        write_file(&store, r#"{ "theme": "catppuccin-mocha" }"#);
        start(&store);

        std::fs::set_permissions(store.file_path(), std::fs::Permissions::from_mode(0o000)).expect("chmod");
        let readable_anyway = std::fs::read(store.file_path()).is_ok(); // running as root
        store.reload_from_disk();
        std::fs::set_permissions(store.file_path(), std::fs::Permissions::from_mode(0o644)).expect("chmod");

        assert_eq!(store.settings().theme_id, "catppuccin-mocha");
        if !readable_anyway {
            assert!(errors(&store) > 0);
        }
    }

    /// The README recommends symlinking settings.json out of a dotfiles repo. An atomic write
    /// is a rename onto the path, so writing must follow the link instead of replacing it.
    #[cfg(unix)]
    #[test]
    fn writing_through_a_symlink_keeps_the_link_and_updates_its_target() {
        let (store, directory) = make_store();
        let target = directory.path().join("dotfiles/soprano.json");
        config_file::write(r#"{ "theme": "gruvbox-dark" }"#, &target).expect("writes");
        std::os::unix::fs::symlink(&target, store.file_path()).expect("symlink");

        start(&store);
        assert!(store.write("catppuccin-mocha", &["theme"]));

        let metadata = std::fs::symlink_metadata(store.file_path()).expect("metadata");
        assert!(metadata.file_type().is_symlink());
        assert!(std::fs::read_to_string(&target).expect("reads").contains("catppuccin-mocha"));
    }

    /// The watcher is debounced, so an external edit can be in flight when a settings control
    /// is clicked. The click must not rewrite the file from a stale copy.
    #[test]
    fn a_ui_write_merges_onto_whatever_is_on_disk_rather_than_overwriting_it() {
        let (store, _directory) = make_store();
        write_file(&store, r#"{ "theme": "gruvbox-dark" }"#);
        start(&store);

        // An external edit the store has not observed yet.
        write_file(&store, r#"{ "theme": "gruvbox-dark", "restoreLastSession": false }"#);

        assert!(store.write("catppuccin-mocha", &["theme"]));

        assert!(file_text(&store).contains("\"restoreLastSession\": false"));
        assert!(!store.settings().restore_last_session);
        assert_eq!(store.settings().theme_id, "catppuccin-mocha");
    }

    #[test]
    fn removing_a_key_restores_the_built_in_default() {
        let (store, _directory) = make_store();
        write_file(&store, r#"{ "theme": "catppuccin-mocha" }"#);
        start(&store);
        assert_eq!(store.settings().theme_id, "catppuccin-mocha");

        assert!(store.remove(&["theme"]));
        assert_eq!(store.settings().theme_id, AppSettings::default().theme_id);
    }

    #[test]
    fn configured_agents_reach_the_catalog_the_rest_of_the_app_reads() {
        let directory = tempfile::tempdir().expect("tempdir");
        let store = ConfigStore::new(directory.path().join("settings.json"));
        write_file(
            &store,
            r##"{ "agents": [ { "id": "aider", "command": "aider", "color": "#8bd5ca" } ] }"##,
        );
        start(&store);

        let aider = AgentCatalog::shared().profile("aider");
        assert_eq!(aider.as_ref().map(|p| p.command.as_str()), Some("aider"));
        assert_eq!(aider.as_ref().map(|p| p.color.as_str()), Some("#8bd5ca"));
        assert!(store.keybindings().bindings.iter().all(|b| b.id != "launch-aider"));

        // Restore the catalog for whatever runs next in this process.
        AgentCatalog::shared().replace_all(DefaultAgents::all());
    }

    #[test]
    fn a_value_of_the_wrong_type_names_the_key_and_the_expected_type() {
        let (store, _directory) = make_store();
        write_file(&store, r#"{ "theme": "nord" }"#);
        start(&store);

        write_file(&store, r#"{ "theme": "dracula", "keybindings": { "prefixTimeoutMs": "fast" } }"#);
        store.reload_from_disk();

        let error = store.issues().into_iter().find(|i| i.severity == Severity::Error).expect("error");
        assert!(
            error.message.contains("keybindings.prefixTimeoutMs should be a number"),
            "{}",
            error.message
        );
        assert!(error.message.ends_with("Nothing in the file was applied."));
        assert_eq!(store.settings().theme_id, "nord");

        write_file(&store, r#"{ "agents": [ { "command": "x" } ] }"#);
        store.reload_from_disk();
        let error = store.issues().into_iter().find(|i| i.severity == Severity::Error).expect("error");
        assert!(error.message.contains("agents.[0] is missing \"id\""), "{}", error.message);
    }

    #[test]
    fn writing_a_non_finite_number_is_refused_instead_of_writing_null() {
        let (store, _directory) = make_store();
        write_file(&store, "{}");
        start(&store);

        assert!(!store.write_number(f64::NAN, &["keybindings", "resizeTickPercent"]));
        assert!(!file_text(&store).contains("null"));
        let error = store.issues().into_iter().find(|i| i.severity == Severity::Error).expect("error");
        assert!(error.message.contains("non-finite"), "{}", error.message);

        assert!(store.write_number(7.0, &["keybindings", "resizeTickPercent"]));
        assert_eq!(store.keybindings().resize_tick_percent, 7.0);
        assert!(store.file_issues().is_empty());
    }

    /// Writes from several threads race; whatever order they land in, observers must end on
    /// the store's final state, never on an older snapshot delivered late.
    #[test]
    fn observers_always_end_on_the_latest_state() {
        let (store, _directory) = make_store();
        write_file(&store, "{}");
        start(&store);
        let last_seen = Arc::new(Mutex::new(String::new()));
        let sink = last_seen.clone();
        store.add_observer("last", move |snapshot| {
            *sink.lock().expect("lock") = snapshot.resolved.settings.theme_id.clone();
        });

        let themes = ["nord", "dracula", "gruvbox-dark", "tokyo-night"];
        let threads: Vec<_> = themes
            .iter()
            .map(|theme| {
                let store = store.clone();
                let theme = theme.to_string();
                std::thread::spawn(move || {
                    for _ in 0..10 {
                        store.write(theme.as_str(), &["theme"]);
                        store.reload_from_disk();
                    }
                })
            })
            .collect();
        for thread in threads {
            thread.join().expect("joins");
        }
        assert_eq!(*last_seen.lock().expect("lock"), store.settings().theme_id);
    }

    /// An observer that writes the store gets that later change delivered after it returns.
    #[test]
    fn an_observer_that_writes_the_store_sees_its_own_change_next() {
        let (store, _directory) = make_store();
        write_file(&store, "{}");
        start(&store);
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        let writer = store.clone();
        store.add_observer("chain", move |snapshot| {
            let theme = snapshot.resolved.settings.theme_id.clone();
            sink.lock().expect("lock").push(theme.clone());
            if theme == "nord" {
                writer.write("dracula", &["theme"]);
            }
        });
        assert!(store.write("nord", &["theme"]));
        assert_eq!(*seen.lock().expect("lock"), ["nord", "dracula"]);
    }

    // MARK: - SettingsConfigWritingTests (config side)

    fn started_store() -> (ConfigStore, tempfile::TempDir) {
        let (store, directory) = make_store();
        start(&store);
        (store, directory)
    }

    #[test]
    fn choosing_a_theme_rewrites_the_theme_key_in_the_file() {
        let (store, _directory) = started_store();
        assert!(store.write("catppuccin-mocha", &["theme"]));
        assert_eq!(store.settings().theme_id, "catppuccin-mocha");
        assert!(file_text(&store).contains("\"theme\": \"catppuccin-mocha\""));
    }

    #[test]
    fn toggling_switches_rewrites_their_keys_in_the_file() {
        let (store, _directory) = started_store();
        assert!(store.write(false, &["restoreLastSession"]));
        assert!(!store.settings().restore_last_session);
        assert!(file_text(&store).contains("\"restoreLastSession\": false"));

        assert!(store.write(true, &["hideWindowBar"]));
        assert!(store.settings().hide_window_bar);
        assert!(file_text(&store).contains("\"hideWindowBar\": true"));
    }

    #[test]
    fn choosing_an_appearance_writes_the_appearance_key() {
        let (store, _directory) = started_store();
        assert!(store.write("dark", &["appearance"]));
        assert_eq!(store.settings().appearance, crate::AppearancePreference::Dark);
        assert!(file_text(&store).contains("\"appearance\": \"dark\""));
    }

    #[test]
    fn toggling_the_uptime_switch_writes_the_nested_status_bar_key() {
        let (store, _directory) = started_store();
        assert!(!store.settings().status_bar_uptime);
        assert!(store.write(true, &["statusBar", "uptime"]));
        assert!(store.settings().status_bar_uptime);
        assert!(file_text(&store).contains("\"uptime\": true"));
        assert!(store.write(false, &["statusBar", "uptime"]));
        assert!(!store.settings().status_bar_uptime);
        assert!(file_text(&store).contains("\"uptime\": false"));
    }

    #[test]
    fn recording_a_prefix_key_writes_it() {
        let (store, _directory) = started_store();
        assert!(store.write("b", &["keybindings", "prefixKey"]));
        assert_eq!(store.keybindings().prefix_key, "b");
        assert!(file_text(&store).contains("\"prefixKey\": \"b\""));
    }

    #[test]
    fn adding_a_project_directory_writes_it_home_relative_and_resolves_it_back() {
        let (store, _directory) = started_store();
        let home = soprano_platform::paths::home_dir().display().to_string();
        assert!(
            store.write(serde_json::json!([config_file::abbreviating_home(&home)]), &["projectDirectories"])
        );
        // Written as "~", read back as the absolute path the app can use.
        assert!(file_text(&store).contains("\"~\""));
        assert_eq!(store.settings().project_directories, [crate::config::expand_path("~")]);
    }

    #[test]
    fn a_clamped_prefix_timeout_is_written_as_the_clamped_value() {
        let (store, _directory) = started_store();
        let clamped = 99999i64.clamp(
            *crate::config::Limits::PREFIX_TIMEOUT_MS.start(),
            *crate::config::Limits::PREFIX_TIMEOUT_MS.end(),
        );
        assert!(store.write(clamped, &["keybindings", "prefixTimeoutMs"]));
        assert_eq!(store.keybindings().prefix_timeout_ms, 5000);
        assert!(file_text(&store).contains("\"prefixTimeoutMs\": 5000"));
    }

    /// A syntax error deliberately keeps the last good values, so nothing the screen compares
    /// changes — only the issue list moves, and it carries the line.
    #[test]
    fn a_breakage_that_changes_no_values_still_raises_an_issue_with_its_line() {
        let (store, _directory) = started_store();
        let notifications = Arc::new(AtomicUsize::new(0));
        let counter = notifications.clone();
        store.add_observer("screen", move |_| {
            counter.fetch_add(1, Ordering::SeqCst);
        });

        write_file(&store, "{\n  \"theme\":\n}");
        store.reload_from_disk();

        assert_eq!(store.settings(), AppSettings::default());
        let error = store.issues().into_iter().find(|i| i.severity == Severity::Error).expect("error");
        assert_eq!(error.line, Some(3));
        assert!(error.message.contains("Unexpected character"));
        assert_eq!(notifications.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_config_problem_is_reported_instead_of_failing_silently() {
        let (store, _directory) = started_store();
        write_file(&store, r#"{ "theme": "no-such-theme" }"#);
        store.reload_from_disk();
        assert!(
            store
                .issues()
                .iter()
                .any(|i| i.severity == Severity::Warning && i.message.contains("no-such-theme"))
        );
    }

    // MARK: - AutomationConfigTests (store side)

    #[test]
    fn an_automation_saved_from_the_app_reads_back_unchanged_and_leaves_the_rest_of_the_file_alone() {
        use crate::automation::{Automation, AutomationSession, AutomationWorkspace};
        use crate::cron::CronSchedule;

        let (store, directory) = make_store();
        write_file(&store, "{\n  // keep me\n  \"theme\": \"nord\"\n}");
        start(&store);

        let automation = Automation {
            id: "nightly".into(),
            name: "Nightly review".into(),
            agent_id: "codex".into(),
            folder: crate::config::expand_path(&directory.path().display().to_string()),
            prompt: "- Review yesterday's commits\n- List anything risky".into(),
            schedule: CronSchedule::parse("30 2 * * *").expect("cron"),
            enabled: false,
            workspace: AutomationWorkspace::Worktree { base_branch: Some("origin/main".into()) },
            session: AutomationSession::Fresh,
            grace_minutes: 180,
            precheck: Some("git log --since=yesterday --oneline | grep -q .".into()),
            precheck_timeout_seconds: 30,
            model: Some("gpt-5.2".into()),
        };
        assert!(store.write(automation.config_object(), &["automations", &automation.id]));

        assert!(store.text().contains("// keep me"));
        assert_eq!(store.settings().theme_id, "nord");
        assert_eq!(store.resolved().automations, vec![automation]);
    }
}
