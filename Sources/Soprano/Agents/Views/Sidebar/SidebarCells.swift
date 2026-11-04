import AppKit
import SopranoAgentsCore

/// Row geometry of the sidebar list: cards are
/// `li py-0.5` around a 78 pt surface, slim rows 36 pt, shelf headers 32 pt, all `gap-px`.
enum SidebarLayout {
    /// `--sidebar-content-inset`: list padding left and right.
    static let contentInset: CGFloat = 8
    /// `--sidebar-row-content-inset`: row padding left and right.
    static let rowInset: CGFloat = 10
    static let cardHeight: CGFloat = Metrics.cardRowHeight + 5
    /// Card without a meta line (`h-auto`).
    static let compactCardHeight: CGFloat = 58 + 5
    static let slimHeight: CGFloat = Metrics.slimRowHeight + 1
    static let shelfHeight: CGFloat = 33
    static let showMoreHeight: CGFloat = 37
    static let emptyHeight: CGFloat = 64
    static let emptyWithButtonHeight: CGFloat = 92
    static let subagentHeight: CGFloat = 30
    /// A pane agent: name and task over its window, `gap-px`.
    static let terminalHeight: CGFloat = 45

    static func height(of item: SidebarItem) -> CGFloat {
        switch item {
        case let .card(row): row.hasMetaLine ? cardHeight : compactCardHeight
        case .slim: slimHeight
        case .subagent: subagentHeight
        case .terminalAgent: terminalHeight
        case .shelf, .terminalsShelf: shelfHeight
        case .showMore: showMoreHeight
        case .spacer: 0
        case let .empty(state): state == .noProjects ? emptyWithButtonHeight : emptyHeight
        }
    }
}

extension SidebarThreadRow {
    /// The meta line shows a branch, a diff or the subagent disclosure; without any the card
    /// drops it.
    var hasMetaLine: Bool { branch != nil || diff != nil || subagents != nil }
}

/// Callbacks a thread row raises; the sidebar controller owns the behavior.
@MainActor
struct SidebarRowActions {
    var select: (String) -> Void
    var rename: (String) -> Void
    var setSettled: (String, Bool) -> Void
    var menu: (String) -> NSMenu?
    var commitRename: (String, String) -> Void
    var cancelRename: () -> Void
    var selectSubagent: (_ threadID: String, _ subagentID: String) -> Void
    var subagentMenu: (_ threadID: String, _ subagentID: String) -> NSMenu?
    /// Opens or closes the subagent rows under a card.
    var toggleSubagents: (_ threadID: String) -> Void
}

// MARK: - Thread rows

/// Shared behavior of card and slim rows: surface fill, click / double-click / context menu,
/// jump hint, inline rename.
class SidebarThreadCell: InteractiveView {
    private(set) var row: SidebarThreadRow?
    var actions: SidebarRowActions?
    var now = Date()
    let surface = NSView()
    private let jumpBadge = JumpHintBadge()
    private(set) var renameField: InlineRenameField?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Radius.md
        addSubview(surface)
        jumpBadge.isHidden = true
        setAccessibilityRole(.row)
    }

    /// The jump hint ("⌃3") while ⌃ is held; nil hides it.
    var jumpHint: String? {
        didSet {
            jumpBadge.text = jumpHint ?? ""
            jumpBadge.isHidden = jumpHint == nil
            if jumpHint != nil, jumpBadge.superview == nil { addSubview(jumpBadge) }
            needsLayout = true
        }
    }

    func configure(_ row: SidebarThreadRow, now: Date) {
        self.row = row
        self.now = now
        setAccessibilityLabel(row.title)
        if renameField != nil { endRename() }
        applyPalette(palette)
        needsLayout = true
    }

    /// Updates the time-dependent parts (live duration, relative time) only.
    func refreshTime(_ now: Date) {
        self.now = now
        refreshStatus()
    }

    func refreshStatus() {}

    var surfaceRect: NSRect { bounds }

    override func layout() {
        super.layout()
        surface.frame = surfaceRect
        if !jumpBadge.isHidden {
            let size = jumpBadge.fittingSize
            jumpBadge.frame = NSRect(x: surfaceRect.maxX - 6 - size.width, y: surfaceRect.midY - 10, width: size.width, height: 20)
        }
    }

    override func applyPalette(_ palette: Palette) {
        guard let row else { return }
        let fill: NSColor = row.isSelected ? palette.sidebarRowActive : isHovered ? palette.sidebarRowHover : .clear
        surface.layer?.backgroundColor = fill.cgColor
        // Light mode rings the open row (`light:ring-1 ring-inset ring-sidebar-border/70`).
        surface.layer?.borderWidth = row.isSelected && !palette.isDark ? 1 : 0
        surface.layer?.borderColor = palette.sidebarBorder.alphaScaled(by: 0.7).cgColor
    }

    // MARK: Mouse

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        super.mouseUp(with: event)
        guard inside, let row, renameField == nil else { return }
        if event.clickCount >= 2 {
            actions?.rename(row.threadID)
        } else {
            actions?.select(row.threadID)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row else { return nil }
        return actions?.menu(row.threadID)
    }

    // MARK: Rename

    /// Where the title sits; the rename field covers it.
    var titleFrame: NSRect { .zero }

    func beginRename() {
        guard let row, renameField == nil else { return }
        let field = InlineRenameField(text: row.title)
        field.onCommit = { [weak self] text in
            self?.endRename()
            self?.actions?.commitRename(row.threadID, text)
        }
        field.onCancel = { [weak self] in
            self?.endRename()
            self?.actions?.cancelRename()
        }
        renameField = field
        addSubview(field)
        layoutRenameField()
        field.beginEditing()
    }

    func layoutRenameField() {
        guard let field = renameField else { return }
        let title = titleFrame
        field.frame = NSRect(x: title.minX - 4, y: title.midY - 11, width: max(40, title.width + 8), height: 22)
    }

    private func endRename() {
        renameField?.onCommit = nil
        renameField?.onCancel = nil
        renameField?.removeFromSuperview()
        renameField = nil
    }

    /// For the snapshot harness and tests.
    var isRenaming: Bool { renameField != nil }
}

