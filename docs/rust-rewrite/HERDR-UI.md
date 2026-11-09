# Herdr UI spec

This spec is for rebuilding Herdr's desktop UI natively in Rust with GPUI. The shipped look comes from the main layout plus the JS mods it loads. The default dark theme is **graphite**; the default light theme is **paper**.

## 0. Conventions and sources

| Key | File (under `/tmp/herdr-app/`) |
|---|---|
| `L` | `defaults/layouts/main.json` |
| `S` | `src/settings.rs` (theme derivation, fonts, defaults) |
| `W` | `src/window.rs` (frames, overlays, separators) |
| `TB` | `src/window/titlebar.rs` |
| `PS` | `src/window/pane_size.rs` |
| `PD` | `src/window/pane_drag.rs` |
| `T` | `src/terminal.rs` |
| `M/<mod>` | `defaults/mods/<mod>/main.js` |
| `PAL` | `defaults/frame/palette/main.js` |
| `SB` | `vendor/gpui-kit/crates/base/src/scrollbar.rs` |

**Units**
- Every number is a logical px at zoom 1.
- Herdr multiplies every length by `zoom`: `S:757` `z(v) = px(v*zoom)`. Mod lengths are scaled the same way via `gpui_shell::set_pixel_scale(zoom)` in `S`'s `set()`.
- Zoom range is 0.5–3.0 in 0.1 steps.
- GPUI rem is set to `ui_font_size × zoom` = **13 px** (`W:4873`). So `text_xs` = 0.75 rem = 9.75 px, `rounded_md` = 0.375 rem ≈ 4.9 px, and `top_2`/`right_2` = 0.5 rem = 6.5 px. These follow GPUI's Tailwind rem scale [INFERENCE: GPUI conventions].

**Line height:** no mod sets `line_height`, so all UI text uses GPUI's default `phi()` = 1.618 × font size (`vendor/gpui-pre/src/style.rs:494`). Examples: 13 px → 21 px line, 12.8 → 20.7, 11.5 → 18.6.

**Weights:** `font_medium` = 500, `font_semibold` = 600, `font_bold` = 700 (`vendor/gpui-kit/crates/shell/src/style.rs:368-370`).

**Alpha suffixes:** colors written as `t.X + "26"` (or `"18"`) are `#rrggbbaa`. `0x26` = 38/255 ≈ **15 %**; `0x18` = 24/255 ≈ **9.4 %**.

**Hover and press:** hover fills switch instantly. Mods define no transitions.

---

## 1. Window and title bar

| Item | Value | Source |
|---|---|---|
| Title bar | `"titlebar": "none"`: the layout draws its own; macOS window is transparent-titlebar | `L:4`, `src/main.rs:214-218` |
| Traffic lights (macOS) | origin **x 12, y 16** (layout value; app default without a layout is 12, 7) | `L:5-8`, `TB:26,56` |
| Traffic-light footprint | 64 px wide: the three buttons plus breathing room | `W:36` |
| Window drag regions | the `brand` row (sidebar top, 46 px) and the `tabs` row (42 px). Double-click calls `titlebar_double_click` (zoom). Drag starts after a small threshold. A mod's own buttons opt out with `stop_propagation` on mouse-down | `L:36,95`, `TB:~88-118` |
| System strip (only when `titlebar: system`) | 28 px drag strip | `TB:23,135` |
| Root background | `canvas` (shows through gaps in the work body) | `L:9`; `W:4912-4919` paints `background` first, then the layout look |
| Root text | `foreground`; font family `ui_font_family` = **Geist** | `W:4918-4919`, `S:525` |
| Divider between sidebar and work | **1 px**, color `border`, full height (no traffic-light inset at a 268 px sidebar) | `L:14-17`, `W:38-62,4228-4243` |
| Resizable | sidebar and work: `resizable: false` (no drag handle). The panel has min/max but no handle in this layout. A handle hit area, where one exists, is 6 px | `L:28,87`, `W:33` |

Divider inset rule (`W:38-62`): if the sidebar's right edge falls between `traffic_lights.x` and `x + 64` (i.e. the 76 px collapsed rail), the divider starts below the 46 px toolbar. The toolbar strip then reads as one continuous band.

---

## 2. Color tokens

### 2.1 How the tokens are derived (`S:306-367`)

```text
bg    = palette.background
light = luminance(bg) > 0.5           # 0.2126 R + 0.7152 G + 0.0722 B   (S:265-268)
fg    = light ? #1b1b1e : #eeeeef      # UI text, NOT the terminal fg     (S:309)
mix(a, b, t) = round(a·(1−t) + b·t) per channel                         (S:293-298)
[working, blocked, done] = preset.status ?? [ansi3, ansi1, ansi4]        (S:310)
```

| Token | Dark formula | Light formula |
|---|---|---|
| `background`, `surface` | `bg` | `bg` |
| `terminal_foreground` | `palette.foreground` | same |
| `foreground`, `solid` | `fg` | `fg` |
| `canvas` (behind cards) | `mix(bg, #000, 0.16)` | `mix(bg, #e8e8e2, 0.2)` |
| `chrome` (sidebar and bars) | `mix(bg, #000, 0.32)` | `mix(bg, #e8e8e2, 0.6)` |
| `popover` | `mix(bg, #fff, 0.06)` | `bg` |
| `raised` | `mix(bg, #fff, 0.09)` | `mix(bg, #000, 0.035)` |
| `hover` | `#ffffff0e` (5.5 % white) | `#0000000c` |
| `selected` | `#ffffff17` (9.0 %) | `#00000012` |
| `border` | `#ffffff18` (9.4 %) | `#00000017` |
| `input` | `#ffffff24` (14 %) | `#00000026` |
| `muted` (secondary text) | `mix(bg, fg, 0.60)` | `mix(bg, fg, 0.66)` |
| `dim` (tertiary text) | `mix(bg, fg, 0.38)` | `mix(bg, fg, 0.46)` |
| `idle`, `unknown` | `mix(bg, fg, 0.38)` | `mix(bg, fg, 0.38)` |
| `accent` | `ansi4` | `ansi4` |
| `accent_foreground` | `bg` | `bg` |
| `solid_foreground` | `mix(bg, #000, 0.28)` | `#ffffff` |
| `ring` | `mix(bg, fg, 0.7)` | same |
| `selection` | `palette.selection` | same |
| `cursor` | `palette.cursor ?? palette.foreground` | same |
| `ansi0..15` | palette | palette |

Overrides (theme-file `colors`, settings.json `colors`, layout `colors`) replace any key afterwards (`S:362-365`, `S:compose`).

The same tokens are mapped onto gpui-kit component tokens (`src/mods.rs:1122-1132`):

| gpui-kit token | Herdr token |
|---|---|
| `primary` | `accent` |
| `secondary` | `raised` |
| `muted` | `raised` |
| `muted_foreground` | `muted` |
| `accent` | `hover` |
| `destructive` | `blocked` |
| `ring` | `ring` |

### 2.2 Graphite: default dark (`S:30-41`)

