import AppKit

enum MainWindowSizing {
    static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private static let visibleFrameFraction: CGFloat = 0.9
    private static let preferredAspectRatio: CGFloat = 16.0 / 10.0

    /// Returns a large, centered terminal window without stretching across an
    /// entire ultrawide display.
    static func initialFrame(in visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return initialFrame(in: fallbackVisibleFrame)
        }

        let maximumWidth = visibleFrame.width * visibleFrameFraction
        let maximumHeight = visibleFrame.height * visibleFrameFraction
        let width = min(maximumWidth, maximumHeight * preferredAspectRatio)
        let height = width / preferredAspectRatio

        return NSRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (height / 2),
            width: width,
            height: height
        ).integral
    }
}
