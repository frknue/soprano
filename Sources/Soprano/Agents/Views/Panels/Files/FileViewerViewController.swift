import AppKit
import SopranoAgentsCore

/// A file tab of the right panel: the active `.file(path)` of the selected thread, read-only.
/// A breadcrumb header with Refresh, Copy contents, Open in Editor and Reveal in Finder over
/// the text (SF Mono, line numbers, syntax colors, no wrapping), the image, or a note for
/// binary and oversized files. Contents are cached per thread and path while the tab is open.
@MainActor
final class FileViewerViewController: NSViewController {
    let engine: AgentEngine
    let state: WorkspaceState

    static let headerHeight: CGFloat = 40
    /// Height of one code line.
    static let lineHeight: CGFloat = 20
    /// Text container and text view limit: no wrapping, no practical size cap (`FLT_MAX`, as
    /// AppKit's non-wrapping text setup uses; `CGFloat.greatestFiniteMagnitude` breaks layers).
    private static let unbounded = CGFloat(Float.greatestFiniteMagnitude)

    private struct FileKey: Hashable {
        var threadID: String
        var path: String
    }

    private enum Loaded: Equatable {
        case content(WorkspaceFileContent)
        case failed(String)
    }

    private var cache: [FileKey: Loaded] = [:]
    /// Bumped when a load changes the cached value, so the body re-renders only then.
    private var versions: [FileKey: Int] = [:]
    /// Generation of the newest load per file; older results are dropped.
    private var pending: [FileKey: Int] = [:]
    private var generation = 0
    /// Files to reload next time they show (their thread finished a turn).
    private var stale: Set<FileKey> = []
    /// Threads seen running, to notice when their turn ends.
    private var runningThreads: Set<String> = []
    private var shown: (key: FileKey, version: Int)?
    /// Syntax tokens of the shown text (re-applied on palette changes).
    private var tokens: [SyntaxToken] = []
    /// Syntax tokens per cached text file, so switching tabs does not re-highlight.
    private var highlights: [FileKey: [SyntaxToken]] = [:]
    private var highlightGeneration = 0
    private var showsText = false

    // Views
    private let header = NSView()
    private let headerRule = HairlineView()
    private let breadcrumbs = NSTextField.label(size: Typography.smallSize)
    private let refreshButton = GhostIconButton(symbol: "arrow.clockwise", size: 28, symbolSize: 12, toolTip: "Refresh file")
    private let copyButton = GhostIconButton(symbol: Icon.copy, size: 28, symbolSize: 12, toolTip: "Copy contents")
    private let editorButton = GhostIconButton(symbol: "arrow.up.forward.app", size: 28, symbolSize: 12, toolTip: "Open in Editor")
    private let revealButton = GhostIconButton(symbol: "folder", size: 28, symbolSize: 12, toolTip: "Reveal in Finder")
    private let textScrollView = NSScrollView()
    private let textView: NSTextView
    private let gutter: FileLineNumberGutter
    private let imageView = NSImageView()
    private let messageStack = NSStackView()
    private let messageLabel = NSTextField.label(size: Typography.smallSize)
    private let messageEditorButton = TextButton("Open in Editor", symbol: "arrow.up.forward.app", variant: .outline, size: .sm)

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        // TextKit 1, so the gutter can read line fragments.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: Self.unbounded, height: Self.unbounded))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        gutter = FileLineNumberGutter(textView: textView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = FilesSurfaceRootView(frame: NSRect(x: 0, y: 0, width: 540, height: 600))
        view = root
        buildHeader()
        buildText()

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        imageView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        imageView.setAccessibilityLabel("Image preview")

        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 4
        messageLabel.lineBreakMode = .byWordWrapping
        messageEditorButton.onClick = { [weak self] in self?.openInEditor() }
        messageStack.orientation = .vertical
        messageStack.alignment = .centerX
        messageStack.spacing = 12
        messageStack.addArrangedSubview(messageLabel)
        messageStack.addArrangedSubview(messageEditorButton)

