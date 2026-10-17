import AppKit
import Testing
@testable import Soprano

@MainActor
struct TerminalSurfaceFocusTests {
    @Test func losingAndRegainingWindowKeyStatusUpdatesTheStillFirstResponderSurface() throws {
        let window = FocusWindow()
        let view = TerminalSurfaceView(paneId: "focus-pane", tabId: "focus-tab", startsSurface: false)
        var focusEvents: [Bool] = []
        view.surfaceFocusHandler = { focusEvents.append($0) }
        let host = try #require(window.contentView)
        host.addSubview(view)
        defer { window.contentView = nil }
        window.changeKeyStatus(to: true)
        #expect(window.makeFirstResponder(view))
        #expect(window.firstResponder === view)
        #expect(focusEvents.last == true)
        focusEvents.removeAll()

        window.changeKeyStatus(to: false)

        #expect(window.firstResponder === view)
        #expect(focusEvents == [false])

        window.changeKeyStatus(to: true)

        #expect(window.firstResponder === view)
        #expect(focusEvents == [false, true])
    }

    @Test func becomingFirstResponderInANonKeyWindowDoesNotFocusTheSurface() throws {
        let window = FocusWindow()
        let view = TerminalSurfaceView(paneId: "focus-pane", tabId: "focus-tab", startsSurface: false)
        var focusEvents: [Bool] = []
        view.surfaceFocusHandler = { focusEvents.append($0) }
        let host = try #require(window.contentView)
        host.addSubview(view)
        defer { window.contentView = nil }
        focusEvents.removeAll()

        #expect(window.makeFirstResponder(view))
        #expect(window.firstResponder === view)
        #expect(!focusEvents.contains(true))

        window.changeKeyStatus(to: true)
        #expect(focusEvents.last == true)
    }

    @Test func responderTransfersFocusOnlyTheNewResponderAndIgnoreRepeatedWindowEvents() throws {
        let window = FocusWindow()
        let first = TerminalSurfaceView(paneId: "first", tabId: "tab", startsSurface: false)
        let second = TerminalSurfaceView(paneId: "second", tabId: "tab", startsSurface: false)
        var firstEvents: [Bool] = []
        var secondEvents: [Bool] = []
        first.surfaceFocusHandler = { firstEvents.append($0) }
        second.surfaceFocusHandler = { secondEvents.append($0) }
        let host = try #require(window.contentView)
        host.addSubview(first)
        host.addSubview(second)
        defer { window.contentView = nil }
        window.changeKeyStatus(to: true)
        #expect(window.makeFirstResponder(first))
        firstEvents.removeAll()
        secondEvents.removeAll()

        #expect(window.makeFirstResponder(second))
        #expect(firstEvents == [false])
        #expect(secondEvents == [true])

        window.changeKeyStatus(to: true)
        window.changeKeyStatus(to: true)
        #expect(firstEvents == [false])
        #expect(secondEvents == [true])

        window.changeKeyStatus(to: false)
        window.changeKeyStatus(to: false)
        #expect(firstEvents == [false])
        #expect(secondEvents == [true, false])
    }

    @Test func notificationsFromAnotherWindowCannotChangeThisSurfaceFocus() throws {
        let window = FocusWindow()
        let otherWindow = FocusWindow()
        let view = TerminalSurfaceView(paneId: "focus-pane", tabId: "focus-tab", startsSurface: false)
        var focusEvents: [Bool] = []
        view.surfaceFocusHandler = { focusEvents.append($0) }
        let host = try #require(window.contentView)
        host.addSubview(view)
        defer { window.contentView = nil }
        window.changeKeyStatus(to: true)
        #expect(window.makeFirstResponder(view))
        focusEvents.removeAll()

        // Another window's event can arrive before our own notification.
        // It must not synchronize this surface, even if our state changed.
        window.simulatedKeyStatus = false
        otherWindow.changeKeyStatus(to: false)
        #expect(focusEvents.isEmpty)
        window.changeKeyStatus(to: false)
        #expect(focusEvents == [false])

        window.simulatedKeyStatus = true
        otherWindow.changeKeyStatus(to: true)
        #expect(focusEvents == [false])
        window.changeKeyStatus(to: true)
        #expect(focusEvents == [false, true])
        #expect(window.firstResponder === view)
        #expect(window.isKeyWindow)
    }

    @Test func detachingAndReattachingResynchronizesFocusAndDestructionClearsTheCache() throws {
        let window = FocusWindow()
        let view = TerminalSurfaceView(paneId: "focus-pane", tabId: "focus-tab", startsSurface: false)
        var focusEvents: [Bool] = []
        view.surfaceFocusHandler = { focusEvents.append($0) }
        let host = try #require(window.contentView)
        host.addSubview(view)
        defer { window.contentView = nil }
        window.changeKeyStatus(to: true)
        #expect(window.makeFirstResponder(view))
        focusEvents.removeAll()

        view.removeFromSuperview()
        #expect(focusEvents == [false])
        #expect(view.window == nil)

        host.addSubview(view)
        #expect(window.makeFirstResponder(view))
        #expect(focusEvents.last == true)
        focusEvents.removeAll()

        view.destroySurface()
        // The replacement surface must receive the current state even if it
        // matches the state sent to the old surface. No Ghostty process starts.
        window.changeKeyStatus(to: true)
        #expect(focusEvents == [true])
    }

    @Test func focusNotificationsAreEmittedOnlyWhenTheSurfaceActuallyGainsFocus() throws {
        let window = FocusWindow()
        let view = TerminalSurfaceView(paneId: "focus-pane", tabId: "focus-tab", startsSurface: false)
        let recorder = FocusNotificationRecorder()
        view.surfaceFocusHandler = { recorder.focusEvents.append($0) }
        let observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: view,
            queue: .main
        ) { notification in
            let paneId = notification.userInfo?["paneId"] as? String ?? ""
            let tabId = notification.userInfo?["tabId"] as? String ?? ""
            MainActor.assumeIsolated {
                recorder.paneIds.append(paneId)
                recorder.tabIds.append(tabId)
                recorder.focusAtNotification.append(recorder.focusEvents.last)
            }
        }
        let host = try #require(window.contentView)
        host.addSubview(view)
        defer {
            NotificationCenter.default.removeObserver(observer)
            window.contentView = nil
        }

        #expect(window.makeFirstResponder(view))
        #expect(recorder.paneIds.isEmpty)
        window.changeKeyStatus(to: true)
        window.changeKeyStatus(to: true)
        window.changeKeyStatus(to: false)
        #expect(recorder.paneIds == ["focus-pane"])
        #expect(recorder.tabIds == ["focus-tab"])
        #expect(recorder.focusAtNotification == [true])

        window.changeKeyStatus(to: true)
        #expect(recorder.paneIds == ["focus-pane", "focus-pane"])
        #expect(recorder.focusAtNotification == [true, true])
    }
}

@MainActor
private final class FocusNotificationRecorder {
    var focusEvents: [Bool] = []
    var paneIds: [String] = []
    var tabIds: [String] = []
    var focusAtNotification: [Bool?] = []
}

@MainActor
private final class FocusWindow: NSWindow {
    var simulatedKeyStatus = false
    override var isKeyWindow: Bool { simulatedKeyStatus }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    func changeKeyStatus(to isKey: Bool) {
        simulatedKeyStatus = isKey
        NotificationCenter.default.post(
            name: isKey ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification,
            object: self
        )
    }
}
