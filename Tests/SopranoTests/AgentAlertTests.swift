import AppKit
import Testing
@testable import Soprano

/// An agent banner reads like Soprano Agents' thread alerts: a short status
/// title over one line naming the conversation.
struct AgentAlertTests {
    @Test func eachWaitingReasonGetsItsOwnShortStatusTitle() {
        #expect(AgentAlert(state: .needsInput, reason: .turnEnded)?.title(agentName: "Claude Code") == "Claude Code finished")
        #expect(AgentAlert(state: .needsInput, reason: .approval)?.title(agentName: "Codex") == "Codex needs approval")
        #expect(AgentAlert(state: .needsInput, reason: .question)?.title(agentName: "omp") == "omp needs input")
        #expect(AgentAlert(state: .error, reason: nil)?.title(agentName: "OpenCode") == "OpenCode failed")
        #expect(AgentAlert(state: .ready, reason: nil) == .completed)
    }

    @Test func aNeedsInputEventThatDoesNotSayWhyReadsAsAQuestion() {
        #expect(AgentAlert(state: .needsInput, reason: nil) == .input)
    }

    @Test func runningAndStoppedEventsNeverMakeABanner() {
        #expect(AgentAlert(state: .running, reason: nil) == nil)
        #expect(AgentAlert(state: .stopped, reason: nil) == nil)
    }

    @Test func theBodyIsTheTabTitleWithoutTheAgentsSpinnerOrStatusGlyph() {
        #expect(AgentAlert.body(
            agentName: "Claude Code", tabTitle: "✳ Fix notification layout",
            windowTitle: "Terminal 1", sessionName: "Default"
        ) == "Fix notification layout")
        #expect(AgentAlert.body(
            agentName: "Claude Code", tabTitle: "⠐ Refactor sidebar",
            windowTitle: "Terminal 1", sessionName: "Default"
        ) == "Refactor sidebar")
        #expect(AgentAlert.strippingStatusGlyphs("~/git/soprano") == "~/git/soprano")
    }

    @Test func aTabStillNamedAfterTheAgentFallsBackToTheWindowThenTheSession() {
        #expect(AgentAlert.body(
            agentName: "Codex", tabTitle: "Codex", windowTitle: "Build", sessionName: "Default"
        ) == "Build")
        #expect(AgentAlert.body(
            agentName: "Codex", tabTitle: "✳", windowTitle: "", sessionName: "Default"
        ) == "Default")
        #expect(AgentAlert.body(
            agentName: "Codex", tabTitle: nil, windowTitle: nil, sessionName: nil
        ) == "Codex")
    }
}