        for subview in [header, headerRule, gutter, textScrollView, imageView, messageStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerRule.heightAnchor.constraint(equalToConstant: 1),

            gutter.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gutter.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            textScrollView.topAnchor.constraint(equalTo: headerRule.bottomAnchor),
            textScrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            textScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            imageView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            messageStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: textScrollView.centerYAnchor, constant: -20),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
        ])

        runningThreads = Set(engine.threads.filter(\.isRunning).map(\.id))
        PaletteCenter.shared.addObserver(self) { [weak self] palette in self?.applyPalette(palette) }
        state.addObserver(self) { [weak self] change in
            switch change {
            case .panels, .selection: self?.stateChanged()
            case .filter, .composerRestore: break
            }
        }
        engine.addObserver(self) { [weak self] event in
            guard let self else { return }
            switch event {
            case let .threadChanged(threadID): threadChanged(threadID)
            case .threadListChanged: pruneDeletedThreads()
            default: break
            }
        }
        applyPalette(PaletteCenter.shared.palette)
        show(message: "", editorButton: false)
        stateChanged()
    }

    private func buildHeader() {
        breadcrumbs.lineBreakMode = .byTruncatingHead
        breadcrumbs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breadcrumbs.setContentHuggingPriority(.init(1), for: .horizontal)
        refreshButton.onClick = { [weak self] in self?.refresh() }
        copyButton.onClick = { [weak self] in self?.copyContents() }
        editorButton.onClick = { [weak self] in self?.openInEditor() }
        revealButton.onClick = { [weak self] in self?.revealInFinder() }
        let stack = NSStackView(views: [breadcrumbs, refreshButton, copyButton, editorButton, revealButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setCustomSpacing(8, after: breadcrumbs)
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
    }

    private func buildText() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: Self.unbounded, height: Self.unbounded)
        // Sized by `fitTextViewToClip` (at least the visible area), never by autoresizing: growing
        // the clip view would otherwise shift a short file's frame down.
        textView.autoresizingMask = []
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.setAccessibilityLabel("File contents")

        textScrollView.documentView = textView
        textScrollView.drawsBackground = false
        textScrollView.hasVerticalScroller = true
        textScrollView.hasHorizontalScroller = true
        textScrollView.autohidesScrollers = true
        textScrollView.scrollerStyle = .overlay
        // Below the text: above it, the bar would cover the first line and shift the text off
        // the line-number gutter.
        textScrollView.findBarPosition = .belowContent
        textScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(textScrolled), name: NSView.boundsDidChangeNotification, object: textScrollView.contentView
        )
    }

    @objc private func textScrolled() {
        gutter.needsDisplay = true
    }

    /// The text view fills at least the visible area from the top: a short file stays at the top of
    /// the clip view and the background covers it.
    private func fitTextViewToClip() {
        let visible = textScrollView.contentSize
        if textView.frame.origin != .zero { textView.setFrameOrigin(.zero) }
        guard textView.minSize != visible else { return }
        textView.minSize = visible
        textView.sizeToFit()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitTextViewToClip()
    }

    // MARK: - Focus

    /// Makes the text the first responder when a text file shows.
    func focusText() {
        guard isViewLoaded else { return }
        view.window?.makeFirstResponder(showsText ? textView : view)
    }

    /// ⌘F in a text file tab: the text view's find bar. Returns false when no text shows.
    @discardableResult
    func showFind() -> Bool {
        guard isViewLoaded, showsText else { return false }
        view.window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(item)
        return true
    }

    // MARK: - State

    private var isShowing: Bool {
        guard state.isRightPanelVisible, case .file = state.rightPanelSurface else { return false }
        return true
    }

    /// The selected thread's active file tab.
    private var currentKey: FileKey? {
        guard let threadID = state.selectedThreadID, case let .file(path) = state.rightPanelSurface else { return nil }
        return FileKey(threadID: threadID, path: path)
    }

    private func stateChanged() {
        guard isViewLoaded else { return }
        pruneClosedTabs()
        render()
    }

    /// Forgets the contents of the selected thread's files whose tab closed.
    private func pruneClosedTabs() {
        guard let threadID = state.selectedThreadID else { return }
        var open: Set<String> = []
        for surface in state.rightPanelSurfaces {
            if case let .file(path) = surface { open.insert(path) }
        }
        for key in cache.keys where key.threadID == threadID && !open.contains(key.path) {
            forget(key)
        }
    }

    private func forget(_ key: FileKey) {
        cache[key] = nil
        versions[key] = nil
        highlights[key] = nil
        pending[key] = nil
        stale.remove(key)
        if shown?.key == key { shown = nil }
    }

    private func threadChanged(_ threadID: String) {
        if engine.thread(threadID)?.isRunning == true {
            runningThreads.insert(threadID)
            return
        }
        guard runningThreads.remove(threadID) != nil else { return }
        let keys = cache.keys.filter { $0.threadID == threadID }
        guard !keys.isEmpty else { return }
        stale.formUnion(keys)
        render()
    }

    private func pruneDeletedThreads() {
        let ids = Set(engine.threads.map(\.id))
        for key in cache.keys where !ids.contains(key.threadID) {
            forget(key)
        }
        runningThreads.formIntersection(ids)
    }

    private func refresh() {
        guard let key = currentKey else { return }
        load(key)
    }

    // MARK: - Loading

    private func load(_ key: FileKey) {
        generation += 1
        let generation = generation
        pending[key] = generation
        stale.remove(key)
        let engine = engine
        Task { [weak self] in
            let loaded: Loaded
            do {
                loaded = .content(try await engine.readWorkspaceFile(key.threadID, path: key.path))
            } catch {
                loaded = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.finishLoad(key, generation: generation, loaded: loaded)
        }
    }

    private func finishLoad(_ key: FileKey, generation: Int, loaded: Loaded) {
        guard pending[key] == generation else { return }
        pending[key] = nil
        if cache[key] != loaded {
            cache[key] = loaded
            highlights[key] = nil
            versions[key, default: 0] += 1
        }
        render()
    }

    // MARK: - Rendering

    private func render() {
        guard isViewLoaded, isShowing else { return }
        guard let key = currentKey else {
            updateHeader(nil)
            shown = nil
            show(message: "Start the thread to browse its files.", editorButton: false)
            return
        }
        updateHeader(key)
        if cache[key] == nil || stale.contains(key), pending[key] == nil {
            load(key)
        }
        guard let loaded = cache[key] else {
            if shown?.key != key {
                shown = nil
                show(message: "Loading…", editorButton: false)
            }
            return
        }
        let version = versions[key] ?? 0
        guard shown?.key != key || shown?.version != version else { return }
        let sameFile = shown?.key == key
        shown = (key, version)
        switch loaded {
        case let .failed(text):
            show(message: text, editorButton: false)
        case let .content(.text(text)):
            showText(text, key: key, keepScroll: sameFile)
        case let .content(.image(data)):
            if let image = NSImage(data: data) {
                showImage(image)
            } else {
                show(message: "This image can't be previewed.", editorButton: true)
            }
        case let .content(.binary(byteCount)):
            show(message: "Binary file · \(Self.size(byteCount))", editorButton: true)
        case let .content(.tooLarge(byteCount)):
            show(message: "File is too large to preview · \(Self.size(byteCount))", editorButton: true)
        }
        copyButton.isEnabled = showsText
    }

    private func updateHeader(_ key: FileKey?) {
        let palette = PaletteCenter.shared.palette
        breadcrumbs.attributedStringValue = Self.breadcrumbs(key?.path ?? "", palette: palette)
        breadcrumbs.toolTip = key?.path
        let hasURL = key.flatMap { engine.workspaceFileURL($0.threadID, path: $0.path) } != nil
        refreshButton.isEnabled = key != nil
        editorButton.isEnabled = hasURL
        revealButton.isEnabled = hasURL
        copyButton.isEnabled = showsText && shown?.key == key
    }

    /// "Sources / Auth / LoginController.swift": folders and separators muted, the name in the
    /// foreground.
    static func breadcrumbs(_ path: String, palette: Palette) -> NSAttributedString {
        let font = Typography.ui(Typography.smallSize)
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.mutedForeground]
        let parts = path.split(separator: "/").map(String.init)
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 {
                result.append(NSAttributedString(string: part, attributes: [
                    .font: Typography.ui(Typography.smallSize, weight: .medium), .foregroundColor: palette.foreground,
                ]))
            } else {
                result.append(NSAttributedString(string: part, attributes: muted))
                result.append(NSAttributedString(string: " / ", attributes: muted))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    static func size(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private func show(message: String, editorButton: Bool) {
        clearText()
        imageView.image = nil
        imageView.isHidden = true
        textScrollView.isHidden = true
        gutter.isHidden = true
        messageLabel.stringValue = message
        messageEditorButton.isHidden = !editorButton
        messageStack.isHidden = message.isEmpty
    }

    private func showImage(_ image: NSImage) {
        clearText()
        imageView.image = image
        imageView.isHidden = false
        textScrollView.isHidden = true
        gutter.isHidden = true
        messageStack.isHidden = true
    }

    private func clearText() {
        guard showsText else { return }
        showsText = false
        tokens = []
        highlightGeneration += 1
        textView.textStorage?.setAttributedString(NSAttributedString())
        gutter.lineStarts = [0]
    }

    private func showText(_ text: String, key: FileKey, keepScroll: Bool) {
        imageView.image = nil
        imageView.isHidden = true
        messageStack.isHidden = true
        textScrollView.isHidden = false
        gutter.isHidden = false
        showsText = true
        tokens = []
        highlightGeneration += 1
        let highlightGeneration = highlightGeneration
        let origin = textScrollView.contentView.bounds.origin
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: textAttributes(PaletteCenter.shared.palette)))
        gutter.lineStarts = Self.lineStarts(of: text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        view.layoutSubtreeIfNeeded()
        fitTextViewToClip()
        textView.sizeToFit()
        textScrollView.contentView.scroll(to: keepScroll ? origin : .zero)
        textScrollView.reflectScrolledClipView(textScrollView.contentView)

        if let cached = highlights[key] {
            tokens = cached
            applyTextColors(PaletteCenter.shared.palette)
            return
        }
        let name = key.path.split(separator: "/").last.map(String.init) ?? key.path
        guard let language = CodeLanguage.forFile(named: name), text.utf16.count <= DiffHighlights.maximumLength else { return }
        Task { [weak self] in
            let tokens = await Task.detached(priority: .userInitiated) {
                CodeSyntaxHighlighter.tokens(in: text, language: language)
            }.value
            guard let self, self.highlightGeneration == highlightGeneration else { return }
            self.tokens = tokens
            highlights[key] = tokens
            applyTextColors(PaletteCenter.shared.palette)
        }
    }

    /// UTF-16 offsets where each line starts; a trailing newline does not start a line.
    static func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        if starts.count > 1, starts.last == offset { starts.removeLast() }
        return starts
    }

    private func textAttributes(_ palette: Palette) -> [NSAttributedString.Key: Any] {
        let font = Typography.mono()
        let natural = ceil(font.ascender - font.descender + font.leading)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        paragraph.lineBreakMode = .byClipping
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * NSAttributedString(string: "0", attributes: [.font: font]).size().width
        return [
            .font: font,
            .foregroundColor: palette.foreground,
            .paragraphStyle: paragraph,
            .baselineOffset: max(0, (Self.lineHeight - natural) / 2),
        ]
    }

    /// Re-colors the shown text: base attributes, then the syntax tokens.
    private func applyTextColors(_ palette: Palette) {
        guard showsText, let storage = textView.textStorage else { return }
        let length = storage.length
        let style = DiffStyle(palette: palette)
        storage.beginEditing()
        storage.setAttributes(textAttributes(palette), range: NSRange(location: 0, length: length))
        for token in tokens where NSMaxRange(token.range) <= length {
            storage.addAttribute(.foregroundColor, value: style.syntaxColor(token.kind), range: token.range)
            if token.kind.isEmphasized {
                storage.addAttribute(.font, value: style.semiboldFont, range: token.range)
            } else if token.kind.isItalic {
                storage.addAttribute(.font, value: style.italicFont, range: token.range)
            }
        }
        storage.endEditing()
    }

    // MARK: - Actions

    private var currentURL: URL? {
        guard let key = currentKey else { return nil }
        return engine.workspaceFileURL(key.threadID, path: key.path)
    }

    private func copyContents() {
        guard let key = currentKey, case let .content(.text(text)) = cache[key] else { return }
        WorkspaceFileActions.copy(text)
    }

    private func openInEditor() {
        guard let url = currentURL else { return }
        WorkspaceFileActions.openInEditor(url)
    }

    private func revealInFinder() {
        guard let url = currentURL else { return }
        WorkspaceFileActions.reveal(url)
    }

    // MARK: - Palette

    private func applyPalette(_ palette: Palette) {
        textView.backgroundColor = palette.background
        textView.insertionPointColor = palette.foreground
        textView.selectedTextAttributes = [.backgroundColor: palette.primary.withAlphaComponent(palette.isDark ? 0.45 : 0.22)]
        messageLabel.textColor = palette.mutedForeground
        applyTextColors(palette)
        gutter.needsDisplay = true
        if isViewLoaded, isShowing { updateHeader(currentKey) }
    }
}

