import AppKit

/// An unboxed badge in a window or layout tab: a 7 pt status mark and a
/// tabular count (`● 3`), both in the color of the most urgent agent behind
/// it, or the running-command color for terminals running a command. Hidden
/// at zero.
final class StatusCountBadgeView: NSView {
    /// Most urgent first; the badge takes the first status any agent has.
    static let urgencyOrder: [AgentStatus] = [.error, .waiting, .running, .starting, .idle]
    static let markSize: CGFloat = 7
    static let height: CGFloat = 16
    private static let gap: CGFloat = 4

    let mark = ChromeStatusMark(size: StatusCountBadgeView.markSize)
    private let countLabel = NSTextField(labelWithString: "")
    /// The status the badge shows, nil while hidden.
    private(set) var status: ChromeStatus?
    private(set) var badgeWidth: CGFloat = 0

    init(identifier: String) {
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        // Laid out by frame; a constraint-less Auto Layout view would be
        // reset by every window layout pass.
        mark.translatesAutoresizingMaskIntoConstraints = true
        addSubview(mark)
        addSubview(countLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(agents: [AgentInstance], theme: AppTheme) {
        let urgent = Self.urgencyOrder.first { status in agents.contains { $0.status == status } }
        configure(count: agents.count, status: urgent?.chromeStatus ?? .ready, theme: theme)
    }

    func configure(runningCommands count: Int, theme: AppTheme) {
        configure(count: count, status: .running, theme: theme)
    }

    private func configure(count: Int, status: ChromeStatus, theme: AppTheme) {
        isHidden = count == 0
        self.status = count == 0 ? nil : status
        let color = status.color(in: theme.colors)
        mark.set(status: status, colors: theme.colors)
        countLabel.setChromeText("\(count)", font: ChromeFont.badge, color: color)
        badgeWidth = Self.markSize + Self.gap + ceil(countLabel.intrinsicContentSize.width)
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

    /// "2 commands running" for tooltips; nil when none is.
    static func summary(ofRunningCommands count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 command running" : "\(count) commands running"
    }

    override func layout() {
        super.layout()
        mark.frame = NSRect(
            x: 0,
            y: floor((bounds.height - Self.markSize) / 2),
            width: Self.markSize,
            height: Self.markSize
        )
        let size = countLabel.intrinsicContentSize
        countLabel.frame = NSRect(
            x: Self.markSize + Self.gap,
            y: floor((bounds.height - size.height) / 2),
            width: ceil(size.width),
            height: size.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
