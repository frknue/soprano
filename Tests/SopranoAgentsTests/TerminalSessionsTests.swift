import AppKit
import Testing
@testable import SopranoAgents

@MainActor
struct TerminalSessionsTests {
    private func makeSessions() -> TerminalSessions {
        var counter = 0
        return TerminalSessions {
            counter += 1
            return "s\(counter)"
        }
    }

    @Test func eachThreadKeepsItsOwnNumberedTerminals() {
        var sessions = makeSessions()
        sessions.add(to: "a")
        sessions.add(to: "b")
        sessions.add(to: "a")
        #expect(sessions.sessions(for: "a").map(\.title) == ["Terminal 1", "Terminal 2"])
        #expect(sessions.sessions(for: "b").map(\.title) == ["Terminal 1"])
        #expect(sessions.activeSession(for: "a")?.id == "s3")
        #expect(sessions.sessions(for: "c").isEmpty)
        #expect(sessions.activeSession(for: "c") == nil)
    }

    @Test func numbersAreNotReusedAfterClosing() {
        var sessions = makeSessions()
        let first = sessions.add(to: "a")
        sessions.add(to: "a")
        sessions.close(first.id, in: "a")
        let next = sessions.add(to: "a")
        #expect(next.title == "Terminal 3")
    }

    @Test func closingTheActiveTerminalActivatesItsNeighbour() {
        var sessions = makeSessions()
        let one = sessions.add(to: "a")
        let two = sessions.add(to: "a")
        let three = sessions.add(to: "a")
        sessions.select(two.id, in: "a")
        let closedTwo = sessions.close(two.id, in: "a")
        #expect(closedTwo)
        #expect(sessions.activeSession(for: "a") == three)
        let closedThree = sessions.close(three.id, in: "a")
        #expect(closedThree)
        #expect(sessions.activeSession(for: "a") == one)
        let closedAgain = sessions.close(three.id, in: "a")
        #expect(!closedAgain)
        let closedOne = sessions.close(one.id, in: "a")
        #expect(closedOne)
        #expect(sessions.activeSession(for: "a") == nil)
        #expect(!sessions.keys.contains("a"))
    }

    @Test func selectingAnotherThreadsTerminalIsIgnored() {
        var sessions = makeSessions()
        let mine = sessions.add(to: "a")
        let theirs = sessions.add(to: "b")
        sessions.select(theirs.id, in: "a")
        #expect(sessions.activeSession(for: "a") == mine)
    }

    @Test func deletedThreadsGiveUpTheirTerminalsForTeardown() {
        var sessions = makeSessions()
        let kept = sessions.add(to: "a")
        let gone = [sessions.add(to: "b"), sessions.add(to: "b")]
        let removed = sessions.prune(keeping: ["a"])
        #expect(Set(removed.map(\.info.id)) == Set(gone.map(\.id)))
        #expect(removed.allSatisfy { $0.key == "b" })
        #expect(sessions.sessions(for: "a") == [kept])
        #expect(sessions.sessions(for: "b").isEmpty)
        let all = sessions.removeAll()
        #expect(all.map(\.id) == [kept.id])
        #expect(sessions.keys.isEmpty)
    }

    @Test func numbersAreSharedAcrossPlacementsOfAThread() {
        var sessions = makeSessions()
        let drawer = sessions.add(to: "a", placement: .drawer)
        let panel = sessions.add(to: "a", placement: .panel)
        #expect(drawer.title == "Terminal 1")
        #expect(panel.title == "Terminal 2")
        #expect(sessions.locate(panel.id)?.placement == .panel)
    }

    @Test func eachPlacementListsAndActivatesOnlyItsOwnTerminals() {
        var sessions = makeSessions()
        let drawer = sessions.add(to: "a", placement: .drawer)
        let panel = sessions.add(to: "a", placement: .panel)
        #expect(sessions.sessions(for: "a", placement: .drawer) == [drawer])
        #expect(sessions.activeSession(for: "a", placement: .drawer) == drawer)
        #expect(sessions.activeSession(for: "a", placement: .panel) == panel)
        sessions.close(drawer.id, in: "a")
        #expect(sessions.activeSession(for: "a", placement: .drawer) == nil)
        #expect(sessions.activeSession(for: "a", placement: .panel) == panel)
    }
}
