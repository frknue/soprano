import AppKit

extension NSStackView {
    /// Makes `views` the arranged subviews, in this order, touching only what
    /// differs: arranged views that stay are left alone or moved, arranged
    /// views missing from `views` leave the stack, and only views new to the
    /// stack are inserted and handed to `prepare`, e.g. to constrain them.
    ///
    /// Lists that refresh on every model change use this to reuse their rows;
    /// building a row's AppKit controls costs far more than reconfiguring one.
    func setArrangedSubviews(_ views: [NSView], prepare: (NSView) -> Void = { _ in }) {
        let kept = Set(views.map(ObjectIdentifier.init))
        for view in arrangedSubviews where !kept.contains(ObjectIdentifier(view)) {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !arrangedSubviews.elementsEqual(views, by: { $0 === $1 }) else { return }

        for (index, view) in views.enumerated() {
            let arrangedViews = arrangedSubviews
            guard index >= arrangedViews.count || arrangedViews[index] !== view else { continue }
            if view.superview === self {
                // Still a subview, so its constraints to the stack survive.
                removeArrangedSubview(view)
                insertArrangedSubview(view, at: index)
            } else {
                insertArrangedSubview(view, at: index)
                prepare(view)
            }
        }
    }
}
