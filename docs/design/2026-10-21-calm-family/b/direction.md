# Folio — final direction (design B)
Source of truth for the implementation. Mockups: `b/*.html`; tokens: `b/tokens.css`; components and class index: `b/components.css`; specimens: `b/system.html`.

## 1. Name, concept, mood
**Folio.** Each app reads like a well-set page: paper and ink, a serif voice for titles, and one sienna pencil mark wherever the keyboard is.
Mood references: **iA Writer** (ink on paper), **Things 3** (calm macOS density, one quiet accent), **Stripe Press** (warm paper, serif heads, hairlines).
Paper (light) is the primary appearance. Ink (dark) is its counterpart. Both are first-class.

## 2. Principles (each testable on a screenshot)
1. **One pencil mark.** Accent appears only on: the keyboard-focus mark (pane-header rule, pencil tick, Tab tile ring); the caret and the focused terminal cursor; matched characters on the **selected** row; a non-NORMAL mode chip and the Prefix / ⌃-jump keycap
   Nothing is filled with accent except the terminal cursor. In Ink, even the focused selection fill is neutral.
2. **Ink is chrome, color is meaning.** Color appears only for status, diff, change kinds, graph lanes and syntax, and each always carries a shape or letter too. A grayscale screenshot loses nothing.
3. **Hairlines, not boxes.** Regions are separated by one 1 px rule or by space. No double rules. Cards appear only in Settings and detail panes.
4. **Serif speaks, sans works.** New York only for titles, headlines, figures and empty states, and only at ≥ 15 px. SF Pro and SF Mono for everything you scan or type. Uppercase only for eyebrows and status labels.
5. **Quiet until needed.** Idle panes and rows carry no color. Only attention, NEEDS INPUT and ERROR add a frame or a wash.
6. **Native skeleton.** Traffic lights on the left, with real macOS colors; macOS radii: 12 / 10 / 8 / 6 / 4; Opaque surfaces; Reduce Motion means no animation.

## 3. Mission Control → Folio
| Item | Verdict | Folio |
|---|---|---|
| Departure Mono, small caps | Remove | SF Pro Text for chrome, New York for titles ≥ 15 px. Delete the woff2, its licence and `RetroFont.display`. |
| Single rules | Keep | 1 px `borderSubtle` between regions; `borderStrong` only on control edges, keycaps and splitters. |
| Double rules | Remove | One 1 px rule, or 8 px of space. |
| Racing stripe | Remove | Removed everywhere. |
| Lamps, glow | Change | Flat 8 px status marks (ring, dot, diamond). No text or colored shadows anywhere. |
| CRT shader | Remove | Delete the shader, the setting and its Settings row. |
| Lit blocks | Remove | Raised paper tab, selection pill + pencil tick, outlined chip, or ink button (§6). |
| Mission clock | Remove | Opt-in only: `statusBar.uptime` shows `Up 2:14:07`, muted and tabular. |
| Square corners | Change | 12 floating panels · 10 popovers, toasts, windows · 8 cards, tiles · 6 controls, pills, tabs · 4 keycaps, chips · tiled panes stay 0. |
| Orange everywhere | Change | Sienna only for the marks in principle 1. Primary buttons are ink. |
| Density | Keep | Data rows keep today's heights. Chrome loses its boxes. |

## 4. Color
| Slot | Paper | Ink | Role |
|---|---|---|---|
| bgBase | #f6f2ea | #1d1b18 | window, terminal, reading surfaces |
| bgPanel | #ede7db | #181613 | sidebars, bars, status bar, unfocused headers |
| bgRaised | #fcfaf5 | #26231f | focused header, selected tab, cards, fields, overlays, palette, launcher, switcher |
| bgOverlay | #e5dece | #2f2b26 | hover, off-switch track |
| textPrimary | #2b2620 | #e2dacb | ink: text, ink buttons, HEAD pill |
| textMuted | #62594d | #a0968a | secondary text, icons, eyebrows, gutter, unselected Tab titles |
| accent | #a34a17 | #e08a52 | sienna pencil |
| accentStrong | #863a0f | #f0a774 | match on the selected row |
| borderSubtle | #e0d8c9 | #322e29 | rules, cards, separators |
| borderStrong | #cbc0ad | #443e37 | control edges, keycaps, splitters, switch edge |
| success | #456b30 | #97ae76 | WORKING, +, A |
| danger | #ae2f3c | #e0707a | ERROR, −, D, destructive |
| blue | #2f5f8a | #86a6cb | READY, attention, SELECT |
| cyan | #266b66 | #74b3a9 | RUNNING, R/C, types |
| yellow | #835f0b | #d6aa4f | STARTING, NEEDS INPUT, M, usage ≥ 70 % |
| gray | #857c6e | #776f64 | STOPPED, ignored, idle dot |

