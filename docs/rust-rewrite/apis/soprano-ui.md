# soprano-ui — API report from UiKit

`crates/soprano-ui` is finished. The gallery example builds, `cargo test -p soprano-ui` passes (91 tests, including window tests for the dialog, picker and toast), clippy over all targets is clean and the code is formatted. I built the gallery but didn't run it.

## Verification
- **Commands:** I ran `CARGO_TARGET_DIR=target/agent-soprano-ui cargo build -p soprano-ui --examples`, `cargo test -p soprano-ui`, `cargo clippy -p soprano-ui --all-targets` (no warnings) and `cargo fmt -p soprano-ui`. For a while other crates' missing example files broke every cargo command in the worktree, so I checked in a scratch workspace holding only soprano-ui, -types and -platform. After that was fixed, the tests also pass in the real workspace.
- **Cross-check:** `cargo check --target x86_64-unknown-linux-gnu -p soprano-ui --lib` passes. The Windows check can't run from this Mac: gpui-pre's own build script needs a Windows resource compiler. My code doesn't cause it.

## Getting started (for the app shell)
- `soprano_ui::init(cx: &mut App, theme_id: &str, appearance: AppearancePreference)` sets up gpui-component, the theme global and the bundled fonts. Tests can call `init_for_tests(cx)`.
- Serve assets with `Application::new().with_assets(SopranoAssets::from_resources_dir())`. `SopranoAssets::new(root)` serves any folder.
- Per window:
  - wrap the root view in `gpui_component::Root`;
  - keep `SopranoTheme::observe_system_appearance(window)` alive;
  - call `cx.soprano_theme().apply_to_window(window)` at the top of the root's `render` (rem = 13 × zoom);
  - render overlay entities (menus, dialogs, picker, toasts) in the root.

## Public API
Sizes are designed px; the widgets apply zoom themselves.

**theme**
- **Palettes:** `AppTheme { id, name, colors: ThemeColors, terminal: TerminalColors }` for `FOLIO_PAPER`, `FOLIO_INK`, `GRUVBOX_DARK`, `CATPPUCCIN_MOCHA`, `DRACULA`, `SOLARIZED_DARK`, `NORD`, `TOKYO_NIGHT`, `ATOM_ONE_DARK`; `ALL_THEMES`, `FOLIO_ID`.
- **Lookup:** `theme_for(id, Appearance)` (unknown ids fall back to Folio), `theme_options()`, `is_known_theme_id()`, `AppearancePreference::{resolve, parse}`, `Appearance::from_window`.
- **Terminal palette:** `TerminalColors::{ghostty_configuration(), ghostty_unfocused_configuration(), unfocused_cursor()}`.
- **Soprano slots:** `ThemeColors::{raised, attention, attention_against(focus), diff_*, syntax(), project_icon_colors(), …}` and `AppTheme::graph_lanes()`.
- **Theme manager:** `ThemeManager::new(id, pref, system)`. `set_theme`, `set_appearance`, `update` and `set_system_appearance` return `Option<&AppTheme>`, set only when the resolved theme changed. Also `follows_system()`.
- **Live global:** `SopranoTheme`, read with `cx.soprano_theme()` from the `ActiveSopranoTheme` trait; it derefs to `Tokens`, e.g. `cx.soprano_theme().hover`. Methods: `z(px) -> Pixels`, `zoom()`, `rem_size()`, `theme()`, `manager()`, `reduce_motion()`, `apply_to_window(window)`.
- **Changes:** `SopranoTheme::{install, set_theme, set_appearance, update_settings, set_system_appearance, set_zoom, zoom_in, zoom_out, reset_zoom, set_reduce_motion}(…, cx)`. Every change re-themes gpui-component and the scrollbar.
- **`Tokens` fields:**
  - Herdr's set: `background`, `surface`, `canvas`, `chrome`, `popover`, `raised`, `hover`, `selected`, `border`, `input`, `foreground`, `muted`, `dim`, `idle`, `accent`, `accent_foreground`, `solid`, `solid_foreground`, `ring`, `selection`, `cursor`, `terminal_foreground`, `ansi[16]`.
  - Fixed colors: `avatar_letter`, `backdrop` (black 35 %), `window_close_hover`.
  - Soprano's: `working`, `approval`, `input_tone`, `failed`, `done`, `muted_tone`, `running_command`, `attention` and its washes, `needs_input_wash`, `error_wash`, `diff_*`, `syntax.*`, `project_colors`, `graph_lanes`.
  - Methods: `tone(StatusTone)`, `lamp(Lamp)`. `HerdrColors::derive(&TerminalColors)` gives the raw 8-bit values.

