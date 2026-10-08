import AppKit

/// A sidebar's persisted width and the bounds a mouse drag may resize it to.
/// The left (windows) and right (explorer) sidebars each have their own.
struct SidebarWidthStore {
    let defaultWidth: CGFloat
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    private let key: String

    /// Width the tiling layout keeps for panes even when a sidebar is dragged
    /// toward the opposite edge of a narrow window.
    static let reservedContentWidth: CGFloat = 320

    static let left = SidebarWidthStore(
        defaultWidth: 220,
        minimumWidth: 160,
        maximumWidth: 520,
        key: "soprano-sidebar-width"
    )

    static let right = SidebarWidthStore(
        defaultWidth: 280,
        minimumWidth: 220,
        maximumWidth: 800,
        key: "soprano-right-sidebar-width"
    )

    /// Clamps a proposed width to the allowed range. Passing the width the
    /// sidebar may share with the panes additionally caps it so
    /// `reservedContentWidth` stays available for them; the minimum always wins
    /// so a very narrow window cannot collapse the sidebar into nothing (that is
    /// what toggling is for).
    func clamp(_ width: CGFloat, availableWidth: CGFloat? = nil) -> CGFloat {
        guard width.isFinite else { return defaultWidth }

        var upperBound = maximumWidth
        if let availableWidth, availableWidth.isFinite, availableWidth > 0 {
            upperBound = min(
                upperBound,
                max(minimumWidth, availableWidth - Self.reservedContentWidth)
            )
        }

        return min(max(width, minimumWidth), upperBound)
    }

    func load(from defaults: UserDefaults = .standard) -> CGFloat {
        guard let stored = defaults.object(forKey: key) as? Double else {
            return defaultWidth
        }
        return clamp(CGFloat(stored))
    }

    func save(_ width: CGFloat, to defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(width)), forKey: key)
    }
}
