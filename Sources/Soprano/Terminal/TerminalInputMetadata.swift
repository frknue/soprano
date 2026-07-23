import Foundation

enum TerminalResponderAction {
    static func bindingAction(for selector: Selector) -> String? {
        switch NSStringFromSelector(selector) {
        case "copy:":
            "copy_to_clipboard"
        case "paste:":
            "paste_from_clipboard"
        case "selectAll:":
            "select_all"
        default:
            nil
        }
    }
}

enum TerminalKeyEquivalentRoute {
    case passThrough
    case deliverPress
    case handled
}

struct TerminalKeyEquivalentRouter {
    private var pendingTimestamp: TimeInterval?
    private var deliveredTimestamp: TimeInterval?
    private var pressedCommandKeyCodes: Set<UInt16> = []

    mutating func routeKeyEquivalent(
        timestamp: TimeInterval,
        hasCommandOrControlModifier: Bool,
        isTerminalBinding: Bool,
        menuHandled: Bool
    ) -> TerminalKeyEquivalentRoute {
        guard timestamp != 0 else { return .passThrough }
        guard hasCommandOrControlModifier else {
            pendingTimestamp = nil
            return .passThrough
        }

        if menuHandled {
            pendingTimestamp = nil
            return .handled
        }

        if deliveredTimestamp == timestamp {
            pendingTimestamp = nil
            return .handled
        }

        if isTerminalBinding {
            pendingTimestamp = nil
            deliveredTimestamp = timestamp
            return .deliverPress
        }

        if pendingTimestamp == timestamp {
            pendingTimestamp = nil
            deliveredTimestamp = timestamp
            return .deliverPress
        }

        pendingTimestamp = timestamp
        return .passThrough
    }

    func shouldRedispatchCommand(timestamp: TimeInterval) -> Bool {
        timestamp != 0
            && pendingTimestamp == timestamp
            && deliveredTimestamp != timestamp
    }

    mutating func prepareForKeyDown() {
        pendingTimestamp = nil
    }

    mutating func recordCommandPress(keyCode: UInt16) {
        pressedCommandKeyCodes.insert(keyCode)
    }

    mutating func consumeCommandRelease(keyCode: UInt16) -> Bool {
        pressedCommandKeyCodes.remove(keyCode) != nil
    }

    mutating func reset() {
        pendingTimestamp = nil
        deliveredTimestamp = nil
        pressedCommandKeyCodes.removeAll()
    }
}

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

struct TerminalModifierDeviceFlags: OptionSet {
    let rawValue: UInt32

    static let controlLeft = Self(rawValue: 0x0000_0001)
    static let shiftLeft = Self(rawValue: 0x0000_0002)
    static let shiftRight = Self(rawValue: 0x0000_0004)
    static let commandLeft = Self(rawValue: 0x0000_0008)
    static let commandRight = Self(rawValue: 0x0000_0010)
    static let optionLeft = Self(rawValue: 0x0000_0020)
    static let optionRight = Self(rawValue: 0x0000_0040)
    static let controlRight = Self(rawValue: 0x0000_2000)
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
        modifiers: TerminalModifierFlags,
        deviceModifiers: TerminalModifierDeviceFlags
    ) -> TerminalModifierAction? {
        switch keyCode {
        case 0x39:
            return modifiers.contains(.capsLock) ? .press : .release
        case 0x38:
            return deviceModifiers.contains(.shiftLeft) ? .press : .release
        case 0x3C:
            return deviceModifiers.contains(.shiftRight) ? .press : .release
        case 0x3B:
            return deviceModifiers.contains(.controlLeft) ? .press : .release
        case 0x3E:
            return deviceModifiers.contains(.controlRight) ? .press : .release
        case 0x3A:
            return deviceModifiers.contains(.optionLeft) ? .press : .release
        case 0x3D:
            return deviceModifiers.contains(.optionRight) ? .press : .release
        case 0x37:
            return deviceModifiers.contains(.commandLeft) ? .press : .release
        case 0x36:
            return deviceModifiers.contains(.commandRight) ? .press : .release
        default:
            return nil
        }
    }
}
