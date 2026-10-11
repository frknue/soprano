import AppKit

/// How close a usage figure is to its limit. The status bar and the usage
/// popover share it so a limit turns yellow and red at the same point in both.
enum UsageSeverity {
    static func color(for fraction: Double, colors: ThemeColors) -> NSColor {
        if fraction >= 0.9 { return colors.danger }
        if fraction >= 0.7 { return colors.yellow }
        return colors.textPrimary
    }
}

/// The status bar's usage popover: every account list with each login's
/// usage and which login is chosen. It follows `AccountsController` while it
/// is on screen, so a refresh or a selection made elsewhere shows up live.
final class AccountUsagePopoverViewController: NSViewController {
    static let maxWidth: CGFloat = 460
    private static let minWidth: CGFloat = 280
    private static let inset: CGFloat = 12
    private static let observerId = "AccountUsagePopover"

    private let themeManager: ThemeManager
    /// Called after "Manage Accounts…" was clicked; the owner closes the
    /// popover and opens Settings → Accounts.
    var onManageAccounts: (() -> Void)?

    private let contentStack = NSStackView()
    private let footerRule = RetroRuleView(axis: .horizontal, style: .single)
    private var refreshButton: RetroButton!
    private var manageButton: RetroButton!
    private var contentWidthConstraint: NSLayoutConstraint!

