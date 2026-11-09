# soprano-editor — API report from EditorUi

`crates/soprano-editor` is finished. The 31 tests pass, clippy (all targets) and fmt are clean, the `editor_demo` example builds, and the Linux check passes. I did not run the Windows check.

**Commands** (target dir `target/agent-soprano-editor`):
- `cargo test -p soprano-editor`: 31 passed.
- `cargo clippy -p soprano-editor --all-targets`: clean.
- `cargo fmt -p soprano-editor --check`: ok.
- `cargo build -p soprano-editor --examples`: ok. It builds `examples/editor_demo.rs`, which shows the editor, the diff and the reader side by side; I did not run it.
- `cargo check --target x86_64-unknown-linux-gnu -p soprano-editor` (target dir `-cross`): ok.
- Windows not run: UiKit and ChatUi both hit gpui-pre's build script needing the Windows SDK. The one per-OS piece in my code is the chord mapping in `keys.rs`.

**Changes after your green ping, from TextPort's later list:**
- The editor clamps offsets with `clamp_offset`.
- The reader uses `ReaderHistory::record(..) -> bool`.
- The diff watcher uses `DiffLocation::needs_reload`.
- **Watcher drop order fix:** with soprano-text's new `FileWatcher`, closing the last tab of a file panicked in the test scheduler: the watcher's thread woke a task that was being dropped. Each view now drops the listening task before the watcher.

## Public API

**Setup the shell needs:**
- Bind keys once: `cx.bind_keys(editor::key_bindings(cx))`, `diff_view::key_bindings(cx)` and `reader::key_bindings(cx)`.
- The window needs gpui-component's `Root`. Text selection in `rich` depends on the selection layer it mounts.

**`rich`** (stateless elements):
- `Markdown::new(id, text, MarkdownStyle::{ASSISTANT, USER, THOUGHT, READER})`, or `MarkdownBlocks::new(id, Arc<[MarkdownBlock]>, style)` for a parsed model.
  - Builders: `.streaming(bool)`, `.on_link(Fn(&str, &mut Window, &mut App))`, `.text_color(Hsla)`, `.shrink_to_fit(bool)`, `.document(ReaderDocument)`, `.track_scroll(&ScrollHandle)`, `.column(width, [top, sides, bottom])`.
  - Without `on_link`, only http/https/mailto links open.
  - Text selects across blocks and copies with ⌘C.
- `RichText::new(id, text)`: `.highlights(..)`, `.font_overrides(..)`, `.links(ranges, LinkHandler)`, `.underline_hovered_link(bool)`, `.document_order(u64)`, `.selection_color(Hsla)`.
- `CodeBlock::new(id, language, code, tokens)` with `.wrap(bool)`: language header and a Copy button that shows a check for 1.2 s.
- Diff rows:
  - `DiffLineRow::new(id, DiffSide, DiffRowLayout { number_width, wrap, text_offset })` with `.selected(bool)`;
  - `DiffSplitRow::new(id, old, new, layout)` with `.selected_side(Option<bool>)`;
  - `DiffFoldRow::new(id, fold, number_width)` with `.on_expand(..)`;
  - `DiffStat::new(additions, deletions, size)` with `.mute_zero(bool)`;
  - `HunkDiff::new(id, Arc<InlineDiff>)` for chat hunks, plus `hunk_side`, `number_width` and `styled_highlights`.
- Free functions: `anchor_block`, `opens_externally`.

**Colors:** `SurfaceColors::of(cx)` gives `.code_syntax(kind)` (the editor/diff map) and `.markdown_syntax(kind)` (the chat/reader map).

**`EditorDocuments<T>`** is an entity, one per app, shared by every tab:
- `open(path, cx) -> DocumentId`, `attach`, `detach`, `document(id)`, `update(id, cx, f)`.
- `save`, `save_anyway`, `resolve_unsaved(ids, SaveChoice, cx)`, `relocate(old, new, cx)`, `store()`.
- It emits `DocumentsEvent::Changed { document, changes }`. It also runs each file's watcher and the delayed, off-thread syntax highlighting.

**`EditorView<T>::new(documents, target, path, window, cx)`:**
- Read state with `title(cx)`, `path(cx)`, `text(cx)`, `selected_range()`, `select(range, cx)`.
- Actions include `save`, plus the `Find`, `FindNext` and `FindPrevious` actions.
- Events (`EditorEvent`): `TitleChanged(SharedString)`, `ModifiedChanged(bool)`, `KeepTab` (first edit, so a preview tab is kept), `Saved`, `OpenMarkdownPreview(PathBuf)`, `FocusRequested`.
- Saving over a newer version on disk asks first ("Save Anyway"). Save errors show an alert.