Palette:
- background `#17191d`
- terminal fg `#d2d4d9`
- selection `#394454`
- status `[working #e5c07b, blocked #f0705f, done #76a8ff]` (`S:30`)

| Token | Hex | Notes [computed] |
|---|---|---|
| background / surface | `#17191d` | terminal and card background |
| canvas | `#131518` | behind cards (work-body gaps) |
| chrome | `#101114` | sidebar, tab row, status bar |
| popover | `#25272b` | menus, dialogs, toasts |
| raised | `#2c2e31` | active tab pill, keycaps, secondary buttons |
| hover | `#ffffff0e` | ≈ `#1d1e21` on chrome |
| selected | `#ffffff17` | ≈ `#262729` on chrome |
| border | `#ffffff18` | ≈ `#27272a` on chrome, `#292b2e` on canvas, `#2d2f32` on background |
| input | `#ffffff24` | input/secondary-button borders, agent tree lines |
| foreground | `#eeeeef` | UI primary text |
| terminal_foreground | `#d2d4d9` | terminal default fg |
| muted | `#98999b` | secondary text |
| dim | `#696a6d` | tertiary text and icons |
| idle / unknown | `#696a6d` | |
| accent | `#96b2d7` | focus ring, input focus, fuzzy hits |
| accent_foreground | `#17191d` | |
| solid | `#eeeeef` | primary button fill |
| solid_foreground | `#111215` | primary button text |
| ring | ≈ `#aeaeb0` | ±1 on R from rounding |
| selection | `#394454` | |
| cursor | `#d2d4d9` | |
| working | `#e5c07b` | |
| blocked | `#f0705f` | |
| done | `#76a8ff` | |

Graphite ANSI 0–15 (`S:38-41`):

```text
#45484f #dc8c95 #a6bd91 #d8be87 #96b2d7 #b5a2ce #8cbdc3 #d2d4d9
#818793 #f0a5ad #bad5a2 #ead2a1 #b0cbef #cbb7e6 #a4d5db #f0f0f2
```

### 2.3 Paper: default light (`S:68-77`)

Palette: bg `#ffffff`, terminal fg `#25272c`, selection `#cfdcf5`, cursor `#25272c`, status `[#9a6700, #c93c2c, #2f6fe4]`.

| Token | Hex [computed] |
|---|---|
| background | `#ffffff` |
| canvas | `#fafaf9` |
| chrome | `#f1f1ee` |
| popover | `#ffffff` |
| raised | `#f6f6f6` |
| hover | `#0000000c` |
| selected | `#00000012` |
| border | `#00000017` |
| input | `#00000026` |
| foreground / solid | `#1b1b1e` |
| muted | `#69696b` (B ±1) |
| dim | `#969698` (B ±1) |
| idle | `#a8a8aa` |
| ring | `#5f5f62` |
| accent | `#1f62d0` |
| accent_fg | `#ffffff` |
| solid_fg | `#ffffff` |
| working | `#9a6700` |
| blocked | `#c93c2c` |
| done | `#2f6fe4` |

Paper ANSI (`S:74-76`):

```text
#25272c #c62a2a #1a7f37 #8f5d00 #1f62d0 #7a45c8 #0f6f74 #5f6068
#7b7e87 #d1242f #1f883d #9a6700 #0969da #8250df #1b7c83 #111214
```

### 2.4 Other built-in themes [computed from `S:43-66`, `defaults/themes/atom-one-dark.json`]

| Theme | bg | canvas | chrome | popover | raised | accent | status (w/b/d) |
|---|---|---|---|---|---|---|---|
| ink | `#111720` | `#0e131b` | `#0c1016` | `#1f252d` | `#262c34` | `#91b6ee` | DARK_STATUS |
| moss | `#151c19` | `#121815` | `#0e1311` | — | — | `#99b9cd` | DARK_STATUS |
| atom-one-dark | `#21252b` | `#1c1f24` | `#16191d` | — | — | `#61afef` | `#e5c07b` / `#e06c75` / `#61afef` |

- Theme selection: settings `appearance` (system / light / dark) picks `theme_light` or `theme_dark`. Defaults are paper and graphite (`S:82-83,546-568`).

### 2.5 Fixed (non-theme) colors

| Use | Value | Source |
|---|---|---|
| Space avatar fills (by stored name) | ansi6 `#22a99a`, ansi3 `#e3814f`, ansi4 `#5b8def`, ansi5 `#8b7cf6`, ansi2 `#3fae6a`, ansi1 `#d9649a`. Assigned in order `[ansi6, ansi3, ansi4, ansi5, ansi2, ansi1]`, least-used first. The `~` space gets none, so the spaces list falls back to ansi6 teal | `M/spaces:39,459-466,410-412` |
| Avatar letter | `#ffffff` | `M/spaces:431` |
| Dialog backdrop | `hsla(0,0,0,0.35)` | `W:4362` |
| Win close hover (Windows only) | `#c42b1c` | `TB:267` |
| Program tiles | `defaults/programs.json`, e.g. shell tile `#16241a`, glyph `#4ec95f`. Not used by the main layout | `programs.json:29` |

---

## 3. Typography

| Role | Family | Size | Weight | Color | Source |
|---|---|---|---|---|---|
| UI default (rem) | Geist | 13 | 400 | foreground | `S:525-526`, `W:4873,4919` |
| Brand "Herdr" | Geist | 13.5 | 600 | foreground | `M/workspace-chrome:48,50` |
| Section headers "Spaces" | Geist | 11.5 | 400 | dim | `M/spaces:469` |
| Section header "Agents" | Geist | 11.5 | 500 | dim | `M/agents:426` |
| Space row name | Geist | 13 | 400 | foreground | `M/spaces:468,432` |
| Space avatar letter | Geist | 10.5 | 700 | #fff | `M/spaces:431` |
| Space git tail | Geist | 11.5 | 400 | dim / ansi2 / ansi1 | `M/spaces:373-377` |
| Machine group header | Geist | 11 | 400 | dim | `M/spaces:322` |
| Agent row name | Geist | 13 | 400 | foreground (muted when idle and unfocused) | `M/agents:415,359` |
| Agent group header | Geist | 11 | 500 | status color or dim | `M/agents:379-397` |
| Agent age ("5m") | Geist | 11 | 400 | dim | `M/agents:364` |
| Sub-agent row | Geist | 12.5 | 400 | muted / fg | `M/agents:184-199` |
| "Needs you" pill | Geist | 10.5 | 600 | blocked | `M/agents:208` |
| Agents empty text | Geist | 12 | 400 | dim | `M/agents:440` |
| Sidebar footer rows | Geist | 13 | 400 | muted / dim | `M/workspace-chrome:36-46` |
| Tab label | Geist | 12.8 | 400 | fg active / muted inactive | `M/tabs:58-59` |
| Panel toggles (Files / Changes) | Geist | 12 | 400 | fg on / muted off | `M/tabs:84-85` |
| Pane header name | Geist | 12 | 500 | foreground | `M/pane:78,82` |
| Pane header cwd | Geist | 12 | 400 | dim | `M/pane:83` |
| Status bar | Geist | 11.8 | 400 | muted (hint: dim) | `M/workspace-status:23,29` |
| Files/Changes panel title | Geist | 13 | 600 | foreground | `M/files:169-172`, `M/changes:186-187` |
| Panel header right label | Geist | 12 | 400 | dim | `M/files:173` |
| Tree rows | Geist | 13 | 400 | foreground | `M/files:169,159` |
| Menu / palette rows | Geist | 12.8 | 400 | foreground (palette: muted unless selected) | `M/menu:129`, `PAL:255-262` |
| Dialog titles | Geist | 15 | 600 | foreground | `M/confirm:42`, `M/prompt:41`, `M/picker:250` |
| Shortcut hints, "Esc" chips | Geist | 11 | 400 | dim | `M/menu:156`, `PAL:231,299` |
| Toast title / body | Geist | 13 / 12 | 600 / 400 | fg / muted | `M/toast:33-34` |
| Terminal | **JetBrains Mono** | **14** | normal = **Medium 500**, bold = 700, italic | terminal_foreground | `S:523,841`, `T:1545-1551` |
| Diff view | terminal font | 11 | — | — | `M/changes:201` |
| File preview | terminal font | 12 | — | — | `M/files:143` |

