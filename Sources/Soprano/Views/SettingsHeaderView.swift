import AppKit

/// A control that uses Esc itself while it holds keyboard focus, such as the
/// Prefix key recorder ending a recording. The settings overlay and the page
/// headers leave Esc to it.
@MainActor
protocol EscapeConsumingControl: AnyObject {
    var consumesEscape: Bool { get }
}

/// The settings page header, ported from Soprano Agents: the breadcrumb
/// "Settings › General" and a close button (×), with one hairline under it.
final class SettingsHeaderView: PaletteView {
    static let height = Metrics.topbarHeight

    var onClose: (() -> Void)?
    let closeButton = GhostIconButton(symbol: "xmark", size: 28, symbolSize: 13, toolTip: "Close settings")
    private let root = SettingsLabel("Settings", size: Typography.bodySize) { $0.mutedForeground }
    private let chevron = NSImageView()
    private let current = SettingsLabel("", size: Typography.bodySize, weight: .medium)
    private let rule = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.addSublayer(rule)
        chevron.image = NSImage.symbol(Icon.chevronRight, size: 11)
        closeButton.onClick = { [weak self] in self?.onClose?() }
        for view in [root, chevron, current, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            root.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: root.trailingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            current.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 6),
            current.centerYAnchor.constraint(equalTo: centerYAnchor),
            current.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyPalette(palette)
    }

    /// The page in the breadcrumb.
    var pageTitle: String {
        get { current.stringValue }
        set { current.stringValue = newValue }
    }

    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    override func applyPalette(_ palette: Palette) {
        rule.backgroundColor = palette.border.cgColor
        chevron.contentTintColor = palette.mutedForeground
    }
}
