import AppKit

/// One file's git diff, read-only, after Orca's diff editor: the whole file
/// with removed and added rows tinted, inline or side by side, kept current
/// while the tab is shown.
final class DiffPaneView: NSView {
    static let toolbarHeight: CGFloat = 34
    /// The layout new diff views start in; the toggle updates it.
    static let sideBySideDefaultsKey = "soprano-diff-side-by-side"

    let target: TerminalTarget
    let fileURL: URL
    let staged: Bool
    private let themeManager: ThemeManager
    private let defaults: UserDefaults

    var onFocusRequested: (() -> Void)?
    /// Opens the working-tree file in the editor (toolbar button).
    var onOpenFileRequested: ((URL) -> Void)?

    private let toolbar = NSView()
    private let toolbarRule = RetroRuleView(axis: .horizontal, style: .single)
    private let pathLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private var previousButton: RetroIconButton!
    private var nextButton: RetroIconButton!
    private var layoutButton: RetroIconButton!
    private var openFileButton: RetroIconButton!

    /// The inline view, or the old side when side by side.
    private let primary = DiffColumn()
    /// The new side when side by side.
    private let secondary = DiffColumn()
    private let columnRule = RetroRuleView(axis: .vertical, style: .single)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var inlineConstraints: [NSLayoutConstraint] = []
    private var sideBySideConstraints: [NSLayoutConstraint] = []

    private var isSideBySide: Bool
    private var rendering: DiffRendering?
    private var fileExists: Bool
    private var isSyncingScroll = false
    private var needsFirstChangeScroll = false
    private var didScrollToFirstChange = false

    private var location: DiffLocation?
    private var externalGitDirectory: String?
    private var watcher: FileSystemWatcher?
    private var wasDetached = false
    private var hasLoaded = false
    private var loadGeneration = 0
    private var loadInFlight = false
    private var reloadPending = false
    private var reloadTask: Task<Void, Never>?

    init(
        target: TerminalTarget,
        fileURL: URL,
        staged: Bool,
        themeManager: ThemeManager,
        defaults: UserDefaults = .standard
    ) {
        self.target = target
        self.fileURL = fileURL
        self.staged = staged
        self.themeManager = themeManager
        self.defaults = defaults
        isSideBySide = defaults.bool(forKey: Self.sideBySideDefaultsKey)
        fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()
        applyLayoutMode()
        applyTheme()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    func focusPreferredControl() {
        onFocusRequested?()
        window?.makeFirstResponder(rendering != nil ? primary.textView : self)
    }

    // MARK: - Setup

    private func setupViews() {
        toolbar.wantsLayer = true
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

        pathLabel.font = RetroFont.body(11)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.stringValue = ConfigFile.abbreviatingHome(fileURL.path)
        pathLabel.toolTip = fileURL.path
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statsLabel.font = RetroFont.body(11)
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statsLabel.setContentHuggingPriority(.required, for: .horizontal)
        let labels = NSStackView(views: [pathLabel, statusLabel, statsLabel])
        labels.orientation = .horizontal
        labels.alignment = .centerY
        labels.spacing = 8
        labels.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(labels)

        previousButton = makeToolbarButton("chevron.up", "Previous Change (⇧F7)", #selector(previousChangeClicked))
        nextButton = makeToolbarButton("chevron.down", "Next Change (F7)", #selector(nextChangeClicked))
        layoutButton = makeToolbarButton("rectangle.split.2x1", "Switch to Side-by-Side Diff", #selector(layoutClicked))
        openFileButton = makeToolbarButton("doc.text", "Open File", #selector(openFileClicked))
        toolbar.addSubview(toolbarRule)

        for column in [primary, secondary] {
            column.textView.onFocus = { [weak self] in self?.onFocusRequested?() }
            column.textView.onNavigate = { [weak self] forward in self?.navigate(forward: forward) }
            column.textView.setAccessibilityLabel(fileURL.lastPathComponent)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: column.clipView
            )
            addSubview(column.scrollView)
        }
        addSubview(columnRule)

        messageLabel.alignment = .center
        messageLabel.font = RetroFont.body(12)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        let primaryView = primary.scrollView
        let secondaryView = secondary.scrollView
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),

            labels.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: previousButton.leadingAnchor, constant: -10),

            openFileButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -6),
            openFileButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            layoutButton.trailingAnchor.constraint(equalTo: openFileButton.leadingAnchor, constant: -2),
            layoutButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: layoutButton.leadingAnchor, constant: -2),
            nextButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -2),
            previousButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            toolbarRule.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarRule.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            toolbarRule.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarRule.heightAnchor.constraint(equalToConstant: Retro.hairline),

