//! Converts agent lifecycle events and terminal OSC notifications into model state, unread
//! attention markers, and native banners (the app side of `AgentNotificationManager.swift`).

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use soprano_ipc::{AgentAlert, AgentEvent, AgentEventState};
use soprano_model::{PaneType, TerminalTarget, Workspace, WorkspaceChange};
use soprano_platform::{AppIdentity, StateStore};
use soprano_types::{AgentCatalog, AgentWaitingReason};

use crate::authorization::{Authorization, AuthorizationState};
use crate::backend::{Banner, BannerClick, NotificationBackend, SystemAuthorization, system_backend};

/// An identical event for the same tab within this window is a hook firing twice.
const DUPLICATE_WINDOW: Duration = Duration::from_secs(1);

/// An OSC 9 / OSC 777 notification a terminal surface received (soprano-term's
/// `TerminalEvent::DesktopNotification`), with the tab it came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TerminalNotification {
    pub target: TerminalTarget,
    pub title: String,
    pub body: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct EventFingerprint {
    state: AgentEventState,
    notify: bool,
    title: String,
    body: String,
}

/// Where the keyboard is: the app's activation and the surface holding focus inside it.
#[derive(Debug)]
struct Focus {
    app_active: bool,
    surface: Option<TerminalTarget>,
}

/// State the OS completion handlers reach from their own threads.
struct Shared {
    backend: Option<Arc<dyn NotificationBackend>>,
    authorization: AuthorizationState,
    /// Banners still in the notification center, per tab, to withdraw once it is focused.
    delivered: Mutex<HashMap<TerminalTarget, HashSet<String>>>,
    focus: Mutex<Focus>,
}

impl Shared {
    /// The tab with keyboard focus while the app is frontmost (Swift `focusedSurfaceTarget`).
    fn focused_target(&self) -> Option<TerminalTarget> {
        let focus = self.focus.lock().expect("focus lock");
        if focus.app_active { focus.surface.clone() } else { None }
    }

    fn remove_delivered(&self, target: &TerminalTarget) {
        let identifiers = self.delivered.lock().expect("delivered lock").remove(target);
        if let (Some(backend), Some(identifiers)) = (&self.backend, identifiers) {
            backend.remove_delivered(&identifiers.into_iter().collect::<Vec<_>>());
        }
    }

    fn schedule(self: &Arc<Self>, banner: Banner) {
        let Some(backend) = self.backend.clone() else { return };
        let shared = self.clone();
        let target = banner.target.clone();
        let identifier = banner.identifier.clone();
        backend.clone().post(
            banner,
            Box::new(move |result| {
                if let Err(error) = result {
                    // Swallowing this is how a completely dead notification path stays
                    // invisible; at minimum it belongs in the log.
                    tracing::error!("Soprano: could not post notification for {}: {error}", target.pane_id);
                    return;
                }
                // Checked and recorded under the `delivered` lock: focusing sets the focus first
                // and then takes this lock to withdraw, so either this sees the tab focused or
                // the withdrawal sees the record. (Swift got the same from the main queue.)
                let focused = {
                    let mut delivered = shared.delivered.lock().expect("delivered lock");
                    let focused = shared.focused_target().as_ref() == Some(&target);
                    if !focused {
                        delivered.entry(target).or_default().insert(identifier.clone());
                    }
                    focused
                };
                if focused {
                    backend.remove_delivered(&[identifier]);
                }
            }),
        );
    }
}

/// Receives agent events and terminal notifications on the UI thread and updates the
/// [`Workspace`]; banners go to the OS notification service.
///
/// Mutations go through ordinary `Workspace` methods, so they record [`WorkspaceChange::Model`]
/// (or [`WorkspaceChange::Layout`] when a tab is focused) for the host to drain.
pub struct NotificationManager {
    shared: Arc<Shared>,
    sound: Box<dyn Fn() -> bool + Send>,
    recent_events: HashMap<TerminalTarget, (EventFingerprint, Instant)>,
}

