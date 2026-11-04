import AppKit

/// The 8 pt mark before a login: a filled dot for the chosen one, a ring for the others, an
/// error diamond for a login with a problem.
final class AccountMarkView: PaletteView {
    enum Shape {
        case dot
        case ring
        case diamond
    }

    static let side: CGFloat = 8

    let shape: Shape

    init(_ shape: Shape) {
        self.shape = shape
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        setAccessibilityElement(false)
        applyPalette(palette)
    }

    convenience init(isSelected: Bool, hasProblem: Bool) {
        self.init(hasProblem ? .diamond : isSelected ? .dot : .ring)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        switch shape {
        case .dot:
            palette.foreground.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
        case .ring:
            palette.mutedForeground.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.25
            ring.stroke()
        case .diamond:
            palette.errorForeground.setFill()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX, y: rect.midY))
            path.close()
            path.fill()
        }
    }

    override func applyPalette(_ palette: Palette) {
        needsDisplay = true
    }
}

/// A 4 pt usage bar: a muted track filled to `fraction` (capped at full) in the severity color.
final class AgentsUsageBarView: PaletteView {
    static let width: CGFloat = 64

    private let fraction: Double

    init(fraction: Double) {
        self.fraction = fraction
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 4))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: 4),
        ])
        setAccessibilityElement(false)
        applyPalette(palette)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: floor((bounds.height - 4) / 2), width: bounds.width, height: 4)
        palette.foreground.withAlphaComponent(palette.isDark ? 0.12 : 0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        let share = CGFloat(min(max(fraction, 0), 1))
        guard share > 0 else { return }
        var filled = rect
        filled.size.width = max(4, round(rect.width * share))
        AgentsUsageSeverity(fraction: fraction).barColor(in: palette).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }

    override func applyPalette(_ palette: Palette) {
        needsDisplay = true
    }
}
