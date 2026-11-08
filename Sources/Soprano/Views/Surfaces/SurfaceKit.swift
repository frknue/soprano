import AppKit

// Soprano Agents' right-panel file surfaces (`Views/Panels/Files`, `Views/Panels/Diff`) as the
// pieces Soprano's editor, diff, Markdown and browser panes and the explorer share: the 40 pt
// header with a hairline, the folder breadcrumbs, the borderless search/address field, and the
// muted centered message with its outline button.

/// A 1 pt `border` rule (Agents' `HairlineView`).
final class SurfaceHairline: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.border.cgColor
    }
}

/// The header of a file surface (`FileViewerViewController.header`): 40 pt on the background,
/// leading content at 16 pt, ghost icon buttons 2 pt apart ending 8 pt from the edge, and a
/// hairline below. `height` includes the hairline.
final class SurfaceToolbar: PaletteView {
    static let contentHeight: CGFloat = 40
    static let height: CGFloat = contentHeight + 1

    private let stack = NSStackView()
    private let rule = SurfaceHairline()

    /// `leading` fills the space (its first view takes the slack); `trailing` sits at the end.
    /// Without `spacer`, a stretchy leading view (an address field) takes the slack itself.
    init(leading: [NSView], trailing: [NSView], spacer hasSpacer: Bool = true, leadingInset: CGFloat = 16) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        for view in leading + (hasSpacer ? [spacer] : []) + trailing {
            stack.addArrangedSubview(view)
        }
        stack.alignment = .centerY
        stack.spacing = 2
        if let last = leading.last {
            stack.setCustomSpacing(8, after: last)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(rule)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.contentHeight / 2),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        applyPalette(palette)
    }

    /// Room after `view` (a group of buttons).
    func setSpacing(_ spacing: CGFloat, after view: NSView) {
        stack.setCustomSpacing(spacing, after: view)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }

    /// A header button: Agents' 28 pt ghost icon button with a 12 pt symbol.
    static func button(_ symbol: String, _ label: String, target: AnyObject, action: Selector) -> ShellGhostButton {
        ShellGhostButton(symbol: symbol, label: label, size: 28, symbolSize: 12, target: target, action: action)
    }
}