impl NotificationManager {
    /// The manager on the running OS's notification service. `sound` is read for every banner
    /// (`settings.notification_sound`), so a `settings.json` edit applies to the very next one.
    /// `on_banner_clicked` runs on the OS's thread: hop to the UI thread, activate the app,
    /// then [`BannerClick::focus`] (or open the automation run).
    pub fn new(
        identity: &AppIdentity,
        state: StateStore,
        sound: impl Fn() -> bool + Send + 'static,
        on_banner_clicked: impl Fn(BannerClick) + Send + Sync + 'static,
    ) -> Self {
        Self::with_backend(system_backend(identity, Arc::new(on_banner_clicked)), state, sound)
    }

    /// The manager on a given service; `None` means this process cannot post banners.
    pub fn with_backend(
        backend: Option<Arc<dyn NotificationBackend>>,
        state: StateStore,
        sound: impl Fn() -> bool + Send + 'static,
    ) -> Self {
        Self {
            shared: Arc::new(Shared {
                backend,
                authorization: AuthorizationState::new(state),
                delivered: Mutex::new(HashMap::new()),
                focus: Mutex::new(Focus { app_active: true, surface: None }),
            }),
            sound: Box::new(sound),
            recent_events: HashMap::new(),
        }
    }

    /// Whether this process can post banners at all.
    pub fn can_post(&self) -> bool {
        self.shared.backend.is_some()
    }

    // MARK: - Authorization

    /// What the OS last said about permission, for the settings screen; `None` until the
    /// first check completes. Persisted under [`crate::AUTHORIZATION_KEY`].
    pub fn authorization(&self) -> Option<Authorization> {
        self.shared.authorization.current()
    }

    /// Called (on any thread) whenever the published authorization changes.
    pub fn on_authorization_changed(&self, observer: impl Fn(Authorization) + Send + Sync + 'static) {
        self.shared.authorization.set_observer(Arc::new(observer));
    }

    /// Asks the OS for permission once, at launch.
    ///
    /// Authorization is also requested lazily by a banner, but that path only runs when an
    /// agent reports in while its pane is unfocused. A user who watches their agents finish
    /// never reaches it, so the prompt never appears and no notification can ever be
    /// delivered. Asking at launch makes the permission explicit before the first event.
    pub fn request_authorization_if_needed(&self) {
        let Some(backend) = self.shared.backend.clone() else { return };
        let shared = self.shared.clone();
        backend.clone().authorization_status(Box::new(move |status| {
            if status != SystemAuthorization::NotDetermined {
                refresh(&shared);
                return;
            }
            backend.request_authorization(Box::new(move |granted| {
                shared.authorization.publish(if granted {
                    Authorization::Authorized
                } else {
                    Authorization::Denied
                });
            }));
        }));
    }

    /// Asks the OS for the current state and publishes it. The settings screen calls this
    /// when it appears so its line is never stale.
    pub fn refresh_authorization(&self) {
        refresh(&self.shared);
    }

    // MARK: - Focus

    /// The app came to the front: the focused tab's marks and banners go.
    pub fn app_did_become_active(&mut self, workspace: &mut Workspace) {
        self.shared.focus.lock().expect("focus lock").app_active = true;
        self.clear_for_focused_target(workspace);
    }

    /// The app went to the background: every pane now counts as unfocused.
    pub fn app_did_resign_active(&mut self) {
        self.shared.focus.lock().expect("focus lock").app_active = false;
    }

    /// A terminal or chat surface took keyboard focus: its attention mark and its banners go.
    pub fn surface_did_focus(&mut self, workspace: &mut Workspace, target: TerminalTarget) {
        self.shared.focus.lock().expect("focus lock").surface = Some(target.clone());
        workspace.clear_attention(&target.pane_id, &target.tab_id);
        self.shared.remove_delivered(&target);
    }

    /// Keyboard focus left `target` for something that is not a terminal or chat (the
    /// sidebar, a dialog, an editor).
    pub fn surface_did_lose_focus(&mut self, target: &TerminalTarget) {
        let mut focus = self.shared.focus.lock().expect("focus lock");
        if focus.surface.as_ref() == Some(target) {
            focus.surface = None;
        }
    }

