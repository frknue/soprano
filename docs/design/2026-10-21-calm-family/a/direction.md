# Direction A: Quiet — final spec

Source of truth for the implementation. Tokens: `a/tokens.css`; components and class index: `a/components.css`; rendered reference: `a/system.html`. Where this text and the screens differ, the screens (and `system.html`) win.

## 1. Name, concept, mood
**Quiet**: the same console with the lights dimmed. Mono chrome, orange still means "your keys go here", and everything that glowed, striped, blinked or shouted is gone. Dark is primary; Light is a first-class **cool graphite console** (grey ground, not paper). Mood references: **Zed** (calm chrome, neutral selection), **Sublime Merge** (dense git UI that reads quietly), **Ghostty** (native chrome that disappears, dimmed unfocused splits).

## 2. Principles (each testable on a screenshot)
1. **One accent per region.** At rest, orange appears only on the focused pane/region frame, the focus tick of the focused list, at most one primary button per view, and the caret/cursor. Test: focus in a terminal pane gives ≤ 3 orange elements on screen.
2. **Color means "act".** Colored *text* only for NEEDS INPUT, ERROR, attention counts, diff/git semantics and usage ≥ 70%. Every other state is colored only as a dot. Test: count the colored text runs.
3. **Uppercase means machine state.** Only status labels (WORKING…) and the mode chip (NORMAL…) are uppercase; acronyms (`SHA`) and letter-key legends (`J`, `⇧J`) are the only other caps. Everything else is sentence case.
4. **One line weight.** Every rule is 1 px. No double rules, no glow, no text shadow. Shadows only on floating overlays.
5. **Shape before hue.** Focus is a frame, attention is a header band, selection is a fill, an active state is a solid dot, a resting state is a ring. Test: in a grayscale screenshot of an 8-pane grid, focused, attention and selected items are still identifiable.
6. **Mono for what the machine says or you type, sans for sentences.** Descriptions, subtitles, dialog messages and empty states are SF Pro; everything else is SF Mono.

## 3. Mission Control → Quiet
| Item | Verdict | Quiet rule |
|---|---|---|
| Departure Mono + small caps | change | All chrome in SF Mono, sentence case. Departure Mono only as the lowercase wordmark `soprano` (About, Welcome, site H1), no small caps, no glow. |
| Single rules | keep, fewer | 1 px borderSubtle dividers; section headings lose their trailing rule. |
| Double rules · racing stripe · glow · CRT | remove | No replacement. The CRT setting, Settings row and shader are deleted. |
| Lamps | change | Flat status dots: solid = active or needs you, ring = at rest. No shadow. |
| Lit blocks | remove | Neutral selection fill (+ accent tick when the list is focused); tinted chip for PREFIX/COPY. |
| `T+HH:MM:SS` clock | remove | The slot holds plain hints `⌘P commands  ⌃A prefix`. |
| Square corners | keep for tiling | Panes, splits, terminals, bars: 0. Rows/chips/keycaps 4 · controls 6 · cards/tiles 8 · overlays 10. |
| Orange | keep, narrowed | `#e8873a` dark / `#a64608` light. Only principle 1, plus transient PREFIX/COPY, ⌃-jump hints and the recorder countdown. Never in code. |
| Density | keep | Bars lose 2–6 px each; type stays 11–13 px; air from consistent spacing. |

## 4. Color
Theme ids: `quiet` (default, follows the system appearance) → `quiet-dark` / `quiet-light`. `missionControl` is deleted; `mission-control` in old settings falls back to `quiet` via the unknown-id fallback.

| Slot | Quiet Dark | Quiet Light | Use |
|---|---|---|---|
| bgBase | #16181c | #f3f4f5 | content, terminals, active tab, launcher/switcher panels |
| bgPanel | #121417 | #e9ebee | sidebars, bars, unfocused pane headers, settings nav |
| bgRaised | #1e2126 | #ffffff | fields, keycaps, focused pane header, buttons, light cards |
| bgOverlay | #262a30 | #e1e4e8 | hover on tiles, pressed standard button |
| textPrimary | #d8d3c6 | #1f2328 | titles, active text |
| textMuted | #8b877e | #59606b | secondary text, icons, hint words |
| accent | #e8873a | #a64608 | focus frame, tick, primary, caret |
| accentStrong | #f2a35e | #8f3c06 | pressed primary only (never syntax) |
| borderSubtle | #24272c | #dde0e4 | dividers, field and keycap borders |
| borderStrong | #33373e | #c9cdd3 | split dividers, overlay edges, keycap edge on fills (dark) |
| success | #8fb573 | #246c35 | WORKING, + lines, strings, granted |
| danger | #de6b5e | #b33029 | ERROR, − lines, destructive |
| blue | #76a3cc | #1f62b0 | READY, attention |
| cyan | #6cb0a8 | #0f6a64 | RUNNING, renames, @@, types |
| yellow | #d7ab55 | #7d5900 | NEEDS INPUT, usage ≥ 70%, search matches, numbers |
| gray | #62656c | #8b929c | STOPPED, ignored files (never text) |