Bundled fonts (`S:825-838`, `assets/fonts/`):
- Geist (variable)
- Geist Mono (variable and italic)
- JetBrains Mono (variable and italic)
- Symbols Nerd Font (`SymbolsNerdFont-Regular.ttf`): terminal icon fallback, read directly for icon glyphs (`S:833-838`)

Terminal ligatures are **off** by default (`S:524`).

---

## 4. Window layout (default main layout)

```text
┌───────────────────── sidebar 268 (chrome) ─────────────┬1┬──────────────────── work (no bg → canvas) ───────────────────────────┐
│ ●●●  [logo]Herdr                         [🔍][▥]  46   │ │ [>_ 1] [>_ shell ×]                        [+] [📄Files] [⑂Changes] 42 │ border_b
│ Spaces                                         [+] 31  │ │┌8┐ ───────────────────────────────────────── 8 ── ───────────────── │
│ ┌──────────────────────────────────────────────┐       │ │  ╭ pane card r10 ─────────────────────────╮ 8 ╭ Files card r10 ───╮│
│ │[~] ~                                 sel  30 │ px8   │ │  │ >_ zsh  ~/git/private/dotfiles     30  │   │ Files     dotfiles││ 42
│ └──────────────────────────────────────────────┘       │ │  ├────────────────────────────────────────┤   ├───────────────────┤│
│  [~] ~                                        30       │ │  │ terminal (pad 14 × 12)                 │   │ › 📁 agents   28  ││
│  …  (weight 1, min 90)                                 │ │  │                                        │   │ › 📁 claude       ││
├──── border_t ──────────────────────────────────────────┤ │  │                                        │   │   📄 README.md    ││
│ Agents                                          [⏲] 41 │ │  │                                        │   │                   ││
│ No agent status yet. Agents show up here …             │ │  │                                        │   │  panel 368        ││
│  …  (weight 1, min 90)                                 │ │  ╰────────────── focus: 1px accent ───────╯   ╰───────────────────╯│
├──── border_t ──────────────────────────────────────────┤ │└8┘                                                                  │
│ ⚙ Settings                                       28    │ │ 🖥 This computer   ⑂ main   ● 0 agents              ⌘⇧P  commands 28 │ border_t
│ + Add machine                                    28 69 │ │                                                                     │
└────────────────────────────────────────────────────────┴─┴─────────────────────────────────────────────────────────────────────┘
```

| Node | Type | Size | Min / Max | Look | Content | Source |
|---|---|---|---|---|---|---|
| root | row | window | — | bg canvas, divider 1 px border, terminal_padding [14,12] | — | `L:1-17` |
| sidebar | column | **268 px** | 44 / 480 | bg chrome; not draggable | — | `L:19-28` |
| brand | block | **46 px** | — | window_drag | workspace-chrome | `L:30-40` |
| sidebar-lists | column | flex | — | — | — | `L:41-68` |
| spaces | block | weight 1 | min 90 | — | spaces | `L:45-55` |
| agents | block | weight 1 | min 90 | — | agents (draws its own border_t) | `L:56-66` |
| sidebar-footer | block | **69 px** | — | — | workspace-chrome `{footer:true}` | `L:69-81` |
| work | column | flex | — | — | — | `L:84-88` |
| tabs | block | **42 px** | — | window_drag | tabs | `L:89-99` |
| work-body | row | flex | — | **padding 8, gap 8** | — | `L:100-105` |
| main | block | flex | — | — | active tab's pane tree, framed | `L:106-134` |
| panel | column | **368 px**, hidden by default | 280 / 900 | — | stack `files` / `changes` | `L:135-160` |
| status | block | **28 px** | — | — | workspace-status | `L:172-178` |

Sidebar rail mode: the mods treat the sidebar as collapsed when its width is < 160 px. The toggle resizes it to **76 px on macOS** (clears the traffic lights) or **44 px** elsewhere, and restores the saved width (default 268) on the way back (`M/workspace-chrome:15-24`).

---

## 5. Sidebar

### 5.1 Brand row: workspace-chrome, header mode (`M/workspace-chrome:48-53`)

| Property | Value |
|---|---|
| Container | h_flex full; bg chrome; **pl 76** on macOS when not fullscreen (else 14); collapsed pl 6; pr 10; gap 4; items center; text 13.5 |
| Logo | `frame/welcome/herdr.png`, **20×20, radius 5**: a dark ram head on an off-white rounded square |
| Title | "Herdr", semibold, foreground; gap 8 after the logo; the group is flex_1 |
| Buttons | 26×26, radius 6, centered. Text muted; hover bg `hover` and text foreground. Mouse-down stops propagation so the window doesn't drag |
| Search button | `search.svg` 15 px → opens the picker (`mod.open picker`) |
| Sidebar toggle | `sidebar.svg` 15 px → toggles rail mode. Hidden in rail mode on macOS |
| Traffic lights | the native ●●● at (12,16), drawn over the left 76 px |

### 5.2 Spaces list (`M/spaces:449-477`)

**Root:** v_flex full, bg chrome, text 13.

**Section header** (`:469-473`)
- h 31, pl 16, pr 10, justify-between; text 11.5 dim; label "Spaces".
- "+" button: 26×26, radius 6; `plus.svg` 14 px; inherits dim; hover bg `hover` and fg; runs `space.new`.
- Rail mode: centered, no label.

**List** (`:474`): v_flex flex_1, px 8 (0 in rail), pb 14, vertical scrollbar in mode **"always"**.

**Space row** (`:381-435`)

