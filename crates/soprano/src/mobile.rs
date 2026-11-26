//! Bridge between `soprano-mobile`'s loopback HTTP/WebSocket server and Soprano's GPUI
//! workspace, chat sessions, and terminal agents.

use std::collections::HashMap;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use gpui::{App, Entity, Hsla, Rgba, Window};
use soprano_agents::{
    AgentDashboardSection, AgentTimeline, AgentTranscriptSource, AgentTranscriptStore, ApprovalKind,
    ChatThread, DashboardEntryStatus,
};
use soprano_chat::ChatInteraction;
use soprano_mobile::{
    DEFAULT_TURN_LIMIT, MobileAction, MobileActionResponse, MobileAgentProfile, MobileApproval,
    MobileApprovalOption, MobileCommand, MobileConfigOption, MobileConfigOptionValue, MobileProject,
    MobileSnapshot, MobileTheme, MobileThreadDetail, MobileThreadSummary, MobileTurn, MobileTurnItem,
    items_from_turn_items, turns_from_chat_thread, user_input_from_request,
};
use soprano_model::{AgentDashboardEntry, Workspace};
use soprano_platform::AppIdentity;
use soprano_types::{AgentCatalog, AgentStatus, AgentWaitingReason, TerminalTarget};
use soprano_ui::{SopranoTheme, StatusClock};

use crate::agents_window;
use crate::content::{ContentHost, PaneContent};
use crate::services::Services;
use crate::shell::Shell;
use crate::workspace::WorkspaceHandle;

/// How long a transcript that was just followed may take to arrive before its thread stops
/// saying it is loading (a conversation without a transcript never produces one).
const TRANSCRIPT_GRACE: Duration = Duration::from_secs(3);
/// A followed transcript is kept this long after the last phone left its thread.
const FOLLOW_LINGER: Duration = Duration::from_secs(10);

/// `#rrggbb`, or `rgba(r, g, b, a)` for a translucent token (borders, hover).
fn css_color(color: Hsla) -> String {
    let rgba: Rgba = color.into();
    let byte = |value: f32| (value.clamp(0.0, 1.0) * 255.0).round() as u8;
    let (r, g, b) = (byte(rgba.r), byte(rgba.g), byte(rgba.b));
    if rgba.a >= 0.999 {
        format!("#{r:02x}{g:02x}{b:02x}")
    } else {
        format!("rgba({r}, {g}, {b}, {:.3})", rgba.a)
    }
}

/// Soprano's active theme as CSS colors for the mobile PWA.
fn mobile_theme(t: &SopranoTheme) -> MobileTheme {
    MobileTheme {
        dark: t.is_dark(),
        background: css_color(t.background),
        canvas: css_color(t.canvas),
        popover: css_color(t.popover),
        raised: css_color(t.raised),
        hover: css_color(t.hover),
        border: css_color(t.border),
        foreground: css_color(t.foreground),
        muted: css_color(t.muted),
        dim: css_color(t.dim),
        accent: css_color(t.accent),
        solid: css_color(t.solid),
        solid_foreground: css_color(t.solid_foreground),
        working: css_color(t.working),
        approval: css_color(t.approval),
        input: css_color(t.input_tone),
        failed: css_color(t.failed),
        done: css_color(t.done),
        diff_add: css_color(t.diff_add),
        diff_delete: css_color(t.diff_delete),
        diff_add_word: css_color(t.diff_add_word),
        diff_delete_word: css_color(t.diff_delete_word),
        diff_add_foreground: css_color(t.diff_add_foreground),
        diff_delete_foreground: css_color(t.diff_delete_foreground),
    }
}

/// Runs `f` with the app's [`StatusClock`], which is a global: it is taken out so `f` can read
/// the workspace alongside.
pub fn with_status_clock<R>(cx: &mut App, f: impl FnOnce(&mut StatusClock, &App) -> R) -> R {
    let mut clock = std::mem::take(cx.default_global::<StatusClock>());
    let result = f(&mut clock, cx);
    *cx.default_global::<StatusClock>() = clock;
    result
}

