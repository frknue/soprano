I found 3 high-severity and 9 medium-severity differences across `soprano-text` and `soprano-ui`. The editor's save path matches Swift: no case loses edits, and permissions and symlinks are handled the same way. All theme palette hex values and the palette search ranking also match.

Tests: `cargo test -p soprano-text` passed 71 of 71 and `cargo test -p soprano-ui` passed 91 of 91. I checked the editor/store/watcher and the high-severity items myself in the code; six read-only helpers did the other side-by-side comparisons, and I re-checked the ones marked as confirmed.

## High

**1. Markdown has no smart punctuation** (soprano-text) — confirmed
- **Rust:** `markdown.rs:111` turns on only tables, task lists and strikethrough.
- **Swift:** `MarkdownDocument.swift:56` and `MarkdownHTMLRenderer.swift:18` call `Document(parsing:)` with no options. swift-markdown's `CommonMarkConverter.swift:614-616` then adds `CMARK_OPT_SMART`.
- **What the user sees:** every chat message and reader document shows straight `'` and `"`, `--` and `...`, where Swift showed ’ “” – — …. Copy and search see the different text too.
- **Fix:** add `Options::ENABLE_SMART_PUNCTUATION`.

**2. The theme never sets the app's light/dark appearance** (soprano-ui) — confirmed
- **Rust:** `theme/mod.rs` (`install`, `change`) never calls `cx.set_window_appearance`, and no crate does. `ThemeManager::follows_system()` (`manager.rs:75`) is never used.
- **Swift:** `ThemeManager.swift:44-85` (`applyApplicationAppearance`) sets `NSApp.appearance` to `nil` while following the system, otherwise to the resolved theme's appearance. It does this on every `update`, even when the palette doesn't change.
- **What the user sees:** with a dark theme on a light-mode Mac, menus, the title bar, alerts and open/save panels stay light. Folio Paper on a dark-mode Mac gets dark ones.
- **Fix:** add `apply_app_appearance(cx)` and call it from `install` and from every branch of `change`, including when `changed == false`. Use `None` when following the system, otherwise `Some(Light|Dark)`.

**3. A regex error makes the output highlighter loop forever** (soprano-text) — confirmed in fancy-regex 0.14's source
- **Rust:** `agent_output.rs:207-211` does `pattern.find_iter(line).flatten()`. In fancy-regex 0.14, after an error such as the backtrack limit, `Matches::next` keeps returning the same error without moving forward (`lib.rs:~302`). `flatten()` skips it and calls `next()` again, so the loop never ends.
- **Which patterns:** `path`, `flag`, `function_call`, `attribute` and `json_key` use lookaround, so they run in fancy-regex's backtracking engine.
- **What the user sees:** one very long output line can freeze the UI thread. Swift's `NSRegularExpression` never fails partway. How often real output reaches the limit is unverified.
- **Fix:** `for found in pattern.find_iter(line) { let Ok(found) = found else { break }; … }`. Optionally raise `backtrack_limit` as well.

## Medium

**4. A selection kept across a reload can split a character, and copying it crashes** (soprano-text)
- **Rust:** `editor.rs` `restore_selection(selection, length)` only limits offsets to the text length; it never moves them to a character boundary. The editor puts the result straight into `anchor`/`head` (`soprano-editor/src/editor/mod.rs:376-380`). Copy (`:680`), cut and use-selection-for-find (`:496`) then call `rope().byte_slice(range)`, which panics off a character boundary (ropey 1.6.1, `rope.rs:966`).
- **Trigger:** select text, then another program rewrites the file so the old byte offset lands inside a multi-byte character (CJK, emoji), then ⌘C.
- **Swift:** an `NSRange` never crashes here.
- **Fix:** pass the rope to `restore_selection` and move each end down to a character boundary. The same length-only clamp at `mod.rs:398-399` also affects a second tab showing the same document.

**5. The file watcher misses changes to a symlink's target and never re-arms** (soprano-text)
- **Rust:** `watch.rs:28-36` watches only the folder of the path it is given (`soprano-editor/src/documents.rs:157` passes the unresolved document path).
- **Swift:** `ConfigFile.swift:351-454` also watches the file itself (`open(O_EVTONLY)` follows the symlink), re-arms after renames and deletes, and retries every 2 s while the folder is missing.
- **What the user sees:**
  - A document opened through a symlink into another folder never auto-reloads or shows "Changed on disk". The check at save time still catches it, so no edits are lost.
  - A document whose folder doesn't exist when it opens never gets a watcher.
- **Fix:** also watch `fs::canonicalize(path)`'s folder (or the file), and re-arm on remove/rename events and while the folder is missing.

**6. The diff highlight limit counts UTF-8 bytes, not UTF-16 units** — confirmed
- **Rust:** `hunks.rs:200` and `soprano-git/src/changes.rs:596` compare `text.len()` with the 1.5M limit.
- **Swift:** `InlineDiffDrawing.swift:176-182` and `GitChanges.swift:468-474` count `utf16`.
- **What the user sees:** diffs of non-ASCII text lose syntax colors at a third to half the size Swift handled.
- **Docs:** `apis/soprano-text.md` says this limit still counts UTF-16; that is only true for the editor.
- **Fix:** keep a separate UTF-16 counter, and keep the byte `starts` for the ranges.

**7. `ReaderHistory::record` adds the current document again** (soprano-text)
- **Rust:** `markdown.rs:707` always cuts the forward entries and pushes.
- **Swift:** `MarkdownPaneView.swift:128-133` returns early, scrolling to the fragment, when the document is already open.
- **What the user sees:** a `README.md#usage` link inside README.md adds a duplicate entry and drops the forward history. Back then seems to do nothing.
- **Fix:** normalize the path and return when it equals `current()`.

