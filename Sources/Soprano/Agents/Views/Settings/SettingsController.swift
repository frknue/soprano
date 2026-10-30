import AppKit
import SopranoAgentsCore

/// The settings screen, T3 Code's settings route modal (`AppRouteModal`): a child window over
/// the main window with a dimmed backdrop and a centered card (max 1280×960, r16, border,
/// shadow); a 240 pt navigation (`bg-sidebar border-e`) on the left; a breadcrumb header and the
/// page on the right.
///
/// The screen keeps no settings state: every control writes through
/// `SettingsCenter.write(_:at:)` / `remove(at:)` and the page re-renders when settings.json
/// (or the engine's providers / archived threads) change. Esc closes it.
@MainActor
final class SettingsController: NSObject {
    static let maxSize = NSSize(width: 1280, height: 960)
    static let navWidth: CGFloat = 240
    static let pageMaxWidth: CGFloat = 768

    let engine: AgentEngine
    let center: SettingsCenter
    private weak var parent: NSWindow?
    private weak var router: KeyboardRouter?

    private let window = OverlayWindow()
    private let card = OverlayCardView(surface: .background)
    private let nav = SettingsNavView()
    private let header = SettingsHeaderView()
    private let scrollView = NSScrollView()
    private let document = FlippedStackDocument()

    private(set) var page: SettingsPage = .general
    /// The Keybindings page's filter text.
    private(set) var keybindingQuery = ""
    /// The command whose chord is being recorded.
    private(set) var recordingCommandID: String?
    private var recorder: ShortcutRecorder?
    private var renderScheduled = false

    init(engine: AgentEngine, center: SettingsCenter = .shared, parent: NSWindow, router: KeyboardRouter?) {
        self.engine = engine
        self.center = center
        self.parent = parent
        self.router = router
        super.init()
    }

    // MARK: - Opening

    /// Opens the settings screen on `page` over `window`; an open one switches to `page`.
    @discardableResult
    static func present(page: SettingsPage = .general, engine: AgentEngine, over window: NSWindow) -> SettingsController {
        if let open = current(over: window) {
            open.show(page)
            return open
        }
        let router = (window.windowController as? MainWindowController)?.router
        let controller = SettingsController(engine: engine, parent: window, router: router)
        controller.page = page
        controller.open()
        return controller
    }

    static func current(over window: NSWindow?) -> SettingsController? {
        window?.childWindows?.lazy
            .compactMap { ($0 as? OverlayWindow)?.owner as? SettingsController }
            .first
    }

    /// `settings.open`: opens the screen, or closes it when it is the topmost overlay.
    static func toggle(in context: CommandContext) {
        guard let window = context.window, let engine = context.engine else { return }
        if let open = current(over: window) {
            open.close()
            return
        }
        present(engine: engine, over: window)
    }

