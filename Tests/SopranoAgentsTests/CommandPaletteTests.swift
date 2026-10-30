import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct CommandPaletteTests {
    private func entry(_ title: String, kind: PaletteEntryKind? = nil, subtitle: String? = nil, terms: [String] = []) -> PaletteEntry {
        PaletteEntry(id: title, kind: kind ?? .command(title), title: title, subtitle: subtitle, icon: "command", searchTerms: terms)
    }

    // MARK: Fuzzy matching

    @Test func aContiguousWordStartMatchBeatsAScatteredOne() throws {
        let tight = try #require(FuzzyMatch.match("term", in: "Toggle Terminal Drawer"))
        let loose = try #require(FuzzyMatch.match("term", in: "Testing rmdir output"))
        #expect(tight.score > loose.score)
        #expect(tight.positions == [7, 8, 9, 10])
    }

    @Test func matchingIgnoresCaseAndWhitespaceInTheQuery() throws {
        let match = try #require(FuzzyMatch.match("Dark Mode", in: "Add dark mode toggle"))
        #expect(match.positions == [4, 5, 6, 7, 9, 10, 11, 12])
        #expect(FuzzyMatch.match("darkmode", in: "Add dark mode toggle") != nil)
    }

    @Test func lettersMissingOrOutOfOrderAreNoMatch() {
        #expect(FuzzyMatch.match("xyz", in: "Toggle Sidebar") == nil)
        #expect(FuzzyMatch.match("rabdis", in: "Toggle Sidebar") == nil)
        #expect(FuzzyMatch.match("   ", in: "Toggle Sidebar") == nil)
    }

    @Test func aQueryScatteredOverManyRunsIsNoMatch() {
        // t…h…r…e…a…d spread over five words is noise, not a hit.
        #expect(FuzzyMatch.match("thread", in: "The quick hare raced a dog") == nil)
        #expect(FuzzyMatch.match("togside", in: "Toggle Sidebar") != nil)
    }

    // MARK: Groups

    private var source: PaletteSource {
        PaletteSource(
            actions: [
                entry("New thread in...", kind: .submenu(.newThreadIn), terms: ["new thread project"]),
                entry("Toggle Sidebar", terms: ["view.toggleSidebar"]),
                entry("Toggle Terminal Drawer", terms: ["view.toggleTerminal"]),
                entry("Open settings.json", terms: ["settings.openFile"]),
            ],
            threads: (0..<15).map { entry("Thread \($0)", kind: .thread("t\($0)"), subtitle: "app · soprano/branch-\($0)", terms: ["soprano/branch-\($0)", "app"]) },
            projects: [entry("app", kind: .project("p1"), subtitle: "~/code/app"), entry("site", kind: .project("p2"), subtitle: "~/code/site")],
            settings: [entry("Chat width", kind: .settings(.general), subtitle: "Settings · General", terms: ["wide full width"])]
        )
    }

    @Test func anEmptyQueryShowsActionsAndTwelveRecentThreads() {
        let groups = PaletteSearch.groups(query: "", submenu: nil, source: source)
        #expect(groups.map(\.title) == ["Actions", "Recent Threads"])
        #expect(groups[0].entries.count == 4)
        #expect(groups[1].entries.map(\.title) == (0..<12).map { "Thread \($0)" })
    }

    @Test func aQueryRanksEveryGroupAndDropsEmptyOnes() {
        let groups = PaletteSearch.groups(query: "term", submenu: nil, source: source)
        #expect(groups.map(\.title) == ["Actions"])
        #expect(groups[0].entries.map(\.title) == ["Toggle Terminal Drawer"])
        #expect(groups[0].entries[0].highlights == [7, 8, 9, 10])

        let width = PaletteSearch.groups(query: "wide", submenu: nil, source: source)
        #expect(width.map(\.title) == ["Settings"])
        // Matched only through its search terms: no title highlight.
        #expect(width[0].entries[0].highlights.isEmpty)
    }

    @Test func threadsMatchByBranchAndProjectsByTitle() {
        let branch = PaletteSearch.groups(query: "branch-14", submenu: nil, source: source)
        #expect(branch.first { $0.title == "Threads" }?.entries.first?.kind == .thread("t14"))

        let project = PaletteSearch.groups(query: "site", submenu: nil, source: source)
        #expect(project.first { $0.title == "Projects" }?.entries.map(\.kind) == [.project("p2")])
    }

    @Test func aTitleMatchOutranksAMatchInSearchTerms() {
        let ranked = PaletteSearch.rank([
            entry("Open settings.json", terms: ["sidebar"]),
            entry("Toggle Sidebar"),
        ], query: "sidebar")
        #expect(ranked.map(\.title) == ["Toggle Sidebar", "Open settings.json"])
    }

    @Test func aGreaterThanPrefixListsOnlyActions() {
        let all = PaletteSearch.groups(query: ">", submenu: nil, source: source)
        #expect(all.map(\.title) == ["Actions"])
        #expect(all[0].entries.count == 4)

        let filtered = PaletteSearch.groups(query: "> app", submenu: nil, source: source)
        #expect(filtered.isEmpty)
        #expect(PaletteSearch.groups(query: ">side", submenu: nil, source: source).first?.entries.map(\.title) == ["Toggle Sidebar"])
    }

    @Test func theNewThreadSubmenuListsProjects() {
        let groups = PaletteSearch.groups(query: "", submenu: .newThreadIn, source: source)
        #expect(groups.map(\.title) == ["Projects"])
        #expect(groups[0].entries.map(\.kind) == [.project("p1"), .project("p2")])
        #expect(PaletteSearch.groups(query: "si", submenu: .newThreadIn, source: source).first?.entries.map(\.title) == ["site"])
    }

    // MARK: Source

    @Test func theSourceSkipsDisabledCommandsThePaletteItselfAndArchivedThreads() throws {
        let built = try DemoFixtures.build("demo")
        let commands = [
            AppCommand(id: "palette.open", title: "Command Palette", category: .app, perform: { _ in }),
            AppCommand(id: "view.toggleSidebar", title: "Toggle Sidebar", category: .view, perform: { _ in }),
            AppCommand(id: "thread.stop", title: "Interrupt", category: .thread, isEnabled: { _ in false }, perform: { _ in }),
            AppCommand(id: "timeline.next", title: "Next", category: .navigation, inPalette: false, perform: { _ in }),
        ]
        let context = CommandContext(window: nil, engine: built.engine, state: WorkspaceState(), workspace: nil, focus: nil, isTextInput: false)
        let source = PaletteSource.make(
            commands: commands, context: context, keycaps: { $0 == "view.toggleSidebar" ? ["⌘B"] : nil },
            engine: built.engine, now: Date()
        )

        #expect(source.actions.map(\.kind) == [.submenu(.newThreadIn), .command("view.toggleSidebar")])
        #expect(source.actions[1].keycaps == ["⌘B"])
        let threadIDs = source.threads.compactMap { entry -> String? in
            if case let .thread(id) = entry.kind { return id }
            return nil
        }
        let archived = Set(built.engine.threads.filter { $0.archivedAt != nil }.map(\.id))
        #expect(!archived.isEmpty)
        #expect(archived.isDisjoint(with: threadIDs))
        #expect(threadIDs.count == built.engine.threads.count - archived.count)
        // Most recently used first.
        let dates = threadIDs.compactMap { built.engine.thread($0) }.map(PaletteSource.lastUse)
        #expect(dates == dates.sorted(by: >))
        #expect(source.projects.count == built.engine.projects.count)
        #expect(Set(source.settings.compactMap { entry -> SettingsPage? in
            if case let .settings(page) = entry.kind { return page }
            return nil
        }) == Set(SettingsPage.allCases))
    }
}
