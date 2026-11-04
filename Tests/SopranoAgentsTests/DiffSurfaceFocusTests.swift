import AppKit
import SopranoAgentsCore
import Testing
@testable import Soprano

@MainActor
struct DiffSurfaceFocusTests {
    private static let patch = """
    diff --git a/a.swift b/a.swift
    --- a/a.swift
    +++ b/a.swift
    @@ -1,1 +1,1 @@
    -let a = 1
    +let a = 2
    diff --git a/b.swift b/b.swift
    --- a/b.swift
    +++ b/b.swift
    @@ -1,1 +1,1 @@
    -let b = 1
    +let b = 2

    """

    @Test func aChangedFileClickFocusesItOnceAndLaterPanelChangesAndReloadsKeepWhatTheUserCollapsed() async {
        let git = RecordingGit()
        git.workingPatch = Self.patch
        let engine = EngineHarness.engine(git: git)
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let state = WorkspaceState()
        state.select(.draft(projectID: project.id))
        state.showDiff(.uncommitted, focus: "b.swift")
        let diff = DiffSurfaceViewController(engine: engine, state: state)
        _ = diff.view

        #expect(await EngineHarness.eventually(timeout: .seconds(30)) { diff.entries.count == 2 })
        #expect(diff.collapsed.isEmpty)

        diff.toggleCollapseAll()
        state.setSidebarVisible(false)
        #expect(diff.collapsed == [0, 1])

        // The reload brings a third file, so its arrival shows the reload was applied.
        git.workingPatch = Self.patch + """
        diff --git a/c.swift b/c.swift
        --- a/c.swift
        +++ b/c.swift
        @@ -1,1 +1,1 @@
        -let c = 1
        +let c = 2

        """
        diff.reload(force: true)
        #expect(await EngineHarness.eventually(timeout: .seconds(30)) { diff.entries.count == 3 })
        #expect(diff.collapsed == [0, 1])
    }
}