/// The file viewer's line numbers, left of the text's scroll view (fixed while the text scrolls
/// sideways): muted, right-aligned SF Mono 12 beside each visible line.
final class FileLineNumberGutter: PaletteView {
    static let padding: CGFloat = 10

    /// UTF-16 offsets of the line starts (`FileViewerViewController.lineStarts(of:)`).
    var lineStarts: [Int] = [0] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private weak var textView: NSTextView?
    private let font = Typography.mono(Typography.smallSize)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(false)
        applyPalette(palette)
    }

    var thickness: CGFloat {
        let digits = max(2, String(lineStarts.count).count)
        let digit = NSAttributedString(string: "0", attributes: [.font: font]).size().width
        return ceil(CGFloat(digits) * digit) + Self.padding * 2
    }

    override var intrinsicContentSize: NSSize { NSSize(width: thickness, height: NSView.noIntrinsicMetric) }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let length = textView.textStorage?.length, length > 0 else { return }
        let width = bounds.width
        let origin = textView.textContainerOrigin
        var visible = textView.visibleRect
        visible.origin.x -= origin.x
        visible.origin.y -= origin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let end = NSMaxRange(characters)
        // The last line starting at or before the first visible character.
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= characters.location { low = middle + 1 } else { high = middle }
        }
        var line = max(0, low - 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: PaletteCenter.shared.palette.mutedForeground]
        while line < lineStarts.count, lineStarts[line] <= end, lineStarts[line] < length {
            let glyph = layoutManager.glyphIndexForCharacter(at: lineStarts[line])
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: width - Self.padding - size.width, y: top + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            line += 1
        }
    }
}