**`DiffView::new(file, staged, StateStore, window, cx)`:**
- `set_shown(bool, cx)` stops watching while the tab is hidden and reloads when it shows again.
- Also `navigate(forward, cx)` (F7 / ⇧F7), `toggle_layout`, `set_layout`, `begin_selection`, `extend_selection`, `selected_text()`, `message()`, `document()`, `list()`, `layout()`.
- The layout choice is stored under `soprano-diff-side-by-side`.
- Events (`DiffEvent`): `OpenFile(PathBuf)`, `FocusRequested`.

**`MarkdownReaderView::new(path, window, cx)`:**
- `open_document(path, fragment, record, cx)`, `go_back`, `go_forward`, `reload`, `follow_link`, `title()`, `history()`.
- Pure helper for links: `reader::link_action(&ReaderDocument, dest) -> Option<ReaderLinkAction>`.
- Events (`ReaderEvent`): `TitleChanged`, `DocumentChanged(PathBuf)`, `OpenExternal(String)` (the app opens a browser pane), `FocusRequested`.

## Swift ported
- **Sources:** `EditorPaneView.swift`, `DiffPaneView.swift`, `DiffTextViews.swift` (view parts), `Surfaces/SurfaceKit.swift`, `Surfaces/SurfaceDiffRows.swift`, `MarkdownPaneView.swift`, the reader style sheet from `MarkdownHTMLRenderer.swift`, and the chat's `MarkdownRenderer.swift` / `MarkdownView.swift` (via `rich`). Also `DiffStyle` / `DiffStatText` from `InlineDiffDrawing.swift`.
- **`EditorTabTests`:**
  - `anEditorTabEditsSavesAndStopsBeingAPreview` (keyword tokens, the ● title, KeepTab, ⌘S only while focused);
  - plus tests for the shared buffer and undo across two tabs, indentation kept on Return, the overwrite question, find next/previous, and the binary-file note.
- **`GutterRulerTests`:** ported as a test that the gutter only lays out rows inside the viewport.
- **`MarkdownIntegrationTests`, view parts:** GFM with source HTML shown as text, viewable files open while scripts are only revealed, links to other Markdown files with back/forward, external links, the unreadable-file note.
- **Diff view:** a file outside any repository, the layout choice remembered across views (against a real git repository), copying the selected line on each split side, the staged/working titles.
- **Logic tests:** tab expansion, word motion, inline flattening, link underline, the parse cache, data images, diff row highlights.

## Deviations
- **Editor built on GPUI primitives, not gpui-component's code editor `Input`.** That editor keeps its own buffer and undo stack per instance and its highlighter re-parses per instance. So two tabs could not share one buffer and one undo history, which the Swift app does, and it would not use soprano-text's shared tokens. The editor does not wrap lines, as in Swift.
- **Line selection in another tab:** when you edit in one tab, the other tab's selection is clamped to the text and to character boundaries but does not shift with the edit, as NSTextView did.
- **Look follows Herdr:**
  - terminal font at 12 for the editor and 11 for diff rows, on 20 px lines;
  - the find bar sits at the top right (Swift's NSTextFinder bar was below the text);
  - the reader uses Geist instead of New York, since no serif font is bundled.
- **Small rendering approximations:**
  - inline code keeps the paragraph's font size (a GPUI line has one size), in the mono font on the chip;
  - tables use CSS-grid columns, not Swift's measured column widths;
  - a reader image inside a sentence sits on its own line.
- **Image formats GPUI cannot draw** (HEIC, PSD, …) show a new note, "“name” is an image Soprano can't show.", with Open with Default App.
- **Key mapping:** Save, Find and the reader's ⌘[ ⌘] ⌘R use Soprano's chord mapping (Ctrl+Shift off-mac). Copy, paste, undo and select all use each platform's own convention, so Ctrl+C on Linux and Windows.
- **Scrolling and drag-selection:** the editor's scroll bar is a 6 px indicator you cannot drag. The diff list does not scroll on its own while you drag a selection past its edge.

Peers were told when `rich` built and again when the crate went green after the soprano-text API change: ChatUi, DashboardUi, and Main (for the others). Nothing is committed.