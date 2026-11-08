import AppKit
import Testing
@testable import Soprano

@MainActor
struct ShellDialogsTests {
    private static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    private static let returnKey = key("\r", code: 36)
    private static let escapeKey = key("\u{1b}", code: 53)

    private static func offscreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private static func prompt(initialValue: String, completion: @escaping (ShellDialogResult) -> Void) -> ShellDialogController {
        ShellDialogController(
            content: ShellDialogs.promptContent(
                title: "Rename Session",
                message: "Name this group of windows.",
                placeholder: "Session name",
                initialValue: initialValue,
                confirmTitle: "Rename"
            ),
            completion: completion
        )
    }

    @Test func returnInAPromptConfirmsWithTheTrimmedText() throws {
        var result: ShellDialogResult?
        let controller = Self.prompt(initialValue: "Main") { result = $0 }
        let input = try #require(controller.input)
        input.stringValue = "  Release work  "

        #expect(controller.window.keyHandler?(Self.returnKey) == true)

        #expect(result?.index == 1)
        #expect(result?.promptValue == "Release work")
    }

    @Test func escapeInAPromptCancelsEvenWithText() {
        var result: ShellDialogResult?
        let controller = Self.prompt(initialValue: "Main") { result = $0 }

        #expect(controller.window.keyHandler?(Self.escapeKey) == true)

        #expect(result?.index == nil)
        #expect(result?.promptValue == nil)
    }

    @Test func returnInTheFieldEditorConfirmsLikeTheDefaultButton() throws {
        var result: ShellDialogResult?
        let controller = Self.prompt(initialValue: "Main") { result = $0 }
        let input = try #require(controller.input)

        #expect(input.onCommand?(#selector(NSResponder.insertNewline(_:))) == true)

        #expect(result?.promptValue == "Main")
    }

    @Test func aBlankPromptAnswerCountsAsNoAnswer() {
        #expect(ShellDialogResult(index: 1, text: "   ").promptValue == nil)
        #expect(ShellDialogResult(index: 0, text: "Kept").promptValue == nil)
    }

    @Test func aPromptStartsWithItsInitialValueSelectedInTheField() throws {
        let parent = Self.offscreenWindow()
        defer { parent.orderOut(nil) }
        parent.orderFront(nil)
        var result: ShellDialogResult?
        let controller = Self.prompt(initialValue: "Main") { result = $0 }

        controller.present(over: parent)
        defer { controller.finish(index: nil) }

        let input = try #require(controller.input)
        let editor = try #require(input.field.currentEditor())
        #expect(editor.selectedRange == NSRange(location: 0, length: 4))
        #expect(result == nil)
    }

    @Test func aButtonsOwnShortcutPicksIt() {
        var result: ShellDialogResult?
        let controller = ShellDialogController(
            content: ShellDialogContent(
                title: "Save?",
                message: "",
                buttons: [
                    ShellDialogButton("Don't Save", style: .destructiveOutline, keyEquivalent: "d", keyModifiers: .command),
                    ShellDialogButton("Cancel"),
                    ShellDialogButton("Save", style: .primary),
                ]
            )
        ) { result = $0 }

        #expect(controller.window.keyHandler?(Self.key("d", code: 2)) == false)
        #expect(result == nil)
        #expect(controller.window.keyHandler?(Self.key("d", code: 2, modifiers: .command)) == true)

        #expect(result?.index == 0)
    }

    @Test func theModalVariantReturnsTheButtonChosenDuringItsSession() {
        let parent = Self.offscreenWindow()
        defer { parent.orderOut(nil) }
        parent.orderFront(nil)
        let controller = ShellDialogController(
            content: ShellDialogContent(
                title: "Save?",
                message: "",
                buttons: [ShellDialogButton("Don't Save"), ShellDialogButton("Cancel"), ShellDialogButton("Save", style: .primary)]
            )
        )
        var sessionWindow: ShellDialogOverlayWindow?

        let result = controller.runModal(over: parent) { window in
            sessionWindow = window
            #expect(window.parent === parent)
            _ = window.keyHandler?(Self.returnKey)
        }

        #expect(sessionWindow === controller.window)
        #expect(result.index == 2)
        #expect(controller.window.isVisible == false)
        #expect(parent.childWindows?.isEmpty ?? true)
    }

    @Test func theModalVariantReturnsAButtonPickedByFinish() {
        let parent = Self.offscreenWindow()
        defer { parent.orderOut(nil) }
        parent.orderFront(nil)
        let controller = ShellDialogController(
            content: ShellDialogContent(title: "Remove?", message: "", buttons: [ShellDialogButton("Cancel"), ShellDialogButton("Remove", style: .destructive)])
        )

        let result = controller.runModal(over: parent) { _ in controller.finish(index: 0) }

        #expect(result.index == 0)
    }

    @Test func aModalSessionEndingUnansweredCancels() {
        let parent = Self.offscreenWindow()
        defer { parent.orderOut(nil) }
        parent.orderFront(nil)
        var completions: [Int?] = []
        let controller = ShellDialogController(
            content: ShellDialogContent(title: "Remove?", message: "", buttons: [ShellDialogButton("Cancel"), ShellDialogButton("Remove")])
        ) { completions.append($0.index) }

        let result = controller.runModal(over: parent) { _ in }

        #expect(result.index == nil)
        #expect(completions == [nil])
        #expect(controller.window.isVisible == false)
    }

    @Test func aDialogAnswersOnceThoughTheBackdropIsClickedAfterAButton() {
        var completions: [Int?] = []
        let controller = ShellDialogController(
            content: ShellDialogContent(title: "Delete?", message: "", buttons: [ShellDialogButton("Cancel"), ShellDialogButton("Delete")])
        ) { completions.append($0.index) }

        controller.finish(index: 1)
        controller.window.backdrop.onClick?()

        #expect(completions == [1])
    }

    @Test func dialogsPresentOverTheWindowBehindAnOverlay() {
        let parent = Self.offscreenWindow()
        defer { parent.orderOut(nil) }
        parent.orderFront(nil)
        let overlay = ShellDialogOverlayWindow()
        overlay.cover(parent)

        #expect(ShellDialogs.host(for: overlay) === parent)
        #expect(ShellDialogs.host(for: parent) === parent)
    }
}
