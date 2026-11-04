import AppKit

enum MainWindowSizing {
    static let fallbackVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    static let minimumFrameSize = NSSize(width: 600, height: 400)

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

    static func isRestorable(_ frame: NSRect, on visibleFrames: [NSRect]) -> Bool {
        let values = [
            frame.origin.x,
            frame.origin.y,
            frame.width,
            frame.height,
        ]
        guard values.allSatisfy(\.isFinite),
              frame.width >= minimumFrameSize.width,
              frame.height >= minimumFrameSize.height
        else {
            return false
        }

        return visibleFrames.contains { visibleFrame in
            let intersection = frame.intersection(visibleFrame)
            return !intersection.isNull
                && intersection.width >= min(100, frame.width)
                && intersection.height >= min(100, frame.height)
        }
    }

    /// Fits a restorable frame into the visible frame it overlaps most, so a
    /// frame saved on a larger display comes back inside the current one.
    static func clamped(_ frame: NSRect, to visibleFrames: [NSRect]) -> NSRect {
        func overlapArea(_ visibleFrame: NSRect) -> CGFloat {
            let intersection = frame.intersection(visibleFrame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        guard let visibleFrame = visibleFrames.max(by: { overlapArea($0) < overlapArea($1) }),
              overlapArea(visibleFrame) > 0
        else { return frame }

        let width = min(frame.width, max(visibleFrame.width, minimumFrameSize.width))
        let height = min(frame.height, max(visibleFrame.height, minimumFrameSize.height))
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

enum MainWindowFrameStore {
    /// Versioned so frames previously captured by AppKit while Settings was
    /// affecting the window do not override the repaired startup behavior.
    private static let key = "soprano-main-window-frame-v2"

    static func load(
        from defaults: UserDefaults = .standard,
        visibleFrames: [NSRect]
    ) -> NSRect? {
        guard let storedFrame = defaults.string(forKey: key) else { return nil }
        let frame = NSRectFromString(storedFrame)
        guard MainWindowSizing.isRestorable(frame, on: visibleFrames) else { return nil }
        return MainWindowSizing.clamped(frame, to: visibleFrames)
    }

    static func save(
        _ frame: NSRect,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(NSStringFromRect(frame), forKey: key)
    }
}

@MainActor
enum WindowFramePreservation {
    static func perform(
        window: NSWindow?,
        layoutView: NSView,
        update: () -> Void
    ) {
        guard let window else {
            update()
            return
        }

        let frame = window.frame
        update()
        layoutView.layoutSubtreeIfNeeded()
        if window.frame != frame {
            window.setFrame(frame, display: false)
        }
    }
}