/// Builds the inbox snapshot for the mobile PWA from the current workspace.
pub fn build_snapshot(
    workspace: &Workspace,
    content: &ContentHost,
    services: &Services,
    theme: &SopranoTheme,
    clock: &mut StatusClock,
    cx: &App,
) -> MobileSnapshot {
    let mut raw_entries: Vec<(AgentDashboardSection, MobileThreadSummary)> = workspace
        .agent_dashboard_entries()
        .into_iter()
        .map(|entry| {
            let section = section_of(&entry);
            let summary = summarize_entry(entry, workspace, content, services, clock, cx);
            (section, summary)
        })
        .collect();

    // Sort by section urgency (NeedsYou -> Working -> Ready -> Stopped), keeping workspace order
    // within each section.
    raw_entries.sort_by_key(|(section, _)| match section {
        AgentDashboardSection::NeedsYou => 0u8,
        AgentDashboardSection::Working => 1,
        AgentDashboardSection::Ready => 2,
        AgentDashboardSection::Stopped => 3,
    });
    let threads = raw_entries.into_iter().map(|(_, s)| s).collect();

    let roots = services.config.settings().project_directories;
    let projects = agents_window::project_choices(workspace, &roots)
        .into_iter()
        .map(|choice| MobileProject {
            name: choice.name,
            display_path: soprano_platform::paths::abbreviate_home(std::path::Path::new(&choice.path)),
            path: choice.path,
        })
        .collect();

    let agents = AgentCatalog::shared()
        .all()
        .into_iter()
        .filter(|profile| profile.id != "terminal")
        .map(|profile| MobileAgentProfile { id: profile.id, name: profile.name })
        .collect();

    MobileSnapshot {
        host_name: AppIdentity::current().name,
        theme: mobile_theme(theme),
        threads,
        projects,
        agents,
    }
}

struct Followed {
    source: AgentTranscriptSource,
    since: Instant,
    last_wanted: Instant,
}

/// What the app keeps for the phones: the transcripts of terminal agents whose thread a phone
/// shows, read on [`AgentTranscriptStore`]'s worker instead of the UI thread, and the revision
/// each watched thread last had, so a thread is announced when it changed and only then.
#[derive(Default)]
pub struct MobileBridge {
    transcripts: Option<AgentTranscriptStore>,
    followed: HashMap<String, Followed>,
    revisions: HashMap<String, u64>,
}

impl MobileBridge {
    /// Drops everything kept for phones; none is connected.
    pub fn release(&mut self) {
        if self.transcripts.is_some() || !self.revisions.is_empty() {
            *self = Self::default();
        }
    }

    /// Once a second while a phone is connected: lets go of transcripts no phone shows any
    /// more, picks up what the others gained, and announces watched threads that changed.
    pub fn tick(
        &mut self,
        workspace: &Workspace,
        content: &ContentHost,
        services: &Services,
        clock: &mut StatusClock,
        cx: &App,
    ) {
        let watched = services.mobile.watched_threads();
        let now = Instant::now();
        let followed = self.followed.len();
        self.followed.retain(|thread_id, followed| {
            if watched.contains(thread_id) {
                followed.last_wanted = now;
            }
            now.duration_since(followed.last_wanted) < FOLLOW_LINGER
        });
        if self.followed.len() != followed {
            self.track();
        }
        if let Some(transcripts) = &self.transcripts {
            transcripts.refresh();
        }
        self.revisions.retain(|thread_id, _| watched.contains(thread_id));
        for thread_id in watched {
            // A thread that went away changes too: the phone's next request says it is gone.
            let revision = self
                .thread_detail(&thread_id, DEFAULT_TURN_LIMIT, workspace, content, services, clock, cx)
                .map_or(0, |detail| detail.revision());
            if self.revisions.insert(thread_id.clone(), revision).is_some_and(|known| known != revision) {
                services.mobile.notify_thread_updated(thread_id);
            }
        }
    }

