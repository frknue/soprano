import AppKit

/// A file open in Soprano, Orca-style: an editable, syntax-colored text view
/// with line numbers, find (⌘F), undo, and ⌘S; images are shown, other files
/// get a note and a way out to their default app. Drawn as Soprano Agents'
/// file viewer: a 40 pt header with the repository-relative breadcrumbs and
/// ghost buttons, SF Mono 13 on 20 pt lines beside muted line numbers, the
/// diff palette's syntax colors.
///
/// Every tab showing the same file shares one `EditorDocument`, so edits,
/// undo, and the saved state are the same in each.
final class EditorPaneView: NSView {
    /// Height of one code line (Agents' `FileViewerViewController.lineHeight`).
    static let lineHeight: CGFloat = 20

    let target: TerminalTarget
    let document: EditorDocument
    private let store: EditorDocumentStore
    private let themeManager: ThemeManager

    var onFocusRequested: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?
    /// The document gained unsaved changes; its tab stops being a preview.
    var onEdited: (() -> Void)?
    var onMarkdownPreviewRequested: ((URL) -> Void)?

    private var toolbar: SurfaceToolbar!
    private let breadcrumbs = SurfaceBreadcrumbs.label()
    private let statusLabel = NSTextField.label(size: Typography.smallSize)
    private var reloadButton: ShellTextButton!
    private var saveButton: ShellGhostButton!
    private var previewButton: ShellGhostButton!
    private var revealButton: ShellGhostButton!
    private var openExternallyButton: ShellGhostButton!
    /// The breadcrumb path, recomputed when the document moves.
    private var displayPath: (url: URL, path: String)?

    private let scrollView = NSScrollView()
    private let layoutManager = EditorLayoutManager()
    let textView: EditorTextView
    private var ruler: EditorLineNumberRuler!
    private let imageView = NSImageView()
    private var message: SurfaceMessageView!
    private var pendingRestore: (selection: [NSValue], origin: NSPoint)?
    private var lastLineCountDigits = 0

