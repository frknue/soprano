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
    static let indentation: CGFloat = 12

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

/// Soprano Agents' explorer rows: a rounded `accent/60` fill under the
/// pointer, `accent` for the selection while the tree has the keyboard, and
/// `accent/60` for it otherwise. The theme colors stay for the drop edge.
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

    /// The fills a row draws (Agents' `FilesRowView`).
    enum Fill: Equatable {
        case none
        /// Pointer over the row (or a drop target): `accent/60`.
        case hover
        /// Selected while the tree has the keyboard: `accent`.
        case selected
        /// Selected in an unfocused tree: `accent/60`.
        case selectedUnfocused
    }

    /// The fill this row draws in its current state.
    var pillStyle: Fill {
        if isSelected {
            return isEmphasized ? .selected : .selectedUnfocused
        }
        return isHovered || isTargetForDropOperation ? .hover : .none
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else { return }
        Self.fill(pillStyle, in: bounds)
        if isTargetForDropOperation, let colors {
            Self.strokeDropEdge(in: bounds, colors: colors)
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Self.fill(pillStyle, in: bounds)
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        Self.fill(.hover, in: bounds)
        guard let colors else { return }
        Self.strokeDropEdge(in: bounds, colors: colors)
    }

    /// Agents' `FilesRowView` fills, inset 4 pt from the row's sides.
    private static func fill(_ style: Fill, in bounds: NSRect) {
        let palette = PaletteCenter.shared.palette
        let color: NSColor? = switch style {
        case .selected: palette.accent
        case .selectedUnfocused, .hover: palette.accent.shellScaled(by: 0.6)
        case .none: nil
        }
        guard let color else { return }
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: Radius.md, yRadius: Radius.md).fill()
    }

    /// A drop target reads as an input edge around the hover fill.
    private static func strokeDropEdge(in bounds: NSRect, colors: ThemeColors) {
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 4.5, dy: 0.5),
            xRadius: Radius.md,
            yRadius: Radius.md
        )
        edge.lineWidth = 1
        PaletteCenter.shared.palette.input.setStroke()
        edge.stroke()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

// MARK: - Cell View

