import AppKit

/// The 8 pt mark before a login (Soprano Agents' `AccountMarkView`): a filled
/// dot for the chosen one, a ring for the others, an error diamond for a
/// login with a problem.
final class SettingsAccountMark: PaletteView {
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

/// A 4 pt usage bar (Soprano Agents' `UsageBarView`): a faint track filled
/// to `fraction` (capped at full) in the severity color.
final class SettingsUsageBar: PaletteView {
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
        UsageSeverity.barColor(for: fraction, in: palette).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }

    override func applyPalette(_ palette: Palette) {
        needsDisplay = true
    }
}

/// A login in Settings → Accounts (Soprano Agents' `AccountEntryRowView`):
/// mark, title with an optional badge, a wrapping detail line (organization,
/// plan, usage), the problem in the error color, and the row's buttons on the
/// right. The chosen login sits on a faint fill with a filled mark.
final class SettingsAccountEntryRowView: PaletteView {
    private let isSelected: Bool

    init(title: String, isSelected: Bool, badge: String?, detail: String, problem: String?, control: NSView?, width: CGFloat) {
        self.isSelected = isSelected
        super.init(frame: .zero)
        let hasProblem = !(problem ?? "").isEmpty
        let mark = SettingsAccountMark(isSelected: isSelected, hasProblem: hasProblem)

        let titleLabel = SettingsLabel(title, size: Typography.bodySize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        if let badge {
            let chip = ComposerBadge(badge)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(chip)
        }

        let controlWidth = control.map { $0.fittingSize.width } ?? 0
        let textWidth = max(120, width - 32 - 18 - (control == nil ? 0 : controlWidth + 24))
        let text = NSStackView(views: [titleRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let detailLabel = SettingsLabel(detail, size: Typography.smallSize, wrapping: true) { $0.mutedForeground }
        detailLabel.preferredMaxLayoutWidth = textWidth
        text.addArrangedSubview(detailLabel)
        if let problem, hasProblem {
            let problemLabel = SettingsLabel(problem, size: Typography.smallSize, wrapping: true) { $0.errorForeground }
            problemLabel.preferredMaxLayoutWidth = textWidth
            text.addArrangedSubview(problemLabel)
        }

        for view in [mark, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        var constraints = [
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mark.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ]
        let fill = text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        fill.priority = .defaultLow
        constraints.append(fill)
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                control.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -24),
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = isSelected
            ? palette.foreground.withAlphaComponent(palette.isDark ? 0.06 : 0.035).cgColor
            : NSColor.clear.cgColor
    }
}
