import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

struct ComposerHistoryTests {
    private let model = ModelSelection.default(for: .omp)

    @Test func entriesAreTheThreadsUserMessagesAndSteersOldestFirst() {
        let thread = AgentThread(projectID: nil, modelSelection: model, turns: [
            Turn(ordinal: 1, userMessage: UserMessage(text: "first"), modelSelection: model, status: .completed,
                 steers: [UserMessage(text: "steer into first", isSteer: true)]),
            Turn(ordinal: 2, userMessage: UserMessage(text: "  "), modelSelection: model, status: .completed),
            Turn(ordinal: 3, userMessage: UserMessage(text: "latest"), modelSelection: model, status: .completed),
        ])
        #expect(ComposerHistory.entries(of: thread) == ["first", "steer into first", "latest"])
        #expect(ComposerHistory.entries(of: nil).isEmpty)
    }

    @Test func upWalksBackFromTheNewestMessageAndStopsAtTheOldest() {
        var history = ComposerHistory(entries: ["one", "two", "three"])
        #expect(history.older() == "three")
        #expect(history.older() == "two")
        #expect(history.older() == "one")
        #expect(history.older() == nil)
        #expect(history.current == "one")
    }

    @Test func downWalksForwardAndLeavesHistoryWithAnEmptyEditor() {
        var history = ComposerHistory(entries: ["one", "two"])
        _ = history.older()
        _ = history.older()
        #expect(history.newer() == "two")
        #expect(history.newer() == "")
        #expect(history.current == nil)
        #expect(history.newer() == nil)
    }

    @Test func aThreadWithoutMessagesRecallsNothing() {
        var history = ComposerHistory(entries: [])
        #expect(history.older() == nil)
        #expect(history.position == nil)
    }
}