/// Chevron, type icon, name, and the bare git letter or ignored mark on the
/// right.
final class FileExplorerCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file-explorer-cell")

    let chevronView = NSImageView()
    let iconView = NSImageView()
    let spinner = NSProgressIndicator()
    let nameField = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let ignoredView = NSImageView()
    /// The 16 pt letter column and the name's stops before the letter or the
    /// ignored mark only hold while those marks show, so clean rows use the
    /// full width.
    private var statusWidth: NSLayoutConstraint!
    private var nameBeforeStatus: NSLayoutConstraint!
    private var nameBeforeIgnored: NSLayoutConstraint!

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

        nameField.font = Self.nameFont
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
            // Content starts 12 pt in (pill inset 4 + row padding 8), clear of
            // the pencil tick.
            chevronView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset),
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
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailingInset),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            ignoredView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset - 2),
            ignoredView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ignoredView.widthAnchor.constraint(equalToConstant: 12),
            ignoredView.heightAnchor.constraint(equalToConstant: 12),
        ])
        statusWidth = statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16)
        nameBeforeStatus = nameField.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -6)
        nameBeforeIgnored = nameField.trailingAnchor.constraint(lessThanOrEqualTo: ignoredView.leadingAnchor, constant: -6)
    }

    /// Leading content inset: the 4 pt fill inset plus 8 pt row padding.
    static let contentInset: CGFloat = 12
    /// Trailing inset: the 4 pt fill inset plus 8 pt row padding.
    static let trailingInset: CGFloat = 12
    /// Names: Agents' 12 pt Files rows.
    static let nameFont = Typography.ui(Typography.smallSize)

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
        let muted = PaletteCenter.shared.palette.mutedForeground
        if node.isDirectory, node.placeholder == nil {
            chevronView.image = Self.symbol(isExpanded ? "chevron.down" : "chevron.right", size: 9, weight: .semibold)
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

        // Ink names; color lives on the bare change letter. Ignored files are
        // gray.
        let palette = PaletteCenter.shared.palette
        let nameColor: NSColor = isIgnored && status == nil ? palette.mutedForeground.shellScaled(by: 0.7) : palette.foreground
        if node.placeholder == nil, !nameField.isEditable {
            nameField.font = Self.nameFont
            nameField.textColor = nameColor
            nameField.stringValue = node.name
        }
        toolTip = node.placeholder == nil ? node.relativePath : nil

        if let status {
            statusLabel.isHidden = false
            statusLabel.attributedStringValue = Self.kindLetter(
                status.letter,
                color: Self.color(for: status, colors: colors)
            )
        } else {
            statusLabel.isHidden = true
            statusLabel.stringValue = ""
        }
        statusWidth.isActive = status != nil
        nameBeforeStatus.isActive = status != nil
        ignoredView.isHidden = !(isIgnored && status == nil)
        nameBeforeIgnored.isActive = !ignoredView.isHidden
        if !ignoredView.isHidden {
            ignoredView.image = Self.symbol("circle.slash", size: 10, weight: .regular)
            ignoredView.contentTintColor = palette.mutedForeground.shellScaled(by: 0.7)
        }
    }

    /// A bare change letter (`.kind`): SF Mono 11 Semibold, centered in 16 pt,
    /// in its change color.
    static func kindLetter(_ letter: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: letter, attributes: [
            .font: Typography.mono(Typography.tinySize, weight: .semibold),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    /// Turns the name into an inline field as Agents edits a name in place:
    /// the background fill clipped to the 6 pt row radius and a `primary/70`
    /// edge (the foreground caret is styled once editing starts).
    func beginEditing(delegate: NSTextFieldDelegate) {
        let palette = PaletteCenter.shared.palette
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBordered = false
        nameField.drawsBackground = true
        nameField.backgroundColor = palette.background
        nameField.textColor = palette.foreground
        nameField.font = Self.nameFont
        nameField.delegate = delegate
        nameField.wantsLayer = true
        nameField.layer?.cornerRadius = Radius.md
        nameField.layer?.masksToBounds = true
        nameField.layer?.borderWidth = 1
        nameField.layer?.borderColor = palette.primary.timelineAlpha(0.7).cgColor
    }

    func endEditing() {
        nameField.delegate = nil
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.drawsBackground = false
        nameField.layer?.borderWidth = 0
        nameField.layer?.cornerRadius = 0
        nameField.layer?.masksToBounds = false
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

// MARK: - Field

/// A text field that reports when it gains or loses the keyboard, so its
/// `SurfaceFieldView` can switch to the focused edge.
final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocusChange?(true)
        }
        return became
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

// MARK: - Empty State

/// Sidebar empty and error states, as Agents' file surface notes them: the
/// first line in muted 12 pt, any further lines fainter.
@MainActor
enum SidebarEmptyState {
    static func text(_ message: String) -> NSAttributedString {
        let palette = PaletteCenter.shared.palette
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let text = NSMutableAttributedString(
            string: String(lines.first ?? ""),
            attributes: [.font: Typography.ui(Typography.smallSize), .foregroundColor: palette.mutedForeground, .paragraphStyle: paragraph]
        )
        if lines.count > 1 {
            text.append(NSAttributedString(
                string: "\n" + lines[1],
                attributes: [.font: Typography.ui(Typography.smallSize), .foregroundColor: palette.mutedForeground.shellScaled(by: 0.7), .paragraphStyle: paragraph]
            ))
        }
        return text
    }
}

// MARK: - Toast

/// The sidebars' failure toast, an Agents popover card: `popover` fill, radius
/// 12, a `border` edge and a soft shadow, the alert symbol and the message in
/// the error color. AppKit resets a backing layer's shadow when the effective
/// appearance changes, so the surface is restyled in `updateLayer`.
final class SidebarToastView: NSView {
    static let shadowOpacity: Float = 0.18

    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()

    var message: String {
        get { messageLabel.stringValue }
        set { applyMessage(newValue) }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isSelectable = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage.symbol(Icon.circleAlert, size: 13)
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 16),
            // Centered on the first 18 pt line.
            icon.centerYAnchor.constraint(equalTo: messageLabel.topAnchor, constant: 9),
            messageLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Re-colors from the palette.
    func apply() {
        icon.contentTintColor = PaletteCenter.shared.palette.errorForeground
        applyMessage(messageLabel.stringValue)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let palette = PaletteCenter.shared.palette
        layer.backgroundColor = palette.popover.cgColor
        layer.cornerRadius = Radius.xl
        layer.borderWidth = 1
        layer.borderColor = palette.border.cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = Self.shadowOpacity
        layer.shadowRadius = 12
        layer.shadowOffset = NSSize(width: 0, height: -4)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func applyMessage(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        messageLabel.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: Typography.ui(Typography.rowSize, weight: .medium),
                .foregroundColor: PaletteCenter.shared.palette.errorForeground,
                .paragraphStyle: paragraph,
            ]
        )
    }
}
