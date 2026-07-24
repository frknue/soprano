import Testing
@testable import Soprano

struct TerminalCopyModeTests {
    @Test func vimKeysMapToCopyModeCommands() {
        var session = TerminalCopyModeSession(
            column: 3,
            row: 4,
            columnCount: 80,
            rowCount: 24
        )

        #expect(session.command(for: .init(key: "h")) == .moveLeft)
        #expect(session.command(for: .init(key: "j")) == .moveDown)
        #expect(session.command(for: .init(key: "k")) == .moveUp)
        #expect(session.command(for: .init(key: "l")) == .moveRight)
        #expect(session.command(for: .init(key: "h", shift: true)) == .viewportTop)
        #expect(session.command(for: .init(key: "m", shift: true)) == .viewportMiddle)
        #expect(session.command(for: .init(key: "l", shift: true)) == .viewportBottom)
        #expect(session.command(for: .init(key: "v")) == .beginSelection)
        #expect(session.command(for: .init(key: "v", shift: true)) == .beginLineSelection)
        #expect(session.command(for: .init(key: "y")) == .copyAndExit)
        #expect(session.command(for: .init(key: "q")) == .cancel)
    }

    @Test func selectionStyleIsRememberedForSubsequentMotions() {
        var characterSession = TerminalCopyModeSession(
            column: 3,
            row: 4,
            columnCount: 80,
            rowCount: 24
        )
        characterSession.beginSelection()

        var lineSession = TerminalCopyModeSession(
            column: 3,
            row: 4,
            columnCount: 80,
            rowCount: 24
        )
        lineSession.beginSelection(style: .line)

        #expect(characterSession.selectionStyle == .character)
        #expect(lineSession.selectionStyle == .line)
    }

    @Test func doubleGAndShiftGMapToHistoryBoundaries() {
        var session = TerminalCopyModeSession(
            column: 3,
            row: 4,
            columnCount: 80,
            rowCount: 24
        )

        #expect(session.command(for: .init(key: "g")) == .awaitMore)
        #expect(session.command(for: .init(key: "g")) == .historyTop)
        #expect(session.command(for: .init(key: "g", shift: true)) == .historyBottom)
    }

    @Test func cursorClampsHorizontallyAndRequestsVerticalScrollAtEdges() {
        var session = TerminalCopyModeSession(
            column: 0,
            row: 0,
            columnCount: 3,
            rowCount: 2
        )

        let movedPastLeftEdge = session.moveHorizontal(-1)
        #expect(!movedPastLeftEdge)
        #expect(session.column == 0)
        let scrollAboveTop = session.moveVertical(-1)
        #expect(scrollAboveTop == -1)
        #expect(session.row == 0)

        let movedToRightEdge = session.moveHorizontal(10)
        #expect(movedToRightEdge)
        #expect(session.column == 2)
        let scrollBelowBottom = session.moveVertical(10)
        #expect(scrollBelowBottom == 9)
        #expect(session.row == 1)
    }

    @Test func historyBottomReturnsToTheLastActiveContentRow() {
        var session = TerminalCopyModeSession(
            column: 3,
            row: 7,
            columnCount: 80,
            rowCount: 24
        )

        session.moveToViewportRow(0)
        session.moveToHistoryBottom()

        #expect(session.column == 79)
        #expect(session.row == 7)
    }
}
