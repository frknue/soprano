import AppKit
import SopranoAgentsCore

/// Sidebar slice: the 52 pt chat header: breadcrumb project / thread title
/// (title click opens the thread action menu, double-click renames inline, right-click anywhere
/// opens the menu) plus the fixed title-bar toggles (thread details, terminal, right panel).
/// With the sidebar hidden, the breadcrumb clears the traffic lights and a sidebar toggle appears.
@MainActor
final class ChatHeaderView: PaletteView {
    let engine: AgentEngine
    let state: WorkspaceState

    private let sidebarButton = GhostIconButton(symbol: Icon.sidebarLeft, symbolSize: 14, toolTip: "Toggle sidebar (⌘B)")
    private let projectButton = BreadcrumbProjectButton()
    private let separator = NSTextField.label("/", size: Typography.bodySize, weight: .medium)
    private let titleButton = HeaderTitleButton()
    private let detailsButton = GhostIconButton(symbol: Icon.squareMenu, symbolSize: 14, toolTip: "Toggle thread details (⇧⌘B)")
    private let terminalButton = GhostIconButton(symbol: Icon.panelBottom, symbolSize: 14, toolTip: "Toggle terminal drawer (⌘J)")
    private let rightPanelButton = GhostIconButton(symbol: Icon.panelRight, symbolSize: 14, toolTip: "Toggle right panel (⌃⌘B)")
    private var renameField: InlineRenameField?
    private var pendingMenu: DispatchWorkItem?

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Metrics.topbarHeight))
        for view in [sidebarButton, projectButton, separator, titleButton, detailsButton, terminalButton, rightPanelButton] as [NSView] {
            addSubview(view)
        }
        sidebarButton.onClick = { [weak self] in self?.perform("view.toggleSidebar") }
        detailsButton.onClick = { [weak self] in self?.perform("view.toggleThreadDetails") }
        terminalButton.onClick = { [weak self] in self?.perform("view.toggleTerminal") }
        rightPanelButton.onClick = { [weak self] in self?.perform("view.toggleRightPanel") }
        projectButton.onClick = { [weak self] in
            guard let self, let projectID = projectButton.projectID else { return }
            ThreadActions.newDraft(projectID: projectID, state: state)
        }
        titleButton.onSingleClick = { [weak self] in self?.scheduleTitleMenu() }
        titleButton.onDoubleClick = { [weak self] in
            self?.pendingMenu?.cancel()
            self?.beginRename()
        }

        engine.addObserver(self) { [weak self] event in
            guard let self else { return }
            switch event {
            case .projectsChanged, .threadListChanged: refresh()
            case let .threadChanged(threadID) where threadID == state.selectedThreadID: refresh()
            default: break
            }
        }
        state.addObserver(self) { [weak self] change in
            if change == .selection || change == .panels { self?.refresh() }
        }
        applyPalette(palette)
        refresh()
    }

    // MARK: Content

    private var thread: AgentThread? { engine.thread(state.selectedThreadID) }

    private func refresh() {
        let thread = thread
        let projectID = thread?.projectID ?? state.draftProjectID
        let project = engine.project(projectID)
        projectButton.configure(project: project)
        projectButton.isHidden = project == nil
        titleButton.title = thread?.title ?? ""
        titleButton.isHidden = thread == nil
        separator.isHidden = project == nil || thread == nil
        if thread == nil { cancelRename() }

        sidebarButton.isHidden = state.isSidebarVisible
        detailsButton.isOn = state.isThreadDetailsVisible
        terminalButton.isOn = state.isTerminalVisible
        rightPanelButton.isOn = state.isRightPanelVisible
        terminalButton.isEnabled = isEnabled("view.toggleTerminal")
        terminalButton.toolTip = terminalButton.isEnabled ? "Toggle terminal drawer (⌘J)" : "Terminal drawer is unavailable"
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        // Title-bar controls: fixed at the right, 28 pt, gap 4.
        var x = bounds.width - 12
        for button in [rightPanelButton, terminalButton, detailsButton] {
            x -= Metrics.titlebarControlSize
            button.frame = NSRect(x: x, y: (height - Metrics.titlebarControlSize) / 2, width: Metrics.titlebarControlSize, height: Metrics.titlebarControlSize)
            x -= 4
        }
        let limit = detailsButton.frame.minX - 12

        var left: CGFloat = Metrics.gutter
        if !sidebarButton.isHidden {
            sidebarButton.frame = NSRect(x: Metrics.windowControlsInset + 1, y: (height - Metrics.titlebarControlSize) / 2, width: Metrics.titlebarControlSize, height: Metrics.titlebarControlSize)
            left = Metrics.windowControlsInset + Metrics.titlebarControlSize + 12
        }
        if !projectButton.isHidden {
            let width = min(projectButton.fittingWidth, max(0, limit - left))
            projectButton.frame = NSRect(x: left, y: (height - 28) / 2, width: width, height: 28)
            left = projectButton.frame.maxX
        }
        if !separator.isHidden {
            let size = separator.intrinsicContentSize
            separator.frame = NSRect(x: left + 12, y: (height - size.height) / 2, width: ceil(size.width) + 4, height: size.height)
            left = separator.frame.maxX + 12
        }
        if !titleButton.isHidden {
            let width = min(titleButton.fittingWidth, max(0, limit - left))
            titleButton.frame = NSRect(x: left, y: (height - 28) / 2, width: width, height: 28)
        }
        if let renameField {
            let title = titleButton.frame
            renameField.frame = NSRect(x: title.minX - 4, y: (height - 24) / 2, width: max(160, min(limit - title.minX, title.width + 40)), height: 24)
        }
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
        separator.textColor = palette.mutedForeground
    }

    // MARK: Menu and rename

    override func menu(for event: NSEvent) -> NSMenu? {
        threadMenu()
    }

    private func threadMenu() -> NSMenu? {
        guard let thread else { return nil }
        return ThreadActions.menu(for: thread.id, engine: engine, state: state, window: window) { [weak self] in
            self?.beginRename()
        }
    }

    /// A single click opens the menu after the double-click interval, so double-click can rename.
    private func scheduleTitleMenu() {
        pendingMenu?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let menu = self.threadMenu() else { return }
                menu.popUp(positioning: nil, at: NSPoint(x: self.titleButton.frame.minX, y: self.titleButton.frame.maxY + 4), in: self)
            }
        }
        pendingMenu = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    /// Inline rename of the title: Enter or blur commits, Escape cancels.
    func beginRename() {
        guard let thread, renameField == nil else { return }
        let field = InlineRenameField(text: thread.title)
        let threadID = thread.id
        field.onCommit = { [weak self] text in
            self?.cancelRename()
            self?.engine.rename(threadID, title: text)
        }
        field.onCancel = { [weak self] in self?.cancelRename() }
        renameField = field
        titleButton.isHidden = true
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        field.beginEditing()
    }

    private func cancelRename() {
        guard let field = renameField else { return }
        field.onCommit = nil
        field.onCancel = nil
        field.removeFromSuperview()
        renameField = nil
        titleButton.isHidden = thread == nil
        needsLayout = true
    }

    var isRenaming: Bool { renameField != nil }

    // MARK: Commands

    private var windowController: MainWindowController? {
        window?.windowController as? MainWindowController
    }

    private func perform(_ id: String) {
        windowController?.perform(id)
        refresh()
    }

    private func isEnabled(_ id: String) -> Bool {
        guard let controller = windowController, let command = CommandRegistry.shared.command(id) else { return true }
        return command.isEnabled(controller.commandContext())
    }
}

