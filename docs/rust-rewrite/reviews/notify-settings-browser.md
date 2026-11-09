I found six behavior differences across the three crates, all low severity: one P2 (agent edits can lose user content in `settings.json`) and five P3s. The notification rules match the Swift: who gets a banner, the one-banner-per-tab replacement (`soprano-<pane>-<tab>`), clearing on focus, status transitions, the stop rules, and the permission states. The automation commands, scripts, error texts and output formatting also match, apart from the blank-page case in finding 6.

**Tests** (`CARGO_TARGET_DIR=target/review-<crate> cargo test -p <crate>`):
- soprano-notify: 45 passed.
- soprano-browser: 32 passed.
- soprano-settings: 62 passed. The first run failed to compile because soprano-config's `Cargo.toml` changed mid-build (commit 5f8e781); the rerun was clean.

## Findings, most severe first

**1. P2 · soprano-settings · Editing an agent profile loses comments and unmodelled keys in `agents`.** Rust: `agents.rs:229-236`. Swift: none (profile editing is new; the Swift page was read-only, `SettingsWindowController.swift:854-878`).
- **What differs:** `set_agent_field`, `remove_agent_entry` and `add_agent` decode the `agents` array into `AgentConfig` structs and write the whole array back. `jsonc::setting` replaces that value in one piece.
- **Consequence:** one field edit or one reset click wipes every comment inside the `agents` block, plus any key `AgentConfig` doesn't model (e.g. `patterns`, `autoRestart`, `restartDelayMs`, or a misspelled key). Key order and formatting are rewritten for every entry, not just the one edited.
- **Fix:** write only the changed field at its own path (`["agents", "<index>", "<field>"]`, if jsonc supports array indices), or add a `#[serde(flatten)] extra: Map<String, Value>` to `AgentConfig` so unknown keys survive. Adding or removing a whole entry can still replace the array.

**2. P3 · soprano-settings · Clicking outside the remove-account dialog or the theme menu also closes Settings.** Rust: `view.rs:845` (overlay `on_mouse_down` → `close`), with the dialog created at `view.rs:580` and the theme menu inside the same overlay. Swift: `SettingsWindowController.swift:1119` (sheet confirm) and the NSMenu-based theme picker.
- **What differs:** soprano-ui's `Dialog` backdrop cancels on mouse-down but doesn't stop propagation (`dialog.rs:482`), and `ContextMenu` dismisses via `on_mouse_down_out`. In GPUI, mouse-down bubbles to every hitbox under the pointer unless one stops it.
- **Consequence:** a click that only meant to cancel the dialog or close the menu also dismisses the whole Settings screen.
- **Fix:** in the overlay's mouse-down handler, return early while `self.dialog` or `self.menu` is set. Alternatively, have the dialog backdrop call `cx.stop_propagation()`.

**3. P3 · soprano-notify · A banner can stay in Notification Center even though its tab just got focus.** Rust: `manager.rs:66-90` (`Shared::schedule` completion). Swift: `AgentNotificationManager.swift:888-897`.
- **What differs:** Swift hops to the main thread, so the focus check and the bookkeeping are atomic with respect to focus changes. Rust checks focus under the `focus` lock, releases it, then takes the `delivered` lock. If the UI thread runs `surface_did_focus` in between, it removes nothing, and the identifier is then recorded for an already-focused tab.
- **Consequence:** the banner and its record stay until the tab is focused again. The porting report's claim that "the behavior is the same" is not quite true.
- **Fix:** do the check and the insert while holding the `delivered` lock. `remove_delivered` already sets focus before taking that lock, so the two paths then always see each other.

**4. P3 · soprano-settings · Esc clears the shortcut search even when the search field doesn't have focus.** Rust: `view.rs:651-655`. Swift: `SettingsWindowController.swift:316-324`.
- **What differs:** Swift clears the query only while the filter field has focus; otherwise Esc closes Settings.
- **Consequence:** after clicking into the page, Esc no longer closes Settings while a query is set; it clears the query first.
- **Fix:** also require `self.shortcut_query.read(cx).focus_handle(cx).is_focused(window)`.

**5. P3 · soprano-settings · Entering the clamped number doesn't fix an out-of-range value in the file.** Rust: `view.rs:441` (`shown.filter(|value| *value != current)`). Swift: `SettingsWindowController.swift:767-790`.
- **What differs:** Swift always writes the clamped value. Rust compares against the resolved value, which is already clamped, and skips the write when they match.
- **Example:** with `"prefixTimeoutMs": 99999` in the file, the field shows the clamped maximum. Committing that value writes nothing, so the file and its "clamped" warning stay.
- **Fix:** compare against the raw value in the file (`snapshot.config.keybindings…`), or always write like Swift.

**6. P3 · soprano-browser · Before a page's first commit, automation commands fail but their scripts still run later.** Rust: `view.rs:510-522` (`evaluate`), together with how wry (lb-wry 0.53.3) handles `eval`. Swift: `BrowserPaneView.swift:527-560`.
- **Cause:** until the first navigation commits, wry pushes scripts onto `pending_scripts` and drops the callback (`wkwebview/mod.rs:684-687`, the same in webkitgtk).
- **Consequence for a tab with no URL** (or during the first load right after `soprano browser open <url>`): `eval`, `snapshot`, `title`, `click`, `fill`, `get` and `is` all answer "The page did not finish running the script". Swift's WKWebView evaluates against the blank document; for example, `title` returns `""`.
- **Side effect:** the queued scripts still run at commit time, so a `click` or `fill` the CLI reported as failed is executed later, with its result discarded.
- **Fix:** build the web view with `about:blank` when there is no initial URL. Also, until the first `PageLoad { started: true }` arrives, answer with an explicit error or wait for it, rather than queueing scripts through wry.

## What I checked and found matching
- **Notification flow:** attach/stop rules, process-id ownership, conversation recording and duplicate suppression within 1 s. Also needs-attention vs. focus, no banner for automation runs, and the banner title/body (`AgentAlert`) and location subtitle. The OSC 9/777 approval rules, permission publish and persist under the Swift key, and banner-click decoding all match.
- **Notification backends:** the macOS, Linux and Windows backends implement replacement and withdrawal on focus.
- **Settings writes:** every key and value written (`theme`, `appearance`, the four switches, `restoreLastSession`, `notifications.sound`, `projectDirectories` home-abbreviated and de-duplicated, `keybindings.prefixKey`/`prefixTimeoutMs`/`resizeTickPercent`, `keybindings.bindings.<id>`, including `null`). Also checked: reset-to-default buttons, the issue banner, prefix-key recorder refusal rules, and notification permission row texts and buttons.
- **Browser:** target resolution and all failure messages, script text, the `literal` escaping (`/` → `\/`), `printableJavaScriptValue` formatting, usage strings, address resolution and screenshot path handling.

Outside my crates, but relevant: `crates/soprano` doesn't yet start the IPC server (`ipc::start_server` has no caller). Nothing there calls `NotificationManager`, `BrowserView::perform_automation` or `BrowserRegistry::view` either, so none of the behavior above is reachable in the app yet.