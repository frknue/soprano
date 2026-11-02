import AppKit

/// Where a link in a Markdown file tab leads, resolved against the document's workspace-relative
/// path the way GitHub resolves repository links.
enum MarkdownReaderLink: Equatable {
    /// A heading of the same document (`#getting-started`).
    case anchor(String)
    /// Another workspace file (workspace-relative path), optionally at a heading.
    case file(path: String, anchor: String?)
    /// http, https and mailto: the default app.
    case external
    /// Outside the workspace, or a scheme the reader never opens (`file:`, `javascript:`, …).
    case blocked

    /// `destination` relative to the folder of `documentPath`; a leading "/" means the workspace
    /// root. ".." may not climb above the root.
    static func resolve(_ url: URL, from documentPath: String) -> MarkdownReaderLink {
        if let scheme = url.scheme?.lowercased() {
            return ["http", "https", "mailto"].contains(scheme) ? .external : .blocked
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath.removingPercentEncoding ?? url.relativePath
        let fragment = components?.fragment.flatMap { $0.isEmpty ? nil : $0 }
        if path.isEmpty {
            return fragment.map { .anchor($0) } ?? .blocked
        }
        var parts: [String] = path.hasPrefix("/")
            ? []
            : documentPath.split(separator: "/").dropLast().map(String.init)
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return .blocked }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        guard !parts.isEmpty else { return .blocked }
        return .file(path: parts.joined(separator: "/"), anchor: fragment)
    }
}

/// A Markdown file tab rendered for reading, as Soprano's Markdown reader sets it: New York
/// 16/26 in a centered column of at most 920 pt, 32/42 pt padding (24/22 below 600 pt), h2
/// headings over a rule, images of the workspace, links to other files and headings. Built on
/// the timeline's renderer (`MarkdownStyle.document`), so code blocks, tables and quotes match
/// the chat.
@MainActor
final class MarkdownReaderView: PaletteView {
    static let columnWidth: CGFloat = 920

    /// A link to another workspace file: its workspace-relative path and `#anchor`.
    var onOpenFile: ((String, String?) -> Void)?
    /// Loads a workspace-relative image; nil when it is missing or no image.
    var loadImage: (@MainActor (String) async -> NSImage?)?

    private let scrollView = NSScrollView()
    private let document = ReaderDocumentView()
    private let markdown = MarkdownView(frame: .zero)
    private var source: String?
    private(set) var path = ""
    private var imageGeneration = 0
    private var laidOutSize: NSSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        document.addSubview(markdown)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        markdown.linkHandler = { [weak self] url in self?.handleLink(url) ?? true }
        document.onScroll = { [weak self] scroll in self?.keyboardScroll(scroll) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Markdown preview")
        applyPalette(palette)
    }

    /// Renders `text` (the file at workspace-relative `path`); `keepScroll` keeps the reading
    /// position and the images until they reload (a reload of the same file).
    func show(_ text: String, path: String, keepScroll: Bool) {
        preservingFocus {
            let origin = scrollView.contentView.bounds.origin
            if !keepScroll { markdown.images = [:] }
            self.path = path
            source = text
            markdown.apply(MarkdownRenderer.render(text, style: .document))
            layoutDocument(force: true)
            scroll(toY: keepScroll ? origin.y : 0)
        }
        loadImages()
    }

    /// How far the document is scrolled down.
    var scrollOffset: CGFloat { scrollView.contentView.bounds.origin.y }

    func clear() {
        source = nil
        path = ""
        imageGeneration += 1
        markdown.images = [:]
        markdown.apply(MarkdownRenderer.render("", style: .document))
        layoutDocument(force: true)
    }

    /// Scrolls the heading with that anchor (as written, lowercased or slugged) to the top.
    @discardableResult
    func scroll(toAnchor fragment: String) -> Bool {
        let decoded = fragment.removingPercentEncoding ?? fragment
        for candidate in [decoded, decoded.lowercased(), MarkdownRenderer.anchorSlug(decoded)] {
            if let top = markdown.anchorTop(candidate) {
                scroll(toY: markdown.frame.minY + top - 20)
                return true
            }
        }
        return false
    }

    /// The reader's document takes the keyboard: arrows, page keys, Home and End scroll it.
    func focus() {
        window?.makeFirstResponder(document)
    }

    /// Re-rendering replaces the text views; one of them holding the keyboard hands it to the
    /// document, so the right panel keeps focus (and its shortcuts).
    private func preservingFocus(_ body: () -> Void) {
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
        body()
        if hadFocus, (window?.firstResponder as? NSView)?.isDescendant(of: self) != true { focus() }
    }

    /// Relayout that keeps the block at the top of the view where it is (images arriving above
    /// it, a palette change).
    private func keepingReadingPosition(_ body: () -> Void) {
        let position = markdown.readingPosition(at: scrollOffset - markdown.frame.minY)
        body()
        layoutDocument(force: true)
        if let position, let y = markdown.y(of: position) {
            scroll(toY: markdown.frame.minY + y)
        }
    }