    init(
        target: TerminalTarget,
        document: EditorDocument,
        themeManager: ThemeManager,
        store: EditorDocumentStore = .shared
    ) {
        self.target = target
        self.document = document
        self.themeManager = themeManager
        self.store = store

        let container = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(container)
        document.textStorage.addLayoutManager(layoutManager)
        textView = EditorTextView(frame: .zero, textContainer: container)

        super.init(frame: .zero)
        wantsLayer = true
        store.attach(self, as: target, to: document)
        setupViews()
        document.addObserver(self) { [weak self] change in
            self?.documentDidChange(change)
        }
        applyTheme()
        showContent()
        updateChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated {
            // The shared storage keeps every layout manager it was given.
            document.textStorage.removeLayoutManager(layoutManager)
            store.detach(self)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func focusPreferredControl() {
        onFocusRequested?()
        window?.makeFirstResponder(document.content == .text ? textView : self)
    }

    /// Saves through the store, which asks before overwriting another
    /// program's version.
    func save() {
        guard document.content == .text else { return }
        store.save(document)
    }

    // MARK: - Setup

    private func setupViews() {
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        reloadButton = ShellTextButton(title: "Reload", variant: .outline)
        reloadButton.target = self
        reloadButton.action = #selector(reloadClicked)
        reloadButton.toolTip = "Replace your unsaved changes with the version on disk"

        previewButton = SurfaceToolbar.button(Icon.eye, "Open Markdown Preview", target: self, action: #selector(previewClicked))
        saveButton = SurfaceToolbar.button("square.and.arrow.down", "Save (⌘S)", target: self, action: #selector(saveClicked))
        openExternallyButton = SurfaceToolbar.button(
            "arrow.up.forward.app",
            "Open with Default App",
            target: self,
            action: #selector(openExternallyClicked)
        )
        revealButton = SurfaceToolbar.button("folder", "Reveal in Finder", target: self, action: #selector(revealClicked))
        toolbar = SurfaceToolbar(
            leading: [breadcrumbs, statusLabel, reloadButton],
            trailing: [previewButton, saveButton, openExternallyButton, revealButton]
        )
        toolbar.setSpacing(8, after: breadcrumbs)
        addSubview(toolbar)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.allowsDocumentBackgroundColorChange = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.delegate = self
        textView.onFocus = { [weak self] in self?.onFocusRequested?() }
        textView.setAccessibilityLabel(document.name)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        // Below the text: above it, the bar would cover the first line.
        scrollView.findBarPosition = .belowContent
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        ruler = EditorLineNumberRuler(textView: textView, document: document)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleTextChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        addSubview(scrollView)

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        imageView.setAccessibilityLabel("Image preview")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        message = SurfaceMessageView(
            buttonTitle: "Open with Default App",
            target: self,
            action: #selector(openExternallyClicked)
        )
        addSubview(message)
        message.pin(centeredIn: scrollView.centerYAnchor, of: self)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Theme

    func applyTheme() {
        let palette = PaletteCenter.shared.palette
        layer?.backgroundColor = palette.background.cgColor
        document.applyBaseAttributes(Self.textAttributes(palette))
        textView.typingAttributes = Self.textAttributes(palette)
        textView.backgroundColor = palette.background
        textView.insertionPointColor = palette.foreground
        textView.selectedTextAttributes = [.backgroundColor: SurfaceText.selection(palette)]
        scrollView.backgroundColor = palette.background
        ruler.needsDisplay = true
        applyHighlights()
        updateChrome()
    }

    /// SF Mono 13 on a fixed 20 pt line, centered in it, tabs four columns.
    static func textAttributes(_ palette: Palette) -> [NSAttributedString.Key: Any] {
        let font = Typography.mono()
        let natural = ceil(font.ascender - font.descender + font.leading)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        return [
            .font: font,
            .foregroundColor: palette.foreground,
            .paragraphStyle: paragraph,
            .baselineOffset: max(0, (lineHeight - natural) / 2),
        ]
    }

    /// Syntax colors are drawn by this view's layout manager rather than
    /// stored in the shared text, so they never touch undo or the dirty state.
    /// Temporary attributes cannot change the font, so keywords carry a
    /// marker the layout manager draws Semibold, and comments a slant.
    private func applyHighlights() {
        let length = document.textStorage.length
        let all = NSRange(location: 0, length: length)
        for key in [NSAttributedString.Key.foregroundColor, .editorSyntaxEmphasis, .obliqueness] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: all)
        }
        let style = DiffStyle(palette: PaletteCenter.shared.palette)
        for token in document.tokens where NSMaxRange(token.range) <= length {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.syntaxColor(token.kind)]
            if token.kind.isEmphasized {
                attributes[.editorSyntaxEmphasis] = true
            } else if token.kind.isItalic {
                attributes[.obliqueness] = Self.commentObliqueness
            }
            layoutManager.addTemporaryAttributes(attributes, forCharacterRange: token.range)
        }
    }

    private static let commentObliqueness: CGFloat = 0.18

    // MARK: - Document Changes

    private func documentDidChange(_ change: EditorDocument.Change) {
        switch change {
        case .willReplaceContent:
            pendingRestore = (textView.selectedRanges, scrollView.contentView.bounds.origin)
        case .content:
            showContent()
            restoreSelectionAfterReload()
        case .state:
            updateChrome()
            if document.isDirty {
                onEdited?()
            }
        case .highlights:
            applyHighlights()
        case .location:
            textView.setAccessibilityLabel(document.name)
            updateChrome()
        case .edited:
            ruler.needsDisplay = true
            let digits = String(document.lineCount).count
            if digits != lastLineCountDigits {
                lastLineCountDigits = digits
                DispatchQueue.main.async { [weak self] in
                    self?.ruler.updateThickness()
                }
            }
        }
    }

    private func restoreSelectionAfterReload() {
        guard let restore = pendingRestore else { return }
        pendingRestore = nil
        let length = document.textStorage.length
        let ranges = restore.selection.map { value -> NSValue in
            let range = value.rangeValue
            let location = min(range.location, length)
            return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
        }
        textView.selectedRanges = ranges.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : ranges
        scrollView.contentView.scroll(to: restore.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func showContent() {
        let content = document.content
        scrollView.isHidden = content != .text
        imageView.isHidden = content != .image
        imageView.image = document.image
        if case .unavailable(let text) = content {
            message.text = text
            message.isHidden = false
        } else {
            message.isHidden = true
        }
        textView.isEditable = content == .text && !document.isReadOnly
        lastLineCountDigits = String(document.lineCount).count
        ruler.updateThickness()
        applyHighlights()
    }

    private func updateChrome() {
        let palette = PaletteCenter.shared.palette
        if displayPath?.url != document.url {
            displayPath = (document.url, SurfaceBreadcrumbs.displayPath(of: document.url))
        }
        breadcrumbs.attributedStringValue = SurfaceBreadcrumbs.make(displayPath?.path ?? document.name, palette: palette)
        breadcrumbs.toolTip = document.url.path
        textView.isEditable = document.content == .text && !document.isReadOnly

        let status: (text: String, color: NSColor)? = switch (document.diskState, document.content) {
        case (.changed, _):
            ("Changed on disk", palette.errorForeground)
        case (.deleted, _):
            ("Deleted on disk", palette.errorForeground)
        case (_, .image):
            document.image.map { ("\(Int($0.size.width)) × \(Int($0.size.height))", palette.mutedForeground) }
        case (_, .unavailable):
            nil
        default:
            if document.isReadOnly {
                ("Read only", palette.mutedForeground)
            } else if document.isDirty {
                ("Modified", palette.warningForeground)
            } else {
                nil
            }
        }
        statusLabel.isHidden = status == nil
        statusLabel.stringValue = status?.text ?? ""
        statusLabel.textColor = status?.color ?? palette.mutedForeground
        reloadButton.isHidden = document.diskState != .changed
        saveButton.isEnabled = document.content == .text && !document.isReadOnly
        previewButton.isHidden = !["md", "markdown"].contains(document.url.pathExtension.lowercased())

        publishTitle()
    }

    /// Reports the tab title: the file name, with ● while it has unsaved
    /// changes.
    func publishTitle() {
        onTitleChanged?(document.isDirty ? "\(document.name) ●" : document.name)
    }

    // MARK: - Actions

    @objc private func saveClicked() {
        save()
    }

    @objc private func reloadClicked() {
        document.reloadFromDisk()
    }

    @objc private func previewClicked() {
        onMarkdownPreviewRequested?(document.url)
    }

    @objc private func revealClicked() {
        NSWorkspace.shared.activateFileViewerSelecting([document.url])
    }

    @objc private func openExternallyClicked() {
        NSWorkspace.shared.open(document.url)
    }

    @objc private func visibleTextChanged() {
        ruler.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }

    /// ⌘S saves and ⌘F / ⌘G / ⇧⌘G find, but only while the keyboard is in
    /// this pane (its text or its find bar). They are not menu shortcuts: a
    /// disabled menu item still consumes its shortcut, which would take ⌘S
    /// and ⌘G away from terminals and browsers.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder?.focusedView?.isDescendant(of: self) == true,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let findAction: NSTextFinder.Action
        switch (key, modifiers) {
        case ("s", .command):
            save()
            return true
        case ("f", .command):
            findAction = .showFindInterface
        case ("g", .command):
            findAction = .nextMatch
        case ("g", [.command, .shift]):
            findAction = .previousMatch
        default:
            return super.performKeyEquivalent(with: event)
        }
        guard document.content == .text else { return super.performKeyEquivalent(with: event) }
        let sender = NSMenuItem()
        sender.tag = findAction.rawValue
        textView.performTextFinderAction(sender)
        return true
    }
}

extension EditorPaneView: NSTextViewDelegate {
    /// One undo history per file, shared by every tab showing it.
    func undoManager(for view: NSTextView) -> UndoManager? {
        document.undoManager
    }
}

// MARK: - Layout Manager

extension NSAttributedString.Key {
    /// Temporary attribute: draw this run in the Semibold weight of its font.
    static let editorSyntaxEmphasis = NSAttributedString.Key("SopranoEditorSyntaxEmphasis")
}

/// Draws runs marked `editorSyntaxEmphasis` in Semibold: glyphs are drawn
/// run by run, and a marked run's glyphs are shown with the Semibold weight
/// of their font. SF Mono's weights share glyphs and advances, so nothing
/// moves and the shared text keeps its one font.
final class EditorLayoutManager: NSLayoutManager {
    private var drawsEmphasis = false
    private var semiboldFonts: [CGFloat: NSFont] = [:]

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard characters.length > 0 else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let end = NSMaxRange(characters)
        var location = characters.location
        while location < end {
            var run = NSRange()
            drawsEmphasis = temporaryAttribute(
                .editorSyntaxEmphasis,
                atCharacterIndex: location,
                longestEffectiveRange: &run,
                in: NSRange(location: location, length: end - location)
            ) as? Bool == true
            let glyphs = glyphRange(forCharacterRange: run, actualCharacterRange: nil)
            super.drawGlyphs(forGlyphRange: NSIntersectionRange(glyphs, glyphsToShow), at: origin)
            location = max(NSMaxRange(run), location + 1)
        }
        drawsEmphasis = false
    }

    override func showCGGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        positions: UnsafePointer<CGPoint>,
        count glyphCount: Int,
        font: NSFont,
        textMatrix: CGAffineTransform,
        attributes: [NSAttributedString.Key: Any] = [:],
        in context: CGContext
    ) {
        guard drawsEmphasis, let semibold = semiboldFont(matching: font) else {
            super.showCGGlyphs(
                glyphs, positions: positions, count: glyphCount, font: font,
                textMatrix: textMatrix, attributes: attributes, in: context
            )
            return
        }
        // AppKit shows the glyphs with the context's font, so the Semibold
        // instance goes there for this run.
        context.saveGState()
        context.setFont(CTFontCopyGraphicsFont(semibold, nil))
        super.showCGGlyphs(
            glyphs, positions: positions, count: glyphCount, font: semibold,
            textMatrix: textMatrix, attributes: attributes, in: context
        )
        context.restoreGState()
    }

    /// SF Mono Semibold at `font`'s size; nil for any other family, since only
    /// SF Mono's own weights share its glyph ids.
    private func semiboldFont(matching font: NSFont) -> NSFont? {
        let semibold = semiboldFonts[font.pointSize] ?? {
            let made = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
            semiboldFonts[font.pointSize] = made
            return made
        }()
        return font.familyName == semibold.familyName ? semibold : nil
    }
}

// MARK: - Text View

/// The editor's text view, keeping the current indentation on Return.
final class EditorTextView: NSTextView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            DispatchQueue.main.async { [weak self] in
                self?.onFocus?()
            }
        }
        return accepted
    }

    override func insertNewline(_ sender: Any?) {
        guard let text = textStorage?.mutableString else {
            super.insertNewline(sender)
            return
        }
        let caret = min(selectedRange().location, text.length)
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        var indentEnd = lineStart
        while indentEnd < caret {
            let character = text.character(at: indentEnd)
            guard character == 32 || character == 9 else { break }
            indentEnd += 1
        }
        let indentation = text.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))
        super.insertNewline(sender)
        if !indentation.isEmpty {
            insertText(indentation, replacementRange: selectedRange())
        }
    }
}

