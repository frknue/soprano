import AppKit
import Testing
@testable import Soprano

@MainActor
struct SlashMenuFocusTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func anotherAppWindowTakingTheKeyboardClosesTheMenu() {
        let main = window()
        let menu = window()
        #expect(SlashMenuFocus.closes(whenKey: window(), main: main, menu: menu))
    }

    @Test func theMainWindowOrTheMenuBecomingKeyKeepsItOpen() {
        let main = window()
        let menu = window()
        #expect(!SlashMenuFocus.closes(whenKey: main, main: main, menu: menu))
        #expect(!SlashMenuFocus.closes(whenKey: menu, main: main, menu: menu))
    }

    @Test func noKeyWindowAsWhenTheAppIsDeactivatedKeepsItOpen() {
        #expect(!SlashMenuFocus.closes(whenKey: nil, main: window(), menu: window()))
    }
}
