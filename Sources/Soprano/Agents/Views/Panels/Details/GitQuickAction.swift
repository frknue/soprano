import AppKit
import SopranoAgentsCore

/// The primary button of the Git actions row, derived from this app's `GitStatusSummary`. Hosts are
/// GitHub-style, so the change request is a "PR" / "pull request".
struct GitQuickAction: Equatable {
    enum Kind: Equatable {
        /// Runs a stacked git action.
        case run(GitStackedAction)
        /// Pulls the upstream branch.
        case pull
        /// The repository has no remote: explains how to publish it.
        case publish
        /// Nothing to do; `hint` says why.
        case hint(String)
    }

    var label: String
    var isDisabled: Bool
    var kind: Kind

    var hint: String? {
        if case let .hint(text) = kind { return text }
        return nil
    }

    private static func hint(_ label: String, _ text: String) -> GitQuickAction {
        GitQuickAction(label: label, isDisabled: true, kind: .hint(text))
    }

    /// `status` nil = not loaded yet or failed; `isBusy` = a git action runs.
    static func resolve(_ status: GitStatusSummary?, isBusy: Bool) -> GitQuickAction {
        if isBusy { return hint("Commit", "Git action in progress.") }
        guard let status, status.isRepository else { return hint("Commit", "Git status is unavailable.") }
        guard status.branch != nil else {
            return hint("Commit", "Create and checkout a ref before pushing or opening a pull request.")
        }
        let hasOpenPR = status.pullRequest?.state == .open
        let isAhead = status.ahead > 0
        let isBehind = status.behind > 0
        let isDefault = status.isDefaultBranch

        if status.hasChanges {
            if !status.hasUpstream && !status.hasRemote {
                return GitQuickAction(label: "Commit", isDisabled: false, kind: .run(.commit))
            }
            if hasOpenPR || isDefault {
                return GitQuickAction(label: "Commit & push", isDisabled: false, kind: .run(.commitAndPush))
            }
            return GitQuickAction(label: "Commit, push & PR", isDisabled: false, kind: .run(.commitPushAndPullRequest))
        }

        if !status.hasUpstream {
            if !status.hasRemote {
                return GitQuickAction(label: "Publish repository", isDisabled: false, kind: .publish)
            }
            if !isAhead {
                if hasOpenPR { return hint("Commit", "Branch is up to date. No action needed.") }
                return hint("Push", "No local commits to push.")
            }
            if hasOpenPR || isDefault {
                return GitQuickAction(label: "Push", isDisabled: false, kind: .run(isDefault ? .commitAndPush : .push))
            }
            return GitQuickAction(label: "Push & create PR", isDisabled: false, kind: .run(.createPullRequest))
        }

        if isAhead && isBehind {
            return hint("Sync ref", "Branch has diverged from upstream. Rebase/merge first.")
        }
        if isBehind {
            return GitQuickAction(label: "Pull", isDisabled: false, kind: .pull)
        }
        if isAhead {
            if hasOpenPR || isDefault {
                return GitQuickAction(label: "Push", isDisabled: false, kind: .run(isDefault ? .commitAndPush : .push))
            }
            return GitQuickAction(label: "Push & create PR", isDisabled: false, kind: .run(.createPullRequest))
        }
        // Up to date with the upstream. ("Create PR" for a branch ahead of the default
        // one needs `ahead > 0`, which returned above: the status has no separate default delta.)
        return hint("Commit", "Branch is up to date. No action needed.")
    }

    /// One entry of the "Git action options" menu.
    struct MenuItem: Equatable {
        enum Action: Equatable {
            /// Opens the "Commit changes" dialog.
            case commitDialog
            case push
            case createPullRequest
        }

        var title: String
        var isEnabled: Bool
        var action: Action
    }

