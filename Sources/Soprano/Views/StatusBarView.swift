import AppKit

/// Bottom status bar showing keybinding mode, pane list, and notification count.
final class StatusBarView: NSView {
    let agentManager: AgentManager
    let themeManager: ThemeManager

    private var brandLabel: NSTextField!
    private var modeLabel: NSTextField!
    private var paneCountLabel: NSTextField!

    init(agentManager: AgentManager, themeManager: ThemeManager) {
        self.agentManager = agentManager
        self.themeManager = themeManager
        super.init(frame: .zero)
        wantsLayer = true
        setupViews()

        agentManager.addObserver(id: "StatusBarView") { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupViews() {
        let theme = themeManager.currentTheme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor

        // Brand label
        brandLabel = NSTextField(labelWithString: "SOPRANO")
        brandLabel.font = .systemFont(ofSize: 10, weight: .bold)
        brandLabel.textColor = theme.colors.accent
        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(brandLabel)

        // Mode label
        modeLabel = NSTextField(labelWithString: "NORMAL")
        modeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        modeLabel.textColor = theme.colors.textMuted
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeLabel)

        // Pane count
        paneCountLabel = NSTextField(labelWithString: "1 pane")
        paneCountLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        paneCountLabel.textColor = theme.colors.textMuted
        paneCountLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paneCountLabel)

        NSLayoutConstraint.activate([
            brandLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            brandLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            modeLabel.leadingAnchor.constraint(equalTo: brandLabel.trailingAnchor, constant: 16),
            modeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            paneCountLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            paneCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func setKeybindingMode(_ mode: KeybindingState) {
        let theme = themeManager.currentTheme
        switch mode {
        case .normal:
            modeLabel.stringValue = "NORMAL"
            modeLabel.textColor = theme.colors.textMuted
        case .prefix:
            modeLabel.stringValue = "PREFIX"
            modeLabel.textColor = theme.colors.accent
        case .copy:
            modeLabel.stringValue = "COPY"
            modeLabel.textColor = theme.colors.accent
        case .copySelection:
            modeLabel.stringValue = "SELECT"
            modeLabel.textColor = theme.colors.blue
        }
    }

    func refreshTheme() {
        let theme = themeManager.currentTheme
        layer?.backgroundColor = theme.colors.bgPanel.cgColor
        brandLabel.textColor = theme.colors.accent
        if modeLabel.stringValue == "PREFIX" || modeLabel.stringValue == "COPY" {
            modeLabel.textColor = theme.colors.accent
        } else if modeLabel.stringValue == "SELECT" {
            modeLabel.textColor = theme.colors.blue
        } else {
            modeLabel.textColor = theme.colors.textMuted
        }
        refresh()
    }

    private func refresh() {
        let theme = themeManager.currentTheme
        let paneCount = agentManager.paneCount
        let windowCount = agentManager.windowCount
        let panes = "\(paneCount) pane\(paneCount == 1 ? "" : "s")"
        let windows = "\(windowCount) window\(windowCount == 1 ? "" : "s")"
        var components = [windows, panes]
        if agentManager.readyAgentCount > 0 {
            components.append("\(agentManager.readyAgentCount) READY")
        }
        if agentManager.attentionCount > 0 {
            components.append("\(agentManager.attentionCount) NEEDS ATTENTION")
        }
        let base = components.joined(separator: " · ")
        if agentManager.maximizedPaneId != nil {
            paneCountLabel.stringValue = "\(base) · MAXIMIZED"
            paneCountLabel.textColor = theme.colors.accent
        } else if agentManager.attentionCount > 0 {
            paneCountLabel.stringValue = base
            paneCountLabel.textColor = theme.colors.blue
        } else {
            paneCountLabel.stringValue = base
            paneCountLabel.textColor = theme.colors.textMuted
        }
    }
}
