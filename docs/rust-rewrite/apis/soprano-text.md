# soprano-text — API report from TextPort

The new crate `crates/soprano-text` is finished. `CARGO_TARGET_DIR=target/agent-soprano-text cargo test -p soprano-text` passes (83 tests after the parity-review fixes in `reviews/text-ui.md`), clippy with `--all-targets` reports no warnings, and `cargo fmt` leaves no changes. Clippy is also clean for `x86_64-unknown-linux-gnu` and `x86_64-pc-windows-msvc`.

Every range in the crate is a UTF-8 byte range, so it can be used directly for GPUI text runs. There is no gpui and no TODOs.

## Public API (for the UI engineers)

**`syntax`** (port of `CodeSyntaxHighlighter.swift`)
- `SyntaxTokenKind`: `Keyword, String, Comment, Number, Type, Function, Attribute, Key, Tag, Heading, Inserted, Deleted`. It has `ALL`, `is_emphasized()` (Keyword/Tag/Heading are semibold) and `is_italic()` (Comment).
- `SyntaxToken { range: Range<usize>, kind }`, `LanguageStyle` and `CodeLanguage { id, style, keywords, … }`. `CodeLanguage` provides:
  - `for_file(name) -> Option<&'static CodeLanguage>`
  - `named(fence) -> Option<…>`
  - `sorted_keywords()`
- `tokens(text, &CodeLanguage) -> Vec<SyntaxToken>`.
- One static per language (`SWIFT`, `JAVASCRIPT`, `TYPESCRIPT`, … `MARKUP`, `MARKDOWN`, `DIFF`).
- Colors are not in this crate. The UI keeps the three Swift color maps: the editor/diff map (`DiffStyle.syntaxColor`), the chat map (`MarkdownRenderer.syntaxColor`) and the reader's `tok-*` CSS colors.

**`agent_output`** (port of `AgentOutputHighlighter.swift`)
- `highlight(text) -> Vec<OutputRun { range, style: OutputStyle { color: OutputColor, weight: OutputWeight, underline, code_background } }>`. The runs cover the whole text in order.
- `OutputColor` is a set of palette roles (`TextPrimary`, `TextMuted`, `Cyan`, `Blue`, `Success`, `Danger`, `Yellow`, `Syntax*`). `OutputWeight` is `Regular`/`Semibold`/`Bold`.

**`editor`** (port of `EditorDocument.swift` plus the document logic of `EditorPaneView.swift`)
- `EditorDocument::open(path)`. Read state with:
  - `path()`, `name()`, `content() -> &DocumentContent { Text, Image{width,height}, Unavailable(String) }`
  - `is_dirty()`, `disk_state() -> DiskState { InSync, Changed, Deleted }`, `is_read_only()`, `language()`
  - `tokens()`, `image_bytes()`, `rope()`, `text()`, `len()`, `is_empty()`, `text_version()`
  - `take_changes() -> Vec<DocumentChange { WillReplaceContent, Content, State, Highlights, Location, Edited }>`
