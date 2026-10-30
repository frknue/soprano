import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct GitActionsQuickActionTests {
    private let changes = [ChangedFileStat(path: "a.swift", additions: 3, deletions: 1)]
    private let openPR = PullRequestInfo(number: 7, title: "Fix", url: "https://example.com/pr/7", state: .open)

    private func status(
        branch: String? = "feature", isDefault: Bool = false, remote: Bool = true, upstream: Bool = true,
        ahead: Int = 0, behind: Int = 0, dirty: Bool = false, pr: PullRequestInfo? = nil
    ) -> GitStatusSummary {
        GitStatusSummary(
            isRepository: true, branch: branch, isDefaultBranch: isDefault, hasRemote: remote, hasUpstream: upstream,
            ahead: ahead, behind: behind, files: dirty ? changes : [], pullRequest: pr
        )
    }

    @Test func busyAndUnknownStatusShowADisabledCommitWithTheReason() {
        #expect(GitQuickAction.resolve(status(dirty: true), isBusy: true) == GitQuickAction(label: "Commit", isDisabled: true, kind: .hint("Git action in progress.")))
        #expect(GitQuickAction.resolve(nil, isBusy: false).hint == "Git status is unavailable.")
        #expect(GitQuickAction.resolve(status(branch: nil, dirty: true), isBusy: false).hint
            == "Create and checkout a ref before pushing or opening a pull request.")
    }

    @Test func uncommittedChangesPickTheStackedActionByRemoteAndPullRequest() {
        #expect(GitQuickAction.resolve(status(remote: false, upstream: false, dirty: true), isBusy: false).kind == .run(.commit))
        #expect(GitQuickAction.resolve(status(dirty: true, pr: openPR), isBusy: false).label == "Commit & push")
        #expect(GitQuickAction.resolve(status(isDefault: true, dirty: true), isBusy: false).kind == .run(.commitAndPush))
        let full = GitQuickAction.resolve(status(dirty: true), isBusy: false)
        #expect(full.label == "Commit, push & PR")
        #expect(full.kind == .run(.commitPushAndPullRequest))
    }

    @Test func cleanTreesFollowUpstreamState() {
        #expect(GitQuickAction.resolve(status(remote: false, upstream: false), isBusy: false).kind == .publish)
        #expect(GitQuickAction.resolve(status(upstream: false), isBusy: false) == GitQuickAction(label: "Push", isDisabled: true, kind: .hint("No local commits to push.")))
        #expect(GitQuickAction.resolve(status(upstream: false, ahead: 2), isBusy: false).kind == .run(.createPullRequest))
        #expect(GitQuickAction.resolve(status(upstream: false, ahead: 2, pr: openPR), isBusy: false).kind == .run(.push))
        #expect(GitQuickAction.resolve(status(ahead: 1, behind: 1), isBusy: false).label == "Sync ref")
        #expect(GitQuickAction.resolve(status(behind: 3), isBusy: false).kind == .pull)
        #expect(GitQuickAction.resolve(status(ahead: 1), isBusy: false).label == "Push & create PR")
        #expect(GitQuickAction.resolve(status(isDefault: true, ahead: 1), isBusy: false) == GitQuickAction(label: "Push", isDisabled: false, kind: .run(.commitAndPush)))
        #expect(GitQuickAction.resolve(status(pr: openPR), isBusy: false).hint == "Branch is up to date. No action needed.")
        #expect(GitQuickAction.resolve(status(), isBusy: false).isDisabled)
    }

    @Test func theMenuOffersOnlyWhatTheBranchAllows() {
        #expect(GitQuickAction.menuItems(status(remote: false, upstream: false, dirty: true), isBusy: false).map(\.title) == ["Commit"])
        let withPR = GitQuickAction.menuItems(status(ahead: 1, pr: openPR), isBusy: false)
        #expect(withPR.map(\.title) == ["Commit", "Push"])
        #expect(withPR.map(\.isEnabled) == [false, true])
        let behind = GitQuickAction.menuItems(status(ahead: 1, behind: 1, dirty: true), isBusy: false)
        #expect(behind.map(\.isEnabled) == [true, false, false])
        #expect(GitQuickAction.menuItems(status(dirty: true), isBusy: true).allSatisfy { !$0.isEnabled })
        #expect(GitQuickAction.menuItems(nil, isBusy: false).isEmpty)
    }

    @Test func publishingFromTheDefaultBranchAsksFirstWithTheRightWording() {
        #expect(GitQuickAction.requiresDefaultBranchConfirmation(.push, isDefaultBranch: true))
        #expect(!GitQuickAction.requiresDefaultBranchConfirmation(.commit, isDefaultBranch: true))
        #expect(!GitQuickAction.requiresDefaultBranchConfirmation(.commitPushAndPullRequest, isDefaultBranch: false))
        let copy = GitQuickAction.defaultBranchCopy(.commitAndPush, branch: "main", includesCommit: true)
        #expect(copy.title == "Commit & push to default ref?")
        #expect(copy.continueTitle == "Commit & push to main")
        #expect(copy.message.hasPrefix("This action will commit and push changes on \"main\"."))
        #expect(GitQuickAction.defaultBranchCopy(.createPullRequest, branch: "main", includesCommit: false).title
            == "Push & create PR from default ref?")
    }

    @Test func countsAndElapsedTimesReadLikeT3Code() {
        #expect(compactDiffCount(999) == "999")
        #expect(compactDiffCount(1_200) == "1.2k")
        #expect(compactDiffCount(12_345) == "12k")
        #expect(compactDiffCount(2_000_000) == "2m")
        #expect(gitActionElapsedText(42) == "42s")
        #expect(gitActionElapsedText(125) == "2m 5s")
    }
}
