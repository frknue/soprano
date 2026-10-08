import AppKit

/// A file open in Soprano, Orca-style: an editable, syntax-colored text view
/// with line numbers, find (⌘F), undo, and ⌘S; images are shown, other files
/// get a note and a way out to their default app.
///
/// Every tab showing the same file shares one `EditorDocument`, so edits,
/// undo, and the saved state are the same in each.
final class EditorPaneView: NSView {
    static let toolbarHeight: CGFloat = 34

    let target: TerminalTarget
    let document: EditorDocument
    private let store: EditorDocumentStore
    private let themeManager: ThemeManager

    var onFocusRequested: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?
    /// The document gained unsaved changes; its tab stops being a preview.
    var onEdited: (() -> Void)?
    var onMarkdownPreviewRequested: ((URL) -> Void)?

    private let toolbar = NSView()
    private let toolbarRule = RetroRuleView(axis: .horizontal, style: .single)
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var reloadButton: RetroButton!
    private var saveButton: RetroIconButton!
    private var previewButton: RetroIconButton!
    private var revealButton: RetroIconButton!
    private var openExternallyButton: RetroIconButton!

    private let scrollView = NSScrollView()
    private let layoutManager = NSLayoutManager()
    let textView: EditorTextView
    private var ruler: EditorLineNumberRuler!
    private let imageView = NSImageView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var messageButton: RetroButton!
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
        toolbar.wantsLayer = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

        pathLabel.font = RetroFont.body(11)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(pathLabel)

        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(statusLabel)

        reloadButton = RetroButton(
            title: "Reload",
            theme: themeManager.currentTheme,
            target: self,
            action: #selector(reloadClicked)
        )
        reloadButton.toolTip = "Replace your unsaved changes with the version on disk"
        toolbar.addSubview(reloadButton)

        saveButton = makeToolbarButton("square.and.arrow.down", "Save (⌘S)", #selector(saveClicked))
        previewButton = makeToolbarButton("eye", "Open Markdown Preview", #selector(previewClicked))
        revealButton = makeToolbarButton("folder", "Reveal in Finder", #selector(revealClicked))
        openExternallyButton = makeToolbarButton(
            "arrow.up.forward.app",
            "Open with Default App",
            #selector(openExternallyClicked)
        )
        toolbar.addSubview(toolbarRule)

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
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.onFocus = { [weak self] in self?.onFocusRequested?() }
        textView.setAccessibilityLabel(document.name)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleTextChanged),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        addSubview(scrollView)

        imageView.imageScaling = .scaleProportionallyDown
        imageView.animates = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        messageLabel.alignment = .center
        messageLabel.font = RetroFont.body(12)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)
        messageButton = RetroButton(
            title: "Open with Default App",
            theme: themeManager.currentTheme,
            target: self,
            action: #selector(openExternallyClicked)
        )
        addSubview(messageButton)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),

            pathLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            pathLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -10),

            statusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -8),

            reloadButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            reloadButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -6),

            openExternallyButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            openExternallyButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            revealButton.trailingAnchor.constraint(equalTo: openExternallyButton.leadingAnchor, constant: -2),
            revealButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            previewButton.trailingAnchor.constraint(equalTo: revealButton.leadingAnchor, constant: -2),
            previewButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: previewButton.leadingAnchor, constant: -2),
            saveButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            toolbarRule.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarRule.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarRule.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarRule.heightAnchor.constraint(equalToConstant: Retro.hairline),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),

            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            messageButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 14),
            messageButton.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    private func makeToolbarButton(_ symbol: String, _ label: String, _ action: Selector) -> RetroIconButton {
        let button = RetroIconButton(
            symbolName: symbol,
            accessibilityLabel: label,
            pointSize: 12,
            size: 24,
            target: self,
            action: action
        )
        toolbar.addSubview(button)
        return button
    }

    // MARK: - Theme

    func applyTheme() {
        let colors = themeManager.currentTheme.colors
        layer?.backgroundColor = colors.bgBase.cgColor
        toolbar.layer?.backgroundColor = colors.bgPanel.cgColor
        toolbarRule.color = colors.borderStrong
        pathLabel.textColor = colors.textMuted
        for button in [saveButton, previewButton, revealButton, openExternallyButton] {
            button?.setTints(normal: colors.textMuted, hover: colors.accent)
        }
        reloadButton.apply(theme: themeManager.currentTheme)
        messageButton.apply(theme: themeManager.currentTheme)
        messageLabel.textColor = colors.textMuted

        let font = RetroFont.body(12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colors.textPrimary,
            .paragraphStyle: paragraph,
        ]
        document.applyBaseAttributes(attributes)
        textView.typingAttributes = attributes
        textView.backgroundColor = colors.bgBase
        textView.insertionPointColor = colors.accent
        textView.selectedTextAttributes = [.backgroundColor: colors.accent.withAlphaComponent(0.3)]
        scrollView.backgroundColor = colors.bgBase
        ruler.colors = colors
        applyHighlights()
        updateChrome()
    }

    static func color(for kind: SyntaxTokenKind, in colors: ThemeColors) -> NSColor {
        switch kind {
        case .keyword, .tag: colors.accentStrong
        case .string, .inserted: colors.success
        case .comment: colors.textMuted
        case .number, .attribute, .heading: colors.accent
        case .type: colors.cyan
        case .function, .key: colors.blue
        case .deleted: colors.danger
        }
    }

    /// Syntax colors are drawn by this view's layout manager rather than
    /// stored in the shared text, so they never touch undo or the dirty state.
    private func applyHighlights() {
        let length = document.textStorage.length
        layoutManager.removeTemporaryAttribute(
            .foregroundColor,
            forCharacterRange: NSRange(location: 0, length: length)
        )
        let colors = themeManager.currentTheme.colors
        for token in document.tokens where NSMaxRange(token.range) <= length {
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: Self.color(for: token.kind, in: colors),
                forCharacterRange: token.range
            )
        }
    }

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
        if case .unavailable(let message) = content {
            messageLabel.stringValue = message
            messageLabel.isHidden = false
            messageButton.isHidden = false
        } else {
            messageLabel.isHidden = true
            messageButton.isHidden = true
        }
        textView.isEditable = content == .text && !document.isReadOnly
        lastLineCountDigits = String(document.lineCount).count
        ruler.updateThickness()
        applyHighlights()
    }

    private func updateChrome() {
        let colors = themeManager.currentTheme.colors
        pathLabel.stringValue = ConfigFile.abbreviatingHome(document.url.path)
        pathLabel.toolTip = document.url.path
        textView.isEditable = document.content == .text && !document.isReadOnly

        let status: (text: String, color: NSColor)? = switch (document.diskState, document.content) {
        case (.changed, _):
            ("Changed on disk", colors.danger)
        case (.deleted, _):
            ("Deleted on disk", colors.danger)
        case (_, .image):
            document.image.map { ("\(Int($0.size.width)) × \(Int($0.size.height))", colors.textMuted) }
        case (_, .unavailable):
            nil
        default:
            if document.isReadOnly {
                ("Read only", colors.textMuted)
            } else if document.isDirty {
                ("Modified", colors.yellow)
            } else {
                nil
            }
        }
        statusLabel.isHidden = status == nil
        statusLabel.setRetroText(status?.text ?? "", color: status?.color ?? colors.textMuted, tracking: 0)
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

/// The gutter: a line number beside the first line fragment of each line,
/// the caret's line brighter.
final class EditorLineNumberRuler: NSRulerView {
    private weak var editorTextView: NSTextView?
    private let document: EditorDocument
    var colors: ThemeColors? {
        didSet { needsDisplay = true }
    }

    private let font = RetroFont.body(10)

    init(textView: NSTextView, document: EditorDocument) {
        self.editorTextView = textView
        self.document = document
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Wide enough for the largest line number.
    func updateThickness() {
        let digits = max(3, String(document.lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + 18)
        if thickness != ruleThickness {
            ruleThickness = thickness
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors else { return }
        colors.bgPanel.setFill()
        bounds.fill()
        colors.borderSubtle.setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let colors,
              let textView = editorTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let text = textView.textStorage?.mutableString
        else { return }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let insetY = textView.textContainerOrigin.y
        let caretLine = document.lineNumber(at: textView.selectedRange().location)

        func drawNumber(_ number: Int, fragmentY: CGFloat, height: CGFloat) {
            let y = convert(NSPoint(x: 0, y: fragmentY + insetY), from: textView).y
            let label = String(number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: number == caretLine ? colors.textPrimary : colors.textMuted,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 9, y: y + (height - size.height) / 2),
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