**fonts**
- Font families: `UI_FONT_FAMILY` ("Geist"), `TERMINAL_FONT_FAMILY`, `MONO_FONT_FAMILY`, `SYMBOLS_FONT_FAMILY`; also `TERMINAL_WEIGHT`, `TERMINAL_LINE_HEIGHT`.
- Sizes in `size::{UI, BRAND, SECTION, SMALL, BADGE, SUBAGENT, META, ROW, STATUS_BAR, PANEL_TITLE, DIALOG_TITLE, TERMINAL, DIFF, FILE_PREVIEW}`.
- Loading: `register_fonts(cx)`, `register_fonts_from(dir, cx)`, `font_files(dir)`.

**icons**
- `IconName`: 139 glyphs, each with `path()`, `stem()` and `ALL`. Herdr's custom glyphs are included, plus Soprano aliases such as `STATUS_WORKING` and `ACCOUNT`.
- It implements gpui-component's `IconNamed`, so it works with that library's own icons.
- `icon(name).size(14.).color(h)`, `Icon::program("claude")`, `Icon::from_path(p)`, `.rotate()`. `agent_icon_stem(profile_id)` names a built-in agent's program icon.
- File icons: `file_type_icon(name)`, `folder_icon(open)`, `SYMLINK_ICON`.

**Buttons**
- `IconButton::new(id, IconName)` or `with_icon(id, Icon)`.
  - Sizes: `IconButtonSize::{Chrome, Pane, Tab}`.
  - Builders: `.icon_size .color .selected .disabled .tooltip .on_click`.
- `Button::new(id, label)`.
  - Variants: `ButtonVariant::{Primary, Secondary, Ghost, Destructive, DestructiveOutline, Text}`.
  - Sizes: `ButtonSize::{Xs, Sm, Regular}` (h24 / h28 / h32).
  - Builders: `.icon .keycap .disabled .full_width .tooltip .on_click`.

**chrome**
- `SidebarRow::new(id)`: `.height .selected .on_click .on_secondary_click(|pos, w, cx|) .tooltip`; accepts children and style tweaks.
- `SectionHeader::new(id, title)`: `.count .collapsed .medium .color .end_slot .on_toggle`.
- `Card::new()`: `.focused .attention .on_mouse_down`.
- `CardHeader::{pane(), panel()}`.
- `TabPill::new(id, label)`: `.active .number .icon .status .badges([Option<TabBadge>]) .tooltip .on_click .on_close .on_secondary_click`.
- `PanelToggle::new(id, IconName, label)`: `.on .on_click`.
- `StatusBar::new()` with `.end(el)`.
- `StatusBarItem::new(text)`: `.icon .dot .color .tooltip(id, text) .on_click(id, f)`.
- `ScrollList::new(id, &ScrollHandle)`: `.mode(ScrollbarMode)`.

**controls**
- `Switch::new(id, on)`: `.disabled .on_change`.
- `SegmentedControl::new(id, titles)`: `.selected .disabled_segments .well .on_select`. `.well()` sets the segments in a bordered `canvas` well, for a control that stands alone in a form or toolbar.
- `text_input(&state)` / `TextInput::new(&state)`: `.small .large .accent .invalid .prefix .suffix`. Re-exports `InputState` and `InputEvent`.

**select**
- `Select::new(id, Vec<SelectOption>, Option<usize>, cx) -> Entity`.
- Methods: `set_placeholder`, `set_width`, `set_disabled`, `set_options`, `set_selected`, `selected`.
- Emits `SelectChanged { index, value }`.

**menu**
- `ContextMenu::new(position, Vec<MenuItem>, window, cx) -> Entity`, plus `set_width`. Emits `DismissEvent`.
- `MenuItem::new(label)`: `.icon .shortcut .disabled .checked .on_select`.
- Also `MenuItem::submenu`, `separator()` and `header()`.

**dialog**
- Content: `DialogContent::{new, confirm(title, msg, confirm, destructive), alert, save_changes, prompt(title, msg, placeholder, initial, confirm)}`, with `.validate(f)` and `.hint(h)`. Also `key_choice(&Keystroke, KeyPlatform)`.
- `Dialog::new(content, window, cx) -> Entity`: `.on_finish(f)`, `.finish(index, …)`. Emits `DialogResult { index, text }` (`prompt_value()`) and then `DismissEvent`.
- `dialog_passes_chord_to_app(&Keystroke)` tells your keystroke interceptor which chords may pass while a dialog is up.

**picker**
- `Picker::new(Vec<PickerItem>, window, cx)`: `set_placeholder`, `set_title`, `set_search_keycaps`, `set_frame(width, top)`, `set_items`. Emits `PickerEvent::{Confirmed { id, query }, Dismissed}` and `DismissEvent`.
- `PickerItem::new(id, label)`: `.description .group .icon .with_icon .keycaps .search_text`.
- Logic without a window: `filter()`, `match_range()`, `PickerState`.

