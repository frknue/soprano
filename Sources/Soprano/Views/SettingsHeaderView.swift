import AppKit

/// The header shared by the full-window overlays (Settings and the Agent
/// Dashboard): a New York screen title, an optional muted subtitle, a
/// `Done esc` button that returns to the workspace, and one hairline under
/// it. It sits directly under the 28 pt titlebar band.
final class SettingsHeaderView: NSView {
    static let height: CGFloat = 56

    let closeButton: ChromeButton
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let rule: ChromeRuleView
    private var theme: AppTheme

    var onClose: (() -> Void)?

    var title: String {
        didSet { applyText() }
    }

    /// Muted meta text after the title, e.g. "Monitoring 4 agents across 3
    /// windows". Empty or nil hides it.
    var subtitle: String? {
        didSet { applyText() }
    }

    var displayedSubtitle: String { subtitleLabel.stringValue }

    init(title: String = "Settings", subtitle: String? = nil, theme: AppTheme) {
        self.theme = theme
        self.title = title
        self.subtitle = subtitle
        closeButton = ChromeButton(title: "Done", theme: theme, kind: .standard, keycap: "esc")
        rule = ChromeRuleView(axis: .horizontal, color: theme.colors.borderSubtle)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(subtitleLabel)

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
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 14),
            subtitleLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -Chrome.Space.s16),

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
        layer?.backgroundColor = colors.bgBase.cgColor
        applyText()
        closeButton.apply(theme: theme)
        rule.color = colors.borderSubtle
    }

    private func applyText() {
        let colors = theme.colors
        titleLabel.setChromeText(title, font: ChromeFont.screen, color: colors.textPrimary)
        let subtitle = subtitle ?? ""
        subtitleLabel.setChromeText(subtitle, font: ChromeFont.meta, color: colors.textMuted)
        subtitleLabel.isHidden = subtitle.isEmpty
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
