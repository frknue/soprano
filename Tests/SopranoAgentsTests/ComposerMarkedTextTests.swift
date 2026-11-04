import AppKit
import Testing
@testable import Soprano

@MainActor
struct ComposerMarkedTextTests {
    private static func key(_ keyCode: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    @Test func menuKeysGoToTheInputMethodWhileTheEditorComposesMarkedText() {
        let editor = ComposerTextView()
        var menuKeys = 0
        editor.menuKeyHandler = { _ in
            menuKeys += 1
            return true
        }
        editor.keyDown(with: Self.key(125, "\u{F701}"))
        #expect(menuKeys == 1)

        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        editor.keyDown(with: Self.key(125, "\u{F701}"))
        #expect(menuKeys == 1)
    }

    @Test func popoverKeysGoToTheInputMethodWhileItsFieldComposesMarkedText() {
        let window = ComposerPopoverWindow(contentRect: NSRect(x: -30000, y: -30000, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView = field
        window.makeFirstResponder(field)
        var handled = 0
        window.keyHandler = { _ in
            handled += 1
            return true
        }
        window.sendEvent(Self.key(53, "\u{1b}"))
        #expect(handled == 1)

        field.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.hasMarkedText())
        #expect(window.firstResponder === field)
        window.sendEvent(Self.key(126, "\u{F700}"))
        _ = window.performKeyEquivalent(with: Self.key(53, "\u{1b}"))
        #expect(handled == 1)
    }
}
