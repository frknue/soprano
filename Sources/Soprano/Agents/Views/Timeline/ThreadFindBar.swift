import AppKit

/// T3 Code's `ThreadFindBar`: a floating search field at the top right of the chat ("Find in
/// thread"), the match count, Previous match / Next match / Close find. Enter = next,
/// Shift+Enter = previous, Esc closes.
final class ThreadFindBar: PaletteView, NSTextFieldDelegate {
    static let height: CGFloat = 36
    static let width: CGFloat = Metrics.threadDetailsWidth

    let field = NSTextField()
    private let countLabel = NSTextField.timelineLabel("", size: Typography.smallSize)
    private let previousButton = TimelineButton(symbol: TimelineIcon.chevronUp, variant: .ghost, toolTip: "Previous match")
    private let nextButton = TimelineButton(symbol: Icon.chevronDown, variant: .ghost, toolTip: "Next match")
    private let closeButton = TimelineButton(symbol: TimelineIcon.close, variant: .ghost, toolTip: "Close find")

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private var noResults = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        layer?.borderWidth = 1
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.ui(Typography.rowSize)
        field.placeholderString = "Find in thread"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Find in thread")
        countLabel.font = Typography.tabular(Typography.smallSize)
        countLabel.alignment = .center
        for view in [field, countLabel, previousButton, nextButton, closeButton] as [NSView] { addSubview(view) }
        previousButton.onClick = { [weak self] in self?.onPrevious?() }
        nextButton.onClick = { [weak self] in self?.onNext?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find in thread")
        applyPalette(palette)
    }

    /// Updates the count ("2/5"), the no-results tint and the arrows.
    func setCount(_ label: String, noResults: Bool, canNavigate: Bool) {
        countLabel.stringValue = label
        self.noResults = noResults
        previousButton.isEnabled = canNavigate
        nextButton.isEnabled = canNavigate
        applyPalette(palette)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 24
        var x = bounds.width - 6 - buttonSize
        let y = (bounds.height - buttonSize) / 2
        for button in [closeButton, nextButton, previousButton] {
            button.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
            x -= buttonSize + 2
        }
        let countWidth = max(40, countLabel.textFitWidth)
        countLabel.frame = NSRect(x: x + buttonSize - countWidth - 2, y: (bounds.height - 16) / 2, width: countWidth, height: 16)
        countLabel.isHidden = countLabel.stringValue.isEmpty
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        let fieldRight = countLabel.isHidden ? x + buttonSize - 2 : countLabel.frame.minX - 4
        field.frame = NSRect(x: 12, y: (bounds.height - fieldHeight) / 2, width: max(0, fieldRight - 12), height: fieldHeight)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.popover.cgColor
        layer?.borderColor = palette.foreground.timelineAlpha(0.1).cgColor
        layer?.shadowColor = NSColor.black.timelineAlpha(palette.isDark ? 0.6 : 0.18).cgColor
        field.textColor = palette.foreground
        field.placeholderAttributedString = NSAttributedString(string: "Find in thread", attributes: [
            .font: Typography.ui(Typography.rowSize), .foregroundColor: palette.placeholder,
        ])
        countLabel.textColor = noResults ? palette.errorForeground : palette.mutedForeground
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// T3 Code's `ScrollToEndButton`: a glass pill "⌄ Scroll to end" over the composer.
final class JumpToLatestPill: InteractiveView {
    private let icon = TimelineIconView(symbol: Icon.chevronDown, size: 11)
    private let label = NSTextField.timelineLabel("Scroll to end", size: Typography.smallSize, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = 13
        layer?.borderWidth = 1
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(icon)
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Scroll to end")
        toolTip = "Jump to latest"
        applyPalette(palette)
    }

    var pillSize: NSSize {
        let labelWidth = label.textFitWidth
        return NSSize(width: 10 + 14 + 4 + labelWidth + 12, height: 26)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 28, y: (bounds.height - 16) / 2, width: bounds.width - 28 - 10, height: 16)
    }

    override func applyPalette(_ palette: Palette) {
        let fill = palette.background.mixed(with: palette.foreground, fraction: isHovered ? 0.06 : 0.02)
        layer?.backgroundColor = fill.timelineAlpha(0.92).cgColor
        layer?.borderColor = palette.foreground.timelineAlpha(0.1).cgColor
        layer?.shadowColor = NSColor.black.timelineAlpha(palette.isDark ? 0.5 : 0.12).cgColor
        icon.contentTintColor = palette.foreground
        label.textColor = palette.foreground
    }
}
