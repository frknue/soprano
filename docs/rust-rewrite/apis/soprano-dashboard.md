# soprano-dashboard — API report from DashboardUi

I've built `crates/soprano-dashboard`: the Agent Dashboard page, the theme-aware rendering of agent terminal output, and the dashboard keyboard. `cargo test -p soprano-dashboard` passes (39 tests, three runs in a row), clippy with `--all-targets` has no warnings, fmt is clean and the `dashboard_demo` example builds. I didn't run the Linux/Windows cross-checks to completion: the Linux check fails because the bundled SQLite in soprano-agents won't compile without the `zig cc` wrappers that AccountsPort used, and I stopped before setting those up. I didn't launch any GUI and didn't change git state.

## Public API (`soprano_dashboard`)

**Constructor**
- `AgentDashboard::new(workspace: Entity<Workspace>, host: DashboardHost, window: &mut Window, cx: &mut Context<Self>) -> Self`
- It reads and observes the workspace entity and never changes it, as in your contract. It is `Render + Focusable + EventEmitter<DashboardEvent>`.
- The shell must focus it when it opens (`window.focus(&dashboard.focus_handle(cx), cx)`) and drop it when it closes. Dropping it stops following transcripts.

**Host**
- `DashboardHost { terminal_text: TerminalTextProvider, notable_branch: BranchProvider, home: PathBuf }`
- Builders: `DashboardHost::new()` / `Default`, `.terminal_text(Fn(&TerminalTarget, &App) -> Option<String>)` (`None` means the terminal isn't available), `.notable_branch(Fn(&str, &App) -> Option<String>)`, `.home(path)` (where transcripts are read and what `~` folds).
- `pub type TerminalTextProvider = Rc<dyn Fn(&TerminalTarget, &App) -> Option<String>>;` and `pub type BranchProvider = Rc<dyn Fn(&str, &App) -> Option<String>>;`

**Events** (`DashboardEvent`; the shell performs each one)
- `Open(TerminalTarget)`: call `focus_tab(pane, tab, true)` and close the dashboard.
- `Stop(TerminalTarget)`: call `Workspace::stop_agent`.
- `Restart(TerminalTarget)`: call `Workspace::restart_agent`.
- `Reply { target, text }`: the text is trimmed and single-line. Type it plus Return into that pane tab, or send it with `ChatView::submit_prompt` for a chat tab.
- `Close`: Esc or the close button; it doesn't change the active agent.

**Methods**
- `reply_failed(&mut self, &TerminalTarget, &str, window, cx)`: call this when a reply can't be delivered. It puts the draft back and shows "Could not send to this terminal." in the error color.
- Also public: `refresh`, `perform(KeyAction, …)`, `list() -> &AgentList`, `subtitle()`, `is_showing_terminal()`, `terminal_text() -> TerminalText`, `reply_input()`, `reply_hint()`, `activity_text()`, `timeline_view()`.

**Modules**
- `keys`: `KeyAction`, `ScrollAmount`, `key_action(&Keystroke, reply_focused)`.
- `state`: `DashboardEntry`, `AgentList`, `Controls`, `TerminalText`, `monitoring_subtitle`, `elapsed_text`, the reply-hint and fallback-activity rules.
- `text`: `OutputPalette::new(&SopranoTheme)`, `output_highlights(text, &palette)`.

**What it shows and does**
- **Surfaces:** the page is `canvas` with its header (title, "Monitoring N agents across M windows", `esc` and close) and the agent list straight on it; the selected agent is soprano-ui's `Card` (`background`, radius 10) 8 px from the page's edges, like a pane in the window. A dashboard without agents is one card saying so.
- **Agent list:** agents under Needs you / Working / Ready / Stopped with counts. A row is the agent's program icon (`agent_icon_stem`), its title and soprano-ui's `StatusPill`; under the title `agent · folder · ⎇ branch — activity` and how long it has run (nothing for a stopped agent). Idle and stopped agents are muted until selected. The selection is focused or unfocused depending on whether the list has the keyboard, and agents that need you get the attention tint. A key-hint footer closes the list. The list is 380 px wide, at most 40 % of the dashboard.
- **Detail card:** icon and title; under it the status pill, the runtime and the location line; the Timeline/Terminal switch in a well, Show/Hide details, and Open, Stop, Restart. The two toolbar groups wrap onto two lines when the card is too narrow for one.
- **Conversation:** Claude Code, Codex, OpenCode and omp agents show their transcript in soprano-chat-ui's `TimelineView`. Transcripts are followed with `AgentTranscriptStore`.
- **Live terminal:** plain terminals and custom agents show their text across the card in the theme's colors. You can select and copy it. While there is none, a centered note says why.
- **Composer:** the activity line, the reply field and the send button, with the hint under it. A field that cannot take a reply is dimmed.
- **Visual QA without a screen:** `cargo run -p soprano-dashboard --example dashboard_demo -- --snapshot /abs/dir [--size WxH] [--appearance dark|light] [--theme ID] [--agents N]` writes the dashboard's states (every agent, details, the terminal, the reply field) as PNGs, inside a mock of the app's frame.
- **Keys:** J/K/↓/↑, Return/Space, Tab or R into the reply, ⇧Tab back out keeping the draft, Esc, ⇧J/⇧K/PgDn/PgUp, `[` `]`, O, G, T. They run through a keystroke interceptor whenever focus is anywhere inside the dashboard, so clicking into the conversation or terminal text never swallows them. While the reply field has the keyboard, only Esc and ⇧Tab belong to the dashboard.

## Swift ported
- `Views/AgentDashboardViewController.swift`, plus the rendering half of `AgentOutputHighlighter.swift` (the highlighting rules live in soprano-text).
- **AgentDashboardViewTests:** I ported row naming and following renames/folder changes; live counts with terminal text, reply, Stop, Restart and Esc; J/K and Return; J from the terminal text; Tab and ⇧Tab keeping the draft; busy titles keeping the list scroll position; urgency reordering and counts; Stop/Restart at the 600×400 minimum window; list width at 700 and 1000 px; and the transcript timeline (prompt bubbles, "Worked for 40s" folds, `[` / G / O, then T to the terminal and back).
- **New view tests:** a failed reply, no terminal available, and the empty dashboard.
- **AgentOutputHighlighterTests:** all four, including the never-the-accent check, run against `OutputPalette`.
- **Pure logic tests:** keys, selection, sections, hints and elapsed time.
- **Not ported:** the snapshot/model tests from `AgentDashboardTests`, which already live in soprano-agents and soprano-model.

## Deviations
- **Event instead of a send callback.** Swift's send callback returned a bool; here `Reply` is an event and failure comes back through `reply_failed`, so the dashboard never changes the model.
- **Terminal text is `Option<String>`.** I didn't depend on soprano-term (its native build) just for its two-field state struct. The host closure should return `TerminalView::visible_text()` or `None` when unavailable.
- **Reused shared pieces instead of copying them.** The activity line uses soprano-chat-ui's `ActivityLine`, and the selectable highlighted terminal text uses soprano-editor's `rich::RichText`. Selection needs gpui-component's `Root` in the window.
- **Looks follow Herdr where Swift differs.** The selected row uses Herdr's `selected` token, or `hover` while the list doesn't have focus. The page header is a 48 px strip with the `esc` keycap and a close button, as in Settings.
- **Toolbar on narrow windows.** The view switch and the agent's actions wrap onto two lines instead of dropping controls one by one by priority. Stop and Restart always stay; the test confirms this at 600×400.
- **Real thread in one test.** The transcript test calls `cx.executor().allow_parking()` because the transcript store reads on its own worker thread.

## Commands
- `CARGO_TARGET_DIR=target/agent-soprano-dashboard cargo test -p soprano-dashboard`: 39 passed, three runs in a row.
- `… cargo clippy -p soprano-dashboard --all-targets`: no warnings.
- `cargo fmt -p soprano-dashboard --check`: clean.
- `… cargo build -p soprano-dashboard --examples`: OK.
- `cargo check --target x86_64-unknown-linux-gnu`: fails building `libsqlite3-sys` (bundled SQLite, from soprano-agents) without the `CC_<target>`/`AR_<target>` zig wrappers (I saw a `/tmp/zigwrap` that may hold them). The Windows check was not run. The crate itself has no platform-specific code.