/// Pinned / status-section card (`h-[4.875rem] px-2.5 py-2`): project line with the status
/// slot, title line, meta line (branch, diff stat, provider mark).
final class SidebarCardCell: SidebarThreadCell {
    private let favicon = ProjectMonogramView()
    private let pinIcon = NSImageView()
    private let projectLabel = NSTextField.label("", size: Typography.smallSize)
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private let timeLabel = NSTextField.label("", size: Typography.smallSize)
    private let settleButton = RowActionButton(symbol: Icon.check, title: "Settle", accessibility: "Settle thread")
    private let moreButton = RowActionButton(symbol: SidebarSymbol.ellipsis, accessibility: "Thread actions")
    private let titleLabel = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    private let worktreeIcon = NSImageView()
    private let branchLabel = NSTextField.middleTruncating(size: Typography.smallSize)
    private let diffLabel = NSTextField.label("", size: Typography.smallSize)
    private let providerIcon = NSImageView()
    private let subagentsButton = SubagentDisclosureButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pinIcon.image = NSImage.symbol(Icon.pin, size: 9)
        worktreeIcon.image = NSImage.symbol(SidebarSymbol.folderGit, size: 11)
        timeLabel.font = Typography.tabular(Typography.smallSize)
        statusLabel.font = Typography.tabular(Typography.smallSize, weight: .medium)
        timeLabel.alignment = .right
        for view in [favicon, pinIcon, projectLabel, statusIcon, statusLabel, timeLabel, settleButton, moreButton, titleLabel, worktreeIcon, branchLabel, diffLabel, providerIcon, subagentsButton] as [NSView] {
            addSubview(view)
        }
        settleButton.onClick = { [weak self] in
            guard let self, let row else { return }
            actions?.setSettled(row.threadID, true)
        }
        moreButton.onClick = { [weak self] in self?.showMoreMenu() }
        subagentsButton.onClick = { [weak self] in
            guard let self, let row else { return }
            actions?.toggleSubagents(row.threadID)
        }
    }

    override var surfaceRect: NSRect {
        NSRect(x: SidebarLayout.contentInset, y: 2, width: bounds.width - SidebarLayout.contentInset * 2, height: bounds.height - 5)
    }

    override func configure(_ row: SidebarThreadRow, now: Date) {
        favicon.projectName = row.projectTitle
        favicon.isHidden = row.projectTitle == nil
        projectLabel.stringValue = row.projectTitle ?? "No project"
        pinIcon.isHidden = !row.isPinned
        titleLabel.stringValue = row.title
        titleLabel.font = Typography.ui(Typography.bodySize, weight: row.recedes ? .regular : .medium)
        branchLabel.stringValue = row.branch ?? ""
        worktreeIcon.isHidden = row.branch == nil || !row.isWorktree
        branchLabel.isHidden = row.branch == nil
        providerIcon.image = ProviderGlyph.image(for: row.provider, size: 14)
        diffLabel.isHidden = row.diff == nil
        subagentsButton.isHidden = row.subagents == nil
        if let summary = row.subagents { subagentsButton.configure(summary) }
        // Search lists settled threads as cards too; Settle would do nothing there (un-settle
        // stays in the More menu).
        settleButton.isHidden = row.isPinned || row.isSettled
        super.configure(row, now: now)
        refreshStatus()
    }

    override func refreshStatus() {
        guard let row else { return }
        let palette = palette
        if let pill = SidebarStatusPill.of(row.status) {
            statusIcon.image = NSImage.symbol(pill.symbol, size: 12.5)
            statusLabel.stringValue = pill.text(now: now)
            statusIcon.contentTintColor = palette.color(for: pill.tone)
            statusLabel.textColor = palette.color(for: pill.tone)
            statusIcon.isHidden = false
            statusLabel.isHidden = false
            timeLabel.isHidden = true
        } else {
            timeLabel.stringValue = DurationText.relative(row.timestamp, now: now)
            statusIcon.isHidden = true
            statusLabel.isHidden = true
            timeLabel.isHidden = false
        }
        updateHoverSlot()
        needsLayout = true
    }

    private func updateHoverSlot() {
        let hovering = isHovered
        settleButton.isHidden = !hovering || (row.map { $0.isPinned || $0.isSettled } ?? true)
        moreButton.isHidden = !hovering
        if hovering {
            statusIcon.isHidden = true
            statusLabel.isHidden = true
            timeLabel.isHidden = true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshStatus()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshStatus()
    }

    override func setHoveredForTesting(_ hovered: Bool) {
        super.setHoveredForTesting(hovered)
        refreshStatus()
    }

    private func showMoreMenu() {
        guard let row, let menu = actions?.menu(row.threadID) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: moreButton.frame.minX, y: moreButton.frame.maxY + 4), in: self)
    }

    override var titleFrame: NSRect { titleLabel.frame }

    override func layout() {
        super.layout()
        let surface = surfaceRect
        let left = surface.minX + SidebarLayout.rowInset
        let right = surface.maxX - SidebarLayout.rowInset
        let line1 = surface.minY + 8
        let line2 = line1 + 24
        let line3 = line2 + 22

        // Line 1: favicon, pin, project name … status slot.
        var x = left
        if !favicon.isHidden {
            favicon.frame = NSRect(x: x, y: line1 + 2, width: 16, height: 16)
            x += 16 + 6
        }
        if !pinIcon.isHidden {
            pinIcon.frame = NSRect(x: x, y: line1 + 4, width: 12, height: 12)
            x += 12 + 6
        }

        var slotLeft = right
        if !moreButton.isHidden {
            let width = moreButton.fittingWidth
            moreButton.frame = NSRect(x: right + 4 - width, y: line1, width: width, height: 20)
            slotLeft = moreButton.frame.minX
        }
        if !settleButton.isHidden {
            let width = settleButton.fittingWidth
            settleButton.frame = NSRect(x: slotLeft - width, y: line1, width: width, height: 20)
            slotLeft = settleButton.frame.minX
        }
        if !statusLabel.isHidden {
            let size = statusLabel.intrinsicContentSize
            let width = ceil(size.width) + 4
            // Labels inset their text 2 pt: shift so the text ends at the row edge.
            statusLabel.frame = NSRect(x: right + 2 - width, y: line1 + (20 - size.height) / 2, width: width, height: size.height)
            statusIcon.frame = NSRect(x: statusLabel.frame.minX + 2 - 4 - 16, y: line1 + 2, width: 16, height: 16)
            slotLeft = statusIcon.frame.minX
        }
        if !timeLabel.isHidden {
            let size = timeLabel.intrinsicContentSize
            let width = max(32, ceil(size.width) + 4)
            timeLabel.frame = NSRect(x: right + 2 - width, y: line1 + (20 - size.height) / 2, width: width, height: size.height)
            slotLeft = timeLabel.frame.minX
        }
        let projectSize = projectLabel.intrinsicContentSize
        projectLabel.frame = NSRect(x: x - 2, y: line1 + (20 - projectSize.height) / 2, width: max(0, slotLeft - 6 - x + 4), height: projectSize.height)

        // Line 2: title (+ provider mark when there is no meta line).
        let hasMeta = row?.hasMetaLine ?? false
        var titleRight = right
        if !hasMeta {
            providerIcon.frame = NSRect(x: right - 14, y: line2 + 3, width: 14, height: 14)
            titleRight = providerIcon.frame.minX - 6
        }
        let titleSize = titleLabel.intrinsicContentSize
        titleLabel.frame = NSRect(x: left - 2, y: line2 + (20 - titleSize.height) / 2, width: max(0, titleRight - left + 4), height: titleSize.height)

        // Line 3: subagent disclosure, worktree + branch … diff stat, provider mark.
        if hasMeta {
            providerIcon.frame = NSRect(x: right - 14, y: line3 + 1, width: 14, height: 14)
            var metaRight = providerIcon.frame.minX - 6
            if !diffLabel.isHidden {
                let size = diffLabel.intrinsicContentSize
                diffLabel.frame = NSRect(x: metaRight - ceil(size.width) - 4, y: line3 + (16 - size.height) / 2, width: ceil(size.width) + 4, height: size.height)
                metaRight = diffLabel.frame.minX - 6
            }
            var metaX = left
            if !subagentsButton.isHidden {
                let width = subagentsButton.fittingWidth
                subagentsButton.frame = NSRect(x: metaX - 4, y: line3 - 2, width: width, height: 20)
                metaX = subagentsButton.frame.maxX + 6
            }
            if !worktreeIcon.isHidden {
                worktreeIcon.frame = NSRect(x: metaX, y: line3 + 1, width: 14, height: 14)
                metaX += 14 + 6
            }
            let branchSize = branchLabel.intrinsicContentSize
            branchLabel.frame = NSRect(x: metaX - 2, y: line3 + (16 - branchSize.height) / 2, width: max(0, metaRight - metaX + 4), height: branchSize.height)
        }
        layoutRenameField()
    }

    override func applyPalette(_ palette: Palette) {
        super.applyPalette(palette)
        guard let row else { return }
        let hovering = isHovered
        projectLabel.textColor = palette.secondaryLabel
        pinIcon.contentTintColor = palette.mutedForeground.alphaScaled(by: 0.65)
        titleLabel.textColor = row.recedes && !hovering ? palette.sidebarForeground.alphaScaled(by: 0.75) : palette.sidebarForeground
        titleLabel.alphaValue = row.isGeneratingTitle ? 0.55 : 1
        timeLabel.textColor = palette.secondaryLabel
        worktreeIcon.contentTintColor = palette.mutedForeground
        branchLabel.textColor = palette.secondaryLabel
        providerIcon.contentTintColor = palette.secondaryLabel
        providerIcon.alphaValue = 0.6
        if let diff = row.diff {
            let font = Typography.mono(Typography.smallSize)
            let text = NSMutableAttributedString(string: "+\(DiffCountText.format(diff.additions))", attributes: [.font: font, .foregroundColor: palette.diffAdditionForeground])
            text.append(NSAttributedString(string: " −\(DiffCountText.format(diff.deletions))", attributes: [.font: font, .foregroundColor: palette.diffDeletionForeground]))
            diffLabel.attributedStringValue = text
        }
        alphaValue = row.recedes && row.status.isWorking && !hovering ? 0.7 : 1
        refreshStatus()
    }
}

