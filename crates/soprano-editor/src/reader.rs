//! The Markdown reader (port of `Views/MarkdownPaneView.swift`; the page style of
//! `MarkdownHTMLRenderer.swift`): a read-only, themed rendering of a local Markdown file that
//! reloads when the file is saved (keeping the reading position), follows links to other
//! Markdown files with back/forward (⌘[ / ⌘]), scrolls to `#anchors`, opens viewable linked
//! files and only reveals anything that could run code, and hands web links to the app (it
//! opens a browser pane). Relative images load from inside the document's access root; source
//! HTML shows as source. Toolbar: breadcrumbs, back, forward, reload (⌘R), open in the default
//! editor, reveal.

use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use gpui::{
    App, Context, EventEmitter, FocusHandle, Focusable, InteractiveElement, IntoElement, KeyBinding,
    MouseButton, ParentElement, Render, ScrollHandle, SharedString, Styled, Task, Window, actions, div,
    point, px,
};
use soprano_text::markdown::{self as model, LinkTarget, MarkdownBlock, ReaderHistory, opens_linked_file};
use soprano_text::watch::FileWatcher;
use soprano_ui::IconName;

use crate::colors::SurfaceColors;
use crate::keys;
use crate::rich::markdown::{AnchorTracker, MarkdownBlocks, MarkdownStyle, ReaderDocument};
use crate::surface::{SurfaceToolbar, breadcrumbs, display_path, toolbar_button};

/// The key context of a focused reader.
pub const READER_CONTEXT: &str = "SopranoMarkdownReader";
/// The debounce of the watcher on the document's folder.
pub const WATCH_DEBOUNCE_MS: u64 = 180;
/// The reading column: 920 px, padded 32 / 42 / 48 (24 / 22 / 48 below 600 px).
pub const COLUMN_WIDTH: f32 = 920.0;

actions!(
    soprano_reader,
    [
        /// ⌘[: the previous Markdown file.
        GoBack,
        /// ⌘]: the next Markdown file.
        GoForward,
        /// ⌘R: read the file again.
        Reload,
        /// ⌘A: select the whole document.
        SelectAll,
    ]
);

/// Keyboard scrolling, as the web view did: arrows by a line, Space and Page keys by a page,
/// Home and End to the ends.
#[derive(Clone, Copy, Debug, PartialEq, Eq, gpui::Action)]
#[action(namespace = soprano_reader, no_json)]
pub enum ScrollReader {
    LineUp,
    LineDown,
    PageUp,
    PageDown,
    Top,
    Bottom,
}

/// One arrow-key step (WebKit's).
pub const LINE_STEP: f32 = 40.0;

/// The scroll offset (distance from the top, positive) after `action`, for a viewport
/// `page` tall over `max` of scrolling: pages keep one line of context.
pub fn scrolled(action: ScrollReader, current: f32, page: f32, max: f32) -> f32 {
    let page_step = (page - LINE_STEP).max(LINE_STEP);
    let next = match action {
        ScrollReader::LineUp => current - LINE_STEP,
        ScrollReader::LineDown => current + LINE_STEP,
        ScrollReader::PageUp => current - page_step,
        ScrollReader::PageDown => current + page_step,
        ScrollReader::Top => 0.0,
        ScrollReader::Bottom => max,
    };
    next.clamp(0.0, max.max(0.0))
}

/// Cocoa's wording for a file that cannot be read (`NSFileReadNoSuchFileError`, …), as the
/// Swift reader showed `localizedDescription`.
pub fn cocoa_error(path: &Path, error: &std::io::Error) -> std::io::Error {
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let message = match error.kind() {
        std::io::ErrorKind::NotFound => {
            format!("The file “{name}” couldn’t be opened because there is no such file.")
        }
        std::io::ErrorKind::PermissionDenied => {
            format!("The file “{name}” couldn’t be opened because you don’t have permission to view it.")
        }
        std::io::ErrorKind::InvalidData => format!(
            "The file “{name}” couldn’t be opened because the text encoding of its contents can’t be determined."
        ),
        _ => format!("The file “{name}” couldn’t be opened."),
    };
    std::io::Error::new(error.kind(), message)
}