    private func keyboardScroll(_ scroll: ReaderDocumentView.Scroll) {
        let page = max(40, scrollView.contentSize.height - 40)
        switch scroll {
        case .line(let lines): self.scroll(toY: scrollOffset + CGFloat(lines) * 40)
        case .page(let pages): self.scroll(toY: scrollOffset + CGFloat(pages) * page)
        case .top: self.scroll(toY: 0)
        case .bottom: self.scroll(toY: .greatestFiniteMagnitude)
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutDocument(force: false)
    }

    /// Soprano's reader padding: 32/42/48, narrower below 600 pt.
    static func padding(width: CGFloat) -> NSEdgeInsets {
        width < 600
            ? NSEdgeInsets(top: 24, left: 22, bottom: 48, right: 22)
            : NSEdgeInsets(top: 32, left: 42, bottom: 48, right: 42)
    }

    private func layoutDocument(force: Bool) {
        let visible = scrollView.contentSize
        guard force || visible != laidOutSize else { return }
        laidOutSize = visible
        let padding = Self.padding(width: visible.width)
        let column = max(1, min(Self.columnWidth, visible.width - padding.left - padding.right))
        let height = markdown.layoutMarkdown(width: column)
        markdown.frame.origin = NSPoint(x: max(padding.left, ((visible.width - column) / 2).rounded()), y: padding.top)
        document.frame = NSRect(x: 0, y: 0, width: visible.width, height: max(visible.height, padding.top + height + padding.bottom))
    }

    private func scroll(toY y: CGFloat) {
        let limit = max(0, document.frame.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), limit)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Images

    /// Loads the workspace images of the image blocks; remote images keep their alt text.
    private func loadImages() {
        imageGeneration += 1
        let generation = imageGeneration
        guard let rendering = markdown.rendering, let loadImage else { return }
        var targets: [String: String] = [:]
        for piece in rendering.pieces {
            guard case let .image(source, _, _) = piece.segment, targets[source] == nil, let url = URL(string: source),
                  case let .file(imagePath, _) = MarkdownReaderLink.resolve(url, from: path) else { continue }
            targets[source] = imagePath
        }
        guard !targets.isEmpty else { return }
        Task { [weak self] in
            var loaded: [String: NSImage] = [:]
            for (source, path) in targets {
                if let image = await loadImage(path) { loaded[source] = image }
            }
            guard let self, self.imageGeneration == generation else { return }
            keepingReadingPosition { markdown.images = loaded }
        }
    }

    // MARK: - Links

    private func handleLink(_ url: URL) -> Bool {
        switch MarkdownReaderLink.resolve(url, from: path) {
        case let .anchor(anchor):
            scroll(toAnchor: anchor)
        case let .file(target, anchor) where target == path:
            if let anchor { scroll(toAnchor: anchor) }
        case let .file(target, anchor):
            // After the click: opening the tab re-renders and removes the clicked text view.
            DispatchQueue.main.async { [weak self] in self?.onOpenFile?(target, anchor) }
        case .external:
            return false
        case .blocked:
            NSSound.beep()
        }
        return true
    }

    // MARK: - Palette

    override func applyPalette(_ palette: Palette) {
        markdown.setQuoteColor(palette.foreground.timelineAlpha(0.35))
        // Colors are baked into the rendering: render again in the new palette.
        guard let source else { return }
        preservingFocus {
            keepingReadingPosition { markdown.apply(MarkdownRenderer.render(source, style: .document)) }
        }
    }
}

/// The reader's scrolled document: first responder of the reader, scrolling by keyboard.
final class ReaderDocumentView: NSView {
    enum Scroll {
        case line(Int)
        case page(Int)
        case top
        case bottom
    }

    var onScroll: ((Scroll) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func moveUp(_ sender: Any?) { onScroll?(.line(-1)) }
    override func moveDown(_ sender: Any?) { onScroll?(.line(1)) }
    override func scrollLineUp(_ sender: Any?) { onScroll?(.line(-1)) }
    override func scrollLineDown(_ sender: Any?) { onScroll?(.line(1)) }
    override func pageUp(_ sender: Any?) { onScroll?(.page(-1)) }
    override func pageDown(_ sender: Any?) { onScroll?(.page(1)) }
    override func scrollPageUp(_ sender: Any?) { onScroll?(.page(-1)) }
    override func scrollPageDown(_ sender: Any?) { onScroll?(.page(1)) }
    override func insertText(_ insertString: Any) {
        // Space pages down, as in a browser.
        if (insertString as? String) == " " { onScroll?(.page(1)) }
    }
    override func moveToBeginningOfDocument(_ sender: Any?) { onScroll?(.top) }
    override func moveToEndOfDocument(_ sender: Any?) { onScroll?(.bottom) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { onScroll?(.top) }
    override func scrollToEndOfDocument(_ sender: Any?) { onScroll?(.bottom) }

    /// Unhandled keys (Escape, shortcuts) go up the chain instead of beeping here.
    override func doCommand(by selector: Selector) {
        if responds(to: selector) { perform(selector, with: nil) } else { nextResponder?.doCommand(by: selector) }
    }
}