/// Agents' file breadcrumbs: "Sources / Auth / LoginController.swift", folders and separators
/// muted, the name in the foreground, truncated from the head.
@MainActor
enum SurfaceBreadcrumbs {
    static func make(_ path: String, palette: Palette) -> NSAttributedString {
        let font = Typography.ui(Typography.smallSize)
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.mutedForeground]
        let parts = path.split(separator: "/").map(String.init)
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 {
                result.append(NSAttributedString(string: part, attributes: [
                    .font: Typography.ui(Typography.smallSize, weight: .medium), .foregroundColor: palette.foreground,
                ]))
            } else {
                result.append(NSAttributedString(string: part, attributes: muted))
                result.append(NSAttributedString(string: " / ", attributes: muted))
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The path a breadcrumb shows for a file: relative to its git working tree (Agents shows
    /// workspace-relative paths), else the home-abbreviated absolute path.
    nonisolated static func displayPath(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let folder = (path as NSString).deletingLastPathComponent
        if let root = GitBranchMonitor.repositoryRoot(startingAt: folder) {
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return ConfigFile.abbreviatingHome(path)
    }

    /// A breadcrumb label: one line, truncating its head, giving way to the buttons.
    static func label() -> NSTextField {
        let label = NSTextField.label(size: Typography.smallSize)
        label.lineBreakMode = .byTruncatingHead
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        return label
    }
}

/// Agents' borderless input (`FilesSearchField`): an optional leading symbol, the caller's
/// embedded text field, and a trailing accessory; `accent/60` under the pointer or while
/// editing, a `primary/70` edge while editing (error edge when invalid), radius 6, 28 pt.
final class SurfaceFieldView: PaletteView {
    static let height: CGFloat = 28

    /// The field holds the keyboard; owners set it from the field's focus changes.
    var isFocused = false {
        didSet { if isFocused != oldValue { applyPalette(palette) } }
    }
    var isInvalid = false {
        didSet { if isInvalid != oldValue { applyPalette(palette) } }
    }
    /// A resting fill (the browser's address bar); nil = none.
    var restingFill: ((Palette) -> NSColor)? {
        didSet { applyPalette(palette) }
    }

    private(set) var isHovered = false
    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?

    /// Embeds `field` (styled with `styleEmbedded`) after `symbol`, then `trailing`.
    init(field: NSTextField, symbol: String?, trailing: NSView? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = Radius.md
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        var constraints = [
            heightAnchor.constraint(equalToConstant: Self.height),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let symbol {
            iconView.image = NSImage.symbol(symbol, size: 12)
            iconView.imageScaling = .scaleNone
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            constraints += [
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10))
        }
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            addSubview(trailing)
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
                field.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -2),
            ]
        } else {
            constraints.append(field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8))
        }
        NSLayoutConstraint.activate(constraints)
        applyPalette(palette)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyPalette(palette)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyPalette(palette)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isHovered {
            isHovered = false
            applyPalette(palette)
        }
    }

    /// A click on the padding around the embedded field focuses the field.
    override func mouseDown(with event: NSEvent) {
        guard let field = subviews.lazy.compactMap({ $0 as? NSTextField }).first(where: { !$0.isHidden }),
              field.isEditable || field.isSelectable, let window else {
            super.mouseDown(with: event)
            return
        }
        if field.currentEditor() == nil {
            window.makeFirstResponder(field)
        }
    }

    override func applyPalette(_ palette: Palette) {
        let active = isHovered || isFocused
        let fill = active ? palette.accent.timelineAlpha(0.6) : (restingFill?(palette) ?? .clear)
        layer?.backgroundColor = fill.cgColor
        let edge: NSColor? = isInvalid ? palette.error : isFocused ? palette.primary.timelineAlpha(0.7) : nil
        layer?.borderWidth = edge == nil ? 0 : 1
        layer?.borderColor = edge?.cgColor
        iconView.contentTintColor = palette.mutedForeground
    }

    /// Makes `field` borderless and backgroundless in the 13 pt UI font (or `font`).
    @MainActor
    static func styleEmbedded(_ field: NSTextField, font: NSFont = Typography.ui(Typography.rowSize)) {
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = PaletteCenter.shared.palette.foreground
    }

    /// The field's placeholder in the palette's placeholder color.
    @MainActor
    static func setPlaceholder(_ text: String, of field: NSTextField, font: NSFont = Typography.ui(Typography.rowSize)) {
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .foregroundColor: PaletteCenter.shared.palette.placeholder, .font: font,
        ])
    }

    /// Gives an active field editor the foreground caret and the viewer's selection tint.
    @MainActor
    static func styleEditor(of field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let palette = PaletteCenter.shared.palette
        editor.insertionPointColor = palette.foreground
        editor.selectedTextAttributes = [.backgroundColor: SurfaceText.selection(palette)]
    }
}

/// Text colors the file viewer uses.
@MainActor
enum SurfaceText {
    /// Selected text: `primary` at 45 % (dark) or 22 % (light).
    static func selection(_ palette: Palette) -> NSColor {
        palette.primary.withAlphaComponent(palette.isDark ? 0.45 : 0.22)
    }
}

/// The file viewer's note for what it cannot show (`messageStack`): a muted 12 pt line, up to
/// four lines centered, over an optional outline button.
final class SurfaceMessageView: PaletteView {
    let label = NSTextField.label(size: Typography.smallSize)
    let button: ShellTextButton?
    private let stack = NSStackView()

    init(buttonTitle: String? = nil, target: AnyObject? = nil, action: Selector? = nil) {
        if let buttonTitle {
            let button = ShellTextButton(title: buttonTitle, variant: .outline)
            button.target = target
            button.action = action
            self.button = button
        } else {
            button = nil
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.addArrangedSubview(label)
        if let button { stack.addArrangedSubview(button) }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        applyPalette(palette)
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// Centers the message over `area`, at most `area`'s width less 48 pt.
    func pin(centeredIn area: NSLayoutYAxisAnchor, of host: NSView) {
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            centerYAnchor.constraint(equalTo: area, constant: -20),
            widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -48),
        ])
    }

    override func applyPalette(_ palette: Palette) {
        label.textColor = palette.mutedForeground
    }
}
