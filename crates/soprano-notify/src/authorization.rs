//! What the OS last said about notification permission, for the settings screen
//! (`AgentNotificationManager.Authorization` and its `UserDefaults` mirror).

use std::sync::{Arc, Mutex};

use soprano_platform::StateStore;

/// Whether the OS lets Soprano post banners. `None` (no value yet) until the first check
/// completes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Authorization {
    Authorized,
    Denied,
    NotDetermined,
    /// This build cannot post at all: an unbundled macOS run, or no notification service.
    Unavailable,
}

impl Authorization {
    /// The persisted spelling (Swift's raw values).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Authorized => "authorized",
            Self::Denied => "denied",
            Self::NotDetermined => "notDetermined",
            Self::Unavailable => "unavailable",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "authorized" => Some(Self::Authorized),
            "denied" => Some(Self::Denied),
            "notDetermined" => Some(Self::NotDetermined),
            "unavailable" => Some(Self::Unavailable),
            _ => None,
        }
    }
}

/// The state key the Swift app used, so a migrated Mac keeps its last known answer.
pub const AUTHORIZATION_KEY: &str = "soprano-notification-authorization";

type Observer = Arc<dyn Fn(Authorization) + Send + Sync>;

/// The persisted authorization and its change observer, shared with the OS completion
/// handlers (which run on arbitrary threads).
#[derive(Clone)]
pub(crate) struct AuthorizationState {
    store: StateStore,
    observer: Arc<Mutex<Option<Observer>>>,
}

impl AuthorizationState {
    pub(crate) fn new(store: StateStore) -> Self {
        Self { store, observer: Arc::new(Mutex::new(None)) }
    }

    pub(crate) fn current(&self) -> Option<Authorization> {
        self.store.get::<String>(AUTHORIZATION_KEY).as_deref().and_then(Authorization::from_raw)
    }

    pub(crate) fn set_observer(&self, observer: Observer) {
        *self.observer.lock().expect("authorization observer lock") = Some(observer);
    }

    /// Records `value` and tells the observer, only when it changed.
    pub(crate) fn publish(&self, value: Authorization) {
        if self.current() == Some(value) {
            return;
        }
        self.store.set(AUTHORIZATION_KEY, value.raw_value());
        let observer = self.observer.lock().expect("authorization observer lock").clone();
        if let Some(observer) = observer {
            observer(value);
        }
    }
}