/// Settled-shelf row (`h-9 px-2.5 gap-2.5`): faded favicon, title, subagent disclosure, time;
/// hover swaps the time for ↶ "Un-settle thread".
final class SidebarSlimCell: SidebarThreadCell {
    private let favicon = ProjectMonogramView()
    private let titleLabel = NSTextField.label("", size: Typography.bodySize)
    private let pinIcon = NSImageView()
    private let timeLabel = NSTextField.label("", size: Typography.smallSize)
    private let unsettleButton = RowActionButton(symbol: SidebarSymbol.undo2, symbolSize: 12, accessibility: "Un-settle thread")
    private let settleButton = RowActionButton(symbol: Icon.check, symbolSize: 11, accessibility: "Settle thread")
    private let subagentsButton = SubagentDisclosureButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pinIcon.image = NSImage.symbol(Icon.pin, size: 9)
        timeLabel.font = Typography.tabular(Typography.smallSize)
        timeLabel.alignment = .right
        for view in [favicon, titleLabel, pinIcon, timeLabel, unsettleButton, settleButton, subagentsButton] as [NSView] {
            addSubview(view)
        }
        unsettleButton.onClick = { [weak self] in
            guard let self, let row else { return }
            actions?.setSettled(row.threadID, false)
        }
        settleButton.onClick = { [weak self] in
            guard let self, let row else { return }
            actions?.setSettled(row.threadID, true)
        }
        subagentsButton.onClick = { [weak self] in
            guard let self, let row else { return }
            actions?.toggleSubagents(row.threadID)
        }
    }

    override var surfaceRect: NSRect {
        NSRect(x: SidebarLayout.contentInset, y: 0, width: bounds.width - SidebarLayout.contentInset * 2, height: bounds.height - 1)
    }

    override func configure(_ row: SidebarThreadRow, now: Date) {
        favicon.projectName = row.projectTitle
        favicon.isHidden = row.projectTitle == nil
        titleLabel.stringValue = row.title
        titleLabel.font = Typography.ui(Typography.bodySize, weight: row.recedes ? .regular : .medium)
        pinIcon.isHidden = !row.isPinned
        subagentsButton.isHidden = row.subagents == nil
        if let summary = row.subagents { subagentsButton.configure(summary) }
        super.configure(row, now: now)
    }

    override func refreshStatus() {
        guard let row else { return }
        timeLabel.stringValue = DurationText.relative(row.timestamp, now: now)
        timeLabel.isHidden = isHovered
        unsettleButton.isHidden = !isHovered || !row.isSettled
        settleButton.isHidden = !isHovered || row.isSettled
        needsLayout = true
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshStatus()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshStatus()
    }

    override func setHoveredForTesting(_ hovered: Bool) {
        super.setHoveredForTesting(hovered)
        refreshStatus()
    }

    override var titleFrame: NSRect { titleLabel.frame }

    override func layout() {
        super.layout()
        let surface = surfaceRect
        let left = surface.minX + SidebarLayout.rowInset
        let right = surface.maxX - SidebarLayout.rowInset
        favicon.frame = NSRect(x: left, y: surface.midY - 8, width: 16, height: 16)
        var slotLeft = right - 32
        for button in [unsettleButton, settleButton] where !button.isHidden {
            let width = button.fittingWidth
            button.frame = NSRect(x: right + 4 - width, y: surface.midY - 12, width: width, height: 24)
        }
        if !timeLabel.isHidden {
            let size = timeLabel.intrinsicContentSize
            let width = max(32, ceil(size.width) + 4)
            timeLabel.frame = NSRect(x: right + 2 - width, y: surface.midY - size.height / 2, width: width, height: size.height)
            slotLeft = timeLabel.frame.minX
        }
        var titleRight = slotLeft - 10
        if !subagentsButton.isHidden {
            let width = subagentsButton.fittingWidth
            subagentsButton.frame = NSRect(x: titleRight + 4 - width, y: surface.midY - 10, width: width, height: 20)
            titleRight = subagentsButton.frame.minX - 6
        }
        if !pinIcon.isHidden {
            pinIcon.frame = NSRect(x: titleRight - 12, y: surface.midY - 6, width: 12, height: 12)
            titleRight = pinIcon.frame.minX - 10
        }
        let titleLeft = left + 16 + 10
        let titleSize = titleLabel.intrinsicContentSize
        titleLabel.frame = NSRect(x: titleLeft - 2, y: surface.midY - titleSize.height / 2, width: max(0, titleRight - titleLeft + 4), height: titleSize.height)
        layoutRenameField()
    }

    override func applyPalette(_ palette: Palette) {
        super.applyPalette(palette)
        guard let row else { return }
        let lit = isHovered || row.isSelected
        favicon.alphaValue = lit ? 1 : 0.4
        let titleColor: NSColor
        if lit || row.status == .input {
            titleColor = palette.sidebarForeground
        } else if row.recedes {
            titleColor = palette.secondaryLabel
        } else if row.status == .done || row.status == .failed {
            titleColor = palette.mutedForeground
        } else {
            titleColor = palette.secondaryLabel.alphaScaled(by: 0.7)
        }
        titleLabel.textColor = titleColor
        titleLabel.alphaValue = row.isGeneratingTitle ? 0.55 : 1
        pinIcon.contentTintColor = palette.mutedForeground.alphaScaled(by: 0.65)
        timeLabel.textColor = palette.secondaryLabel
        refreshStatus()
    }
}

