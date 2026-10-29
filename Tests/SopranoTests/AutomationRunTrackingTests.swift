import AppKit
import Testing
@testable import Soprano

struct AutomationRunTrackingTests {
    private func run(status: AutomationRun.Status = .starting, sawWork: Bool = false) -> AutomationRun {
        var run = AutomationRun(
            id: "run-1",
            automationId: "audit",
            number: 1,
            trigger: .scheduled,
            startedAt: Date(),
            status: status,
            profileId: "omp",
            folder: "/tmp"
        )
        run.sawWork = sawWork
        return run
    }

    private func agent(
        _ status: AgentStatus,
        reason: AgentWaitingReason? = nil,
        message: String? = nil
    ) -> AutomationRunTracking.Observation {
        .init(tabExists: true, hasAgent: true, status: status, waitingReason: reason, message: message)
    }

    @Test func aFinishedTurnCompletesTheRunEvenWhenTheAgentNeverSaidItWasWorking() {
        // Codex without its hooks reports only the end of its turn.
        #expect(AutomationRunTracking.change(for: run(), observing: agent(.waiting, reason: .turnEnded)) == .completed)
    }

    @Test func theReadyAnAgentReportsWhenItComesUpDoesNotCompleteTheRun() {
        #expect(AutomationRunTracking.change(for: run(), observing: agent(.idle)) == nil)
    }

    @Test func readyMidRunDoesNotCompleteItBecauseOnlyAFinishedTurnDoes() {
        // Claude Code starts a session again after compacting its context
        // mid-turn; every CLI reports a finished turn as needs-input instead.
        let working = run(status: .running, sawWork: true)

        #expect(AutomationRunTracking.change(for: working, observing: agent(.idle)) == nil)
        #expect(AutomationRunTracking.change(for: working, observing: agent(.waiting, reason: .turnEnded)) == .completed)
    }

    @Test func anApprovalOrQuestionPutsTheRunOnHoldWithWhatTheAgentAsked() {
        let working = run(status: .running, sawWork: true)

        #expect(
            AutomationRunTracking.change(for: working, observing: agent(.waiting, reason: .question, message: "Which branch?"))
                == .needsInput(message: "Which branch?")
        )
        #expect(
            AutomationRunTracking.change(for: working, observing: agent(.waiting, reason: .approval))
                == .needsInput(message: nil)
        )
    }

    @Test func aRunAlreadyWaitingForAnAnswerIsNotAnnouncedAgain() {
        let waiting = run(status: .needsInput, sawWork: true)

        #expect(AutomationRunTracking.change(for: waiting, observing: agent(.waiting, reason: .question)) == nil)
    }

    @Test func workingAgainAfterAnAnswerMovesTheRunBackToRunning() {
        let waiting = run(status: .needsInput, sawWork: true)

        #expect(AutomationRunTracking.change(for: waiting, observing: agent(.running)) == .running)
    }

    @Test func closingTheRunsWindowFailsTheRun() {
        let observation = AutomationRunTracking.Observation(
            tabExists: false, hasAgent: false, status: nil, waitingReason: nil, message: nil
        )

        #expect(
            AutomationRunTracking.change(for: run(status: .running, sawWork: true), observing: observation)
                == .failed(message: "Its window was closed before the run finished.")
        )
    }

    @Test func anAgentThatExitsBeforeFinishingFailsTheRunSayingHowFarItGot() {
        let exited = AutomationRunTracking.Observation(
            tabExists: true, hasAgent: false, status: nil, waitingReason: nil, message: nil
        )

        #expect(
            AutomationRunTracking.change(for: run(), observing: exited)
                == .failed(message: "The agent exited before it started working.")
        )
        #expect(
            AutomationRunTracking.change(for: run(status: .running, sawWork: true), observing: exited)
                == .failed(message: "The agent exited before it finished its turn.")
        )
    }

    @Test func anAgentErrorFailsTheRunWithTheAgentsMessage() {
        #expect(
            AutomationRunTracking.change(for: run(status: .running, sawWork: true), observing: agent(.error, message: "Rate limited"))
                == .failed(message: "Rate limited")
        )
    }

    @Test func aFinishedRunIgnoresWhateverItsAgentDoesAfterwards() {
        let done = run(status: .completed, sawWork: true)

        #expect(AutomationRunTracking.change(for: done, observing: agent(.running)) == nil)
    }
}
