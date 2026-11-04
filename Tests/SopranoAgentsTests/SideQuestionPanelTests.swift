import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct SideQuestionPanelTests {
    private static func topic(_ questions: [String]) -> SideQuestion {
        let exchanges = questions.enumerated().map { index, question in
            SideQuestionExchange(question: question, answer: "a", status: .complete, createdAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        return SideQuestion(id: "t", first: exchanges[0], followUps: Array(exchanges.dropFirst()))
    }

    @Test func aFollowUpRepeatingTheLastQuestionStaysStoppableUntilItIsReported() {
        let panel = SideQuestionPanelContent(width: 600)
        let topic = Self.topic(["why?"])
        panel.update([topic], isLoading: false, isStarting: false)
        panel.select("t")

        panel.setPending("why?")
        // Any other change (a history read) arrives before omp reports the follow-up.
        panel.update([topic], isLoading: false, isStarting: false)
        #expect(panel.isAnswering)

        panel.update([Self.topic(["why?", "why?"])], isLoading: false, isStarting: false)
        #expect(!panel.isAnswering)
    }

    @Test func aQuestionStartingFromAnEarlierPanelCanBeStopped() {
        let panel = SideQuestionPanelContent(width: 600)
        var cancels = 0
        panel.onCancel = { cancels += 1 }
        panel.update([], isLoading: false, isStarting: true)

        #expect(panel.isAnswering)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        #expect(panel.handleKey(escape))
        #expect(cancels == 1)
    }
}
