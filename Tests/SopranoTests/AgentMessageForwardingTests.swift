import AppKit
import Testing
@testable import Soprano

/// The banner exists to say what an agent is asking, not that it asked
/// something. Each agent hands the payload over differently — Claude Code pipes
/// JSON to the hook, Codex appends it as a trailing argument, OpenCode passes it
/// through `--message-json` — so each route is covered here.
struct AgentMessageForwardingTests {
    private let environment = [
        "SOPRANO_APP_PID": "4242",
        "SOPRANO_PANE_ID": "pane-1",
        "SOPRANO_TAB_ID": "tab-2",
    ]

    private func body(
        arguments: [String],
        standardInput: String? = nil
    ) -> String? {
        AgentEventCommand.notificationEnvelope(
            arguments: arguments,
            environment: environment,
            standardInput: { standardInput.map { Data($0.utf8) } }
        )?.userInfo["body"]
    }

    @Test func claudeCodeHookPayloadOnStandardInputBecomesTheBody() {
        let payload = #"{"hook_event_name":"Notification","message":"Drop the legacy column? [y/n]"}"#

        #expect(
            body(
                arguments: [
                    "soprano", "agent-event", "needs-input",
                    "--notify", "--message-from-stdin", "--body", "Approval or input required",
                ],
                standardInput: payload
            ) == "Needs input — Drop the legacy column? [y/n]"
        )
    }

    @Test func codexAppendsItsPayloadAsATrailingArgumentAndItStillReachesTheBanner() {
        let payload = #"{"type":"agent-turn-complete","last-assistant-message":"Migration applied."}"#

        #expect(
            body(arguments: [
                "soprano", "agent-event", "needs-input",
                "--notify", "--title", "Codex", "--body", "Response ready",
                payload,
            ]) == "Needs input — Migration applied."
        )
    }

    @Test func openCodePassesItsEventPropertiesThroughMessageJson() {
        let payload = #"{"description":"Allow writing to Package.swift?"}"#

        #expect(
            body(arguments: [
                "soprano", "agent-event", "needs-input",
                "--notify", "--message-json", payload, "--body", "Approval required",
            ]) == "Needs input — Allow writing to Package.swift?"
        )
    }

    @Test func aNotificationTypeWithoutProseStillReadsAsSomethingHumanFacing() {
        let payload = #"{"notification_type":"idle_prompt","cwd":"/tmp"}"#

        #expect(
            body(
                arguments: ["soprano", "agent-event", "needs-input", "--notify", "--message-from-stdin"],
                standardInput: payload
            ) == "Needs input — Waiting for your next prompt"
        )
    }

    @Test func theStaticBodySurvivesWhenThePayloadCarriesNoReadableMessage() {
        #expect(
            body(
                arguments: [
                    "soprano", "agent-event", "needs-input",
                    "--notify", "--message-from-stdin", "--body", "Approval or input required",
                ],
                standardInput: #"{"session_id":"abc","cwd":"/tmp"}"#
            ) == "Approval or input required"
        )
    }

    @Test func aMissingOrUnparseablePayloadFallsBackRatherThanLosingTheNotification() {
        #expect(
            body(
                arguments: ["soprano", "agent-event", "error", "--notify", "--message-from-stdin"],
                standardInput: "not json at all"
            ) == "The agent stopped with an error"
        )
        #expect(
            body(
                arguments: ["soprano", "agent-event", "error", "--notify", "--message-from-stdin"],
                standardInput: nil
            ) == "The agent stopped with an error"
        )
    }

    @Test func multiLineAgentOutputCollapsesToASingleBannerLine() {
        #expect(
            AgentEventCommand.summarize("  Applied 3 files.\n\n  Ran   tests.\t Done.  ")
                == "Applied 3 files. Ran tests. Done."
        )
    }

    @Test func anUnboundedAgentMessageIsElidedRatherThanHandedToTheWindowServerWhole() {
        let long = String(repeating: "a", count: AgentEventCommand.messageLimit + 50)
        let summary = AgentEventCommand.summarize(long)

        #expect(summary?.count == AgentEventCommand.messageLimit + 1)
        #expect(summary?.hasSuffix("…") == true)
    }

    @Test func whitespaceOnlyOutputIsNotTreatedAsAMessage() {
        #expect(AgentEventCommand.summarize("   \n\t ") == nil)
        #expect(AgentEventCommand.agentMessage(fromPayload: #"{"message":"   "}"#) == nil)
    }

    @Test func everyStateCarriesTheLabelABannerPrefixesItsMessageWith() {
        #expect(AgentEventCommand.label(for: .needsInput) == "Needs input")
        #expect(AgentEventCommand.label(for: .error) == "Error")
        #expect(AgentEventCommand.label(for: .ready) == "Ready")
    }
}