    /// The timeline of `thread_id`'s transcript as far as the store's worker has read it, and
    /// whether a missing one may still be on its way.
    fn follow(&mut self, thread_id: &str, source: AgentTranscriptSource) -> (Option<AgentTimeline>, bool) {
        let now = Instant::now();
        match self.followed.get_mut(thread_id) {
            Some(followed) if followed.source == source => followed.last_wanted = now,
            _ => {
                self.followed.insert(thread_id.to_owned(), Followed { source, since: now, last_wanted: now });
                self.track();
            }
        }
        let timeline = self.transcripts.as_ref().and_then(|transcripts| transcripts.timeline(thread_id));
        let pending = self
            .followed
            .get(thread_id)
            .is_some_and(|followed| now.duration_since(followed.since) < TRANSCRIPT_GRACE);
        (timeline, pending)
    }

    /// Points the transcript store at the followed transcripts; without any, its threads stop.
    fn track(&mut self) {
        if self.followed.is_empty() {
            self.transcripts = None;
            return;
        }
        let transcripts = self
            .transcripts
            .get_or_insert_with(|| AgentTranscriptStore::with_home(soprano_platform::paths::home_dir()));
        transcripts.track(
            self.followed.iter().map(|(id, followed)| (id.clone(), followed.source.clone())).collect(),
        );
    }

    /// The conversation of one thread id (`"pane_id:tab_id"`): its newest `turn_limit` turns,
    /// all of them for 0.
    #[allow(clippy::too_many_arguments)]
    fn thread_detail(
        &mut self,
        thread_id: &str,
        turn_limit: usize,
        workspace: &Workspace,
        content: &ContentHost,
        services: &Services,
        clock: &mut StatusClock,
        cx: &App,
    ) -> Option<MobileThreadDetail> {
        let target = parse_thread_id(thread_id)?;
        let entry = workspace.agent_dashboard_entry(&target)?;
        let summary = summarize_entry(entry.clone(), workspace, content, services, clock, cx);
        let mut detail = MobileThreadDetail {
            summary,
            loading: false,
            preamble: Vec::new(),
            earlier_turns: 0,
            turns: Vec::new(),
            options: Vec::new(),
            pending_approval: None,
            pending_input: None,
            queued_prompts: Vec::new(),
        };

        if let Some(PaneContent::Chat(chat_view)) = content.content(&target) {
            let session_rc = chat_view.read(cx).session();
            let session = session_rc.borrow();
            let thread = session.thread();
            detail.preamble = items_from_turn_items(&thread.preamble);
            (detail.earlier_turns, detail.turns) = turns_from_chat_thread(&thread, turn_limit);
            detail.options = session
                .config_options()
                .iter()
                .map(|opt| MobileConfigOption {
                    id: opt.id.clone(),
                    name: opt.name.clone(),
                    current_value: opt.current_value.clone(),
                    values: opt
                        .values
                        .iter()
                        .map(|v| MobileConfigOptionValue { value: v.value.clone(), name: v.name.clone() })
                        .collect(),
                })
                .collect();
            match session.interaction() {
                Some(ChatInteraction::Permission(perm)) => {
                    detail.pending_approval = Some(MobileApproval {
                        title: perm.kind.title().to_owned(),
                        detail: perm.subject(),
                        is_command: perm.kind == ApprovalKind::Command,
                        reason: perm.reason().filter(|reason| !reason.trim().is_empty()),
                        options: perm
                            .options
                            .iter()
                            .map(|o| MobileApprovalOption {
                                id: o.id.clone(),
                                label: o.name.clone(),
                                kind: o.kind.clone(),
                            })
                            .collect(),
                    });
                }
                Some(ChatInteraction::Question(question)) => {
                    detail.pending_input =
                        Some(user_input_from_request(&question.user_input_request("question")));
                }
                None => {}
            }
            detail.queued_prompts = session.queued_prompts();
            return Some(detail);
        }

        // Terminal-hosted agent: its transcript when it writes one, else the visible terminal
        // text.
        if let Some(source) = AgentTranscriptSource::new(&entry.profile_id, entry.conversation.as_ref()) {
            match self.follow(thread_id, source) {
                (Some(timeline), _) => {
                    let thread = ChatThread::from_transcript(&timeline, entry.status == AgentStatus::Running);
                    detail.preamble = items_from_turn_items(&thread.preamble);
                    (detail.earlier_turns, detail.turns) = turns_from_chat_thread(&thread, turn_limit);
                }
                (None, pending) => detail.loading = pending,
            }
        }
        if detail.turns.is_empty()
            && !detail.loading
            && let Some(visible) = content.visible_terminal_text(&target, cx)
        {
            let trimmed = visible.trim();
            if !trimmed.is_empty() {
                detail.turns.push(MobileTurn {
                    id: "terminal-preview".into(),
                    user_text: String::new(),
                    status: "completed".into(),
                    failure_message: None,
                    started_at_ms: None,
                    completed_at_ms: None,
                    stopping: false,
                    items: vec![MobileTurnItem::Command {
                        id: "terminal-screen".into(),
                        status: "completed".into(),
                        command: format!("{} (terminal)", entry.profile_name),
                        output: trimmed.to_owned(),
                        exit_code: None,
                    }],
                });
            }
        }
        Some(detail)
    }
}

