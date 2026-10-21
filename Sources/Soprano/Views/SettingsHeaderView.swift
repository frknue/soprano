import AppKit

/// The Settings overlay's header: the serif screen title, a `Done esc`
/// button that returns to the workspace, and one hairline under it.
final class SettingsHeaderView: NSView {
    static let height: CGFloat = 56

    let closeButton: ChromeButton
    private let titleLabel = NSTextField(labelWithString: "Settings")
    private let rule: ChromeRuleView
    private var theme: AppTheme

    var onClose: (() -> Void)?

    init(theme: AppTheme) {
        self.theme = theme
        closeButton = ChromeButton(title: "Done", theme: theme, kind: .standard, keycap: "esc")
        rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.keyEquivalentModifierMask = []
        closeButton.toolTip = "Return to the workspace (Esc)"
        addSubview(closeButton)

        addSubview(rule)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Chrome.Space.page),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Chrome.Space.page),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        self.theme = theme
        let colors = theme.colors
        layer?.backgroundColor = colors.bgPanel.cgColor
        titleLabel.setChromeText("Settings", font: ChromeFont.screen, color: colors.textPrimary)
        closeButton.apply(theme: theme)
        rule.color = colors.borderSubtle
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