    init(themeManager: ThemeManager) {
        self.themeManager = themeManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        let theme = themeManager.currentTheme
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        refreshButton = RetroButton(
            title: "Refresh",
            theme: theme,
            target: self,
            action: #selector(refreshClicked)
        )
        manageButton = RetroButton(
            title: "Manage Accounts…",
            theme: theme,
            target: self,
            action: #selector(manageAccountsClicked)
        )
        let footer = NSStackView(views: [refreshButton, manageButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [contentStack, footerRule, footer])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outer)

        contentWidthConstraint = contentStack.widthAnchor.constraint(equalToConstant: Self.minWidth)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            outer.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.inset),
            contentWidthConstraint,
            footerRule.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        render(AccountsController.shared.snapshot)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        AccountsController.shared.addObserver(id: Self.observerId) { [weak self] snapshot in
            self?.render(snapshot)
        }
        render(AccountsController.shared.snapshot)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        AccountsController.shared.removeObserver(id: Self.observerId)
    }

    @objc private func refreshClicked() {
        AccountsController.shared.refresh(force: true)
    }

    @objc private func manageAccountsClicked() {
        onManageAccounts?()
    }

    // MARK: - Rendering

    private func render(_ snapshot: AccountsSnapshot) {
        let theme = themeManager.currentTheme
        let colors = theme.colors
        view.layer?.backgroundColor = colors.bgPanel.cgColor
        view.layer?.borderWidth = Retro.hairline
        view.layer?.borderColor = colors.borderStrong.cgColor
        footerRule.color = colors.borderSubtle
        refreshButton.apply(theme: theme)
        manageButton.apply(theme: theme)
        refreshButton.title = snapshot.isRefreshing ? "Refreshing…" : "Refresh"
        refreshButton.isEnabled = !snapshot.isRefreshing

        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Rows measure their natural width before they are pinned to the
        // column, so the popover is as wide as its longest line, capped.
        var fullWidthViews: [NSView] = []
        var usageLabels: [(label: NSTextField, indent: CGFloat)] = []
        var naturalWidth: CGFloat = 0
        func add(_ view: NSView, spacingAfter: CGFloat? = nil) {
            contentStack.addArrangedSubview(view)
            if let spacingAfter {
                contentStack.setCustomSpacing(spacingAfter, after: view)
            }
            fullWidthViews.append(view)
        }

        var currentProvider: AccountProvider?
        for listID in AccountListID.all {
            guard let list = snapshot.lists[listID],
                  !list.accounts.isEmpty || list.systemDefault != nil
            else { continue }

            if listID.provider != currentProvider {
                if let last = contentStack.arrangedSubviews.last {
                    contentStack.setCustomSpacing(12, after: last)
                }
                add(RetroHeadingView(title: listID.provider.displayName, theme: theme), spacingAfter: 8)
                currentProvider = listID.provider
            } else if let last = contentStack.arrangedSubviews.last {
                contentStack.setCustomSpacing(10, after: last)
            }

            let isAutomatic = listID.tool == .omp && list.selectedAccountId == nil
            let caption = makeLabel()
            caption.setRetroText(
                isAutomatic ? "\(listID.tool.displayName) · automatic" : listID.tool.displayName,
                color: colors.textMuted
            )
            add(caption, spacingAfter: 4)

            if let systemDefault = list.systemDefault {
                let row = makeRow(
                    systemDefault,
                    isSelected: list.selectedAccountId == nil,
                    isSystemDefault: true,
                    colors: colors
                )
                naturalWidth = max(naturalWidth, row.naturalWidth)
                usageLabels.append((row.usageLabel, row.indent))
                add(row.view)
            }
            for account in list.accounts {
                let row = makeRow(
                    account,
                    isSelected: list.selectedAccountId == account.id,
                    isSystemDefault: false,
                    colors: colors
                )
                naturalWidth = max(naturalWidth, row.naturalWidth)
                usageLabels.append((row.usageLabel, row.indent))
                add(row.view)
            }
        }

        if fullWidthViews.isEmpty {
            let empty = makeLabel()
            empty.attributedStringValue = bodyText("No accounts yet.", color: colors.textMuted)
            add(empty)
        }

        for view in fullWidthViews {
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        let footerWidth = refreshButton.intrinsicContentSize.width + 8 + manageButton.intrinsicContentSize.width
        let columnWidth = min(
            Self.maxWidth - Self.inset * 2,
            max(Self.minWidth, ceil(naturalWidth), footerWidth)
        )
        contentWidthConstraint.constant = columnWidth
        // Wrapping labels need their width up front to report the right height.
        for (label, indent) in usageLabels {
            label.preferredMaxLayoutWidth = columnWidth - indent
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// Two lines, so a long email never squeezes the figures (or the reverse):
    ///
    ///     ● ada@example.com
    ///       5h 9% · 3h 54m   7d 10% · 5d 17h
    private func makeRow(
        _ row: AccountRow,
        isSelected: Bool,
        isSystemDefault: Bool,
        colors: ThemeColors
    ) -> (view: NSView, usageLabel: NSTextField, indent: CGFloat, naturalWidth: CGFloat) {
        let marker = makeLabel()
        marker.attributedStringValue = bodyText(
            isSelected ? "●" : "○",
            color: isSelected ? colors.accent : colors.textMuted
        )
        marker.setContentHuggingPriority(.required, for: .horizontal)
        marker.setContentCompressionResistancePriority(.required, for: .horizontal)

        let name = NSMutableAttributedString()
        if isSystemDefault {
            name.append(bodyText("System default — ", color: colors.textMuted))
        }
        name.append(bodyText(row.identity.email.isEmpty ? (row.problem ?? "") : row.identity.email, color: colors.textPrimary))
        // The paragraph style, not the field's lineBreakMode, decides how an
        // attributed label breaks: one line, shortened in the middle.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingMiddle
        name.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: name.length))
        let nameLabel = makeLabel()
        nameLabel.maximumNumberOfLines = 1
        nameLabel.cell?.wraps = false
        nameLabel.attributedStringValue = name
        nameLabel.toolTip = row.organizationName.map { "\(row.identity.email) · \($0)" } ?? row.identity.email
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [marker, nameLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let usage = usageText(row.usage, colors: colors)
        let usageLabel = NSTextField(wrappingLabelWithString: "")
        usageLabel.attributedStringValue = usage
        usageLabel.maximumNumberOfLines = 0
        usageLabel.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(usageLabel)
        let indent = marker.intrinsicContentSize.width + header.spacing
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            usageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: indent),
            usageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            usageLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            usageLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let naturalWidth = max(
            marker.intrinsicContentSize.width + header.spacing + ceil(name.size().width),
            indent + ceil(usage.size().width)
        ) + 4
        return (view, usageLabel, indent, naturalWidth)
    }

    /// Each window as `UsageFormat.window` renders it, with the percentage
    /// colored by how close it is to the limit.
    private func usageText(_ usage: AccountUsage?, colors: ThemeColors) -> NSAttributedString {
        guard let usage, !usage.windows.isEmpty else {
            return bodyText("no usage data", color: colors.textMuted)
        }
        let now = Date()
        let text = NSMutableAttributedString()
        for (index, window) in usage.windows.enumerated() {
            if index > 0 {
                text.append(bodyText("   ", color: colors.textMuted))
            }
            let segment = NSMutableAttributedString(
                attributedString: bodyText(UsageFormat.window(window, now: now), color: colors.textMuted)
            )
            let percentRange = (segment.string as NSString).range(of: UsageFormat.percent(window.usedFraction))
            if percentRange.location != NSNotFound {
                segment.addAttribute(
                    .foregroundColor,
                    value: UsageSeverity.color(for: window.usedFraction, colors: colors),
                    range: percentRange
                )
            }
            text.append(segment)
        }
        return text
    }

    private func bodyText(_ string: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: RetroFont.body(11),
            .foregroundColor: color,
        ])
    }

    private func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
