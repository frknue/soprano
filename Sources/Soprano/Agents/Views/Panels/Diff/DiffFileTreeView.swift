import AppKit
import SopranoAgentsCore

/// The diff's file tree (`DiffFileTree.tsx`): a "Files" header with the count, then directories
/// and files indented by depth; clicking a file reveals it in the diff.
final class DiffFileTreeView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onSelectFile: ((Int) -> Void)?
    var palette: Palette = PaletteCenter.shared.palette {
        didSet { applyPalette() }
    }

    var selectedFile: Int? {
        didSet { tableView.reloadData() }
    }

    private var items: [DiffTreeItem] = []
    private var entries: [DiffFileEntry] = []
    private let titleLabel = NSTextField.label("Files", size: Typography.smallSize, weight: .medium)
    private let countLabel = NSTextField.label(size: Typography.smallSize)
    private let edge = NSView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    static let rowHeight: CGFloat = 24

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        edge.wantsLayer = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.rowHeight = Self.rowHeight
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked)
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        countLabel.alignment = .right

        for subview in [edge, titleLabel, countLabel, scrollView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: edge.trailingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Files")
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(items: [DiffTreeItem], entries: [DiffFileEntry], palette: Palette) {
        self.items = items
        self.entries = entries
        self.palette = palette
        countLabel.stringValue = String(entries.count)
        selectedFile = nil
    }

    private func applyPalette() {
        layer?.backgroundColor = palette.background.cgColor
        edge.layer?.backgroundColor = palette.border.fading(0.6).cgColor
        titleLabel.textColor = palette.foreground
        countLabel.textColor = palette.mutedForeground
        tableView.reloadData()
    }

    @objc private func clicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row), case let .file(index) = items[row].kind else { return }
        selectedFile = index
        onSelectFile?(index)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: DiffTreeCell.identifier, owner: self) as? DiffTreeCell) ?? DiffTreeCell()
        let item = items[row]
        var tint = palette.mutedForeground
        var symbol = "folder"
        var isSelected = false
        if case let .file(index) = item.kind {
            isSelected = index == selectedFile
            switch entries[index].file.kind {
            case .added, .untracked:
                symbol = "plus.square"
                tint = palette.diffAdditionForeground
            case .deleted:
                symbol = "minus.square"
                tint = palette.diffDeletionForeground
            case .renamed, .copied:
                symbol = "arrow.right.square"
                tint = palette.infoForeground
            default:
                symbol = "doc"
                tint = palette.infoForeground.mixed(with: palette.mutedForeground, fraction: 0.5)
            }
        }
        cell.configure(name: item.name, depth: item.depth, symbol: symbol, tint: tint,
                       isDirectory: item.kind == .directory, isSelected: isSelected, palette: palette)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// One file-tree row: indentation, glyph, name.
final class DiffTreeCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DiffTreeCell")

    private let icon = NSImageView()
    private let label = NSTextField.label(size: Typography.smallSize)
    private var leading: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        layer?.cornerRadius = Radius.md
        icon.imageScaling = .scaleNone
        label.lineBreakMode = .byTruncatingMiddle
        for subview in [icon, label] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        let leading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        self.leading = leading
        NSLayoutConstraint.activate([
            leading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(name: String, depth: Int, symbol: String, tint: NSColor, isDirectory: Bool, isSelected: Bool, palette: Palette) {
        leading?.constant = 8 + CGFloat(depth) * 12
        icon.image = NSImage.symbol(symbol, size: 11)
        icon.contentTintColor = tint
        label.stringValue = name
        label.textColor = isDirectory ? palette.mutedForeground : palette.foreground
        layer?.backgroundColor = (isSelected ? palette.accent : .clear).cgColor
        toolTip = name
    }
}
