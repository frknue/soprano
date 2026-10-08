import AppKit

// MARK: - Node

/// One row of the explorer tree. Directory listings load lazily: `children`
/// stays nil until the folder is first expanded.
@MainActor
final class FileExplorerNode {
    /// The inline "new file / new folder" row, which exists only while its
    /// name is being typed.
    enum Placeholder {
        case file
        case folder
    }

    let url: URL
    /// Root-relative, "/"-separated; empty for the root itself.
    let relativePath: String
    let isDirectory: Bool
    let isSymlink: Bool
    let placeholder: Placeholder?
    weak var parent: FileExplorerNode?

    var children: [FileExplorerNode]?
    var isLoading = false
    var reloadRequested = false
    var loadError: String?
    var visibleChildrenCache: [FileExplorerNode]?
    var visibleChildrenGeneration = -1

    init(
        url: URL,
        relativePath: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        placeholder: Placeholder? = nil,
        parent: FileExplorerNode? = nil
    ) {
        self.url = url
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.placeholder = placeholder
        self.parent = parent
    }

    var name: String { url.lastPathComponent }

    func childRelativePath(_ name: String) -> String {
        relativePath.isEmpty ? name : "\(relativePath)/\(name)"
    }

    /// The folder new items go into when this row is the context: the folder
    /// itself, or a file's parent.
    var containingFolder: FileExplorerNode {
        isDirectory || parent == nil ? self : parent ?? self
    }
}

// MARK: - Outline View

/// Commands the outline's keyboard handling and Edit menu route to the explorer.
@MainActor
protocol FileExplorerOutlineCommands: AnyObject {
    func outlineRenameSelection()
    func outlineActivateSelection()
    func outlineTrashSelection()
    func outlineCopyPaths(relative: Bool)
    func outlineCopyFiles()
    func outlineReturnFocus()
    func outlineCollapseOrSelectParent()
    func outlineExpandOrSelectFirstChild()
    var outlineUndoManager: UndoManager { get }
}

/// The explorer tree. Draws its own chevrons inside the cells (so the native
/// disclosure triangle is hidden), indents 16 points per level like Orca, and
/// maps the explorer's keyboard shortcuts onto `commands`.
final class FileExplorerOutlineView: NSOutlineView {
    static let rowHeight: CGFloat = 24
    static let indentation: CGFloat = 16

    weak var commands: FileExplorerOutlineCommands?
    /// Row under the pointer, painted with the hover tint.
    private(set) var hoveredRow = -1 {
        didSet {
            guard hoveredRow != oldValue else { return }
            for row in [oldValue, hoveredRow] where row >= 0 && row < numberOfRows {
                (rowView(atRow: row, makeIfNecessary: false) as? FileExplorerRowView)?
                    .isHovered = row == hoveredRow
            }
        }
    }
    private var hoverArea: NSTrackingArea?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let x = CGFloat(level(forRow: row)) * indentationPerLevel
        frame.size.width = max(0, frame.maxX - x)
        frame.origin.x = x
        return frame
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoveredRow = row(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredRow = -1
    }

