# soprano-browser — API report from BrowserUi

The `soprano-browser` crate is in place. `cargo build -p soprano-browser --examples` and `cargo test -p soprano-browser` pass (32 tests), clippy is clean and `cargo fmt` has been run. Neither cross-check could finish: on Windows, `gpui-pre`'s build script fails, and on Linux, `wayland-backend` needs system libraries. Both stop in dependencies before this crate is compiled. Nothing was launched or committed, and no page was loaded in a real webview, so the injected scripts have not been run against a page.

## Public API (`soprano_browser`)

```rust
// View
pub struct BrowserView;  // EventEmitter<BrowserEvent>, Focusable, Render
impl BrowserView {
    pub fn new(target: TerminalTarget, initial_url: Option<&str>, window: &mut Window, cx: &mut Context<Self>) -> Self;
    pub fn target(&self) -> &TerminalTarget;
    pub fn url(&self) -> &str;
    pub fn is_loading(&self) -> bool;
    pub fn focus_preferred_control(&mut self, window: &mut Window, cx: &mut Context<Self>); // page if something loaded, else address bar
    pub fn focus_address_bar(&mut self, window: &mut Window, cx: &mut Context<Self>);       // ⌘L, selects the text
    pub fn navigate(&mut self, input: &str, window: &mut Window, cx: &mut Context<Self>) -> Result<String, String>;
    pub fn go_back(&mut self, cx: &mut Context<Self>);
    pub fn go_forward(&mut self, cx: &mut Context<Self>);
    pub fn reload(&mut self, cx: &mut Context<Self>); // stops the load if one is in progress
    pub fn perform_automation(&mut self, command: &str, arguments: &[String], window: &mut Window, cx: &mut Context<Self>) -> Task<Result<String, String>>;
}
pub enum BrowserEvent { UrlChanged(String), TitleChanged(String), FocusRequested, LoadingChanged(bool) }
actions!(browser, [FocusAddressBar, GoBack, GoForward, Reload]);
pub const KEY_CONTEXT: &str = "BrowserView";
pub fn bind_keys(cx: &mut App); // secondary-l / -shift-l / -[ / -] / -r / -shift-r in KEY_CONTEXT

// Registry: a gpui Global, the port of BrowserPaneRegistry
pub type BrowserRegistry = Registry<BrowserView>;
impl Registry<V> { fn register(&mut self, TerminalTarget, WeakEntity<V>); fn unregister(&mut self, &TerminalTarget, EntityId); fn view_for(&mut self, &TerminalTarget) -> Option<Entity<V>> }
impl BrowserRegistry { pub fn view(target: &TerminalTarget, cx: &mut App) -> Option<Entity<BrowserView>> }

// App-side routing, the port of BrowserAutomationController
// Tabs are addressed by soprano_types::TerminalTarget { pane_id, tab_id }
pub struct PaneTabs { pub active_tab_id: Option<String>, pub tabs: Vec<(String, bool /*is_web_browser*/)> }
pub fn resolve_target(requested_pane_id: Option<&str>, active_pane_id: &str, ordered_leaf_ids: &[String], pane: impl Fn(&str) -> Option<PaneTabs>) -> Option<TerminalTarget>;
pub fn is_open_command(command: &str) -> bool;   // open | open-split | new
pub fn no_target_message(requested: Option<&str>) -> String;
pub fn unavailable_message(target: &TerminalTarget) -> String;
pub const PANE_LIMIT_MESSAGE: &str;
pub fn resolve_address(input: &str) -> Option<String>;  // also address::resolve
pub const SCREENSHOT_UNSUPPORTED_MESSAGE: &str;
pub mod scripts; pub mod value;  // pure script generation and result formatting
```

Views register themselves on creation and unregister when released. For a request, the shell does: `is_open_command` → spawn the pane; otherwise `resolve_target` → focus the tab → `BrowserRegistry::view` → `perform_automation`, answering with the message helpers when a step fails.

## Swift ported
- **`BrowserPaneView.swift`**:
  - URL resolution: local dev addresses use HTTP, hostnames HTTPS, other text goes to a DuckDuckGo search, and the text is kept as written.
  - Every automation command, with the same usage and error texts.
  - All seven scripts copied verbatim, with the same layout. The scripts the Swift builds through string interpolation reproduce its output exactly.
  - Output formatting matches `printableJavaScriptValue`: Foundation-style pretty JSON with sorted keys, `true`/`false` print as `1`/`0`, `null` prints as `<null>`, `undefined` as `null`.
  - The address bar is not overwritten while the user is typing in it.
  - Links that open a new window load in the same tab.
  - Toolbar: 41 px with a hairline, 26 px icon buttons, Stop/Reload toggle, a 28 px address field with radius 6, the faint resting fill and an accent edge on focus, and a spinner while loading. The page's light/dark scheme follows the theme.
  - `examples/browser_demo.rs` opens one view (build only).
- **`BrowserAutomationCommand.swift`**: `resolveTarget` plus all of the app's messages.
- **Tests**: the two URL-resolution tests from `BrowserIntegrationTests`, plus new tests for target resolution, the generated scripts, output formatting, the registry, page messages and screenshot writing. `BrowserPaneAutomationTests` needs a live page, so only the parts that work without one became pure tests (fill/check scripts, hidden passwords in snapshots, the same-page URL updates).

## Deviations
- **Running scripts**: wry drops JavaScript exceptions and can crash on results it can't convert to JSON, so every script runs inside a wrapper that always returns JSON. Errors keep the WebKit wording ("A JavaScript exception occurred" / "…unsupported type").
- **`eval` input** runs through a global `eval()` so the last statement's value comes back. Pages whose security policy blocks `eval()` will report the exception message instead.
- **Same-page navigations, back/forward state, page focus and the four shortcuts** come from a script injected into every page, because wry has no equivalent of the Swift app's direct observation of the web view. When the browser can't report back/forward history, the buttons stay enabled.
- **Title** is read from `document.title` when a page finishes loading. **Back/forward** use `history.back()` / `history.forward()`.
- **Screenshot** works on macOS (WKWebView snapshot). On Windows and Linux it returns "Screenshots are not supported by this platform's web view"; the Swift app has no wording for that case.
- **Failed loads**: wry gives no notice that a load failed, so the spinner can keep running until the next page loads.
- **Submitting a bad address** does nothing; the Swift app beeped, and GPUI has no beep.
- **Script answers that never arrive** (page not ready, or closed) return "The page did not finish running the script".
- **Dates** from `eval` print in ISO format, not Foundation's date format.
- **Numbers** that aren't whole use Rust's shortest form, not Foundation's.
- **Toolbar styling**: `soprano-ui` isn't finished, so the toolbar uses gpui-component's theme colors directly.
- **On Linux** the window must run on X11 or XWayland. If the webview can't be built, the pane shows the error and automation returns it.