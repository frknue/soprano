//! App state that is not configuration: saved workspaces, window geometry, sidebar widths,
//! account choices. The Swift app kept these in `UserDefaults` under `soprano-*` keys; here they
//! live in one JSON object, `<data dir>/state.json`, under the same keys.
//!
//! Types that persist state take a `StateStore` (`StateStore::in_memory()` in tests), the way
//! the Swift types took an injectable `UserDefaults`.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::{AppIdentity, paths};

/// A shared handle to one state file; clones see the same values.
#[derive(Clone)]
pub struct StateStore {
    inner: Arc<Mutex<Inner>>,
}

struct Inner {
    path: Option<PathBuf>,
    values: Map<String, Value>,
}

impl StateStore {
    /// The running app's store. On the first start of a Mac that ran the Swift build, it is
    /// seeded from that build's `UserDefaults` domain so workspaces and choices carry over.
    pub fn for_app(identity: &AppIdentity) -> Self {
        let path = paths::data_dir(identity).join("state.json");
        let fresh = !path.exists();
        let store = Self::open(path);
        if fresh {
            #[cfg(target_os = "macos")]
            store.import_user_defaults(&identity.id);
        }
        store
    }

    /// A store backed by `path`. A missing file is an empty store; an unreadable one is
    /// moved aside to `state.json.corrupt` so a bad write never wedges the app.
    pub fn open(path: PathBuf) -> Self {
        let values = match std::fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
                Ok(Value::Object(map)) => map,
                _ => {
                    let _ = std::fs::rename(&path, path.with_extension("json.corrupt"));
                    Map::new()
                }
            },
            Err(_) => Map::new(),
        };
        Self { inner: Arc::new(Mutex::new(Inner { path: Some(path), values })) }
    }

    /// A store that never touches disk.
    pub fn in_memory() -> Self {
        Self { inner: Arc::new(Mutex::new(Inner { path: None, values: Map::new() })) }
    }

    pub fn path(&self) -> Option<PathBuf> {
        self.inner.lock().unwrap().path.clone()
    }

    pub fn get<T: DeserializeOwned>(&self, key: &str) -> Option<T> {
        let value = self.get_raw(key)?;
        serde_json::from_value(value).ok()
    }

    pub fn get_raw(&self, key: &str) -> Option<Value> {
        self.inner.lock().unwrap().values.get(key).cloned()
    }

    pub fn contains(&self, key: &str) -> bool {
        self.inner.lock().unwrap().values.contains_key(key)
    }

    /// Stores `value` under `key` and writes the file. A value that fails to serialize is a
    /// programming error and is dropped (with the key left unchanged) rather than panicking.
    pub fn set<T: Serialize + ?Sized>(&self, key: &str, value: &T) {
        let Ok(value) = serde_json::to_value(value) else { return };
        self.set_raw(key, value);
    }

    pub fn set_raw(&self, key: &str, value: Value) {
        let mut inner = self.inner.lock().unwrap();
        if inner.values.get(key) == Some(&value) {
            return;
        }
        inner.values.insert(key.to_owned(), value);
        inner.flush();
    }

    pub fn remove(&self, key: &str) {
        let mut inner = self.inner.lock().unwrap();
        if inner.values.remove(key).is_some() {
            inner.flush();
        }
    }

    /// Copies the Swift build's `soprano-*` preferences into this store. `UserDefaults`
    /// holds Codable values as JSON `Data`; those are decoded, plain values copied as-is.
    #[cfg(target_os = "macos")]
    fn import_user_defaults(&self, domain: &str) {
        let plist_path = paths::home_dir().join("Library/Preferences").join(format!("{domain}.plist"));
        let Ok(plist::Value::Dictionary(dict)) = plist::Value::from_file(&plist_path) else { return };
        let mut inner = self.inner.lock().unwrap();
        for (key, value) in dict {
            if !key.starts_with("soprano-") {
                continue;
            }
            if let Some(json) = legacy_value(value) {
                inner.values.insert(key, json);
            }
        }
        inner.flush();
    }
}

#[cfg(target_os = "macos")]
fn legacy_value(value: plist::Value) -> Option<Value> {
    Some(match value {
        plist::Value::Data(bytes) => serde_json::from_slice(&bytes).ok()?,
        plist::Value::String(s) => Value::String(s),
        plist::Value::Boolean(b) => Value::Bool(b),
        plist::Value::Integer(i) => i.as_signed().map(Value::from).or_else(|| i.as_unsigned().map(Value::from))?,
        plist::Value::Real(r) => serde_json::Number::from_f64(r).map(Value::Number)?,
        plist::Value::Array(items) => Value::Array(items.into_iter().filter_map(legacy_value).collect()),
        plist::Value::Dictionary(dict) => {
            Value::Object(dict.into_iter().filter_map(|(k, v)| Some((k, legacy_value(v)?))).collect())
        }
        _ => return None,
    })
}

impl Inner {
    fn flush(&self) {
        let Some(path) = &self.path else { return };
        let Ok(bytes) = serde_json::to_vec_pretty(&self.values) else { return };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = write_atomically(path, &bytes);
    }
}

/// Writes `bytes` to a sibling temp file and renames it over `path`, so readers never see a
/// half-written file. The folder must exist (a save into a deleted folder fails, as Foundation's
/// atomic write does); the temp file is removed when the write or rename fails.
pub fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    let result = std::fs::write(&tmp, bytes).and_then(|()| std::fs::rename(&tmp, path));
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values_survive_reopening_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        let store = StateStore::open(path.clone());
        store.set("soprano-sidebar-visible", &false);
        store.set("soprano-sessions", &vec!["a", "b"]);
        let reopened = StateStore::open(path);
        assert_eq!(reopened.get::<bool>("soprano-sidebar-visible"), Some(false));
        assert_eq!(reopened.get::<Vec<String>>("soprano-sessions"), Some(vec!["a".into(), "b".into()]));
    }

    #[test]
    fn a_corrupt_file_is_moved_aside_and_the_store_starts_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        std::fs::write(&path, b"{not json").unwrap();
        let store = StateStore::open(path.clone());
        assert!(store.get_raw("anything").is_none());
        assert!(dir.path().join("state.json.corrupt").exists());
    }

    #[test]
    fn clones_share_values_and_removal_persists() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.json");
        let store = StateStore::open(path.clone());
        let clone = store.clone();
        store.set("k", &1);
        assert_eq!(clone.get::<i32>("k"), Some(1));
        clone.remove("k");
        assert!(StateStore::open(path).get_raw("k").is_none());
    }
}
