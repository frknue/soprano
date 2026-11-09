I found 3 real problems in commands/keyboard and 1 small menu gap. Everything else I compared matches Swift, apart from zoom, which differs on purpose. `CARGO_TARGET_DIR=target/review-app cargo test -p soprano` passed all 112 tests, but none of them covers the problems below.

## Findings (most severe first)

### 1. P1 — Editor and Automations page lose their own shortcuts
- **Rust:** `crates/soprano/src/main_view.rs:1523-1536` (`focused_content`) only ever returns `Terminal`, `Browser` or `Other`.
- **Swift:** `KeybindingManager.swift:42-65` (`ownsChord`) together with `MainWindowController.swift:916` (`focusedContent(of:)`). There, a focused `EditorPaneView` counts as `.editor` and `AutomationsRootView` counts as `.automations`.
- **What differs:** the resolver never sees `FocusedContent::Editor` or `FocusedContent::Automations`. The keystroke interceptor runs before GPUI's keymap and stops the key, so Soprano's bindings win over the content's own:
  - ⌘F in an editor opens **Find Window** (default `find-window`) instead of the editor's find bar. The editor binds `Find` on `cmd-f` in `soprano-editor/src/editor/mod.rs:118`.
  - ⇧⌘G in an editor toggles **Source Control** instead of Find Previous.
  - ⌘G and ⌘S, if the user binds them, act the same way.
  - ⌘N on the Automations page opens a **New Window** instead of New Automation (`soprano-automations-ui` binds `cmd-n`).
- **Fix:** return `FocusedContent::Editor` for `PaneContent::Editor(_)`. Before looping over the contents, return `FocusedContent::Automations` when `self.automations_page`'s focus handle `contains_focused(window, cx)`.

### 2. P2 — `soprano <file.md>` prints a tab id instead of a pane id
- **Rust:** `crates/soprano/src/ipc.rs:71-72`. `Workspace::preview_markdown` returns the reader's **tab id** (`soprano-model/src/workspace/files.rs:26-27,47`), and the code sends that as the reply.
- **Swift:** `MarkdownCommand.swift:336-343` returns `ownerPaneId` after a preview succeeds.
- **Consequence:** the default (no `--new`) Markdown command prints a tab id on stdout. A script that feeds it to `soprano browser --pane …` or other pane-addressed commands gets an id that is not a pane. The test only checks that the output is not empty.
- **Fix:** `Some(_) => Response::success(owner)`.

### 3. P2 — Commands-menu shortcuts stay frozen at their launch-time chords
- **Rust:** `crates/soprano/src/menus.rs:131`. `menus::install` is called again on every settings.json change (`main_view.rs:1455`), and each time it calls `cx.bind_keys(display_bindings)`.
- **GPUI behaviour (checked in the 0.3.12 source):**
  - `bind_keys` only appends.
  - The macOS menu builder (`gpui-pre-macos/src/platform.rs:345-365`) uses `bindings_for_action(..).find_or_first(..)`. The `SopranoMenuDisplay` predicate never matches, so it always takes the **first** binding ever added for that action.
- **Swift:** `installCommandsMenu()` rebuilds the menu with key equivalents read from the current config. Its comment explains why: a stale equivalent would keep firing and outrank settings.json.
- **Consequence:** after rebinding or unbinding Command Palette, Find Window, Open Project or Agent Dashboard, the menu still shows the old chord. The NSMenu item also keeps that old chord as a real key equivalent. When focused content doesn't handle the key, GPUI's `performKeyEquivalent` returns NO and AppKit then fires the menu item, so the old chord most likely still runs the command. That last step is an inference; the stale menu display is certain.
- **Fix:** don't append on reinstall. Clear the keymap (`cx.clear_key_bindings()`) and rebind everything in one shared function — gpui-component, terminal, browser, editor/diff/reader and the menu bindings. Currently `app.rs` binds these once at startup.

### 4. P3 — Edit menu is missing "Delete"
- **Rust:** `menus.rs:132-145` builds Edit as Undo, Redo, Cut, Copy, Paste, Select All.
- **Swift:** `AppDelegate.swift:151` also has **Delete** (`NSText.delete(_:)`, no key equivalent) between Paste and the separator.
- **Fix:** add a Delete row there (only if GPUI can express it on macOS).

## Areas checked and clean
- **Binding table:** every id in `executeBinding` maps to the same `BindingCommand` and the same model call in `run_binding`:
  - `select-window-N`, `launch-<agent>`, the split direction swap, `new-chat`.
  - Navigation, previous/next/last window, resize with the tick percent.
  - `close-pane`, and `kill-pane` / `close-active` / `close-pane-tab(-direct)` (the last tab takes the pane with it), maximize, copy mode.
  - Window, tab and pane-tab ids, and the `-direct` aliases.
  - `find-*`, `open-*`, rename/close window, terminal, browser, save, the four sidebar toggles, settings, dashboard.
- **Resolver order** matches Swift `handleKeyDown`: typed hint, prefix/literal prefix, prefix bindings, direct bindings (passthrough claims, then menu-owned ids, then content-owned chords), then the pane-hint chord. The zoom-in alias and Tab handling match too.
- **Command palette:** all items are in the Swift order with the same ids, titles, descriptions, search text, shortcut binding fallbacks and actions. Soprano Git is listed only when installed. The session, window and project pickers match (placeholders, "Current · " wording, query-matched tab focus, "Choose Directory…").
- **Commands menu:** same titles, order, separator and actions.
- **Prompts:** New/Rename/Close Session, Rename Window and Save Workspace use the Swift strings.
- **Pages:** Settings, Accounts, Dashboard and Automations close each other as in Swift.
- **Open in Soprano Git** reports its notice the same way.
- **IPC:**
  - `navigate-pane` acts only for the active tab.
  - Passthrough enable/disable and claim sync work as in Swift.
  - Markdown errors and their wording match.
  - Browser `open/open-split/new`, target resolution and all message strings match.
  - `agent-event` routing matches.
- **CLI and launch:** `LaunchDispatch` and `main.rs` match Swift's subcommand order, usage text and exit codes.
- **Zoom** scales the whole UI rather than only the active terminal's font. This is intentional ("per the brief" in the git history of `docs/rust-rewrite/apis/soprano-app.md`), so I didn't count it as a finding.

## Lead addendum

5. Zoom must follow Swift: ⌘= / ⌘- / ⌘0 change the ACTIVE TERMINAL's font size (`MainWindowController.keybindingZoom` → `changeActiveTerminalFontSize(delta)`, `resetActiveTerminalFontSize()`), not the whole UI. Use `TerminalView::change_font_size(delta)` / `reset_font_size(configured)`. The UI zoom factor stays at 1.