// MARK: - Subagents

/// The card's subagent disclosure on the meta line: "⌄ ⚙ 2" (chevron points right while
/// closed), tinted while one runs.
final class SubagentDisclosureButton: InteractiveView {
    private let chevron = NSImageView()
    private let icon = NSImageView()
    private let label = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private var summary: SidebarThreadRow.SubagentSummary?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Radius.sm
        label.font = Typography.tabular(Typography.smallSize, weight: .medium)
        icon.image = NSImage.symbol(Icon.subagent, size: 10.5)
        for view in [chevron, icon, label] as [NSView] { addSubview(view) }
        setAccessibilityRole(.button)
    }

    func configure(_ summary: SidebarThreadRow.SubagentSummary) {
        self.summary = summary
        chevron.image = NSImage.symbol(summary.expanded ? Icon.chevronDown : Icon.chevronRight, size: 8, weight: .semibold)
        label.stringValue = summary.running > 0 ? "\(summary.running)/\(summary.count)" : "\(summary.count)"
        let noun = summary.count == 1 ? "subagent" : "subagents"
        let text = summary.running > 0 ? "\(summary.count) \(noun), \(summary.running) running" : "\(summary.count) \(noun)"
        toolTip = "\(text) (\(summary.expanded ? "hide" : "show"))"
        setAccessibilityLabel(text)
        setAccessibilityExpanded(summary.expanded)
        applyPalette(palette)
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        4 + 10 + 3 + 14 + 3 + ceil(label.intrinsicContentSize.width) + 4
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        chevron.frame = NSRect(x: 4, y: midY - 5, width: 10, height: 10)
        icon.frame = NSRect(x: chevron.frame.maxX + 3, y: midY - 7, width: 14, height: 14)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: icon.frame.maxX + 1, y: midY - size.height / 2, width: ceil(size.width) + 4, height: size.height)
    }

    override func applyPalette(_ palette: Palette) {
        let running = (summary?.running ?? 0) > 0
        let tint = running ? palette.color(for: .working) : isHovered ? palette.sidebarForeground : palette.secondaryLabel
        chevron.contentTintColor = isHovered ? palette.sidebarForeground : palette.mutedForeground
        icon.contentTintColor = tint
        label.textColor = tint
        layer?.backgroundColor = (isHovered ? palette.sidebarRowHover : .clear).cgColor
    }
}

