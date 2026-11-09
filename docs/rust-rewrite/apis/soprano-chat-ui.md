# soprano-chat-ui — API report from ChatUi

> `ChatUi` is running a newer turn. The output below is from its PREVIOUS run (published 5.0s ago), not the current one. Live progress: `history://ChatUi`; its next result auto-delivers to its owner.I've built `crates/soprano-chat-ui` (the chat timeline and the chat tab with its composer), but my final changes are not verified yet and clippy and the Linux/Windows checks have never run. Those runs are blocked because `soprano-editor` stopped compiling against the current `soprano-text`; that isn't my crate.

**Where verification stands:**
- **Last green state** (before my final edits): `cargo test -p soprano-chat-ui` passed 47 of 47, including 11 headless GPUI tests, and `cargo build -p soprano-chat-ui --examples` built `examples/chat_demo`.
- **Edits made after that run, not built yet:**
  - the popover now catches Esc/↑/↓/Return coming from the model search field;
  - text the composer sets itself no longer opens the `/` menu;
  - the chips can't be opened while the agent is stopped;
  - the status test now also covers the title event and stop → Return asking for a restart.
- **Clippy and the Linux/Windows cross-checks:** never completed. The first clippy attempt failed on a then-broken `soprano-text`; the latest one on `soprano-editor`.
- **`cargo fmt -p soprano-chat-ui`:** has been run.
- **The blocker:** `soprano-text` changed `FileWatcher::new`, `restore_selection` and table cells, and `soprano-editor` (EditorUi's) hasn't caught up. I've told EditorUi which lines break. Once it builds, run:
  - `CARGO_TARGET_DIR=target/agent-soprano-chat-ui cargo test -p soprano-chat-ui`
  - `CARGO_TARGET_DIR=target/agent-soprano-chat-ui cargo clippy -p soprano-chat-ui --all-targets`
  - `CARGO_TARGET_DIR=target/agent-soprano-chat-ui cargo build -p soprano-chat-ui --examples`
  - `cargo check --target x86_64-unknown-linux-gnu -p soprano-chat-ui`, and the same with `--target x86_64-pc-windows-msvc`

## Public API (re-exported at the crate root)
- **`TimelineSource`** (trait): `thread() -> ChatThread`, `empty_timeline_text(&str) -> String`, and `can_send_queued_now`, `choose_permission_option(&str)`, `send_queued_prompt_now(&str)`, `remove_queued_prompt(&str)`, which do nothing by default.
  - `SessionSource(SharedSession)` implements it, with `SharedSession = Rc<RefCell<AgentChatSession>>`.
  - `TranscriptSource::new() -> Rc<Self>` plus `.set(thread, empty_text)` is the dashboard's read-only source.
- **`TimelineView`** (Entity, `Focusable`, emits `TimelineEvent::FollowingChanged(bool)`):
  - `new(Rc<dyn TimelineSource>, agent_name, window, cx)`
  - `reload(scroll_to_end, cx)`, `rows()`, `expansion()`
  - `set_bottom_inset(Pixels, cx)`, which takes window pixels
  - `is_detailed()` / `set_detailed(bool, cx)`
  - `jump_to_message(i32, cx)`, `jump_to_latest(cx)`, `is_following()`
  - `scroll_by(Pixels, cx)`, `page_height()`
  - `reveal_diff(turn_id, path, cx)`, `set_agent_name`, `close()`
  - ↑/↓/PgUp/PgDn/Space/Home/End are handled inside; every other key bubbles up to the host.
- **`ChatView`** (Entity) emits `ChatViewEvent::{Agent(AgentChatEvent), FocusRequested, RestartRequested}`:
  - `new(AgentChatSession, agent_name, window, cx)` takes over the session's change, event and waker callbacks.
  - `start(Option<&str>, …)`, `stop`, `restart(fallback, …)`, `submit_prompt(&str, …) -> bool` (the dashboard reply), `close(cx)`.
  - `session()`, `timeline()`, `composer()`, `focus_composer(window, cx)`.
  - The shell updates the workspace from these events (Main's contract); `ChatView` never mutates the workspace itself.
- **`ComposerView`** emits `ComposerEvent::{Submitted, RestartRequested, FocusChanged(bool)}`; also `text`, `set_text`, `submit(alternate)`, `focus_editor`, `close`.
- **`ActivityLine::new(AgentTimelineActivity)`** with `.compact(bool)`, `.fonts(size, weight)`, `.color(h)`, `.code_color(h)`; plus `activity_parts`.
- **Logic modules:**
  - `rows`: `timeline_rows`, `fold_label`, `TimelineExpansion`, the row models
  - `work_log`, `changed_file_tree`, `format`
  - `composer_logic`: primary action, history, slash token and filter, context reading, chip compaction, model helpers, `AnswerDraft`, placeholder
  - `keys`: ⌘ on macOS, Ctrl+Shift on Linux and Windows
- Windows that show these need gpui-component's `Root` and `soprano_ui::init`.

## Ported
- **Swift views:**
  - `AgentChatPaneView`, `ChatTimelineView`, `TimelineListView`
  - `TimelineRows`, `WorkLog`, `ChangedFileTree`, all of `Rows/*`
  - every composer file (`ChatComposerView`, `ComposerControls`, `ComposerEditor`, `ComposerMenus`, `ComposerPanels`, `ComposerPopover`, `ContextMeterView`, `SlashCommandMenu`)
  - the drawing of `AgentTimelineActivity`
  - inline diffs, drawn with `soprano_editor::rich::HunkDiff` and `DiffStat`
  - Markdown, drawn with `rich::Markdown`
- **Tests:**
  - the `TimelineBuilder` and `foldLabel` cases from `ACPTurnBuilderTests`
  - the view parts of `TranscriptThreadTests` and `AgentTimelineActivityTests`
  - the status and conversation part of `AgentChatTabTests`
  - the queue, steer, cancel, slash-command and queued-message parts of `AgentChatSessionTests`
  - the dashboard's timeline test (prompt jumps, following, minimal vs detailed work log)
  - composer behavior: Return, ⇧Return, ⌘Return, Esc, ↑/↓ history, decline-and-redirect on an approval, picking a question's answer by digit, Tab inserting a `/` command
  - logic tests for every module

## Deviations
- **Popovers** are drawn inside the window (anchored, deferred) instead of child windows, so "another window became key" now means the editor lost focus.
- **Folding long user messages** uses the height of the text shaped at 14 px, not the rendered Markdown's height.
- **The activity line's code part** is drawn in mono at the line's size rather than one size smaller, because a GPUI text run can't change size mid-line.
- **The "↪ Steer" glyph** is Lucide `Redo2`, and the round button's arrow is the `ArrowUp` icon instead of a hand-drawn path.
- **Timestamps** use the US format ("3:42 PM", "3/14") rather than the system locale.

## Example
`examples/chat_demo.rs` runs a `ReplayAgent` peer that replays `examples/chat_demo.acp.jsonl` on every prompt: plan, thinking, read, search, edit, write, an approval it waits on, a command, the answer, commands for the `/` menu, and context usage. It was only built, never launched.