// MARK: - Line Numbers

/// The gutter (Agents' `FileLineNumberGutter`): muted, right-aligned SF Mono
/// 12 beside the first line fragment of each line, 10 pt either side, on the
/// text's background with no rule.
final class EditorLineNumberRuler: NSRulerView {
    static let padding: CGFloat = 10

    private weak var editorTextView: NSTextView?
    private let document: EditorDocument

    private let font = Typography.mono(Typography.smallSize)

    init(textView: NSTextView, document: EditorDocument) {
        self.editorTextView = textView
        self.document = document
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        // A ruler sits beside the scroll view, not inside its clip view; the
        // gutter must keep its fill and numbers off the toolbar.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Wide enough for the largest line number (two digits at least).
    func updateThickness() {
        let digits = max(2, String(document.lineCount).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth) + Self.padding * 2
        if thickness != ruleThickness {
            ruleThickness = thickness
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The dirty rect can reach past the ruler's bounds; clip so the
        // fill and numbers stay inside the gutter.
        NSBezierPath.clip(bounds)
        PaletteCenter.shared.palette.background.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = editorTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let text = textView.textStorage?.mutableString
        else { return }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let insetY = textView.textContainerOrigin.y
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: PaletteCenter.shared.palette.mutedForeground,
        ]

        func drawNumber(_ number: Int, fragmentY: CGFloat, height: CGFloat) {
            let y = convert(NSPoint(x: 0, y: fragmentY + insetY), from: textView).y
            let label = String(number) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - Self.padding, y: y + (height - size.height) / 2),
                withAttributes: attributes
            )
        }

        var lineStart = text.lineRange(for: NSRange(location: min(characterRange.location, text.length), length: 0)).location
        var number = document.lineNumber(at: lineStart)
        while lineStart < text.length, lineStart <= NSMaxRange(characterRange) {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineStart)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            drawNumber(number, fragmentY: fragment.minY, height: fragment.height)
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            guard lineRange.length > 0 else { break }
            lineStart = NSMaxRange(lineRange)
            number += 1
        }
        // The empty last line after a trailing newline, or an empty file.
        let extra = layoutManager.extraLineFragmentRect
        if extra.height > 0, NSMaxRange(characterRange) >= text.length {
            drawNumber(document.lineCount, fragmentY: extra.minY, height: extra.height)
        }
    }
}

extension NSResponder {
    /// The view holding the keyboard: a field editor stands in for the
    /// control it is editing (an address bar, a find field).
    var focusedView: NSView? {
        if let editor = self as? NSTextView, editor.isFieldEditor {
            return editor.delegate as? NSView
        }
        return self as? NSView
    }
}
