import AppKit

/// How close a usage figure is to its limit. The status bar and the usage
/// popover share it so a limit turns yellow and red at the same point in both:
/// yellow from 70 %, danger from 90 %.
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
    private static let inset: CGFloat = 14
    private static let observerId = "AccountUsagePopover"
    /// Mark column: the 8 pt mark plus its gap, so names and usage lines
    /// share one left edge.
    private static let markColumn: CGFloat = Chrome.statusMark + 8
    private static let windowLabelWidth: CGFloat = 52
    private static let barWidth: CGFloat = 64
    private static let percentWidth: CGFloat = 36

    private let themeManager: ThemeManager
    /// Called after "Manage Accounts…" was clicked; the owner closes the
    /// popover and opens Settings → Accounts.
    var onManageAccounts: (() -> Void)?

    private let contentStack = NSStackView()
    private let footerRule = ChromeRuleView(axis: .horizontal)
    private var refreshButton: ChromeButton!
    private var manageButton: ChromeButton!
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
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        refreshButton = ChromeButton(
            title: "Refresh",
            theme: theme,
            target: self,
            action: #selector(refreshClicked)
        )
        manageButton = ChromeButton(
            title: "Manage Accounts…",
            theme: theme,
            kind: .ink,
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
        outer.spacing = 12
        outer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outer)

        contentWidthConstraint = contentStack.widthAnchor.constraint(equalToConstant: Self.minWidth)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            outer.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
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

    /// Rebuilds the popover for `snapshot`; `AccountsController` calls it on
    /// every change while the popover is open.
    func render(_ snapshot: AccountsSnapshot) {
        let theme = themeManager.currentTheme
        let colors = theme.colors
        // The popover is a raised surface; NSPopover supplies the 10 pt
        // radius and the edge.
        view.layer?.backgroundColor = colors.raised.cgColor
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
                    let rule = ChromeRuleView(axis: .horizontal, color: colors.borderSubtle)
                    contentStack.setCustomSpacing(12, after: last)
                    add(rule, spacingAfter: 12)
                }
                add(ChromeEyebrowView(title: listID.provider.displayName, theme: theme), spacingAfter: 8)
                currentProvider = listID.provider
            } else if let last = contentStack.arrangedSubviews.last {
                contentStack.setCustomSpacing(12, after: last)
            }

            let isAutomatic = listID.tool == .omp && list.selectedAccountId == nil
            let caption = makeLabel()
            caption.setChromeText(
                isAutomatic ? "\(listID.tool.displayName) · automatic" : listID.tool.displayName,
                font: ChromeFont.meta,
                color: colors.textMuted
            )
            add(caption, spacingAfter: 6)

            if let systemDefault = list.systemDefault {
                let row = makeRow(
                    systemDefault,
                    isSelected: list.selectedAccountId == nil,
                    isSystemDefault: true,
                    colors: colors
                )
                naturalWidth = max(naturalWidth, row.naturalWidth)
                add(row.view, spacingAfter: 8)
            }
            for account in list.accounts {
                let row = makeRow(
                    account,
                    isSelected: list.selectedAccountId == account.id,
                    isSystemDefault: false,
                    colors: colors
                )
                naturalWidth = max(naturalWidth, row.naturalWidth)
                add(row.view, spacingAfter: 8)
            }
        }

        if fullWidthViews.isEmpty {
            let empty = makeLabel()
            empty.setChromeText("No accounts yet.", font: ChromeFont.label, color: colors.textMuted)
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
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// The login on one line, then one line per usage window:
    ///
    ///     ● ada@example.com
    ///       5h      ▬▬▭▭▭   9%  3h 54m
    ///       7d      ▬▭▭▭▭  10%  5d 17h
    ///
    /// The chosen login has a filled ink mark, the others a ring; a login
    /// with a problem shows the error diamond.
    private func makeRow(
        _ row: AccountRow,
        isSelected: Bool,
        isSystemDefault: Bool,
        colors: ThemeColors
    ) -> (view: NSView, naturalWidth: CGFloat) {
        let hasProblem = !(row.problem ?? "").isEmpty
        let mark = ChromeStatusMark(
            shape: hasProblem ? .diamond : (isSelected ? .dot : .ring),
            color: hasProblem ? colors.danger : (isSelected ? colors.textPrimary : colors.textMuted)
        )

        let name = NSMutableAttributedString()
        if isSystemDefault {
            name.append(ChromeText.attributed("System default — ", font: ChromeFont.label, color: colors.textMuted))
        }
        name.append(ChromeText.attributed(
            row.identity.email.isEmpty ? (row.problem ?? "") : row.identity.email,
            font: isSelected ? ChromeFont.labelStrong : ChromeFont.label,
            color: colors.textPrimary
        ))
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

        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mark)
        view.addSubview(nameLabel)

        let usageStack = NSStackView()
        usageStack.orientation = .vertical
        usageStack.alignment = .leading
        usageStack.spacing = 3
        usageStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(usageStack)

        var usageWidth: CGFloat = 0
        if let usage = row.usage, !usage.windows.isEmpty {
            let now = Date()
            for window in usage.windows {
                let line = makeUsageLine(window, now: now, colors: colors)
                usageStack.addArrangedSubview(line.view)
                usageWidth = max(usageWidth, line.width)
            }
        } else {
            let none = makeLabel()
            none.setChromeText("no usage data", font: ChromeFont.meta, color: colors.textMuted)
            usageStack.addArrangedSubview(none)
            usageWidth = ceil(none.intrinsicContentSize.width)
        }

        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mark.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.markColumn),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            nameLabel.topAnchor.constraint(equalTo: view.topAnchor),
            usageStack.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            usageStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            usageStack.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            usageStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let naturalWidth = Self.markColumn + max(ceil(name.size().width), usageWidth) + 4
        return (view, naturalWidth)
    }

    /// One usage window: its label, a bar filled to the share used, the
    /// percentage in the severity color, and the time until it resets.
    private func makeUsageLine(
        _ window: UsageWindow,
        now: Date,
        colors: ThemeColors
    ) -> (view: NSView, width: CGFloat) {
        let severity = UsageSeverity.color(for: window.usedFraction, colors: colors)

        let label = makeLabel()
        label.setChromeText(window.label, font: ChromeFont.meta, color: colors.textMuted)

        let bar = UsageBarView(
            fraction: window.usedFraction,
            fill: severity == colors.textPrimary ? colors.textMuted : severity,
            track: colors.bgOverlay
        )

        let percent = makeLabel()
        percent.alignment = .right
        percent.setChromeText(UsageFormat.percent(window.usedFraction), font: ChromeFont.badge, color: severity)

        var views: [NSView] = [label, bar, percent]
        // Labels take at least the column width; a longer omp label
        // (`<window> <tier>`) widens its line instead of truncating.
        let labelWidth = max(Self.windowLabelWidth, ceil(label.intrinsicContentSize.width))
        var width = labelWidth + 8 + Self.barWidth + 8 + Self.percentWidth
        if let reset = UsageFormat.timeUntil(window.resetsAt, now: now) {
            let resetLabel = makeLabel()
            resetLabel.setChromeText(reset, font: ChromeFont.count, color: colors.textMuted)
            views.append(resetLabel)
            width += 10 + ceil(resetLabel.intrinsicContentSize.width)
        }

        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        line.setCustomSpacing(10, after: percent)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.windowLabelWidth),
            bar.widthAnchor.constraint(equalToConstant: Self.barWidth),
            percent.widthAnchor.constraint(equalToConstant: Self.percentWidth),
        ])
        return (line, width)
    }

    private func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

/// A 4 pt usage bar: an overlay track filled to `fraction` (capped at full).
private final class UsageBarView: NSView {
    private let fraction: Double
    private let fill: NSColor
    private let track: NSColor

    init(fraction: Double, fill: NSColor, track: NSColor) {
        self.fraction = fraction
        self.fill = fill
        self.track = track
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: floor((bounds.height - 4) / 2), width: bounds.width, height: 4)
        track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        let share = CGFloat(min(max(fraction, 0), 1))
        guard share > 0 else { return }
        var filled = rect
        filled.size.width = max(4, round(rect.width * share))
        fill.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}
