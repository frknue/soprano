import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

@MainActor
struct ThreadNotifierTests {
    private final class Recorder: ThreadNotificationPosting {
        var posted: [(threadID: String, alert: ThreadAlert, body: String, sound: Bool)] = []
        func post(threadID: String, alert: ThreadAlert, body: String, sound: Bool) {
            posted.append((threadID, alert, body, sound))
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let model = ModelSelection(provider: .omp, model: "openai-codex/gpt-6.1-sol")

    private func runningThread(_ id: String, title: String) -> AgentThread {
        AgentThread(
            id: id, projectID: nil, title: title, createdAt: now.addingTimeInterval(-600), modelSelection: model,
            lastVisitedAt: now.addingTimeInterval(-300),
            turns: [Turn(id: "\(id)-turn", ordinal: 1, userMessage: UserMessage(text: "Go", createdAt: now.addingTimeInterval(-120)),
                         modelSelection: model, status: .running, startedAt: now.addingTimeInterval(-120))]
        )
    }

    private func engine(_ threads: [AgentThread]) -> AgentEngine {
        AgentEngine(environment: EngineEnvironment(
            drivers: [:],
            git: FixtureGitService(),
            store: InMemoryThreadStore(StoreSnapshot(threads: threads)),
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("sa-notifier"),
            now: { [now] in now }
        ))
    }

    private func finish(_ engine: AgentEngine, _ id: String, _ status: TurnStatus) {
        engine.updateThread(id) { thread in
            thread.turns[0].status = status
            thread.turns[0].completedAt = now
        }
    }

    private func requestApproval(_ engine: AgentEngine, _ id: String) {
        engine.updateThread(id) { thread in
            thread.turns[0].items.append(TurnItem(id: "approval", kind: .approval(ApprovalRequest(id: "a1", kind: .command, detail: "rm -rf build"))))
        }
    }

    @Test func aThreadFinishingInTheBackgroundPostsThreadCompletedWithItsTitle() {
        let engine = engine([runningThread("t1", title: "Fix login")])
        let recorder = Recorder()
        var badges: [Int] = []
        let notifier = ThreadNotifier(engine: engine, settings: { .defaults }, isWatching: { false }, poster: recorder, setBadge: { badges.append($0) })

        finish(engine, "t1", .completed)

        #expect(recorder.posted.map(\.alert) == [.completed])
        #expect(recorder.posted.first?.body == "Fix login")
        #expect(recorder.posted.first?.sound == true)
        #expect(ThreadAlert.completed.title == "Thread completed")
        #expect(notifier.badgeCount == 1)
        #expect(badges == [1])
    }

    @Test func failuresApprovalsAndQuestionsPostTheirOwnTitles() {
        let engine = engine([runningThread("t1", title: "A"), runningThread("t2", title: "B")])
        let recorder = Recorder()
        let notifier = ThreadNotifier(engine: engine, settings: { .defaults }, isWatching: { false }, poster: recorder, setBadge: { _ in })

        requestApproval(engine, "t1")
        finish(engine, "t2", .failed)

        #expect(recorder.posted.map(\.alert) == [.approval, .failed])
        #expect(recorder.posted.map { $0.alert.title } == ["Approval needed", "Thread failed"])
        #expect(ThreadAlert.input.title == "Input needed")
        #expect(notifier.badgeCount == 2)
    }

    @Test func nothingIsPostedWhileTheAgentsWindowIsWatchedOrNotificationsAreOff() {
        let engine = engine([runningThread("t1", title: "A"), runningThread("t2", title: "B")])
        let recorder = Recorder()
        var active = true
        var settings = AgentsSettings.defaults
        let notifier = ThreadNotifier(engine: engine, settings: { settings }, isWatching: { active }, poster: recorder, setBadge: { _ in })

        finish(engine, "t1", .completed)
        active = false
        settings.notificationsEnabled = false
        finish(engine, "t2", .completed)

        #expect(recorder.posted.isEmpty)
        // The Dock badge still counts both unread completions.
        #expect(notifier.badgeCount == 2)
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func anApprovalArrivingWhileSopranosTerminalWindowIsKeyStillNotifies() {
        let agentsWindow = Self.window()
        let terminalWindow = Self.window()
        let engine = engine([runningThread("t1", title: "Deploy check")])
        let recorder = Recorder()
        let notifier = ThreadNotifier(engine: engine, settings: { .defaults }, isWatching: {
            AgentsAppController.isWatching(agentsWindow: agentsWindow, keyWindow: terminalWindow, isActive: true)
        }, poster: recorder, setBadge: { _ in })

        requestApproval(engine, "t1")

        #expect(recorder.posted.map(\.alert) == [.approval])
        #expect(recorder.posted.first?.body == "Deploy check")
        #expect(notifier.badgeCount == 1)
    }

    @Test func onlyTheAgentsWindowOrAPanelHangingOffItCountsAsWatching() {
        let agentsWindow = Self.window()
        let palette = Self.window()
        agentsWindow.addChildWindow(palette, ordered: .above)
        defer { agentsWindow.removeChildWindow(palette) }

        #expect(AgentsAppController.isWatching(agentsWindow: agentsWindow, keyWindow: agentsWindow, isActive: true))
        #expect(AgentsAppController.isWatching(agentsWindow: agentsWindow, keyWindow: palette, isActive: true))
        #expect(!AgentsAppController.isWatching(agentsWindow: agentsWindow, keyWindow: Self.window(), isActive: true))
        #expect(!AgentsAppController.isWatching(agentsWindow: agentsWindow, keyWindow: agentsWindow, isActive: false))
        #expect(!AgentsAppController.isWatching(agentsWindow: agentsWindow, keyWindow: nil, isActive: true))
    }

    @Test func soundFollowsTheSetting() {
        let engine = engine([runningThread("t1", title: "A")])
        let recorder = Recorder()
        var settings = AgentsSettings.defaults
        settings.notificationSound = false
        let notifier = ThreadNotifier(engine: engine, settings: { settings }, isWatching: { false }, poster: recorder, setBadge: { _ in })

        finish(engine, "t1", .completed)

        #expect(recorder.posted.first?.sound == false)
        _ = notifier
    }

    @Test func threadsAlreadyDoneAtLaunchNeverNotifyButCountOnTheBadge() {
        var done = runningThread("t1", title: "Old")
        done.turns[0].status = .completed
        done.turns[0].completedAt = now.addingTimeInterval(-60)
        let engine = engine([done, runningThread("t2", title: "New")])
        let recorder = Recorder()
        var badges: [Int] = []
        let notifier = ThreadNotifier(engine: engine, settings: { .defaults }, isWatching: { false }, poster: recorder, setBadge: { badges.append($0) })

        engine.rename("t1", title: "Old, renamed")

        #expect(recorder.posted.isEmpty)
        #expect(notifier.badgeCount == 1)
        #expect(badges == [1])
    }

    @Test func visitingAThreadClearsItFromTheBadgeAndArchivedThreadsDoNotCount() {
        let engine = engine([runningThread("t1", title: "A"), runningThread("t2", title: "B")])
        var badges: [Int] = []
        let notifier = ThreadNotifier(engine: engine, settings: { .defaults }, isWatching: { true }, poster: nil, setBadge: { badges.append($0) })

        finish(engine, "t1", .completed)
        finish(engine, "t2", .failed)
        engine.markVisited("t1")
        engine.setArchived("t2", true)

        #expect(notifier.badgeCount == 0)
        #expect(badges == [1, 2, 1, 0])
    }

    @Test func settledThreadsLeaveTheBadgeUntilUnsettled() {
        var settledAtLaunch = runningThread("t1", title: "Settled earlier")
        settledAtLaunch.turns[0].status = .completed
        settledAtLaunch.turns[0].completedAt = now.addingTimeInterval(-60)
        settledAtLaunch.settledAt = now.addingTimeInterval(-30)
        let engine = engine([settledAtLaunch, runningThread("t2", title: "B")])
        var badges: [Int] = []
        let notifier = ThreadNotifier(engine: engine, settings: { .defaults }, isWatching: { true }, poster: nil, setBadge: { badges.append($0) })

        finish(engine, "t2", .completed)
        engine.setSettled("t2", true)
        engine.setSettled("t1", false)

        #expect(notifier.badgeCount == 1)
        #expect(badges == [1, 0, 1])
    }

    @Test func aSettledThreadWaitingOnApprovalStillCountsOnTheBadge() {
        let engine = engine([runningThread("t1", title: "A")])
        let notifier = ThreadNotifier(engine: engine, settings: { .defaults }, isWatching: { true }, poster: nil, setBadge: { _ in })

        engine.setSettled("t1", true)
        requestApproval(engine, "t1")

        #expect(notifier.badgeCount == 1)
    }

    @Test func aPinnedThreadCountsEvenWhenAlsoSettled() {
        let engine = engine([runningThread("t1", title: "A")])
        let notifier = ThreadNotifier(engine: engine, settings: { .defaults }, isWatching: { true }, poster: nil, setBadge: { _ in })

        finish(engine, "t1", .completed)
        engine.setSettled("t1", true)
        engine.setPinned("t1", true)

        #expect(notifier.badgeCount == 1)
    }

    @Test func theSameAlertIsNotPostedTwice() {
        let engine = engine([runningThread("t1", title: "A")])
        let recorder = Recorder()
        let notifier = ThreadNotifier(engine: engine, settings: { .defaults }, isWatching: { false }, poster: recorder, setBadge: { _ in })

        finish(engine, "t1", .completed)
        engine.rename("t1", title: "A2")

        #expect(recorder.posted.count == 1)
        _ = notifier
    }
}