Derived tokens (formulas over the slots — every theme gets them; translucent so they sit on any surface):
| Token | Formula (dark / light) |
|---|---|
| selection / selectionInactive / hover | textPrimary @ 8 / 7% · 5 / 4.5% · 5 / 4% (selection 12% if textPrimary luminance < 0.35) |
| focusRing | accent (pane frame, Git region frame, tick) |
| attention | blue, or the theme's ANSI 5 when accent and blue are < 30° apart in hue |
| attentionBand | attention @ 18% / 14% |
| chipFill(c) | c @ 14% / 8% |
| dim (unfocused pane) | bgBase @ 20% / 25% over terminal content only |
| scrim | #000 @ 45% / bgBase @ 60% |
| diffAdd · diffDel / word emphasis | success · danger @ 12% / 10% · @ 26% / 24% |
| diffFiller | textMuted @ 5% / 6%, flat (no hatch) |
| searchMatch | yellow @ 20% |
| shadows L1 / L2 / window | black .30 / .40 / .45 dark · ink .12 / .16 / .18 light |

Contrast (WCAG): **Dark** textPrimary 11.9 on bgBase, 12.4 on bgPanel; textMuted 5.0 / 5.2 (4.2 on selection); accent 6.7; ink #121417 on accent 7.0. **Light** textPrimary 14.4 / 13.2; textMuted 5.8 / 5.3 (5.0 on selection); accent 5.5 / 5.0; white on accent 6.0; accent on its chip 4.5. Status colors ≥ 4.6 on both grounds, ≥ 4.5 on their own washes/chips (`+` lines and strings on the add wash, `M` on its yellow chip). Gray never carries text.

## 5. Terminal palette
| | bg | fg | cursor | selection |
|---|---|---|---|---|
| Dark | #16181c | #d4cfc2 (11.4) | #e8873a | #34373d (fg 7.7) |
| Light | #f3f4f5 | #1f2328 (14.4) | #a64608 | #d3d8de (fg 11.0) |

| ANSI | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| Dark | #1f2227 | #de6b5e | #8fb573 | #d7ab55 | #76a3cc | #c48bb8 | #6cb0a8 | #c9c4b7 |
| Dark 8–15 | #767a82 (4.1) | #eb857a | #a8cb8e | #e8c174 | #93b9dd | #d6a6cb | #8ac6be | #ece7da |
| Light | #24292f | #b33029 | #246c35 | #7d5900 | #1f62b0 | #8a3f9c | #0f6a64 | #6b727c |
| Light 8–15 | #555c66 | #c24c3f | #327f41 | #946a00 | #2f72c2 | #9b52ad | #1a7d76 | #8b929c |
Light 1–6 are ≥ 5.0 on the terminal bg; Light 7/15 are mid greys (GitHub Light convention) so "white" CLI output stays visible. Cursor: solid accent in the focused pane, hollow 1 px textMuted in unfocused panes.

## 6. Status, attention, focus, selection
| State | Dot (8 px header / 6 px rows) | Label |
|---|---|---|
| STARTING | ring, 2 px stroke, textMuted | textMuted |
| WORKING | solid success | textMuted |
| RUNNING (plain shell) | solid cyan | textMuted |
| READY | ring blue | textMuted |
| NEEDS INPUT | solid yellow | **yellow** |
| ERROR | solid danger | **danger** |
| STOPPED | ring gray | textMuted |
| Idle shell | 6 px ring borderStrong | none |
Labels: SF Mono 11 Semibold UPPER, +0.5 tracking. Pane headers show every state word; sidebar rows show the word only for NEEDS INPUT / ERROR. Aggregates take the most urgent member: error > waiting > running > starting > idle. Badges are `● 3` (dot + textMuted count), no box. When a pane header carries the status dot, its active pane tab does not repeat it.