    /// Call with the changes drained from the workspace: a model change may have brought a
    /// tab to focus, and that tab's marks and banners go.
    pub fn workspace_did_change(&mut self, workspace: &mut Workspace, changes: &[WorkspaceChange]) {
        if changes.iter().any(|change| matches!(change, WorkspaceChange::Model | WorkspaceChange::Layout)) {
            self.clear_for_focused_target(workspace);
        }
    }

    /// The tab that counts as focused: keyboard focus inside the frontmost app.
    pub fn focused_target(&self) -> Option<TerminalTarget> {
        self.shared.focused_target()
    }

    fn is_focused(&self, target: &TerminalTarget) -> bool {
        self.shared.focused_target().as_ref() == Some(target)
    }

    fn clear_for_focused_target(&mut self, workspace: &mut Workspace) {
        let Some(target) = self.shared.focused_target() else { return };
        workspace.clear_attention(&target.pane_id, &target.tab_id);
        self.shared.remove_delivered(&target);
    }

    // MARK: - Events

    /// An `agent-event` report from a pane (`Request::AgentEvent`).
    pub fn handle_agent_event(&mut self, workspace: &mut Workspace, event: AgentEvent) {
        self.handle_agent_event_at(workspace, event, Instant::now());
    }

    /// [`Self::handle_agent_event`] at a given time (duplicate suppression is time based).
    pub fn handle_agent_event_at(&mut self, workspace: &mut Workspace, event: AgentEvent, now: Instant) {
        let target = TerminalTarget::new(&event.pane_id, &event.tab_id);
        // A stop never attaches: agent tabs report one again from their shell fallback after
        // the agent's own shutdown hook has already detached it.
        if let Some(profile_id) = &event.profile_id
            && event.state != AgentEventState::Stopped
        {
            workspace.attach_agent_if_needed(&event.pane_id, &event.tab_id, profile_id);
        }

        let Some(agent) = workspace.agent_mut(&event.pane_id, &event.tab_id) else { return };
        if let Some(process_id) = event.process_id
            && event.profile_id.as_deref() == Some(agent.profile_id.as_str())
        {
            agent.process_id = Some(process_id);
        }
        if let Some(message) = &event.message {
            agent.last_message = Some(message.clone());
        }
        let profile_id = agent.profile_id.clone();
        let runs_automation = agent.automation_run_id.is_some();
        // Identity must survive even if the status/message is a duplicate, or if the event is
        // SessionEnd just before the workspace is saved.
        if let Some(conversation) = &event.conversation {
            workspace.record_agent_conversation(
                conversation.clone(),
                &event.pane_id,
                &event.tab_id,
                event.profile_id.as_deref(),
            );
        }

        let fingerprint = EventFingerprint {
            state: event.state,
            notify: event.notify,
            title: event.title.clone(),
            body: event.body.clone(),
        };
        if let Some((recent, at)) = self.recent_events.get(&target)
            && *recent == fingerprint
            && now.saturating_duration_since(*at) < DUPLICATE_WINDOW
        {
            return;
        }
        self.recent_events.insert(target.clone(), (fingerprint, now));

        let needs_attention = event.notify && !self.is_focused(&target);

        if event.state == AgentEventState::Stopped {
            workspace.agent_returned_to_shell(&target, None);
            return;
        }

        workspace.update_agent_status(
            &event.pane_id,
            &event.tab_id,
            event.state.agent_status(),
            Some(needs_attention),
            event.reason,
        );

        // An automation's run announces itself, naming the automation, once it has the run's
        // outcome; a banner for its pane would name a window nobody opened.
        if needs_attention && !runs_automation {
            let (title, body) = agent_banner(workspace, &event, &profile_id);
            self.deliver(title, body, None, target, None);
        }
    }