    /// Menu items: Commit, Push, Create PR (only Commit without a remote, no
    /// Create PR while a PR is open). Empty while the status is unknown.
    static func menuItems(_ status: GitStatusSummary?, isBusy: Bool) -> [MenuItem] {
        guard let status, status.isRepository else { return [] }
        let hasBranch = status.branch != nil
        let hasOpenPR = status.pullRequest?.state == .open
        let isBehind = status.behind > 0
        let canPushWithoutUpstream = status.hasRemote && !status.hasUpstream
        let canCommit = !isBusy && status.hasChanges
        let canPush = !isBusy && hasBranch && !isBehind && status.ahead > 0
            && (status.hasUpstream || canPushWithoutUpstream)
        let canCreatePR = !isBusy && hasBranch && !hasOpenPR && status.ahead > 0 && !isBehind
            && (status.hasUpstream || canPushWithoutUpstream)

        let commit = MenuItem(title: "Commit", isEnabled: canCommit, action: .commitDialog)
        guard status.hasRemote else { return [commit] }
        let push = MenuItem(title: "Push", isEnabled: canPush, action: .push)
        if hasOpenPR { return [commit, push] }
        return [commit, push, MenuItem(title: "Create PR", isEnabled: canCreatePR, action: .createPullRequest)]
    }

    /// Actions that publish from the default branch ask first (`requiresDefaultBranchConfirmation`).
    static func requiresDefaultBranchConfirmation(_ action: GitStackedAction, isDefaultBranch: Bool) -> Bool {
        guard isDefaultBranch else { return false }
        switch action {
        case .push, .createPullRequest, .commitAndPush, .commitPushAndPullRequest: return true
        case .commit: return false
        }
    }

    struct DefaultBranchCopy: Equatable {
        var title: String
        var message: String
        var continueTitle: String
    }

    /// Confirmation copy for acting on the default branch.
    static func defaultBranchCopy(_ action: GitStackedAction, branch: String, includesCommit: Bool) -> DefaultBranchCopy {
        let suffix = " on \"\(branch)\". You can continue on this ref or create a feature ref and run the same action there."
        switch action {
        case .push, .commitAndPush, .commit:
            if includesCommit {
                return DefaultBranchCopy(
                    title: "Commit & push to default ref?",
                    message: "This action will commit and push changes\(suffix)",
                    continueTitle: "Commit & push to \(branch)"
                )
            }
            return DefaultBranchCopy(
                title: "Push to default ref?",
                message: "This action will push local commits\(suffix)",
                continueTitle: "Push to \(branch)"
            )
        case .createPullRequest, .commitPushAndPullRequest:
            if includesCommit {
                return DefaultBranchCopy(
                    title: "Commit, push & create PR from default ref?",
                    message: "This action will commit, push, and create a pull request\(suffix)",
                    continueTitle: "Commit, push & create PR"
                )
            }
            return DefaultBranchCopy(
                title: "Push & create PR from default ref?",
                message: "This action will push local commits and create a pull request\(suffix)",
                continueTitle: "Push & create PR"
            )
        }
    }

    /// Whether `action` starts with a commit.
    static func includesCommit(_ action: GitStackedAction) -> Bool {
        switch action {
        case .commit, .commitAndPush, .commitPushAndPullRequest: true
        case .push, .createPullRequest: false
        }
    }
}

/// "12s", "3m 4s": elapsed time of a running git action (`formatGitActionElapsed`).
func gitActionElapsedText(_ seconds: TimeInterval) -> String {
    let whole = max(0, Int(seconds))
    if whole < 60 { return "\(whole)s" }
    return "\(whole / 60)m \(whole % 60)s"
}

/// Diff counts: 999, 1.2k, 12k, 1.5m.
func compactDiffCount(_ value: Int) -> String {
    func scaled(_ amount: Double, _ suffix: String) -> String {
        if amount < 10 {
            let text = String(format: "%.1f", amount)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        return "\(Int(amount.rounded()))\(suffix)"
    }
    if value < 1000 { return String(value) }
    if value < 999_500 { return scaled(Double(value) / 1000, "k") }
    if value < 999_500_000 { return scaled(Double(value) / 1_000_000, "m") }
    return scaled(Double(value) / 1_000_000_000, "b")
}
