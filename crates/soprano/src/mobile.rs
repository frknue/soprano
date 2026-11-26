//! Bridge between `soprano-mobile`'s loopback HTTP/WebSocket server and Soprano's GPUI
//! workspace, chat sessions, and terminal agents.

use std::time::{SystemTime, UNIX_EPOCH};

use gpui::{App, Entity, Rgba, Window};
use soprano_agents::{AgentDashboardSection, AgentTranscriptSource, ChatThread, DashboardEntryStatus};
use soprano_chat::ChatInteraction;
use soprano_mobile::{
    MobileAction, MobileActionResponse, MobileAgentProfile, MobileApproval, MobileApprovalOption,
    MobileCommand, MobileConfigOption, MobileConfigOptionValue, MobileProject, MobileSnapshot, MobileTheme,
    MobileThreadDetail, MobileThreadSummary, MobileTurn, MobileTurnItem, turns_from_chat_thread,
    user_input_from_request,
};
use soprano_model::{AgentDashboardEntry, Workspace};
use soprano_platform::AppIdentity;
use soprano_types::{AgentCatalog, AgentStatus, AgentWaitingReason, TerminalTarget};
use soprano_ui::SopranoTheme;

use crate::agents_window;
use crate::content::{ContentHost, PaneContent};
use crate::services::Services;
use crate::shell::Shell;
use crate::workspace::WorkspaceHandle;

/// Converts Soprano's active GPUI theme into CSS hex strings for the mobile PWA.
pub fn mobile_theme(t: &SopranoTheme) -> MobileTheme {
    let hex = |color: gpui::Hsla| {
        let rgba: Rgba = color.into();
        format!(
            "#{:02x}{:02x}{:02x}",
            (rgba.r.clamp(0.0, 1.0) * 255.0).round() as u8,
            (rgba.g.clamp(0.0, 1.0) * 255.0).round() as u8,
            (rgba.b.clamp(0.0, 1.0) * 255.0).round() as u8,
        )
    };
    MobileTheme {
        canvas: hex(t.canvas),
        surface: hex(t.background),
        raised: hex(t.raised),
        hover: hex(t.hover),
        border: hex(t.border),
        foreground: hex(t.foreground),
        muted: hex(t.muted),
        dim: hex(t.dim),
        accent: hex(t.accent),
        working: hex(t.working),
        approval: hex(t.approval),
        input: hex(t.input),
        failed: hex(t.failed),
        done: hex(t.done),
    }
}