| Part | Spec |
|---|---|
| Row | v_flex, px 8, **h 30** (28 for a worktree child), **radius 8**, centered vertically |
| Active (shown space) | bg **selected**; no hover change |
| Inactive | hover bg **hover** |
| Drag | pressed row → opacity 0.5. Drop target shows a **2 px accent** line at its top or bottom edge (absolute, full width) |
| Inner | h_flex, **gap 9**, items center |
| Avatar | **18×18, radius 5**, fill = space color (§2.5). First letter uppercased, 10.5 px bold, #fff, centered |
| Worktree child | instead of the avatar: pl 22 + `branch.svg` 13 px dim. Rows are ordered under their main checkout. The tree glyph is computed but only used for row height |
| Name | flex_shrink 0, **max_w 150**, truncate, foreground |
| Git tail | flex_1, justify_end, gap 5, text 11.5, dim. Shows `repo · branch`; the repo is omitted when the name already says it and the branch when it's main/master. Then `↑N` in ansi2 and `↓N` in ansi1 |
| Interactions | left-click selects; right-click opens the context menu popup (200 × ≤260); drag reorders |

The spaces list does **not** nest tabs or terminals. Tabs live in the tab row and in the picker. Only git worktree spaces nest under their main checkout (`M/spaces:282-298`).

**Machine groups** appear only when remote machines exist (`:301-357`):
- Header: h 26, px 8, gap 7, text 11 dim, hover bg `hover`. Contents: `monitor.svg` / `server.svg` 13 px, name (flex_1 truncate), state word, "+" (px 4, r 4, hover bg), a 6 px status dot (ansi2 connected / dim), and `chevron-down`/`chevron-right` 11 px.
- Empty-group row "New space there": h 28, px 8, gap 7, r 7, text 12 dim, `plus.svg` 12, hover bg `hover` and fg.
- Loading row: h 28, text 12 dim "Loading…".

**Rail-mode space cell** (`:437-449`): a 32×26 cell, radius 6, active bg selected. Shows the index number (fg if active, else muted) and a status glyph at right 5: "●" for blocked/done, else "·", colored by status.

### 5.3 Agents list (`M/agents:404-461`)

**Root:** v_flex full, bg chrome, **border_t 1 border**, text 13.

**Section header** (`:416-438`)
- px 16, **h 41, pt 14, pb 5**, justify-between.
- "Agents": 11.5, medium, dim.
- Right: sort button showing `clock.svg` (Priority sort, the default) or `layers.svg` (Grouped by space), 14 px, dim, hover fg, tooltip "Sort agents: …". Opens a popup 200×140.

**Empty state** (`:440`): px 12, text 12 dim:
> "No agent status yet. Agents show up here when they report their status. Older versions and agents inside tmux may not."

**List** (`:442`): flex_1, px 8, vertical scrollbar mode "always".

**Agent row** (`:293-366`)

| Part | Spec |
|---|---|
| Row | h_flex, px 8, **h 30, radius 8**, gap 9. Focused agent: bg **selected**; hover bg **hover** |
| Icon | program icon **16 px**. Tinted SVG uses foreground; otherwise an image. Click folds its sub-agents |
| Name | min_w 0, max_w 200 (120 when a detail follows), truncate. Foreground; muted when idle and not focused |
| Detail | "· {tab or title}", dim, flex_1 truncate (priority / pinned views) |
| Machine | remote agents show the machine name at 10 px dim |
| Fold toggle | h 18, px 3, gap 3, r 4, text 11; `chevron-down`/`right` 11. Folded it shows the count, colored by the most urgent status; hover bg and fg |
| Hover affordance | instead of the age: a pin button (p 2, r 4, dim, `pin.svg`/`pin-off.svg` 13 px, hover bg and fg) |
| Age | 11 px dim: "<1m", "Nm", "Nh", "Nd" (`:64-71`) |
| Status | see §5.3.1 |

**Group header** (`:379-402`)
- px 8, **pt 8, h 30**, gap 6, text 11 medium, hover text foreground.
- Priority view: sections in order "Needs you" (blocked color), "Done" (done color), "Working" (working color), "Idle" (dim), each followed by its count in dim.
- Grouped view: the space name in dim.
- Folded: shows count, compact status and `chevron-right` 11 dim.
- Pinned agents get a "Pinned" group first.

**Sub-agent row** (`:179-201`)
- pl **39**, pr 8, r 8, **h 26**, text 12.5. Shown: bg raised. Hover bg hover.
- Tree connectors: each 9×17 px, mr 4, mt −4. Vertical: border-left **1.5 px in `input`**. Elbows: also border-bottom 1.5 with bottom-left radius 6.
- Icon 14 with mr 8; name muted (fg when shown).

**Sort popup** (`:136-157`)
- p 5, bg popover, text 12.8.
- Title "Sort agents": 11 dim, px 8, pt 4, pb 6.
- Rows: h 31, px 8, gap 9, r 7, hover bg hover. Icon 14 muted; `check.svg` 14 fg on the active option.

#### 5.3.1 Status glyphs (shared by agents, tabs, pane header, picker)

| Status | Glyph | Source |
|---|---|---|
| working | `spinner.svg` **12 px**: ring at 24 % opacity plus a 90° arc, stroke 3.2. Color `working`; **900 ms per revolution**, redrawn every 100 ms (stepped). mx 1 | `M/agents:206`; spin impl `vendor/gpui-kit/crates/shell/src/materialize.rs:2885-2905` |
| blocked (full) | pill "Needs you": h 18, px 6, r 5, bg `blocked` at 15 %, text 10.5 semibold blocked | `M/agents:208`, `M/pane:85` |
| blocked (compact) | 14×14 r 4 square, bg blocked at 15 %, "!" 10.5 bold | `M/agents:207` |
| done | **7 px dot** (r 4), `done` color, mx 3 | `M/agents:211`, `M/pane:86` |
| idle | **7 px ring**, border 1.5 in `idle` | `M/agents:210` |
| tab row | working spinner 12; blocked/done: 6 px dot | `M/tabs:70-71` |

**Rail mode:** rows are h 26 with the index right-aligned (muted) plus a compact status. A footer "»" (h 28, 13 px dim, hover fg) expands the sidebar (`M/agents:298-310,443-460`).

### 5.4 Sidebar footer: workspace-chrome, footer mode (`M/workspace-chrome:35-46`)

| Property | Value |
|---|---|
| Container | v_flex full, bg chrome, **border_t 1 border**, px 8, **pt 4, pb 8**, text 13. 1 + 4 + 28 + 28 + 8 = 69 = `L:73` |
| Row | h_flex, **h 28**, px 8, **gap 9**, radius 8, pointer. Hover bg `hover` and text foreground |
| Settings | `settings.svg` 14 + "Settings", muted. If an update is ready, a 6 px accent dot follows |
| Add machine | `plus.svg` 14 + "Add machine", **dim** |
| Rail mode | 32 px icon-only cells with tooltips |

---

## 6. Tab row (`M/tabs:46-102`)

