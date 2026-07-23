import AppKit
import Testing
@testable import Soprano

struct TerminalInputMetadataTests {
    @Test func editSelectorsMapToExactGhosttyBindingActions() {
        #expect(TerminalResponderAction.bindingAction(
            for: #selector(NSText.copy(_:))
        ) == "copy_to_clipboard")
        #expect(TerminalResponderAction.bindingAction(
            for: #selector(NSText.paste(_:))
        ) == "paste_from_clipboard")
        #expect(TerminalResponderAction.bindingAction(
            for: #selector(NSText.selectAll(_:))
        ) == "select_all")
        #expect(TerminalResponderAction.bindingAction(
            for: #selector(NSText.cut(_:))
        ) == nil)
    }

    @Test func unhandledCommandEquivalentDeliversExactlyOnePressAndRelease() {
        var router = TerminalKeyEquivalentRouter()
        let timestamp = 42.5
        let keyCode: UInt16 = 47
        var pressCount = 0
        var releaseCount = 0

        #expect(router.routeKeyEquivalent(
            timestamp: timestamp,
            hasCommandOrControlModifier: true,
            isTerminalBinding: false,
            menuHandled: false
        ) == .passThrough)
        #expect(router.shouldRedispatchCommand(timestamp: timestamp))

        if router.routeKeyEquivalent(
            timestamp: timestamp,
            hasCommandOrControlModifier: true,
            isTerminalBinding: false,
            menuHandled: false
        ) == .deliverPress {
            router.prepareForKeyDown()
            router.recordCommandPress(keyCode: keyCode)
            pressCount += 1
        }

        if router.routeKeyEquivalent(
            timestamp: timestamp,
            hasCommandOrControlModifier: true,
            isTerminalBinding: false,
            menuHandled: false
        ) == .deliverPress {
            pressCount += 1
        }
        if router.consumeCommandRelease(keyCode: keyCode) {
            releaseCount += 1
        }
        if router.consumeCommandRelease(keyCode: keyCode) {
            releaseCount += 1
        }

        #expect(pressCount == 1)
        #expect(releaseCount == 1)
        #expect(!router.shouldRedispatchCommand(timestamp: timestamp))
    }

    @Test func menuHandledEquivalentIsNotRedispatchedOrReleasedToTerminal() {
        var router = TerminalKeyEquivalentRouter()
        let timestamp = 73.25

        #expect(router.routeKeyEquivalent(
            timestamp: timestamp,
            hasCommandOrControlModifier: true,
            isTerminalBinding: true,
            menuHandled: true
        ) == .handled)
        #expect(!router.shouldRedispatchCommand(timestamp: timestamp))
        let releasedToTerminal = router.consumeCommandRelease(keyCode: 8)
        #expect(!releasedToTerminal)
    }

    @Test func zeroTimestampEquivalentIsNeverTrackedForRedispatch() {
        var router = TerminalKeyEquivalentRouter()

        #expect(router.routeKeyEquivalent(
            timestamp: 0,
            hasCommandOrControlModifier: true,
            isTerminalBinding: false,
            menuHandled: false
        ) == .passThrough)
        #expect(!router.shouldRedispatchCommand(timestamp: 0))
    }

    @Test func scrollMetadataKeepsPrecisionAndMomentumInTheirDedicatedBits() {
        #expect(TerminalInputMetadata.scrollFlags(
            precise: false,
            momentum: .none
        ) == 0b0000)
        #expect(TerminalInputMetadata.scrollFlags(
            precise: true,
            momentum: .changed
        ) == 0b0111)
        #expect(TerminalInputMetadata.scrollFlags(
            precise: false,
            momentum: .mayBegin
        ) == 0b1100)
    }

    @Test func preciseScrollDeltasAreDoubledWhileDiscreteDeltasAreUnchanged() {
        let discrete = TerminalInputMetadata.scrollDeltas(
            x: 1.25,
            y: -2.5,
            precise: false
        )
        #expect(discrete.x == 1.25)
        #expect(discrete.y == -2.5)

        let precise = TerminalInputMetadata.scrollDeltas(
            x: 1.25,
            y: -2.5,
            precise: true
        )
        #expect(precise.x == 2.5)
        #expect(precise.y == -5)
    }

    @Test func leftModifierTransitionsReportPressAndRelease() {
        #expect(TerminalInputMetadata.modifierTransition(
            keyCode: 0x38,
            modifiers: [.shift],
            deviceModifiers: [.shiftLeft]
        ) == .press)
        #expect(TerminalInputMetadata.modifierTransition(
            keyCode: 0x38,
            modifiers: [],
            deviceModifiers: []
        ) == .release)
    }

    @Test func rightModifierTransitionsUseTheRightSideState() {
        #expect(TerminalInputMetadata.modifierTransition(
            keyCode: 0x3D,
            modifiers: [.option, .optionRight],
            deviceModifiers: [.optionRight]
        ) == .press)
        #expect(TerminalInputMetadata.modifierTransition(
            keyCode: 0x3D,
            modifiers: [.option],
            deviceModifiers: [.optionLeft]
        ) == .release)
    }

    @Test func everySupportedRightModifierReportsPressAndRelease() {
        let cases: [
            (
                keyCode: UInt16,
                pressedModifiers: TerminalModifierFlags,
                releasedModifiers: TerminalModifierFlags,
                right: TerminalModifierDeviceFlags,
                left: TerminalModifierDeviceFlags
            )
        ] = [
            (0x3C, [.shift, .shiftRight], [.shift], .shiftRight, .shiftLeft),
            (0x3E, [.control, .controlRight], [.control], .controlRight, .controlLeft),
            (0x3D, [.option, .optionRight], [.option], .optionRight, .optionLeft),
            (0x36, [.command, .commandRight], [.command], .commandRight, .commandLeft),
        ]

        for testCase in cases {
            #expect(TerminalInputMetadata.modifierTransition(
                keyCode: testCase.keyCode,
                modifiers: testCase.pressedModifiers,
                deviceModifiers: testCase.right
            ) == .press)
            #expect(TerminalInputMetadata.modifierTransition(
                keyCode: testCase.keyCode,
                modifiers: testCase.releasedModifiers,
                deviceModifiers: testCase.left
            ) == .release)
        }
    }

    @Test func releasingLeftModifierWhileRightRemainsHeldReportsRelease() {
        let cases: [
            (
                keyCode: UInt16,
                modifiers: TerminalModifierFlags,
                left: TerminalModifierDeviceFlags,
                right: TerminalModifierDeviceFlags
            )
        ] = [
            (0x38, [.shift, .shiftRight], .shiftLeft, .shiftRight),
            (0x3B, [.control, .controlRight], .controlLeft, .controlRight),
            (0x3A, [.option, .optionRight], .optionLeft, .optionRight),
            (0x37, [.command, .commandRight], .commandLeft, .commandRight),
        ]

        for testCase in cases {
            #expect(TerminalInputMetadata.modifierTransition(
                keyCode: testCase.keyCode,
                modifiers: testCase.modifiers,
                deviceModifiers: testCase.left
            ) == .press)
            #expect(TerminalInputMetadata.modifierTransition(
                keyCode: testCase.keyCode,
                modifiers: testCase.modifiers,
                deviceModifiers: testCase.right
            ) == .release)
        }
    }

    @Test func capsLockTransitionUsesItsAggregateToggleState() {
        #expect(TerminalInputMetadata.modifierTransition(
            keyCode: 0x39,
            modifiers: [.capsLock],
            deviceModifiers: []
        ) == .press)
        #expect(TerminalInputMetadata.modifierTransition(
            keyCode: 0x39,
            modifiers: [],
            deviceModifiers: []
        ) == .release)
    }
}