            primaryView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            primaryView.bottomAnchor.constraint(equalTo: bottomAnchor),
            primaryView.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnRule.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            columnRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            columnRule.widthAnchor.constraint(equalToConstant: Retro.hairline),
            columnRule.trailingAnchor.constraint(equalTo: secondaryView.leadingAnchor),
            secondaryView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            secondaryView.bottomAnchor.constraint(equalTo: bottomAnchor),
            secondaryView.trailingAnchor.constraint(equalTo: trailingAnchor),

            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Self.toolbarHeight / 2 - 10),
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
        ])
        // Inline, the new side collapses to nothing at the trailing edge.
        inlineConstraints = [
            primaryView.trailingAnchor.constraint(equalTo: trailingAnchor),
            secondaryView.widthAnchor.constraint(equalToConstant: 0),
        ]
        sideBySideConstraints = [
            primaryView.trailingAnchor.constraint(equalTo: columnRule.leadingAnchor),
            secondaryView.widthAnchor.constraint(equalTo: primaryView.widthAnchor),
        ]
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

    private func applyLayoutMode() {
        NSLayoutConstraint.deactivate(isSideBySide ? inlineConstraints : sideBySideConstraints)
        NSLayoutConstraint.activate(isSideBySide ? sideBySideConstraints : inlineConstraints)
        updateContentVisibility()
    }

    private func updateContentVisibility() {
        let showsText = rendering != nil
        primary.scrollView.isHidden = !showsText
        secondary.scrollView.isHidden = !showsText || !isSideBySide
        columnRule.isHidden = !showsText || !isSideBySide
        messageLabel.isHidden = showsText
    }

    // MARK: - Theme

    func applyTheme() {
        let colors = themeManager.currentTheme.colors
        layer?.backgroundColor = colors.bgBase.cgColor
        toolbar.layer?.backgroundColor = colors.bgPanel.cgColor
        toolbarRule.color = colors.borderStrong
        columnRule.color = colors.borderStrong
        pathLabel.textColor = colors.textMuted
        for button in [previousButton, nextButton, layoutButton, openFileButton] {
            button?.setTints(normal: colors.textMuted, hover: colors.accent)
        }
        messageLabel.textColor = colors.textMuted
        primary.apply(colors: colors)
        secondary.apply(colors: colors)
        updateChrome()
    }

    private func updateChrome() {
        let colors = themeManager.currentTheme.colors
        statusLabel.isHidden = !staged
        statusLabel.setRetroText(staged ? "Staged" : "", color: colors.textMuted, tracking: 0)

        let stats = NSMutableAttributedString()
        if let rendering {
            let font = RetroFont.body(11)
            if rendering.linesAdded > 0 {
                stats.append(NSAttributedString(
                    string: "+\(rendering.linesAdded)",
                    attributes: [.font: font, .foregroundColor: colors.success]
                ))
            }
            if rendering.linesRemoved > 0 {
                if stats.length > 0 {
                    stats.append(NSAttributedString(string: " ", attributes: [.font: font]))
                }
                stats.append(NSAttributedString(
                    string: "−\(rendering.linesRemoved)",
                    attributes: [.font: font, .foregroundColor: colors.danger]
                ))
            }
        }
        statsLabel.attributedStringValue = stats
        statsLabel.isHidden = stats.length == 0

        let hasChanges = rendering != nil && !(primary.side?.changeStarts.isEmpty ?? true)
        previousButton.isEnabled = hasChanges
        nextButton.isEnabled = hasChanges
        let layoutLabel = isSideBySide ? "Switch to Inline Diff" : "Switch to Side-by-Side Diff"
        layoutButton.setSymbol(
            isSideBySide ? "rectangle.split.1x2" : "rectangle.split.2x1",
            accessibilityLabel: layoutLabel,
            pointSize: 12
        )
        layoutButton.toolTip = layoutLabel
        openFileButton.isEnabled = fileExists
    }

    // MARK: - Loading

    /// Reloads after a quiet spell, never with two reads in flight.
    private func scheduleReload(immediately: Bool = false) {
        if loadInFlight {
            reloadPending = true
            return
        }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.reloadTask = nil
            self?.load()
        }
    }

    private func load() {
        guard !loadInFlight else {
            reloadPending = true
            return
        }
        loadInFlight = true
        loadGeneration += 1
        let generation = loadGeneration
        let filePath = fileURL.standardizedFileURL.path
        let staged = staged
        if !hasLoaded {
            showLoadingMessageIfSlow()
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = DiffLoader.load(filePath: filePath, staged: staged)
            Task { @MainActor [weak self] in
                self?.finishLoad(result, generation: generation)
            }
        }
    }

    /// A quick first read shows the diff straight away; a slow one says so.
    private func showLoadingMessageIfSlow() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !self.hasLoaded, self.loadInFlight else { return }
            self.messageLabel.stringValue = "Loading diff…"
            self.updateContentVisibility()
        }
    }

    private func finishLoad(_ result: DiffLoadResult, generation: Int) {
        loadInFlight = false
        guard generation == loadGeneration else { return }
        hasLoaded = true
        fileExists = result.fileExists
        updateLocation(result.location)

        switch result.content {
        case .message(let message):
            rendering = nil
            primary.show(nil)
            secondary.show(nil)
            messageLabel.stringValue = message
            updateContentVisibility()
        case .text(let newRendering):
            if newRendering.lines != rendering?.lines {
                let savedOrigin = rendering != nil ? primary.clipView.bounds.origin : nil
                let savedSecondaryX = secondary.clipView.bounds.minX
                rendering = newRendering
                updateContentVisibility()
                showRendering()
                layoutSubtreeIfNeeded()
                if let savedOrigin {
                    primary.scroll(to: savedOrigin)
                    if isSideBySide {
                        secondary.scroll(to: NSPoint(x: savedSecondaryX, y: secondary.clipView.bounds.minY))
                    }
                }
                if !didScrollToFirstChange {
                    didScrollToFirstChange = true
                    needsFirstChangeScroll = true
                    scrollToFirstChangeIfSized()
                }
            }
        }
        updateChrome()

        if reloadPending {
            reloadPending = false
            scheduleReload()
        }
    }

    private func showRendering() {
        guard let rendering else { return }
        if isSideBySide {
            primary.show(rendering.old)
            secondary.show(rendering.new)
        } else {
            primary.show(rendering.inline)
            secondary.show(nil)
        }
    }

    /// The first change is scrolled to once the view has a height, which a
    /// tab loaded in the background gets only when shown.
    private func scrollToFirstChangeIfSized() {
        guard needsFirstChangeScroll, primary.clipView.bounds.height > 0 else { return }
        needsFirstChangeScroll = false
        if let first = primary.side?.changeStarts.first {
            primary.scroll(toRow: first)
        }
    }

    override func layout() {
        super.layout()
        scrollToFirstChangeIfSized()
    }

    // MARK: - Watching

    private func updateLocation(_ newLocation: DiffLocation?) {
        guard newLocation != location else { return }
        location = newLocation
        externalGitDirectory = newLocation.flatMap { FileExplorerView.externalGitDirectory(forRoot: $0.root) }
        stopWatching()
        if window != nil {
            startWatching()
        }
    }

    private func startWatching() {
        guard watcher == nil, let location else { return }
        let paths = [location.root] + [externalGitDirectory].compactMap { $0 }
        watcher = FileSystemWatcher(paths: paths) { [weak self] paths, needsRescan in
            self?.handleFileSystemEvents(paths, needsRescan: needsRescan)
        }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    /// Only the file itself and git's own state can change its diff.
    private func handleFileSystemEvents(_ paths: [String], needsRescan: Bool) {
        guard let location else { return }
        let gitDirectory = location.realRoot + "/.git"
        let externalGitDirectory = externalGitDirectory
        let relevant = needsRescan || paths.contains { path in
            if path == location.realFilePath || path == gitDirectory || path.hasPrefix(gitDirectory + "/") {
                return true
            }
            guard let externalGitDirectory else { return false }
            return path == externalGitDirectory || path.hasPrefix(externalGitDirectory + "/")
        }
        if relevant {
            scheduleReload()
        }
    }

    /// Inactive tabs leave the window; they stop watching meanwhile and
    /// catch up when shown again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stopWatching()
            wasDetached = true
            return
        }
        startWatching()
        if wasDetached {
            wasDetached = false
            scheduleReload(immediately: true)
        }
    }

    @objc private func applicationDidBecomeActive() {
        guard window != nil, hasLoaded else { return }
        scheduleReload(immediately: true)
    }

    // MARK: - Scrolling

    /// Keeps both sides on the same rows; horizontal scrolling stays per side.
    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        let isPrimary = clip === primary.clipView
        let source = isPrimary ? primary : secondary
        let other = isPrimary ? secondary : primary
        source.ruler.needsDisplay = true
        guard isSideBySide, !isSyncingScroll else { return }
        let otherClip = other.clipView
        guard otherClip.bounds.minY != clip.bounds.minY else { return }
        isSyncingScroll = true
        other.scroll(to: NSPoint(x: otherClip.bounds.minX, y: clip.bounds.minY))
        isSyncingScroll = false
    }

    /// Moves to the next or previous change relative to the row a third of
    /// the way down; side by side, the old side leads and the new follows.
    private func navigate(forward: Bool) {
        guard rendering != nil,
              let side = primary.side,
              let anchor = primary.anchorRow()
        else { return }
        let target = forward
            ? side.changeStarts.first(where: { $0 > anchor })
            : side.changeStarts.last(where: { $0 < anchor })
        if let target {
            primary.scroll(toRow: target)
        }
    }

    // MARK: - Actions

    @objc private func previousChangeClicked() {
        navigate(forward: false)
    }

    @objc private func nextChangeClicked() {
        navigate(forward: true)
    }

    @objc private func layoutClicked() {
        let anchorLine = primary.topAnchorLine()
        let secondaryHadFocus = window?.firstResponder === secondary.textView
        isSideBySide.toggle()
        defaults.set(isSideBySide, forKey: Self.sideBySideDefaultsKey)
        applyLayoutMode()
        showRendering()
        layoutSubtreeIfNeeded()
        if let anchorLine {
            primary.scroll(toAnchorLine: anchorLine)
        }
        if secondaryHadFocus {
            window?.makeFirstResponder(primary.textView)
        }
        updateChrome()
    }

    @objc private func openFileClicked() {
        onOpenFileRequested?(fileURL)
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }
}

