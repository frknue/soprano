import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

struct ComposerBranchLabelTests {
    @Test func theTriggerNamesTheWorktreeBaseOrTheCheckedOutBranch() {
        #expect(BranchLabel.trigger(branch: "main", newWorktree: true) == "From main")
        #expect(BranchLabel.trigger(branch: "origin/main", newWorktree: true, isRemote: true) == "From origin/main (remote)")
        #expect(BranchLabel.trigger(branch: "main", newWorktree: false) == "main")
        #expect(BranchLabel.trigger(branch: nil, newWorktree: true) == "Select ref")
    }

    @Test func badgesFollowCurrentThenWorktreeThenRemoteThenDefault() {
        let project = "/repo"
        #expect(BranchLabel.badge(for: GitBranchRef(name: "main", isCurrent: true, isDefault: true, worktreePath: "/elsewhere"), projectPath: project) == "current")
        #expect(BranchLabel.badge(for: GitBranchRef(name: "feature", isDefault: true, worktreePath: "/elsewhere"), projectPath: project) == "worktree")
        #expect(BranchLabel.badge(for: GitBranchRef(name: "feature", worktreePath: project), projectPath: project) == nil)
        #expect(BranchLabel.badge(for: GitBranchRef(name: "origin/main", isRemote: true, isDefault: true), projectPath: project) == "remote")
        #expect(BranchLabel.badge(for: GitBranchRef(name: "main", isDefault: true), projectPath: project) == "default")
    }
}
