import AppKit

enum TerminalCopyModePhase {
    case navigating
    case selecting
}

enum TerminalCopyModeSelectionStyle: Equatable {
    case character
    case line
}

enum TerminalCopyModeCommand: Equatable {
    case moveLeft
    case moveDown
    case moveUp
    case moveRight
    case lineStart
    case lineEnd
    case viewportTop
    case viewportMiddle
    case viewportBottom
    case historyTop
    case historyBottom
    case halfPageUp
    case halfPageDown
    case pageUp
    case pageDown
    case beginSelection
    case beginLineSelection
    case copyAndExit
    case cancel
    case awaitMore
}

struct TerminalCopyModeInput {
    let key: String
    let keyCode: UInt16
    let control: Bool
    let shift: Bool
    let option: Bool
    let command: Bool

    init(
        key: String,
        keyCode: UInt16 = 0,
        control: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        command: Bool = false
    ) {
        self.key = key
        self.keyCode = keyCode
        self.control = control
        self.shift = shift
        self.option = option
        self.command = command
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(
            key: event.charactersIgnoringModifiers?.lowercased() ?? "",
            keyCode: event.keyCode,
            control: flags.contains(.control),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            command: flags.contains(.command)
        )
    }
}

struct TerminalCopyModeSession {
    private(set) var phase: TerminalCopyModePhase = .navigating
    private(set) var selectionStyle: TerminalCopyModeSelectionStyle?
    private(set) var column: Int
    private(set) var row: Int
    let columnCount: Int
    let rowCount: Int
    private let bottomContentRow: Int
    private var awaitsSecondG = false

    init(
        column: Int,
        row: Int,
        columnCount: Int,
        rowCount: Int
    ) {
        self.columnCount = max(1, columnCount)
        self.rowCount = max(1, rowCount)
        self.column = min(max(0, column), self.columnCount - 1)
        self.row = min(max(0, row), self.rowCount - 1)
        self.bottomContentRow = self.row
    }

    mutating func command(for input: TerminalCopyModeInput) -> TerminalCopyModeCommand? {
        guard !input.command, !input.option else {
            awaitsSecondG = false
            return nil
        }

        if input.keyCode == 53 || (input.control && input.key == "c") {
            awaitsSecondG = false
            return .cancel
        }

        if input.control {
            awaitsSecondG = false
            return switch input.key {
            case "u": .halfPageUp
            case "d": .halfPageDown
            case "b": .pageUp
            case "f": .pageDown
            case " ": .beginSelection
            default: nil
            }
        }

        let command: TerminalCopyModeCommand? = switch input.keyCode {
        case 123: .moveLeft
        case 124: .moveRight
        case 125: .moveDown
        case 126: .moveUp
        case 116: .pageUp
        case 121: .pageDown
        case 36, 76: .copyAndExit
        default: nil
        }
        if let command {
            awaitsSecondG = false
            return command
        }

        switch input.key {
        case "h" where input.shift:
            awaitsSecondG = false
            return .viewportTop
        case "m" where input.shift:
            awaitsSecondG = false
            return .viewportMiddle
        case "l" where input.shift:
            awaitsSecondG = false
            return .viewportBottom
        case "h":
            awaitsSecondG = false
            return .moveLeft
        case "j":
            awaitsSecondG = false
            return .moveDown
        case "k":
            awaitsSecondG = false
            return .moveUp
        case "l":
            awaitsSecondG = false
            return .moveRight
        case "0", "^":
            awaitsSecondG = false
            return .lineStart
        case "6" where input.shift:
            awaitsSecondG = false
            return .lineStart
        case "$":
            awaitsSecondG = false
            return .lineEnd
        case "4" where input.shift:
            awaitsSecondG = false
            return .lineEnd
        case "g" where input.shift:
            awaitsSecondG = false
            return .historyBottom
        case "g":
            if awaitsSecondG {
                awaitsSecondG = false
                return .historyTop
            }
            awaitsSecondG = true
            return .awaitMore
        case "v" where input.shift:
            awaitsSecondG = false
            return .beginLineSelection
        case "v", " ":
            awaitsSecondG = false
            return .beginSelection
        case "y":
            awaitsSecondG = false
            return .copyAndExit
        case "q":
            awaitsSecondG = false
            return .cancel
        default:
            awaitsSecondG = false
            return nil
        }
    }

    mutating func beginSelection(style: TerminalCopyModeSelectionStyle = .character) {
        phase = .selecting
        selectionStyle = style
    }

    @discardableResult
    mutating func moveHorizontal(_ delta: Int) -> Bool {
        let next = min(max(0, column + delta), columnCount - 1)
        guard next != column else { return false }
        column = next
        return true
    }

    /// Returns the number of lines that the viewport must scroll. The cursor
    /// remains on the boundary row when movement crosses the visible grid.
    mutating func moveVertical(_ delta: Int) -> Int {
        let candidate = row + delta
        if candidate < 0 {
            row = 0
            return candidate
        }
        if candidate >= rowCount {
            row = rowCount - 1
            return candidate - (rowCount - 1)
        }
        row = candidate
        return 0
    }

    mutating func moveToLineStart() {
        column = 0
    }

    mutating func moveToLineEnd() {
        column = columnCount - 1
    }

    mutating func moveToViewportRow(_ target: Int) {
        row = min(max(0, target), rowCount - 1)
    }

    mutating func moveToHistoryTop() {
        column = 0
        row = 0
    }

    mutating func moveToHistoryBottom() {
        column = columnCount - 1
        row = bottomContentRow
    }
}
