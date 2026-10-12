import AppKit

@MainActor
final class DashboardController: NSObject {
    let window: ConsolePanel
    private let root = ConsoleBackground()
    private let clock = Desktop.label("", size: 33)
    private let date = Desktop.label("", color: Desktop.theme.colors.textMuted)
    private let memory = Desktop.label("")
    private let battery = Desktop.label("")
    private let uptime = Desktop.label("")
    private let apps = Desktop.label("")
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var isRaised = false
    private var previousApp: NSRunningApplication?
    var onOverview: (() -> Void)?
    var onPermissions: (() -> Void)?

    override init() {
        window = ConsolePanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 340),
            styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.title = "Soprano Desktop Dashboard"
        window.isOpaque = true
        window.backgroundColor = Desktop.theme.colors.bgBase
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = root
        window.onCancel = { [weak self] in self?.lower() }
        build()
        position()
        lower()
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func showOnDesktop() { window.orderFrontRegardless() }

    func toggle() {
        if isRaised { lower(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        isRaised = true
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        animateIn()
    }

    func lower() {
        isRaised = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        if window.isKeyWindow { window.resignKey() }
        if let previousApp, previousApp.bundleIdentifier != Desktop.bundleID { _ = previousApp.activate(options: []) }
        previousApp = nil
    }

    func snapshot(to url: URL) throws { try Desktop.snapshot(root, to: url) }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: area.maxX - window.frame.width - 28, y: area.minY + 28))
    }

    @objc private func screenChanged() { position() }

    private func animateIn() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window.animator().alphaValue = 1
        }
    }

    private func build() {
        let colors = Desktop.theme.colors
        let stripe = RetroStripeView(layout: .slanted, colors: colors.stripe)
        stripe.frame = NSRect(x: 18, y: 290, width: 36, height: 28)
        root.addSubview(stripe)
        place(Desktop.label("mission control", color: colors.accent), x: 65, y: 300, width: 285)
        place(Desktop.label("personal workstation", color: colors.textMuted), x: 65, y: 282, width: 285)
        place(clock, x: 18, y: 231, width: 350, height: 42)
        place(date, x: 20, y: 208, width: 350)
        let rule = RetroRuleView(axis: .horizontal, color: colors.borderStrong)
        rule.frame = NSRect(x: 18, y: 193, width: 354, height: 4)
        root.addSubview(rule)
        place(memory, x: 20, y: 170, width: 350)
        place(battery, x: 20, y: 148, width: 350)
        place(uptime, x: 20, y: 126, width: 350)
        place(apps, x: 20, y: 104, width: 350)
        let launchers = Launcher.available
        let tileWidth = min(CGFloat(66), 352 / CGFloat(max(1, launchers.count)))
        for (index, launcher) in launchers.enumerated() {
            let tile = LauncherTile(launcher: launcher)
            tile.frame = NSRect(x: 20 + CGFloat(index) * (tileWidth + 4), y: 46, width: tileWidth, height: 46)
            tile.onLaunch = { [weak self] in self?.lower() }
            root.addSubview(tile)
        }
        let overview = RetroButton(title: "overview  ⌃⌥space", theme: Desktop.theme, target: self, action: #selector(openOverview))
        overview.frame = NSRect(x: 18, y: 12, width: 196, height: 24)
        root.addSubview(overview)
        let access = RetroButton(title: "permissions", theme: Desktop.theme, target: self, action: #selector(openPermissions))
        access.frame = NSRect(x: 224, y: 12, width: 148, height: 24)
        root.addSubview(access)
    }

    private func place(_ label: NSTextField, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 18) {
        label.frame = NSRect(x: x, y: y, width: width, height: height)
        root.addSubview(label)
    }

    func update() {
        let metrics = SystemMetrics.read()
        let now = Date()
        clock.setRetroText(now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)), color: Desktop.theme.colors.textPrimary, size: 33)
        date.setRetroText(now.formatted(.dateTime.weekday(.wide).day().month(.wide)), color: Desktop.theme.colors.textMuted)
        memory.setRetroText("memory resident   \(metrics.memory)", color: Desktop.theme.colors.textPrimary)
        battery.setRetroText("power             \(metrics.battery)", color: Desktop.theme.colors.textPrimary)
        uptime.setRetroText("uptime            \(metrics.uptime)", color: Desktop.theme.colors.textPrimary)
        apps.setRetroText("applications      \(metrics.appCount)  /  load \(metrics.load)", color: Desktop.theme.colors.textMuted)
    }

    @objc private func openOverview() { lower(); onOverview?() }
    @objc private func openPermissions() { onPermissions?() }
}

@MainActor
final class LauncherTile: NSButton {
    private let launcher: Launcher
    private let icon: NSImage?
    var onLaunch: (() -> Void)?

    init(launcher: Launcher) {
        self.launcher = launcher
        icon = NSImage(contentsOf: Desktop.support.appendingPathComponent("assets/\(launcher.id).png"))
        super.init(frame: .zero)
        title = launcher.name
        isBordered = false
        target = self
        action = #selector(launch)
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel("Open \(launcher.name)")
        toolTip = launcher.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let colors = Desktop.theme.colors
        (isHighlighted ? colors.bgOverlay : colors.bgPanel).setFill()
        bounds.fill()
        (isHighlighted ? colors.accent : colors.borderStrong).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        icon?.draw(in: NSRect(x: (bounds.width - 28) / 2, y: 17, width: 28, height: 28))
        let label = RetroText.display(launcher.name, color: colors.textMuted, tracking: 0)
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 1))
    }

    @objc private func launch() {
        do { try launcher.open(); onLaunch?() }
        catch { NSApp.presentError(error) }
    }
}