    /// An OSC 9 / OSC 777 notification from a terminal. In an agent's tab it is that agent
    /// asking (Codex reports approvals this way); in a plain terminal its program wrote the
    /// banner itself and only the location is added.
    pub fn handle_terminal_notification(
        &mut self,
        workspace: &mut Workspace,
        notification: TerminalNotification,
    ) {
        let TerminalNotification { target, title, body } = notification;
        let combined = format!("{title} {body}").to_lowercase();
        let profile_id =
            workspace.agent(&target.pane_id, &target.tab_id).map(|agent| agent.profile_id.clone());
        let is_codex = profile_id.as_deref() == Some("codex");
        let needs_input = is_codex
            || ["approval", "permission", "question", "input required"]
                .iter()
                .any(|word| combined.contains(word));
        // Codex rings the terminal bell this way only for approvals.
        let reason = if is_codex || combined.contains("approv") || combined.contains("permission") {
            AgentWaitingReason::Approval
        } else {
            AgentWaitingReason::Question
        };

        let Some(profile_id) = profile_id else {
            // A plain terminal's program wrote the title and body itself; only the location
            // says which pane it came from.
            if self.is_focused(&target) {
                return;
            }
            let subtitle = location_subtitle_for(workspace, &target);
            self.deliver(title, body, subtitle, target, None);
            return;
        };

        let title = if title.is_empty() { agent_name(&profile_id) } else { title };
        let body = match (body.is_empty(), needs_input) {
            (false, _) => body,
            (true, true) => "Input required".to_owned(),
            (true, false) => "Ready for a prompt".to_owned(),
        };
        self.handle_agent_event(
            workspace,
            AgentEvent {
                pane_id: target.pane_id,
                tab_id: target.tab_id,
                state: if needs_input { AgentEventState::NeedsInput } else { AgentEventState::Ready },
                notify: true,
                title,
                body,
                profile_id: Some(profile_id),
                process_id: None,
                message: None,
                reason: needs_input.then_some(reason),
                conversation: None,
            },
        );
    }

    /// The tab's shell reported that its command finished (OSC 133;D): a dedicated agent tab
    /// becomes a terminal; an agent typed into a terminal detaches once the process its hooks
    /// named is gone (or at once when they named none).
    pub fn terminal_command_did_finish(
        &mut self,
        workspace: &mut Workspace,
        target: &TerminalTarget,
        exit_code: Option<i32>,
    ) {
        workspace.agent_command_did_finish(target, exit_code);
    }

    /// The tab's pane process exited.
    pub fn terminal_child_did_exit(
        &mut self,
        workspace: &mut Workspace,
        target: &TerminalTarget,
        exit_code: Option<i32>,
    ) {
        workspace.agent_process_did_exit(target, exit_code);
    }

    /// Periodic upkeep (every second or two): forgets expired duplicate fingerprints, and
    /// detaches agents typed into a terminal whose hook-owner process has exited without a
    /// shutdown hook, so their badge clears even when the shell never reports the prompt.
    pub fn tick(&mut self, now: Instant, workspace: &mut Workspace) {
        self.recent_events.retain(|_, (_, at)| now.saturating_duration_since(*at) < DUPLICATE_WINDOW);
        let monitored: Vec<TerminalTarget> = workspace
            .panes()
            .values()
            .flat_map(|pane| {
                pane.tabs
                    .iter()
                    .filter(|tab| {
                        tab.pane_type == PaneType::Terminal
                            && tab.agent.as_ref().is_some_and(|agent| agent.process_id.is_some())
                    })
                    .map(|tab| TerminalTarget::new(&pane.id, &tab.id))
            })
            .collect();
        for target in monitored {
            // For a terminal tab with a known process this detaches only when it is gone.
            workspace.agent_command_did_finish(&target, None);
        }
    }

    /// A banner for an automation run; clicking it opens the run in Automations rather than
    /// its terminal, which may already be closed.
    pub fn deliver_automation_notification(&self, title: &str, body: &str, run_id: &str) {
        self.deliver(
            title.to_owned(),
            body.to_owned(),
            Some(Workspace::AUTOMATION_SESSION_NAME.to_owned()),
            TerminalTarget::new(format!("automation-{run_id}"), run_id),
            Some(run_id.to_owned()),
        );
    }

    /// Names the session, window, and pane asking for attention: `Session ▸ Window ▸ Tab`,
    /// skipping missing and empty parts.
    pub fn location_subtitle(
        session_name: Option<&str>,
        window_title: Option<&str>,
        tab_title: Option<&str>,
    ) -> Option<String> {
        let parts: Vec<&str> = [session_name, window_title, tab_title]
            .into_iter()
            .flatten()
            .filter(|part| !part.is_empty())
            .collect();
        (!parts.is_empty()).then(|| parts.join(" ▸ "))
    }

