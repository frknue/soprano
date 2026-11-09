I found 20 problems across the two crates. Two are high: clicks in the editor's find bar fall through to the text behind it, and replies to chat tabs never get through. I didn't find any way for the editor to lose unsaved edits.

Someone was editing `crates/soprano-editor` while I reviewed it (uncommitted changes in `documents.rs`, `editor/mod.rs`, `element.rs`, `layout.rs`: moving the selection in other tabs, a draggable scroll bar, scrolling while dragging a selection). Findings and line numbers are against the working tree. Tests on that tree: `cargo test -p soprano-editor` 35 passed, `cargo test -p soprano-dashboard` 39 passed.

## High

**1. editor: clicking the find bar sends the click to the text behind it.**
- **Rust:** `editor/mod.rs:1309` attaches `mouse_down` to `editor-text`, and the find bar (`render_find_bar`, `:1420`) is drawn inside that element with nothing that blocks the click. The find field's `Input` doesn't stop the press either. So after the field takes focus, the editor's `mouse_down` runs: it calls `self.focus.focus(...)` and moves the caret to the text under the bar. It also sets `selecting`, so dragging in the field extends the editor's selection. The ↑ ↓ × buttons are fine because soprano-ui's `IconButton` stops the press.
- **Swift:** the NSTextFinder bar is its own view below the text (`EditorPaneView.swift:139,175`), so clicks never reach the text.
- **What users see:** once focus leaves the find field, they can't click back into it to change the query, and the click moves their caret.
- **Fix:** add `.occlude()` to the find-bar div, or `.on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())`.

**2. dashboard (in the shell): replies to chat tabs never work.**
- **Rust:** `crates/soprano/src/content.rs:695-699` (`visible_terminal_text`) returns `None` for anything that isn't a live terminal. `submit_agent_prompt` (`:703`) does the same, and `main_view.rs:917-921` never calls `ChatView::submit_prompt`.
- **Swift:** `SplitTreeView.swift:279-281` reports a running chat as available, and `:297-300` sends with `chatView.session.send(prompt)`.
- **What users see:** for a running chat agent, the reply field is disabled, Tab and R do nothing, and the hint says "Restart the agent before replying."
- **Fix:** return `Some(String::new())` for a running `PaneContent::Chat`, send `Reply` through `submit_prompt`, and call `reply_failed` when that returns false.

## Medium

**3. editor: IME composition fills the undo history with half-typed text.**
- **Rust:** `replace_and_mark_text_in_range` (`mod.rs:1144`) and the commit both call `type_text`, which replaces the marked range. In `soprano-text/src/editor.rs:436`, typing only joins the previous undo step when nothing was removed, or when it is a pure deletion. A replacement is neither, so every composition update becomes its own undo step.
- **Swift:** NSTextView makes a committed IME word one "Undo Typing".
- **What users see:** after typing 日本 with a Japanese input method, ⌘Z brings back にほん, then にほn, and so on.
- **Fix:** while text is marked, apply updates without recording them (or fold them into the open step), and record one step on commit.

**4. editor: the find bar has no Replace.** The Swift editor is an editable NSTextView with `usesFindBar = true` (`EditorPaneView.swift:139`). [INFERENCE] AppKit shows Replace in that bar for editable text; I didn't confirm this at runtime. The Rust bar only finds (`render_find_bar`). Fix: add a replace field with Replace and Replace All, each as one undo step.

**5. reader: a link that wraps an image is broken, and debug builds can panic.**
- **Rust:** `rich/inline.rs:108-123` records the link's `start` before walking its children. An image child flushes the text buffer, so `end` is measured on a new buffer and `start..end` mixes two strings.
- **Swift:** `MarkdownHTMLRenderer.swift:228-240` writes `<a>` around whatever the link contains.
- **What users see:**
  - Badge links like `[![CI](…svg)](…)` and linked screenshots can't be clicked.
  - Text after the image inside the link gets the wrong click range.
  - A stale `start` inside a multibyte character, as in `abcd [x ![i](i.png) 日本](d.md)`, trips gpui's char-boundary `debug_assert`.
- **Fix:** carry the destination on `InlinePiece::Image` and make the image clickable; close the link range at each flush and reopen it in the new buffer.

**6. diff: F7 / ⇧F7 put the change in the wrong place.**
- **Rust:** `scroll_to_row` (`diff_view.rs:~574-586`) estimates the height of the rows above the target with `list_state.bounds_for_item(ix-1)`. In gpui-pre 0.3.12, `list.rs:719` returns `None` for rows above the scroll top and for rows never drawn, so each such row counts as 20 px. Folds (28 px) and wrapped rows (40 px or more) are taller, and wrapping is on by default.
- **Swift:** `DiffPaneView.swift:503-517` uses the real row positions (`rect(ofRow:).minY - height/3`).
- **What users see:** ⇧F7 can put the change at the bottom edge or off-screen.
- **Also:** when the loop stops early, the leftover distance is dropped (`offset_in_item: 0`). The row a third of the way down can then be the row after the target, so ⇧F7 right after F7 jumps to the same change again.
- **Fix:** add up real heights with the existing, unused `DiffList::wrapped_height`, and keep the leftover in `offset_in_item`.

**7. reader: a UTF-8 BOM breaks the first block.** `reader.rs:199-202` passes the file text to pulldown-cmark unchanged. swift-cmark skips the BOM (`blocks.c:1521`). In a README saved with a BOM, `# Title` shows as a plain paragraph and loses its anchor. Fix: `strip_prefix('\u{FEFF}')` before parsing.

