import AppKit

/// A pane agent in the Terminals section (44 pt): status glyph, its task (or its name before it
/// has one) with the status word on the right, and `Codex · window` underneath. Agents that
/// wait for the user get an emphasized status word and glyph; the agent the Terminal Agents
/// board shows gets the selected fill. Clicking opens the board on it.
final class SidebarTerminalCell: InteractiveView {
    private(set) var row: SidebarTerminalRow?
    private let surface = NSView()
    private let statusIcon = NSImageView()
    private let titleLabel = NSTextField.label("", size: Typography.bodySize, weight: .medium)
    private let statusLabel = NSTextField.label("", size: Typography.smallSize, weight: .medium)
    private let metaLabel = NSTextField.label("", size: Typography.smallSize)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.wantsLayer = true
        surface.layer?.cornerRadius = Radius.md
        statusLabel.alignment = .right
        for view in [surface, statusIcon, titleLabel, statusLabel, metaLabel] as [NSView] { addSubview(view) }
        setAccessibilityRole(.button)
    }

    /// The whole row is one button: clicks on its labels count too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    func configure(_ row: SidebarTerminalRow) {
        self.row = row
        statusIcon.image = NSImage.symbol(Self.symbol(row.status), size: 12)
        statusLabel.stringValue = row.status.label
        titleLabel.stringValue = row.title ?? row.name
        metaLabel.stringValue = row.title == nil ? row.windowTitle : "\(row.name) · \(row.windowTitle)"
        setAccessibilityLabel("\(row.name)\(row.title.map { " · \($0)" } ?? ""), \(row.status.label), \(row.windowTitle)")
        setAccessibilitySelected(row.isSelected)
        toolTip = "Open \(row.name) in Terminal Agents"
        applyPalette(palette)
        needsLayout = true
    }

    private static func symbol(_ status: SidebarTerminalStatus) -> String {
        switch status {
        case .needsInput: Icon.messageQuestion
        case .failed: Icon.circleAlert
        case .starting, .working: Icon.circleDashed
        case .ready: Icon.circleCheck
        case .stopped: Icon.circleStop
        }
    }

    private static func tone(_ status: SidebarTerminalStatus) -> ThreadStatusTone {
        switch status {
        case .needsInput: .input
        case .failed: .failed
        case .starting, .working: .working
        case .ready: .done
        case .stopped: .muted
        }
    }

    override func layout() {
        super.layout()
        let inset = SidebarLayout.contentInset
        let rect = NSRect(x: inset, y: 0, width: bounds.width - inset * 2, height: bounds.height - 1)
        surface.frame = rect
        let left = rect.minX + SidebarLayout.rowInset
        let right = rect.maxX - SidebarLayout.rowInset
        let lineOne = rect.minY + 14
        let lineTwo = rect.minY + 31
        statusIcon.frame = NSRect(x: left, y: lineOne - 7, width: 14, height: 14)
        let textLeft = statusIcon.frame.maxX + 8
        let statusSize = statusLabel.intrinsicContentSize
        let statusWidth = ceil(statusSize.width) + 4
        statusLabel.frame = NSRect(x: right + 2 - statusWidth, y: lineOne - statusSize.height / 2, width: statusWidth, height: statusSize.height)
        let titleSize = titleLabel.intrinsicContentSize
        titleLabel.frame = NSRect(x: textLeft - 2, y: lineOne - titleSize.height / 2, width: max(0, statusLabel.frame.minX - 8 - textLeft + 4), height: titleSize.height)
        let metaSize = metaLabel.intrinsicContentSize
        metaLabel.frame = NSRect(x: textLeft - 2, y: lineTwo - metaSize.height / 2, width: max(0, right - textLeft + 4), height: metaSize.height)
    }

    override func applyPalette(_ palette: Palette) {
        guard let row else { return }
        // Selection is the only fill besides hover, as on thread rows; attention shows in the
        // status word and glyph alone.
        let fill: NSColor = row.isSelected ? palette.sidebarRowActive : isHovered ? palette.sidebarRowHover : .clear
        surface.layer?.backgroundColor = fill.cgColor
        surface.layer?.borderWidth = row.isSelected && !palette.isDark ? 1 : 0
        surface.layer?.borderColor = palette.sidebarBorder.alphaScaled(by: 0.7).cgColor
        let tone: ThreadStatusTone = switch (row.needsAttention, row.status) {
        case (true, .failed): .failed
        case (true, _): .input
        case (false, let status): Self.tone(status)
        }
        let toneColor = palette.color(for: tone)
        statusIcon.contentTintColor = toneColor
        statusLabel.textColor = row.needsAttention ? toneColor : palette.secondaryLabel
        statusLabel.font = Typography.ui(Typography.smallSize, weight: row.needsAttention ? .semibold : .medium)
        titleLabel.textColor = row.status == .stopped ? palette.mutedForeground : palette.sidebarForeground
        metaLabel.textColor = palette.mutedForeground
    }
}