- Toolbar helpers: `tab_title()` (adds `●` when dirty), `is_editable()`, `shows_reload()`, `shows_markdown_preview()`, `status() -> Option<EditorStatus { text, tone: StatusTone }>`.
- Editing: `replace(range, text)`, `type_text(range, text)` (keystrokes that continue at the typing caret — typing, backspace, forward delete — join one undo step), `break_undo_coalescing()`, `insert_newline(selection) -> caret` (keeps the line's indentation), `undo()` / `redo() -> Option<Range>`, `can_undo()` / `can_redo()`, `line_number(offset)`, `line_count()`, `clamp_offset(offset)` (clamp to the text and floor to a character boundary; use it for any offset a view kept across edits made elsewhere).
- Input methods: `mark_text(range, text) -> Range` applies marked (composing) text without recording undo; `commit_marked_text()` records the composition as one typing step (nothing when cancelled); `marked_range()`. `type_text` inside the composition commits it with the final text; `replace`, other edits, `undo` and `redo` commit a pending composition first.
- Find: `find_all`, `find_next(q, from)`, `find_previous(q, before)`. All wrap around and ignore case.
- Highlighting: `highlight_request() -> Option<HighlightRequest { version, text, language }>`, `apply_highlights(version, tokens) -> bool`, `highlight_now()`.
- Disk: `save() -> io::Result` (keeps permissions, writes through symlinks), `disk_changed_since_last_sync()`, `disk_did_change()`, `reload_from_disk()`, `discard_changes()`, `relocate(path)`.
- Free functions: `restore_selection(&selection, &Rope)` (clamped and floored to character boundaries), `format_file_size`, `is_image_file`, `number_column_width(largest, digit_width)` (gutter width).
- Constants: `MAXIMUM_TEXT_BYTES` (8 MB), `MAXIMUM_IMAGE_BYTES` (64 MB), `MAXIMUM_HIGHLIGHTED_LENGTH`, `HIGHLIGHT_DELAY_MS`, `WATCH_DEBOUNCE_MS`, `LINE_HEIGHT`, `GUTTER_PADDING`.

**`editor_store`** (port of `EditorDocumentStore`)
- `EditorDocumentStore<T /*tab target*/, V /*view key*/>` and `DocumentId`.
- Documents: `open(path)`, `get` / `get_mut`, `document_at`, `attach(view, target, id)`, `detach(&view)`, `has_unsaved_changes`, `relocate(old, new)`.
- Closing: `unsaved_when_closing(&targets)`, `unsaved_when_closing_all()`, `names(&ids)`, `resolve_unsaved(&ids, SaveChoice) -> CloseResolution { Proceed, Cancel, SaveBlocked{document, outcome} }`.
- Saving: `save(id)` and `save_anyway(id) -> SaveOutcome { Saved, NeedsOverwriteConfirmation, Failed(io::Error) }`.
- Dialog text: `save_question(&names) -> (title, message, button)`, `overwrite_question(name)`, `OVERWRITE_MESSAGE`.

**`find`**: `find_all`, `find_next`, `find_previous` over `&str`.

**`watch`**: `FileWatcher::new(path, debounce, on_change) -> FileWatcher`, the Swift editor's and reader's `ConfigFileWatcher` (`soprano_config::ConfigFileWatcher`): it watches the file's folder and a symlink target's folder, re-arms when the folder is replaced or the link re-pointed, and retries every `REARM_INTERVAL` (2 s) while the folder is missing. It calls `on_change` once after a quiet spell, on the watcher thread, so forward it to the UI thread. Dropping the watcher stops it.

**`diff`** (`DiffTextViews`, the logic parts of `DiffPaneView` and `SurfaceDiffRows`, built on `soprano_git::changes`)
- `DiffDocument::new(path, Vec<GitDiffLine>, language)` with fields `lines`, `unified`, `old`, `new`, `highlights`, `additions`, `deletions`, `max_line`, `max_columns`, `change: FileChange`. Methods: `emphasis(row)`, `tokens(row, old_side)`, `side(row, old_side) -> Option<DiffSide { kind, number, text: StyledLine }>`.
- `StyledLine::build(raw, tokens, emphasis)` produces `{ text, spans: Vec<StyledSpan { range, syntax, emphasized }> }`. It cuts lines to 2000 characters, shows line-breaking characters as symbols and expands tabs, with spans re-mapped onto the display text. Also `display_text(text)`.
- `DiffList::build(doc, DiffListLayout, collapsed, &expanded)` produces `{ rows: Vec<DiffListRow>, change_rows }` with three lines of context and folds. Methods: `section`, `line`, `text(&DiffSelection, doc)`, `select_all`, `next_change` / `previous_change`, `anchor_line`, `row_for_line`, `wrapped_height`.
- Fold and selection types: `DiffFold { id, rows, range, section }` with `hidden_lines()` and `label()`; `DiffSelection { anchor, head, old_side }`.
- Layout math: `columns`, `wrapped_lines`, `code_width`, `split_divider_x`, plus row and header height constants.
- Loading: `load_diff(path, staged) -> DiffLoadResult { location, file_exists, content: DiffContent { Text, Message } }` (the path is standardized first), `diff_message(&GitFileDiff, staged)` (binary, too large, no changes, empty file notes), `DiffLocation::is_relevant` / `needs_reload(&paths, needs_rescan, external_git_dir)` / `watched_paths`, `relative_path`, `resolved_path` (no `\\?\` prefix on Windows).

**`hunks`** (chat edit diffs: `InlineDiffDrawing` and the model from `FileDiffRowView`)
- `parse_hunks(text) -> Vec<DiffHunk { old_start, new_start, section, lines: Vec<HunkLine> }>`.
- `HunkHighlights::compute(hunks, path)`.
- `InlineDiff::new(diff, path, full_content)` with `lines: Vec<InlineDiffLine { Separator, Line{line, numbered} }>`, `additions`, `deletions`, `max_number`. Methods: `highlight()`, `is_highlighted()`, `tokens(line)`.

**`markdown`** (`MarkdownDocument`, plus the model rules of `MarkdownRenderer`, `MarkdownHTMLRenderer` and `MarkdownPaneView`)
- `parse(text, line_breaks) -> Vec<MarkdownBlock>` with smart punctuation (’ “” – — …, as swift-markdown). Blocks: `Paragraph`, `Heading{level, inlines, anchor}`, `List{ordered, start, items}`, `Blockquote`, `Code{language, code, tokens}`, `Table(MarkdownTable { alignments, header: Vec<TableCell>, rows: Vec<Vec<TableCell>> })`, `ThematicBreak`, `Html(source)`. `TableCell { inlines, colspan, rowspan }` models GFM `||` / `^` spans; skip `is_covered()` cells.
- Inline model is `MarkdownInline`. Helpers: `plain_text`, `highlighted_code`, `bullet(depth)`, `ordered_marker(n, depth)`, `heading_slug` (full case folding, diacritics stripped, recomposed).
- Links and images: `resolve_link(dest, doc, root) -> Option<LinkTarget { Anchor, Markdown{path, fragment}, File, External }>`, `resolve_image(..) -> Option<ImageSource { File, Remote, Data }>`, `access_root(doc)`, `is_markdown`, `opens_linked_file`.
- Reader: `ReaderHistory` (`record(path) -> bool` — false when the path is already the current document: only scroll to the fragment —, `back`, `forward`, `current`, `can_go_back`, `can_go_forward`) and `unreadable_document(path, err)`.

**`context_line`** (port of `PaneContextLine.swift`)
- `ContextLine { context, branch, tab_count }` with `for_title(title, agent_name, cwd, branch, tab_count, home)`, `is_empty()`, `parts() -> Vec<ContextPart { Text, Branch }>` and `SEPARATOR`.
- `folder_name(path, home)`.

## What was ported
Sources: `CodeSyntaxHighlighter`, `AgentOutputHighlighter`, `EditorDocument` (document and store), `EditorPaneView` (indentation on Return, status, title, gutter width, find), `DiffTextViews`, the loader, navigation and selection logic of `DiffPaneView`, the row text of `SurfaceDiffRows`, `InlineDiffDrawing` and the `FileDiffRowView` model, `MarkdownDocument`, the model parts of `MarkdownRenderer`, the safety and slug rules of `MarkdownHTMLRenderer`, the link, history and access-root rules of `MarkdownPaneView`, and `PaneContextLine`.

Tests ported:
- `CodeSyntaxHighlighterTests`, except the AppKit color and font tests.
- `AgentOutputHighlighterTests`, except the accent check, which no longer applies because there is no accent role.
- All logic tests of `EditorDocumentTests`.
- The document parts of `EditorTabTests` (the `●` title and keyword tokens).
- The `GitChangesTests` cases for `SurfaceDiffDocument` and `SurfaceDiffList` (folds, `displayText`, split copy).
- The stacked/split rows of `SourceControlViewTests`, plus a test against a real git repository.
- From `MarkdownIntegrationTests`: GitHub-flavored Markdown with escaped source HTML, percent-encoded links decoded once, and linked files that never run scripts or apps.

`GutterRulerTests` only checks AppKit drawing clipping, so I ported the width calculation instead.

## Deviations and why
- **Diff layout lives in `soprano-git`:** per your note, I depend on `soprano-git` and reuse `GitDiffLine`, `GitDiffLayout`, `GitDiffHighlights` and `GitFileDiff`. The `similar` crate is not used: Swift's diffs come from git, and its intra-line ranges are a prefix/suffix comparison that `soprano-git` already ports.
- **Byte ranges instead of UTF-16:** the Swift code counted UTF-16 units. The 1.5M highlight limits (editor and chat hunks) still count UTF-16 units, as Swift did.
- **No shebang detection:** the brief mentions it, but the Swift app never detects languages by shebang, so I did not add it.
- **Store asks instead of blocking:** the Swift store called blocking alert callbacks. GPUI prompts are asynchronous, so the store returns what needs asking and takes the answer back through `resolve_unsaved` / `save_anyway`.
- **Changes are queued, not observed:** the document queues `DocumentChange`s instead of calling observers, and highlighting is a request/apply pair that the UI debounces.
- **No HTML output:** the reader is drawn natively, so `MarkdownHTMLRenderer`'s HTML string output was not ported; only its safety rules (unsafe links and image sources are refused, source HTML stays visible as text), heading slugs, task boxes, table alignment and code highlighting were.
- **Extension lists replace UTType:** image detection, the "opens linked file" check and the size formatter use extension lists and `imagesize` instead of UTType and NSImage. Any file with an executable bit counts as not viewable.
- **`folder_name` is duplicated:** `context_line` has a small local copy of `TerminalTitle.folderName` (same rules as `soprano_model::terminal_title::folder_name_in`) so it does not depend on `soprano-model`.
- **Chat hunks:** they are split on `\n` only.
- **`FileWatcher` reuses `soprano-config`'s `ConfigFileWatcher`,** as the Swift editor and reader used `ConfigFileWatcher`.

## Commands run
- `cargo test -p soprano-text`: 71 passed. The watcher test was flaky at first because the backend reported events from before the burst; it now drains those first and passed 8 runs in a row.
- `cargo clippy -p soprano-text --all-targets`: no warnings.
- `cargo fmt -p soprano-text`.
- `cargo clippy --target x86_64-unknown-linux-gnu` and `--target x86_64-pc-windows-msvc` (target dir `target/agent-soprano-text-cross`): no warnings.

While other crates had broken manifests, I built from a temporary workspace in `/tmp` (since deleted), then reran everything in the real worktree. The root `Cargo.lock` changed because of the new dependencies: `fancy-regex`, `imagesize`, `notify`, `percent-encoding`, `pulldown-cmark`, `ropey`, `unicode-normalization`, `unicode-segmentation` and `libc`. Nothing was committed.