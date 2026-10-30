import AppKit
import SopranoAgentsCore

/// Settings → Accounts: one section per account list (omp's Claude logins, Claude Code, omp's
/// Codex logins, the Codex CLI) with the chosen login, the others, sign-in and removal. Reads
/// and acts only through `accounts` (`AccountsCenter.source`); re-renders on every change.
extension SettingsController {
    static let accountsIntro = "Sign in to several Claude and Codex accounts. omp balances across its accounts; Claude Code and the Codex CLI use the one you choose."

    func accountsPage(_ form: SettingsForm) -> [NSView] {
        let snapshot = accounts.snapshot
        let refresh = form.button(snapshot.isRefreshing ? "Refreshing…" : "Refresh", size: .xs) { [weak self] in
            self?.accounts.refresh(force: true)
        }
        refresh.isEnabled = !snapshot.isRefreshing
        let updated = ThemedLabel(UsageText.refreshed(snapshot), size: Typography.smallSize) { $0.mutedForeground }
        var sections = [form.section(nil, [
            form.row("Accounts", description: Self.accountsIntro, control: form.group([updated, refresh], spacing: 10)),
        ])]
        for listID in AccountListID.all {
            sections.append(accountListSection(listID, snapshot: snapshot, form: form))
        }
        return sections
    }

    private func accountListSection(_ listID: AccountListID, snapshot: AccountsSnapshot, form: SettingsForm) -> NSView {
        var rows: [NSView] = []
        if let error = snapshot.errors[listID] {
            let dismiss = form.button("Dismiss", variant: .ghost, size: .xs) { [weak self] in
                self?.accounts.dismissError(in: listID)
            }
            rows.append(form.row("Something went wrong", description: error, descriptionRole: { $0.errorForeground }, control: dismiss))
        }

        let list = snapshot.lists[listID]
        if let list, let reason = list.unavailableReason {
            rows.append(form.row("Unavailable", description: reason))
        } else if let list {
            rows.append(defaultAccountRow(list, form: form))
            for account in list.accounts {
                rows.append(accountRow(account, in: list, snapshot: snapshot, form: form))
            }
        } else {
            rows.append(form.row(snapshot.isRefreshing ? "Loading accounts…" : "Accounts not loaded yet."))
        }
        rows.append(accountListFooter(listID, list: list, snapshot: snapshot, form: form))

        return form.section(
            "\(listID.provider.displayName) · \(listID.tool.displayName)",
            note: UsageText.listNote(listID.tool),
            rows
        )
    }

    /// "Automatic" for omp, "System default" for the CLIs: the choice that leaves the tool to
    /// its own login.
    private func defaultAccountRow(_ list: AccountList, form: SettingsForm) -> NSView {
        let isSelected = list.selectedAccountId == nil
        let listID = list.id
        let title: String
        let detail: String
        var problem: String?
        if listID.tool == .omp {
            title = "Automatic"
            detail = "Balance by usage"
        } else {
            title = "System default"
            if let systemDefault = list.systemDefault {
                let email = systemDefault.identity.email
                detail = ([email].filter { !$0.isEmpty } + UsageText.detailParts(systemDefault)).joined(separator: "  ·  ")
                problem = systemDefault.problem
            } else {
                detail = "Not signed in"
            }
        }
        var buttons: [NSView] = []
        if !isSelected {
            buttons.append(form.button(listID.tool == .omp ? "Automatic" : "Use", size: .xs) { [weak self] in
                self?.accounts.select(accountId: nil, in: listID)
            })
        }
        return AccountEntryRowView(
            title: title,
            isSelected: isSelected,
            badge: isSelected ? "Active" : nil,
            detail: detail,
            problem: problem,
            control: buttons.isEmpty ? nil : form.group(buttons),
            width: form.width
        )
    }

    private func accountRow(_ account: AccountRow, in list: AccountList, snapshot: AccountsSnapshot, form: SettingsForm) -> NSView {
        let listID = list.id
        let accountId = account.id
        let isSelected = list.selectedAccountId == accountId
        var buttons: [NSView] = []
        if !isSelected {
            buttons.append(form.button(listID.tool == .omp ? "Prefer" : "Use", size: .xs) { [weak self] in
                self?.accounts.select(accountId: accountId, in: listID)
            })
        }
        let reauthenticate = form.button("Re-authenticate", size: .xs) { [weak self] in
            self?.accounts.reauthenticate(accountId: accountId, in: listID)
        }
        // One browser sign-in at a time, across every list.
        reauthenticate.isEnabled = snapshot.pendingLogin == nil
        buttons.append(reauthenticate)
        buttons.append(form.button("Remove", variant: .destructiveOutline, size: .xs) { [weak self] in
            self?.confirmRemove(account, from: listID)
        })
        return AccountEntryRowView(
            title: account.identity.email,
            isSelected: isSelected,
            badge: isSelected ? (listID.tool == .omp ? "Preferred" : "Active") : nil,
            detail: UsageText.detailParts(account).joined(separator: "  ·  "),
            problem: account.problem,
            control: form.group(buttons),
            width: form.width
        )
    }

