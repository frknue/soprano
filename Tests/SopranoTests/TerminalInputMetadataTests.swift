import Testing
@testable import Soprano

struct TerminalInputMetadataTests {
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
