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

    @Test func unhandledCommandAndControlEquivalentsRedispatchTheirExactEventOnce() {
        let cases: [(modifiers: TerminalKeyEquivalentModifiers, keyCode: UInt16)] = [
            (.command, 47),
            (.control, 8),
        ]

        for testCase in cases {
            var router = TerminalKeyEquivalentRouter()
            let timestamp = 42.5

            let firstRoute = router.routeKeyEquivalent(
                timestamp: timestamp,
                keyCode: testCase.keyCode,
                modifiers: testCase.modifiers,
                isTerminalBinding: false,
                menuHandled: false
            )
            #expect(firstRoute == .passThrough)
            #expect(router.shouldRedispatchKeyEquivalent(
                timestamp: timestamp,
                keyCode: testCase.keyCode
            ))
            #expect(!router.shouldRedispatchKeyEquivalent(
                timestamp: timestamp,
                keyCode: testCase.keyCode + 1
            ))

            let secondRoute = router.routeKeyEquivalent(
                timestamp: timestamp,
                keyCode: testCase.keyCode,
                modifiers: testCase.modifiers,
                isTerminalBinding: false,
                menuHandled: false
            )
            #expect(secondRoute == .deliverPress)
            router.prepareForKeyDown(timestamp: timestamp, keyCode: testCase.keyCode)
            router.recordKeyDownDelivery(keyCode: testCase.keyCode)

            let duplicatePress = router.routeKeyEquivalent(
                timestamp: timestamp,
                keyCode: testCase.keyCode,
                modifiers: testCase.modifiers,
                isTerminalBinding: false,
                menuHandled: false
            )
            let release = router.routeKeyUp(keyCode: testCase.keyCode)
            let duplicateRelease = router.routeKeyUp(keyCode: testCase.keyCode)

            #expect(duplicatePress == .handled)
            #expect(release == .deliver)
            #expect(duplicateRelease == .suppress)
            #expect(!router.shouldRedispatchKeyEquivalent(
                timestamp: timestamp,
                keyCode: testCase.keyCode
            ))
        }
    }

    @Test func sameTimestampEquivalentKeyCodesRemainIndependent() {
        var router = TerminalKeyEquivalentRouter()
        let timestamp = 66.0

        let commandRoute = router.routeKeyEquivalent(
            timestamp: timestamp,
            keyCode: 47,
            modifiers: .command,
            isTerminalBinding: true,
            menuHandled: false
        )
        router.prepareForKeyDown(timestamp: timestamp, keyCode: 47)
        router.recordKeyDownDelivery(keyCode: 47)

        let controlRoute = router.routeKeyEquivalent(
            timestamp: timestamp,
            keyCode: 8,
            modifiers: .control,
            isTerminalBinding: true,
            menuHandled: false
        )
        router.prepareForKeyDown(timestamp: timestamp, keyCode: 8)
        router.recordKeyDownDelivery(keyCode: 8)

        #expect(commandRoute == .deliverPress)
        #expect(controlRoute == .deliverPress)
        #expect(router.routeKeyUp(keyCode: 47) == .deliver)
        #expect(router.routeKeyUp(keyCode: 8) == .deliver)
    }

    @Test func menuHandledControlEquivalentEmitsNoTerminalPressOrRelease() {
        var router = TerminalKeyEquivalentRouter()
        let timestamp = 73.25
        let keyCode: UInt16 = 8

        let pressRoute = router.routeKeyEquivalent(
            timestamp: timestamp,
            keyCode: keyCode,
            modifiers: .control,
            isTerminalBinding: true,
            menuHandled: true
        )
        let releaseRoute = router.routeKeyUp(keyCode: keyCode)
        let duplicateRelease = router.routeKeyUp(keyCode: keyCode)

        #expect(pressRoute == .handled)
        #expect(releaseRoute == .suppress)
        #expect(duplicateRelease == .suppress)
        #expect(!router.shouldRedispatchKeyEquivalent(
            timestamp: timestamp,
            keyCode: keyCode
        ))
    }

    @Test func passedThroughControlHandledElsewhereEmitsNoTerminalRelease() {
        var router = TerminalKeyEquivalentRouter()
        let timestamp = 79.5
        let keyCode: UInt16 = 9

        let pressRoute = router.routeKeyEquivalent(
            timestamp: timestamp,
            keyCode: keyCode,
            modifiers: .control,
            isTerminalBinding: false,
            menuHandled: false
        )
        let releaseRoute = router.routeKeyUp(keyCode: keyCode)
        let duplicateRelease = router.routeKeyUp(keyCode: keyCode)

        #expect(pressRoute == .passThrough)
        #expect(releaseRoute == .suppress)
        #expect(duplicateRelease == .suppress)
        #expect(!router.shouldRedispatchKeyEquivalent(
            timestamp: timestamp,
            keyCode: keyCode
        ))
    }

    @Test func deliveredControlEquivalentEmitsExactlyOnePressAndRelease() {
        var router = TerminalKeyEquivalentRouter()
        let timestamp = 84.5
        let keyCode: UInt16 = 8

        let pressRoute = router.routeKeyEquivalent(
            timestamp: timestamp,
            keyCode: keyCode,
            modifiers: .control,
            isTerminalBinding: true,
            menuHandled: false
        )
        #expect(pressRoute == .deliverPress)
        router.prepareForKeyDown(timestamp: timestamp, keyCode: keyCode)
        router.recordKeyDownDelivery(keyCode: keyCode)

        let releaseRoute = router.routeKeyUp(keyCode: keyCode)
        let duplicateRelease = router.routeKeyUp(keyCode: keyCode)
        #expect(releaseRoute == .deliver)
        #expect(duplicateRelease == .suppress)
    }

    @Test func deliveredCommandEquivalentReleasesAfterCommandModifierIsLifted() {
        var router = TerminalKeyEquivalentRouter()
        let keyCode: UInt16 = 47

        let pressRoute = router.routeKeyEquivalent(
            timestamp: 95.75,
            keyCode: keyCode,
            modifiers: .command,
            isTerminalBinding: true,
            menuHandled: false
        )
        #expect(pressRoute == .deliverPress)
        router.prepareForKeyDown(timestamp: 95.75, keyCode: keyCode)
        router.recordKeyDownDelivery(keyCode: keyCode)

        // Key-up intentionally has no modifier argument: the Command key may
        // already have been lifted when the character release arrives.
        let releaseWithoutModifierSnapshot = router.routeKeyUp(keyCode: keyCode)
        let duplicateRelease = router.routeKeyUp(keyCode: keyCode)
        #expect(releaseWithoutModifierSnapshot == .deliver)
        #expect(duplicateRelease == .suppress)

        // A subsequent ordinary press of the same key clears duplicate-release
        // history and remains independently deliverable.
        router.prepareForKeyDown(timestamp: 96.0, keyCode: keyCode)
        router.recordKeyDownDelivery(keyCode: keyCode)
        let laterOrdinaryRelease = router.routeKeyUp(keyCode: keyCode)
        #expect(laterOrdinaryRelease == .deliver)
    }

    @Test func ordinaryNonEquivalentKeyUpRemainsDeliverable() {
        var router = TerminalKeyEquivalentRouter()
        let keyCode: UInt16 = 12

        router.prepareForKeyDown(timestamp: 105.0, keyCode: keyCode)
        router.recordKeyDownDelivery(keyCode: keyCode)
        let releaseRoute = router.routeKeyUp(keyCode: keyCode)

        #expect(releaseRoute == .deliver)
    }

    @Test func zeroTimestampEquivalentIsNeverTrackedForRedispatch() {
        var router = TerminalKeyEquivalentRouter()
        let keyCode: UInt16 = 47

        let route = router.routeKeyEquivalent(
            timestamp: 0,
            keyCode: keyCode,
            modifiers: .command,
            isTerminalBinding: false,
            menuHandled: false
        )
        #expect(route == .passThrough)
        #expect(!router.shouldRedispatchKeyEquivalent(timestamp: 0, keyCode: keyCode))
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
