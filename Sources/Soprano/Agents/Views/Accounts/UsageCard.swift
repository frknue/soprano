import AppKit

/// The usage card: omp's account lists with each login's usage and which login is preferred,
/// one per provider. It follows `AccountsCenter.source` while open, so a refresh or a
/// selection made in Settings shows up live.
///
///     CLAUDE
///     omp · automatic
///     ○ ada@example.com
///       5h      ▬▭▭▭▭    9%  3h 54m
///       7d      ▬▭▭▭▭    6%  5d 17h
///     ──────────────────────────────
///     [Refresh]  [Manage Accounts…]
final class UsageCardContent: ComposerPopoverContent {
    static let width: CGFloat = 340
    private static let inset: CGFloat = 14
    /// The mark plus its gap, so names and usage lines share one left edge.
    private static let markColumn: CGFloat = AccountMarkView.side + 8
    private static let windowLabelWidth: CGFloat = 52
    private static let percentWidth: CGFloat = 36

    var onRefresh: (() -> Void)?
    var onManageAccounts: (() -> Void)?

    private let contentStack = NSStackView()
    private let footerRule = AccountsRule()
    private let refreshButton = TextButton("Refresh", size: .xs)
    private let manageButton = TextButton("Manage Accounts…", variant: .primary, size: .xs)
    private var lastSnapshot = AccountsSnapshot()

    init(snapshot: AccountsSnapshot) {
        super.init(frame: .zero)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0

        refreshButton.onClick = { [weak self] in self?.onRefresh?() }
        manageButton.onClick = { [weak self] in self?.onManageAccounts?() }
        let footer = NSStackView(views: [refreshButton, manageButton])
        footer.orientation = .horizontal
        footer.spacing = 8

        for view in [contentStack, footerRule, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            footerRule.topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: 12),
            footerRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            footer.topAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityLabel("Account usage")
        render(snapshot)
    }

    /// Rebuilds the card for `snapshot`.
    func render(_ snapshot: AccountsSnapshot, now: Date = Date()) {
        lastSnapshot = snapshot
        refreshButton.title = snapshot.isRefreshing ? "Refreshing…" : "Refresh"
        refreshButton.setAccessibilityLabel(refreshButton.title)
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

        for listID in AccountListID.shown {
            guard let list = snapshot.lists[listID], !list.accounts.isEmpty else { continue }
            if let last = contentStack.arrangedSubviews.last {
                contentStack.setCustomSpacing(12, after: last)
                add(AccountsRule(), after: 12)
            }
            add(eyebrow(listID.provider.displayName), after: 8)
            add(ThemedLabel(UsageText.caption(for: list), size: Typography.smallSize) { $0.mutedForeground }, after: 6)
            for account in list.accounts {
                add(makeRow(account, isSelected: list.selectedAccountId == account.id, now: now), after: 8)
            }
        }
        if fullWidth.isEmpty {
            add(ThemedLabel("No accounts yet.", size: Typography.rowSize) { $0.mutedForeground }, after: 0)
        }
        for view in fullWidth {
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            if let rule = view as? AccountsRule { rule.heightAnchor.constraint(equalToConstant: 1).isActive = true }
        }
        requestResize?()
    }

    override func applyPalette(_ palette: Palette) {
        // Attributed and drawn parts take the new palette on a rebuild.
        render(lastSnapshot)
    }

    /// "CLAUDE": 11 pt semibold muted capitals, slightly tracked.
    private func eyebrow(_ title: String) -> NSView {
        NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: [
            .font: Typography.ui(Typography.tinySize, weight: .semibold),
            .foregroundColor: palette.mutedForeground,
            .kern: 0.6,
        ]))
    }

    /// The login on one line, then one line per usage window.
    private func makeRow(_ row: AccountRow, isSelected: Bool, now: Date) -> NSView {
        let hasProblem = !(row.problem ?? "").isEmpty
        let mark = AccountMarkView(isSelected: isSelected, hasProblem: hasProblem)

        let name = NSMutableAttributedString(string: row.identity.email.isEmpty ? (row.problem ?? "") : row.identity.email, attributes: [
            .font: Typography.ui(Typography.rowSize, weight: isSelected ? .semibold : .regular),
            .foregroundColor: palette.foreground,
        ])
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
            usageStack.addArrangedSubview(ThemedLabel("no usage data", size: Typography.smallSize) { $0.mutedForeground })
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

    /// One window: its label, a bar filled to the share used, the percentage in the severity
    /// color, and the time until it resets.
    private func makeUsageLine(_ window: UsageWindow, now: Date) -> NSView {
        let severity = UsageSeverity(fraction: window.usedFraction)
        let label = ThemedLabel(window.label, size: Typography.smallSize) { $0.mutedForeground }
        let bar = UsageBarView(fraction: window.usedFraction)
        let percent = ThemedLabel(UsageFormat.percent(window.usedFraction), size: Typography.smallSize, weight: .medium) { severity.color(in: $0) }
        percent.font = Typography.tabular(Typography.smallSize, weight: .medium)
        percent.alignment = .right
        var views: [NSView] = [label, bar, percent]
        if let reset = UsageFormat.timeUntil(window.resetsAt, now: now) {
            let resetLabel = ThemedLabel(reset, size: Typography.smallSize) { $0.mutedForeground }
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

/// A 1 pt hairline in `border`.
final class AccountsRule: PaletteView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.border.cgColor
    }
}

/// Opens and closes the usage card next to its anchor (the sidebar's usage indicator, else the
/// Settings button) and keeps it rendering the accounts source while it is open.
@MainActor
final class UsageCardPresenter {
    private static let observerID = "UsageCard"
    private var popover: ComposerPopover?
    private var content: UsageCardContent?
    /// "Manage Accounts…" was clicked; the card is closed already.
    var onManageAccounts: (() -> Void)?

    var isShown: Bool { popover?.isShown ?? false }

    func toggle(anchoredTo anchor: NSView) {
        if isShown {
            close()
        } else {
            show(anchoredTo: anchor)
        }
    }

    func show(anchoredTo anchor: NSView) {
        close()
        let source = AccountsCenter.source
        let content = UsageCardContent(snapshot: source.snapshot)
        content.onRefresh = { AccountsCenter.source.refresh(force: true) }
        content.onManageAccounts = { [weak self] in
            self?.close()
            self?.onManageAccounts?()
        }
        let popover = ComposerPopover(content: content)
        popover.onClose = { [weak self] in
            AccountsCenter.source.removeObserver(id: Self.observerID)
            self?.popover = nil
            self?.content = nil
        }
        self.popover = popover
        self.content = content
        source.addObserver(id: Self.observerID) { [weak content] snapshot in
            content?.render(snapshot)
        }
        popover.show(anchoredTo: anchor, side: .above, alignment: .leading)
        source.refresh(force: false)
    }

    func close() {
        popover?.close()
    }
}
