import AppKit
import SopranoAgentsCore

/// The sidebar's project filter (a project scope combobox): a child window under the
/// search row with "Search projects...", "All projects" and one row per project. Click selects
/// one project and closes; Shift-click toggles a project and stays open. Right-click a project
/// for "Remove project".
@MainActor
final class ProjectFilterPopup: NSPanel {
    private let engine: AgentEngine
    private let state: WorkspaceState
    private let content: ProjectFilterContentView
    private var monitor: Any?

    static let width: CGFloat = 288

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        content = ProjectFilterContentView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        super.init(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        contentView = content
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .utilityWindow
        content.onPick = { [weak self] projectID, toggles in self?.pick(projectID, toggles: toggles) }
        content.onRemove = { [weak self] projectID in self?.remove(projectID) }
        content.onClose = { [weak self] in self?.dismiss() }
        content.onQueryChange = { [weak self] in self?.reload() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isShown: Bool { parent != nil && isVisible }

    /// Shows the popup with its top-left under `anchor` (the search row).
    func show(below anchor: NSView) {
        guard let parentWindow = anchor.window else { return }
        content.query = ""
        reload()
        let anchorRect = anchor.convert(anchor.bounds, to: nil)
        let screenRect = parentWindow.convertToScreen(anchorRect)
        let width = min(Self.width, max(anchorRect.width, content.preferredWidth))
        let height = content.preferredHeight
        // The surface sits 4 pt under the anchor; the window adds a shadow margin around it.
        let margin = ProjectFilterContentView.shadowMargin
        let frame = NSRect(x: screenRect.minX - margin, y: screenRect.minY - 4 - height - margin, width: width + margin * 2, height: height + margin * 2)
        setFrame(frame, display: true)
        if parent !== parentWindow {
            parent?.removeChildWindow(self)
            parentWindow.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
        makeKey()
        content.focusSearch()
        installMonitor()
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        // Clicking elsewhere closes it, like a popover.
        if isVisible, NSApp.isActive { dismiss() }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window !== self else { return }
                self.dismiss()
            }
            return event
        }
    }

    private func reload() {
        content.update(projects: engine.projects, filter: state.projectFilter)
        let height = content.preferredHeight
        let margin = ProjectFilterContentView.shadowMargin
        guard isVisible, abs(frame.height - (height + margin * 2)) > 0.5 else { return }
        var resized = frame
        resized.origin.y = frame.maxY - (height + margin * 2)
        resized.size.height = height + margin * 2
        setFrame(resized, display: true)
    }

    private func pick(_ projectID: String?, toggles: Bool) {
        guard let projectID else {
            state.setProjectFilter([])
            dismiss()
            return
        }
        if toggles {
            var filter = state.projectFilter
            if filter.contains(projectID) { filter.remove(projectID) } else { filter.insert(projectID) }
            state.setProjectFilter(filter)
            reload()
        } else {
            state.setProjectFilter([projectID])
            dismiss()
        }
    }

    private func remove(_ projectID: String) {
        var filter = state.projectFilter
        filter.remove(projectID)
        state.setProjectFilter(filter)
        engine.removeProject(projectID)
        // Its new-thread draft has no folder anymore: fall back to the projectless draft.
        if state.draftProjectID == projectID { state.select(.draft(projectID: nil)) }
        reload()
    }
}

/// Glass-free dropdown surface (`rounded-lg`, popover fill, 10 % border, menu shadow).
final class ProjectFilterContentView: PaletteView, NSTextFieldDelegate {
    static let shadowMargin: CGFloat = 24
    private static let rowHeight: CGFloat = 28

    var onPick: ((String?, Bool) -> Void)?
    var onRemove: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onQueryChange: (() -> Void)?

    private let surface = ProjectFilterSurface()
    private let searchIcon = NSImageView()
    private let searchField = NSTextField()
    private let rule = NSView()
    private let emptyLabel = NSTextField.label("No matching projects.", size: Typography.bodySize)
    private var rows: [ProjectFilterRow] = []
    private var highlighted = 0

    var query: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Radius.lg
        surface.layer?.borderWidth = 1
        surface.layer?.shadowOffset = CGSize(width: 0, height: -16)
        surface.layer?.shadowRadius = 20
        addSubview(surface)
        searchIcon.image = NSImage.symbol(Icon.search, size: 13)
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.font = Typography.ui(Typography.bodySize)
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search projects")
        rule.wantsLayer = true
        emptyLabel.alignment = .center
        for view in [searchIcon, searchField, rule, emptyLabel] as [NSView] { surface.addSubview(view) }
        applyPalette(palette)
    }

    /// Widest row (favicon, gap, name, padding), at least room for the search placeholder.
    var preferredWidth: CGFloat {
        let widest = rows.map(\.labelWidth).max() ?? 0
        return max(200, 4 + 8 + 16 + 8 + widest + 8 + 4)
    }

