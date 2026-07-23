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
}
