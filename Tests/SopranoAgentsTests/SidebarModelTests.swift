import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct SidebarModelTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let model = ModelSelection(provider: .codex, model: "gpt-6.1-sol")
    private static let app = Project(id: "app", title: "app", path: "/tmp/app")
    private static let site = Project(id: "site", title: "site", path: "/tmp/site")

    private static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    /// A thread whose single turn ended `ago` seconds before `now` (or still runs).
    private static func thread(
        _ id: String,
        project: String? = "app",
        title: String? = nil,
        ago seconds: TimeInterval = 600,
        status: TurnStatus = .completed,
        visited: Bool = true,
        pinned: Bool = false,
        settled: Bool = false,
        branch: String? = nil,
        reply: String = "",
        checkpoint: TurnCheckpoint? = nil
    ) -> AgentThread {
        let started = ago(seconds)
        let turn = Turn(
            ordinal: 1,
            userMessage: UserMessage(text: "Prompt for \(id)", createdAt: started),
            modelSelection: model,
            status: status,
            startedAt: started,
            completedAt: status == .running ? nil : started.addingTimeInterval(10),
            items: reply.isEmpty ? [] : [TurnItem(id: "\(id)-a", kind: .assistantMessage(text: reply, isFinal: true), status: .completed)],
            checkpoint: checkpoint
        )
        return AgentThread(
            id: id,
            projectID: project,
            title: title ?? "Thread \(id)",
            createdAt: started,
            modelSelection: model,
            branch: branch,
            pinnedAt: pinned ? started : nil,
            settledAt: settled ? started.addingTimeInterval(60) : nil,
            lastVisitedAt: visited ? now : nil,
            turns: [turn]
        )
    }

    private static func build(_ threads: [AgentThread], projects: [Project] = [app, site], _ options: SidebarListOptions = SidebarListOptions()) -> [SidebarItem] {
        SidebarListModel.build(threads: threads, projects: projects, options: options)
    }

    private static func describe(_ items: [SidebarItem]) -> [String] {
        items.map { item in
            switch item {
            case let .card(row): "card \(row.threadID)"
            case let .slim(row): "slim \(row.threadID)"
            case let .shelf(section, count, expanded): "\(section.title) \(count)\(expanded ? " open" : "")"
            case let .showMore(count): "more \(count)"
            case .spacer: "spacer"
            case let .empty(state): "empty \(state.message)"
            }
        }
    }

    @Test func pinnedComeFirstThenActiveByLatestActivityThenTheShelvesAtTheBottom() {
        let items = Self.build([
            Self.thread("old", ago: 9000),
            Self.thread("new", ago: 60),
            Self.thread("pin", ago: 99_000, pinned: true),
            Self.thread("run", ago: 30, status: .running),
            Self.thread("done", ago: 50_000, settled: true),
        ])
        #expect(Self.describe(items) == ["card pin", "card new", "card old", "spacer", "Working 1", "Settled 1"])
    }

    @Test func closedShelvesStillShowTheOpenThread() {
        let threads = [
            Self.thread("a", settled: true),
            Self.thread("b", ago: 900, settled: true),
            Self.thread("run", status: .running),
        ]
        let items = Self.build(threads, SidebarListOptions(selectedThreadID: "b"))
        #expect(Self.describe(items) == ["spacer", "Working 1", "Settled 2", "slim b"])
        let working = Self.build(threads, SidebarListOptions(selectedThreadID: "run"))
        #expect(Self.describe(working) == ["spacer", "Working 1", "card run", "Settled 2"])
    }

    @Test func theSettledShelfShowsTenThenOffersTheNextPage() {
        let settled = (0..<40).map { Self.thread("s\($0)", ago: Double(100 + $0), settled: true) }
        var options = SidebarListOptions(expandedShelves: [.settled])
        let first = Self.build(settled, options)
        #expect(first.filter { if case .slim = $0 { true } else { false } }.count == 10)
        #expect(first.last == .showMore(25))
        #expect(first.first(where: { $0.thread != nil })?.thread?.threadID == "s0")

        options.settledLimit = 35
        #expect(Self.build(settled, options).last == .showMore(5))
        options.settledLimit = 60
        #expect(Self.build(settled, options).filter { $0.thread != nil }.count == 40)
    }

    @Test func theOpenThreadStaysVisibleBeyondTheSettledPage() {
        let settled = (0..<15).map { Self.thread("s\($0)", ago: Double(100 + $0), settled: true) }
        let items = Self.build(settled, SidebarListOptions(selectedThreadID: "s14", expandedShelves: [.settled]))
        #expect(items.contains { $0.thread?.threadID == "s14" })
        #expect(items.last == .showMore(4))
    }

    @Test func theProjectFilterHidesOtherProjectsAndScratchThreads() {
        let threads = [Self.thread("a"), Self.thread("b", project: "site"), Self.thread("scratch", project: nil)]
        let items = Self.build(threads, SidebarListOptions(projectFilter: ["site"]))
        #expect(SidebarListModel.threadOrder(items) == ["b"])
        let both = Self.build(threads, SidebarListOptions(projectFilter: ["site", "app"]))
        #expect(Set(SidebarListModel.threadOrder(both)) == ["a", "b"])
    }

    @Test func emptyListsExplainWhy() {
        #expect(Self.build([], projects: []) == [.empty(.noProjects)])
        #expect(Self.build([]) == [.empty(.noThreads("No threads yet"))])
        #expect(Self.build([Self.thread("a")], SidebarListOptions(projectFilter: ["site"])) == [.empty(.noThreads("No threads in site yet"))])
        #expect(Self.build([], SidebarListOptions(projectFilter: ["site", "app"])) == [.empty(.noThreads("No threads in these projects yet"))])
    }

    @Test func archivedThreadsNeverShow() {
        var archived = Self.thread("gone")
        archived.archivedAt = Self.now
        #expect(SidebarListModel.threadOrder(Self.build([archived, Self.thread("a")])) == ["a"])
    }

    @Test func searchMatchesTitlesBranchesAndMessagesAcrossSections() {
        let threads = [
            Self.thread("title", title: "Fix SSO login"),
            Self.thread("branch", settled: true, branch: "soprano/sso-cleanup"),
            Self.thread("reply", reply: "The SSO cookie races the redirect."),
            Self.thread("other", title: "Dark mode"),
        ]
        let items = Self.build(threads, SidebarListOptions(searchText: "  sso "))
        #expect(Set(SidebarListModel.threadOrder(items)) == ["title", "branch", "reply"])
        #expect(items.allSatisfy { if case .card = $0 { true } else { false } })
        #expect(Self.build(threads, SidebarListOptions(searchText: "nothing like this")) == [.empty(.noResults)])
    }

    @Test func statusPillsUseTheT3LabelsAndALiveDuration() {
        let started = Self.ago(75)
        let working = SidebarStatusPill.of(.working(since: started))
        #expect(working?.text(now: Self.now) == "Working 1m")
        #expect(working?.tone == .working)
        #expect(SidebarStatusPill.of(.working(since: Self.ago(12)))?.text(now: Self.now) == "Working 12s")
        #expect(SidebarStatusPill.of(.approval)?.text(now: Self.now) == "Approval")
        #expect(SidebarStatusPill.of(.approval)?.tone == .approval)
        #expect(SidebarStatusPill.of(.input)?.label == "Input")
        #expect(SidebarStatusPill.of(.failed)?.tone == .failed)
        #expect(SidebarStatusPill.of(.done)?.label == "Done")
        #expect(SidebarStatusPill.of(.idle) == nil)
    }

    @Test func readIdleRowsRecedeButTheOpenAndUnreadOnesDoNot() {
        let items = Self.build([
            Self.thread("read"),
            Self.thread("unread", visited: false),
            Self.thread("open", ago: 30),
        ], SidebarListOptions(selectedThreadID: "open"))
        let rows = Dictionary(uniqueKeysWithValues: items.compactMap(\.thread).map { ($0.threadID, $0) })
        #expect(rows["read"]?.recedes == true)
        #expect(rows["unread"]?.recedes == false)
        #expect(rows["unread"]?.status == .done)
        #expect(rows["open"]?.recedes == false)
        #expect(rows["open"]?.isSelected == true)
    }

    @Test func theDiffStatComesFromTheLastReadyCheckpoint() {
        let ready = TurnCheckpoint(ref: "r", status: .ready, files: [
            ChangedFileStat(path: "a", additions: 18, deletions: 6),
            ChangedFileStat(path: "b", additions: 1200, deletions: 0),
        ])
        let items = Self.build([
            Self.thread("diff", checkpoint: ready),
            Self.thread("missing", checkpoint: TurnCheckpoint(ref: "r", status: .missing)),
        ])
        let rows = Dictionary(uniqueKeysWithValues: items.compactMap(\.thread).map { ($0.threadID, $0) })
        #expect(rows["diff"]?.diff == SidebarThreadRow.DiffStat(additions: 1218, deletions: 6))
        #expect(rows["missing"]?.diff == nil)
        #expect(rows["missing"]?.hasMetaLine == false)
        #expect(DiffCountText.format(1218) == "1.2k")
        #expect(DiffCountText.format(999) == "999")
        #expect(DiffCountText.format(12_500) == "12k")
    }

    @Test func settledRowsShowWhenTheyWereSettled() {
        let row = SidebarListModel.build(
            threads: [Self.thread("s", ago: 86400 * 3, settled: true)],
            projects: [Self.app],
            options: SidebarListOptions(expandedShelves: [.settled])
        ).compactMap(\.thread).first
        #expect(row.map { DurationText.relative($0.timestamp, now: Self.now) } == "2d")
    }

    @Test func projectMonogramsFollowT3Code() {
        #expect(ProjectIdentity.monogram("app") == "AP")
        #expect(ProjectIdentity.monogram("soprano") == "SO")
        #expect(ProjectIdentity.monogram("t3code") == "T3")
        #expect(ProjectIdentity.monogram("my project") == "MP")
        #expect(ProjectIdentity.monogram("  ") == "PR")
        #expect(ProjectIdentity.colorIndex("app") == ProjectIdentity.colorIndex("APP"))
        #expect((0..<18).contains(ProjectIdentity.colorIndex("soprano-agents")))
    }
}