/// Executes one mobile command on Soprano's GPUI main thread and sends back the reply. True
/// when the command may have changed what the inbox shows.
#[allow(clippy::too_many_arguments)]
pub fn handle_command(
    command: MobileCommand,
    bridge: &mut MobileBridge,
    workspace: &WorkspaceHandle,
    content: &Entity<ContentHost>,
    shell: &Entity<Shell>,
    services: &Services,
    window: &mut Window,
    cx: &mut App,
) -> bool {
    let reads = matches!(command.action, MobileAction::GetThread { .. });
    let response = match command.action {
        MobileAction::GetThread { thread_id, turn_limit } => {
            let detail = with_status_clock(cx, |clock, cx| {
                let (ws, host) = (workspace.model.read(cx), content.read(cx));
                bridge.thread_detail(&thread_id, turn_limit, ws, host, services, clock, cx)
            });
            match detail {
                Some(detail) => {
                    let revision = detail.revision();
                    // What this phone shows now; `tick` announces the thread once it differs.
                    bridge.revisions.entry(thread_id.clone()).or_insert(revision);
                    MobileActionResponse::Thread { detail: Box::new(detail), revision }
                }
                None => MobileActionResponse::NotFound(format!("Thread {thread_id} no longer exists.")),
            }
        }
        MobileAction::Reply { thread_id, text } => match parse_thread_id(&thread_id) {
            Some(target) => {
                let sent = content.update(cx, |host, cx| host.reply_to_agent(&text, &target, window, cx));
                if sent {
                    services.mobile.notify_thread_updated(&thread_id);
                    MobileActionResponse::Ok
                } else {
                    MobileActionResponse::Error("That agent cannot accept a reply right now.".into())
                }
            }
            None => MobileActionResponse::NotFound("Invalid thread id.".into()),
        },
        MobileAction::Approve { thread_id, option_id } => match parse_thread_id(&thread_id) {
            Some(target) => {
                let chat = content.read(cx).content(&target).and_then(PaneContent::chat).cloned();
                match chat {
                    Some(chat_view) => {
                        chat_view.update(cx, |view, cx| {
                            view.session().borrow_mut().choose_permission_option(&option_id);
                            cx.notify();
                        });
                        services.mobile.notify_thread_updated(&thread_id);
                        MobileActionResponse::Ok
                    }
                    None => MobileActionResponse::Error("Approval is only available on chat tabs.".into()),
                }
            }
            None => MobileActionResponse::NotFound("Invalid thread id.".into()),
        },
        MobileAction::AnswerUserInput { thread_id, answers } => match parse_thread_id(&thread_id) {
            Some(target) => {
                let chat = content.read(cx).content(&target).and_then(PaneContent::chat).cloned();
                match chat {
                    Some(chat_view) => {
                        let answered = chat_view.update(cx, |view, cx| {
                            let session_rc = view.session();
                            let mut session = session_rc.borrow_mut();
                            let content_map = match session.interaction() {
                                Some(ChatInteraction::Question(q)) => Some(q.content(&answers)),
                                _ => None,
                            };
                            if let Some(map) = content_map {
                                session.answer_question(map);
                                cx.notify();
                                true
                            } else {
                                false
                            }
                        });
                        if answered {
                            services.mobile.notify_thread_updated(&thread_id);
                            MobileActionResponse::Ok
                        } else {
                            MobileActionResponse::Error("No pending question on this thread.".into())
                        }
                    }
                    None => MobileActionResponse::Error("User input is only available on chat tabs.".into()),
                }
            }
            None => MobileActionResponse::NotFound("Invalid thread id.".into()),
        },
        MobileAction::DeclineUserInput { thread_id } => match parse_thread_id(&thread_id) {
            Some(target) => {
                let chat = content.read(cx).content(&target).and_then(PaneContent::chat).cloned();
                match chat {
                    Some(chat_view) => {
                        chat_view.update(cx, |view, cx| {
                            view.session().borrow_mut().decline_question();
                            cx.notify();
                        });
                        services.mobile.notify_thread_updated(&thread_id);
                        MobileActionResponse::Ok
                    }
                    None => MobileActionResponse::Error("User input is only available on chat tabs.".into()),
                }
            }
            None => MobileActionResponse::NotFound("Invalid thread id.".into()),
        },
        MobileAction::Stop { thread_id } => match parse_thread_id(&thread_id) {
            Some(target) => {
                workspace.update(cx, |ws| ws.stop_agent(&target));
                services.mobile.notify_thread_updated(&thread_id);
                MobileActionResponse::Ok
            }
            None => MobileActionResponse::NotFound("Invalid thread id.".into()),
        },
        MobileAction::Restart { thread_id } => match parse_thread_id(&thread_id) {
            Some(target) => {
                workspace.update(cx, |ws| ws.restart_agent(&target));
                services.mobile.notify_thread_updated(&thread_id);
                MobileActionResponse::Ok
            }
            None => MobileActionResponse::NotFound("Invalid thread id.".into()),
        },
        MobileAction::Cancel { thread_id } => match parse_thread_id(&thread_id) {
            Some(target) => {
                let chat = content.read(cx).content(&target).and_then(PaneContent::chat).cloned();
                if let Some(chat_view) = chat {
                    chat_view.update(cx, |view, cx| {
                        view.session().borrow_mut().cancel();
                        cx.notify();
                    });
                } else {
                    workspace.update(cx, |ws| ws.stop_agent(&target));
                }
                services.mobile.notify_thread_updated(&thread_id);
                MobileActionResponse::Ok
            }
            None => MobileActionResponse::NotFound("Invalid thread id.".into()),
        },
        MobileAction::SetOption { thread_id, id, value } => match parse_thread_id(&thread_id) {
            Some(target) => {
                content.update(cx, |host, cx| host.set_chat_option(&target, &id, &value, window, cx));
                services.mobile.notify_thread_updated(&thread_id);
                MobileActionResponse::Ok
            }
            None => MobileActionResponse::NotFound("Invalid thread id.".into()),
        },
        MobileAction::NewThread { profile_id, cwd, prompt, options } => {
            let as_chat = profile_id == "omp" || shell.read(cx).launches_as_chat(&profile_id);
            let opened = workspace
                .update(cx, |ws| ws.open_thread_with_mode(&profile_id, &cwd, Some(&prompt), as_chat));
            match opened {
                Some(target) => {
                    let started = content
                        .update(cx, |host, cx| host.start_thread(&target, &prompt, options, window, cx));
                    if started {
                        MobileActionResponse::Created {
                            thread_id: format!("{}:{}", target.pane_id, target.tab_id),
                        }
                    } else {
                        MobileActionResponse::Error(
                            "The agent tab opened, but could not start with that prompt.".into(),
                        )
                    }
                }
                None => MobileActionResponse::Error(
                    "Could not open a new thread for that project and agent.".into(),
                ),
            }
        }
    };
    let _ = command.reply.try_send(response);
    !reads
}