// MARK: - Loading

/// Where a diff's file lives, as the watcher reports paths.
private struct DiffLocation: Equatable, Sendable {
    let root: String
    let realRoot: String
    let realFilePath: String
}

private struct DiffLoadResult: Sendable {
    enum Content: Sendable {
        case text(DiffRendering)
        case message(String)
    }

    let location: DiffLocation?
    let fileExists: Bool
    let content: Content
}

/// Reads and lays out a diff; blocks on git, so it runs off the main thread.
private enum DiffLoader {
    static func load(filePath: String, staged: Bool) -> DiffLoadResult {
        let fileExists = FileManager.default.fileExists(atPath: filePath)
        func message(_ text: String, _ location: DiffLocation? = nil) -> DiffLoadResult {
            DiffLoadResult(location: location, fileExists: fileExists, content: .message(text))
        }

        guard GitStatusReader.executableURL != nil else { return message("Git is not installed.") }
        // Walks up from the folder, so a deleted file still finds its repository.
        guard let root = GitBranchMonitor.repositoryRoot(startingAt: (filePath as NSString).deletingLastPathComponent)
        else { return message("This file is not in a Git repository.") }
        let realRoot = resolvedPath(root)
        let realFilePath = resolvedPath(filePath)
        guard let relativePath = relativePath(of: filePath, in: root) ?? relativePath(of: realFilePath, in: realRoot)
        else { return message("This file is not in a Git repository.") }
        let location = DiffLocation(root: root, realRoot: realRoot, realFilePath: realFilePath)

        switch GitStatusReader.diff(root: root, relativePath: relativePath, staged: staged) {
        case .text(let lines):
            let language = CodeLanguage.forFile(named: (filePath as NSString).lastPathComponent)
            return DiffLoadResult(
                location: location,
                fileExists: fileExists,
                content: .text(DiffRendering(lines: lines, language: language))
            )
        case .binary:
            return message("Binary file changed\nText diff is unavailable for this file.", location)
        case .tooLarge:
            return message("This diff is too large to show.", location)
        case .noChanges:
            return message(staged ? "No staged changes" : "No changes", location)
        case .unavailable:
            return message("Could not read this diff.", location)
        }
    }

    private static func relativePath(of path: String, in root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The symlink-free path, resolving the nearest existing ancestor for a
    /// deleted file.
    private static func resolvedPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (resolvedPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
