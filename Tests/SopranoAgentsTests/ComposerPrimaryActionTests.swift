import AppKit
import Testing
@testable import Soprano
@testable import SopranoAgentsCore

struct ComposerPrimaryActionTests {
    @Test func anIdleThreadSendsWhenThereIsSomethingToSendAndIsDisabledOtherwise() {
        #expect(ComposerPrimaryAction.resolve(isRunning: false, hasContent: true, isAwaitingApproval: false, followUp: .steer, alternate: false) == .send)
        #expect(ComposerPrimaryAction.resolve(isRunning: false, hasContent: false, isAwaitingApproval: false, followUp: .steer, alternate: false) == .sendDisabled)
        #expect(ComposerPrimaryAction.resolve(isRunning: false, hasContent: true, isAwaitingApproval: false, followUp: .queue, alternate: true) == .send)
    }

    @Test func aRunningTurnWithAnEmptyComposerOffersStop() {
        #expect(ComposerPrimaryAction.resolve(isRunning: true, hasContent: false, isAwaitingApproval: false, followUp: .steer, alternate: false) == .stop)
        #expect(ComposerPrimaryAction.resolve(isRunning: true, hasContent: false, isAwaitingApproval: true, followUp: .queue, alternate: true) == .stop)
    }

    @Test func aRunningTurnFollowsTheFollowUpSettingAndCommandFlipsIt() {
        #expect(ComposerPrimaryAction.resolve(isRunning: true, hasContent: true, isAwaitingApproval: false, followUp: .steer, alternate: false) == .steer)
        #expect(ComposerPrimaryAction.resolve(isRunning: true, hasContent: true, isAwaitingApproval: false, followUp: .steer, alternate: true) == .queue)
        #expect(ComposerPrimaryAction.resolve(isRunning: true, hasContent: true, isAwaitingApproval: false, followUp: .queue, alternate: false) == .queue)
        #expect(ComposerPrimaryAction.resolve(isRunning: true, hasContent: true, isAwaitingApproval: false, followUp: .queue, alternate: true) == .steer)
    }

    @Test func textWhileAnApprovalWaitsIsAPlainSendThatDeclinesIt() {
        let action = ComposerPrimaryAction.resolve(isRunning: true, hasContent: true, isAwaitingApproval: true, followUp: .queue, alternate: false)
        #expect(action == .send)
        #expect(action.sendMode == .automatic)
    }

    @Test func steerAndQueueMapToTheirSendModesAndStopSendsNothing() {
        #expect(ComposerPrimaryAction.steer.sendMode == .steer)
        #expect(ComposerPrimaryAction.queue.sendMode == .queue)
        #expect(ComposerPrimaryAction.stop.sendMode == nil)
        #expect(ComposerPrimaryAction.sendDisabled.sendMode == nil)
    }

    @Test func theFollowUpTooltipNamesTheClickAndTheAlternate() {
        #expect(ComposerPrimaryAction.steer.tooltip(followUp: .steer) == "Click to steer, ⌘-click or ⌘↩ to queue")
        #expect(ComposerPrimaryAction.steer.tooltip(followUp: .queue) == "Click to queue, ⌘-click or ⌘↩ to steer")
        #expect(ComposerPrimaryAction.stop.tooltip(followUp: .steer) == "Interrupt")
    }
}
