//! App-lifetime controller for Soprano Mobile access.
//!
//! Coordinates the loopback HTTP/WS server, `tailscale serve` setup/teardown, pairing codes,
//! paired device storage, and Settings UI observation via [`MobileSource`].

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, RwLock};

use soprano_platform::StateStore;
use tokio::sync::broadcast;

use crate::pairing::{PairedDevice, PairingOffer, PairingStore};
use crate::protocol::{MobileCommand, MobileSnapshot, ServerEvent};
use crate::server::{MobileClients, RunningServer, start_server};
use crate::tailscale::{
    SystemTailscaleRunner, TailscaleRunner, TailscaleStatus, connect_serve, disable_serve,
};

/// Observer notified on any state change (Tailscale status, pairing code, paired devices,
/// connected clients). May be called from a background thread.
pub type MobileObserver = Arc<dyn Fn(&MobileStateSnapshot) + Send + Sync>;

/// Presentation-ready snapshot of Soprano Mobile state for Settings ▸ Mobile.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MobileStateSnapshot {
    pub enabled: bool,
    pub port: u16,
    pub local_port: Option<u16>,
    pub checking: bool,
    pub tailscale: TailscaleStatus,
    pub pairing: Option<PairingOffer>,
    pub devices: Vec<PairedDevice>,
    pub connected_clients: usize,
}

impl Default for MobileStateSnapshot {
    fn default() -> Self {
        Self {
            enabled: false,
            port: 8443,
            local_port: None,
            checking: false,
            tailscale: TailscaleStatus::Disabled,
            pairing: None,
            devices: Vec::new(),
            connected_clients: 0,
        }
    }
}

/// What `soprano-settings` reads and acts on (mockable in tests and `settings_demo`).
pub trait MobileSource {
    fn snapshot(&self) -> MobileStateSnapshot;
    fn add_observer(&self, id: &str, handler: MobileObserver);
    fn remove_observer(&self, id: &str);
    fn refresh(&self);
    fn regenerate_pairing(&self);
    fn revoke_device(&self, device_id: &str);
    fn revoke_all_devices(&self);
}

struct ControllerState {
    enabled: bool,
    port: u16,
    checking: bool,
    tailscale: TailscaleStatus,
    server: Option<RunningServer>,
    configured_serve_port: Option<u16>,
    generation: u64,
    observers: BTreeMap<String, MobileObserver>,
}

/// Shared, cheaply cloneable controller owned by the app shell and passed to Settings.
#[derive(Clone)]
pub struct MobileController {
    inner: Arc<MobileControllerInner>,
}

struct MobileControllerInner {
    pairing: Arc<PairingStore>,
    runner: Arc<dyn TailscaleRunner>,
    data_snapshot: Arc<RwLock<MobileSnapshot>>,
    events: broadcast::Sender<ServerEvent>,
    commands_tx: async_channel::Sender<MobileCommand>,
    clients: Arc<MobileClients>,
    state: Mutex<ControllerState>,
}

impl MobileController {
    /// Creates a new controller backed by `state` and returns `(controller, command_rx)`.
    /// The app shell consumes `command_rx` on the UI thread to answer PWA requests.
    pub fn new(state: StateStore) -> (Self, async_channel::Receiver<MobileCommand>) {
        Self::with_runner(state, Arc::new(SystemTailscaleRunner))
    }

    pub fn with_runner(
        state: StateStore,
        runner: Arc<dyn TailscaleRunner>,
    ) -> (Self, async_channel::Receiver<MobileCommand>) {
        let (events, _) = broadcast::channel(64);
        let (commands_tx, commands_rx) = async_channel::unbounded();
        let controller = Self {
            inner: Arc::new(MobileControllerInner {
                pairing: Arc::new(PairingStore::new(state)),
                runner,
                data_snapshot: Arc::new(RwLock::new(MobileSnapshot::default())),
                events,
                commands_tx,
                clients: Arc::new(MobileClients::default()),
                state: Mutex::new(ControllerState {
                    enabled: false,
                    port: 8443,
                    checking: false,
                    tailscale: TailscaleStatus::Disabled,
                    server: None,
                    configured_serve_port: None,
                    generation: 0,
                    observers: BTreeMap::new(),
                }),
            }),
        };
        (controller, commands_rx)
    }

    /// Reconciles the running server and `tailscale serve` against `settings.json`.
    pub fn apply_config(&self, enabled: bool, port: u16) {
        let prev_serve_port;
        let generation;
        {
            let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
            if st.enabled == enabled && st.port == port && (st.server.is_some() == enabled) {
                return;
            }
            st.generation = st.generation.wrapping_add(1);
            generation = st.generation;
            prev_serve_port = st.configured_serve_port.take();
            st.enabled = enabled;
            st.port = port;

            if !enabled {
                st.server = None;
                st.checking = false;
                st.tailscale = TailscaleStatus::Disabled;
                self.inner.pairing.clear_offer();
            } else {
                st.checking = true;
            }
        }

        if !enabled {
            self.notify_observers();
            if let Some(old_port) = prev_serve_port {
                let runner = self.inner.runner.clone();
                std::thread::Builder::new()
                    .name("soprano-tailscale-off".into())
                    .spawn(move || {
                        let _ = disable_serve(runner.as_ref(), old_port);
                    })
                    .ok();
            }
            return;
        }

        // Start loopback server if not already listening.
        let local_port = match self.ensure_server_running() {
            Ok(p) => p,
            Err(message) => {
                {
                    let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
                    st.checking = false;
                    st.tailscale = TailscaleStatus::Error { message };
                }
                self.notify_observers();
                return;
            }
        };

        self.notify_observers();
        self.spawn_tailscale_connect(generation, port, local_port, prev_serve_port);
    }