/// The reader's key bindings; the app binds them once (`cx.bind_keys(key_bindings(cx))`).
pub fn key_bindings(cx: &App) -> Vec<KeyBinding> {
    let table: [(String, Box<dyn gpui::Action>); 3] = [
        (keys::command("["), Box::new(GoBack)),
        (keys::command("]"), Box::new(GoForward)),
        (keys::command("r"), Box::new(Reload)),
    ];
    let scrolling: [(&str, Box<dyn gpui::Action>); 10] = [
        ("up", Box::new(ScrollReader::LineUp)),
        ("down", Box::new(ScrollReader::LineDown)),
        ("pageup", Box::new(ScrollReader::PageUp)),
        ("pagedown", Box::new(ScrollReader::PageDown)),
        ("space", Box::new(ScrollReader::PageDown)),
        ("shift-space", Box::new(ScrollReader::PageUp)),
        ("home", Box::new(ScrollReader::Top)),
        ("end", Box::new(ScrollReader::Bottom)),
        ("secondary-up", Box::new(ScrollReader::Top)),
        ("secondary-down", Box::new(ScrollReader::Bottom)),
    ];
    table
        .into_iter()
        .chain(scrolling.into_iter().map(|(keys, action)| (keys.to_string(), action)))
        .chain(std::iter::once(("secondary-a".to_string(), Box::new(SelectAll) as Box<dyn gpui::Action>)))
        .filter_map(|(keys, action)| keys::bind(&keys, action, READER_CONTEXT, cx))
        .collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReaderEvent {
    /// The tab title: the document's file name.
    TitleChanged(SharedString),
    /// The reader now shows another file (the app updates the tab's saved URL).
    DocumentChanged(PathBuf),
    /// An `http`, `https` or `mailto` link: the app opens it (a browser pane, the mail app).
    OpenExternal(String),
    /// The reader was clicked or took the keyboard: focus its pane.
    FocusRequested,
}

/// What following a link does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ReaderLinkAction {
    /// A heading of this document.
    ScrollTo(String),
    /// Another Markdown file, in this reader (recorded in its history).
    OpenMarkdown { path: PathBuf, fragment: Option<String> },
    /// A file a viewer only displays: its default app opens it.
    OpenFile(PathBuf),
    /// Anything that could run code (an app, a script, an executable): revealed only.
    RevealFile(PathBuf),
    /// The browser or mail app.
    External(String),
}

/// What a link's `destination` in `document` does; `None` when it leads nowhere.
pub fn link_action(document: &ReaderDocument, destination: &str) -> Option<ReaderLinkAction> {
    Some(match document.resolve_link(destination)? {
        LinkTarget::Anchor(anchor) => ReaderLinkAction::ScrollTo(anchor),
        LinkTarget::Markdown { path, fragment } => ReaderLinkAction::OpenMarkdown { path, fragment },
        LinkTarget::File(path) if opens_linked_file(&path) => ReaderLinkAction::OpenFile(path),
        LinkTarget::File(path) => ReaderLinkAction::RevealFile(path),
        LinkTarget::External(url) => ReaderLinkAction::External(url),
    })
}

pub struct MarkdownReaderView {
    path: PathBuf,
    document: ReaderDocument,
    blocks: Arc<[MarkdownBlock]>,
    loaded: bool,
    history: ReaderHistory,
    /// The listening task drops before the watcher (tuple fields drop in order).
    watcher: Option<(Task<()>, FileWatcher)>,
    scroll: ScrollHandle,
    anchors: Rc<AnchorTracker>,
    focus: FocusHandle,
}

impl EventEmitter<ReaderEvent> for MarkdownReaderView {}

impl Focusable for MarkdownReaderView {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}