**Derived tokens** (formulas over the 16 slots, so third-party themes inherit them):

| Token | Paper | Ink |
|---|---|---|
| selection (focused list) | accent @ 12 % (sienna wash) | **textPrimary @ 11 %** (neutral ink fill; never Mission Control brown) |
| selectionMuted (unfocused list) | textPrimary @ 6 % | textPrimary @ 7 % |
| pencilTick | accent, 2×14 px, radius 1, `--tick-inset` 4 px inside the pill | same |
| focusMark | accent, 2 px rule | same |
| attention | blue; yellow when hue distance(accent, blue) < 40° | same rule |
| attentionWash · statusWash | colour @ 10 % | same |
| unfocusedVeil | **bgPanel, multiply blend** (the page sinks; ink keeps ≈ 11 : 1) | **black @ 18 %**, normal blend |
| diff add / word | **#5f8f3a @ 16 % / 30 %** (success @ 12 % read gray on paper) | success @ 16 % / 28 % |
| diff del / word | danger @ 10 % / 22 % | same |
| diff filler | textPrimary @ 3 % | same |
| textSelection | accent @ 22 % | same |
| glyphTile | bgOverlay | textPrimary @ 9 % over bgRaised |
| switchKnobOff | bgRaised | textMuted (a bgRaised knob vanishes on Ink cards) |
| inkButton | fill textPrimary, label bgRaised, pressed 85 % | same |
| raised | bgRaised; if contrast(bgRaised, bgPanel) < 1.05, mix 5 % textPrimary into bgPanel | same |
| scrim · e2 · e3 | `#2b2620 @ .20` · `0 6 18 rgba(43,38,32,.12)` · `0 12 36 rgba(43,38,32,.16)` | `#000 @ .45` · `0 8 24 rgba(0,0,0,.40)` · `0 14 40 rgba(0,0,0,.55)` |

**Contrast:** textPrimary: Paper 13.4 on bgBase, 12.2 on bgPanel; Ink 12.4 and 13.0. · textMuted: Paper 6.2 and 5.6; Ink 5.9 and 6.2. · On selection: Paper: ink 10.3, muted 4.75, accentStrong 5.5; Ink: ink 10.0, muted 4.8, accentStrong 7.0. · Status colors are ≥ 4.7 on base, panel and raised.

## 5. Terminal palettes
| | bg | fg | cursor | selection | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Paper | #f6f2ea | #2b2620 | #a34a17 | #e4cdbc | #2b2620 | #ae2f3c | #456b30 | #835f0b | #2f5f8a | #8a3f78 | #266b66 | #6f665a |
| Ink | #1d1b18 | #e2dacb | #e08a52 | #483325 | #2a2622 | #e0707a | #97ae76 | #d6aa4f | #86a6cb | #c191b8 | #74b3a9 | #cfc6b5 |

| | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---|---|---|---|---|---|---|---|
| Paper | #5a5248 | #c0414a | #557f3b | #9a7212 | #3d72a3 | #a04f8d | #2f817b | #8f8678 |
| Ink | #7d7469 | #ec8f97 | #b0c592 | #e8c272 | #a3bfdf | #d5aacd | #93c9bf | #f4efe5 |

- Paper follows the GitHub-Light convention: 7 and 15 are mid-grey. · Faint (dim) text = 66 % of fg mixed toward bg (Paper 4.7 : 1, Ink 6.1 : 1). · Cursor: the focused pane shows an accent block. Unfocused panes, including any pane behind an overlay, show a hollow cursor: 1 px outline in fg @ 55 %, no accent. · Default font: SF Mono 13 / 17.

