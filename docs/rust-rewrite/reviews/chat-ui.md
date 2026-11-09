I found 10 issues in `soprano-chat-ui`, most severe first. The worst one: scrolling the timeline with the mouse wheel or trackpad will crash the app. `cargo test -p soprano-chat-ui` passed 47 of 47, but no test scrolls with the wheel, clicks a popover's own chip, or presses Stop while a question is open, so none of these are covered.

### 1. P0: scrolling the timeline crashes the app
- **Where:** `timeline_view.rs:100` (the scroll callback) and `timeline_view.rs:255` (`scrolled`). Swift: `TimelineListView.swift:373` (`didScroll`).
- **What differs:**
  - The list runs its scroll callback while it still has its internal state locked (`gpui-pre-0.3.12/src/elements/list.rs:1635` calls it inside its own `scroll()` at `:907`).
  - Our callback calls `scrolled`, which reads the list's following state again. Reading it while it is locked crashes the app.
- **Consequence:** any mouse-wheel or trackpad scroll over a chat tab, or over the Dashboard transcript (which uses the same view), crashes. Arrow keys and Page Up/Down are not affected.
- **Fix:** take the value from the scroll event instead of reading the list again: `list.set_scroll_handler(move |event, _, cx| { let following = event.is_following_tail; … view.set_following(following, cx) })`. `set_following` holds the `was_following` / emit logic and never touches `self.list`.

### 2. P1: with a question open, the Stop button sends the answer instead of stopping
- **Where:** `composer.rs:415` (`primary_clicked`) and `composer_parts.rs:498` / `:847`. Swift: `ChatComposerView.swift:517`.
- **What differs:**
  - While answering a question, the round button is drawn as Stop.
  - A click recomputes the action from scratch, and that ignores question mode. With a typed answer in the editor the result is Queue or Steer, so `submit` runs and moves to or submits the answer.
  - Swift acts on the action actually shown on the button.
- **Consequence:** with a typed answer on screen, clicking Stop moves to the next question or sends the answer to the agent; the turn is never interrupted.
- **Fix:** pass the drawn `action` into the click closure: `if action == Stop { cancel } else { submit(alternate) }`.

### 3. P2: clicking an open popover's chip reopens it, and outside clicks lose keyboard focus
- **Where:** `popovers.rs:274` (closing on an outside mouse-down), `composer.rs:553` (`toggle_popover`), `composer.rs:578` (`close_popover`). Swift: `ComposerPopover.swift:113-122` and `ChatComposerView.swift:865`.
- **What differs:**
  - Pressing on the chip closes the popover first. Releasing then counts as a click on the chip, which finds no popover open and opens it again.
  - Swift swallows that press so the chip toggles the popover closed.
  - Swift also gives the editor the keyboard back whenever a popover closes. Rust leaves focus on the popover that is gone.
- **Consequence:**
  - The model, thinking and permission chips and the context ring cannot close their own popover, which reopens with its search and highlight reset.
  - After clicking any spot that can't take the keyboard (e.g. the composer padding or the plan panel), typing goes nowhere.
- **Fix:**
  - Skip the close when the press lands on the anchor's bounds (`anchors.*`).
  - Make every close path call `focus_editor`.

### 4. P2: opening a row stops following, and can scroll the row out of view
- **Where:** `timeline_view.rs:296-297` (`toggle`) and `:355-356` (`reveal_diff`). Swift: `ChatTimelineView.swift:224` and `TimelineListView.swift:358`.
- **What differs:**
  - Rust always scrolls to the opened row and then stops following.
  - Swift does nothing, and keeps following, when the header is already in view (8 pt margins); otherwise it centres the header.
  - GPUI's reveal also lines the row's bottom up with the bottom edge when the top visible row is tall, and rows that were just inserted have no measured height yet.
- **Consequence:**
  - Opening a group, entry or diff during a running turn stops following and shows "Scroll to end".
  - The click can move the header down to just above the composer, hiding what was just opened.
- **Fix:** after `reload`, do nothing if the row is already visible (use `bounds_for_item` against the viewport minus the inset). Otherwise scroll it to the top, and stop following only in that case.

### 5. P2: scrolling inside a diff, command output or approval detail also scrolls the timeline (from the row-views scout; I checked it in the GPUI source)
- **Where:** `row_views.rs:510`, `:598`, `:731`. Swift: `WorkLogRows.swift:607` (`PassThroughScrollView`).
- **What differs:**
  - A scrollable box in GPUI doesn't stop the wheel event (`div.rs:3399-3440`), and the list's hit test also matches, so both scroll.
  - Swift hands the wheel to the timeline only at the box's edge.
