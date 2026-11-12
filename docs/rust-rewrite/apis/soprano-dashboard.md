# soprano-dashboard — API

`crates/soprano-dashboard` is the Agent Dashboard: every agent of the workspace as a thread, laid
out like Soprano Agents. The app shows it in an OS window of its own (`crates/soprano/src/agents_window.rs`);
the crate itself only needs a window with gpui-component's `Root`.

## Public API (`soprano_dashboard`)

**Constructor**
- `AgentDashboard::new(workspace: Entity<Workspace>, host: DashboardHost, window, cx) -> Self`
- It reads and observes the workspace entity and never changes it. It is `Render + Focusable + EventEmitter<DashboardEvent>`.
- Focus it when its window opens; dropping it stops following transcripts. Without any agent it opens on a new thread.

**Host** (`DashboardHost`, built with `new()` and the setters of the same names)
- `accepts_replies: Fn(&TerminalTarget, &App) -> bool`: whether that pane tab's agent takes a message now.
- `notable_branch: Fn(&str, &App) -> Option<String>`: a folder's branch when it is not the default.
- `projects: Fn(&App) -> Vec<ProjectChoice>`: the folders a new thread is offered.
- `thread_options: Fn(&TerminalTarget, &App) -> Vec<AgentChatConfigOption>`: the settings that pane tab's chat session offers now (model, thinking level); empty for an agent in its terminal. Read with `accepts_replies`.
- `draft_options: Fn(&str, Vec<(String, String)>, &mut App) -> Task<Vec<AgentChatConfigOption>>`: what a new thread of that agent would offer with those (option id, value) pairs applied, from a throwaway conversation; asked when a draft opens, changes its agent, or changes its model.
- `home: PathBuf` (where transcripts are read and what `~` folds), `state: StateStore` (the agent the last thread started with, `soprano-agents-thread-agent`, and each agent's model and thinking level, `soprano-agents-thread-options`), `leading_inset: f32` (what the window's own controls take at the top-left).

**Events** (`DashboardEvent`; the shell performs each one)
- `Open(target)`: show that pane tab in its window.
- `Stop(target)` / `Restart(target)`: `Workspace::stop_agent` / `restart_agent`.
- `Reply { target, text }`: send the trimmed text (line breaks kept) to that pane tab's agent; on failure call `reply_failed`.
- `NewThread { profile_id, cwd, prompt, options }`: `Workspace::open_thread` (omp as a chat tab, the others in their terminal), start it — a chat with `options` set before `prompt` goes out — then call `thread_opened(target)` or `thread_failed(message)`.
- `SetOption { target, id, value }`: set that option of the pane tab's chat session.
- `ChooseProject`: ask for any folder, then call `set_draft_project(path)`.
- `Close`: Esc on the inbox or ⌘W.

**Methods**: `refresh`, `perform(KeyAction, …)`, `new_thread`, `open_project_picker`, `open_agent_menu`, `open_model_picker`, `open_thinking_menu`, `pick_option(id, value)`, `toggle_fold(section)`, `set_search(query)`, `set_composer_text(text)`; reading: `list() -> &AgentList`, `timeline_view()`, `composer_text()`, `composer_hint() -> (String, is_error)`, `composer_options()`, `is_drafting()`, `draft_choice()`.

**Modules**
- `keys`: `KeyAction`, `KeyFocus { List, Composer, Search }`, `ScrollAmount`, `key_action(&Keystroke, KeyFocus)`.
- `state`: `DashboardEntry` (entry, waiting reason, project name, since when in its status), `AgentList` (sections, search, folds, selection, `rows() -> Vec<ListRow>`), `AgentChoice`, `ThreadOption` (model and thinking level: which option, its chip label, what a thread starts with, what each agent's last thread started with), `ProjectChoice`, `Controls`, the composer hint and empty-timeline rules.

## What it shows

- **Inbox** (256 px on `chrome`, at most 40 %): the brand band, a search field and New Thread, then threads under Needs you / Working / Ready / Stopped as "Title N ⌄" headers that fold. A card is the project's monogram and name with the status pill (or how long ago, for an idle thread), the title, and a third line with what the agent does right now, else its machine or branch. Stopped threads are folded away at first and take one line each. A search lists its matches as cards without headers.
- **Chat column**: a 52 px header (`project / title`, status pill, a location chip that opens the thread in its window, and the detailed work log, Restart, Stop and Open buttons); the conversation in soprano-chat-ui's `TimelineView` (Claude Code, Codex, OpenCode and omp transcripts, followed with `AgentTranscriptStore`); the floating composer (Return sends, ⇧Return adds a line) with the agent's name, a hint when nothing can be sent, and the round send button. There is no terminal view.
- **New thread**: the headline "What should we build in *project*?" (the project opens a picker), where the tab will go ("Opens as a tab of “window”" or "Opens in a new window"), and the composer with the agent chip (omp, and the agents that take a first message on their command line). The chat column is never empty: without a thread to show, a new one is drafted with the composer focused.
- **Model and thinking chips** beside the agent, for a thread whose agent runs as a chat (omp) and for its draft: the model opens a `Picker` of the agent's models grouped by provider, the level a menu above its chip. A draft's pick is kept in the draft (a model pick asks the host again, since it changes the levels) and goes out with `NewThread`; an open thread's goes out as `SetOption`, shows at once and is read back after 200 ms.
- **Keys** (a keystroke interceptor while focus is anywhere inside): J/K/↓/↑, Return/Space, Tab or R into the composer, Esc or ⇧Tab back out, `/` search, N or ⌘N new thread, ⇧⌘M model, ⇧⌘E thinking level, ⇧J/⇧K/PgDn/PgUp, `[` `]`, O, G, Esc on the inbox (a draft is given up first) or ⌘W to close.
- **Visual QA without a screen:** `cargo run -p soprano-dashboard --example dashboard_demo -- --snapshot /abs/dir [--size WxH] [--appearance dark|light] [--theme ID] [--agents N]` writes the dashboard's states as PNGs.