/// Builds a fresh inbox snapshot for the mobile PWA from the current workspace.
pub fn build_snapshot(
    workspace: &Workspace,
    content: &ContentHost,
    services: &Services,
    version: u64,
    theme: &SopranoTheme,
    cx: &App,
) -> MobileSnapshot {
    let mut raw_entries: Vec<(AgentDashboardSection, MobileThreadSummary)> = workspace
        .agent_dashboard_entries()
        .into_iter()
        .map(|entry| {
            let section = section_of(&entry);
            let summary = summarize_entry(entry, workspace, content, services, cx);
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
        version,
        host_name: AppIdentity::current().name,
        theme: mobile_theme(theme),
        threads,
        projects,
        agents,
    }
}

/// Builds the full conversation detail for one thread id (`"pane_id:tab_id"`).
pub fn build_thread_detail(
    thread_id: &str,
    workspace: &Workspace,
    content: &ContentHost,
    services: &Services,
    cx: &App,
) -> Option<MobileThreadDetail> {
    let target = parse_thread_id(thread_id)?;
    let entry = workspace.agent_dashboard_entry(&target)?;
    let summary = summarize_entry(entry.clone(), workspace, content, services, cx);

    if let Some(PaneContent::Chat(chat_view)) = content.content(&target) {
        let session_rc = chat_view.read(cx).session();
        let session = session_rc.borrow();
        let thread = session.thread();
        let turns = turns_from_chat_thread(&thread);
        let options = session
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
        let (pending_approval, pending_input) = match session.interaction() {
            Some(ChatInteraction::Permission(perm)) => {
                let detail = [Some(perm.subject()), perm.reason()]
                    .into_iter()
                    .flatten()
                    .filter(|s| !s.trim().is_empty())
                    .collect::<Vec<_>>()
                    .join("\n\n");
                let approval = MobileApproval {
                    id: "permission".into(),
                    title: perm.kind.title().to_owned(),
                    detail: (!detail.is_empty()).then_some(detail),
                    options: perm
                        .options
                        .iter()
                        .map(|o| MobileApprovalOption { id: o.id.clone(), label: o.name.clone() })
                        .collect(),
                };
                (Some(approval), None)
            }
            Some(ChatInteraction::Question(question)) => {
                let req = question.user_input_request("question");
                (None, Some(user_input_from_request(&req)))
            }
            None => (None, None),
        };
        let queued_prompts = session.queued_prompts();
        let phase = Some(format!("{:?}", session.phase()).to_lowercase());
        return Some(MobileThreadDetail {
            summary,
            turns,
            phase,
            options,
            pending_approval,
            pending_input,
            queued_prompts,
        });
    }

    // Terminal-hosted agent: read its transcript when available, else show the visible terminal
    // text as a clean fallback notice.
    let mut turns = Vec::new();
    if let Some(source) = AgentTranscriptSource::new(&entry.profile_id, entry.conversation.as_ref()) {
        let home = soprano_platform::paths::home_dir();
        let mut reader = source.make_reader(&home);
        if let Some(timeline) = reader.read_appended() {
            let thread = ChatThread::from_transcript(&timeline, entry.status == AgentStatus::Running);
            turns = turns_from_chat_thread(&thread);
        }
    }
    if turns.is_empty()
        && let Some(visible) = content.visible_terminal_text(&target, cx)
    {
        let trimmed = visible.trim();
        if !trimmed.is_empty() {
            turns.push(MobileTurn {
                id: "terminal-preview".into(),
                user_text: String::new(),
                items: vec![MobileTurnItem::Command {
                    id: "terminal-screen".into(),
                    status: "running".into(),
                    command: format!("{} (terminal output)", entry.profile_name),
                    output: trimmed.to_owned(),
                    exit_code: None,
                }],
            });
        }
    }

    Some(MobileThreadDetail {
        summary,
        turns,
        phase: None,
        options: Vec::new(),
        pending_approval: None,
        pending_input: None,
        queued_prompts: Vec::new(),
    })
}

/// Executes one mobile command on Soprano's GPUI main thread and sends back the reply.
#[allow(clippy::too_many_arguments)]
pub fn handle_command(
    command: MobileCommand,
    workspace: &WorkspaceHandle,
    content: &Entity<ContentHost>,
    shell: &Entity<Shell>,
    services: &Services,
    window: &mut Window,
    cx: &mut App,
) {
    let response = match command.action {
        MobileAction::GetThread { thread_id } => {
            let ws = workspace.model.read(cx);
            let host = content.read(cx);
            match build_thread_detail(&thread_id, ws, host, services, cx) {
                Some(detail) => MobileActionResponse::Thread(Box::new(detail)),
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
    cx: &App,
) -> MobileThreadSummary {
    let target = entry.target();
    let waiting_reason = workspace
        .tab(&entry.pane_id, &entry.tab_id)
        .and_then(|tab| tab.agent.as_ref().and_then(|agent| agent.waiting_reason))
        .map(|reason| match reason {
            AgentWaitingReason::Approval => "approval".to_owned(),
            AgentWaitingReason::Question => "question".to_owned(),
            AgentWaitingReason::TurnEnded => "turn".to_owned(),
        });
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
    let since_ms = entry
        .started_at
        .unwrap_or_else(SystemTime::now)
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let accepts_replies = content.accepts_prompt(&target, cx);

    MobileThreadSummary {
        id: entry.id(),
        pane_id: entry.pane_id.clone(),
        tab_id: entry.tab_id.clone(),
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
        branch,
        cwd: entry.cwd,
        session_name: entry.session_name,
        window_title: entry.window_title,
        since_ms,
    }
}