- **Consequence:** the box and the whole timeline scroll together, and scrolling up also stops following.
- **Fix:** give each box a scroll handle and an `on_scroll_wheel` handler that stops the event while the box can still move in that direction.

### 6. P2: long diff lines are cut off in narrow lanes
- **Where:** `row_views.rs:599` relies on `overflow_x_scroll`. The line's code cell in `soprano-editor/src/rich/diff.rs:164-178` is full-width and clips what doesn't fit, and its sideways offset is always 0 (`:458`). Swift: `FileDiffRowView.swift:130-136` and `:276`.
- **Consequence:** when lines don't wrap (narrow split panes), the rest of each line is clipped and can't be scrolled to. Swift makes the diff as wide as its longest line and scrolls sideways.
- **Fix:** when not wrapping, give the diff a minimum width of the number column plus the longest line's columns (capped at 2000), and stop clipping the code cell.

### 7. P2: keyboard highlight in the `/` menu and the model picker isn't scrolled into view
- **Where:** `composer_parts.rs:613`, `composer.rs:681`, `popovers.rs:403` and `:207`. Swift: `ComposerPopover.swift:587` (`scrollRowToVisible`).
- **Consequence:**
  - ↑/↓ past the visible rows moves the highlight off screen (288 px for `/`, 280 px for models).
  - When the picker opens, the current model's row may not be visible.
- **Fix:** give each list a scroll handle and scroll the highlighted row into view on every highlight change.

### 8. P3: the `/` menu's highlight doesn't follow when the command list changes
- **Where:** `composer.rs:355`. Swift: `SlashCommandMenu.swift` (`show(…, keepingHighlight:)`).
- **What differs:**
  - Rust picks the highlight only when the typed token changes.
  - Swift re-lists on every refresh, keeping the same command highlighted or falling back to the first one.
- **Consequence:** if you type `/` before the agent's commands arrive, nothing is highlighted once they load. Return then just closes the menu, and a second Return sends a bare "/" to the agent. If the list shrinks, the highlight can point past its end.
- **Fix:** in `sync_slash_menu`, also recompute the highlight against the current matches: keep it by insert text, else highlight row 0.

### 9. P3: a failed work group's icon isn't red, and its summary has no hover colour
- **Where:** `row_views.rs:418-440`. Swift: `WorkLogRows.swift:380-382` and `:181`.
- **What differs:**
  - `render_group` never reads `model.failed`, so the icon stays muted (Swift: error colour at 85%).
  - The hover colour on the outer div is overridden by the line's own muted label colour, so hovering changes nothing.
- **Fix:**
  - Set the icon colour to `t.failed.opacity(0.85)` when the group failed.
  - Set the hover colour on the label itself.

### 10. P3: the changed-files card prints "+12 -3" with a hyphen
- **Where:** `row_views.rs:830` and `:952` (through `DiffStat`). Swift: `ChangedFilesCardView.swift:9` uses "−" (U+2212).
- **Fix:** add a "−" option to `DiffStat` for the card header and tree totals.

### Checked and matching
- **Composer keys:** Return, ⇧Return, ⌘Return (Ctrl+Shift+Enter elsewhere), Esc order (`/` menu, then popover, then stop), ↑/↓ history including the "" at the end, digits 1–9 for options, Tab and Return in the `/` menu.
- **Composer logic:**
  - when Return queues, steers or sends;
  - restart on a stopped agent;
  - the approval panel (Decline, Approve, More menu, detail/reason fallbacks) and decline-and-redirect;
  - question drafts, the 200 ms auto-advance, Previous/Next/Submit and stashing the composer's text;
  - placeholders, chip compaction and chip disabling, and the context card strings.
- **Timeline:** jumping between messages, Home/End/Page/Space, the "Scroll to end" pill, the details toggle (clears turns/groups/diffs), and `reveal_diff`'s two passes.
- **The row-logic scout** found row ids, order, labels, grouping and the changed-file tree matching Swift. Its only differences are low-severity edge cases where Rust trims fewer kinds of whitespace (`work_log.rs:155`, `:225`, `:404`, `:494`).
- **Not counted as behaviour bugs:**
  - performance: the 1 s clock re-renders the whole timeline (`timeline_view.rs:270`), and open diffs and the file tree are rebuilt on every render;
  - the error row's timestamp has no tooltip (`row_views.rs:1025`).
- **No panics or leaked tasks found apart from #1.**

I didn't edit any files.