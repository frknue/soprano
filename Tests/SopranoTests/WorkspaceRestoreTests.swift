import Testing
@testable import Soprano

struct WorkspaceRestoreTests {
    @Test func restoreGenerationAdvancesOnlyAfterSuccessfulWorkspaceRestore() {
        let manager = AgentManager()
        let initialGeneration = manager.workspaceRestoreGeneration

        manager.setLayout(.leaf("pane-1"))
        #expect(manager.workspaceRestoreGeneration == initialGeneration)

        manager.restoreWorkspace(emptySession)
        #expect(manager.workspaceRestoreGeneration == initialGeneration)

        let restorableSession = manager.snapshotWorkspace()
        manager.restoreWorkspace(restorableSession)
        #expect(manager.workspaceRestoreGeneration == initialGeneration + 1)

        manager.restoreWorkspace(restorableSession)
        #expect(manager.workspaceRestoreGeneration == initialGeneration + 2)
    }

    private var emptySession: WorkspaceSession {
        WorkspaceSession(
            id: "empty",
            name: "Empty",
            savedAt: .distantPast,
            layout: nil,
            panes: [],
            activePaneId: ""
        )
    }
}
