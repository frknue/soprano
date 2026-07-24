import AppKit

/// The sidebar's persisted width and the bounds a mouse drag may resize it to.
enum SidebarWidthStore {
    static let defaultWidth: CGFloat = 220
    static let minimumWidth: CGFloat = 160
    static let maximumWidth: CGFloat = 520

    /// Width the tiling layout keeps for panes even when the sidebar is dragged
    /// toward the right edge of a narrow window.
    static let reservedContentWidth: CGFloat = 320

    private static let key = "soprano-sidebar-width"

    /// Clamps a proposed width to the allowed range. Passing the container width
    /// additionally caps the sidebar so `reservedContentWidth` stays available for
    /// panes; the minimum always wins so a very narrow window cannot collapse the
    /// sidebar into nothing (that is what toggling is for).
    static func clamp(_ width: CGFloat, availableWidth: CGFloat? = nil) -> CGFloat {
        guard width.isFinite else { return defaultWidth }

        var upperBound = maximumWidth
        if let availableWidth, availableWidth.isFinite, availableWidth > 0 {
            upperBound = min(
                upperBound,
                max(minimumWidth, availableWidth - reservedContentWidth)
            )
        }

        return min(max(width, minimumWidth), upperBound)
    }

    static func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard let stored = defaults.object(forKey: key) as? Double else {
            return defaultWidth
        }
        return clamp(CGFloat(stored))
    }

    static func save(_ width: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(width)), forKey: key)
    }
}