    /// The running sign-in for this list, or the button that starts one.
    private func accountListFooter(_ listID: AccountListID, list: AccountList?, snapshot: AccountsSnapshot, form: SettingsForm) -> NSView {
        if let pending = snapshot.pendingLogin, pending.list == listID {
            let email = pending.accountId.flatMap { id in list?.accounts.first { $0.id == id }?.identity.email }
            let text = email.map { "Waiting for sign-in in your browser to re-authenticate \($0)…" }
                ?? "Waiting for sign-in in your browser…"
            var buttons: [NSView] = []
            if let url = pending.signInURL {
                buttons.append(form.button("Open Sign-in Page", size: .xs) {
                    _ = NSWorkspace.shared.open(url)
                })
            }
            buttons.append(form.button("Cancel", variant: .ghost, size: .xs) { [weak self] in
                self?.accounts.cancelLogin()
            })
            return form.row(
                text,
                description: pending.signInURL == nil ? "Finish signing in in the browser window that opened." : "If no browser window opened, open the sign-in page yourself.",
                control: form.group(buttons)
            )
        }
        let add = form.button("Add Account", symbol: "plus", variant: .primary, size: .xs) { [weak self] in
            self?.accounts.addAccount(to: listID)
        }
        // One browser sign-in at a time, across every list.
        add.isEnabled = snapshot.pendingLogin == nil
        return SettingsActionsRowView(views: [add])
    }

    private func confirmRemove(_ account: AccountRow, from listID: AccountListID) {
        let accounts = accounts
        let host = parentWindow
        let accountId = account.id
        Task { @MainActor in
            let confirmed = await Dialogs.confirm(
                title: "Remove \(account.identity.email)?",
                message: UsageText.removalExplanation(listID.tool),
                confirmTitle: "Remove",
                isDestructive: true,
                in: host
            )
            if confirmed { accounts.remove(accountId: accountId, from: listID) }
        }
    }
}

/// A login in Settings → Accounts: mark, title with an optional badge, a wrapping detail line
/// (organization, plan, usage), the problem in the error color, and the row's buttons on the
/// right. The chosen login sits on a faint fill with a filled mark.
final class AccountEntryRowView: PaletteView {
    private let isSelected: Bool

    init(title: String, isSelected: Bool, badge: String?, detail: String, problem: String?, control: NSView?, width: CGFloat) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        let hasProblem = !(problem ?? "").isEmpty
        let mark = AccountMarkView(isSelected: isSelected, hasProblem: hasProblem)

        let titleLabel = ThemedLabel(title, size: Typography.bodySize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        if let badge {
            let chip = ComposerBadge(badge)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(chip)
        }

        let controlWidth = control.map { $0.fittingSize.width } ?? 0
        let textWidth = max(120, width - 32 - 18 - (control == nil ? 0 : controlWidth + 24))
        let text = NSStackView(views: [titleRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let detailLabel = ThemedLabel(detail, size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
        detailLabel.preferredMaxLayoutWidth = textWidth
        text.addArrangedSubview(detailLabel)
        if let problem, hasProblem {
            let problemLabel = ThemedLabel(problem, size: Typography.smallSize, wrapping: true) { $0.errorForeground }
            problemLabel.preferredMaxLayoutWidth = textWidth
            text.addArrangedSubview(problemLabel)
        }

        for view in [mark, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mark.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ]
        let fill = text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        fill.priority = .defaultLow
        constraints.append(fill)
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -24),
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = isSelected
            ? palette.foreground.withAlphaComponent(palette.isDark ? 0.06 : 0.035).cgColor
            : NSColor.clear.cgColor
    }
}

/// A settings row holding only actions, left-aligned ("Add Account").
final class SettingsActionsRowView: NSView {
    init(views: [NSView]) {
        super.init(frame: .zero)
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}