/// Breadcrumb project: favicon + name (`max-w-40`, muted, hover foreground). Click starts a new
/// thread in the project.
final class BreadcrumbProjectButton: InteractiveView {
    private let favicon = ProjectMonogramView()
    private let label = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    private(set) var projectID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(favicon)
        addSubview(label)
        setAccessibilityRole(.button)
        applyPalette(palette)
    }

    func configure(project: Project?) {
        projectID = project?.id
        favicon.projectName = project?.title
        label.stringValue = project?.title ?? ""
        toolTip = project.map { "New thread in \($0.title)" }
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        14 + 6 + min(160, ceil(label.intrinsicContentSize.width) + 4)
    }

    override func layout() {
        super.layout()
        favicon.frame = NSRect(x: 0, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 20, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 20), height: size.height)
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = isHovered ? palette.foreground : palette.mutedForeground
    }
}

/// The thread title (`h2`, 14 medium) with the hover chevron ("Thread actions for {title}").
final class HeaderTitleButton: InteractiveView {
    private let label = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    private let chevron = NSImageView()
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            toolTip = newValue
            setAccessibilityLabel("Thread actions for \(newValue)")
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.image = NSImage.symbol(Icon.chevronDown, size: 10, weight: .semibold)
        addSubview(label)
        addSubview(chevron)
        setAccessibilityRole(.button)
        applyPalette(palette)
    }

    var fittingWidth: CGFloat {
        ceil(label.intrinsicContentSize.width) + 4 + 4 + 14
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        let labelWidth = min(ceil(size.width) + 4, max(0, bounds.width - 18))
        label.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: labelWidth, height: size.height)
        chevron.frame = NSRect(x: label.frame.maxX + 4, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        super.mouseUp(with: event)
        guard inside else { return }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onSingleClick?()
        }
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = palette.foreground
        chevron.contentTintColor = palette.mutedForeground
        chevron.alphaValue = isHovered ? 1 : 0
    }
}