    override func reloadData() {
        hoveredRow = -1
        super.reloadData()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let commands else {
            super.keyDown(with: event)
            return
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty: // Return, Enter
            commands.outlineRenameSelection() // Finder-style rename
        case 49 where modifiers.isEmpty: // Space
            commands.outlineActivateSelection()
        case 53: // Escape
            commands.outlineReturnFocus()
        case 51 where modifiers == .command: // ⌘⌫
            commands.outlineTrashSelection()
        case 117 where modifiers.isEmpty: // Forward delete
            commands.outlineTrashSelection()
        case 123 where modifiers.isEmpty: // ←
            commands.outlineCollapseOrSelectParent()
        case 124 where modifiers.isEmpty: // →
            commands.outlineExpandOrSelectFirstChild()
        case 115: // Home
            moveSelection(to: 0, extending: modifiers.contains(.shift))
        case 119: // End
            moveSelection(to: numberOfRows - 1, extending: modifiers.contains(.shift))
        case 116: // Page Up
            moveSelection(by: -pageStep, extending: modifiers.contains(.shift))
        case 121: // Page Down
            moveSelection(by: pageStep, extending: modifiers.contains(.shift))
        default:
            if key == "c", modifiers == [.command, .option] {
                commands.outlineCopyPaths(relative: false)
            } else if key == "c", modifiers == [.command, .option, .shift] {
                commands.outlineCopyPaths(relative: true)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Orca jumps a tenth of the list per page key.
    private var pageStep: Int { max(1, numberOfRows / 10) }

    private func moveSelection(by delta: Int, extending: Bool) {
        let current = selectedRowIndexes.last ?? (delta > 0 ? -1 : numberOfRows)
        moveSelection(to: current + delta, extending: extending)
    }

    private func moveSelection(to row: Int, extending: Bool) {
        guard numberOfRows > 0 else { return }
        let target = min(max(0, row), numberOfRows - 1)
        if extending, let anchor = selectedRowIndexes.first {
            let range = min(anchor, target)...max(anchor, target)
            selectRowIndexes(IndexSet(integersIn: range), byExtendingSelection: false)
        } else {
            selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        }
        scrollRowToVisible(target)
    }

    // MARK: Edit Menu

    @objc func undo(_ sender: Any?) {
        commands?.outlineUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        commands?.outlineUndoManager.redo()
    }

    @objc func copy(_ sender: Any?) {
        commands?.outlineCopyFiles()
    }

    @objc func delete(_ sender: Any?) {
        commands?.outlineTrashSelection()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        let undoManager = commands?.outlineUndoManager
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true
        case #selector(copy(_:)), #selector(delete(_:)):
            return !selectedRowIndexes.isEmpty
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

// MARK: - Row View

/// Square, theme-colored selection, hover and drop-target backgrounds, with
/// the accent rail Soprano marks selected rows with.
final class FileExplorerRowView: NSTableRowView {
    var colors: ThemeColors? {
        didSet { needsDisplay = true }
    }
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let colors else { return }
        if isTargetForDropOperation {
            colors.borderSubtle.setFill()
            bounds.fill()
        } else if isHovered, !isSelected {
            colors.bgOverlay.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let colors else { return }
        (isEmphasized ? colors.bgSelectedStrong : colors.bgSelected).setFill()
        bounds.fill()
        (isEmphasized ? colors.accent : colors.railMuted).setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        guard let colors else { return }
        colors.borderSubtle.setFill()
        bounds.fill()
        colors.accent.setStroke()
        let frame = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = Retro.hairline
        frame.stroke()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

// MARK: - Cell View

/// Chevron, type icon, name, and the git letter or ignored mark on the right.
final class FileExplorerCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file-explorer-cell")

    let chevronView = NSImageView()
    let iconView = NSImageView()
    let spinner = NSProgressIndicator()
    let nameField = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let ignoredView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        textField = nameField

        for imageView in [chevronView, iconView, ignoredView] {
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(imageView)
        }

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        nameField.font = RetroFont.body(11)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.cell?.truncatesLastVisibleLine = true
        nameField.focusRingType = .none
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameField)

        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            chevronView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            iconView.leadingAnchor.constraint(equalTo: chevronView.trailingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(
                lessThanOrEqualTo: statusLabel.leadingAnchor,
                constant: -6
            ),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            ignoredView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ignoredView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ignoredView.widthAnchor.constraint(equalToConstant: 11),
            ignoredView.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(
        node: FileExplorerNode,
        isExpanded: Bool,
        status: GitFileStatus?,
        isIgnored: Bool,
        colors: ThemeColors
    ) {
        let muted = colors.textMuted
        if node.isDirectory, node.placeholder == nil {
            chevronView.image = Self.symbol(isExpanded ? "chevron.down" : "chevron.right", size: 9, weight: .bold)
            chevronView.contentTintColor = muted
        } else {
            chevronView.image = nil
        }

        let iconName: String = if node.isSymlink {
            FileTypeIcon.symlink
        } else if node.isDirectory || node.placeholder == .folder {
            isExpanded ? FileTypeIcon.openFolder : FileTypeIcon.folder
        } else {
            FileTypeIcon.symbolName(forFileNamed: node.name)
        }
        iconView.image = Self.symbol(iconName, size: 11, weight: .regular)
        iconView.contentTintColor = muted
        iconView.isHidden = node.isLoading && node.children == nil
        if iconView.isHidden {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        let nameColor: NSColor = if let status {
            Self.color(for: status, colors: colors)
        } else if isIgnored {
            colors.gray
        } else {
            colors.textPrimary
        }
        var font = RetroFont.body(11)
        if isIgnored, status == nil {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        if node.placeholder == nil, !nameField.isEditable {
            nameField.font = font
            nameField.textColor = nameColor
            nameField.stringValue = node.name
        }
        toolTip = node.placeholder == nil ? node.relativePath : nil

        if let status {
            statusLabel.isHidden = false
            statusLabel.attributedStringValue = RetroText.display(
                status.letter,
                color: nameColor,
                tracking: 0,
                alignment: .right
            )
        } else {
            statusLabel.isHidden = true
            statusLabel.stringValue = ""
        }
        ignoredView.isHidden = !(isIgnored && status == nil)
        if !ignoredView.isHidden {
            ignoredView.image = Self.symbol("circle.slash", size: 9, weight: .regular)
            ignoredView.contentTintColor = colors.gray
        }
    }

    /// Turns the name into an inline text field framed in the accent color.
    func beginEditing(colors: ThemeColors, delegate: NSTextFieldDelegate) {
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBordered = false
        nameField.drawsBackground = true
        nameField.backgroundColor = colors.bgRaised
        nameField.textColor = colors.textPrimary
        nameField.font = RetroFont.body(11)
        nameField.delegate = delegate
        nameField.wantsLayer = true
        nameField.layer?.borderWidth = Retro.hairline
        nameField.layer?.borderColor = colors.accent.cgColor
    }

    func endEditing() {
        nameField.delegate = nil
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.drawsBackground = false
        nameField.layer?.borderWidth = 0
    }

    static func color(for status: GitFileStatus, colors: ThemeColors) -> NSColor {
        switch status {
        case .modified: colors.yellow
        case .added, .untracked: colors.success
        case .deleted: colors.danger
        case .renamed, .copied: colors.cyan
        }
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
}