## 6. Status, attention, focus, selection
Marks are 8 px and flat. Ring stroke is 2 px; the diamond is a 6 px square rotated 45°. Labels are SF Pro Text 11 Semibold UPPERCASE, +0.4 tracking, in the status colour.
| State | Colour | Mark | Pane-header wash |
|---|---|---|---|
| STARTING | yellow | ring | — |
| WORKING | success | dot | — |
| RUNNING | cyan | dot | — |
| READY | blue | ring | — |
| NEEDS INPUT | yellow | dot | yellow @ 10 % |
| ERROR | danger | diamond | danger @ 10 % |
| STOPPED | gray | ring | — |
| idle shell | gray @ 60 % | 6 px dot, no label | — |

- **Aggregate badges** follow the order error > waiting > running > starting > idle. A badge is an unboxed mark plus a tabular count (`● 3`). · **Focused pane:** The header is `raised`, the title is ink Medium, and a 2 px accent rule sits on the header's bottom edge; Every other pane is `.is-dimmed` and gets the veil. In 8 panes at 600×400, exactly one pane is unveiled; Behind an overlay (palette, dashboard), the window keeps the raised header but loses the accent rule, and its cursor turns hollow. · **Attention pane:** A full 2 px frame in `attention`; **Never veiled**; the CSS guards this even if `.is-dimmed` is set; The header keeps one status mark only. The attention dot is dropped, because the frame already says "attention". The NEEDS INPUT and ERROR wash wins over the attention wash. · **Attention elsewhere:** Pane tab: `● ` prefix in attention; Sidebar count: `3 · 1!`; Status bar: `1 needs you`. · **Attention row in lists** (`.row.is-attention`, used by the dashboard, the site and the specimens): a blue 2×14 tick plus a full-bleed attention @ 6 % wash. It has no pill and no radius, so it never reads as selected. · **List selection:** In the focused list, the selected row is a 6 px-radius pill (4 px inset) in `selection`, with the pencil tick 4 px inside its left edge; In unfocused lists it is `selectionMuted` with no tick; Selection never shifts row content horizontally. · **Matches:** Semibold everywhere. Accent appears **only on the selected row** (`accentStrong`); other rows' matches are ink. Applies to palette, launcher, menu, table and list. · **Git region focus:** a 2 px accent rule under the focused `.panel-header` or `.pane-toolbar`. · **Tab tile:** the selected tile gets a 2 px accent ring, outset 3 px, and an ink Medium title. Hovered tiles have an ink title; all other titles are muted. · **Fields:** accent caret on a borderStrong edge, never an accent border.
**Selection idioms**

| Today | Folio |
|---|---|
| Lit block on tabs and settings nav | Raised tab: `raised` 6 px pill, 1 px borderSubtle, ink Medium. Soprano layout tabs have no index; Git repo tabs show a muted index (`1  soprano`). |
| Lit block on palette, launcher and choose rows | Selection pill + pencil tick |
| Lit PREFIX / COPY chip | 18 px outline chip, accent border and label. SELECT uses blue. NORMAL is muted text with no border. |
| ⌃ jump numbers, Prefix keycap | Keycap with accent legend and border (`.kbd-accent`; `.kbd-field` for the 24 px settings control) |
| Lit prominent button | Ink button. Destructive buttons use a danger fill. |
| Pane-tab underline | Ink underline, 2 px |
| Lit HEAD pill | Ink pill (textPrimary fill) with ✓ |

