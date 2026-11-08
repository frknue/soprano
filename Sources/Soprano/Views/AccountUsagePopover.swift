import AppKit

/// How close a usage figure is to its limit: warning-colored from 70 %,
/// error-colored from 90 %. The status bar, the usage card and Settings →
/// Accounts turn at the same points.
enum UsageSeverity {
    /// The status bar's figure: ink while there is room.
    static func color(for fraction: Double, colors: ThemeColors) -> NSColor {
        if fraction >= 0.9 { return colors.danger }
        if fraction >= 0.7 { return colors.yellow }
        return colors.textPrimary
    }

    /// A percentage in the usage card (Soprano Agents): muted while there is room.
    static func percentColor(for fraction: Double, in palette: Palette) -> NSColor {
        if fraction >= 0.9 { return palette.errorForeground }
        if fraction >= 0.7 { return palette.warningForeground }
        return palette.mutedForeground
    }

    /// The fill of a usage bar.
    static func barColor(for fraction: Double, in palette: Palette) -> NSColor {
        if fraction >= 0.9 { return palette.error }
        if fraction >= 0.7 { return palette.warning }
        return palette.mutedForeground
    }
}

/// The status bar's usage popover, laid out as Soprano Agents' usage card:
/// per provider an eyebrow, each list's caption ("omp · automatic") and its
/// logins with one bar per usage window, then Refresh and Manage Accounts….
/// It follows `AccountsController` while it is on screen, so a refresh or a
/// selection made elsewhere shows up live.
///
///     CLAUDE
///     omp · automatic
///     ○ ada@example.com
///       5h      ▬▭▭▭▭    9%  3h 54m
///       7d      ▬▭▭▭▭    6%  5d 17h
///     ──────────────────────────────
///     [Refresh]  [Manage Accounts…]
final class AccountUsagePopoverViewController: NSViewController {
    static let width: CGFloat = 340
    private static let inset: CGFloat = 14
    private static let observerId = "AccountUsagePopover"
    /// The mark plus its gap, so names and usage lines share one left edge.
    private static let markColumn: CGFloat = SettingsAccountMark.side + 8
    private static let windowLabelWidth: CGFloat = 52
    private static let percentWidth: CGFloat = 36

    private let themeManager: ThemeManager
    /// Called after "Manage Accounts…" was clicked; the owner closes the
    /// popover and opens Settings → Accounts.
    var onManageAccounts: (() -> Void)?

    private let contentStack = NSStackView()
    private var refreshButton: SettingsButton!