    var preferredHeight: CGFloat {
        let list = rows.isEmpty ? 36 : CGFloat(rows.count) * Self.rowHeight + 8
        return 44 + list
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    func update(projects: [Project], filter: Set<String>) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [(id: String?, title: String)] = [(nil, "All projects")]
        entries += projects.map { (Optional($0.id), $0.title) }
        if !needle.isEmpty {
            entries = entries.filter { $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        rows.forEach { $0.removeFromSuperview() }
        rows = entries.map { entry in
            let row = ProjectFilterRow(projectID: entry.id, title: entry.title, isSelected: entry.id.map(filter.contains) ?? filter.isEmpty)
            row.onPick = { [weak self] id, toggles in self?.onPick?(id, toggles) }
            row.onRemove = { [weak self] id in self?.onRemove?(id) }
            surface.addSubview(row)
            return row
        }
        highlighted = min(highlighted, max(0, rows.count - 1))
        updateHighlight()
        emptyLabel.isHidden = !rows.isEmpty
        needsLayout = true
    }

    private func updateHighlight() {
        for (index, row) in rows.enumerated() { row.isHighlighted = index == highlighted && !query.isEmpty }
    }

    override func layout() {
        super.layout()
        let margin = Self.shadowMargin
        let rect = bounds.insetBy(dx: margin, dy: margin)
        surface.frame = rect
        let width = rect.width
        searchIcon.frame = NSRect(x: 12, y: 10 + 5, width: 16, height: 16)
        let fieldHeight = searchField.intrinsicContentSize.height
        searchField.frame = NSRect(x: 12 + 20, y: 10 + (26 - fieldHeight) / 2, width: width - 44, height: fieldHeight)
        rule.frame = NSRect(x: 12, y: 42, width: width - 24, height: 1)
        var y: CGFloat = 44 + 4
        for row in rows {
            row.frame = NSRect(x: 4, y: y, width: width - 8, height: Self.rowHeight)
            y += Self.rowHeight
        }
        emptyLabel.frame = NSRect(x: 8, y: 52, width: width - 16, height: 20)
    }

    override var isFlipped: Bool { true }

    override func applyPalette(_ palette: Palette) {
        surface.layer?.backgroundColor = palette.popover.cgColor
        surface.layer?.borderColor = palette.foreground.alphaScaled(by: 0.1).cgColor
        surface.layer?.shadowColor = NSColor.black.cgColor
        surface.layer?.shadowOpacity = palette.isDark ? 0.8 : 0.3
        searchIcon.contentTintColor = palette.mutedForeground.alphaScaled(by: 0.55)
        searchField.textColor = palette.foreground
        searchField.placeholderAttributedString = NSAttributedString(string: "Search projects...", attributes: [
            .foregroundColor: palette.placeholder,
            .font: Typography.ui(Typography.bodySize),
        ])
        rule.layer?.backgroundColor = palette.border.alphaScaled(by: 0.7).cgColor
        emptyLabel.textColor = palette.mutedForeground
    }

    func controlTextDidChange(_ obj: Notification) {
        highlighted = 0
        onQueryChange?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        case #selector(NSResponder.moveDown(_:)):
            highlighted = min(highlighted + 1, max(0, rows.count - 1))
            for (index, row) in rows.enumerated() { row.isHighlighted = index == highlighted }
        case #selector(NSResponder.moveUp(_:)):
            highlighted = max(highlighted - 1, 0)
            for (index, row) in rows.enumerated() { row.isHighlighted = index == highlighted }
        case #selector(NSResponder.insertNewline(_:)):
            guard rows.indices.contains(highlighted) else { return true }
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onPick?(rows[highlighted].projectID, shift)
        default:
            return false
        }
        return true
    }
}

/// One row: favicon (folder for "All projects") with the selected check badge, then the name.
final class ProjectFilterRow: InteractiveView {
    let projectID: String?
    private let isSelected: Bool
    private let favicon = ProjectMonogramView()
    private let folderIcon = NSImageView()
    private let badge = NSView()
    private let badgeCheck = NSImageView()
    private let label = NSTextField.label("", size: Typography.bodySize)
    var onPick: ((String?, Bool) -> Void)?
    var onRemove: ((String) -> Void)?

    var isHighlighted = false {
        didSet { applyPalette(palette) }
    }

    init(projectID: String?, title: String, isSelected: Bool) {
        self.projectID = projectID
        self.isSelected = isSelected
        super.init(frame: .zero)
        layer?.cornerRadius = Radius.sm
        label.stringValue = title
        if projectID != nil {
            favicon.projectName = title
            addSubview(favicon)
        } else {
            folderIcon.image = NSImage.symbol("folder", size: 13)
            addSubview(folderIcon)
        }
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.borderWidth = 2
        badgeCheck.image = NSImage.symbol(Icon.check, size: 6, weight: .black)
        badge.addSubview(badgeCheck)
        badge.isHidden = !isSelected
        addSubview(label)
        addSubview(badge)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilitySelected(isSelected)
        applyPalette(palette)
    }

    var labelWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 4 }

    override func layout() {
        super.layout()
        let iconRect = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        favicon.frame = iconRect
        folderIcon.frame = iconRect
        badge.frame = NSRect(x: iconRect.maxX - 8, y: iconRect.maxY - 8, width: 12, height: 12)
        badgeCheck.frame = NSRect(x: 2, y: 2, width: 8, height: 8)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: iconRect.maxX + 8, y: (bounds.height - size.height) / 2, width: bounds.width - iconRect.maxX - 16, height: size.height)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        super.mouseUp(with: event)
        guard inside else { return }
        onPick?(projectID, event.modifierFlags.contains(.shift))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let projectID else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Remove project", symbol: SidebarSymbol.trash) { [weak self] in
            self?.onRemove?(projectID)
        })
        return menu
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (isHovered || isHighlighted ? palette.foreground.alphaScaled(by: 0.09) : .clear).cgColor
        label.textColor = palette.foreground
        folderIcon.contentTintColor = palette.mutedForeground
        badge.layer?.backgroundColor = palette.primary.cgColor
        badge.layer?.borderColor = palette.popover.cgColor
        badgeCheck.contentTintColor = palette.primaryForeground
    }
}

/// Plain container with a top-left origin.
final class ProjectFilterSurface: NSView {
    override var isFlipped: Bool { true }
}