## 7. Type
| Role | Family | px / weight / line-height / tracking |
|---|---|---|
| Hero (About, Welcome) | New York | 30 / 400 / 36 / −0.4 |
| Screen title (Settings, Dashboard, Cast pages, Extensions) | New York | 22 / 400 / 28 / −0.2 |
| Headline (dialog, commit subject, detail title) | New York | 17 / 500 / 22 |
| Empty state | New York Italic | 17 / 400 / 22, muted |
| Figures (dashboard) | New York, tabular | 26 / 400 / 30 |
| Launcher query | SF Pro Display | 20 / 400 / 26 |
| Palette query | SF Pro Text | 15 / 400 / 20 |
| Row title | SF Pro Text | 13 / 400 / 18 |
| Chrome label | SF Pro Text | 12 / 400 (500 when selected) / 16 |
| Meta, hints | SF Pro Text | 11 / 400 / 14, muted |
| Eyebrow | SF Pro Text | 11 / 600 / 14 / +0.6, UPPERCASE, muted, no trailing rule |
| Status label | SF Pro Text | 11 / 600 / 14 / +0.4, UPPERCASE |
| Keycap | SF Pro Text | 11 / 500; cap 18 px (16 px in hints rows), min-width 18, radius 4 |
| Mono | SF Mono | 12 / 18; SHAs, dates and line numbers 11 / 14 |
| Markdown reader | New York 16 / 26 | h1 28, h2 21 + 1 px rule; code in SF Mono 13; 920 px column |

- All fonts ship with macOS. Serif is `NSFontDescriptor.SystemDesign.serif`. · The HTML mockups embed New York and SF Mono via `shared/system-fonts.css`, because Chrome can't reach them by name. · 1x rules: nothing below 11 px, no Light or Thin weights, serif only at ≥ 15 px, `backingAlignedRect` for every frame.
**Keycaps (K1)** One cap per chord step: modifiers + key go in one cap (`⌘1`, `⇧⌘P`, `⇧⌘D`, `⌃A`). · A prefix sequence is separate caps in a group: `⌃A` then `P`; `⌃A` then `⇧P`. · Single keys are one cap (`↵`, `esc`). · Letter legends are uppercase (`J`, `K`, `V`, `Y`, `⇧J`). Named keys stay lowercase (`esc`).

## 8. Space and shape
- Spacing scale: 2 · 4 · 8 · 12 · 16 · 24 · 32 · 48. · Insets: 12 in bars, 16 in panels, 24 for page gutters.

| App | Heights (px) |
|---|---|
| Soprano | titlebar 28 · tab rows 32 (pill 24) · sidebar header 32 · window row 28 · pane row 40 (two lines; `2T` on the branch line) · pane header 28 (pane tabs 22) · status bar 26 · right header 32 · tree rows 24 · pane toolbar 32 · overlays (Dashboard and Settings both): 28 titlebar + 56 header with serif title and `Done esc` · agent rows 52 · settings nav 30 · settings rows ≥ 36 · palette 620 wide, top ≥ 100, search 44, rows 44, footer 28 |
| Git | tab bar 36 (traffic inset 78) · toolbar 38 · panel headers 28 · refs 24 · graph 28 · files 26 · sections 28 · hunk header 26 · diff lines 18 · banner 36 · status bar 26 |
| Cast | launcher 750×474, top at 1/5 below the menu bar · search 56 · section 26 · rows 40 · footer 40 · Action Panel rows 30 · settings window 1120×700 content + 28 titlebar; title, count and search share one 52 px bar · table head 26 · group 28 · row 32 |
| Tab | header 28 · tile title 22 · title rows 28 / 34 / 40 · search strip 30 · tile gap 8 |

- Borders are 1 px only. · Elevation: e0 flat; e2 popovers, toasts, HUD; e3 palette, launcher, switcher. · Materials: everything opaque, no `NSVisualEffectView`. The switcher panel sits on `raised`, so it separates from same-coloured windows behind it.
**Controls** Buttons: 24 px tall, 6 px radius. Standard = raised fill with a borderStrong edge. Primary = ink. Danger = danger fill. Plain = borderless text button. · Switch: 26×16; Off: bgOverlay track, borderStrong edge, `switchKnobOff` knob; On: ink track, bgRaised knob. · Checkbox: 14 px. Checked = ink fill with tick. Inside dense tables it is an outline with an ink tick. · Segmented control: raised active segment.