**Focus.** The focused pane draws a 1 px accent frame inside its bounds and gets a bgRaised header with textPrimary title. Unfocused panes: no own frame inside a split tree (the 1 px borderStrong dividers separate), bgPanel header, textMuted title, the `dim` overlay, their active pane tab textMuted on selectionInactive, hollow textMuted cursor. **Git uses the same frame idiom**: the region that owns j/k/s/u/d (refs, graph, commit panel, diff) draws a 1 px accent frame (`.region.is-focused`); its header title turns textPrimary, the header bottom line stays borderSubtle.
**Attention.** Pane header filled with `attentionBand` plus a 2 px attention line on its top edge — a band, never a frame. An attention pane is **never dimmed**; it is the brightest unfocused pane. Pane tab: 6 px attention dot before the title. **Rows** (sidebar, dashboard, any list): no fill, no tick — 6 px attention dot + the colored state label only, so attention never reads as selection. Window count `3 · ●1`, status bar `1 needs input` in attention. Clears on focus.
**Selection.**
- *Row*: `selection` fill, inset 4 px, radius 4; the list that owns the keyboard adds a 2 × (rowH − 8) px accent tick at x = 2; unfocused lists use selectionInactive, no tick. The palette has the tick; single-list surfaces (Cast launcher, Tab titles) do not.
- *Current tab*: the tab takes the surface it controls (bgBase), textPrimary Medium; inactive tabs bgPanel, textMuted; no underline, no separators; the bottom line breaks under the active tab.
- *Mode / on*: `chipFill(accent)` + accent ink (PREFIX, COPY, ⌃-jump hints `1`–`9`, `⇧K`); SELECT = chipFill(blue); NORMAL = textMuted in a 1 px borderSubtle chip. *Primary*: accent fill, ink #121417 / #ffffff, radius 6, one per view; a primary that can't run shows the standard disabled look.
- *Matches* (Cast, Tab): Bold 700 + 1 px textPrimary underline, no color; a selected row with a match keeps its title Regular. Git search: yellow @ 20% highlight + 2 px yellow tick on the current match row.
- *Hover*: `hover` fill; icons textMuted → textPrimary, never accent (accent on an icon = toggle on). *Destructive menu rows*: textPrimary label + danger icon.

**Keys (K1, family rule).** One cap per chord (`⌘1`, `⇧⌘P`, `⌃A`); a prefix sequence is separate caps (`⌃A` then `G`); letter keys are uppercase legends like the keyboard and macOS menus (`J`, `K`, `V`, `Y`, `⇧J`); `esc` is lowercase. Settings Prefix shows one cap `⌃A`. **Boxed `.kbd`** (18 high, bgRaised, 1 px borderSubtle; borderStrong edge on a selection fill or inside a hotkey field in dark) only where the key is the content: palette shortcut column, Cast hotkeys (rows, table, detail, recorder), keycap fields, shortcut tables. **Hint groups and footers are plain console text**: key textPrimary SF Mono Medium, word textMuted, lowercase — `↑↓ navigate  ↵ run  esc close`. Key text inside buttons (Git toolbar `Pull ⌃A P`): SF Pro 11 Medium textMuted. Location separator everywhere: `›`.
**Syntax.** Keywords textPrimary Semibold, types cyan, strings success, comments textMuted italic, numbers yellow, functions blue, attributes ANSI 5. No orange in code.