/// A subagent under its thread's card (30 pt): tree line, status glyph, name, agent, and what it
/// is doing (or was asked); running ones count their run's time on the right.
final class SidebarSubagentCell: InteractiveView {
    private(set) var row: SidebarSubagentRow?
    var actions: SidebarRowActions?
    private var now = Date()
    private let surface = NSView()
    private let guide = NSView()
    private let statusIcon = NSImageView()
    private let nameLabel = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private let detailLabel = NSTextField.label("", size: Typography.smallSize)
    private let timeLabel = NSTextField.label("", size: Typography.smallSize)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Radius.md
        guide.wantsLayer = true
        detailLabel.lineBreakMode = .byTruncatingTail
        nameLabel.lineBreakMode = .byTruncatingTail
        timeLabel.font = Typography.tabular(Typography.smallSize)
        timeLabel.alignment = .right
        for view in [surface, guide, statusIcon, nameLabel, detailLabel, timeLabel] as [NSView] { addSubview(view) }
        setAccessibilityRole(.row)
    }

    func configure(_ row: SidebarSubagentRow, now: Date) {
        self.row = row
        self.now = now
        nameLabel.stringValue = row.name
        detailLabel.stringValue = [row.agent, row.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        statusIcon.image = NSImage.symbol(Self.symbol(row.status), size: 11)
        setAccessibilityLabel("Subagent \(row.name), \(row.status.rawValue)")
        toolTip = row.detail
        refreshTime(now)
        applyPalette(palette)
    }

    func refreshTime(_ now: Date) {
        self.now = now
        guard let row else { return }
        timeLabel.isHidden = row.status != .running
        timeLabel.stringValue = DurationText.compact(now.timeIntervalSince(row.since))
        needsLayout = true
    }

    private static func symbol(_ status: SubagentStatus) -> String {
        switch status {
        case .running: Icon.circleDashed
        case .completed: Icon.circleCheck
        case .failed: Icon.circleAlert
        case .aborted: Icon.circleStop
        }
    }

    override func layout() {
        super.layout()
        let inset = SidebarLayout.contentInset
        // Indented under the card's favicon column.
        let rect = NSRect(x: inset + 18, y: 1, width: bounds.width - inset * 2 - 18, height: bounds.height - 2)
        surface.frame = rect
        let guideX = inset + SidebarLayout.rowInset + 7
        guide.frame = NSRect(x: guideX, y: 0, width: 1, height: row?.isLast == true ? bounds.midY : bounds.height)
        let left = rect.minX + 8
        let right = rect.maxX - 8
        statusIcon.frame = NSRect(x: left, y: rect.midY - 7, width: 14, height: 14)
        var textRight = right
        if !timeLabel.isHidden {
            let size = timeLabel.intrinsicContentSize
            let width = max(24, ceil(size.width) + 4)
            timeLabel.frame = NSRect(x: right + 2 - width, y: rect.midY - size.height / 2, width: width, height: size.height)
            textRight = timeLabel.frame.minX - 6
        }
        let nameX = statusIcon.frame.maxX + 6
        let nameSize = nameLabel.intrinsicContentSize
        let nameWidth = min(ceil(nameSize.width) + 4, max(0, textRight - nameX + 2))
        nameLabel.frame = NSRect(x: nameX - 2, y: rect.midY - nameSize.height / 2, width: nameWidth, height: nameSize.height)
        let detailX = nameLabel.frame.maxX + 4
        let detailSize = detailLabel.intrinsicContentSize
        detailLabel.frame = NSRect(x: detailX, y: rect.midY - detailSize.height / 2, width: max(0, textRight - detailX + 2), height: detailSize.height)
    }

    override func applyPalette(_ palette: Palette) {
        guard let row else { return }
        let fill: NSColor = row.isSelected ? palette.sidebarRowActive : isHovered ? palette.sidebarRowHover : .clear
        surface.layer?.backgroundColor = fill.cgColor
        surface.layer?.borderWidth = row.isSelected && !palette.isDark ? 1 : 0
        surface.layer?.borderColor = palette.sidebarBorder.alphaScaled(by: 0.7).cgColor
        guide.layer?.backgroundColor = palette.sidebarBorder.cgColor
        let lit = row.isSelected || isHovered
        statusIcon.contentTintColor = switch row.status {
        case .running: palette.color(for: .working)
        case .completed: palette.color(for: .done)
        case .failed: palette.color(for: .failed)
        case .aborted: palette.mutedForeground
        }
        nameLabel.textColor = lit || row.status == .running ? palette.sidebarForeground : palette.sidebarForeground.alphaScaled(by: 0.8)
        detailLabel.textColor = palette.secondaryLabel
        timeLabel.textColor = palette.color(for: .working)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        super.mouseUp(with: event)
        guard inside, let row else { return }
        actions?.selectSubagent(row.threadID, row.subagentID)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let row else { return nil }
        return actions?.subagentMenu(row.threadID, row.subagentID)
    }
}

