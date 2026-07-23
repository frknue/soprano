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
            modifiers: [.shift]
        ) == .press)
        #expect(TerminalInputMetadata.modifierTransition(
            keyCode: 0x38,
            modifiers: []
        ) == .release)
    }

    @Test func rightModifierTransitionsUseTheRightSideState() {
        #expect(TerminalInputMetadata.modifierTransition(
            keyCode: 0x3D,
            modifiers: [.option, .optionRight]
        ) == .press)
        #expect(TerminalInputMetadata.modifierTransition(
            keyCode: 0x3D,
            modifiers: [.option]
        ) == .release)
    }

    @Test func everySupportedRightModifierReportsPressAndRelease() {
        let cases: [(UInt16, TerminalModifierFlags, TerminalModifierFlags)] = [
            (0x3C, [.shift, .shiftRight], [.shift]),
            (0x3E, [.control, .controlRight], [.control]),
            (0x3D, [.option, .optionRight], [.option]),
            (0x36, [.command, .commandRight], [.command]),
        ]

        for (keyCode, pressed, released) in cases {
            #expect(TerminalInputMetadata.modifierTransition(
                keyCode: keyCode,
                modifiers: pressed
            ) == .press)
            #expect(TerminalInputMetadata.modifierTransition(
                keyCode: keyCode,
                modifiers: released
            ) == .release)
        }
    }
}
