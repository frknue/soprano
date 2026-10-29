import AppKit
import Testing
@testable import Soprano

/// An automation run completes when its agent's turn ends but waits when the
/// agent asks something, so the hook bridge must tell the two apart, and a
/// run's agent must get its prompt exactly once.
struct AgentWaitingReasonTests {
    private let environment = [
        "SOPRANO_APP_PID": "4242",
        "SOPRANO_PANE_ID": "pane-1",
        "SOPRANO_TAB_ID": "tab-2",
    ]

    private func userInfo(_ arguments: [String], standardInput: String? = nil) -> [String: String]? {
        AgentEventCommand.notificationEnvelope(
            arguments: arguments,
            environment: environment,
            standardInput: { standardInput.map { Data($0.utf8) } }
        )?.userInfo
    }

    @Test func anExplicitReasonFromTheOmpExtensionIsForwarded() {
        let info = userInfo(["soprano", "agent-event", "needs-input", "--notify", "--reason", "question"])

        #expect(info?["reason"] == "question")
    }

    @Test func claudeCodesNotificationTypesTellApprovalsAndQuestionsFromAFinishedTurn() {
        let cases: [(String, String)] = [
            (#"{"hook_event_name":"Notification","notification_type":"permission_prompt"}"#, "approval"),
            (#"{"hook_event_name":"Notification","notification_type":"elicitation_dialog"}"#, "question"),
            (#"{"hook_event_name":"Stop","session_id":"abc"}"#, "turn"),
        ]
        for (payload, reason) in cases {
            let info = userInfo(["soprano", "agent-event", "needs-input", "--message-from-stdin"], standardInput: payload)
            #expect(info?["reason"] == reason)
        }
    }

    @Test func codexsTurnNotificationIsAFinishedTurn() {
        let payload = #"{"type":"agent-turn-complete","last-assistant-message":"Done."}"#

        #expect(userInfo(["soprano", "agent-event", "needs-input", payload])?["reason"] == "turn")
    }

    @Test func onlyNeedsInputEventsCarryAReason() {
        #expect(userInfo(["soprano", "agent-event", "running", "--reason", "question"])?["reason"] == nil)
    }

    @Test func theAgentsWholeMessageTravelsBesideTheOneLineBanner() {
        let reply = "## Findings\n\n" + String(repeating: "A long paragraph. ", count: 40)
        let payload = "{\"message\":\(String(decoding: try! JSONEncoder().encode(reply), as: UTF8.self))}"

        let info = userInfo(["soprano", "agent-event", "needs-input", "--message-json", payload])

        #expect(info?["message"] == reply.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(info?["body"]?.hasSuffix("…") == true)
    }

    @Test func aPromptThatStartsLikeAnOptionIsPassedAfterTheEndOfOptions() {
        let launch = AgentLaunch(prompt: "- check the PRs\n- report", model: "opus", skipsApprovals: true)

        #expect(
            TerminalConfig.launchArguments(profileId: "claude-code", launch: launch, includingPrompt: true)
                == ["--model", "opus", "--dangerously-skip-permissions", "--", "- check the PRs\n- report"]
        )
        #expect(
            TerminalConfig.launchArguments(profileId: "omp", launch: launch, includingPrompt: true)
                == ["--model=opus", "--auto-approve", "--", "- check the PRs\n- report"]
        )
        #expect(
            TerminalConfig.launchArguments(profileId: "opencode", launch: launch, includingPrompt: true)
                == ["--auto", "--prompt=- check the PRs\n- report"]
        )
    }

    @Test func aResumedRunKeepsItsAutonomyButIsNotGivenItsPromptAgain() {
        let launch = AgentLaunch(prompt: "Audit the repo.", model: nil, skipsApprovals: true)
        let resumed = TerminalConfig.forAgent(
            DefaultAgents.codex,
            paneId: "pane-1",
            tabId: "tab-2",
            conversation: AgentConversation(id: "0199a1b2-c3d4", cwd: "/tmp"),
            launch: launch,
            loginShell: "/bin/zsh"
        )

        let command = resumed.command ?? ""
        #expect(command.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(command.contains("resume"))
        #expect(!command.contains("Audit the repo."))
    }
}