// MARK: - Shelf header, show more, empty state, spacer

/// `CollapsibleSectionHeader` of a shelf: "Working  2 ⌄" (chevron points right while closed).
/// Thread sections and the Terminals section share it.
final class SidebarShelfCell: InteractiveView {
    private let titleLabel = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private let countLabel = NSTextField.label("", size: Typography.smallSize)
    private let chevron = NSImageView()
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        countLabel.font = Typography.tabular(Typography.smallSize)
        for view in [titleLabel, countLabel, chevron] as [NSView] { addSubview(view) }
        setAccessibilityRole(.button)
        onClick = { [weak self] in self?.onToggle?() }
        applyPalette(palette)
    }

    func configure(title: String, count: Int, expanded: Bool) {
        titleLabel.stringValue = title
        countLabel.stringValue = "\(count)"
        chevron.image = NSImage.symbol(expanded ? Icon.chevronDown : Icon.chevronRight, size: 9, weight: .semibold)
        setAccessibilityLabel("\(title) \(count)")
        setAccessibilityExpanded(expanded)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let left = SidebarLayout.contentInset + 2 + 8
        let right = bounds.width - SidebarLayout.contentInset - 2 - 8
        let height: CGFloat = 32
        let titleSize = titleLabel.intrinsicContentSize
        titleLabel.frame = NSRect(x: left - 2, y: (height - titleSize.height) / 2, width: ceil(titleSize.width) + 4, height: titleSize.height)
        chevron.frame = NSRect(x: right - 12, y: (height - 12) / 2, width: 12, height: 12)
        let countSize = countLabel.intrinsicContentSize
        countLabel.frame = NSRect(x: chevron.frame.minX - 8 - ceil(countSize.width) - 4, y: (height - countSize.height) / 2, width: ceil(countSize.width) + 4, height: countSize.height)
    }

    override func applyPalette(_ palette: Palette) {
        let color = isHovered ? palette.sidebarForeground.alphaScaled(by: 0.8) : palette.sidebarMutedForeground
        titleLabel.textColor = color
        countLabel.textColor = color
        chevron.contentTintColor = color
    }
}

