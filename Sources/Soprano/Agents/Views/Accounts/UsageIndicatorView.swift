import AppKit

/// The sidebar footer's usage readout next to Settings: "Claude 9% · Codex 75%", each
/// provider's tightest limit in its severity color, resets in the tooltip. Hidden while no
/// provider has usage. Clicking it toggles the usage card (`usage.open`).
final class UsageIndicatorView: InteractiveView {
    private let label = NSTextField.label("", size: Typography.smallSize)
    private let observerID = "UsageIndicator-\(UUID().uuidString)"
    private var snapshot = AccountsSnapshot()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Radius.lg
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Account usage")
        startObserving()
        applyPalette(palette)
    }

    /// Follows the accounts source installed now (the app installs it before building the
    /// window; the snapshot harness too).
    func startObserving() {
        let source = AccountsCenter.source
        source.addObserver(id: observerID) { [weak self] snapshot in self?.update(snapshot) }
        update(source.snapshot)
    }

    func stopObserving() {
        AccountsCenter.source.removeObserver(id: observerID)
    }

    private func update(_ snapshot: AccountsSnapshot) {
        self.snapshot = snapshot
        render()
    }

    private func render() {
        let text = UsageText.attributedIndicator(snapshot, palette: palette)
        label.attributedStringValue = text ?? NSAttributedString(string: "")
        toolTip = UsageText.tooltip(snapshot)
        isHidden = text == nil
    }

    override func applyPalette(_ palette: Palette) {
        let active = isEnabled && isHovered
        layer?.backgroundColor = (active ? palette.sidebarRowHover : .clear).cgColor
        alphaValue = isPressed ? 0.85 : 1
        // The attributed text carries its colors; rebuild it for the new palette.
        let text = UsageText.attributedIndicator(snapshot, palette: palette)
        label.attributedStringValue = text ?? NSAttributedString(string: "")
    }
}
