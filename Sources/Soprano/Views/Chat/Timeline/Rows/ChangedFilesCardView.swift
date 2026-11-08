import AppKit

/// "+12 −3" in the diff colors, mono.
enum TimelineDiffStat {
    static func make(additions: Int, deletions: Int, size: CGFloat, palette: Palette) -> NSAttributedString {
        let font = Typography.mono(size)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "+\(additions)", attributes: [.font: font, .foregroundColor: palette.diffAdditionForeground]))
        result.append(NSAttributedString(string: " −\(deletions)", attributes: [.font: font, .foregroundColor: palette.diffDeletionForeground]))
        return result
    }
}

/// The changed-files card: `rounded-lg bg-secondary`, header "N changed files +A −D" with
/// "Expand/Collapse all folders", then the folder tree with per-file stats. Clicking a file
/// shows its diff in the turn's work log.
final class ChangedFilesCardView: PaletteView {
    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 28
    static let treePadding: CGFloat = 8

    weak var delegate: TimelineRowDelegate?
    private var model: ChangedFilesModel?
    private var nodes: [ChangedFileNode] = []
    private var rows: [ChangedFileTreeRow] = []

    private let titleLabel = NSTextField.timelineLabel("", size: Typography.smallSize, weight: .medium)
    private let statLabel = NSTextField.timelineLabel("", size: Typography.smallSize)
    private let foldersButton = TimelineButton(symbol: TimelineIcon.unfoldAll, toolTip: "Collapse all folders")
    private var rowViews: [ChangedFileRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        for view in [titleLabel, statLabel, foldersButton] as [NSView] { addSubview(view) }
        foldersButton.onClick = { [weak self] in self?.toggleAllFolders() }
        applyPalette(palette)
    }

    func configure(_ model: ChangedFilesModel) {
        if model.files != self.model?.files { nodes = ChangedFileTree.build(model.files) }
        self.model = model
        rows = ChangedFileTree.rows(nodes, collapsed: model.closedFolders)
        let count = model.files.count
        titleLabel.stringValue = "\(count) changed file\(count == 1 ? "" : "s")"
        let hasDirectories = model.files.contains { $0.path.contains("/") }
        foldersButton.isHidden = !hasDirectories
        let allOpen = model.closedFolders.isEmpty
        foldersButton.toolTip = allOpen ? "Collapse all folders" : "Expand all folders"
        foldersButton.setAccessibilityLabel(foldersButton.toolTip)
        while rowViews.count < rows.count {
            let view = ChangedFileRowView(frame: .zero)
            rowViews.append(view)
            addSubview(view)
        }
        let showsSpacer = hasDirectories
        for (index, view) in rowViews.enumerated() {
            view.isHidden = index >= rows.count
            guard index < rows.count else { continue }
            let row = rows[index]
            view.configure(row, closed: model.closedFolders.contains(row.node.path), showsSpacer: showsSpacer || row.depth > 0)
            view.onClick = { [weak self] in self?.activate(row.node) }
        }
        applyPalette(palette)
    }

    func layoutCard(width: CGFloat) -> CGFloat {
        let buttonX = foldersButton.isHidden ? width : width - 12 - 24
        let titleWidth = min(titleLabel.textFitWidth, max(0, buttonX - 12 - 8))
        titleLabel.frame = NSRect(x: 12, y: (Self.headerHeight - 16) / 2, width: titleWidth, height: 16)
        let statWidth = statLabel.textFitWidth
        statLabel.frame = NSRect(x: titleLabel.frame.maxX + 12, y: (Self.headerHeight - 16) / 2, width: statWidth, height: 16)
        // A narrow card drops the total before it would run under the folders button.
        statLabel.isHidden = statLabel.frame.maxX > buttonX - 8
        foldersButton.frame = NSRect(x: width - 12 - 24, y: 8, width: 24, height: 24)
        let treePadding = width < Self.narrowWidth ? 4 : Self.treePadding
        var y = Self.headerHeight + Self.treePadding - 8
        for (index, view) in rowViews.enumerated() where index < rows.count {
            view.frame = NSRect(x: treePadding, y: y, width: width - treePadding * 2, height: Self.rowHeight)
            view.needsLayout = true
            y += Self.rowHeight
        }
        y += Self.treePadding
        frame.size = NSSize(width: width, height: y)
        return y
    }

    /// Cards narrower than this tighten the tree (indent, padding) and drop row totals the
    /// names need the room for.
    static let narrowWidth: CGFloat = 300

    private func activate(_ node: ChangedFileNode) {
        guard let model else { return }
        switch node {
        case let .directory(_, path, _, _, _):
            var closed = model.closedFolders
            if closed.contains(path) { closed.remove(path) } else { closed.insert(path) }
            delegate?.timelineSetClosedFolders(turnID: model.turnID, paths: closed)
        case let .file(_, path, _, _):
            delegate?.timelineRevealDiff(turnID: model.turnID, path: path)
        }
    }

