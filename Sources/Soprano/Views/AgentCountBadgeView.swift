import AppKit

/// The open agents behind a window or layout tab: their count beside a lamp
/// in the color of the most urgent one, red for errors, yellow for input or
/// startup, green for working, and blue for ready. Hidden without agents.
final class AgentCountBadgeView: NSView {
    /// Most urgent first; the lamp takes the first status any agent has.
    static let urgencyOrder: [AgentStatus] = [.error, .waiting, .running, .starting, .idle]
    private static let lampSize: CGFloat = 6

    private let lamp = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private(set) var badgeWidth: CGFloat = 28

    init(identifier: String) {
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        wantsLayer = true
        layer?.cornerRadius = Retro.cornerRadius
        layer?.borderWidth = Retro.hairline
        lamp.wantsLayer = true
        lamp.layer?.cornerRadius = Self.lampSize / 2
        addSubview(lamp)
        addSubview(countLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(agents: [AgentInstance], theme: AppTheme) {
        let status = Self.urgencyOrder.first { status in agents.contains { $0.status == status } }
        let color: NSColor = switch status {
        case .error: theme.colors.danger
        case .waiting, .starting: theme.colors.yellow
        case .running: theme.colors.success
        default: theme.colors.blue
        }
        isHidden = agents.isEmpty
        countLabel.setRetroText("\(agents.count)", color: color)
        RetroLamp.light(lamp, color: color)
        layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        layer?.borderColor = color.cgColor
        badgeWidth = 20 + ceil(countLabel.intrinsicContentSize.width)
        needsLayout = true
    }

    /// "2 agents: 1 working, 1 ready" for tooltips; nil without agents.
    static func summary(of agents: [AgentInstance]) -> String? {
        guard !agents.isEmpty else { return nil }
        let noun = agents.count == 1 ? "agent" : "agents"
        let counts = urgencyOrder.compactMap { status -> String? in
            let count = agents.filter { $0.status == status }.count
            return count > 0 ? "\(count) \(status.displayLabel.lowercased())" : nil
        }
        return "\(agents.count) \(noun): \(counts.joined(separator: ", "))"
    }

    override func layout() {
        super.layout()
        lamp.frame = NSRect(
            x: 5,
            y: floor((bounds.height - Self.lampSize) / 2),
            width: Self.lampSize,
            height: Self.lampSize
        )
        let size = countLabel.intrinsicContentSize
        countLabel.frame = NSRect(
            x: 15,
            y: floor((bounds.height - size.height) / 2),
            width: ceil(size.width),
            height: size.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A flat colored plate inside a tab that never takes clicks from it.
final class TabPlateView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
