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

/// Folio list rows: a hover pill under the pointer, the selection pill with
/// the pencil tick while the tree has the keyboard, the muted pill otherwise.
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

    /// The pill style this row draws in its current state.
    var pillStyle: ChromeSelectionPill.Style {
        if isSelected {
            return isEmphasized ? .selected : .selectedUnfocused
        }
        return isHovered || isTargetForDropOperation ? .hover : .none
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let colors, !isSelected else { return }
        ChromeSelectionPill.draw(pillStyle, in: bounds, colors: colors)
        if isTargetForDropOperation {
            Self.strokeDropEdge(in: bounds, colors: colors)
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let colors else { return }
        ChromeSelectionPill.draw(pillStyle, in: bounds, colors: colors)
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        guard let colors else { return }
        ChromeSelectionPill.draw(.hover, in: bounds, colors: colors)
        Self.strokeDropEdge(in: bounds, colors: colors)
    }

    /// A drop target reads as a field edge around the hover pill, never accent.
    private static func strokeDropEdge(in bounds: NSRect, colors: ThemeColors) {
        let edge = NSBezierPath(
            roundedRect: bounds.insetBy(dx: Chrome.pillInset + 0.5, dy: 0.5),
            xRadius: Chrome.Radius.control,
            yRadius: Chrome.Radius.control
        )
        edge.lineWidth = Chrome.hairline
        colors.fieldFocusEdge.setStroke()
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

        nameField.font = ChromeFont.label
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
            nameField.trailingAnchor.constraint(
                lessThanOrEqualTo: statusLabel.leadingAnchor,
                constant: -6
            ),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),

            ignoredView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset - 2),
            ignoredView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ignoredView.widthAnchor.constraint(equalToConstant: 12),
            ignoredView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    /// Leading content inset: the 4 pt pill inset plus 8 pt row padding.
    static let contentInset: CGFloat = Chrome.pillInset + Chrome.Space.s8
    /// Trailing inset: the 4 pt pill inset plus 8 pt row padding.
    static let trailingInset: CGFloat = Chrome.pillInset + Chrome.Space.s8

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
        iconView.image = Self.symbol(iconName, size: 12, weight: .regular)
        iconView.contentTintColor = muted
        iconView.isHidden = node.isLoading && node.children == nil
        if iconView.isHidden {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        // Ink names; color lives on the bare change letter. Ignored files are
        // gray.
        let nameColor: NSColor = isIgnored && status == nil ? colors.gray : colors.textPrimary
        if node.placeholder == nil, !nameField.isEditable {
            nameField.font = ChromeFont.label
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
        ignoredView.isHidden = !(isIgnored && status == nil)
        if !ignoredView.isHidden {
            ignoredView.image = Self.symbol("circle.slash", size: 10, weight: .regular)
            ignoredView.contentTintColor = colors.gray
        }
    }

    /// A bare change letter (`.kind`): SF Mono 11 Semibold, centered in 16 pt,
    /// in its change color.
    static func kindLetter(_ letter: String, color: NSColor) -> NSAttributedString {
        ChromeText.attributed(
            letter,
            font: ChromeFont.monospaced(size: 11, weight: .semibold),
            color: color,
            alignment: .center
        )
    }

    /// Turns the name into an inline Folio field: raised fill, a
    /// `fieldFocusEdge` edge and the accent caret (styled once editing starts).
    func beginEditing(colors: ThemeColors, delegate: NSTextFieldDelegate) {
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBordered = false
        nameField.drawsBackground = true
        nameField.backgroundColor = colors.raised
        nameField.textColor = colors.textPrimary
        nameField.font = ChromeFont.label
        nameField.delegate = delegate
        nameField.wantsLayer = true
        nameField.layer?.cornerRadius = Chrome.Radius.cap
        nameField.layer?.borderWidth = Chrome.hairline
        nameField.layer?.borderColor = colors.fieldFocusEdge.cgColor
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

// MARK: - Field

/// A text field that reports when it gains or loses the keyboard, so its
/// `ChromeFieldView` can switch to the focused edge.
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

/// Sidebar empty and error states: the first line in the serif empty-state
/// voice (New York italic 17, muted), any further lines as muted meta.
enum SidebarEmptyState {
    static func text(_ message: String, colors: ThemeColors) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let text = NSMutableAttributedString(
            string: String(lines.first ?? ""),
            attributes: [.font: ChromeFont.empty, .foregroundColor: colors.textMuted, .paragraphStyle: paragraph]
        )
        if lines.count > 1 {
            text.append(NSAttributedString(
                string: "\n" + lines[1],
                attributes: [.font: ChromeFont.meta, .foregroundColor: colors.textMuted, .paragraphStyle: paragraph]
            ))
        }
        return text
    }
}

// MARK: - Toast

/// The sidebars' failure toast (`.toast.is-error`): a raised e2 surface with
/// a 10 pt radius and a `borderSubtle` edge, a danger diamond, and the message
/// as the 13 pt Semibold title in danger.
final class SidebarToastView: NSView {
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let mark = ChromeStatusMark(shape: .diamond, size: Chrome.statusMark)
    private var colors: ThemeColors

    var message: String {
        get { messageLabel.stringValue }
        set { applyMessage(newValue) }
    }

    init(colors: ThemeColors) {
        self.colors = colors
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isSelectable = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            mark.widthAnchor.constraint(equalToConstant: Chrome.statusMark),
            mark.heightAnchor.constraint(equalToConstant: Chrome.statusMark),
            // Centered on the first 18 pt line.
            mark.centerYAnchor.constraint(equalTo: messageLabel.topAnchor, constant: 9),
            messageLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            messageLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        apply(colors: colors)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(colors: ThemeColors) {
        self.colors = colors
        guard let layer else { return }
        ChromeSurface.applyFloating(to: layer, colors: colors, radius: Chrome.Radius.popover, shadow: colors.shadowE2)
        layer.borderColor = colors.borderSubtle.cgColor
        mark.color = colors.danger
        applyMessage(messageLabel.stringValue)
    }

    private func applyMessage(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        messageLabel.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: ChromeFont.sans(size: 13, weight: .semibold),
                .foregroundColor: colors.danger,
                .paragraphStyle: paragraph,
            ]
        )
    }
}