fn standardized(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map(|directory| directory.join(path)).unwrap_or_else(|_| path.to_path_buf())
    };
    soprano_platform::paths::normalize(&absolute)
}

impl MarkdownReaderView {
    /// Shows `path`, the first entry of the reader's history.
    pub fn new(path: impl AsRef<Path>, _window: &mut Window, cx: &mut Context<Self>) -> Self {
        // `https` images need an HTTP client; GPUI has none by default.
        crate::http::install_http_client(cx);
        let path = standardized(path.as_ref());
        let mut view = Self {
            document: ReaderDocument::new(path.clone()),
            path: path.clone(),
            blocks: Arc::from(Vec::new()),
            loaded: false,
            history: ReaderHistory::default(),
            watcher: None,
            scroll: ScrollHandle::new(),
            anchors: AnchorTracker::new(),
            focus: cx.focus_handle(),
        };
        view.open_document(&path, None, true, cx);
        view
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn blocks(&self) -> &[MarkdownBlock] {
        &self.blocks
    }

    pub fn history(&self) -> &ReaderHistory {
        &self.history
    }

    /// The tab title: the file name.
    pub fn title(&self) -> SharedString {
        self.path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default().into()
    }

    /// Shows `path` (scrolling to `fragment`), recording it in the history when asked; the
    /// file already shown only scrolls.
    pub fn open_document(
        &mut self,
        path: &Path,
        fragment: Option<String>,
        record: bool,
        cx: &mut Context<Self>,
    ) {
        let path = standardized(path);
        // The document on screen only scrolls (`MarkdownPaneView.openDocument`).
        if path == self.path && self.loaded {
            if let Some(fragment) = fragment {
                self.scroll_to_anchor(&fragment);
                cx.notify();
            }
            return;
        }
        if record {
            // False only when the history's current entry is this path already.
            let _ = self.history.record(path.clone());
        }
        self.path = path.clone();
        self.document = ReaderDocument::new(path.clone());
        self.watch(cx);
        cx.emit(ReaderEvent::TitleChanged(self.title()));
        cx.emit(ReaderEvent::DocumentChanged(path));
        self.read();
        self.scroll.set_offset(point(px(0.0), px(0.0)));
        if let Some(fragment) = fragment {
            self.scroll_to_anchor(&fragment);
        }
        cx.notify();
    }

    /// Reads the file again; the scroll position stays.
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        self.read();
        cx.notify();
    }

    fn read(&mut self) {
        self.blocks = match std::fs::read_to_string(&self.path) {
            // A byte order mark is not text (swift-cmark skips it too).
            Ok(source) => model::parse(source.strip_prefix('\u{FEFF}').unwrap_or(&source), false).into(),
            Err(error) => model::unreadable_document(&self.path, &cocoa_error(&self.path, &error)).into(),
        };
        self.loaded = true;
    }

    /// Brings the heading `anchor` to the top, on the next frame (when it has been drawn).
    fn scroll_to_anchor(&self, anchor: &str) {
        self.anchors.scroll_to(anchor);
    }

    fn watch(&mut self, cx: &mut Context<Self>) {
        let (sender, receiver) = async_channel::unbounded::<()>();
        let watcher = FileWatcher::new(&self.path, Duration::from_millis(WATCH_DEBOUNCE_MS), move || {
            let _ = sender.try_send(());
        });
        let task = cx.spawn(async move |this, cx| {
            while receiver.recv().await.is_ok() {
                if this.update(cx, |this, cx| this.reload(cx)).is_err() {
                    break;
                }
            }
        });
        self.watcher = Some((task, watcher));
    }

    pub fn go_back(&mut self, cx: &mut Context<Self>) {
        if let Some(path) = self.history.back().map(Path::to_path_buf) {
            self.open_document(&path, None, false, cx);
            cx.notify();
        }
    }

    pub fn go_forward(&mut self, cx: &mut Context<Self>) {
        if let Some(path) = self.history.forward().map(Path::to_path_buf) {
            self.open_document(&path, None, false, cx);
            cx.notify();
        }
    }