    private func toggleAllFolders() {
        guard let model else { return }
        let closed = model.closedFolders.isEmpty ? ChangedFileTree.directoryPaths(nodes) : []
        delegate?.timelineSetClosedFolders(turnID: model.turnID, paths: closed)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = (palette.isDark ? palette.input.timelineAlpha(0.2) : palette.secondary).cgColor
        titleLabel.textColor = palette.foreground
        if let model {
            statLabel.attributedStringValue = TimelineDiffStat.make(additions: model.additions, deletions: model.deletions, size: Typography.smallSize, palette: palette)
        }
    }
}

/// One folder or file row of the changed-files tree (h-7, rounded, hover `accent/60`).
final class ChangedFileRowView: InteractiveView {
    private let chevron = TimelineIconView(symbol: Icon.chevronRight, size: 10)
    private let icon = TimelineIconView(symbol: TimelineIcon.file, size: 12)
    private let nameLabel = NSTextField.timelineLabel("", size: Typography.smallSize)
    private let statLabel = NSTextField.timelineLabel("", size: 10)
    private var row: ChangedFileTreeRow?
    private var showsSpacer = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.md
        for view in [chevron, icon, nameLabel, statLabel] as [NSView] { addSubview(view) }
        nameLabel.lineBreakMode = .byTruncatingMiddle
        setAccessibilityRole(.button)
    }

    func configure(_ row: ChangedFileTreeRow, closed: Bool, showsSpacer: Bool) {
        self.row = row
        self.showsSpacer = showsSpacer
        if row.node.isDirectory {
            chevron.setSymbol(closed ? Icon.chevronRight : Icon.chevronDown, size: 10, weight: .medium)
            icon.setSymbol(closed ? TimelineIcon.folder : "folder", size: 12)
            nameLabel.font = Typography.mono(Typography.tinySize)
        } else {
            icon.setSymbol(TimelineIcon.file, size: 12)
            nameLabel.font = Typography.mono(Typography.smallSize)
        }
        nameLabel.stringValue = row.node.name
        setAccessibilityLabel(row.node.path)
        toolTip = row.node.path
        needsLayout = true
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        guard let row else { return }
        let narrow = bounds.width < ChangedFilesCardView.narrowWidth - 8
        let iconWidth: CGFloat = 14
        let iconGap: CGFloat = narrow ? 4 : 8
        var x = (narrow ? 4 : 8) + CGFloat(row.depth) * (narrow ? 8 : 14)
        let mid = bounds.height / 2
        if row.node.isDirectory || showsSpacer {
            chevron.isHidden = !row.node.isDirectory
            chevron.frame = NSRect(x: x, y: mid - 7, width: iconWidth, height: 14)
            x += iconWidth + iconGap
        } else {
            chevron.isHidden = true
        }
        icon.frame = NSRect(x: x, y: mid - 7, width: iconWidth, height: 14)
        x += iconWidth + iconGap
        let statWidth = statLabel.textFitWidth
        let trailing = bounds.width - 8
        // The name comes first: a row too narrow for both drops its total (the header and the
        // file's diff row still carry it) rather than cutting the name to a few characters.
        let nameWidth = nameLabel.textFitWidth
        statLabel.isHidden = statWidth > 0 && trailing - statWidth - 8 - x < min(nameWidth, 120)
        let nameEnd = statLabel.isHidden ? trailing : trailing - statWidth - 8
        statLabel.frame = NSRect(x: trailing - statWidth, y: mid - 7, width: statWidth, height: 14)
        nameLabel.frame = NSRect(x: x, y: mid - 8, width: max(0, nameEnd - x), height: 16)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = isHovered ? palette.accent.timelineAlpha(palette.isDark ? 1 : 0.6).cgColor : NSColor.clear.cgColor
        chevron.contentTintColor = palette.mutedForeground.timelineAlpha(0.7)
        icon.contentTintColor = palette.mutedForeground.timelineAlpha(0.75)
        guard let row else { return }
        if row.node.isDirectory {
            nameLabel.textColor = isHovered ? palette.foreground.timelineAlpha(0.9) : palette.mutedForeground.timelineAlpha(0.9)
        } else {
            nameLabel.textColor = isHovered ? palette.foreground : palette.foreground.timelineAlpha(0.85)
        }
        switch row.node {
        case let .directory(_, _, additions, deletions, _), let .file(_, _, additions, deletions):
            statLabel.attributedStringValue = additions == 0 && deletions == 0
                ? NSAttributedString()
                : TimelineDiffStat.make(additions: additions, deletions: deletions, size: 10, palette: palette)
        }
    }
}
