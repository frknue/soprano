import Testing
@testable import Soprano

struct ExternalEventRoutingTests {
    @Test func agentEventsUseTheOwningProcessNotificationName() {
        #expect(
            AgentEventCommand.notificationName(appProcessId: "4242").rawValue
                == "com.soprano.agent-event.4242"
        )
    }

    @Test func agentEventEnvelopeCarriesTheExactTerminalTarget() {
        let envelope = AgentEventCommand.notificationEnvelope(
            arguments: ["soprano", "agent-event", "needs-input", "--notify"],
            environment: [
                "SOPRANO_APP_PID": "4242",
                "SOPRANO_PANE_ID": "pane-1",
                "SOPRANO_TAB_ID": "tab-2",
            ]
        )

        #expect(envelope?.name.rawValue == "com.soprano.agent-event.4242")
        #expect(envelope?.userInfo == [
            "paneId": "pane-1",
            "tabId": "tab-2",
            "state": "needs-input",
            "notify": "1",
            "title": "Agent",
            "body": "Input required",
        ])
    }

    @Test func agentEventWithoutAProcessOrTerminalIdentityBuildsNoEnvelope() {
        #expect(AgentEventCommand.notificationEnvelope(
            arguments: ["soprano", "agent-event", "ready"],
            environment: [
                "SOPRANO_PANE_ID": "pane-1",
                "SOPRANO_TAB_ID": "tab-2",
            ]
        ) == nil)
        #expect(AgentEventCommand.notificationEnvelope(
            arguments: ["soprano", "agent-event", "ready"],
            environment: [
                "SOPRANO_APP_PID": "4242",
                "SOPRANO_PANE_ID": "pane-1",
            ]
        ) == nil)
    }

    @Test func navigationAndPassthroughEnvelopesCarryTheExactTerminalTarget() {
        let environment = [
            "SOPRANO_APP_PID": "4242",
            "SOPRANO_PANE_ID": "pane-1",
            "SOPRANO_TAB_ID": "tab-2",
        ]

        let navigation = PaneNavigationCommand.notificationEnvelope(
            arguments: ["soprano", "navigate-pane", "left"],
            environment: environment
        )
        let passthrough = PaneNavigationCommand.notificationEnvelope(
            arguments: ["soprano", "navigation-passthrough", "enable", "nvim"],
            environment: environment
        )

        #expect(navigation?.name == PaneNavigationCommand.notificationName(appProcessId: "4242"))
        #expect(navigation?.userInfo == [
            "paneId": "pane-1",
            "tabId": "tab-2",
            "direction": "left",
        ])
        #expect(passthrough?.userInfo == [
            "paneId": "pane-1",
            "tabId": "tab-2",
            "passthrough": "enable",
            "source": "nvim",
        ])
    }

    @Test func navigationWithoutAProcessOrTerminalIdentityBuildsNoEnvelope() {
        #expect(PaneNavigationCommand.notificationEnvelope(
            arguments: ["soprano", "navigate-pane", "left"],
            environment: [
                "SOPRANO_APP_PID": "4242",
                "SOPRANO_PANE_ID": "pane-1",
            ]
        ) == nil)
        #expect(PaneNavigationCommand.notificationEnvelope(
            arguments: ["soprano", "navigation-passthrough", "enable", "nvim"],
            environment: [
                "SOPRANO_PANE_ID": "pane-1",
                "SOPRANO_TAB_ID": "tab-2",
            ]
        ) == nil)
    }

    @Test func navigationWithMissingIdentityDoesNotInvokeTmux() {
        var tmuxNavigatorCalls = 0

        let handled = PaneNavigationCommand.handle(
            arguments: ["soprano", "navigate-pane", "left"],
            environment: ["TMUX": "/tmp/tmux-123/default,1,0"]
        ) { _, _ in
            tmuxNavigatorCalls += 1
            return false
        }

        #expect(handled)
        #expect(tmuxNavigatorCalls == 0)
    }
}
