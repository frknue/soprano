import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

@MainActor
struct FilesSurfaceDraftTests {
    /// Lists one more file on every call, so a reload is visible as a new listing.
    private final class GrowingFiles: WorkspaceFileService, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var calls: Int { lock.withLock { count } }

        func listFiles(root: String) async throws -> [String] {
            let n = lock.withLock { count += 1; return count }
            return (1...n).map { "file\($0).txt" }
        }

        func readFile(root: String, relativePath: String) async throws -> WorkspaceFileContent { .text("") }
    }

    @Test func returningToAProjectDraftRelistsItsFolderInsteadOfShowingTheOldTree() async throws {
        let files = GrowingFiles()
        let engine = AgentEngine(environment: EngineEnvironment(
            drivers: [:],
            git: RecordingGit(),
            store: InMemoryThreadStore(),
            dataDirectory: EngineHarness.temporaryDirectory(),
            files: files
        ))
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let state = WorkspaceState()
        let surface = FilesSurfaceViewController(engine: engine, state: state)
        _ = surface.view
        state.select(.draft(projectID: project.id))
        state.showRightPanel(.files)
        #expect(await EngineHarness.eventually { files.calls == 1 })

        // Meanwhile a "Current checkout" thread changes the folder.
        let threadID = EngineHarness.idleThread(in: engine)
        state.select(.thread(threadID))
        state.select(.draft(projectID: project.id))

        #expect(await EngineHarness.eventually { files.calls >= 2 })
    }
}