**8. Heading anchors don't match Swift's** (soprano-text, `markdown.rs:201`)
- **Case folding:** Rust uses `to_lowercase`, so "Straße" becomes `straße`. Swift's `folding(.caseInsensitive)` gives `strasse` [INFERENCE: Foundation behavior, not run]. Existing `#strasse` links stop working.
- **Hangul:** Rust decomposes with `nfd()` and never recomposes, so a `#한국어` link can never match its heading.
- **Fix:** full case folding, and `.nfc()` after stripping the marks. The `heading_anchors_fold_case_and_diacritics` test will need its expected value updated.

**9. On Windows, `resolved_path` uses verbatim paths, so diff tabs never refresh** (soprano-text)
- **Rust:** `diff.rs:739` uses `fs::canonicalize`, which gives `\\?\C:\…` paths. Watchers report plain paths, so `is_relevant` never matches.
- **Fix:** strip the prefix the way `soprano-files/src/root.rs:29-43` already does.

**10. Ctrl-N / Ctrl-P don't move the palette selection on macOS** (soprano-ui)
- **Rust:** `picker.rs:513-520` handles only the input's MoveUp/MoveDown, which gpui-base binds to the arrow keys.
- **Swift:** Cocoa's standard key bindings send `moveDown:`/`moveUp:` for ^N/^P too.
- **Fix:** bind `ctrl-n`/`ctrl-p` in the `SopranoPicker` context on macOS.

**11. Monograms use code points and different letter classes** (soprano-ui)
- **Rust:** `identity.rs:20-39` splits words with `is_alphabetic`/`is_numeric` and takes `chars()`.
- **Swift:** `ShellKit.swift:20-29` treats letters as L* and M* and works on grapheme clusters.
- **Examples:** "हिन्दी" and "第三版" (Swift `第三`, Rust `第版`) get different monograms.
- **Fix:** iterate graphemes and use the L/M/Nd categories.

**12. ⌘↩ confirms a prompt dialog** (soprano-ui)
- **Rust:** `dialog.rs:323` accepts every `PressEnter`, including `secondary`.
- **Swift:** only a bare Return or keypad Enter confirms (`ShellDialogs.swift:659-676`).
- **Fix:** ignore `secondary: true`.

## Low
- **`context_line::folder_name`** (`context_line.rs:75-83`) removes only one trailing `/` and only splits on `/`. `/a/git//` gives `/a/git/` where Swift gives `git`, and Windows paths show in full. Copying `soprano-model`'s `folder_name_in` fixes it.
- **Backspace undo steps:** `type_text(range, "")` deletions never join the typing undo step (`editor.rs` `edit`, called from `soprano-editor/src/editor/mod.rs:627`). Holding backspace gives one undo step per character; NSTextView groups the whole run [INFERENCE: AppKit behavior, not run].
- **Atomic write:** `soprano_platform::state::write_atomically` leaves `name.tmp-<pid>` in the user's folder if the write or rename fails. It also recreates a deleted parent folder, where Swift's save failed.
- **`DialogContent::save_changes`** (`dialog.rs:177-189`) hard-codes "Save". Swift says "Save All" for several files, and `save_question` already returns that. Nothing calls it yet.
- **Diff and markdown edge cases:**
  - The fold label cuts at 80 code points, not 80 graphemes (`diff.rs:511-513`).
  - `load_diff` doesn't normalize `..` in its path.
  - `is_relevant` has no "needs rescan" input.
  - Inline-diff paths ending in `/` get no colors (`hunks.rs:170`).
  - The character-literal escape window counts bytes.
  - Table `^`/`||` cell spans aren't modelled.
  - `opens_linked_file` is missing some extensions (mpg, caf, midi, psd, RAW formats, patch/diff, …).
- **Palette text matching:** Rust lowercases a word-final Σ to ς, and composed vs decomposed accents don't compare equal. This only affects Greek and decomposed text.

## Outside the two crates
- **Build error:** `crates/soprano/src/main_view.rs:1593` calls `soprano_ui::AppearancePreference::from_raw`, which doesn't exist; only `parse` does (`palettes.rs:46-64`). Use `parse`.
- **Wrong default terminal colors:** `crates/soprano-term/src/theme.rs:31-60` says it is "Folio Ink's terminal colors", but 17 of its 21 values differ from `Theme.swift` Folio Ink. The app replaces it with the real theme, so it only shows in defaults and the demo.

## Checked and matching
- **Editor and store:**
  - Opening and reading: the size limits, binary/UTF-8 detection, the "too large" and "unavailable" messages, and the missing-file-as-empty-buffer behavior.
  - Saving: through the real path (canonicalize, like `realpath`), keeping permissions, read-only state, the overwrite check, and change detection by signature and bytes.
  - Disk changes, reload, discard and relocate (folder prefix by path component).
  - The close and save flows and every dialog string.
  - Line numbers: ropey without default features counts LF only, like Swift.
  - Gutter width and file-size formatting.
- **Syntax highlighter:** all 26 languages, keyword sets, file-name and fence lookup, scanner branch order, and no panics on non-ASCII text.
- **Agent output highlighter:** every regex pattern and color/weight role matches character for character.
- **Themes:** all 9 themes × every UI slot × background/foreground/cursor/selection and the 16 ANSI colors are exact. Also matching: theme ids, names and order, the Folio light/dark resolution, ghostty config output, the mixing, attention and graph-lane math, and the status tones.
- **Palette search:** ranking matches exactly (label > description > search text, then exact > prefix > contained, then offset, then original order), and so do the keyboard clamps.
- **Status pill, badges, tooltips, project colors, keycaps** and `dialog_passes_chord_to_app` all match.