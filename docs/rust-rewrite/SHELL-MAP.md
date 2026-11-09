# Soprano's screens in Herdr's frame

Herdr's measurements and tokens: `HERDR-UI.md`. Soprano's behavior: the Swift views named per
region. Where the two disagree, Herdr decides how it looks and Soprano decides what it does and
what it shows. No uppercase eyebrows anywhere (Soprano convention); section headers read
"Title N ⌄".

```text
┌ sidebar 268 (chrome) ──────────────┬1┬ work (canvas) ──────────────────────────────────────────────┐
│ ●●●  [icon] Session 1 ⌄     [⌕][▥] │ │ [window tabs row: 1 Editor  2 Server  +]  (hideWindowTabs=false) │
│ Windows 3                     [+]  │ │ [>_ zsh ×] [◆ Claude Code ●2] [+]          [+] [Files] [Changes]  │ 42
│ ▾ [1] Editor          ◌2 ●1        │ │ ┌8┐                                                              │
│    ▏ shop             Working 2m   │ │  ╭ pane card r10 ────────────────────╮ 8 ╭ Explorer / SC r10 ─╮ │
│    ▏ Claude Code · shop · feat-x   │ │  │ ◆ Claude Code  ~/git/shop  ◌ 2m  │   │ Files     shop     │ │
│    ▏ zsh  ~/git/shop               │ │  │ [tab][tab][+]       ⇥ ⇩ ⛶ ×      │   │ › 📁 src           │ │
│ ▸ [2] Server          ● running    │ │  ├───────────────────────────────────┤   │                    │ │
│ Agents 2                     [⏲]   │ │  │ terminal / browser / chat / editor│   │                    │ │
│ Needs you 1                        │ │  │ / markdown / diff                 │   │                    │ │
│  ◆ Claude Code · shop     Approval │ │  ╰───────────────────────────────────╯   ╰────────────────────╯ │
│ Working 1                          │ │                                                                 │
│  ◇ Codex · api            ◌ 4m     │ │                                                                 │
│ ⏱ Automations                      │ │                                                                 │
│ ⚙ Settings                         │ │ Normal  work › Editor › Claude Code · Tab 2   1 needs you        │
│                                    │ │         Claude 18% · 3h 5m   Up 2:14:07   ⌘P Commands  ⌃A Prefix │ 28
└────────────────────────────────────┴─┴─────────────────────────────────────────────────────────────────┘
```

| Region | Herdr part | Soprano content and behavior (Swift source) |
|---|---|---|
| Brand row 46 | traffic lights (macOS 12,16), logo 20 r5, title, search + sidebar toggle buttons | app icon, active **session** name with ⌄: session switcher popup (sessions, New Session…, Rename Session…, Close Session…, Saved Workspaces, Save Workspace As…) — `SidebarView.swift` session selector. Search button = `⌘F` window search; toggle = `⌘E` (sidebar hidden entirely, not rail mode, as Soprano) |
| Spaces list → **Windows** | rows h30 r8, avatar 18 r5, name, right tail | the active session's logical windows (`SidebarView.swift`): number avatar, title, agent badge (count, most urgent color) + cyan running badge; chevron collapse per window, collapse all; under each expanded window its panes grouped by layout tab with a guide line (indent), each pane row: name (task / folder / command), second line agent · folder · non-default branch, status pill, running mark, pencil tick on the focused pane, pane hint caps while Control (Alt+Shift off-mac) is held, window number hints. Click focuses; context menus as Swift. Header "+" = Soprano's sidebar **+** menu (new terminal pane, agents, chat, browser, Markdown…) |
| Agents list | rows h30, status glyphs, groups | every agent across the session's windows grouped Needs you / Working / Ready / Stopped with counts (dashboard grouping, `AgentDashboardSnapshot`); click focuses its pane tab; header button opens the Agent Dashboard (`⇧⌘D`) |
| Footer | Settings / Add machine rows h28 | Automations (opens Automations page), Settings (`⌘,`) |
| Tab row 42 | tab pills h29 r7, "+", Files/Changes toggles | the active window's **layout tabs** (`LayoutTabBarView.swift`, `TabPillButton.swift`): title = focused pane title, badge with counts + hover breakdown, cyan running badge, × / middle-click close, scroll, keeps active visible; "+" = new tab; right: Files / Changes = right sidebar Explorer / Source Control toggles (`RightSidebarView.swift`) |
| Window tabs row | (same pill style) | numbered logical-window tabs `1  Editor` (number muted) when `hideWindowTabs` is false (`WindowTabBarView.swift`), "+" new window |
| Pane card | r10, 1px border, accent when focused, header 30 | `SplitTreeView.swift` + `PaneHeaderView.swift`: header shows icon (agent icon from `resources/icons/<agent>.svg`, terminal `>_`), title, cwd dim, status pill or RUNNING mark, pane tabs (when > 1; shrink, scroll, × per tab), `+` pane-tab menu (terminal, browser, each agent, chat, Markdown…; disabled at 10), hover buttons split right / split down / maximize / close. Attention panes get the attention color border instead of accent. Split dividers are the 8px gaps; drag to resize; maximize shows one pane |
| Right panel 368 | Files / Changes cards | Explorer (`FileExplorerView.swift`) / Source Control (`SourceControlView.swift`); width 220 min, persisted, resizable leading edge |
| Status bar 28 | items with 13px icons, palette hint right | `StatusBarView.swift`: keybinding mode (Normal / Prefix / Copy), location `session › window › pane · Tab n`, `N needs you`, account usage (click → usage popover), optional uptime, `⌘P Commands`, `⌃A Prefix` keycaps |
| Overlays | palette 620 at top 60, picker, menus, dialogs 380/420, toasts | command palette (`⌘P`), window search (`⌘F`), session switcher, project search (`⇧⌘P`), Settings card, Agent Dashboard, Automations page, Shell dialogs |

Sidebar width: drag the trailing edge 160–520, double-click resets to the Swift default (220), a
narrow window keeps 320 for panes, persisted (`SidebarWidthStore.swift`). Herdr's 268 is not
used because Soprano's width behavior is the spec.