    init(themeManager: ThemeManager) {
        self.themeManager = themeManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = UsageCardRootView()
        root.setAccessibilityLabel("Account usage")
        view = root

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0

        refreshButton = SettingsButton("Refresh", size: .xs) {
            AccountsController.shared.refresh(force: true)
        }
        let manageButton = SettingsButton("Manage Accounts…", variant: .primary, size: .xs) { [weak self] in
            self?.onManageAccounts?()
        }
        let footer = NSStackView(views: [refreshButton, manageButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        let footerRule = UsageCardRule()

        for subview in [contentStack, footerRule, footer] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            contentStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
            footerRule.topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: 12),
            footerRule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footer.topAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
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

    // MARK: - Rendering

    /// Rebuilds the card for `snapshot`; `AccountsController` calls it on
    /// every change while the popover is open.
    func render(_ snapshot: AccountsSnapshot, now: Date = Date()) {
        loadViewIfNeeded()
        refreshButton.title = snapshot.isRefreshing ? "Refreshing…" : "Refresh"
        refreshButton.isEnabled = !snapshot.isRefreshing

        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var fullWidth: [NSView] = []
        func add(_ view: NSView, after spacing: CGFloat) {
            contentStack.addArrangedSubview(view)
            contentStack.setCustomSpacing(spacing, after: view)
            fullWidth.append(view)
        }

        var currentProvider: AccountProvider?
        for listID in AccountListID.all {
            guard let list = snapshot.lists[listID],
                  !list.accounts.isEmpty || list.systemDefault != nil
            else { continue }
            if listID.provider != currentProvider {
                if let last = contentStack.arrangedSubviews.last {
                    contentStack.setCustomSpacing(12, after: last)
                    add(UsageCardRule(), after: 12)
                }
                add(eyebrow(listID.provider.displayName), after: 8)
                currentProvider = listID.provider
            } else if let last = contentStack.arrangedSubviews.last {
                contentStack.setCustomSpacing(12, after: last)
            }
            add(SettingsLabel(Self.caption(for: list), size: Typography.smallSize) { $0.mutedForeground }, after: 6)
            if let systemDefault = list.systemDefault {
                add(makeRow(systemDefault, isSelected: list.selectedAccountId == nil, isSystemDefault: true, now: now), after: 8)
            }
            for account in list.accounts {
                add(makeRow(account, isSelected: list.selectedAccountId == account.id, isSystemDefault: false, now: now), after: 8)
            }
        }
        if fullWidth.isEmpty {
            add(SettingsLabel("No accounts yet.", size: Typography.rowSize) { $0.mutedForeground }, after: 0)
        }
        for view in fullWidth {
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// "omp · automatic" until a login is preferred, then the tool's name.
    private static func caption(for list: AccountList) -> String {
        list.id.tool == .omp && list.selectedAccountId == nil
            ? "\(list.id.tool.displayName) · automatic"
            : list.id.tool.displayName
    }

    /// "CLAUDE": 11 pt semibold muted capitals, slightly tracked.
    private func eyebrow(_ title: String) -> NSView {
        NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [
            .font: Typography.ui(Typography.tinySize, weight: .semibold),
            .foregroundColor: PaletteCenter.shared.palette.mutedForeground,
            .kern: 0.6,
        ]))
    }

    /// The login on one line, then one line per usage window. The chosen
    /// login has a filled mark, the others a ring; a login with a problem
    /// shows the error diamond.
    private func makeRow(_ row: AccountRow, isSelected: Bool, isSystemDefault: Bool, now: Date) -> NSView {
        let palette = PaletteCenter.shared.palette
        let hasProblem = !(row.problem ?? "").isEmpty
        let mark = SettingsAccountMark(isSelected: isSelected, hasProblem: hasProblem)

        let name = NSMutableAttributedString()
        if isSystemDefault {
            name.append(NSAttributedString(string: "System default — ", attributes: [
                .font: Typography.ui(Typography.rowSize),
                .foregroundColor: palette.mutedForeground,
            ]))
        }
        name.append(NSAttributedString(string: row.identity.email.isEmpty ? (row.problem ?? "") : row.identity.email, attributes: [
            .font: Typography.ui(Typography.rowSize, weight: isSelected ? .semibold : .regular),
            .foregroundColor: palette.foreground,
        ]))
        // The paragraph style, not the field's lineBreakMode, decides how an
        // attributed label breaks: one line, shortened in the middle.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingMiddle
        name.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: name.length))
        let nameLabel = NSTextField(labelWithAttributedString: name)
        nameLabel.maximumNumberOfLines = 1
        nameLabel.cell?.wraps = false
        nameLabel.toolTip = row.problem ?? row.organizationName.map { "\(row.identity.email) · \($0)" } ?? row.identity.email
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let usageStack = NSStackView()
        usageStack.orientation = .vertical
        usageStack.alignment = .leading
        usageStack.spacing = 3
        if let usage = row.usage, !usage.windows.isEmpty {
            for window in usage.windows {
                usageStack.addArrangedSubview(makeUsageLine(window, now: now))
            }
        } else {
            usageStack.addArrangedSubview(SettingsLabel("no usage data", size: Typography.smallSize) { $0.mutedForeground })
        }

        let view = NSView()
        for subview in [mark, nameLabel, usageStack] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
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
        return view
    }

    /// One window: its label, a bar filled to the share used, the percentage
    /// in the severity color, and the time until it resets.
    private func makeUsageLine(_ window: UsageWindow, now: Date) -> NSView {
        let fraction = window.usedFraction
        let label = SettingsLabel(window.label, size: Typography.smallSize) { $0.mutedForeground }
        let bar = SettingsUsageBar(fraction: fraction)
        let percent = SettingsLabel(UsageFormat.percent(fraction), size: Typography.smallSize, weight: .medium) {
            UsageSeverity.percentColor(for: fraction, in: $0)
        }
        percent.font = Typography.tabular(Typography.smallSize, weight: .medium)
        percent.alignment = .right
        var views: [NSView] = [label, bar, percent]
        if let reset = UsageFormat.timeUntil(window.resetsAt, now: now) {
            let resetLabel = SettingsLabel(reset, size: Typography.smallSize) { $0.mutedForeground }
            resetLabel.font = Typography.tabular(Typography.smallSize)
            views.append(resetLabel)
        }
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 8
        line.setCustomSpacing(10, after: percent)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.windowLabelWidth),
            percent.widthAnchor.constraint(equalToConstant: Self.percentWidth),
        ])
        return line
    }
}

/// The card's surface: the popover fill.
private final class UsageCardRootView: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.popover.cgColor
    }
}

/// A 1 pt hairline in `border`.
private final class UsageCardRule: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.border.cgColor
    }
}
