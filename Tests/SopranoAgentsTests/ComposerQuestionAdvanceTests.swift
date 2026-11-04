import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

@MainActor
struct ComposerQuestionAdvanceTests {
    private static func option(_ label: String) -> UserInputOption {
        UserInputOption(label: label, description: nil)
    }

    private static func thread(_ title: String, in engine: AgentEngine, first: UserInputQuestion, second: UserInputQuestion) -> String {
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let selection = ModelSelection.default(for: .omp)
        let request = UserInputRequest(id: "\(title)-input", questions: [first, second])
        let turn = Turn(
            ordinal: 1,
            userMessage: UserMessage(text: "go"),
            modelSelection: selection,
            items: [TurnItem(id: "\(title)-item", kind: .userInput(request))]
        )
        let thread = AgentThread(projectID: project.id, title: title, modelSelection: selection, turns: [turn])
        engine.insertThread(thread)
        return thread.id
    }

    private static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + views(type, in: $0) }
    }

    private static func shows(_ text: String, in root: NSView) -> Bool {
        views(NSTextField.self, in: root).contains { $0.stringValue == text && !$0.isHiddenOrHasHiddenAncestor }
    }

    @Test func aPendingAutoAdvanceDoesNotMoveTheQuestionsOfAThreadSelectedMeanwhile() async throws {
        let engine = EngineHarness.engine()
        let single = UserInputQuestion(id: "a1", header: "A", question: "Pick one for A", options: [Self.option("x"), Self.option("y")])
        let threadA = Self.thread("A", in: engine, first: single, second: UserInputQuestion(id: "a2", header: "A", question: "Second for A", options: [Self.option("z")]))
        let multiple = UserInputQuestion(id: "b1", header: "B", question: "Pick any for B", options: [Self.option("p"), Self.option("q")], allowsMultiple: true)
        let threadB = Self.thread("B", in: engine, first: multiple, second: UserInputQuestion(id: "b2", header: "B", question: "Second for B", options: [Self.option("r")]))
        let state = WorkspaceState()
        state.select(.thread(threadB))
        let composer = ComposerViewController(engine: engine, state: state)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = composer
        defer { window.close() }
        let panel = try #require(Self.views(ComposerQuestionPanel.self, in: composer.view).first)

        // B's first question is answered (multiple choice: no auto-advance), then A's single
        // choice starts its 200 ms auto-advance and B is selected again before it fires.
        #expect(Self.shows("Pick any for B", in: composer.view))
        panel.onToggleOption?(0)
        state.select(.thread(threadA))
        #expect(Self.shows("Pick one for A", in: composer.view))
        panel.onToggleOption?(0)
        state.select(.thread(threadB))

        try await Task.sleep(for: .milliseconds(500))
        #expect(Self.shows("Pick any for B", in: composer.view))
        #expect(!Self.shows("Second for B", in: composer.view))
    }
}