fn parse_thread_id(id: &str) -> Option<TerminalTarget> {
    let (pane_id, tab_id) = id.split_once(':')?;
    if pane_id.is_empty() || tab_id.is_empty() {
        return None;
    }
    Some(TerminalTarget::new(pane_id, tab_id))
}

struct EntryStatus<'a>(&'a AgentDashboardEntry);

impl DashboardEntryStatus for EntryStatus<'_> {
    fn status(&self) -> AgentStatus {
        self.0.status
    }
    fn needs_attention(&self) -> bool {
        self.0.needs_attention
    }
}

fn section_of(entry: &AgentDashboardEntry) -> AgentDashboardSection {
    AgentDashboardSection::of(&EntryStatus(entry))
}

fn summarize_entry(
    entry: AgentDashboardEntry,
    workspace: &Workspace,
    content: &ContentHost,
    services: &Services,
    clock: &mut StatusClock,
    cx: &App,
) -> MobileThreadSummary {
    let target = entry.target();
    let agent = workspace.agent(&entry.pane_id, &entry.tab_id);
    let waiting_reason = agent.and_then(|agent| agent.waiting_reason).map(|reason| match reason {
        AgentWaitingReason::Approval => "approval".to_owned(),
        AgentWaitingReason::Question => "question".to_owned(),
        AgentWaitingReason::TurnEnded => "turn".to_owned(),
    });
    // The same clock as the desktop's pills, so "Working 2m" counts from the same moment.
    let since = agent.map_or(entry.started_at, |agent| {
        Some(clock.since(&agent.id, agent.status, agent.started_at, SystemTime::now()))
    });
    let since_ms = since
        .and_then(|since| since.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |elapsed| elapsed.as_millis() as i64);
    let section = match section_of(&entry) {
        AgentDashboardSection::NeedsYou => "needs_you",
        AgentDashboardSection::Working => "working",
        AgentDashboardSection::Ready => "ready",
        AgentDashboardSection::Stopped => "stopped",
    };
    let status = match entry.status {
        AgentStatus::Running => "running",
        AgentStatus::Starting => "starting",
        AgentStatus::Waiting => "waiting",
        AgentStatus::Error => "error",
        AgentStatus::Idle => "idle",
        AgentStatus::Stopped => "stopped",
    };
    let branch = entry.branch.clone().or_else(|| {
        if entry.machine.is_some() {
            return None;
        }
        entry.cwd.as_deref().and_then(|cwd| services.branches.notable_branch(cwd))
    });
    let project = entry
        .cwd
        .as_deref()
        .map(|cwd| {
            let root = Workspace::project_root(cwd);
            root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| cwd.to_owned())
        })
        .unwrap_or_else(|| entry.window_title.clone());
    // The Agent Dashboard's rules (`Controls`): a starting or stopped agent takes no message,
    // and only an agent's own tab is stopped or restarted.
    let accepts_replies = matches!(
        entry.status,
        AgentStatus::Running | AgentStatus::Idle | AgentStatus::Waiting | AgentStatus::Error
    ) && content.accepts_prompt(&target, cx);

    MobileThreadSummary {
        id: entry.id(),
        title: entry.title(),
        project,
        profile_id: entry.profile_id,
        profile_name: entry.profile_name,
        status: status.to_owned(),
        section: section.to_owned(),
        waiting_reason,
        needs_attention: entry.needs_attention,
        is_chat: entry.is_chat,
        accepts_replies,
        can_stop: entry.owns_tab && entry.status != AgentStatus::Stopped,
        can_restart: entry.owns_tab && entry.status != AgentStatus::Starting,
        branch,
        since_ms,
    }
}
