# Settings Redesign — Design

Date: 2026-07-14
Status: approved (direction: refined terminal aesthetic; scope: restyle + light restructuring; controls: hybrid)

## Goal

Replace the current ad-hoc settings UI with a cohesive, themed design that reads
as part of Soprano's terminal aesthetic. No functional changes: same four tabs
(General, Keyboard Shortcuts, Agent Profiles, About), same callbacks, same
persistence, same theme reactivity.

## Problems being fixed

- Page subtitle renders in a narrow side column that wraps one word per line.
- Stock AppKit controls (silver bezels, blue accents) clash with the dark theme.
- Heavy nested cards with inconsistent insets (`-36`, `-24`, `-20` magic numbers).
- About tab: oversized 34pt hero; the ⌘P key badge stretches across the full row
  (content-hugging bug).
- Every row is hand-built, so spacing/typography drift from row to row.

## Layout & chrome

- Keep the embedded overlay: rounded card inset 18pt inside the terminal area,
  `Done` button top-right in a slim header.
- Content area gets a page header: 20pt semibold title + one-line 12pt muted
  subtitle. This replaces the wrapping side column.
- Content is a single scrolling column, max width 560pt, 24pt padding. Rows do
  not stretch further on wide windows.
- Sidebar: 180pt, four tabs with SF Symbols. Selected tab = subtle `bgRaised`
  pill with accent-tinted icon and `textPrimary` label; unselected = `textMuted`.
  No large accent-colored fills.

## Design language

- Grouped sections instead of nested cards: an 11pt uppercase monospace section
  label (same voice as the status bar's SOPRANO/NORMAL) above a rounded group
  (`bgPanel` fill, 8pt radius, 1px `borderSubtle`), rows separated by hairline
  dividers.
- Row anatomy: min height 44pt; 14pt horizontal padding; left side = 13pt medium
  label plus optional 11pt `textMuted` help text; right side = control, right
  aligned.
- Typography: page title 20 semibold; section label 11 bold uppercase monospace;
  row label 13 medium; help text 11 regular; keys/paths/commands monospaced 11.
- Color discipline: `bgBase` page, `bgPanel` groups, `borderSubtle` borders.
  Accent appears only for selection, toggle-on state, and focus rings.

## Components (new file: Sources/Soprano/Views/SettingsComponents.swift)

- `SettingsSectionView` — section label + grouped rows container with dividers.
- `SettingsRowView` — label/sublabel left, control right; enforces row anatomy.
- `ToggleSwitchView` — custom themed switch (~36×20, accent when on, animated
  knob) replacing stock checkboxes.
- `KeyBadgeView` — monospace key chip with correct intrinsic size and hugging
  (fixes the stretched ⌘P badge).
- Styling helpers for buttons and text fields: `bgRaised` fill, `borderSubtle`
  border, accent focus ring, `textPrimary` text.
- Dropdowns remain `NSPopUpButton` with dark-appearance tuning (hybrid
  decision): popup menu behavior is not worth rebuilding.

All components take an `AppTheme` and restyle in `apply(theme:)` so theme
switching keeps working.

## Per-tab treatment

- **General** — sections: Appearance (theme dropdown row), Session (restore
  toggle row), Project Directories (one row per path with trailing remove
  button; final row holds the path field + Browse + Add), Keybinding Behavior
  (Prefix Key, Prefix Timeout, Resize Step as compact ~80pt right-aligned
  fields).
- **Keyboard Shortcuts** — rows grouped by binding category; each row: label,
  muted monospace PREFIX/DIRECT chip, `KeyBadgeView` right-aligned.
- **Agent Profiles** — one row per agent: color dot, name, command string in
  muted monospace.
- **About** — compact wordmark (16pt bold "SOPRANO" with accent), two monospace
  muted lines (Version, Runtime), then Quick Reference reusing the same
  shortcut-row component as the Keyboard Shortcuts tab.

## Implementation approach

Add the component kit, then rewrite the four tab builders in
`SettingsWindowController.swift` to compose components instead of hand-building
rows. `SettingsViewController`'s state, callbacks, and persistence logic are
untouched. Expected outcome: tab builders shrink substantially; visual
consistency is enforced by construction.

## Non-goals

- No new settings, no information-architecture changes, no settings search.
- No custom dropdown implementation.
- No changes outside the settings surface.

## Verification

- Build, relaunch via the background test harness (postToPid driver + window-ID
  screenshots), capture all four tabs at narrow (600pt) and wide (1200pt)
  window sizes.
- Confirm theme switching restyles every component (switch theme in General).
- Re-confirm the settings focus fix: after Done, typing lands in the active
  terminal.