    private func open() {
        guard let parent else { return }
        window.owner = self
        buildViews()
        center.addObserver(self) { [weak self] in self?.scheduleRender() }
        engine.addObserver(self) { [weak self] event in
            guard let self else { return }
            switch (event, page) {
            case (.providersChanged, .providers), (.providersChanged, .textGeneration),
                 (.threadListChanged, .archive), (.projectsChanged, .archive):
                scheduleRender()
            default:
                break
            }
        }
        window.backdrop.onClick = { [weak self] in self?.close() }
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.onClose = { [weak self] in self?.stopRecording(rerender: false) }
        NotificationCenter.default.addObserver(self, selector: #selector(overlayResized), name: NSWindow.didResizeNotification, object: window)
        render(resetScroll: true)
        window.present(over: parent, focus: document)
    }

    func close() {
        window.dismiss()
    }

    @objc private func overlayResized() {
        scheduleRender()
    }

    private func buildViews() {
        let backdrop = window.backdrop
        card.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(card)
        let content = card.content

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document

        nav.onSelect = { [weak self] page in self?.show(page) }
        nav.onOpenFile = { [weak self] in self?.center.openInEditor() }
        header.onClose = { [weak self] in self?.close() }

        for view in [nav, header, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let width = card.widthAnchor.constraint(equalToConstant: Self.maxSize.width)
        width.priority = .overlayPreferred
        let height = card.heightAnchor.constraint(equalToConstant: Self.maxSize.height)
        height.priority = .overlayPreferred
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            width, height,
            card.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -64),
            card.heightAnchor.constraint(lessThanOrEqualTo: backdrop.heightAnchor, constant: -64),

            nav.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            nav.topAnchor.constraint(equalTo: content.topAnchor),
            nav.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            nav.widthAnchor.constraint(equalToConstant: Self.navWidth),

            header.leadingAnchor.constraint(equalTo: nav.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.topbarHeight),

            scrollView.leadingAnchor.constraint(equalTo: nav.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// Width of the page column for the current window size.
    private var pageWidth: CGFloat {
        let parentWidth = window.frame.width
        let cardWidth = min(Self.maxSize.width, parentWidth - 64)
        return max(320, min(Self.pageMaxWidth, cardWidth - Self.navWidth - 48))
    }

    // MARK: - Pages

    func show(_ page: SettingsPage) {
        guard page != self.page else { return }
        stopRecording(rerender: false)
        self.page = page
        render(resetScroll: true)
    }

    func movePage(by delta: Int) {
        let pages = SettingsPage.allCases
        guard let index = pages.firstIndex(of: page) else { return }
        show(pages[(index + delta + pages.count) % pages.count])
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        // Re-rendering tears down the control that fired; let its event finish first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            renderScheduled = false
            guard !window.isClosing else { return }
            render(resetScroll: false)
        }
    }

    /// Rebuilds the page from settings and the engine, keeping the scroll position and the
    /// focused text field (by identifier, with its selection) unless the page changed.
    func render(resetScroll: Bool) {
        let focused = focusedFieldState()
        let origin = scrollView.contentView.bounds.origin
        nav.update(selected: page)
        header.update(page: page)

        let form = SettingsForm(width: pageWidth)
        let sections = buildPage(page, form: form)
        document.setSections(sections, width: pageWidth)
        card.content.layoutSubtreeIfNeeded()
        document.fit(to: scrollView.contentView.bounds.width)

        let clip = scrollView.contentView
        let target = resetScroll ? .zero : clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
        restoreFocus(focused)
    }

    private func focusedFieldState() -> (identifier: NSUserInterfaceItemIdentifier, selection: NSRange)? {
        guard let editor = window.firstResponder as? NSTextView,
              let field = editor.delegate as? NSTextField,
              let identifier = field.identifier
        else { return nil }
        return (identifier, editor.selectedRange())
    }

    private func restoreFocus(_ state: (identifier: NSUserInterfaceItemIdentifier, selection: NSRange)?) {
        if let state, let field = document.field(withIdentifier: state.identifier) {
            window.makeFirstResponder(field)
            let length = field.stringValue.utf16.count
            let location = min(state.selection.location, length)
            field.currentEditor()?.selectedRange = NSRange(location: location, length: min(state.selection.length, length - location))
        } else if window.firstResponder == nil || window.firstResponder === window || !(window.firstResponder is NSView) {
            window.makeFirstResponder(document)
        }
    }

    /// Writes one value; failures surface as settings issues on the General page.
    func write(_ value: Any, at path: [String]) {
        center.write(value, at: path)
    }

    func remove(_ path: [String]) {
        center.remove(at: path)
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if recordingCommandID != nil {
            if let router, router.capture != nil {
                _ = router.dispatch(event)
            } else {
                recorderReceivedEvent(event)
            }
            return true
        }
        guard let stroke = KeyStroke(event: event), !stroke.option else { return false }
        if stroke.key == "\u{1B}", !stroke.ctrl, !stroke.meta, !stroke.shift {
            if page == .keybindings, !keybindingQuery.isEmpty, isEditingFilter {
                keybindingQuery = ""
                render(resetScroll: false)
            } else {
                close()
            }
            return true
        }
        if stroke.meta, !stroke.ctrl, !stroke.shift, stroke.key == "w" || stroke.key == "," {
            close()
            return true
        }
        if stroke.meta, !stroke.ctrl, !stroke.shift, stroke.key == "f", page == .keybindings,
           let field = document.field(withIdentifier: Self.filterIdentifier) {
            window.makeFirstResponder(field)
            return true
        }
        return false
    }

    private var isEditingFilter: Bool {
        focusedFieldState()?.identifier == Self.filterIdentifier
    }

    static let filterIdentifier = NSUserInterfaceItemIdentifier("keybindings.filter")

    // MARK: - Recording

    /// Starts capturing the next chord for `id` through the keyboard router; key presses stop
    /// reaching commands, menus and fields until it is recorded or cancelled.
    func startRecording(_ id: String) {
        window.makeFirstResponder(document)
        recordingCommandID = id
        recorder = ShortcutRecorder(prefixKey: center.keymap.prefixKey)
        router?.capture = { [weak self] stroke in self?.recorderReceived(stroke) }
        render(resetScroll: false)
    }

    func stopRecording(rerender: Bool) {
        guard recordingCommandID != nil else { return }
        router?.capture = nil
        recordingCommandID = nil
        recorder = nil
        if rerender { render(resetScroll: false) }
    }

    private func recorderReceivedEvent(_ event: NSEvent) {
        guard let stroke = KeyStroke(event: event) else { return }
        recorderReceived(stroke)
    }

    private func recorderReceived(_ stroke: KeyStroke) {
        guard var recorder, let id = recordingCommandID else { return }
        let outcome = recorder.feed(stroke)
        self.recorder = recorder
        switch outcome {
        case .awaitingPrefixKey:
            render(resetScroll: false)
        case .rejected:
            NSSound.beep()
        case .cancelled:
            stopRecording(rerender: true)
        case let .recorded(chord):
            stopRecording(rerender: false)
            write(chord.canonicalString, at: ["keybindings", "bindings", id])
        }
    }

    /// The recording row's prompt.
    var recordingPrompt: String {
        guard let recorder else { return "" }
        return recorder.isAwaitingPrefixKey ? "⌃\(recorder.prefixKey.uppercased()) … now the key" : "Press shortcut"
    }

    func setKeybindingQuery(_ query: String) {
        guard query != keybindingQuery else { return }
        keybindingQuery = query
        scheduleRender()
    }

    /// The main window the screen covers.
    var parentWindow: NSWindow? { parent }
}

// MARK: - Chrome views

/// The page column inside the scroll view: sections stacked with `gap-8`, centered, `py-8`.
final class FlippedStackDocument: NSView {
    private let stack = NSStackView()
    private var widthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 32),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func setSections(_ sections: [NSView], width: CGFloat) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for section in sections { stack.addArrangedSubview(section) }
        widthConstraint?.isActive = false
        widthConstraint = stack.widthAnchor.constraint(equalToConstant: width)
        widthConstraint?.isActive = true
    }

