import AppKit
import Testing
@testable import Soprano

struct MainWindowSizingTests {
    @Test func initialFrameUsesDisplayHeightWithoutSpanningAnUltrawideScreen() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 5120, height: 1400)

        let frame = MainWindowSizing.initialFrame(in: visibleFrame)

        #expect(abs(frame.height - 1260) <= 1)
        #expect(abs((frame.width / frame.height) - 1.6) < 0.01)
        #expect(frame.width < visibleFrame.width / 2)
        #expect(abs(frame.midX - visibleFrame.midX) <= 1)
        #expect(abs(frame.midY - visibleFrame.midY) <= 1)
    }

    @Test func initialFrameFitsAndCentersOnAConventionalDisplay() {
        let visibleFrame = NSRect(x: 40, y: 25, width: 1440, height: 900)

        let frame = MainWindowSizing.initialFrame(in: visibleFrame)

        #expect(visibleFrame.contains(frame))
        #expect(abs(frame.width - (visibleFrame.width * 0.9)) <= 1)
        #expect(abs(frame.midX - visibleFrame.midX) <= 1)
        #expect(abs(frame.midY - visibleFrame.midY) <= 1)
    }

    @Test func invalidVisibleFrameUsesTheFallbackDisplay() {
        let frame = MainWindowSizing.initialFrame(in: .zero)
        let fallbackFrame = MainWindowSizing.initialFrame(
            in: MainWindowSizing.fallbackVisibleFrame
        )

        #expect(frame == fallbackFrame)
    }

    @Test func frameStoreRoundTripsAVisibleUserFrame() throws {
        let suiteName = "MainWindowSizingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibleFrame = NSRect(x: 0, y: 0, width: 5120, height: 1400)
        let userFrame = NSRect(x: 750, y: 120, width: 3000, height: 1100)

        MainWindowFrameStore.save(userFrame, to: defaults)

        #expect(MainWindowFrameStore.load(
            from: defaults,
            visibleFrames: [visibleFrame]
        ) == userFrame)
    }

    @Test func frameStoreRejectsUndersizedAndOffscreenFrames() throws {
        let suiteName = "MainWindowSizingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        MainWindowFrameStore.save(
            NSRect(x: 100, y: 100, width: 500, height: 300),
            to: defaults
        )
        #expect(MainWindowFrameStore.load(
            from: defaults,
            visibleFrames: [visibleFrame]
        ) == nil)

        MainWindowFrameStore.save(
            NSRect(x: 5000, y: 5000, width: 1200, height: 800),
            to: defaults
        )
        #expect(MainWindowFrameStore.load(
            from: defaults,
            visibleFrames: [visibleFrame]
        ) == nil)
    }
}

@MainActor
struct WindowFramePreservationTests {
    @Test func restoresFrameChangedDuringAContentTransition() {
        let originalFrame = NSRect(x: 240, y: 160, width: 1800, height: 1000)
        let window = NSWindow(
            contentRect: originalFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let layoutView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = layoutView
        window.setFrame(originalFrame, display: false)

        WindowFramePreservation.perform(
            window: window,
            layoutView: layoutView
        ) {
            window.setFrame(
                NSRect(x: 300, y: 200, width: 900, height: 600),
                display: false
            )
        }

        #expect(window.frame == originalFrame)
    }
}
