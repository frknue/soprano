//! What each pane tab shows, the non-visual half of `Views/SplitTreeView.swift`.
//!
//! Content entities are cached by exact pane/tab target and survive layout rebuilds: a tab's
//! terminal is never recreated because the split tree changed, a window was switched away from,
//! or a tab moved to the back. Content goes away only when its tab does (or a restored
//! workspace replaces every tab). Terminal reports flow back into the workspace here: titles,
//! folders, running commands, agent input and exits, closes, copy mode.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gpui::{
    AnyView, App, AppContext, Context, Entity, EventEmitter, FocusHandle, Focusable, SharedString,
    Subscription, Task, Window,
};
use soprano_accounts::AccountLaunchState;
use soprano_browser::{BrowserEvent, BrowserView};
use soprano_chat::session::AgentChatEvent;
use soprano_chat_ui::{ChatView, ChatViewEvent};
use soprano_editor::{
    DiffEvent, DiffView, DocumentsEvent, EditorDocuments, EditorEvent, EditorView, MarkdownReaderView,
    ReaderEvent,
};
use soprano_ipc::AgentEventState;
use soprano_launch::{AccountAdjustments, AgentRequest, LaunchContext, LaunchSpec};
use soprano_model::file_url;
use soprano_model::{PaneTab, PaneType, TerminalLifecycleAction, WorkspaceChange, WorkspaceEvent};
use soprano_platform::StateStore;
use soprano_term::ClipboardConfirmationCoordinator;
use soprano_term::{
    ClipboardRequest, TerminalEvent, TerminalLaunch, TerminalSettings, TerminalTheme, TerminalView,
};
use soprano_text::DocumentId;
use soprano_types::TerminalTarget;
use soprano_types::{AgentCatalog, AgentConversation, AgentStatus, KeybindingState};

use crate::shell::{CloseTarget, Command, Shell, dispatch};
use crate::workspace::{WorkspaceHandle, WorkspaceUpdate};

/// Seconds between samples of which terminals are running a command (Swift
/// `runningCommandSampleInterval`). Shell integration reports the end of a command at once;
/// the sample catches the start.
pub const RUNNING_COMMAND_SAMPLE_INTERVAL: Duration = Duration::from_secs(1);
/// How long a starting Codex agent may stay "starting" before it counts as ready.
pub const CODEX_READINESS_DELAY: Duration = Duration::from_millis(2500);

/// One tab's content.
#[derive(Clone)]
pub enum PaneContent {
    Terminal(Entity<TerminalView>),
    Browser(Entity<BrowserView>),
    /// A chat tab: the agent's ACP session in the chat view.
    Chat(Entity<ChatView>),
    /// A file in the code editor.
    Editor(Entity<EditorView<TerminalTarget>>),
    /// The git diff of a file.
    Diff(Entity<DiffView>),
    /// A Markdown reader.
    Reader(Entity<MarkdownReaderView>),
    /// An agent tab whose agent was stopped before this view existed: no process runs until
    /// it is restarted (Swift's surface-less terminal view).
    Stopped,
    /// The content could not start; the pane shows why.
    Failed(SharedString),
}

impl PaneContent {
    pub fn view(&self) -> Option<AnyView> {
        match self {
            PaneContent::Terminal(view) => Some(view.clone().into()),
            PaneContent::Browser(view) => Some(view.clone().into()),
            PaneContent::Chat(view) => Some(view.clone().into()),
            PaneContent::Editor(view) => Some(view.clone().into()),
            PaneContent::Diff(view) => Some(view.clone().into()),
            PaneContent::Reader(view) => Some(view.clone().into()),
            PaneContent::Stopped | PaneContent::Failed(_) => None,
        }
    }

    pub fn focus_handle(&self, cx: &App) -> Option<FocusHandle> {
        match self {
            PaneContent::Terminal(view) => Some(view.focus_handle(cx)),
            PaneContent::Browser(view) => Some(view.focus_handle(cx)),
            PaneContent::Chat(view) => Some(view.focus_handle(cx)),
            PaneContent::Editor(view) => Some(view.focus_handle(cx)),
            PaneContent::Diff(view) => Some(view.focus_handle(cx)),
            PaneContent::Reader(view) => Some(view.focus_handle(cx)),
            PaneContent::Stopped | PaneContent::Failed(_) => None,
        }
    }

    pub fn terminal(&self) -> Option<&Entity<TerminalView>> {
        match self {
            PaneContent::Terminal(view) => Some(view),
            _ => None,
        }
    }
}

/// Starts terminals; tests swap in one that never spawns a shell.
pub trait TerminalFactory {
    fn create(
        &self,
        launch: TerminalLaunch,
        settings: TerminalSettings,
        window: &mut Window,
        cx: &mut App,
    ) -> anyhow::Result<Entity<TerminalView>>;

    /// Restarts `view` with `launch` (Swift `recreateSurface`); false when it could not start.
    fn restart(&self, view: &Entity<TerminalView>, launch: TerminalLaunch, cx: &mut App) -> bool;
}

/// The real factory: a PTY with the launch's process.
pub struct PtyTerminals;

impl TerminalFactory for PtyTerminals {
    fn create(
        &self,
        launch: TerminalLaunch,
        settings: TerminalSettings,
        window: &mut Window,
        cx: &mut App,
    ) -> anyhow::Result<Entity<TerminalView>> {
        TerminalView::spawn(launch, settings, window, cx)
    }

    fn restart(&self, view: &Entity<TerminalView>, launch: TerminalLaunch, cx: &mut App) -> bool {
        view.update(cx, |view, cx| view.restart(launch, cx)).is_ok()
    }
}

/// What the main view handles for the content layer.
#[derive(Clone, Debug)]
pub enum ContentEvent {
    /// A terminal entered or left copy mode (the status bar's mode).
    CopyModeChanged(KeybindingState),
    /// A terminal needs a clipboard confirmation.
    ClipboardConfirmation { terminal: Entity<TerminalView>, request: ClipboardRequest },
    /// A program posted a desktop notification (OSC 9 / 777).
    DesktopNotification { target: TerminalTarget, title: String, body: String },
    /// A chat tab's agent reported a status the way a hook does (`AgentEventPayload`).
    AgentEvent(soprano_ipc::AgentEvent),
    /// A terminal took the keyboard (clears its attention and delivered banners).
    SurfaceFocused(TerminalTarget),
    /// A terminal was destroyed or restarted: its pending clipboard prompts are denied.
    TerminalDestroyed(u64),
    /// Something to tell the user in a toast (no room for a file's tab, …).
    ShowError(String),
}

/// Which tab shows which editor document, and which documents have unsaved changes: what
/// the workspace's close-confirmation predicate (which must be `Send + Sync`) reads.
#[derive(Clone, Debug, Default)]
pub struct UnsavedEditors {
    shown: Vec<(TerminalTarget, DocumentId)>,
    dirty: HashSet<DocumentId>,
}

impl UnsavedEditors {
    pub fn new(shown: Vec<(TerminalTarget, DocumentId)>, dirty: HashSet<DocumentId>) -> Self {
        Self { shown, dirty }
    }

    /// Whether closing `targets` loses unsaved changes: a dirty document no tab outside
    /// `targets` still shows (`EditorDocumentStore::unsaved_when_closing` is not empty).
    pub fn loses_changes(&self, targets: &[TerminalTarget]) -> bool {
        self.shown.iter().any(|(target, document)| {
            targets.contains(target)
                && self.dirty.contains(document)
                && !self.shown.iter().any(|(other, shown)| shown == document && !targets.contains(other))
        })
    }
}