    /// Follows a clicked link.
    pub fn follow_link(&mut self, destination: &str, cx: &mut Context<Self>) {
        cx.emit(ReaderEvent::FocusRequested);
        let Some(action) = link_action(&self.document, destination) else { return };
        match action {
            ReaderLinkAction::ScrollTo(anchor) => {
                self.scroll_to_anchor(&anchor);
                cx.notify();
            }
            ReaderLinkAction::OpenMarkdown { path, fragment } => {
                self.open_document(&path, fragment, true, cx)
            }
            ReaderLinkAction::OpenFile(path) => {
                if let Err(error) = soprano_platform::system::open_default(&path.to_string_lossy()) {
                    tracing::warn!("{error:#}");
                }
            }
            ReaderLinkAction::RevealFile(path) => {
                if let Err(error) = soprano_platform::system::reveal_in_file_manager(&path) {
                    tracing::warn!("{error:#}");
                }
            }
            ReaderLinkAction::External(url) => cx.emit(ReaderEvent::OpenExternal(url)),
        }
    }

    /// Scrolls the reading column by keyboard.
    pub fn scroll_by(&mut self, action: ScrollReader, cx: &mut Context<Self>) {
        let offset = self.scroll.offset();
        let page = f32::from(self.scroll.bounds().size.height);
        let max = f32::from(self.scroll.max_offset().y);
        let next = scrolled(action, -f32::from(offset.y), page, max);
        self.scroll.set_offset(point(offset.x, px(-next)));
        cx.notify();
    }

    fn open_in_editor(&self) {
        if let Err(error) = soprano_platform::system::open_default(&self.path.to_string_lossy()) {
            tracing::warn!("{error:#}");
        }
    }

    fn reveal(&self) {
        if let Err(error) = soprano_platform::system::reveal_in_file_manager(&self.path) {
            tracing::warn!("{error:#}");
        }
    }
}

