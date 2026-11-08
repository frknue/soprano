import AppKit

/// An unboxed badge in a window or layout tab, in Soprano Agents' status pill
/// language: the pill symbol of the most urgent agent behind it (Working,
/// Approval, Input, Done, Failed) or the Running terminal symbol for commands,
/// and a tabular count, both in the pill's tone. Hidden at zero.
final class StatusCountBadgeView: NSView {
    /// Most urgent first; the badge takes the first status any agent has.
    static let urgencyOrder: [AgentStatus] = [.error, .waiting, .running, .starting, .idle]
    static let iconSize: CGFloat = 12
    static let height: CGFloat = 16
    private static let gap: CGFloat = 3

    let icon = NSImageView()
    private let countLabel = NSTextField(labelWithString: "")
    /// The pill the badge shows, nil while hidden.
    private(set) var pill: ShellStatusPill?
    private(set) var badgeWidth: CGFloat = 0

    init(identifier: String) {
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        addSubview(countLabel)
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.applyTint() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(agents: [AgentInstance], theme: AppTheme) {
        let urgent = Self.urgencyOrder.lazy.compactMap { status in agents.first { $0.status == status } }.first
        let pill = urgent.flatMap { ShellStatusPill.of(status: $0.status, waitingReason: $0.waitingReason, workingSince: nil) }
            ?? ShellStatusPill(label: "Ready", symbol: Icon.circleCheck, tone: .muted, since: nil)
        configure(count: agents.count, pill: pill)
    }

    func configure(runningCommands count: Int, theme: AppTheme) {
        configure(count: count, pill: .running)
    }

    private func configure(count: Int, pill: ShellStatusPill) {
        isHidden = count == 0
        self.pill = count == 0 ? nil : pill
        icon.image = NSImage.symbol(pill.symbol, size: 11, weight: .medium)
        countLabel.stringValue = "\(count)"
        countLabel.font = Typography.tabular(Typography.smallSize, weight: .medium)
        applyTint()
        badgeWidth = Self.iconSize + Self.gap + ceil(countLabel.intrinsicContentSize.width)
        needsLayout = true
    }

    private func applyTint() {
        let color = PaletteCenter.shared.palette.color(for: pill?.tone ?? .muted)
        icon.contentTintColor = color
        countLabel.textColor = color
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

    /// "2 commands running" for tooltips; nil when none is.
    static func summary(ofRunningCommands count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 command running" : "\(count) commands running"
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(
            x: 0,
            y: floor((bounds.height - Self.iconSize) / 2),
            width: Self.iconSize,
            height: Self.iconSize
        )
        let size = countLabel.intrinsicContentSize
        countLabel.frame = NSRect(
            x: Self.iconSize + Self.gap,
            y: floor((bounds.height - size.height) / 2),
            width: ceil(size.width),
            height: size.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