pub type SharedUnsaved = Arc<Mutex<UnsavedEditors>>;

/// The workspace predicate asking before tabs with unsaved editor changes close.
pub fn close_confirmation(unsaved: SharedUnsaved) -> soprano_model::CloseConfirmation {
    Box::new(move |targets| unsaved.lock().unwrap_or_else(|e| e.into_inner()).loses_changes(targets))
}

pub struct ContentHost {
    workspace: WorkspaceHandle,
    shell: Entity<Shell>,
    terminals: Rc<dyn TerminalFactory>,
    launch_context: LaunchContext,
    terminal_settings: TerminalSettings,
    documents: Entity<EditorDocuments<TerminalTarget>>,
    state: StateStore,
    unsaved: SharedUnsaved,
    clipboard: Option<Rc<ClipboardConfirmationCoordinator>>,
    contents: HashMap<TerminalTarget, PaneContent>,
    subscriptions: HashMap<TerminalTarget, Subscription>,
    last_restore_generation: u64,
    copy_mode_target: Option<TerminalTarget>,
    _bus: Subscription,
    _documents: Subscription,
    _sampler: Option<Task<()>>,
}
impl EventEmitter<ContentEvent> for ContentHost {}

impl ContentHost {
    /// Also installs the workspace's close-confirmation predicate: closing tabs whose editor
    /// documents have unsaved changes returns `CloseOutcome::NeedsConfirmation`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        workspace: WorkspaceHandle,
        shell: Entity<Shell>,
        terminals: Rc<dyn TerminalFactory>,
        launch_context: LaunchContext,
        terminal_settings: TerminalSettings,
        documents: Entity<EditorDocuments<TerminalTarget>>,
        state: StateStore,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let bus = cx.subscribe_in(&workspace.bus, window, |host, _, update: &WorkspaceUpdate, window, cx| {
            host.handle_update(update, window, cx);
        });
        let documents_subscription = cx.subscribe(&documents, |host, _, event: &DocumentsEvent, cx| {
            if let DocumentsEvent::Changed { .. } = event {
                host.refresh_unsaved(cx);
            }
        });
        let unsaved: SharedUnsaved = Arc::default();
        let predicate = close_confirmation(unsaved.clone());
        workspace.model.update(cx, |ws, _| ws.set_close_confirmation(Some(predicate)));
        let last_restore_generation = workspace.read(cx).workspace_restore_generation();
        let mut host = Self {
            workspace,
            shell,
            terminals,
            launch_context,
            terminal_settings,
            documents,
            state,
            unsaved,
            clipboard: None,
            contents: HashMap::new(),
            subscriptions: HashMap::new(),
            last_restore_generation,
            copy_mode_target: None,
            _bus: bus,
            _documents: documents_subscription,
            _sampler: None,
        };
        host.sync_visible_contents(window, cx);
        host
    }

    pub fn documents(&self) -> &Entity<EditorDocuments<TerminalTarget>> {
        &self.documents
    }

    /// The app's clipboard prompt queue, handed to every terminal (existing and future) so a
    /// destroyed terminal withdraws its own prompts.
    pub fn set_clipboard_coordinator(
        &mut self,
        coordinator: Rc<ClipboardConfirmationCoordinator>,
        cx: &mut Context<Self>,
    ) {
        for content in self.contents.values() {
            if let PaneContent::Terminal(view) = content {
                let coordinator = coordinator.clone();
                view.update(cx, |view, _| view.set_clipboard_coordinator(Some(coordinator)));
            }
        }
        self.clipboard = Some(coordinator);
    }

    /// Mirrors which tab shows which editor document and which are dirty for the predicate.
    fn refresh_unsaved(&mut self, cx: &App) {
        let documents = self.documents.read(cx);
        let shown: Vec<(TerminalTarget, DocumentId)> = self
            .contents
            .iter()
            .filter_map(|(target, content)| match content {
                PaneContent::Editor(view) => Some((target.clone(), view.read(cx).document_id())),
                _ => None,
            })
            .collect();
        let dirty = shown
            .iter()
            .map(|(_, id)| *id)
            .filter(|id| documents.document(*id).is_some_and(|d| d.is_dirty()))
            .collect();
        *self.unsaved.lock().unwrap_or_else(|e| e.into_inner()) = UnsavedEditors::new(shown, dirty);
    }

    /// Samples running commands every second (the app does this; tests drive it by hand).
    pub fn start_sampling(&mut self, cx: &mut Context<Self>) {
        self._sampler = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(RUNNING_COMMAND_SAMPLE_INTERVAL).await;
                if this.update(cx, |this, cx| this.sample_running_commands(cx)).is_err() {
                    break;
                }
            }
        }));
    }

    pub fn content(&self, target: &TerminalTarget) -> Option<&PaneContent> {
        self.contents.get(target)
    }

    pub fn contents(&self) -> impl Iterator<Item = (&TerminalTarget, &PaneContent)> {
        self.contents.iter()
    }

    /// The content of `pane_id`'s active tab.
    pub fn active_content(&self, pane_id: &str, cx: &App) -> Option<&PaneContent> {
        let tab = self.workspace.read(cx).pane(pane_id)?.active_tab()?;
        self.contents.get(&TerminalTarget::new(pane_id, &tab.id))
    }

    /// The terminal of the focused pane's active tab.
    pub fn active_terminal(&self, cx: &App) -> Option<Entity<TerminalView>> {
        let pane_id = self.workspace.read(cx).active_pane_id().to_owned();
        self.active_content(&pane_id, cx)?.terminal().cloned()
    }

    /// Whether `handle` belongs to any pane content (a dead pane's focus is reclaimed).
    pub fn owns_focus(&self, window: &Window, cx: &App) -> bool {
        self.contents
            .values()
            .filter_map(|content| content.focus_handle(cx))
            .any(|handle| handle.contains_focused(window, cx))
    }

    pub fn terminal_settings(&self) -> &TerminalSettings {
        &self.terminal_settings
    }

    /// New colors, font or zoom for every terminal.
    pub fn set_terminal_settings(&mut self, settings: TerminalSettings, cx: &mut Context<Self>) {
        if settings == self.terminal_settings {
            return;
        }
        self.terminal_settings = settings.clone();
        for content in self.contents.values() {
            if let PaneContent::Terminal(view) = content {
                let settings = settings.clone();
                view.update(cx, |view, cx| view.set_settings(settings, cx));
            }
        }
    }

    // MARK: - Workspace changes

    fn handle_update(&mut self, update: &WorkspaceUpdate, window: &mut Window, cx: &mut Context<Self>) {
        for event in &update.events {
            match event {
                WorkspaceEvent::Terminal(action) => self.handle_lifecycle(action, window, cx),
            }
        }
        for change in &update.changes {
            if let WorkspaceChange::Document(target) = change {
                self.handle_document_change(target, cx);
            }
        }
        self.cancel_copy_mode_outside_active_terminal(cx);
        let generation = self.workspace.read(cx).workspace_restore_generation();
        if generation != self.last_restore_generation {
            self.last_restore_generation = generation;
            self.invalidate_all(cx);
        }
        self.prune_orphans(cx);
        self.sync_visible_contents(window, cx);
        self.sync_diff_visibility(cx);
        self.refresh_unsaved(cx);
        cx.notify();
    }

    /// A file tab now shows another file (a rename or move, a reused preview): a reader
    /// opens it in place; an editor or diff whose file differs is rebuilt. Editor documents
    /// follow a move themselves (`EditorDocuments::relocate`), so their views stay.
    fn handle_document_change(&mut self, target: &TerminalTarget, cx: &mut Context<Self>) {
        let Some(path) = self
            .workspace
            .read(cx)
            .tab(&target.pane_id, &target.tab_id)
            .and_then(|tab| tab.url.as_deref().and_then(file_url::path_from_file_url))
        else {
            return;
        };
        let stale = match self.contents.get(target) {
            Some(PaneContent::Reader(view)) => {
                if view.read(cx).path() != path {
                    view.update(cx, |view, cx| view.open_document(&path, None, false, cx));
                }
                false
            }
            Some(PaneContent::Editor(view)) => {
                view.read(cx).path(cx).is_none_or(|shown| !same_file(&shown, &path))
            }
            Some(PaneContent::Diff(view)) => !same_file(view.read(cx).file(), &path),
            _ => false,
        };
        if stale {
            self.remove_content(target, cx);
        }
    }

    /// Diffs stop watching while their tab is hidden and reload when it shows again.
    fn sync_diff_visibility(&mut self, cx: &mut Context<Self>) {
        let shown: HashSet<TerminalTarget> = {
            let workspace = self.workspace.read(cx);
            workspace
                .layout()
                .map(|layout| layout.leaf_ids())
                .unwrap_or_default()
                .into_iter()
                .filter_map(|pane_id| {
                    let tab = workspace.pane(&pane_id)?.active_tab()?;
                    Some(TerminalTarget::new(&pane_id, &tab.id))
                })
                .collect()
        };
        for (target, content) in &self.contents {
            if let PaneContent::Diff(view) = content {
                let visible = shown.contains(target);
                view.update(cx, |view, cx| view.set_shown(visible, cx));
            }
        }
    }

    fn handle_lifecycle(
        &mut self,
        action: &TerminalLifecycleAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            TerminalLifecycleAction::Stop(target) => match self.contents.get(target) {
                Some(PaneContent::Terminal(view)) => view.update(cx, |view, cx| view.destroy(cx)),
                Some(PaneContent::Chat(view)) => view.update(cx, |view, cx| view.stop(window, cx)),
                _ => {}
            },
            TerminalLifecycleAction::Restart(target) => {
                let Some(tab) = self.workspace.read(cx).tab(&target.pane_id, &target.tab_id).cloned() else {
                    return;
                };
                match self.contents.get(target).cloned() {
                    Some(PaneContent::Chat(view)) => {
                        let conversation =
                            tab.agent.as_ref().and_then(|a| a.conversation.as_ref()).map(|c| c.id.clone());
                        view.update(cx, |view, cx| view.restart(conversation.as_deref(), window, cx));
                    }
                    Some(PaneContent::Terminal(view)) => {
                        let launch = self.launch_for(&tab, &target.pane_id);
                        if self.terminals.restart(&view, launch, cx) {
                            self.schedule_readiness(target, cx);
                        }
                    }
                    Some(_) => {
                        // A stopped placeholder (or a failed start) becomes a live terminal.
                        self.remove_content(target, cx);
                        self.ensure_content(&tab, &target.pane_id, Some(true), window, cx);
                    }
                    None => {
                        self.ensure_content(&tab, &target.pane_id, None, window, cx);
                    }
                }
            }
        }
    }

    /// Creates the content of every pane in the active layout that lacks it (each pane's
    /// active tab).
    fn sync_visible_contents(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let wanted: Vec<(PaneTab, String)> = {
            let workspace = self.workspace.read(cx);
            let Some(layout) = workspace.layout() else { return };
            layout
                .leaf_ids()
                .into_iter()
                .filter_map(|pane_id| {
                    let tab = workspace.pane(&pane_id)?.active_tab()?.clone();
                    Some((tab, pane_id))
                })
                .collect()
        };
        for (tab, pane_id) in wanted {
            self.ensure_content(&tab, &pane_id, None, window, cx);
        }
    }

    fn prune_orphans(&mut self, cx: &mut Context<Self>) {
        let live: HashSet<TerminalTarget> = {
            let workspace = self.workspace.read(cx);
            workspace
                .panes()
                .values()
                .flat_map(|pane| pane.tabs.iter().map(|tab| TerminalTarget::new(&pane.id, &tab.id)))
                .collect()
        };
        let orphans: Vec<TerminalTarget> =
            self.contents.keys().filter(|target| !live.contains(*target)).cloned().collect();
        for target in orphans {
            self.remove_content(&target, cx);
        }
    }

    fn invalidate_all(&mut self, cx: &mut Context<Self>) {
        let targets: Vec<TerminalTarget> = self.contents.keys().cloned().collect();
        for target in targets {
            self.remove_content(&target, cx);
        }
    }

    fn remove_content(&mut self, target: &TerminalTarget, cx: &mut Context<Self>) {
        self.subscriptions.remove(target);
        match self.contents.remove(target) {
            Some(PaneContent::Terminal(view)) => view.update(cx, |view, cx| view.destroy(cx)),
            Some(PaneContent::Chat(view)) => view.update(cx, |view, cx| view.close(cx)),
            _ => {}
        }
        if self.copy_mode_target.as_ref() == Some(target) {
            self.copy_mode_target = None;
            cx.emit(ContentEvent::CopyModeChanged(KeybindingState::Normal));
        }
    }

    // MARK: - Creating content

    /// The content of `tab`, created when missing. `starts` overrides whether an agent tab
    /// starts its process (`None`: unless its agent is stopped).
    pub fn ensure_content(
        &mut self,
        tab: &PaneTab,
        pane_id: &str,
        starts: Option<bool>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> PaneContent {
        let target = TerminalTarget::new(pane_id, &tab.id);
        if let Some(existing) = self.contents.get(&target) {
            return existing.clone();
        }
        let content = match tab.pane_type {
            PaneType::Browser if tab.is_editor() || tab.is_diff() || tab.is_markdown() => {
                self.make_file_view(tab, &target, window, cx)
            }
            PaneType::Browser => self.make_browser(tab, &target, window, cx),
            PaneType::Agent if tab.is_chat() => match self.make_chat(tab, &target, window, cx) {
                Some(chat) => chat,
                None => self.make_terminal(tab, &target, window, cx),
            },
            PaneType::Terminal | PaneType::Agent => {
                let starts = starts.unwrap_or(
                    tab.pane_type != PaneType::Agent
                        || tab.agent.as_ref().map(|a| a.status) != Some(AgentStatus::Stopped),
                );
                if starts { self.make_terminal(tab, &target, window, cx) } else { PaneContent::Stopped }
            }
        };
        self.contents.insert(target.clone(), content.clone());
        if matches!(content, PaneContent::Terminal(_)) {
            self.schedule_readiness(&target, cx);
        }
        content
    }

    /// An editor, diff or Markdown reader for a file tab.
    fn make_file_view(
        &mut self,
        tab: &PaneTab,
        target: &TerminalTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> PaneContent {
        let Some(path) = tab.url.as_deref().and_then(file_url::path_from_file_url) else {
            return PaneContent::Failed("This tab's file could not be found.".into());
        };
        let workspace = self.workspace.clone();
        let events_target = target.clone();
        let (content, subscription) = if tab.is_editor() {
            let documents = self.documents.clone();
            let view_target = target.clone();
            let view = cx.new(|cx| EditorView::new(documents, view_target, path, window, cx));
            let subscription = cx.subscribe(&view, move |host, _, event: &EditorEvent, cx| {
                host.handle_editor_event(&events_target, event, cx)
            });
            (PaneContent::Editor(view), subscription)
        } else if tab.is_diff() {
            let staged = tab.content_kind.as_deref() == Some(soprano_model::PaneContentKind::STAGED_DIFF);
            let state = self.state.clone();
            let view = cx.new(|cx| DiffView::new(path, staged, state, window, cx));
            let subscription = cx.subscribe(&view, move |host, _, event: &DiffEvent, cx| match event {
                DiffEvent::OpenFile(path) => {
                    let opened = workspace.update(cx, |ws| ws.open_editor(path, false, None));
                    if opened.is_none() {
                        cx.emit(ContentEvent::ShowError(soprano_explorer::NO_ROOM_MESSAGE.to_owned()));
                    }
                }
                DiffEvent::FocusRequested => host.focus_tab(&events_target, cx),
            });
            (PaneContent::Diff(view), subscription)
        } else {
            let view = cx.new(|cx| MarkdownReaderView::new(&path, window, cx));
            let subscription = cx.subscribe(&view, move |host, _, event: &ReaderEvent, cx| {
                let (pane, tab) = (events_target.pane_id.as_str(), events_target.tab_id.as_str());
                match event {
                    ReaderEvent::TitleChanged(title) => {
                        workspace.update(cx, |ws| ws.rename_tab(pane, tab, title))
                    }
                    ReaderEvent::DocumentChanged(path) => {
                        workspace.update(cx, |ws| ws.update_file_document(pane, tab, path))
                    }
                    ReaderEvent::OpenExternal(url) => open_external(&workspace, url, cx),
                    ReaderEvent::FocusRequested => host.focus_tab(&events_target, cx),
                }
            });
            (PaneContent::Reader(view), subscription)
        };
        self.subscriptions.insert(target.clone(), subscription);
        content
    }

    /// What an editor tab reports (`EditorPaneView`'s delegate).
    fn handle_editor_event(&mut self, target: &TerminalTarget, event: &EditorEvent, cx: &mut Context<Self>) {
        let (pane, tab) = (target.pane_id.as_str(), target.tab_id.as_str());
        match event {
            EditorEvent::TitleChanged(title) => {
                self.workspace.update(cx, |ws| ws.rename_tab(pane, tab, title))
            }
            EditorEvent::ModifiedChanged(_) | EditorEvent::Saved => self.refresh_unsaved(cx),
            EditorEvent::KeepTab => self.workspace.update(cx, |ws| ws.keep_editor_tab(pane, tab)),
            EditorEvent::OpenMarkdownPreview(path) => {
                self.workspace.update(cx, |ws| preview_markdown_in_file_pane(ws, path));
            }
            EditorEvent::FocusRequested => self.focus_tab(target, cx),
        }
    }

    fn focus_tab(&self, target: &TerminalTarget, cx: &mut Context<Self>) {
        self.workspace.update(cx, |ws| ws.focus_tab(&target.pane_id, &target.tab_id, false));
    }

    fn make_browser(
        &mut self,
        tab: &PaneTab,
        target: &TerminalTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> PaneContent {
        let browser_target = TerminalTarget::new(&target.pane_id, &target.tab_id);
        let url = tab.url.clone();
        let view = cx.new(|cx| BrowserView::new(browser_target, url.as_deref(), window, cx));
        let workspace = self.workspace.clone();
        let target_for_events = target.clone();
        let subscription = cx.subscribe(&view, move |_, _, event: &BrowserEvent, cx| {
            let target = &target_for_events;
            match event {
                BrowserEvent::UrlChanged(url) => {
                    workspace.update(cx, |ws| ws.update_browser_url(&target.pane_id, &target.tab_id, url))
                }
                BrowserEvent::TitleChanged(title) => {
                    workspace.update(cx, |ws| ws.rename_tab(&target.pane_id, &target.tab_id, title))
                }
                BrowserEvent::FocusRequested => {
                    workspace.update(cx, |ws| ws.focus_tab(&target.pane_id, &target.tab_id, false))
                }
                BrowserEvent::LoadingChanged(_) => {}
            }
        });
        self.subscriptions.insert(target.clone(), subscription);
        PaneContent::Browser(view)
    }

    /// A chat tab's view and the session running its agent (`makeChatView`): starts the agent
    /// on the tab's conversation unless the tab was stopped; `None` when the agent has no chat,
    /// so the tab opens as a terminal instead.
    fn make_chat(
        &mut self,
        tab: &PaneTab,
        target: &TerminalTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<PaneContent> {
        let agent = tab.agent.as_ref()?;
        let profile = AgentCatalog::shared().profile(&agent.profile_id)?;
        let cwd = agent.conversation.as_ref().and_then(|c| c.cwd.clone()).or_else(|| tab.cwd.clone());
        let adjustments = AccountLaunchState::shared().adjustments(&profile.id);
        let accounts =
            AccountAdjustments { environment: adjustments.environment, arguments: adjustments.arguments };
        let ctx = &self.launch_context;
        let launch = soprano_launch::ChatLaunch::for_profile(
            &profile,
            cwd.as_deref(),
            &ctx.login_shell,
            &accounts,
            &ctx.base_env,
            &ctx.home,
        )?;
        let mut argv = vec![launch.shell.clone()];
        argv.extend(launch.arguments.iter().cloned());
        let spec = soprano_chat::session::LaunchSpec {
            argv,
            cwd: PathBuf::from(&launch.working_directory),
            env: launch.environment.clone().into_iter().collect(),
        };
        let chat_launch = soprano_chat::session::AgentChatLaunch::new(&profile, spec)?;
        let session = soprano_chat::session::AgentChatSession::new(chat_launch);
        let agent_name = profile.name.clone();
        let view = cx.new(|cx| ChatView::new(session, agent_name.clone(), window, cx));
        let target_for_events = target.clone();
        let subscription = cx.subscribe(&view, move |host, _, event: &ChatViewEvent, cx| {
            host.handle_chat_event(&target_for_events, &agent_name, event, cx);
        });
        self.subscriptions.insert(target.clone(), subscription);
        if agent.status != AgentStatus::Stopped {
            let resume = agent.conversation.as_ref().map(|c| c.id.clone());
            view.update(cx, |view, cx| view.start(resume.as_deref(), window, cx));
        }
        Some(PaneContent::Chat(view))
    }

    /// What a chat session reports turns into the tab's status, conversation and title
    /// (`handleChatEvent`).
    fn handle_chat_event(
        &mut self,
        target: &TerminalTarget,
        agent_name: &str,
        event: &ChatViewEvent,
        cx: &mut Context<Self>,
    ) {
        let (pane, tab) = (target.pane_id.as_str(), target.tab_id.as_str());
        match event {
            ChatViewEvent::Agent(AgentChatEvent::Status { status, waiting_reason, notify, message }) => {
                let state = match status {
                    AgentStatus::Idle => AgentEventState::Ready,
                    AgentStatus::Running => AgentEventState::Running,
                    AgentStatus::Waiting => AgentEventState::NeedsInput,
                    AgentStatus::Error => AgentEventState::Error,
                    // Hooks never report these; a stop must not turn the tab into a terminal
                    // the way a hook's stop does.
                    AgentStatus::Starting | AgentStatus::Stopped => {
                        let status = *status;
                        self.workspace
                            .update(cx, |ws| ws.update_agent_status(pane, tab, status, Some(false), None));
                        return;
                    }
                };
                cx.emit(ContentEvent::AgentEvent(soprano_ipc::AgentEvent {
                    pane_id: pane.to_owned(),
                    tab_id: tab.to_owned(),
                    state,
                    notify: *notify,
                    title: agent_name.to_owned(),
                    body: message.clone().unwrap_or_default(),
                    profile_id: None,
                    process_id: None,
                    message: message.clone(),
                    reason: *waiting_reason,
                    conversation: None,
                }));
            }
            ChatViewEvent::Agent(AgentChatEvent::Conversation { id, cwd }) => {
                let mut conversation = AgentConversation::new(id.clone());
                conversation.cwd = Some(cwd.clone());
                self.workspace.update(cx, |ws| ws.record_agent_conversation(conversation, pane, tab, None));
            }
            ChatViewEvent::Agent(AgentChatEvent::Title(title)) => {
                self.workspace.update(cx, |ws| ws.rename_tab(pane, tab, title))
            }
            ChatViewEvent::FocusRequested => self.workspace.update(cx, |ws| ws.focus_tab(pane, tab, false)),
            ChatViewEvent::RestartRequested => self.workspace.update(cx, |ws| ws.restart_agent(target)),
        }
    }

    fn make_terminal(
        &mut self,
        tab: &PaneTab,
        target: &TerminalTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> PaneContent {
        let launch = self.launch_for(tab, &target.pane_id);
        match self.terminals.create(launch, self.terminal_settings.clone(), window, cx) {
            Ok(view) => {
                if let Some(coordinator) = self.clipboard.clone() {
                    view.update(cx, |view, _| view.set_clipboard_coordinator(Some(coordinator)));
                }
                let target_for_events = target.clone();
                let subscription = cx.subscribe(&view, move |host, view, event: &TerminalEvent, cx| {
                    host.handle_terminal_event(&target_for_events, view, event, cx);
                });
                self.subscriptions.insert(target.clone(), subscription);
                PaneContent::Terminal(view)
            }
            Err(error) => {
                tracing::error!(
                    "cannot start the terminal of {}/{}: {error:#}",
                    target.pane_id,
                    target.tab_id
                );
                PaneContent::Failed(format!("The terminal could not start: {error}").into())
            }
        }
    }

    /// How `tab`'s process starts (Swift `terminalConfig(for:paneId:)`).
    pub fn launch_for(&self, tab: &PaneTab, pane_id: &str) -> TerminalLaunch {
        terminal_launch(&launch_spec(&self.launch_context, tab, pane_id))
    }

    fn schedule_readiness(&mut self, target: &TerminalTarget, cx: &mut Context<Self>) {
        let Some(generation) = self.workspace.update(cx, |ws| ws.begin_agent_readiness_generation(target))
        else {
            return;
        };
        let workspace = self.workspace.clone();
        cx.spawn(async move |_, cx| {
            cx.background_executor().timer(CODEX_READINESS_DELAY).await;
            cx.update(|cx| workspace.update(cx, |ws| ws.mark_agent_ready_if_starting(&generation)));
        })
        .detach();
    }

    // MARK: - Terminal reports

    fn handle_terminal_event(
        &mut self,
        target: &TerminalTarget,
        view: Entity<TerminalView>,
        event: &TerminalEvent,
        cx: &mut Context<Self>,
    ) {
        let (pane, tab) = (target.pane_id.as_str(), target.tab_id.as_str());
        match event {
            TerminalEvent::TitleChanged(title) => {
                self.workspace.update(cx, |ws| ws.rename_tab(pane, tab, title))
            }
            TerminalEvent::WorkingDirectoryChanged(path) => {
                self.workspace.update(cx, |ws| ws.update_working_directory(pane, tab, path))
            }
            TerminalEvent::DesktopNotification { title, body } => {
                cx.emit(ContentEvent::DesktopNotification {
                    target: target.clone(),
                    title: title.clone(),
                    body: body.clone(),
                })
            }
            TerminalEvent::Bell => {}
            TerminalEvent::CommandFinished { exit_code } => {
                let exit_code = *exit_code;
                self.workspace.update(cx, |ws| {
                    let mut targets = ws.running_command_targets().clone();
                    targets.remove(target);
                    ws.set_running_command_targets(targets);
                    ws.agent_command_did_finish(target, exit_code);
                });
            }
            TerminalEvent::RunningCommandChanged(_) => self.sample_running_commands(cx),
            TerminalEvent::ChildExited { exit_code } => {
                let exit_code = *exit_code;
                self.workspace.update(cx, |ws| ws.agent_process_did_exit(target, exit_code));
            }
            TerminalEvent::CloseRequested => dispatch(
                &self.shell,
                Command::Close(CloseTarget::TerminalClosed {
                    pane_id: pane.to_owned(),
                    tab_id: tab.to_owned(),
                }),
                cx,
            ),
            TerminalEvent::ClipboardConfirmationRequested(request) => {
                cx.emit(ContentEvent::ClipboardConfirmation { terminal: view, request: request.clone() })
            }
            TerminalEvent::AgentInputSubmitted => self.workspace.update(cx, |ws| {
                if ws.agent(pane, tab).is_some() {
                    ws.update_agent_status(pane, tab, AgentStatus::Running, Some(false), None);
                }
            }),
            TerminalEvent::CopyModeStateChanged(state) => {
                match state {
                    KeybindingState::Copy | KeybindingState::CopySelection => {
                        self.copy_mode_target = Some(target.clone())
                    }
                    KeybindingState::Normal => {
                        if self.copy_mode_target.as_ref() != Some(target) {
                            return;
                        }
                        self.copy_mode_target = None;
                    }
                    KeybindingState::Prefix => {}
                }
                cx.emit(ContentEvent::CopyModeChanged(*state));
            }
            TerminalEvent::FocusRequested => self.workspace.update(cx, |ws| ws.focus_tab(pane, tab, false)),
            TerminalEvent::Focused => cx.emit(ContentEvent::SurfaceFocused(target.clone())),
            TerminalEvent::Destroyed => cx.emit(ContentEvent::TerminalDestroyed(view.entity_id().as_u64())),
            TerminalEvent::ClipboardWrite { .. } | TerminalEvent::ClipboardReadRequested(_) => {}
        }
    }

    /// Publishes which terminals, in every window, are running a command.
    pub fn sample_running_commands(&mut self, cx: &mut Context<Self>) {
        let running: HashSet<TerminalTarget> = self
            .contents
            .iter()
            .filter_map(|(target, content)| match content {
                PaneContent::Terminal(view) if view.read(cx).is_running_command() => Some(target.clone()),
                _ => None,
            })
            .collect();
        self.workspace.update(cx, |ws| ws.set_running_command_targets(running));
    }

    /// A pane change moved focus away from the terminal in copy mode: copy mode ends.
    fn cancel_copy_mode_outside_active_terminal(&mut self, cx: &mut Context<Self>) {
        let Some(copy_target) = self.copy_mode_target.clone() else { return };
        let active = {
            let workspace = self.workspace.read(cx);
            let pane_id = workspace.active_pane_id();
            workspace
                .pane(pane_id)
                .and_then(|p| p.active_tab())
                .map(|tab| TerminalTarget::new(pane_id, &tab.id))
        };
        if active.as_ref() == Some(&copy_target) {
            return;
        }
        if let Some(PaneContent::Terminal(view)) = self.contents.get(&copy_target) {
            view.update(cx, |view, cx| view.cancel_copy_mode(cx));
            return;
        }
        self.copy_mode_target = None;
        cx.emit(ContentEvent::CopyModeChanged(KeybindingState::Normal));
    }

    // MARK: - Host queries (dashboard, automations)

    /// Starts the agent of a tab in a window nobody is looking at (an automation's run).
    pub fn start_background_terminal(
        &mut self,
        target: &TerminalTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(tab) = self.workspace.read(cx).tab(&target.pane_id, &target.tab_id).cloned() else {
            return false;
        };
        if tab.pane_type != PaneType::Agent || tab.is_chat() {
            return false;
        }
        match self.contents.get(target).cloned() {
            Some(PaneContent::Terminal(view)) if !view.read(cx).has_exited() => true,
            Some(PaneContent::Terminal(view)) => {
                let launch = self.launch_for(&tab, &target.pane_id);
                let started = self.terminals.restart(&view, launch, cx);
                if started {
                    self.schedule_readiness(target, cx);
                }
                started
            }
            Some(_) => {
                self.remove_content(target, cx);
                matches!(
                    self.ensure_content(&tab, &target.pane_id, Some(true), window, cx),
                    PaneContent::Terminal(_)
                )
            }
            None => matches!(
                self.ensure_content(&tab, &target.pane_id, Some(true), window, cx),
                PaneContent::Terminal(_)
            ),
        }
    }

    /// The text a live terminal shows.
    pub fn visible_terminal_text(&self, target: &TerminalTarget, cx: &App) -> Option<String> {
        match self.contents.get(target)? {
            PaneContent::Terminal(view) if !view.read(cx).has_exited() => view.read(cx).visible_text(),
            _ => None,
        }
    }

    /// What the Agent Dashboard shows for `target`: a live terminal's text, or an empty text
    /// for a running chat tab (its transcript lives in the chat), so both count as available.
    pub fn dashboard_text(&self, target: &TerminalTarget, cx: &App) -> Option<String> {
        match self.contents.get(target)? {
            PaneContent::Chat(view) if view.read(cx).session().borrow().is_running() => Some(String::new()),
            _ => self.visible_terminal_text(target, cx),
        }
    }

    /// A reply typed in the Agent Dashboard: a chat tab's prompt goes through its composer's
    /// submit, a terminal agent gets it typed in. False when it could not be sent.
    pub fn reply_to_agent(
        &mut self,
        prompt: &str,
        target: &TerminalTarget,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        match self.contents.get(target).cloned() {
            Some(PaneContent::Chat(view)) => {
                view.update(cx, |view, cx| view.submit_prompt(prompt, window, cx))
            }
            _ => self.submit_agent_prompt(prompt, target, cx),
        }
    }

    /// Types `prompt` into an agent's terminal and submits it; the agent turns running.
    pub fn submit_agent_prompt(
        &mut self,
        prompt: &str,
        target: &TerminalTarget,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(PaneContent::Terminal(view)) = self.contents.get(target).cloned() else { return false };
        if view.read(cx).has_exited() {
            return false;
        }
        if !view.update(cx, |view, cx| view.submit_text(prompt, cx)) {
            return false;
        }
        self.workspace.update(cx, |ws| {
            ws.update_agent_status(&target.pane_id, &target.tab_id, AgentStatus::Running, Some(false), None)
        });
        true
    }

    /// Drops `paths` onto the terminal of `target` as shell-escaped words.
    pub fn drop_paths(
        &mut self,
        target: &TerminalTarget,
        paths: Vec<PathBuf>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(PaneContent::Terminal(view)) = self.contents.get(target).cloned() {
            let payload = soprano_term::drop_content::DropPayload::files(paths);
            view.update(cx, |view, cx| view.drop_payload(&payload, window, cx));
        }
    }
}

/// The launch spec for a tab (`TerminalConfig.forCommand` / `.forAgent` / plain shell).
pub fn launch_spec(ctx: &LaunchContext, tab: &PaneTab, pane_id: &str) -> LaunchSpec {
    let cwd = tab.cwd.as_deref();
    if tab.pane_type == PaneType::Terminal
        && let Some(command) = &tab.startup_command
    {
        return LaunchSpec::for_command(ctx, command, cwd, pane_id, &tab.id);
    }
    if tab.pane_type == PaneType::Agent
        && let Some(agent) = &tab.agent
        && let Some(profile) = AgentCatalog::shared().profile(&agent.profile_id)
    {
        let adjustments = AccountLaunchState::shared().adjustments(&profile.id);
        let accounts =
            AccountAdjustments { environment: adjustments.environment, arguments: adjustments.arguments };
        let mut request = AgentRequest::new(&profile, pane_id, &tab.id);
        request.cwd = cwd;
        request.conversation = agent.conversation.as_ref();
        request.launch = agent.launch.as_ref();
        request.accounts = &accounts;
        return LaunchSpec::for_agent(ctx, &request);
    }
    LaunchSpec::default_shell(ctx, cwd, pane_id, &tab.id)
}

pub fn terminal_launch(spec: &LaunchSpec) -> TerminalLaunch {
    TerminalLaunch {
        argv: spec.argv.clone(),
        cwd: spec.cwd.clone(),
        env: spec.env.clone(),
        initial_input: spec.initial_input.clone(),
        wait_after_command: spec.wait_after_command,
    }
}

/// The terminal palette of a Soprano theme (ThemeManager → GhosttyAppManager glue).
pub fn terminal_theme(theme: &soprano_ui::theme::AppTheme) -> TerminalTheme {
    let colors = &theme.terminal;
    TerminalTheme {
        background: colors.background,
        foreground: colors.foreground,
        cursor: colors.cursor,
        cursor_text: colors.cursor_accent,
        selection_background: colors.selection_background,
        palette: colors.ansi,
    }
}

/// Shows `path` in the window's file pane's reusable reader, or a new reader pane when the
/// window has no file pane (the explorer's and the editor's Open Markdown Preview).
pub fn preview_markdown_in_file_pane(ws: &mut soprano_model::Workspace, path: &Path) {
    let window_id = ws.active_window_id().to_owned();
    match ws.file_pane(&window_id) {
        Some(pane) => {
            ws.preview_markdown(path, &pane);
        }
        None => {
            ws.spawn_markdown(path, None);
        }
    }
}

/// A reader's external link: web pages open in a browser pane, anything else (mailto) in
/// the system's handler.
fn open_external(workspace: &WorkspaceHandle, url: &str, cx: &mut App) {
    if url.starts_with("http://") || url.starts_with("https://") {
        workspace.update(cx, |ws| ws.spawn_browser(Some(url)));
    } else {
        cx.open_url(url);
    }
}

/// Whether two paths name the same file, compared the way the model compares tab files.
fn same_file(a: &Path, b: &Path) -> bool {
    file_url::comparable_path(a) == file_url::comparable_path(b)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    use gpui::TestAppContext;
    use soprano_config::{AppSettings, DefaultKeybindings};
    use soprano_launch::Resources;
    use soprano_model::Workspace;
    use soprano_platform::StateStore;
    use soprano_types::SplitDirection;

    use super::*;

    /// Never spawns a shell: records each start and fails it, so content stays `Failed`.
    #[derive(Default)]
    struct RecordingTerminals {
        created: RefCell<Vec<TerminalLaunch>>,
    }

    impl TerminalFactory for RecordingTerminals {
        fn create(
            &self,
            launch: TerminalLaunch,
            _: TerminalSettings,
            _: &mut Window,
            _: &mut App,
        ) -> anyhow::Result<Entity<TerminalView>> {
            self.created.borrow_mut().push(launch);
            anyhow::bail!("no shells in tests")
        }

        fn restart(&self, _: &Entity<TerminalView>, _: TerminalLaunch, _: &mut App) -> bool {
            false
        }
    }

    fn context() -> LaunchContext {
        LaunchContext {
            soprano_bin: "/Applications/Soprano.app/Contents/MacOS/Soprano".into(),
            app_pid: 42,
            socket: Some("/tmp/soprano-test.sock".into()),
            app_version: "0.6.0".into(),
            login_shell: "/bin/zsh".into(),
            resources: Resources::none(),
            base_env: BTreeMap::from([("PATH".to_owned(), "/usr/bin:/bin".to_owned())]),
            home: "/Users/test".into(),
            platform: soprano_launch::spec::Platform::Unix,
            shell_integration: soprano_launch::ShellIntegrationConfig::default(),
        }
    }

    fn host(
        workspace: Workspace,
        cx: &mut TestAppContext,
    ) -> (WorkspaceHandle, Entity<ContentHost>, Rc<RecordingTerminals>, &mut gpui::VisualTestContext) {
        let terminals = Rc::new(RecordingTerminals::default());
        let factory: Rc<dyn TerminalFactory> = terminals.clone();
        let cx = cx.add_empty_window();
        let (workspace, host) = cx.update(|window, cx| {
            let workspace = WorkspaceHandle::new(workspace, cx);
            let shell = cx.new(|_| {
                Shell::new(
                    StateStore::in_memory(),
                    AppSettings::default_settings(),
                    DefaultKeybindings::config(),
                )
            });
            let host = cx.new(|cx| {
                ContentHost::new(
                    workspace.clone(),
                    shell,
                    factory,
                    context(),
                    TerminalSettings::default(),
                    cx.new(|_| EditorDocuments::new()),
                    StateStore::in_memory(),
                    window,
                    cx,
                )
            });
            (workspace, host)
        });
        cx.run_until_parked();
        (workspace, host, terminals, cx)
    }

    fn active_target(workspace: &WorkspaceHandle, cx: &mut gpui::VisualTestContext) -> TerminalTarget {
        cx.update(|_, cx| {
            let ws = workspace.read(cx);
            let pane = ws.active_pane_id().to_owned();
            let tab = ws.pane(&pane).and_then(|p| p.active_tab()).map(|t| t.id.clone()).expect("tab");
            TerminalTarget::new(pane, tab)
        })
    }

    #[gpui::test]
    fn the_visible_panes_get_their_content_once(cx: &mut TestAppContext) {
        let (workspace, host, terminals, cx) = host(Workspace::new(), cx);
        let first = active_target(&workspace, cx);
        assert_eq!(terminals.created.borrow().len(), 1);
        cx.update(|_, cx| assert!(host.read(cx).content(&first).is_some()));

        cx.update(|_, cx| {
            workspace.update(cx, |ws| ws.split_pane(SplitDirection::Horizontal, &first.pane_id));
        });
        cx.run_until_parked();
        // The split started one new terminal; the first pane's content was kept.
        assert_eq!(terminals.created.borrow().len(), 2);
    }

    #[gpui::test]
    fn a_layout_change_never_recreates_a_terminal(cx: &mut TestAppContext) {
        let (workspace, _host, terminals, cx) = host(Workspace::new(), cx);
        let first = active_target(&workspace, cx);
        cx.update(|_, cx| {
            workspace.update(cx, |ws| ws.split_pane(SplitDirection::Vertical, &first.pane_id));
        });
        cx.run_until_parked();
        let started = terminals.created.borrow().len();
        cx.update(|_, cx| {
            workspace.update(cx, |ws| {
                ws.toggle_maximize();
                ws.toggle_maximize();
                ws.focus_pane(&first.pane_id);
                ws.create_layout_tab(None, None);
            })
        });
        cx.run_until_parked();
        // Only the new layout tab's pane started.
        assert_eq!(terminals.created.borrow().len(), started + 1);
        cx.update(|_, cx| workspace.update(cx, |ws| ws.activate_previous_layout_tab()));
        cx.run_until_parked();
        assert_eq!(terminals.created.borrow().len(), started + 1);
    }

    #[gpui::test]
    fn closing_a_tab_drops_its_content(cx: &mut TestAppContext) {
        let (workspace, host, _terminals, cx) = host(Workspace::new(), cx);
        let first = active_target(&workspace, cx);
        let second = cx.update(|_, cx| workspace.update(cx, |ws| ws.spawn_terminal(None))).expect("pane");
        cx.run_until_parked();
        let second_target = cx.update(|_, cx| {
            let tab = workspace.read(cx).pane(&second).and_then(|p| p.active_tab()).map(|t| t.id.clone());
            TerminalTarget::new(second.clone(), tab.expect("tab"))
        });
        cx.update(|_, cx| assert!(host.read(cx).content(&second_target).is_some()));
        cx.update(|_, cx| {
            workspace.update(cx, |ws| ws.close_pane(&second));
        });
        cx.run_until_parked();
        cx.update(|_, cx| {
            assert!(host.read(cx).content(&second_target).is_none());
            assert!(host.read(cx).content(&first).is_some());
        });
    }

    #[gpui::test]
    fn restoring_a_workspace_replaces_every_cached_content(cx: &mut TestAppContext) {
        let (workspace, host, terminals, cx) = host(Workspace::new(), cx);
        let first = active_target(&workspace, cx);
        let snapshot = cx.update(|_, cx| workspace.read(cx).snapshot_workspace());
        cx.update(|_, cx| {
            workspace.update(cx, |ws| ws.restore_workspace(snapshot));
        });
        cx.run_until_parked();
        // Same ids, new terminals: the restored tab started again.
        assert_eq!(terminals.created.borrow().len(), 2);
        cx.update(|_, cx| assert!(host.read(cx).content(&first).is_some()));
    }

    #[gpui::test]
    fn a_stopped_agent_tab_starts_no_process_until_restarted(cx: &mut TestAppContext) {
        let mut model = Workspace::new();
        let pane =
            model.spawn_agent(soprano_types::DefaultAgents::CLAUDE_CODE, None, false).expect("agent pane");
        let tab = model.pane(&pane).and_then(|p| p.active_tab()).map(|t| t.id.clone()).expect("tab");
        let target = TerminalTarget::new(&pane, &tab);
        model.stop_agent(&target);
        model.take_changes();
        model.take_events();
        let (workspace, host, terminals, cx) = host(model, cx);
        let started = terminals.created.borrow().len();
        cx.update(|_, cx| {
            assert!(!matches!(host.read(cx).content(&target), Some(PaneContent::Terminal(_))));
        });
        cx.update(|_, cx| workspace.update(cx, |ws| ws.restart_agent(&target)));
        cx.run_until_parked();
        assert_eq!(terminals.created.borrow().len(), started + 1);
        cx.update(|_, cx| assert!(matches!(host.read(cx).content(&target), Some(PaneContent::Failed(_)))));
    }

    fn editor_id(
        host: &Entity<ContentHost>,
        target: &TerminalTarget,
        cx: &mut gpui::VisualTestContext,
    ) -> DocumentId {
        cx.update(|_, cx| match host.read(cx).content(target) {
            Some(PaneContent::Editor(view)) => view.read(cx).document_id(),
            _ => panic!("no editor for {target:?}"),
        })
    }

    fn type_into(host: &Entity<ContentHost>, id: DocumentId, cx: &mut gpui::VisualTestContext) {
        cx.update(|_, cx| {
            let documents = host.read(cx).documents().clone();
            documents.update(cx, |documents, cx| {
                documents.update(id, cx, |document| document.replace(0..0, "edit "))
            });
        });
        cx.run_until_parked();
    }

    #[gpui::test]
    fn file_tabs_show_the_editor_the_diff_and_the_reader(cx: &mut TestAppContext) {
        cx.update(gpui_component::init);
        let folder = tempfile::tempdir().expect("folder");
        let code = folder.path().join("main.rs");
        let notes = folder.path().join("notes.md");
        std::fs::write(&code, "fn main() {}\n").expect("write");
        std::fs::write(&notes, "# Notes\n").expect("write");
        let mut model = Workspace::new();
        let editor = model.open_editor(&code, false, None).expect("editor");
        let diff = model.open_diff(&code, false, false, None).expect("diff");
        let reader = model.open_markdown(&notes, &editor.pane_id).expect("reader");
        model.take_changes();
        model.take_events();
        let (workspace, host, _, cx) = host(model, cx);
        for target in [&editor, &diff] {
            cx.update(|_, cx| {
                workspace.update(cx, |ws| ws.focus_tab(&target.pane_id, &target.tab_id, false))
            });
            cx.run_until_parked();
        }
        cx.update(|_, cx| workspace.update(cx, |ws| ws.focus_tab(&reader.pane_id, &reader.tab_id, false)));
        cx.run_until_parked();
        cx.update(|_, cx| {
            let host = host.read(cx);
            assert!(matches!(host.content(&editor), Some(PaneContent::Editor(_))));
            assert!(matches!(host.content(&diff), Some(PaneContent::Diff(_))));
            assert!(matches!(host.content(&reader), Some(PaneContent::Reader(_))));
        });
    }

    #[gpui::test]
    fn closing_the_only_tab_of_an_unsaved_file_asks_first(cx: &mut TestAppContext) {
        cx.update(gpui_component::init);
        let folder = tempfile::tempdir().expect("folder");
        let code = folder.path().join("main.rs");
        std::fs::write(&code, "fn main() {}\n").expect("write");
        let mut model = Workspace::new();
        let editor = model.open_editor(&code, false, None).expect("editor");
        model.take_changes();
        model.take_events();
        let (workspace, host, _, cx) = host(model, cx);
        let id = editor_id(&host, &editor, cx);
        type_into(&host, id, cx);
        let outcome = cx.update(|_, cx| {
            workspace.update(cx, |ws| ws.remove_tab_from_pane(&editor.pane_id, &editor.tab_id))
        });
        assert!(matches!(outcome, soprano_model::CloseOutcome::NeedsConfirmation { .. }));
        // Don't Save: the document drops its changes and the close goes through.
        cx.update(|_, cx| {
            let documents = host.read(cx).documents().clone();
            let unsaved = documents.read(cx).store().unsaved_when_closing(std::slice::from_ref(&editor));
            assert_eq!(unsaved, vec![id]);
            documents.update(cx, |documents, cx| {
                documents.resolve_unsaved(&unsaved, soprano_text::editor_store::SaveChoice::Discard, cx)
            });
        });
        cx.run_until_parked();
        let outcome = cx.update(|_, cx| {
            workspace.update(cx, |ws| ws.remove_tab_from_pane(&editor.pane_id, &editor.tab_id))
        });
        assert!(!matches!(outcome, soprano_model::CloseOutcome::NeedsConfirmation { .. }));
    }

    #[test]
    fn a_file_another_tab_still_shows_closes_without_asking() {
        let (first, second) =
            (TerminalTarget::new("pane-1", "tab-1"), TerminalTarget::new("pane-2", "tab-2"));
        let mut store: soprano_text::EditorDocumentStore<TerminalTarget, u8> =
            soprano_text::EditorDocumentStore::new();
        let id = store.open("/tmp/never-read.rs");
        let unsaved =
            UnsavedEditors::new(vec![(first.clone(), id), (second.clone(), id)], HashSet::from([id]));
        assert!(!unsaved.loses_changes(std::slice::from_ref(&first)));
        assert!(unsaved.loses_changes(&[first.clone(), second.clone()]));
        let clean = UnsavedEditors::new(vec![(first.clone(), id)], HashSet::new());
        assert!(!clean.loses_changes(&[first]));
    }

    #[test]
    fn terminals_start_the_login_shell_in_their_folder() {
        let mut workspace = Workspace::new();
        let pane = workspace.spawn_terminal(Some("/tmp")).expect("pane");
        let tab = workspace.pane(&pane).and_then(|p| p.active_tab()).cloned().expect("tab");
        let spec = launch_spec(&context(), &tab, &pane);
        assert_eq!(spec.argv.first().map(String::as_str), Some("/bin/zsh"));
        assert_eq!(spec.cwd.as_deref(), Some(std::path::Path::new("/tmp")));
        assert_eq!(spec.env.get("SOPRANO_PANE_ID").map(String::as_str), Some(pane.as_str()));
        assert_eq!(spec.env.get("SOPRANO_TAB_ID").map(String::as_str), Some(tab.id.as_str()));
        assert_eq!(spec.env.get("SOPRANO_SOCKET").map(String::as_str), Some("/tmp/soprano-test.sock"));
        let launch = terminal_launch(&spec);
        assert_eq!(launch.argv, spec.argv);
        assert_eq!(launch.env, spec.env);
    }

    #[test]
    fn agent_tabs_launch_their_agent_through_the_login_shell() {
        let mut workspace = Workspace::new();
        let pane = workspace.spawn_agent("codex", None, false).expect("pane");
        let tab = workspace.pane(&pane).and_then(|p| p.active_tab()).cloned().expect("tab");
        let spec = launch_spec(&context(), &tab, &pane);
        let script = spec.argv.last().cloned().unwrap_or_default();
        assert!(script.contains("'codex'"), "{script}");
        assert_eq!(spec.env.get("SOPRANO_AGENT_PROFILE").map(String::as_str), Some("codex"));
    }

    #[test]
    fn the_terminal_palette_follows_the_theme() {
        let theme = soprano_ui::theme::theme_for("nord", soprano_ui::Appearance::Dark);
        let palette = terminal_theme(theme);
        assert_eq!(palette.background, theme.terminal.background);
        assert_eq!(palette.palette, theme.terminal.ansi);
        assert_eq!(palette.cursor_text, theme.terminal.cursor_accent);
    }
}