| Part | Spec |
|---|---|
| Container | h_flex full, px 10, **pl = lightsPadding**, gap 3, items center, bg **chrome**, **border_b 1 border**. lightsPadding = `max(10, (traffic_x + 64)/zoom − sidebarPx)` on macOS with no titlebar, else 10. With the 268 px sidebar it's **10** (`:76-78,92`) |
| Wheel | scroll down → previous tab; scroll up → next tab |
| Tab strip | flex_1, gap 3, horizontal scrollbar (`:95`) |
| **Tab pill** | h_flex, **h 29, px 10, gap 7, radius 7**, text **12.8**, **border 1** (`:58-59`) |
| Active tab | bg **raised**, border **border**, text foreground, plus a close button |
| Inactive tab | bg **chrome**, border **chrome** (invisible), text **muted** |
| Hover | bg **hover** |
| Icon | program icon 14 px (tinted SVG in muted). The shell icon is Lucide `terminal` ">_" (`defaults/icons/shell.svg`) |
| Label | max_w 170, truncate. An unnamed tab shows its index ("1"); an internal `tb\d+` name shows the program name; zoomed adds " Z" |
| Status | working spinner 12; blocked/done 6 px dot (r 3) |
| Close | active tab only: `pane/close.svg` **12 px**, dim, stroke 1.3 |
| Gestures | press-and-release on another tab = reorder; double-click = rename prompt; right-click = context menu popup (width 200) |
| "+" button | 26×26, r 6, text dim, literal "+" glyph; hover bg hover and fg. Opens the new-menu popup **250 × 512** (`:53,96`) |
| Panel toggles | h_flex **h 26, px 8, gap 5, r 6**, text 12. On: bg **selected**, fg. Off: bg chrome, muted. Hover bg hover. Icons 14: Files = `mods/files/file.svg` (Lucide file); Changes = `mods/changes/changes.svg` (custom git-compare, stroke 1.5). Clicking toggles the `panel` node and selects its stack child. Open/closed state is remembered per space (`:20-44,82-98`) |
| Window buttons | Linux/Windows client decorations only: 26×26 buttons. Not shown on macOS |

---

## 7. Work body, pane frame and pane header

### 7.1 Pane frame (`L:111-131`, `W:4008-4033`, `PS:15-21`)

