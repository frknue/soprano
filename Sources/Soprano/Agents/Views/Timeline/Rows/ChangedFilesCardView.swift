import AppKit
import SopranoAgentsCore

/// "+12 −3" in the diff colors, mono (T3 Code's `DiffStatLabel`).
enum TimelineDiffStat {
    static func make(additions: Int, deletions: Int, size: CGFloat, palette: Palette) -> NSAttributedString {
        let font = Typography.mono(size)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "+\(additions)", attributes: [.font: font, .foregroundColor: palette.diffAdditionForeground]))
        result.append(NSAttributedString(string: " −\(deletions)", attributes: [.font: font, .foregroundColor: palette.diffDeletionForeground]))
        return result
    }
}

/// T3 Code's changed-files card (`ChangedFilesTree.tsx`): `rounded-lg bg-secondary`, header
/// "N changed files +A −D" with "Expand/Collapse all folders" and "Open diff", then the folder tree
/// with per-file stats. Clicking a file opens the turn diff at that file.
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
    private let openDiffButton = TimelineButton("Open diff", symbol: Icon.fileDiff, toolTip: "Open the full diff")
    private var rowViews: [ChangedFileRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        for view in [titleLabel, statLabel, foldersButton, openDiffButton] as [NSView] { addSubview(view) }
        foldersButton.onClick = { [weak self] in self?.toggleAllFolders() }
        openDiffButton.onClick = { [weak self] in
            guard let self, let model else { return }
            delegate?.timelineOpenDiff(turnOrdinal: model.turnOrdinal, path: nil)
        }
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

    static func height(for model: ChangedFilesModel) -> CGFloat {
        let rows = ChangedFileTree.rows(ChangedFileTree.build(model.files), collapsed: model.closedFolders)
        return headerHeight + treePadding * 2 - 8 + CGFloat(rows.count) * rowHeight
    }

    func layoutCard(width: CGFloat) -> CGFloat {
        let titleWidth = titleLabel.textFitWidth
        titleLabel.frame = NSRect(x: 12, y: (Self.headerHeight - 16) / 2, width: titleWidth, height: 16)
        let statWidth = statLabel.textFitWidth
        statLabel.frame = NSRect(x: titleLabel.frame.maxX + 12, y: (Self.headerHeight - 16) / 2, width: statWidth, height: 16)
        // "Open diff" shows its label when the card is at least 24rem wide.
        openDiffButton.title = width >= 384 ? "Open diff" : ""
        let openWidth = openDiffButton.fittingWidth
        openDiffButton.frame = NSRect(x: width - 12 - openWidth, y: 8, width: openWidth, height: 24)
        foldersButton.frame = NSRect(x: openDiffButton.frame.minX - 4 - 24, y: 8, width: 24, height: 24)
        var y = Self.headerHeight + Self.treePadding - 8
        for (index, view) in rowViews.enumerated() where index < rows.count {
            view.frame = NSRect(x: Self.treePadding, y: y, width: width - Self.treePadding * 2, height: Self.rowHeight)
            view.needsLayout = true
            y += Self.rowHeight
        }
        y += Self.treePadding
        frame.size = NSSize(width: width, height: y)
        return y
    }

    private func activate(_ node: ChangedFileNode) {
        guard let model else { return }
        switch node {
        case let .directory(_, path, _, _, _):
            var closed = model.closedFolders
            if closed.contains(path) { closed.remove(path) } else { closed.insert(path) }
            delegate?.timelineSetClosedFolders(turnID: model.turnID, paths: closed)
        case let .file(_, path, _, _):
            delegate?.timelineOpenDiff(turnOrdinal: model.turnOrdinal, path: path)
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
        var x = 8 + CGFloat(row.depth) * 14
        let mid = bounds.height / 2
        if row.node.isDirectory || showsSpacer {
            chevron.isHidden = !row.node.isDirectory
            chevron.frame = NSRect(x: x, y: mid - 7, width: 14, height: 14)
            x += 14 + 8
        } else {
            chevron.isHidden = true
        }
        icon.frame = NSRect(x: x, y: mid - 7, width: 14, height: 14)
        x += 14 + 8
        let statWidth = statLabel.textFitWidth
        statLabel.frame = NSRect(x: bounds.width - 8 - statWidth, y: mid - 7, width: statWidth, height: 14)
        nameLabel.frame = NSRect(x: x, y: mid - 8, width: max(0, statLabel.frame.minX - 8 - x), height: 16)
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