/// "Show 25 more" under the Settled shelf (`h-9 px-2.5 gap-2.5 text-sm`).
final class SidebarShowMoreCell: InteractiveView {
    private let icon = NSImageView()
    private let label = NSTextField.label("", size: Typography.bodySize)
    private let surface = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Radius.md
        icon.image = NSImage.symbol(Icon.chevronDown, size: 11)
        for view in [surface, icon, label] { addSubview(view) }
        setAccessibilityRole(.button)
        applyPalette(palette)
    }

    func configure(count: Int) {
        label.stringValue = "Show \(count) more"
        setAccessibilityLabel(label.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rect = NSRect(x: SidebarLayout.contentInset, y: 0, width: bounds.width - SidebarLayout.contentInset * 2, height: 36)
        surface.frame = rect
        icon.frame = NSRect(x: rect.minX + SidebarLayout.rowInset, y: rect.midY - 8, width: 16, height: 16)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: icon.frame.maxX + 10, y: rect.midY - size.height / 2, width: max(0, rect.maxX - icon.frame.maxX - 20), height: size.height)
    }

    override func applyPalette(_ palette: Palette) {
        surface.layer?.backgroundColor = (isHovered ? palette.sidebarRowHover : .clear).cgColor
        let color = isHovered ? palette.sidebarForeground : palette.sidebarMutedForeground
        label.textColor = color
        icon.contentTintColor = color
    }
}

