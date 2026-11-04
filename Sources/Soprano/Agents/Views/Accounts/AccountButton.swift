import AppKit

/// The sidebar footer's account button next to Settings and Statistics: a person icon, tinted
/// `warning` / `error` once a provider's headline limit passes 70 % / 90 %, with each
/// provider's usage and resets in the tooltip. Clicking it toggles the usage card (`usage.open`).
final class AccountButton: InteractiveView {
    private static let side: CGFloat = 32
    private let imageView = NSImageView()
    private let observerID = "AccountButton-\(UUID().uuidString)"
    private var snapshot = AccountsSnapshot()

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        layer?.cornerRadius = Radius.lg
        imageView.image = NSImage.symbol(Icon.account, size: 15)
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Accounts")
        startObserving()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    /// Follows the accounts source installed now (the app installs it before building the
    /// window; the snapshot harness too).
    private func startObserving() {
        let source = AccountsCenter.source
        source.addObserver(id: observerID) { [weak self] snapshot in self?.update(snapshot) }
        update(source.snapshot)
    }

    private func update(_ snapshot: AccountsSnapshot) {
        self.snapshot = snapshot
        toolTip = UsageText.tooltip(snapshot) ?? "Accounts (⌘U)"
        // VoiceOver reads the usage the icon only hints at.
        setAccessibilityHelp(toolTip)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        let active = isEnabled && isHovered
        layer?.backgroundColor = (active ? palette.sidebarRowHover : .clear).cgColor
        imageView.contentTintColor = switch UsageText.severity(snapshot) {
        case .warning: palette.warningForeground
        case .critical: palette.errorForeground
        case .normal: active ? palette.sidebarForeground : palette.sidebarMutedForeground.alphaScaled(by: 0.8)
        }
        alphaValue = isPressed ? 0.85 : 1
    }
}
