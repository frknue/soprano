import Foundation

enum TerminalScrollMomentum: Int32 {
    case none = 0
    case began = 1
    case stationary = 2
    case changed = 3
    case ended = 4
    case cancelled = 5
    case mayBegin = 6
}

struct TerminalModifierFlags: OptionSet {
    let rawValue: UInt32

    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
    static let capsLock = Self(rawValue: 1 << 4)
    static let shiftRight = Self(rawValue: 1 << 6)
    static let controlRight = Self(rawValue: 1 << 7)
    static let optionRight = Self(rawValue: 1 << 8)
    static let commandRight = Self(rawValue: 1 << 9)
}

enum TerminalModifierAction {
    case press
    case release
}

enum TerminalInputMetadata {
    static func scrollFlags(
        precise: Bool,
        momentum: TerminalScrollMomentum
    ) -> Int32 {
        (precise ? 1 : 0) | (momentum.rawValue << 1)
    }

    static func scrollDeltas(
        x: Double,
        y: Double,
        precise: Bool
    ) -> (x: Double, y: Double) {
        let multiplier = precise ? 2.0 : 1.0
        return (x * multiplier, y * multiplier)
    }

    static func modifierTransition(
        keyCode: UInt16,
        modifiers: TerminalModifierFlags
    ) -> TerminalModifierAction? {
        let base: TerminalModifierFlags
        let right: TerminalModifierFlags?
        let isRight: Bool

        switch keyCode {
        case 0x39:
            base = .capsLock
            right = nil
            isRight = false
        case 0x38:
            base = .shift
            right = .shiftRight
            isRight = false
        case 0x3C:
            base = .shift
            right = .shiftRight
            isRight = true
        case 0x3B:
            base = .control
            right = .controlRight
            isRight = false
        case 0x3E:
            base = .control
            right = .controlRight
            isRight = true
        case 0x3A:
            base = .option
            right = .optionRight
            isRight = false
        case 0x3D:
            base = .option
            right = .optionRight
            isRight = true
        case 0x37:
            base = .command
            right = .commandRight
            isRight = false
        case 0x36:
            base = .command
            right = .commandRight
            isRight = true
        default:
            return nil
        }

        guard modifiers.contains(base) else { return .release }
        if isRight, let right, !modifiers.contains(right) {
            return .release
        }
        return .press
    }
}