    /// Sizes the document to the clip width and the stack's height.
    func fit(to width: CGFloat) {
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height + 64
        setFrameSize(NSSize(width: width, height: height))
        layoutSubtreeIfNeeded()
    }

    func field(withIdentifier identifier: NSUserInterfaceItemIdentifier) -> NSTextField? {
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier == identifier { return field }
            for subview in view.subviews {
                if let match = search(subview) { return match }
            }
            return nil
        }
        return search(self)
    }
}

/// The left navigation (`w-60 bg-sidebar border-e`): one row per page, the active one filled,
/// and "Open settings.json" at the bottom.
final class SettingsNavView: PaletteView {
    var onSelect: ((SettingsPage) -> Void)?
    var onOpenFile: (() -> Void)?
    private var items: [SettingsPage: SettingsNavItem] = [:]
    private let rule = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(rule)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let heading = ThemedLabel("Settings", size: Typography.bodySize, weight: .semibold) { $0.sidebarForeground }
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)
        for page in SettingsPage.allCases {
            let item = SettingsNavItem(title: page.title, symbol: page.icon)
            item.onClick = { [weak self] in self?.onSelect?(page) }
            items[page] = item
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let file = SettingsNavItem(title: "Open settings.json", symbol: "doc.text")
        file.onClick = { [weak self] in self?.onOpenFile?() }
        file.translatesAutoresizingMaskIntoConstraints = false
        addSubview(file)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            heading.centerYAnchor.constraint(equalTo: topAnchor, constant: Metrics.topbarHeight / 2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topbarHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            file.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            file.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            file.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        applyPalette(palette)
    }

    func update(selected: SettingsPage) {
        for (page, item) in items { item.isActive = page == selected }
    }

    override func layout() {
        super.layout()
        rule.frame = NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.sidebar.cgColor
        rule.backgroundColor = palette.sidebarBorder.cgColor
    }
}

/// `SidebarMenuButton` (h32, `text-sm`, 16 pt icon); active rows are filled and medium weight.
final class SettingsNavItem: InteractiveView {
    private let icon = NSImageView()
    private let label: ThemedLabel
    var isActive = false {
        didSet { applyPalette(palette) }
    }

    init(title: String, symbol: String) {
        label = ThemedLabel(title, size: Typography.bodySize) { $0.sidebarForeground }
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.lg
        icon.image = NSImage.symbol(symbol, size: 14)
        icon.imageScaling = .scaleNone
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        let fill: NSColor = isActive
            ? (palette.isDark ? palette.sidebarRowActive : palette.foreground.withAlphaComponent(0.06))
            : (isHovered ? (palette.isDark ? palette.sidebarRowHover : palette.foreground.withAlphaComponent(0.04)) : .clear)
        layer?.backgroundColor = fill.cgColor
        icon.contentTintColor = isActive ? palette.sidebarForeground : palette.sidebarMutedForeground
        label.font = Typography.ui(Typography.bodySize, weight: isActive ? .medium : .regular)
        label.role = { $0.sidebarForeground }
    }
}

/// The page header: breadcrumb "Settings › Page" and a close button, `border-b`.
final class SettingsHeaderView: PaletteView {
    var onClose: (() -> Void)?
    private let root = ThemedLabel("Settings", size: Typography.bodySize) { $0.mutedForeground }
    private let chevron = NSImageView()
    private let current = ThemedLabel("", size: Typography.bodySize, weight: .medium)
    private let closeButton = GhostIconButton(symbol: "xmark", size: 28, symbolSize: 13, toolTip: "Close settings")
    private let rule = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(rule)
        chevron.image = NSImage.symbol(Icon.chevronRight, size: 11)
        closeButton.onClick = { [weak self] in self?.onClose?() }
        for view in [root, chevron, current, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            root.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: root.trailingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            current.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            current.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyPalette(palette)
    }

    func update(page: SettingsPage) {
        current.stringValue = page.title
    }

    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    override func applyPalette(_ palette: Palette) {
        rule.backgroundColor = palette.border.cgColor
        chevron.contentTintColor = palette.mutedForeground
    }
}