    fn deliver(
        &self,
        title: String,
        body: String,
        subtitle: Option<String>,
        target: TerminalTarget,
        automation_run_id: Option<String>,
    ) {
        let Some(backend) = self.shared.backend.clone() else { return };
        let banner = Banner {
            identifier: Banner::identifier(&target),
            title,
            subtitle,
            body,
            plays_sound: (self.sound)(),
            thread_identifier: target.pane_id.clone(),
            target,
            automation_run_id,
        };
        let shared = self.shared.clone();
        backend.clone().authorization_status(Box::new(move |status| match status {
            SystemAuthorization::Authorized => {
                shared.authorization.publish(Authorization::Authorized);
                shared.schedule(banner);
            }
            SystemAuthorization::NotDetermined => {
                backend.request_authorization(Box::new(move |granted| {
                    shared.authorization.publish(if granted {
                        Authorization::Authorized
                    } else {
                        Authorization::Denied
                    });
                    if granted {
                        shared.schedule(banner);
                    }
                }));
            }
            // The OS only ever prompts once. After a denial the app cannot ask again, so the
            // only honest thing is to record it and let Settings offer the way to the OS page.
            SystemAuthorization::Denied => shared.authorization.publish(Authorization::Denied),
            SystemAuthorization::Unknown => {}
        }));
    }
}

impl BannerClick {
    /// Focuses the banner's tab (Swift `focusTab`); an automation run's banner is the host's
    /// to open in Automations.
    pub fn focus(&self, workspace: &mut Workspace) {
        if let Self::Tab(target) = self {
            workspace.focus_tab(&target.pane_id, &target.tab_id, false);
        }
    }
}

fn refresh(shared: &Arc<Shared>) {
    let Some(backend) = &shared.backend else {
        shared.authorization.publish(Authorization::Unavailable);
        return;
    };
    let shared = shared.clone();
    backend.authorization_status(Box::new(move |status| {
        shared.authorization.publish(match status {
            SystemAuthorization::Authorized => Authorization::Authorized,
            SystemAuthorization::Denied => Authorization::Denied,
            SystemAuthorization::NotDetermined => Authorization::NotDetermined,
            SystemAuthorization::Unknown => Authorization::Unavailable,
        });
    }));
}

fn agent_name(profile_id: &str) -> String {
    AgentCatalog::shared()
        .profile(profile_id)
        .map(|profile| profile.name)
        .unwrap_or_else(|| "Agent".to_owned())
}

/// The banner for an agent event: what the agent wants, over the conversation (tab) name.
fn agent_banner(workspace: &Workspace, event: &AgentEvent, profile_id: &str) -> (String, String) {
    let agent_name = AgentCatalog::shared()
        .profile(profile_id)
        .map(|profile| profile.name)
        .unwrap_or_else(|| event.title.clone());
    let Some(alert) = AgentAlert::new(event.state, event.reason) else {
        return (event.title.clone(), event.body.clone());
    };
    let window = workspace.window_containing_pane(&event.pane_id);
    let session_name = window
        .and_then(|window| workspace.terminal_sessions().get(&window.session_id))
        .map(|session| session.name.as_str());
    (
        alert.title(&agent_name),
        AgentAlert::body(
            &agent_name,
            workspace.tab(&event.pane_id, &event.tab_id).map(|tab| tab.title.as_str()),
            window.map(|window| window.title.as_str()),
            session_name,
        ),
    )
}

fn location_subtitle_for(workspace: &Workspace, target: &TerminalTarget) -> Option<String> {
    let window = workspace.window_containing_pane(&target.pane_id);
    NotificationManager::location_subtitle(
        window
            .and_then(|window| workspace.terminal_sessions().get(&window.session_id))
            .map(|session| session.name.as_str()),
        window.map(|window| window.title.as_str()),
        workspace.tab(&target.pane_id, &target.tab_id).map(|tab| tab.title.as_str()),
    )
}