## 7. Type
Families: **SF Mono** and **SF Pro Text** (system). **Departure Mono** only for the wordmark (bundled, SIL OFL 1.1, github.com/rektdeckard/departure-mono).
| Role | Font | px / line | Weight | Case |
|---|---|---|---|---|
| Chrome label (tabs, buttons, headers, columns, window rows) | SF Mono | 11 / 16 | Medium | sentence |
| Row text (pane titles, files, commit messages, paths) | SF Mono | 12 / 16 | Regular | — |
| Data small (branch, SHA, dates, counts, line numbers) | SF Mono | 11 / 14 | Regular, textMuted | — |
| State label + mode chip | SF Mono | 11 / 14 | Semibold, +0.5 | UPPER |
| Section header | SF Mono | 11 / 16 | Semibold, textMuted | sentence; 16 above / 4 below |
| Screen title | SF Mono | 17 / 22 | Semibold, −0.2 | sentence |
| Prose | SF Pro Text | 12 / 17 | Regular | sentence |
| Settings row label | SF Pro Text | 13 / 18 | Regular | sentence |
| Inputs (palette, filters, settings fields, composer) | SF Mono | 13 / 18 | Regular | — |
| Launcher query | SF Mono | 18 / 24 | Regular | — |
| Palette / launcher row title | SF Mono | 13 / 18 | Regular (selected Medium) | — |
| Keycap / in-button key text | SF Pro Text | 11 / 14 | Medium, textMuted | K1 |
| Hint key (plain) | SF Mono | 11 / 14 | Medium, textPrimary | K1 |
| Dashboard tallies | SF Mono | 22 / 26 | Medium (zero: textMuted, no dot) | — |
| Wordmark | Departure Mono | 22 (About/Welcome) · 96 (site) | Regular | lowercase |
| Markdown reader | SF Pro 15/24 body · SF Pro Display 26 / 20 Semibold h1/h2 · SF Mono 13 code | | | no rules |
1x: nothing below 11 px; no weight below Regular; tabular digits; frames on whole pixels (`backingAlignedRect`).

## 8. Space, shape, elevation
Scale 2 · 4 · 8 · 12 · 16 · 24 · 32. Row/bar padding 12, icon–text gap 8, cluster gap 16, controls 24.
| Surface | Height (today) |
|---|---|
| Soprano layout-tab row / window-tab row | 32 (34) / 30 (34) |
| Sidebar header, window row, pane row (2 lines), footer | 28, 28 (32), 40, 32 (36) |
| Pane header / pane tabs | 26 (32) / 20, radius 4 |
| Status bar / right-sidebar header / explorer + SCM rows | 26 (32) / 32 (34) / 24 |
| Dashboard header / tallies / agent rows | 52 (68) / 72 (92) / 52 |
| Settings header / nav row / form row | 48 (52) / 30, radius 6 / ≥ 36 |
| Palette 620 wide, height to content ≤ 440: search / rows / footer | 44 / 40 single-line (56) / 28 |
| Git tab bar / toolbar / panel header / graph header / graph row | 32 / 36 (40) / 28 / 24 (28) / 26 (28) |
| Git sidebar row / file row / section row / hunk / diff line / status bar | 24 / 24 (26) / 28 (30) / 26 (28) / 18 / 24 |
| Cast launcher 750×474 fixed: search / section / row / footer / action row | 56 / 28 / 40 / 36 (40) / 32 |
| Tab header / search strip / titles rows s-m-l | 24 / 30 / 28-34-40 |
Radii: 0 panes, splits, terminals, bars · 4 rows, chips, keycaps · 6 buttons, fields, nav, Cast rows · 8 cards, tiles, popovers, toast · 10 palette, launcher, switcher, dialogs, recorder; macOS window frame 10.
Borders: dividers 1 px borderSubtle; borderStrong on split dividers and overlay edges. Fields bgRaised + 1 px borderSubtle, focused border textMuted (the caret carries the accent). Cards: dark bgPanel, no border; light bgRaised + 1 px borderSubtle.
Elevation: in-window chrome none. **L1** (popovers, Action Panel, toast, HUD): 1 px borderStrong, shadow 16 / y −4. **L2** (palette, launcher, switcher, dialogs): shadow 28 / y −10. No materials (solid fills keep all themes faithful).