| Property | Value |
|---|---|
| Radius | **10** |
| Background | `background` (#17191d) |
| Border | **1 px `border`**; focused pane: **1 px `accent`** (same width, so no layout shift) |
| `lone: true` | the frame also draws when the tab has a single pane |
| Gap between split panes | **8** (`L:112`; separator width = gap + divider, `PS:27-29`) |
| Header | **30 px, top, always visible** (`L:124-131`; default 30, `W:32`). Placed inside the card above the terminal body |
| Clip | overflow hidden, so the content clips to the radius |
| Unframed tabs | only when `lone` is false and there's one pane |

### 7.2 Pane header mod (`M/pane:59-92`)

| Part | Spec |
|---|---|
| Container | h_flex full, **px 10, gap 8**, bg **background**, **border_b 1 border** (border_t if positioned at the bottom), text **12**. Click focuses the pane |
| Icon | program icon **14 px, dim** (tinted) |
| Name | max_w 260, truncate, **medium**, foreground. Value: program name for agents and shells (e.g. "zsh"), else the terminal title |
| cwd | flex_1, truncate, **dim**; home folder shown as `~` |
| Status | working spinner 12 / "Needs you" pill / 7 px done dot |
| Hover buttons | four icons appear on hover: `split-right`, `split-down`, `zoom` / `unzoom`, `close`. Each p 3, r 4, dim, **14 px** (16-unit viewBox, stroke 1.3). Hover bg `hover` and fg |

### 7.3 Pane drag grip (`PD:50-71`)

- Shown when the pointer is in the top header strip of a movable pane (≥ 2 panes, not zoomed).
- 28×18, radius 4, absolutely centered horizontally; top = (30 − 18)/2 = 6.
- bg `background` at 85 %; hover bg `hover`.
- Two rows of three 2 px dots, gap 3, colored dim (foreground on hover or while dragging).
- Cursor: open hand, closed hand while dragging.

---

## 8. Terminal rendering (`T`)

| Item | Value | Source |
|---|---|---|
| Padding | x **14**, y **12** (layout); app default 10 × 6 | `L:10-13`, `S:534`, `T:45-49` |
| Grid size | cols = ⌊(w − 2·14) / cellW⌋, rows = ⌊(h − 2·12) / cellH⌋ | `T:51-55` |
| Vertical spare | leftover height split top/bottom: origin.y = pad_y + ⌊spare/2⌋, snapped to device px | `T:1716-1721` |
| Font | JetBrains Mono 14, **Medium** for normal text, Bold for bold; ligatures off | `T:1545-1551` |
| Cell size | width = advance('M'); height = ⌈(ascent + descent) · **1.15** · scale⌉ / scale | `T:1561-1572` |
| Background | theme `background` × terminal_opacity (1.0) | `T:1754,2047` |
| Default fg | `terminal_foreground` (#d2d4d9) | `src/vt.rs:72` |
| Selection | cell bg = `selection` (#394454); fg unchanged | `src/vt.rs:1651-1652` |
| Cursor (focused) | block fills the cursor color and redraws the glyph in bg; bar **2 px**; underline **2 px** at cell bottom. The program chooses the shape via DECSCUSR; default block | `T:1854-1882` |
| Cursor (unfocused) | **1 px hollow outline** | `T:1881` |
| Cursor color | program-set, else theme fg (graphite #d2d4d9) | `src/vt.rs:1611` |
| Find highlights | accent at **28 %** (matches), **55 %** (current) | `T:1810-1823` |
| Link underline | 1 px at cell bottom − 2 px, in the text color (while the Cmd/Ctrl modifier is held) | `T:1844-1850` |
| Scrollbar | thumb **4 px** wide, 2 px from the right edge, radius 2, color **muted**. Rail 1 px muted at 35 %. Min length = 1 cell height. Uses the padding lane (≥ 8 px). Hidden on the alt screen and at ≤ 4 cols | `T:1083-1098,1905-1928` |
| Find bar | absolute, top 0.5 rem, right 0.5 rem; max_w **460**, **h 38**, gap 0.25 rem, px 0.25 rem, rounded_md, border 1 border, bg popover, shadow_md. Count label w 58 text_xs muted. ↑/↓/× buttons **26×26** rounded_sm, hover bg hover | `T:2213-2285` |
| Ended badge | absolute, bottom 0.5 rem, right 0.75 rem; px 0.5 rem, py 0.25 rem, rounded_md, bg raised, text_xs, terminal fg: "[exited …]" | `T:2287-2300` |

---

## 9. Right panel: Files and Changes

The panel is a column, 368 px wide (min 280, max 900), and sits inside the work body after an 8 px gap. Each mod draws its own card (`M/files:169`, `M/changes:182`):
- radius **10**, overflow hidden
- bg **background**
- border **1 border**
- text 13 foreground
- no focus ring

### 9.1 Files (`M/files:150-178`)

| Part | Spec |
|---|---|
| Header | h_flex **h 42, px 14, gap 8**, border_b 1 border |
| Title | "Files", semibold 13 |
| Right label | flex_1, truncate, **right-aligned**, 12 dim: root folder basename (e.g. "dotfiles"), or the open file's path |
| Back arrow | when previewing a file: "←", w 20, muted |
| Tree | v_flex, scrollbar, **p 6** |
| Row | h_flex **h 28**, **pl 8 + depth·18**, pr 8, **gap 7**, radius 7, hover bg **hover** |
| Chevron | `chevron-right` / `chevron-down` **12 px, dim** (Lucide, stroke 2). Files get a 12 px spacer |
| Icon | `folder.svg` / `file.svg` **14 px, muted** (Lucide, stroke 2) |
| Name | flex_1, truncate, foreground |
| Git mark | 11 px letter: A = ansi2, D/U = ansi1, M = **blocked** color |
| Order | folders first, then by name |
| Empty / loading | p 8, 12 dim: "Loading files…" / "No files" / "No folder" |
| Cap notice | p 8, 11 dim |
| File preview | read-only gpui-kit Editor, terminal font **12**. Syntax: keyword ansi5, string ansi2, comment dim, function ansi4, type ansi3, number ansi1, constant ansi6 |

### 9.2 Changes (`M/changes:171-212`)

| Part | Spec |
|---|---|
| Header | h 42, px 14, gap 8, border_b. "Changes" semibold. Badge "N files": px 5, py 1, r 4, border 1 border, text 10, muted. Spacer, then "+A" 11 ansi2 and "−D" 11 ansi1 |
| File list | min_h 44, max_h files·28 + 12, border_b; p 6 |
| File row | h 28, px 8, gap 8, r 7. Open file: bg **selected**; hover bg hover |
| Status letter | w 14, text 11: A ansi2, D/U ansi1, M blocked |
| Path | directory in dim + name (max_w 260); then +n / −n at 11 |
| Diff area | terminal font **11**, virtual list rows **20 px**, horizontal and vertical scrollbars |
| Hunk header | px 12, h 20, bg **raised**, dim |
| Line row | h 20, gap 10. Added: bg ansi2 at **9.4 %**. Removed: bg ansi1 at 9.4 %. Line number w 30, right-aligned, dim |
| Placeholder | "Select a file to view its changes", top 6, px 12, dim |
| Commit bar | p 10, gap 8, border_t |
| Message input | h 32, px 10, r 8, border 1: **accent** when focused, else border. Text 12, placeholder "Commit message" |
| Commit button | h 32, px 14, r 8, text 12. Enabled: bg **solid**, text solid_foreground. Disabled: bg raised, text dim |

---

## 10. Status bar (`M/workspace-status:17-30`)

| Part | Spec |
|---|---|
| Container | h_flex full (**28 px**), **px 14, gap 16**, bg **chrome**, **border_t 1 border**, text **11.8 muted** |
| Item pattern | h_flex gap 6: icon **13 px** + text |
| Machine | `monitor.svg` + "This computer" (remote spaces: `server.svg` + machine name) |
| Branch | `branch.svg` + branch (only when known) |
| Agents | **6 px dot** (r 3, bg dim) + "N agents". If any are blocked: "· N needs you" in blocked color |
| Right | spacer, then the palette hint in **dim**: "⌘⇧P  commands" (two spaces), built from the bound key with ⌘⌃⇧⌥ symbols on macOS. Click opens the palette |

---

## 11. Overlays

### 11.1 Overlay frame and kinds (`W:3573-3651,4321-4395,4533-4536`)

| Kind | Placement | Default size | Backdrop and closing |
|---|---|---|---|
| Frame (every kind unless `frame:"none"`) | — | — | bg **popover**, **border 1 border**, **radius 8**, **shadow_lg**, overflow hidden (`W:4349`) |
| dialog | centered | width **420**, height up to 85 % (fits content when no height) | full-window **black 35 %** backdrop; click outside closes (unless modal); Esc closes |
| popup | at the pointer, clamped **8 px** from window edges (`W:4533-4536`). `at:"top"`: horizontally centered at `offset` px from the top | width 420, max height 85 %, height fits content | no dim; left or right click outside closes |
| toast | bottom-right, **right 16, bottom 16**, stacked upward (+ height + 8) | **340 × 72** | auto-dismiss **5 s** (error/warning **8 s**) |
| window | draggable, remembered position | content size | — |

Shadows: `shadow_lg` and `shadow_md` are GPUI's Tailwind presets [INFERENCE]:
- lg: `0 10 15 −3 rgba(0,0,0,.1)` plus `0 4 6 −4 rgba(0,0,0,.1)`
- md: `0 4 6 −1 rgba(0,0,0,.1)` plus `0 2 4 −2 rgba(0,0,0,.1)`

### 11.2 Command palette (⌘⇧P) (`W:3349-3358`, `PAL`)

**Placement:** popup, `at: top`, **offset 60, width 620, max height 85 %** of the window.

```text
╭──────────────────────────── 620 ────────────────────────────╮  p 18, gap 10, bg popover
│ ╭─────────────────────────────────────────────────────────╮ │
│ │ ⌘  Type a command…                                  Esc │ │  h 36, r 9, border 1 accent, bg background
│ ╰─────────────────────────────────────────────────────────╯ │
│   Recent                                                    │  group head 26: px 14, pb 4, align bottom, 11 semibold dim
│  ▌New tab                                    [cmd][t]     ▐ │  row 32: mx 6, px 10, gap 10, r 7; selected = bg selected
│   Split right                                [cmd][d]       │  keycap: px 5, r 4, border, bg raised, 11 dim, gap 3
│   …                                   (10 rows = 320 px)    │
╰─────────────────────────────────────────────────────────────╯
```

| Part | Spec |
|---|---|
| Body | v_flex, **p 18, gap 10**, bg popover (`PAL:271-273`) |
| Search field | **h 36, px 10, gap 10, r 9, border 1 accent, bg background** (`:288-296`). macOS icon `frame/palette/command.svg` **16 dim** (search icon elsewhere). Input 12.8, placeholder "Type a command…". Trailing "Esc" 11 dim |
| List | **10 visible rows × 32 = 320 px**; group heads **26** (`:16-19`); mb 6 |
| Row | mx 6, px 10, gap 10, r 7, text 12.8. Selected: bg **selected**; hover bg hover. Title text: **muted**, or foreground when selected |
| Fuzzy matches | matched letters in **accent, semibold** (`:202`) |
| Group label | while typing, a right-aligned group name at 11.5 dim (`:262`) |
| Keycaps | one box per token of the bound key. Tokens are shown raw (e.g. `cmd`, `shift`, `p`), not as symbols. px 5, r 4, border 1 border, bg raised, text 11 dim, gap 3 (`:230-231`) |
| Group order | Recent, Tab, Pane, Space, Layout, Terminal, Agent, Window, App (`:20`) |
| Empty | px 16, py 14, 13 dim: `Nothing matches "…". Places are in the picker.` |

### 11.3 Picker "Go to…" (⌘P) (`M/picker`, `mod.json`: popup at top, offset 40, width 640, height 0.8)

| Part | Spec |
|---|---|
| Body | p 18, gap 10, bg popover, text 13 (`:232-235`) |
| Title row | "Go to…" 15 semibold fg. "Esc" chip: px 6, py 2, r 5, 11 dim, hover bg and fg (`:250`) |
| Search | h 36, px 10, gap 8, r 9, border accent, bg background. `search.svg` 15 dim. Input 12.8, placeholder "Go to a tab, space or agent…" (`:252-254`) |
| List | max 320 px; row heights: head 29, earlier 35, new 36, ctx 32, space 32 (`:136`) |
| Space head | px 10, pt 10, pb 3, gap 8, 11 semibold dim. Avatar 18 r 5 (the `~` space uses dim) |
| Tab row | mx 4, px 10, h 32, r 7, gap 10. Keyboard selection / hover: bg **hover**. Glyph w 12: spinner, or ● / ○ / · in the status color. Name fg, semibold if current. "needs you" 11 blocked; "finished" 11 done; agent names 11 dim |
| "earlier: N quiet spaces ▾" | mt 6, px 10, py 6, border_t, 12 dim |
| New rows | "+ new tab" / "+ new space": h 32, r 7, muted |

### 11.4 Context menu (`M/menu:120-158`)

**Placement:** popup at the pointer, width **200**, height fits up to 260.

| Part | Spec |
|---|---|
| Body | p 5, bg popover, text 12.8 |
| Row | **h 31, px 8, gap 9, r 7**, foreground. Keyboard selection: bg **selected**; hover bg **hover** |
| Icon | 14 px muted. Mapping: `x` for close, `square-pen` rename, `plus` new, `git-branch` worktree, `panel-right` split, `square` zoom, `terminal` other (`:82-85`) |
| Shortcut | right side, 11 dim, raw key string |
| Separator | 1 px border, mx 7, my 4. Placed before Close, Keybinds and the first theme item |

Items per target:

| Target | Items |
|---|---|
| tab | Rename / New tab / Close |
| space | Rename / [New worktree / Open worktree] / [Remove worktree] / Close |
| pane | Split right / Split down / Zoom / Send right-clicks to pane / Close pane |

### 11.5 New menu (tab-row "+") (`M/new-menu:41-72`)

**Placement:** popup **250** wide; height = min(491, 167 + 31·n).

| Part | Spec |
|---|---|
| Body | p 5, popover, 12.8 |
| Row | **h 31, px 9, gap 10, r 7**. Hover bg **selected** (not hover). Disabled rows: dim |
| "Terminal" | `icons/shell.svg` 14; hint = bound key (e.g. ⌘T) at 11 dim |
| "Start an agent" | label: px 9, pt 8, pb 4, 11 dim |
| Agent rows | icon 14 + name. Hint "1"…"9" (digit shortcut), or "not installed" (dim row) |
| Divider | 1 px, mx 4, my 5 |
| Bottom rows | "+ New space" (⌘N); "New worktree…" and "Open worktree…" with `branch.svg` 14 |

### 11.6 Confirm and prompt dialogs (dialog, width **380**: `W:2871,3519`)

| Part | Confirm (`M/confirm:24-50`) | Prompt (`M/prompt:33-48`) |
|---|---|---|
| Body | p 18, gap 12, r 8, popover, text 13 | p 18, popover |
| Title | 15 semibold fg + "Esc" 11 dim | same |
| Content | detail text in muted | label "Name": pt 16, pb 7, 11.5 dim. Input **h 36, px 10, r 9**, border accent when focused (else input), bg background, 12.8. Hint: pt 6, 11.5 dim |
| Buttons | right-aligned, gap 8, text 12; **h 32, px 14, r 8** | pt 20, gap 8, right; same size, text 12.5 medium |
| Secondary button | "Cancel": bg raised, border input, fg | same |
| Primary button | "Confirm": bg **solid**, fg solid_foreground | "Save": same |
| Hover | opacity 0.88 | opacity 0.88 |

### 11.7 Toast (`M/toast:13-36`, frame from §11.1)

- Container: h_flex, **px 18, gap 12**, bg popover; hover bg **hover**; click runs the toast's action.
- Leading: a **8 px dot** colored by level (error → blocked, warning → working, success → done, info → accent), or an 18 px image.
- Title 13 semibold fg, truncated; body 12 muted.

### 11.8 Peek overlay (`W:3659-3672`, `M/peek:48-75`)

- Dialog **80 % × 80 %**. Layout column: a **34 px** bar on top, the terminal below.
- Bar: px 12, gap 8, bg **surface**, border_b, text 12.
  - Status glyph w 12: a braille spinner "⠋⠙⠹…" at **90 ms per frame** for working; ○ for idle; ● for other statuses; · when none.
  - Program icon 14; name semibold fg; status word ("working" / "needs you" / "finished" / "idle") in the status color; "from {parent}" dim.
  - Spacer, then buttons px 8, py 2, r 5, muted, hover bg and fg: "↗ go to" (or "↗ keep") and "✕".

### 11.9 Update pill (`W:4421-4490`)

- Bottom-right 16; **h 34**, pl 14, pr 6, gap 10; popover bg, border, **fully rounded**, shadow_lg; text 13.
- "Restart" button: h 24, px 10, fully rounded, bg accent, text accent_fg, semibold, hover opacity 0.9.
- Link "What changed" in accent.
- Dismiss "×": 24 px circle, dim; hover bg raised and fg.

---

## 12. Icons

Icon set: **Lucide** (ISC), plus a few custom 16- or 24-unit glyphs. Brand icons: Simple Icons. Agent icons: LobeHub (`defaults/icons/LICENSES.md`).

All icons are monochrome `stroke="currentColor"`, tinted via `text_color`.

| Icon file | Stroke / viewBox | Used where (px) |
|---|---|---|
| `workspace-chrome/plus.svg` | Lucide 2 / 24 | Spaces "+" 14; footer "Add machine" 14; machine "New space there" 12 |
| `workspace-chrome/search.svg` | custom 1.5 / 24 | brand search button 15; picker 15; palette on non-macOS 16 |
| `workspace-chrome/sidebar.svg` | custom 1.5 / 24 (rect r3 + divider) | brand sidebar toggle 15 |
| `workspace-chrome/settings.svg` | Lucide 2 | footer Settings 14; menu theme items 14 |
| `workspace-chrome/clock.svg` | Lucide 2 | Agents sort (Priority) 14 |
| `workspace-chrome/layers.svg` | Lucide 2 | Agents sort (Grouped) 14 |
| `workspace-chrome/check.svg` | Lucide 2 | sort-menu check 14 |
| `workspace-chrome/spinner.svg` | custom 3.2 / 24 (ring at 24 % + arc) | working status 12 |
| `workspace-chrome/monitor.svg` | custom 1.5 | status bar 13; machine header 13 |
| `workspace-chrome/server.svg` | custom 1.5 | remote machine 13 |
| `workspace-chrome/branch.svg` | custom 1.5 | status bar 13; worktree rows 13; new-menu 14 |
| `workspace-chrome/chevron-{down,right}.svg` | Lucide 2 | fold toggles 11 |
| `workspace-chrome/pin.svg`, `pin-off.svg` | Lucide 2 | agent hover pin 13 |
| `workspace-chrome/{x, square-pen, git-branch, panel-right, square, terminal}.svg` | Lucide 2 | context-menu icons 14 |
| `files/file.svg` | Lucide file 2 | Files toggle 14; file rows 14 |
| `files/folder.svg` | Lucide folder 2 | folder rows 14 |
| `files/chevron-{down,right}.svg` | Lucide 2 | tree chevrons 12 |
| `changes/changes.svg` | custom git-compare 1.5 | Changes toggle 14 |
| `pane/{split-right, split-down, zoom, unzoom, close}.svg` | custom 1.3 / **16** | pane header buttons 14; tab close 12 |
| `tabs/win-{min,max,restore,close}.svg` | 1 / 16 | Windows caption buttons 16 |
| `defaults/icons/shell.svg` | Lucide terminal ">_" 2 | shell program: tab 14, pane header 14, new-menu 14 |
| `frame/palette/command.svg` | — | palette search on macOS 16 |
| `frame/welcome/herdr.png` | raster 160² | brand logo 20 r 5 |

Program icons and names come from `defaults/programs.json` (key → name / icon / tint). Shells listed at `:2` resolve to `shell` with name = process name (e.g. "zsh").

---

## 13. Interaction states, motion and scrollbars

| State | Rule |
|---|---|
| Row hover (sidebar, tree, menus) | bg `hover`; text often switches to foreground. Instant |
| Selected / active row | bg `selected` (space row, focused agent, menu keyboard row, palette selection, panel toggle, open diff file) |
| Raised / active chip | bg `raised` (active tab pill, shown sub-agent, keycaps, secondary buttons, hunk header) |
| Icon buttons | 26×26 r 6 (chrome, tabs) or p 3 r 4 (pane header); rest color muted or dim; hover bg `hover` and fg |
| Primary / secondary buttons | hover opacity 0.88 (dialogs) or 0.9 (update pill) |
| Focus ring | pane: 1 px accent border, radius 10. Text inputs: border switches to accent (palette and picker inputs are always accent). No outer glow |
| Drag-reorder | spaces: source opacity 0.5 and a 2 px accent insertion line. Tabs: press on one tab, release on another |
| Spinner | 900 ms per revolution, repainted every 100 ms (`materialize.rs:2895-2905`) |
| Peek braille spinner | 90 ms per frame (`M/peek:63`) |
| Scrollbars (gpui-kit) | lane 16 px; thumb **6 px** (8 px when hovered or dragged); inset 4; **radius 0**; min length 48; fill foreground at **35 %** (55 % hover/active); transparent track (`SB:21-31,1030-1031,1049-1150`). Spaces and agents lists use mode **"always"**. Default motion: visible for 2 s after activity, enter/exit 0 ms (`SB:38,298-307`) |
| Terminal scrollbar | separate implementation: see §8 |
| Tooltips | used in rail mode and on the sort and pin buttons (gpui-kit tooltip) |

---

## 14. Reconciling with `/tmp/soprano-rs-ref/herdr-main.png`

Measurements from the image use a **≈ 0.85** design-px ratio:

| Element | Measured | ÷ 0.85 | Spec |
|---|---|---|---|
| Tab row | ≈ 36 | 42 | 42 |
| Pane header | ≈ 25 | 30 | 30 |
| Status bar | ≈ 24 | 28 | 28 |
| Files panel width | ≈ 310 | 365 | 368 |
| Brand-row left inset to logo | ≈ 65 | 76 | 76 |
| "Spaces" text center | y ≈ 52 | — | brand 46 + ½ × 31 header = 61.5 → 52 at 0.85 ✓ |

Either the screenshot was downscaled, or the window ran at zoom 0.85.

| Observation | Spec explanation |
|---|---|
| Sidebar edge at x ≈ 178 (≈ 210 design px, not 268) | **Discrepancy**: the user's saved sidebar width differs. `layout.resize` and the saved `sidebar.width` persist per user. The shipped default is 268 (`L:23`) |
| Traffic lights at the top-left, vertically centered in the brand row | lights at (12,16) with a 46 px row (`L:5-8,34`) |
| Logo + "Herdr", then 🔍 and ▥ at the right | §5.1 |
| "Spaces" header with + on the right; two "~" rows with teal avatars; the first row has a lighter fill | `~` falls back to ansi6 `#22a99a`; active row bg `selected` (§5.2) |
| "Agents" header roughly mid-sidebar with a clock icon; empty-state paragraph | two weight-1 blocks; Priority sort icon = clock (§5.3) |
| "⚙ Settings" (lighter) and "+ Add machine" (dimmer) at the bottom | muted vs dim (§5.4) |
| Tab row: ">_ 1" (inactive, no border) and ">_ shell ×" (raised pill with border) | §6 |
| Right side of the tab row: "+", "📄 Files" (filled = selected), "⑂ Changes" | §6 panel toggles |
| Pane card with a light-blue 1 px outline and rounded corners | focus = accent `#96b2d7`, radius 10 (§7.1) |
| Pane header ">_ zsh ~/git/private/dotfiles" with a divider line under it | icon dim, name medium, cwd dim, border_b (§7.2) |
| Terminal text starts inset from the card edge | padding 14 × 12 (§8) |
| Files card: "Files" title, "dotfiles" right-aligned, rows with chevron + folder icon | §9.1 |
| Status bar: "🖥 This computer ⑂ main ● 0 agents … ⌘⇧P commands" | §10 |
| Background tones: sidebar, tab row and status bar darkest; gaps slightly lighter; cards lighter still | chrome `#101114` < canvas `#131518` < background `#17191d` |

---

## 15. GPUI port notes

- **Tokens:** model them as one struct derived per theme with the formulas in §2.1 (`mix` with round-half-away, alpha tokens as `Hsla` with alpha). Keep `foreground` (UI, `#eeeeef`) separate from `terminal_foreground` (`#d2d4d9`).
- **Scaling:** multiply every layout length by zoom (Herdr's `z()`), and set `window.set_rem_size(13 × zoom)` so GPUI rem-based helpers match.
- **Fonts:** register the bundled fonts at startup; set the root `font_family("Geist")`. The terminal uses JetBrains Mono Medium 14 with a 1.15 line factor.
- **Cards:** the pane card and the Files/Changes cards use the same recipe (radius 10, bg background, 1 px border). Only panes swap the border to accent on focus.
- **Overlays:** every overlay shares the frame recipe (popover, 1 px border, radius 8, shadow_lg). Dialogs add the 35 % black backdrop; popups clamp 8 px from window edges.