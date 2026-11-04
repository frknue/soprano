import AppKit
import Testing
@testable import Soprano

@MainActor
struct DialogsTests {
    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = AgentsWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.allowsOffscreenFrame = true
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private func overlay(over window: NSWindow) async throws -> OverlayWindow {
        for _ in 0..<100 {
            if let overlay = OverlayWindow.topmost(over: window) { return overlay }
            await Task.yield()
        }
        return try #require(OverlayWindow.topmost(over: window))
    }

    private func key(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    private func textField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = textField(in: subview) { return field }
        }
        return nil
    }

    @Test func aDialogRaisedAfterItsWindowClosedFallsBackToAPlainAlert() {
        let window = makeWindow()
        let overlay = OverlayWindow()
        overlay.present(over: window)
        #expect(Dialogs.host(for: window) === window)
        #expect(Dialogs.host(for: overlay) === window)
        overlay.dismiss()

        window.close()

        #expect(Dialogs.host(for: window) == nil)
    }

    @Test func returnChoosesTheLastButtonAndClosesTheDialog() async throws {
        let window = makeWindow()
        let answer = Task { await Dialogs.choose(
            title: "Uncommitted changes", message: "",
            buttons: [DialogButton("Cancel"), DialogButton("Push"), DialogButton("Commit & push", style: .primary)],
            in: window
        ) }
        let overlay = try await overlay(over: window)

        overlay.sendEvent(try key("\r", keyCode: 36))

        #expect(await answer.value == 2)
        #expect(OverlayWindow.topmost(over: window) == nil)
    }

    @Test func escapeCancelsAConfirm() async throws {
        let window = makeWindow()
        let answer = Task { await Dialogs.confirm(title: "Delete thread?", message: "Gone for good.", confirmTitle: "Delete", isDestructive: true, in: window) }
        let overlay = try await overlay(over: window)

        overlay.sendEvent(try key("\u{1B}", keyCode: 53))

        #expect(await answer.value == false)
    }

    @Test func aPromptReturnsTheTrimmedTextAndNilWhenEmpty() async throws {
        let window = makeWindow()
        let renamed = Task { await Dialogs.prompt(title: "Rename thread", message: "", initialValue: "Old", confirmTitle: "Rename", in: window) }
        var overlay = try await overlay(over: window)
        let field = try #require(textField(in: overlay.contentView))
        #expect(field.stringValue == "Old")
        field.stringValue = "  Fix login  "
        overlay.sendEvent(try key("\r", keyCode: 36))
        #expect(await renamed.value == "Fix login")

        let empty = Task { await Dialogs.prompt(title: "Rename thread", message: "", initialValue: "Old", in: window) }
        overlay = try await self.overlay(over: window)
        try #require(textField(in: overlay.contentView)).stringValue = "   "
        overlay.sendEvent(try key("\r", keyCode: 36))
        #expect(await empty.value == nil)
    }
}