**status**
- Time text: `compact_duration`, `relative_time`.
- `StatusPillSpec::{of(status, reason, since), for_pane, RUNNING, READY}` and `.text(now)`.
- `StatusClock` (a global): `since`, `pill`, `forget`.
- Tab badges: `TabBadge::{agents, running_commands}`, `agents_summary`, `running_commands_summary`, `tab_tooltip`.
- Elements:
  - `StatusPill::new(pill)` with `.relative_to .now`;
  - `TabBadgeView`;
  - `StatusGlyph::{spinner, needs_you, dot, ring, new(GlyphKind), for_pill(&pill, compact)}` with `.color`.

**Other modules**
- **identity:** `monogram`, `project_color_index`, `project_color`, `Avatar::new(name)` (`.color .size`), `Monogram::new(name)` (`.size`).
- **keycaps:**
  - from a binding: `keycaps(&KeyBinding, prefix)` / `keycaps_for(…, KeyPlatform)`, plus `chord_cap` and `key_legend`;
  - the element: `Keycaps::new(caps)` / `alternatives(groups)`, with `.small .color`.
- **tooltip:** `tooltip(text)`, `tooltip_with_keycaps(text, caps)`, the `Tooltip` view.
- **toast:** `ToastStack::new(cx)` with `.push(Toast::new(ToastLevel, title).body(..).on_click(..), cx)` and `.remove`.
- **motion:** `FADE` (150 ms), `fade_in(el, id, cx)`, the spinner constants and `ease_out`.
- **snapshot** (feature `snapshot`, dev-dependencies only): the examples' `--snapshot` mode. `Args::parse(width, height)` reads `--snapshot /abs/dir`, `--size`, `--appearance` and leaves the example's own flags in `rest`; `redraw(cx).await` draws a window that is not on screen; `click`, `scroll` and `press("j enter")` send real input; `pixels` and `write_png` read the frame; `finish` quits or exits 1. The renderer needs `gpui_platform/test-support`, which the examples enable on macOS only.

I added `ShieldQuestionMark`-style names and the extra glyphs that ExplorerUi, EditorUi, ChatUi, SettingsUi and AppShell asked for, and sent each of them the signatures they need.

## Swift ported
- **Tests:**
  - `TerminalThemeTests`: all of it.
  - `CommandPaletteSearchTests`: all of it.
  - `CommandPaletteDismissTests`: as window click tests.
  - `CommandPaletteKeycapTests`: the default bindings are built by hand, because `DefaultKeybindings` lives in soprano-config.
  - `ShellDialogsTests`: the logic and key tests.
  - The badge and tooltip cases from `WindowTabBarTests` and `LayoutTabBarTests`.
- **Sources:**
  - `Theme.swift` and `ThemeManager.swift`;
  - the `Palette.swift` tone mapping, `ShellKit.swift` and `ShellDialogs.swift`;
  - the button parts of `Controls.swift` and `ShellControls.swift`;
  - the icon list in `Style.swift`, `FileTypeIcon.swift`, `StatusCountBadgeView.swift`;
  - the keycap logic in `MainWindowController.swift`;
  - the search in `CommandPalettePanel.swift`.

## Where I departed from the brief or the Swift
- **Status colors:** I followed the exact Swift mapping, as you asked me to check it. Status pills, badges and the glyphs drawn from them use `Palette.color(for:)`: Working blue, Approval yellow, Input cyan, Failed red, Done green. Commands also count as Working there, so the running-commands badge is **blue in Swift, not cyan as the brief said**. The colors you listed (Starting/Input yellow, Working green, Ready blue, running command cyan) are Swift's older lamp mapping; they are available as `tokens.lamp(Lamp::…)` and `running_command`. If you want the tab badge cyan anyway, it's a one-line change.
- **Attention color:** it is measured against Herdr's focus accent (ANSI blue), so focus and attention never share a hue. In practice attention is yellow in most themes.
- **Not ported:**
  - `ThemeShadowTests`: these test AppKit layer rendering. Overlays use Herdr's Tailwind shadows instead.
  - Swift's modal-session dialog tests: GPUI has no modal sessions. Dialogs answer through a callback or event.
- **Dialog behavior:** the backdrop is Herdr's black 35 % rather than Swift's tinted background. A dialog can't stop app-wide shortcuts by itself; the app shell does that with `dialog_passes_chord_to_app`.
- **Theme palettes:** `PLAN.md` also lists "Theme palettes as data" under soprano-config. The palettes now live here as `&'static` data, so whoever owns soprano-config should re-export these rather than copy them.
- **New dependencies:** `gpui-base` and `gpui-kit-assets` (both =0.9.1, already in the lockfile) and `unicode-normalization`, which the monogram needs for Swift's text normalization.

Nothing was committed. New files are under `crates/soprano-ui/`, `resources/icons/ui/` (139 SVGs plus `LICENSES.txt`) and `examples/gallery.rs`.