## 9. Iconography and app icons
**UI icons** SF Symbols, Regular weight: 13 px in 24 px toolbar boxes, 12 px in rows, 16 px in Cast glyph tiles (24 px, radius 5, `glyphTile` fill). · Muted at rest, ink on hover. Toggled-on = raised pill, never accent. · Menu-bar templates are 16 px with 1.5 px strokes. Cast and Tab glyphs are in the class index under `.tpl`.
**App icons** (`b/icons/<app>.svg` and `<app>-dark.svg`) Paper squircle (#f3eee4 → #e9e2d4), ink #2b2620 glyph, 48 px stroke at 1024 (Cast magnifier 32). · Exactly one sienna #a34a17 element per icon: Soprano: three sheets, the top-right one filled; Git: three ink ring nodes on a trunk, plus a filled branch-tip node; Cast: a search-bar outline with a magnifier, plus the caret; Tab: two offset sheets, plus the ⇥ arrow. · Ink variant: squircle #2a2622 → #1a1815, glyph #e2dacb, mark #e08a52.

## 10. Motion
- Under Reduce Motion (Furkan's setting), every duration is 0. · Otherwise: overlays fade over 120 ms (opacity only), sidebar 150 ms, HUD fade 200 ms, Tab preview 120 ms. · No hover transitions, pulses, glows or blinking chrome. Elapsed timers tick at 1 Hz as text only.

## 11. Per app (as shown in `b/*.html`)
**Soprano** **Panes:** focus as in §6. The Codex attention pane is framed, unveiled, and carries one NEEDS INPUT dot with a yellow header wash. · **Sidebar:** single rule; Pane rows: mark + title (`zsh · swift build`, command muted) + status word; the branch line carries `· 2T`; Pencil tick on the focused pane row. ⌃ held shows keycaps. Footer: Saved Workspaces · Agent Dashboard · Settings icons. · **Layout tabs:** raised pill with no index, plus an unboxed badge. · **Status bar:** Left: NORMAL chip, then `session › window › pane · Tab 1`; Right: muted counts with `1 needs you` in attention, usage (yellow ≥ 70 %), then `⌘P Commands` and `⌃A Prefix` hints. · **Palette:** Raised panel, radius 12, e3; top ≥ 100; Rows: icon, title, description. Selected row = pill + tick, with accent `Open` only on that row; Footer: `N results` + `↑↓ Navigate  ↵ Run  esc Close`. · **Dashboard:** Header: serif title, subtitle, `Done esc`. Four unboxed New York figures, muted at 0; Agent rows (`.agent`): selected = pill + tick; attention = A1 idiom; Detail panel: TIMELINE heading with hints `⇧J ⇧K Scroll · [ ] Turn · O Details · G Live · T Terminal` and `LIVE`; A `now` strip under the heading; Diff blocks use the diff tokens; Reply field + ink Send. · **Settings:** Same overlay chrome as the Dashboard. Raised nav; the content column sits 48 px from the nav; Eyebrow sections over cards. Switches per §8. Prefix key = `.kbd-field.kbd-accent` showing `⌃A`; Appearance control: System / Light / Dark. No CRT row.
**Soprano Git** **Repo tab:** `1  soprano`. · **Toolbar:** borderless text buttons with sequence keycaps (`⌃A` `P`, `⌃A` `⇧P`, `⌘B`), and a raised branch chip `⎇ main ↑0 ↓0`. · **Graph:** Graphite trunk (lane 0); lanes 1–7 = blue, success, ANSI 5, cyan, yellow, ANSI 13, ANSI 12. Never accent; 8 px nodes; HEAD gets a 12 px ink ring; merge = ring; stash = square; WIP = dashed; Ref pills: lane @ 10 % with a lane border. HEAD is an ink pill. · **Commit panel:** New York 17 subject; Muted sentence-case meta; Bare coloured change letters; Diffstat zeros are muted; Paths truncate at a path component. · **Diff:** Green or pink line washes plus word emphasis; Semibold ± markers; Full-muted gutter; The current hunk gets a 2×14 tick in the gutter of its first changed row; Fillers are flat (no hatch); Syntax: keywords ink Semibold, strings success, comments muted italic, numbers and attributes yellow, types cyan, functions blue. · **Toolbar keycaps:** Previous `K`, Next `J`, Split/Inline `V`, Close `esc`. · **Dialogs and toasts:** serif dialog title; toasts radius 10, e2.
**Soprano Cast** **Launcher:** Raised panel, radius 12, e3; SF Pro Display 20 query; Selected row = pill + tick + `⌘1` keycap; Built-in commands sit on glyph tiles; Footer: glyph + `Soprano Cast` · `Open Application ↵` | `Actions ⌘K`. · **Settings:** Raised nav. `Extensions` serif title + `79 commands` + search in one bar; Table: eyebrow column heads, all 14 app rows, the table scrolled to the top with a scroll thumb, quiet checkboxes. Detail pane with a serif title.
**Soprano Tab** **Switcher:** Raised panel; header `All windows · 13` with keycap hints; Tiles: bgPanel, radius 8; titles muted, ink when hovered, ink Medium when selected; Selected tile: accent ring; Chips: `Minimized` / `Hidden` / `Full screen` / Space; Windowless tiles are dimmed. · **Hover window controls:** 12 px circles in the **real macOS traffic colours**, on an opaque raised corner chip over the thumbnail (`.thumb-lamps`), so the title keeps its full width. · **Backdrop windows** follow the page mode. · **Menu bar:** `Soprano · Edit · Commands`, with the Cast and Tab template glyphs.
**soprano-site** Folio Paper by default; Ink via `prefers-color-scheme`. · The theme switcher offers Folio plus the 7 themes. · Removed: grain, drift, spotlight and sweep. One 1 px rule replaces the staff rule. · Flat raised panels; §6 marks; ink primary button. · Attention uses the A1 row idiom. · A "family" section shows the four icons.

## 12. AppKit implementation
**`RetroChrome.swift` → `Chrome.swift`** (no aliases) `Metrics`: hairline 1; radii 12 / 10 / 8 / 6 / 4; tickInset 4; spacing scale. · `ChromeFont.title / sans / mono / eyebrow / status`. · `ChromeButton.standard / ink / danger / text` and `ChromeIconButton`. · `EyebrowView`. · `StatusMark.dot / ring / diamond`. · `KeycapView`: renders K1 chords and sequences. · `ModeChip`. · `SelectionPill(focused:, attention:)`: draws the pill and the tick; attention = tick + full-bleed wash. · `ChromeSwitch`.
Delete: stripe, double rules, glow, small caps, Departure Mono and its font shims, CRT.
**Unfocused-pane veil:** Paper: a `CALayer` filled with bgPanel, `compositingFilter = "multiplyBlendMode"`. · Ink: black at 18 %. · Never added to attention panes.
**`Theme.swift`** `AppTheme.appearance` (`.light` / `.dark`). · New themes `folioPaper` and `folioInk`. `folio` (default) follows `NSApp.effectiveAppearance`; pinned ids are `folio-paper` and `folio-ink`. · `mission-control` is deleted; unknown ids fall back to `folio`. · Derived tokens as in §4, including the per-mode `selectionTint`, `veil`, `diffAddTint`, `switchKnobOff` and `glyphTile`. · `window.appearance` comes from the theme. Markdown CSS follows the theme.
**Per view** **Soprano:** `PaneContainerView`, `PaneHeaderView`, `StatusBarView`, `SidebarView`, the tab bars, `RightSidebarView`, the palette, the dashboard and Settings. · **Git** (re-vendor first): `GraphStyle`, `PanelHeaderView`, toolbar, `ChangeKindBadge`, the diff renderer and its syntax map. · **Cast:** launcher panel (rounded, shadowed), rows, footer, Action Panel, recorder, HUD, Settings. · **Tab:** header, `TileView` (ring, chips, corner-chip lamps in system colours), search strip.
Land the changes in Soprano first, then vendor them to the siblings.

## 13. Third-party themes and risks
- All 7 keep `appearance = .dark` and inherit every formula. · **Accent ≈ blue** (Solarized, Dracula, Nord, Tokyo Night, Atom One): attention switches to yellow, and the shapes still differ (underline + veil vs frame). · **bgRaised = bgPanel** (Gruvbox, Solarized): `raised` mixes 5 % ink into the panel colour. · **Focused selection** is neutral in every dark theme (textPrimary @ 11 %), and the theme's accent is used only for ticks and marks. · **Risks:** The habit "orange = active" still holds: accent marks exactly the active place; The veil keeps background agents readable (multiply in Paper; ≥ 8 : 1 under the Ink veil); Serif is used only at ≥ 15 px; Folio is the first light theme. Check the Markdown CSS, the diff tints and NSAlert in Paper before shipping.