**8. markdown (soprano-text): email autolinks lose `mailto:`.**
- **Rust:** `soprano-text/src/markdown.rs:499` ignores the link type, so `<user@example.com>` becomes a relative file link. The reader reveals a path that doesn't exist; in the chat the click does nothing.
- **Swift:** swift-cmark prefixes `mailto:`.
- **Fix:** for `LinkType::Email`, prefix `mailto:`.

**9. reader: remote images never load, and broken images show nothing.** The scout grepped and found no HTTP client installed anywhere in `crates/`, so `img(url)` for `https` images fails (`rich/markdown.rs:595-602`). There is also no `.with_fallback`, so missing local or `data:` images are blank and the alt text is lost. Swift's content security policy allows `https:` images, and WebKit shows alt text. Fix: install an HTTP client at app start and add an alt-text fallback.

**10. reader: no keyboard scrolling and no ⌘A.** `reader.rs:346-349` handles only back, forward and reload. Arrows, Space, Page Up/Down and Home/End don't scroll, and Select All doesn't work. The Swift WKWebView did all of these.

## Low

11. **dashboard:** "Could not send to this terminal." stays up until the selection changes (`view.rs` `sync_detail`, ~`:368`). Swift's `updateControls` puts the status-based hint back on the next detail update. Fix: also clear `reply_failed` when the selected agent's status or terminal availability changes.
12. **diff:** turning wrapping on or off changes every open diff tab, because they share the global `WRAPS_LINES` (`diff_view.rs:50,636`). Their wrap buttons go stale until they repaint. Swift keeps `wrap` per view. Fix: a per-view field, writing the global only as the default for new tabs.
13. **diff:** right-clicking a fold row, the end space or below the rows shows no menu (`diff_view.rs:~724-731`). Swift offers Copy and Copy File Path there (`SurfaceDiffRows.swift:550`).
14. **diff:** a sideways trackpad swipe also scrolls the list vertically. Swift locks a gesture to the axis it started on.
15. **editor:** each ←/→, ⌥←/→, Backspace/Delete and double-click copies the whole document with `self.text(cx)` (`mod.rs:685,855,867,912`). Files can be up to 8 MiB, so that is up to 8 MiB copied per key press. Fix: work on rope slices around the caret.
16. **editor:** text being composed with an input method isn't underlined. `EditorPaint` (`element.rs`) has no marked range, so it can't be told apart from committed text.
17. **editor:** clicking the image view, the unreadable-file note or the toolbar doesn't emit `FocusRequested` or take focus. Swift's `mouseDown` override did this for the whole pane.
18. **dashboard** [INFERENCE, not tested at runtime]: `keys.rs:51` also rejects the `function` modifier. gpui keeps that flag for Return and letter keys, so fn+Return (keypad Enter) may not open the agent, though Swift handles key code 76.
19. **reader, smaller differences:**
    - `data:` images that aren't base64 aren't percent-decoded (`markdown.rs:795`).
    - The unreadable-file note shows Rust error text ("No such file or directory (os error 2)") instead of Cocoa's wording.
    - `open_document` (`reader.rs:171`) treats "current in history" as "shown on screen". A later recorded open of that document can then only scroll and never open it.
    - Viewable files with the execute bit set (a 0755 PNG or PDF) are only revealed; Swift decides by file type alone.
    - Link and image `title` tooltips and the breadcrumb path tooltip are missing.
    - `#anchor` links scroll to the top of the list or quote that holds the heading, not the heading itself.
20. **Test gaps:**
    - No end-to-end test that an open diff reloads when the file changes on disk.
    - No dashboard tests for a chat-tab reply, clearing the draft when the selection changes, or Esc in the reply field.

## Checked and matching Swift
- **Unsaved edits:**
  - One document per file path is shared by every tab.
  - Closing asks only about documents no remaining tab shows; quitting asks about all of them, sorted by name.
  - Don't Save reloads from disk; Save stops on an overwrite question or an error.
  - A change on disk keeps unsaved edits and shows "Changed on disk"; a clean buffer follows the file.
  - Reload and Save Anyway behave the same; saving over a newer file asks first.
  - Rename follows the file and re-watches its folder; undo history resets on reload.
- **Editor:** Return keeps the indentation up to the caret, Tab inserts a tab, typing groups into one undo step, case-insensitive find with wrap-around, ⌘S/⌘F/⌘G/⇧⌘G only while the pane has the keyboard, the status texts, the ● title, KeepTab. The editor's key bindings don't leak into the find field.
- **Diff:** loading, messages, git options, parsing, stacked and split pairing, folds, copy without +/- markers, reload debounce, the layout key, no panics found.
- **Reader:**
  - Link schemes: only http, https and mailto go out; `javascript:` and others go nowhere.
  - Paths can't escape the folder; scripts are only revealed.
  - Raw HTML always shows as source.
  - Heading slugs and GFM features match.
  - History and ⌘[ ⌘] ⌘R work.
- **Dashboard:**
  - Every key, with the list or the reply field focused.
  - Esc closes from anywhere; ⌘/⌃/⌥ chords pass through.
  - The reply goes to the agent selected at send time, by id, and survives reordering; it is trimmed and empty replies aren't sent.
  - Strings, toolbar rules, the output highlighter, and index handling all match.