## 9. Iconography and app icons
In-app: SF Symbols `.regular`, 13 pt toolbars (24 × 24 hit), 12 pt rows, 11 pt inline (`arrow.triangle.branch` replaces `⎇`). textMuted, hover textPrimary + hover fill radius 4; accent only for an "on" toggle. Window controls (title bars and Tab tile lamps) use the real macOS colors in both modes: #ff5f57 / #febc2e / #28c840.
App icons keep today's glyph geometry: squircle with a flat vertical gradient #26292e → #1b1d21, cream glyphs #cfc8b6 at 85%, **exactly one** flat orange #e8873a part with no glow, ≤ 20% of the glyph area — **except Tab**, whose orange part is the front window card itself (≈ 35%). Glyph live area 560/1024, tile radius 64, strokes 56. Light variant (cool, like Quiet Light): squircle #f4f5f7 → #e4e7eb, glyph #2a2e34, orange #c0550c.
- **Soprano**: three split tiles, top-right orange. **Git**: a three-node lane with one branch curve, HEAD node orange. **Cast**: cream magnifier with a small orange ⌘-keycap tile (today's orange frame dropped). **Tab**: two cream window outlines behind an orange front card with a charcoal ⇥.
- Menu-bar templates: Cast = rounded square with a slanted beam; Tab = two offset squares with ⇥ (outlined default, filled variant).

## 10. Motion
None by default: hover and selection swap instantly. With Reduce Motion off, sidebar toggles animate width 0.12 s ease-out; with it on (Furkan's setting) they are instant. Opacity-only fades stay: toast/HUD out 0.15 s, Tab preview in 0.12 s. The recorder countdown steps per tick. Deleted: clock tick, glow, pulses, CRT, every site animation.

## 11. Per app: the loudest things today → replacement
**Soprano**
1. Stripe + glowing `SOPRANO` + clock → mode chip, breadcrumb `soprano › soprano › Claude Code · tab 1` (pane in textPrimary), counts, usage, plain hints `⌘P commands  ⌃A prefix`.
2. Double rules → single 1 px borderSubtle.
3. Lit blocks (settings nav, palette row, window tab, PREFIX) → row selection + tick, the current-tab idiom, the tinted chip.
4. 2 pt orange frame + 4 pt header bar + glow + blue ring → 1 px accent frame, dim on the others, attention band (never dimmed).
5. Boxed badges `WORKING · RUNNING · 2T · TAB 2` → dot + textMuted `2t · tab 2`; the word only for NEEDS INPUT / ERROR.
Also: TUI boxes and the Codex approval rail drawn as 1 px border / 4 px inset bar (glyphs gap at 17 px lines); dashboard: no color bars, tallies SF Mono 22, attention row = dot + label, `LIVE` = success dot + textMuted label; settings Prefix = `⌃A` keycap, Appearance System / Light / Dark; About: wordmark 22.

**Soprano Git**
1. Solid orange tab → current-tab idiom, `1 soprano`.
2. Orange main lane, glowing nodes, lit HEAD pill → lanes [blue, success, ANSI 5, yellow, cyan, accent, danger, ANSI 12] (main is blue), flat nodes, HEAD = 2 px textPrimary ring; HEAD pill lane @ 16% + 1 px lane border, other pills lane @ 12%; branch chip bgRaised, ↓ yellow.
3. Orange-brown wash on the selected commit → neutral fill + tick; the focused region draws the 1 px accent frame.
4. Boxed toolbar buttons + keycaps → `.plain` buttons `Pull ⌃A P` (key text muted, 16 px gaps); `Commands ⌘P` plain on the right.
5. Hatched fillers, focus bar, glowing banner → flat filler; current hunk = one continuous 2 px accent bar down the left side; long lines soft-wrap with a hanging indent; banner = chipFill(yellow) band (danger with conflicts), Continue primary; toast with danger dot + title; dialogs without stripe, destructive primary = danger fill.

**Soprano Cast**
1. Brown row + orange rail → selection fill, radius 6, no tick; hotkey caps on the selected row.
2. Orange matches + alias → Bold + underline matches; alias textPrimary; placeholders textMuted.
3. Stripe footer → `Soprano Cast` (toast slot) · `Open Application ↵ │ actions ⌘K` as plain text.
4. Solid orange settings tab → nav selection (+ tick while focused); SF Pro 13 labels; dense checkbox columns textMuted-filled (the selected row's stays textPrimary).
5. Square 0.98-alpha panel → bgBase, radius 10, 1 px borderStrong, L2.

**Soprano Tab**
1. Orange wash + frame → 2 px accent ring outset 2 px, radius 10; selected title textPrimary Medium, others textMuted; hovered title textPrimary.
2. Stripe + caps header → `All windows 13`, plain hints `⇥ next  ⇧ back  ↩ open  W close  M min  Q quit  S search`.
3. Glowing lamps → macOS-colored 10 px lamps on a small chip over the thumbnail's top-left (the title keeps its width).
4. Boxed `HIDDEN/MIN/FULL` → lowercase `hidden` chips, bgBase @ 85%.
5. Titles-style wash + rail → selection fill, no tick. Windowless tiles dim to 60%; no-thumbnail icon centered at half height.

**soprano-site**: grain, washes, spotlights, staff rules, playhead, pings, letter-rise, lift → removed; static score panel; `soprano` wordmark 96 px; H2 ui-monospace 600 32/1.15; panels 1 px borderSubtle radius 10, no shadow; Quiet default following `prefers-color-scheme` plus the 7 themes.

## 12. AppKit implementation notes
- **Theme.swift**: `AppTheme` gains `isDark`; delete `missionControl`, add `quietDark` / `quietLight` (§4, §5); `quiet` resolves via `NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])`. Delete `bgSelectedStrong`, `railMuted`, `stripe`; add `selection`, `selectionInactive`, `hover`, `focusRing`, `attention` (hue rule), `attentionBand`, `chipFill(_:)`, `dim`, `scrim`, `kbdEdgeOnFill`, shadow levels, diff tokens.
- **Appearance (all 4 apps)**: delete forced `.darkAqua`; window, popover and alert appearance follow `theme.isDark`; while `quiet`, KVO `NSApp.effectiveAppearance` → `refreshTheme()`. Markdown CSS gets `color-scheme` from the theme.
- **RetroChrome.swift → Chrome.swift** (clean rename, re-vendor into Cast/Tab, Git after it catches up): metrics (hairline 1, radii 4/6/8/10, spacing, controlHeight 24); `ChromeFont.mono/.prose/.keycap/.wordmark`; `RuleView` single only; `StatusDot(.solid/.ring, 6/8/10)`; `ChromeButton(.standard/.plain/.primary/.destructive)`; `ChromeIconButton` (hover textPrimary + fill); `SectionHeader` (no rule); new `KeycapView`, `HintView` (plain key + word), `ModeChip`, `SelectionBackgroundView(isListFocused:)`, `FocusFrameView` (panes **and** Git regions). Delete `RetroStripeView`, glow, double rule, `RetroLamp`.
- **Soprano**: sidebar, tab rows, PaneContainerView (frame + non-hit-testing dim layer, skipped for attention panes), PaneHeaderView (attention band), StatusBarView (drop clock, add hints), right sidebar, diff (flat filler), dashboard, settings (drop CRT), palette (40 px rows, content height ≤ 440, tick).
- **Git**: re-vendor, then tab bar, toolbar `.plain`, regions with `FocusFrameView`, GraphStyle (lane order, no blur, HEAD ring), ref pills, `ChangeKindBadge` (letter on chipFill), DiffRows (no hatch, soft wrap, current-hunk bar), dialogs, toast, welcome, settings.
- **Cast / Tab**: rounded borderless panels (`isOpaque = false`, clear background, content layer radius 10 + `masksToBounds` + 1 px border, `invalidateShadow()`); rows, footer, HUD, settings; TileView outset ring, lamp chip, windowless dim.

## 13. Risks and third-party themes
- *Losing the identity*: kept mono chrome, orange = active, the dot vocabulary, the wordmark, the icon geometry.
- *Focus too quiet in 8 panes at 600×400*: frame + raised header + dim stack; acceptance is the grayscale test.
- *Quiet Light vs a warm light theme*: Quiet Light is cool graphite (#f3f4f5 ground, #1f2328 ink) so it never reads as paper.
- *Accent ≈ attention*: the hue rule switches attention to ANSI 5; frame vs band still separates them.
- *Dark-only third-party themes in system light*: they keep `isDark = true`; only `quiet` follows the system.

| Theme | Under Quiet rules |
|---|---|
| Gruvbox Dark | bgRaised == bgPanel, so the focused header shows no fill change; frame + dim carry focus. |
| Catppuccin Mocha | Purple frame/tick; attention stays blue (hue gap ≈ 50°); bgRaised darker than bgPanel reads sunken, frame still marks focus. |
| Dracula | blue == accent (#bd93f9) → attention = ANSI 5 #ff79c6. |
| Solarized Dark | accent == blue → attention = ANSI 5 #d33682; textPrimary luminance < 0.35 → selection 12%. |
| Nord | accent #88c0d0 within 30° of blue → attention = ANSI 5 #b48ead. |
| Tokyo Night | accent == blue → attention = ANSI 5 #bb9af7. |
| Atom One Dark | accent == blue → attention = ANSI 5 #c678dd. |
Chrome uses only the 16 slots, the derived formulas and ANSI 5; terminal palettes are untouched.
