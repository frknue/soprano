import AppKit
import SopranoAgentsCore

/// Sidebar slice: the 52 pt chat header: breadcrumb project / thread title (/ subagent when one
/// is selected; the thread title then opens the thread)
/// (title click opens the thread action menu, double-click renames inline, right-click anywhere
/// opens the menu), the workspace location (`repo/sub/folder` and branch; click toggles the thread
/// details) plus the fixed title-bar toggles (thread details, terminal, right panel).
/// With the sidebar hidden, the breadcrumb clears the traffic lights and a sidebar toggle appears.
@MainActor
final class ChatHeaderView: PaletteView {
    let engine: AgentEngine
    let state: WorkspaceState

    private let sidebarButton = GhostIconButton(symbol: Icon.sidebarLeft, symbolSize: 14, toolTip: "Toggle sidebar (⌘E)")
    private let projectButton = BreadcrumbProjectButton()
    private let separator = NSTextField.label("/", size: Typography.bodySize, weight: .medium)
    private let titleButton = HeaderTitleButton()
    private let subagentSeparator = NSTextField.label("/", size: Typography.bodySize, weight: .medium)
    /// "Reader · sonic" while a subagent is selected.
    private let subagentLabel = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    private let locationButton = HeaderLocationButton()
    /// What `locationButton` shows was loaded for; a change reloads it.
    private var locationSignature: String?
    private var locationGeneration = 0
    private let detailsButton = GhostIconButton(symbol: Icon.squareMenu, symbolSize: 14, toolTip: "Toggle thread details (⇧⌘B)")
    private let terminalButton = GhostIconButton(symbol: Icon.panelBottom, symbolSize: 14, toolTip: "Toggle terminal drawer (⌘J)")
    private let rightPanelButton = GhostIconButton(symbol: Icon.panelRight, symbolSize: 14, toolTip: "Toggle right panel (⌘L)")
    private var renameField: InlineRenameField?
    private var pendingMenu: DispatchWorkItem?

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Metrics.topbarHeight))
        subagentLabel.lineBreakMode = .byTruncatingTail
        for view in [sidebarButton, projectButton, separator, titleButton, subagentSeparator, subagentLabel, locationButton, detailsButton, terminalButton, rightPanelButton] as [NSView] {
            addSubview(view)
        }
        sidebarButton.onClick = { [weak self] in self?.perform("view.toggleSidebar") }
        detailsButton.onClick = { [weak self] in self?.perform("view.toggleThreadDetails") }
        terminalButton.onClick = { [weak self] in self?.perform("view.toggleTerminal") }
        rightPanelButton.onClick = { [weak self] in self?.perform("view.toggleRightPanel") }
        locationButton.onClick = { [weak self] in self?.perform("view.toggleThreadDetails") }
        projectButton.onClick = { [weak self] in
            guard let self, let projectID = projectButton.projectID else { return }
            ThreadActions.newDraft(projectID: projectID, state: state)
        }
        titleButton.onSingleClick = { [weak self] in
            guard let self else { return }
            if let threadID = state.selectedThreadID, state.selectedSubagentID != nil {
                ThreadActions.open(threadID, engine: engine, state: state)
            } else {
                scheduleTitleMenu()
            }
        }
        titleButton.onDoubleClick = { [weak self] in
            guard let self, state.selectedSubagentID == nil else { return }
            pendingMenu?.cancel()
            beginRename()
        }

        engine.addObserver(self) { [weak self] event in
            guard let self else { return }
            switch event {
            case .projectsChanged, .threadListChanged: refresh()
            case let .threadChanged(threadID) where threadID == state.selectedThreadID: refresh()
            case let .subagentListChanged(threadID) where threadID == state.selectedThreadID: refresh()
            default: break
            }
        }
        state.addObserver(self) { [weak self] change in
            if change == .selection || change == .panels { self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil
        )
        applyPalette(palette)
        refresh()
    }

    // MARK: Content

    private var thread: AgentThread? { engine.thread(state.selectedThreadID) }

    private var subagent: Subagent? { engine.subagent(state.selectedThreadID, state.selectedSubagentID) }

    private func refresh() {
        let thread = thread
        let projectID = thread?.projectID ?? state.draftProjectID
        let project = engine.project(projectID)
        projectButton.configure(project: project)
        projectButton.isHidden = project == nil
        titleButton.title = thread?.title ?? ""
        titleButton.isHidden = thread == nil
        separator.isHidden = project == nil || thread == nil
        let subagent = subagent
        subagentLabel.stringValue = subagent.map { "\($0.name) · \($0.agent)" } ?? ""
        subagentLabel.toolTip = subagent?.assignment
        subagentLabel.isHidden = subagent == nil
        subagentSeparator.isHidden = subagent == nil
        titleButton.toolTip = subagent == nil ? nil : "Open \(thread?.title ?? "thread")"
        if thread == nil { cancelRename() }

        sidebarButton.isHidden = state.isSidebarVisible
        detailsButton.isOn = state.isThreadDetailsVisible
        terminalButton.isOn = state.isTerminalVisible
        rightPanelButton.isOn = state.isRightPanelVisible
        terminalButton.isEnabled = isEnabled("view.toggleTerminal")
        terminalButton.toolTip = terminalButton.isEnabled ? "Toggle terminal drawer (⌘J)" : "Terminal drawer is unavailable"
        needsLayout = true
        refreshLocation()
    }

    // MARK: Location

    /// Reloads the location when the workspace, its folder or branch, or the running state (a
    /// finished turn may have switched branches) changed.
    private func refreshLocation(force: Bool = false) {
        guard let workspace = state.workspace else {
            locationSignature = nil
            locationGeneration += 1
            locationButton.configure(nil)
            needsLayout = true
            return
        }
        let thread = thread
        // Folder existence too: a new worktree's folder appears under the path stored at launch.
        let path = engine.workingDirectory(of: workspace) ?? ""
        let signature = [workspace.key, path, "\(FileManager.default.fileExists(atPath: path))", thread?.branch ?? "", "\(thread?.isRunning == true)"]
            .joined(separator: "\u{0}")
        guard force || signature != locationSignature else { return }
        if locationSignature?.hasPrefix(workspace.key + "\u{0}") != true {
            // Another workspace: don't show the previous one's location while loading.
            locationButton.configure(nil)
            needsLayout = true
        }
        locationSignature = signature
        locationGeneration += 1
        let generation = locationGeneration
        Task { [weak self] in
            guard let self else { return }
            let location = await engine.workspaceLocation(workspace)
            guard generation == locationGeneration else { return }
            locationButton.configure(location)
            needsLayout = true
        }
    }

    @objc private func applicationDidBecomeActive() {
        refreshLocation(force: true)
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

        // Location, right-aligned before the toggles: natural width when the breadcrumb leaves
        // room, else squeezed down to 160 pt (the title truncates first), hidden when the project
        // would be cut or the title (or the rename field) would get less than 160 pt.
        var breadcrumbLimit = limit
        locationButton.isHidden = !locationButton.hasLocation
        if locationButton.hasLocation {
            let gap: CGFloat = 16
            let prefix = (projectButton.isHidden ? 0 : projectButton.fittingWidth)
                + (separator.isHidden ? 0 : ceil(separator.intrinsicContentSize.width) + 28)
            let title: CGFloat = if renameField != nil {
                max(160, titleButton.frame.width + 40)
            } else {
                titleButton.isHidden ? 0 : titleButton.fittingWidth + subagentWidth
            }
            let room = limit - left - prefix - gap
            let natural = locationButton.fittingWidth
            let width = min(natural, max(min(natural, 160), room - title))
            if room - width < min(title, 160) {
                locationButton.isHidden = true
            } else {
                locationButton.frame = NSRect(x: limit - width, y: (height - 28) / 2, width: width, height: 28)
                breadcrumbLimit = locationButton.frame.minX - gap
            }
        }

        if !projectButton.isHidden {
            let width = min(projectButton.fittingWidth, max(0, breadcrumbLimit - left))
            projectButton.frame = NSRect(x: left, y: (height - 28) / 2, width: width, height: 28)
            left = projectButton.frame.maxX
        }
        if !separator.isHidden {
            let size = separator.intrinsicContentSize
            separator.frame = NSRect(x: left + 12, y: (height - size.height) / 2, width: ceil(size.width) + 4, height: size.height)
            left = separator.frame.maxX + 12
        }
        if !titleButton.isHidden {
            // A selected subagent's label keeps its room; the thread title truncates first.
            let room = subagentLabel.isHidden ? breadcrumbLimit - left : max(80, breadcrumbLimit - left - subagentWidth)
            let width = min(titleButton.fittingWidth, max(0, room))
            titleButton.frame = NSRect(x: left, y: (height - 28) / 2, width: width, height: 28)
            left = titleButton.frame.maxX
        }
        if !subagentLabel.isHidden {
            let size = subagentSeparator.intrinsicContentSize
            subagentSeparator.frame = NSRect(x: left + 8, y: (height - size.height) / 2, width: ceil(size.width) + 4, height: size.height)
            left = subagentSeparator.frame.maxX + 8
            let labelSize = subagentLabel.intrinsicContentSize
            subagentLabel.frame = NSRect(x: left, y: (height - labelSize.height) / 2, width: max(0, min(ceil(labelSize.width) + 4, breadcrumbLimit - left)), height: labelSize.height)
        }
        if let renameField {
            let title = titleButton.frame
            renameField.frame = NSRect(x: title.minX - 4, y: (height - 24) / 2, width: max(160, min(breadcrumbLimit - title.minX, title.width + 40)), height: 24)
        }
    }

    /// Width of "/ Reader · sonic" after the title while a subagent is selected.
    private var subagentWidth: CGFloat {
        guard !subagentLabel.isHidden else { return 0 }
        return 8 + ceil(subagentSeparator.intrinsicContentSize.width) + 4 + 8 + ceil(subagentLabel.intrinsicContentSize.width) + 4
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
        separator.textColor = palette.mutedForeground
        subagentSeparator.textColor = palette.mutedForeground
        subagentLabel.textColor = palette.foreground
    }

    // MARK: Menu and rename

    override func menu(for event: NSEvent) -> NSMenu? {
        if let threadID = state.selectedThreadID, let subagentID = state.selectedSubagentID {
            return SubagentActions.menu(threadID: threadID, subagentID: subagentID, engine: engine, state: state, window: window)
        }
        return threadMenu()
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

/// Where the selection works: folder glyph (worktree glyph for worktrees) + `repo/sub/folder`
/// (middle-truncated), then branch glyph + branch (tail-truncated, at most 160 pt). Muted, 12 pt,
/// hover fill like the ghost buttons; the tooltip has the full path.
final class HeaderLocationButton: InteractiveView {
    private let icon = NSImageView()
    private let label = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private static let padding: CGFloat = 8
    private static let maxBranchWidth: CGFloat = 160

    private(set) var hasLocation = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Radius.md
        for view in [icon, label, branchIcon, branchLabel] { addSubview(view) }
        label.lineBreakMode = .byTruncatingMiddle
        branchLabel.lineBreakMode = .byTruncatingTail
        branchIcon.image = NSImage.symbol(Icon.gitBranch, size: 11)
        setAccessibilityRole(.button)
        applyPalette(palette)
    }

    func configure(_ location: WorkspaceLocation?) {
        hasLocation = location != nil
        guard let location else {
            toolTip = nil
            setAccessibilityLabel(nil)
            return
        }
        label.stringValue = location.title
        icon.image = NSImage.symbol(location.kind == .worktree ? "folder.badge.gearshape" : Icon.files, size: 12)
        branchLabel.stringValue = location.branch ?? ""
        branchIcon.isHidden = location.branch == nil
        branchLabel.isHidden = location.branch == nil
        let kind = switch location.kind {
        case .checkout: "Local checkout"
        case .worktree: "Worktree"
        case .scratch: "Scratch folder"
        }
        let path = (location.path as NSString).abbreviatingWithTildeInPath
        toolTip = [kind + (location.branch.map { " on \($0)" } ?? ""), path, "Click to toggle thread details"].joined(separator: "\n")
        setAccessibilityLabel("Workspace: \(location.title)\(location.branch.map { ", branch \($0)" } ?? ""), \(path)")
        needsLayout = true
    }

    /// A label's width with the text field's cell padding.
    private static func width(of field: NSTextField) -> CGFloat {
        ceil(field.intrinsicContentSize.width) + 4
    }

    private var branchWidth: CGFloat {
        branchLabel.isHidden ? 0 : min(Self.maxBranchWidth, Self.width(of: branchLabel))
    }

    var fittingWidth: CGFloat {
        guard hasLocation else { return 0 }
        let branch = branchLabel.isHidden ? 0 : 10 + 12 + 4 + branchWidth
        return Self.padding * 2 + 18 + Self.width(of: label) + branch
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let branch = branchLabel.isHidden ? 0 : 10 + 12 + 4 + branchWidth
        // The path label gives way first, down to 60 pt; then the branch shrinks.
        let labelWidth = max(min(60, Self.width(of: label)), bounds.width - Self.padding * 2 - 18 - branch)
        var x = Self.padding
        icon.frame = NSRect(x: x, y: (height - 14) / 2, width: 14, height: 14)
        x += 18
        let labelSize = label.intrinsicContentSize
        label.frame = NSRect(x: x, y: (height - labelSize.height) / 2, width: labelWidth, height: labelSize.height)
        x += labelWidth + 10
        guard !branchLabel.isHidden else { return }
        branchIcon.frame = NSRect(x: x, y: (height - 12) / 2, width: 12, height: 12)
        x += 16
        let branchSize = branchLabel.intrinsicContentSize
        branchLabel.frame = NSRect(x: x, y: (height - branchSize.height) / 2, width: max(0, bounds.width - Self.padding - x), height: branchSize.height)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered ? palette.accent : .clear).cgColor
        let text = isHovered ? palette.foreground : palette.mutedForeground
        label.textColor = text
        branchLabel.textColor = text
        icon.contentTintColor = palette.mutedForeground
        branchIcon.contentTintColor = palette.mutedForeground
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