/// "No projects yet" + "Add project", "No threads yet", "No threads found"
/// (`text-xs text-muted-foreground/60 py-6`, centered).
final class SidebarEmptyCell: PaletteView {
    private let label = NSTextField.label("", size: Typography.smallSize)
    let addProjectButton = AddProjectPill()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.alignment = .center
        addSubview(label)
        addSubview(addProjectButton)
        applyPalette(palette)
    }

    func configure(_ state: ThreadSidebarEmptyState) {
        label.stringValue = state.message
        addProjectButton.isHidden = state != .noProjects
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 8, y: 24, width: bounds.width - 16, height: size.height)
        if !addProjectButton.isHidden {
            let buttonSize = addProjectButton.fittingSize
            addProjectButton.frame = NSRect(x: (bounds.width - buttonSize.width) / 2, y: label.frame.maxY + 8, width: buttonSize.width, height: buttonSize.height)
        }
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = palette.mutedForeground.alphaScaled(by: 0.6)
    }
}

/// The small outline "＋ Add project" button of the empty sidebar.
final class AddProjectPill: InteractiveView {
    private let icon = NSImageView()
    private let label = NSTextField.label("Add project", size: Typography.tinySize, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.md
        layer?.borderWidth = 1
        icon.image = NSImage.symbol(SidebarSymbol.plus, size: 9, weight: .semibold)
        addSubview(icon)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add project")
        applyPalette(palette)
    }

    override var fittingSize: NSSize {
        let labelWidth: CGFloat = ceil(label.intrinsicContentSize.width) + 4
        return NSSize(width: 8 + 12 + 4 + labelWidth + 8, height: 24)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 12) / 2, width: 12, height: 12)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: icon.frame.maxX + 4, y: (bounds.height - size.height) / 2, width: ceil(size.width) + 4, height: size.height)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.borderColor = palette.sidebarBorder.cgColor
        layer?.backgroundColor = (isHovered ? palette.sidebarRowHover : .clear).cgColor
        let color = isHovered ? palette.sidebarForeground : palette.sidebarMutedForeground
        label.textColor = color
        icon.contentTintColor = color
    }
}

/// `JumpHintBadge`: "⌘3" pill at the row's right edge while ⌘ is held.
final class JumpHintBadge: PaletteView {
    private let label = NSTextField.label("", size: 10)

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Typography.mono(10, weight: .medium)
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.08
        layer?.shadowRadius = 1
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(label)
        applyPalette(palette)
    }

    override var fittingSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 4 + 12, height: 20)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 6, y: (bounds.height - size.height) / 2, width: ceil(size.width) + 4, height: size.height)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.alphaScaled(by: 0.95).cgColor
        layer?.borderColor = palette.border.alphaScaled(by: 0.8).cgColor
        label.textColor = palette.foreground
    }
}
