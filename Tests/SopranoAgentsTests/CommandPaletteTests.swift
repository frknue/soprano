import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

@MainActor
struct CommandPaletteTests {
    private func context(_ engine: AgentEngine) -> CommandContext {
        CommandContext(window: nil, engine: engine, state: WorkspaceState(), workspace: nil, focus: nil, isTextInput: false)
    }

    private func folder(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Command palette

    @Test func theCommandListSkipsDisabledCommandsThePaletteItselfAndArchivedThreads() throws {
        let built = try DemoFixtures.build("demo")
        let commands = [
            AppCommand(id: "palette.open", title: "Command Palette", description: "", category: .app, perform: { _ in }),
            AppCommand(id: "view.toggleSidebar", title: "Toggle Sidebar", description: "Show or hide the thread list", category: .view, perform: { _ in }),
            AppCommand(id: "thread.stop", title: "Interrupt", description: "", category: .thread, isEnabled: { _ in false }, perform: { _ in }),
            AppCommand(id: "timeline.next", title: "Next", description: "", category: .navigation, inPalette: false, perform: { _ in }),
        ]
        let rows = PaletteItems.root(
            commands: commands, context: context(built.engine), keycaps: { $0 == "view.toggleSidebar" ? ["⌘E"] : nil },
            engine: built.engine, now: Date()
        )

        let commandRows = rows.filter { if case .command = $0.choice { true } else { false } }
        #expect(commandRows == [PaletteRow(
            id: "command:view.toggleSidebar", icon: "command", label: "Toggle Sidebar", description: "Show or hide the thread list",
            shortcut: ["⌘E"], searchText: "view.toggleSidebar", choice: .command("view.toggleSidebar")
        )])
        let threadIDs = rows.compactMap { row -> String? in
            if case let .thread(id) = row.choice { return id }
            return nil
        }
        let archived = Set(built.engine.threads.filter { $0.archivedAt != nil }.map(\.id))
        #expect(!archived.isEmpty)
        #expect(archived.isDisjoint(with: threadIDs))
        #expect(threadIDs.count == built.engine.threads.count - archived.count)
        // Most recently used first.
        let dates = threadIDs.compactMap { built.engine.thread($0) }.map(PaletteItems.lastUse)
        #expect(dates == dates.sorted(by: >))
        #expect(Set(rows.compactMap { row -> SettingsPage? in
            if case let .settings(page) = row.choice { return page }
            return nil
        }) == Set(SettingsPage.allCases))
    }

    @Test func aThreadRowNamesItsProjectAndBranchAndMatchesBoth() throws {
        let built = try DemoFixtures.build("demo")
        let thread = try #require(built.engine.threads.first { $0.archivedAt == nil && $0.branch != nil && $0.projectID != nil })
        let project = try #require(built.engine.project(thread.projectID))
        let now = Date()
        let rows = PaletteItems.root(commands: [], context: context(built.engine), keycaps: { _ in nil }, engine: built.engine, now: now)
        let row = try #require(rows.first { $0.choice == .thread(thread.id) })

        #expect(row.label == thread.title)
        #expect(row.description == "\(project.title) · \(thread.branch!) · \(DurationText.relative(thread.activityDate, now: now))")
        #expect(CommandPaletteSearch.filter([item(row)], query: thread.branch!).count == 1)
    }

    private func item(_ row: PaletteRow) -> CommandItem {
        CommandItem(id: row.id, icon: row.icon, label: row.label, description: row.description, shortcut: row.shortcut, searchText: row.searchText) {}
    }

    // MARK: Open Project…

    @Test func projectFoldersAreTheVisibleSubfoldersOfEachRootOnceByName() throws {
        let home = EngineHarness.temporaryDirectory()
        let privateRoot = try folder("private", in: home)
        let work = try folder("work", in: home)
        _ = try folder("zeta", in: privateRoot)
        _ = try folder("Alpha", in: privateRoot)
        _ = try folder(".hidden", in: privateRoot)
        _ = try folder("beta", in: work)
        try "x".write(to: work.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let folders = ProjectFolders.scan([privateRoot.path, work.path, privateRoot.path + "/", home.appendingPathComponent("missing").path])

        #expect(folders.map(\.name) == ["Alpha", "beta", "zeta"])
        #expect(folders.map(\.path) == [
            privateRoot.appendingPathComponent("Alpha").standardizedFileURL.path,
            work.appendingPathComponent("beta").standardizedFileURL.path,
            privateRoot.appendingPathComponent("zeta").standardizedFileURL.path,
        ])
    }

    @Test func openProjectListsProjectsThenNewFoldersThenChooseFolder() throws {
        let engine = EngineHarness.engine()
        let root = EngineHarness.temporaryDirectory()
        let known = try folder("known", in: root).standardizedFileURL.path
        let fresh = try folder("fresh", in: root).standardizedFileURL.path
        let project = engine.addProject(path: known)

        let rows = PaletteItems.projects(engine: engine, folders: ProjectFolders.scan([root.path]))

        #expect(rows.map(\.choice) == [.project(project.id), .folder(fresh), .chooseFolder])
        #expect(rows[1].label == "fresh")
    }

    @Test func pickingAFolderAddsItAsAProjectOnceAndStartsAThreadInIt() throws {
        let built = try DemoFixtures.build("demo")
        let controller = AgentsWindowController(engine: built.engine, state: WorkspaceState(), defaults: UserDefaults(suiteName: UUID().uuidString)!, persistsFrame: false)
        let path = EngineHarness.temporaryDirectory().standardizedFileURL.path
        let before = built.engine.projects.count

        controller.palette.run(.folder(path))
        controller.palette.run(.folder(path))

        let added = try #require(built.engine.projects.first { $0.path == path })
        #expect(built.engine.projects.count == before + 1)
        #expect(controller.state.selection == .draft(projectID: added.id))
    }
}