    /// Publishes the inbox snapshot to all connected mobile clients, unless it is the one
    /// they already have.
    pub fn publish_snapshot(&self, snapshot: MobileSnapshot) {
        {
            let mut guard = self.inner.data_snapshot.write().unwrap_or_else(|e| e.into_inner());
            if *guard == snapshot {
                return;
            }
            *guard = snapshot.clone();
        }
        let _ = self.inner.events.send(ServerEvent::Snapshot { snapshot: Box::new(snapshot) });
    }

    /// Phones connected right now.
    pub fn connected_clients(&self) -> usize {
        self.inner.clients.count()
    }

    /// The threads open on any connected phone.
    pub fn watched_threads(&self) -> BTreeSet<String> {
        self.inner.clients.watched_threads()
    }

    /// Notifies connected mobile clients that a thread's conversation has new content.
    pub fn notify_thread_updated(&self, thread_id: impl Into<String>) {
        let _ = self.inner.events.send(ServerEvent::ThreadUpdated { thread_id: thread_id.into() });
    }

    /// Stops the local server on app shutdown (keeps the `tailscale serve` config intact while
    /// Mobile Access remains enabled so re-opening Soprano reconnects immediately).
    pub fn shutdown_local_server(&self) {
        let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        st.server = None;
    }

    fn ensure_server_running(&self) -> Result<u16, String> {
        let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(server) = &st.server {
            return Ok(server.local_port());
        }
        let controller_paired = self.clone();
        let on_paired = Arc::new(move || {
            controller_paired.notify_observers();
        });
        let controller_clients = self.clone();
        let on_clients = Arc::new(move || {
            controller_clients.notify_observers();
        });
        let server = start_server(
            self.inner.pairing.clone(),
            self.inner.data_snapshot.clone(),
            self.inner.events.clone(),
            self.inner.commands_tx.clone(),
            self.inner.clients.clone(),
            on_paired,
            on_clients,
        )?;
        let port = server.local_port();
        st.server = Some(server);
        Ok(port)
    }

    fn spawn_tailscale_connect(
        &self,
        generation: u64,
        https_port: u16,
        local_port: u16,
        previous_port: Option<u16>,
    ) {
        let controller = self.clone();
        std::thread::Builder::new()
            .name("soprano-tailscale-connect".into())
            .spawn(move || {
                if let Some(old_port) = previous_port
                    && old_port != https_port
                {
                    let _ = disable_serve(controller.inner.runner.as_ref(), old_port);
                }
                let status = connect_serve(controller.inner.runner.as_ref(), https_port, local_port);
                {
                    let mut st = controller.inner.state.lock().unwrap_or_else(|e| e.into_inner());
                    if st.generation != generation {
                        return;
                    }
                    st.checking = false;
                    if let Some(https_url) = status.https_url() {
                        st.configured_serve_port = Some(https_port);
                        if controller.inner.pairing.active_offer().is_none() {
                            let _ = controller.inner.pairing.create_offer(https_url);
                        }
                    } else {
                        controller.inner.pairing.clear_offer();
                    }
                    st.tailscale = status;
                }
                controller.notify_observers();
            })
            .ok();
    }

    fn current_snapshot(&self) -> MobileStateSnapshot {
        let st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        MobileStateSnapshot {
            enabled: st.enabled,
            port: st.port,
            local_port: st.server.as_ref().map(RunningServer::local_port),
            checking: st.checking,
            tailscale: st.tailscale.clone(),
            pairing: self.inner.pairing.active_offer(),
            devices: self.inner.pairing.devices(),
            connected_clients: self.inner.clients.count(),
        }
    }

    fn notify_observers(&self) {
        let snap = self.current_snapshot();
        let observers: Vec<MobileObserver> = {
            let st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
            st.observers.values().cloned().collect()
        };
        for observer in observers {
            observer(&snap);
        }
    }
}

impl MobileSource for MobileController {
    fn snapshot(&self) -> MobileStateSnapshot {
        self.current_snapshot()
    }

    fn add_observer(&self, id: &str, handler: MobileObserver) {
        let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        st.observers.insert(id.to_owned(), handler);
    }

    fn remove_observer(&self, id: &str) {
        let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        st.observers.remove(id);
    }

    fn refresh(&self) {
        let (enabled, port, generation, local_port) = {
            let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
            if !st.enabled {
                return;
            }
            st.generation = st.generation.wrapping_add(1);
            st.checking = true;
            (st.enabled, st.port, st.generation, st.server.as_ref().map(RunningServer::local_port))
        };
        if !enabled {
            return;
        }
        let local_port = match local_port {
            Some(p) => p,
            None => match self.ensure_server_running() {
                Ok(p) => p,
                Err(message) => {
                    let mut st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
                    st.checking = false;
                    st.tailscale = TailscaleStatus::Error { message };
                    drop(st);
                    self.notify_observers();
                    return;
                }
            },
        };
        self.notify_observers();
        self.spawn_tailscale_connect(generation, port, local_port, None);
    }

    fn regenerate_pairing(&self) {
        let base_url = {
            let st = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
            st.tailscale.https_url().map(str::to_owned)
        };
        if let Some(url) = base_url {
            let _ = self.inner.pairing.create_offer(&url);
            self.notify_observers();
        }
    }

    fn revoke_device(&self, device_id: &str) {
        if self.inner.pairing.revoke(device_id) {
            self.notify_observers();
        }
    }

    fn revoke_all_devices(&self) {
        if self.inner.pairing.revoke_all() > 0 {
            self.notify_observers();
        }
    }
}