impl Render for MarkdownReaderView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let colors = SurfaceColors::of(cx);
        let (can_back, can_forward) = (self.history.can_go_back(), self.history.can_go_forward());
        let toolbar = SurfaceToolbar::new()
            .leading(breadcrumbs(&display_path(&self.path), &self.path, cx))
            .trailing(toolbar_button(
                "reader-back",
                IconName::ChevronLeft,
                "Previous Markdown file",
                can_back,
                cx.listener(|this, _, _, cx| this.go_back(cx)),
            ))
            .trailing(toolbar_button(
                "reader-forward",
                IconName::ChevronRight,
                "Next Markdown file",
                can_forward,
                cx.listener(|this, _, _, cx| this.go_forward(cx)),
            ))
            .trailing(div().w(px(6.0)))
            .trailing(toolbar_button(
                "reader-reload",
                IconName::RefreshCw,
                "Reload Markdown",
                true,
                cx.listener(|this, _, _, cx| {
                    cx.emit(ReaderEvent::FocusRequested);
                    this.reload(cx);
                }),
            ))
            .trailing(toolbar_button(
                "reader-open",
                IconName::ExternalLink,
                "Open in Editor",
                true,
                cx.listener(|this, _, _, cx| {
                    cx.emit(ReaderEvent::FocusRequested);
                    this.open_in_editor();
                }),
            ))
            .trailing(toolbar_button(
                "reader-reveal",
                IconName::Folder,
                soprano_platform::system::reveal_label(),
                true,
                cx.listener(|this, _, _, cx| {
                    cx.emit(ReaderEvent::FocusRequested);
                    this.reveal();
                }),
            ));
        let narrow = self.scroll.bounds().size.width > px(0.0) && self.scroll.bounds().size.width < px(600.0);
        let padding = if narrow { [24.0, 22.0, 48.0] } else { [32.0, 42.0, 48.0] };
        let entity = cx.entity().downgrade();
        let body = MarkdownBlocks::new("markdown-reader", self.blocks.clone(), MarkdownStyle::READER)
            .document(self.document.clone())
            .track_scroll(&self.scroll)
            .anchors(self.anchors.clone())
            .column(COLUMN_WIDTH, padding)
            .on_link(move |destination, _, cx| {
                let _ = entity.update(cx, |this, cx| this.follow_link(destination, cx));
            });
        div()
            .id("soprano-markdown-reader")
            .key_context(READER_CONTEXT)
            .track_focus(&self.focus)
            .size_full()
            .flex()
            .flex_col()
            .bg(colors.background)
            .on_action(cx.listener(|this, _: &GoBack, _, cx| this.go_back(cx)))
            .on_action(cx.listener(|this, _: &GoForward, _, cx| this.go_forward(cx)))
            .on_action(cx.listener(|this, _: &Reload, _, cx| this.reload(cx)))
            .on_action(cx.listener(|this, action: &ScrollReader, _, cx| this.scroll_by(*action, cx)))
            .on_action(
                cx.listener(|_, _: &SelectAll, window, cx| gpui_base::TextSelection::select_all(window, cx)),
            )
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, window, cx| {
                    this.focus.focus(window, cx);
                    cx.emit(ReaderEvent::FocusRequested);
                }),
            )
            .child(toolbar)
            .child(div().flex_1().min_h_0().w_full().child(body))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    use gpui::TestAppContext;
    use soprano_text::markdown::MarkdownInline;

    use crate::rich::markdown::{anchor_block, document_text};

    fn setup(cx: &mut TestAppContext) {
        cx.update(|cx| {
            soprano_ui::init_for_tests(cx);
            cx.bind_keys(key_bindings(cx));
        });
    }

    #[gpui::test]
    async fn links_open_other_markdown_files_with_back_and_forward(cx: &mut TestAppContext) {
        setup(cx);
        let root = tempfile::tempdir().unwrap();
        let readme = root.path().join("README.md");
        let guide = root.path().join("docs/guide.md");
        std::fs::create_dir_all(guide.parent().unwrap()).unwrap();
        std::fs::write(
            &readme,
            "# Readme\n\nSee [the guide](docs/guide.md#setup) or [the web](https://example.com).\n",
        )
        .unwrap();
        std::fs::write(&guide, "# Guide\n\n## Setup\n\nBack to [readme](../README.md).\n").unwrap();

        let (view, cx) = cx.add_window_view(|window, cx| MarkdownReaderView::new(&readme, window, cx));
        let events: Rc<RefCell<Vec<ReaderEvent>>> = Rc::default();
        let sink = events.clone();
        cx.update(|_, cx| {
            cx.subscribe(&view, move |_, event: &ReaderEvent, _| sink.borrow_mut().push(event.clone()))
                .detach();
        });
        assert_eq!(view.read_with(cx, |view, _| view.title()), "README.md");

        view.update(cx, |view, cx| view.follow_link("docs/guide.md#setup", cx));
        assert_eq!(view.read_with(cx, |view, _| view.path().to_path_buf()), standardized(&guide));
        assert!(events.borrow().contains(&ReaderEvent::TitleChanged("guide.md".into())));
        assert!(events.borrow().contains(&ReaderEvent::DocumentChanged(standardized(&guide))));
        assert!(view.read_with(cx, |view, _| view.history().can_go_back()));

        view.update(cx, |view, cx| view.go_back(cx));
        assert_eq!(view.read_with(cx, |view, _| view.path().to_path_buf()), standardized(&readme));
        assert!(view.read_with(cx, |view, _| view.history().can_go_forward()));
        view.update_in(cx, |view, window, cx| view.focus.focus(window, cx));
        cx.simulate_keystrokes(&keys::command("]"));
        assert_eq!(view.read_with(cx, |view, _| view.path().to_path_buf()), standardized(&guide));

        view.update(cx, |view, cx| view.follow_link("https://example.com", cx));
        assert!(events.borrow().contains(&ReaderEvent::OpenExternal("https://example.com".into())));
    }

    #[gpui::test]
    async fn an_external_save_is_shown_after_a_reload(cx: &mut TestAppContext) {
        setup(cx);
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("notes.md");
        std::fs::write(&path, "one\n").unwrap();
        let (view, cx) = cx.add_window_view(|window, cx| MarkdownReaderView::new(&path, window, cx));
        assert_eq!(view.read_with(cx, |view, _| document_text(view.blocks())), "one");
        std::fs::write(&path, "two\n").unwrap();
        view.update(cx, |view, cx| view.reload(cx));
        assert_eq!(view.read_with(cx, |view, _| document_text(view.blocks())), "two");
    }

    #[gpui::test]
    async fn a_missing_file_says_so_and_keeps_watching(cx: &mut TestAppContext) {
        setup(cx);
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("gone.md");
        let (view, cx) = cx.add_window_view(|window, cx| MarkdownReaderView::new(&path, window, cx));
        let text = view.read_with(cx, |view, _| document_text(view.blocks()));
        assert!(text.starts_with("Unable to read Markdown"));
        assert!(text.contains("Soprano is still watching this path and will reload it when it reappears."));
    }

    #[test]
    fn linked_files_open_when_viewable_and_scripts_are_only_revealed() {
        let root = tempfile::tempdir().unwrap();
        let document =
            ReaderDocument { path: root.path().join("README.md"), access_root: root.path().to_path_buf() };
        std::fs::write(root.path().join("diagram.pdf"), "%PDF").unwrap();
        std::fs::write(root.path().join("install.sh"), "#!/bin/sh\n").unwrap();
        assert_eq!(
            link_action(&document, "diagram.pdf"),
            Some(ReaderLinkAction::OpenFile(soprano_platform::paths::normalize(
                &root.path().join("diagram.pdf")
            )))
        );
        assert!(matches!(link_action(&document, "install.sh"), Some(ReaderLinkAction::RevealFile(_))));
        assert_eq!(link_action(&document, "#usage"), Some(ReaderLinkAction::ScrollTo("usage".into())));
        assert_eq!(link_action(&document, "javascript:alert(1)"), None);
        assert_eq!(link_action(&document, "../outside.md"), None);
        assert_eq!(
            link_action(&document, "mailto:a@b.c"),
            Some(ReaderLinkAction::External("mailto:a@b.c".into()))
        );
    }

    /// `MarkdownIntegrationTests.markdownRenderingSupportsGFMAndEscapesDocumentProvidedHTML`,
    /// at the level the native reader works on: headings get unique anchors the reader can
    /// scroll to, tables and task boxes are blocks, source HTML stays visible text, the unsafe
    /// link leads nowhere, and code is text.
    #[test]
    fn the_reader_supports_gfm_and_shows_document_html_as_source() {
        let source = "# Hello & Goodbye\n# Hello & Goodbye\n\n- [x] shipped\n\n| Name | State |\n| --- | ---: |\n| Reader | ready |\n\n<script>alert(\"no\")</script>\n\n[unsafe](javascript:alert(1))\n[safe](https://example.com)\n\n```html\n<button onclick=\"bad()\">Run</button>\n```\n";
        let blocks = model::parse(source, false);
        assert_eq!(anchor_block(&blocks, "hello-goodbye"), Some(0));
        assert_eq!(anchor_block(&blocks, "hello-goodbye-1"), Some(1));
        assert!(blocks.iter().any(|block| matches!(block, MarkdownBlock::Table(_))));
        assert!(blocks.iter().any(|block| matches!(
            block,
            MarkdownBlock::List { items, .. } if items[0].checkbox == Some(true)
        )));
        let text = document_text(&blocks);
        assert!(text.contains("<script>alert(\"no\")</script>"));
        assert!(text.contains("<button onclick=\"bad()\">Run</button>"));
        assert!(text.contains("Hello & Goodbye"));
        let document =
            ReaderDocument { path: PathBuf::from("/tmp/r/README.md"), access_root: PathBuf::from("/tmp/r") };
        let links: Vec<Option<String>> = blocks
            .iter()
            .filter_map(|block| match block {
                MarkdownBlock::Paragraph(inlines) => Some(inlines),
                _ => None,
            })
            .flatten()
            .filter_map(|inline| match inline {
                MarkdownInline::Link { destination, .. } => Some(destination.clone()),
                _ => None,
            })
            .collect();
        assert_eq!(links.len(), 2);
        assert_eq!(link_action(&document, links[0].as_deref().unwrap_or_default()), None);
        assert_eq!(
            link_action(&document, links[1].as_deref().unwrap_or_default()),
            Some(ReaderLinkAction::External("https://example.com".into()))
        );
        assert!(blocks.iter().any(|block| matches!(
            block,
            MarkdownBlock::Code { language: Some(language), .. } if language == "html"
        )));
    }

    #[gpui::test]
    async fn a_byte_order_mark_does_not_hide_the_first_heading(cx: &mut TestAppContext) {
        setup(cx);
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("bom.md");
        std::fs::write(&path, "\u{FEFF}# Title\n\nbody\n").unwrap();
        let (view, cx) = cx.add_window_view(|window, cx| MarkdownReaderView::new(&path, window, cx));
        let first = view.read_with(cx, |view, _| view.blocks().first().cloned());
        assert!(matches!(first, Some(MarkdownBlock::Heading { anchor, .. }) if anchor == "title"));
    }

    #[test]
    fn keyboard_scrolling_steps_by_lines_and_pages() {
        assert_eq!(scrolled(ScrollReader::LineDown, 0.0, 500.0, 1000.0), 40.0);
        assert_eq!(scrolled(ScrollReader::LineUp, 10.0, 500.0, 1000.0), 0.0);
        assert_eq!(scrolled(ScrollReader::PageDown, 0.0, 500.0, 1000.0), 460.0);
        assert_eq!(scrolled(ScrollReader::PageDown, 900.0, 500.0, 1000.0), 1000.0);
        assert_eq!(scrolled(ScrollReader::Bottom, 0.0, 500.0, 1000.0), 1000.0);
        assert_eq!(scrolled(ScrollReader::Top, 700.0, 500.0, 1000.0), 0.0);
    }

    #[test]
    fn unreadable_files_are_described_in_cocoas_words() {
        let missing = std::io::Error::from(std::io::ErrorKind::NotFound);
        assert_eq!(
            cocoa_error(Path::new("/x/gone.md"), &missing).to_string(),
            "The file “gone.md” couldn’t be opened because there is no such file."
        );
        let denied = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        assert!(cocoa_error(Path::new("/x/a.md"), &denied).to_string().contains("permission to view it"));
    }

    #[gpui::test]
    async fn an_anchor_link_scrolls_to_the_heading_itself(cx: &mut TestAppContext) {
        setup(cx);
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("long.md");
        let filler: String = (1..=60).map(|n| format!("Paragraph {n}.\n\n")).collect();
        // The heading sits inside a list item, below a long first item.
        let source =
            format!("# Top\n\n{filler}- first\n\n  {filler}\n- second\n\n  ## Nested\n\n  text\n\n{filler}");
        std::fs::write(&path, source).unwrap();
        let (view, cx) = cx.add_window_view(|window, cx| MarkdownReaderView::new(&path, window, cx));
        cx.run_until_parked();
        view.update(cx, |view, cx| view.follow_link("#nested", cx));
        cx.run_until_parked();
        let (heading, viewport, pending) = view.read_with(cx, |view, _| {
            (view.anchors.heading_bounds("nested"), view.scroll.bounds(), view.anchors.is_pending())
        });
        let heading = heading.expect("the heading was drawn");
        assert!(!pending);
        let expected = viewport.top() + px(crate::rich::markdown::ANCHOR_MARGIN);
        assert!((heading.top() - expected).abs() <= px(1.0), "{:?} vs {expected:?}", heading.top());
    }
}
