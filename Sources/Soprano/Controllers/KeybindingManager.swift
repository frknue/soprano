import AppKit

struct PaneNavigationClaimRegistry {
    private var countsByTarget: [TerminalTarget: [String: Int]] = [:]
    private var workspaceRestoreGeneration: Int?

    mutating func enable(source: String, for target: TerminalTarget) {
        countsByTarget[target, default: [:]][source, default: 0] += 1
    }

    mutating func disable(source: String, for target: TerminalTarget) {
        guard let count = countsByTarget[target]?[source], count > 0 else { return }
        if count == 1 {
            countsByTarget[target]?[source] = nil
            if countsByTarget[target]?.isEmpty == true {
                countsByTarget[target] = nil
            }
        } else {
            countsByTarget[target]?[source] = count - 1
        }
    }

    func hasClaims(for target: TerminalTarget) -> Bool {
        countsByTarget[target]?.isEmpty == false
    }

    mutating func synchronize(
        validTargets: Set<TerminalTarget>,
        workspaceRestoreGeneration: Int
    ) {
        if let previousGeneration = self.workspaceRestoreGeneration,
           previousGeneration != workspaceRestoreGeneration {
            countsByTarget.removeAll()
        } else {
            countsByTarget = countsByTarget.filter { validTargets.contains($0.key) }
        }
        self.workspaceRestoreGeneration = workspaceRestoreGeneration
    }
}

@MainActor
protocol KeybindingDelegate: AnyObject {
    func keybindingToggleSidebar()
    func keybindingSaveSession()
    func keybindingOpenSettings()
    func keybindingOpenCommandPalette()
    func keybindingOpenProjectSearch()
    func keybindingZoom(delta: Int)
    func keybindingZoomReset()
}

final class KeybindingManager: @unchecked Sendable {
    let agentManager: AgentManager
    weak var delegate: KeybindingDelegate?

    private(set) var config: KeyBindingConfig
    private(set) var state: KeybindingState = .normal
    private var prefixTimer: Timer?
    private var eventMonitor: Any?
    private var appResignObserver: NSObjectProtocol?
    private var paneNavigationObserver: NSObjectProtocol?
    private var paneNavigationPassthroughClaims = PaneNavigationClaimRegistry()
    private let paneNavigationClaimObserverId = "KeybindingManager"
    private(set) var isControlKeyHeld: Bool

    var stateChangeHandler: (@MainActor (KeybindingState) -> Void)?
    var controlKeyStateChangeHandler: (@MainActor (Bool) -> Void)?

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
        self.config = DefaultKeybindings.load()
        self.isControlKeyHeld = NSEvent.modifierFlags.contains(.control)
        startMonitoring()
        observeApplicationDeactivation()
        observePaneNavigationRequests()
        observePaneNavigationClaimLifecycle()
    }

    deinit {
        stopMonitoring()
        prefixTimer?.invalidate()
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
        }
        if let paneNavigationObserver {
            DistributedNotificationCenter.default().removeObserver(paneNavigationObserver)
        }
        agentManager.removeObserver(id: paneNavigationClaimObserverId)
    }

    private func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            // Optional chaining flattens the NSEvent? result, so `?? event`
            // must only cover the self-is-gone case — otherwise it would
            // resurrect events handleKeyDown intentionally swallowed.
            guard let self else { return event }
            if event.type == .flagsChanged {
                self.setControlKeyHeld(event.modifierFlags.contains(.control))
                return event
            }
            return self.handleKeyDown(event: event)
        }
    }

    private func observeApplicationDeactivation() {
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setControlKeyHeld(false)
        }
    }

    private func observePaneNavigationRequests() {
        let appProcessId = String(ProcessInfo.processInfo.processIdentifier)
        paneNavigationObserver = DistributedNotificationCenter.default().addObserver(
            forName: PaneNavigationCommand.notificationName(appProcessId: appProcessId),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let paneId = info["paneId"] as? String,
                  let tabId = info["tabId"] as? String
            else {
                return
            }
            let target = TerminalTarget(paneId: paneId, tabId: tabId)

            if let mode = info["passthrough"] as? String,
               let source = info["source"] as? String {
                if mode == "enable" {
                    self.paneNavigationPassthroughClaims.enable(source: source, for: target)
                } else if mode == "disable" {
                    self.paneNavigationPassthroughClaims.disable(source: source, for: target)
                }
                return
            }

            guard target == self.activeTerminalTarget,
                  let rawDirection = info["direction"] as? String,
                  let direction = NavigationDirection(rawValue: rawDirection)
            else {
                return
            }

            self.agentManager.navigateToPane(direction: direction)
        }
    }

    private func observePaneNavigationClaimLifecycle() {
        synchronizePaneNavigationClaims()
        agentManager.addObserver(id: paneNavigationClaimObserverId) { [weak self] in
            self?.synchronizePaneNavigationClaims()
        }
    }

    private func synchronizePaneNavigationClaims() {
        let validTargets = Set(agentManager.panes.values.flatMap { pane in
            pane.tabs.map { TerminalTarget(paneId: pane.id, tabId: $0.id) }
        })
        paneNavigationPassthroughClaims.synchronize(
            validTargets: validTargets,
            workspaceRestoreGeneration: agentManager.workspaceRestoreGeneration
        )
    }

    private func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    private func handleKeyDown(event: NSEvent) -> NSEvent? {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if isCtrlOnly(flags) && key == config.prefixKey.lowercased() {
            startPrefixMode()
            return nil
        }

        if state == .prefix {
            if let binding = config.bindings.first(where: { matchesPrefixBinding($0, key: key, flags: flags) }) {
                executeBinding(binding)
            }
            clearPrefixMode()
            return nil
        }

        if let binding = config.bindings.first(where: { matchesDirectBinding($0, key: key, flags: flags) }) {
            // Terminal applications get first refusal for Ctrl+H/J/K/L. Vim,
            // tmux, fuzzy finders, and completion menus can consume the keys;
            // the navigation bridge bubbles them back to Soprano only when an
            // inner layout reaches its boundary.
            if Self.paneNavigationBindingIds.contains(binding.id),
               let activeTarget = activeTerminalTarget,
               paneNavigationPassthroughClaims.hasClaims(for: activeTarget) {
                return event
            }

            // Let AppKit dispatch standard Command-menu equivalents through
            // the main menu. This is more reliable than swallowing them in a
            // local monitor while a terminal surface is first responder.
            if binding.id == "command-palette" || binding.id == "open-project" {
                return event
            }
            executeBinding(binding)
            return nil
        }

        if isCtrlOnly(flags), agentManager.focusPane(shortcutKey: key) {
            return nil
        }

        return event
    }

    private func matchesPrefixBinding(_ binding: KeyBinding, key: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard binding.mode == .prefix else { return false }
        guard binding.key == key else { return false }
        return hasShift(flags) == (binding.shift == true)
    }

    private func matchesDirectBinding(_ binding: KeyBinding, key: String, flags: NSEvent.ModifierFlags) -> Bool {
        guard binding.mode == .direct else { return false }

        // Ghostty accepts both Command+= and Command+plus for increasing the
        // font size. Depending on the keyboard layout, plus may be a dedicated
        // key or a shifted equal, so accept either representation here.
        let isZoomInAlias = binding.id == "zoom-in"
            && binding.key == "="
            && (key == "=" || key == "+")
        guard binding.key == key || isZoomInAlias else { return false }

        return hasCtrl(flags) == (binding.ctrl == true)
            && hasMeta(flags) == (binding.meta == true)
            && (isZoomInAlias || hasShift(flags) == (binding.shift == true))
    }

    private func isCtrlOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        hasCtrl(flags) && !hasMeta(flags) && !hasShift(flags)
    }

    private func hasCtrl(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.control)
    }

    private func hasMeta(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command)
    }

    private func hasShift(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.shift)
    }

    private static let paneNavigationBindingIds: Set<String> = [
        "nav-left",
        "nav-down",
        "nav-up",
        "nav-right",
    ]

    private var activeTerminalTarget: TerminalTarget? {
        guard let tabId = agentManager.panes[agentManager.activePaneId]?.activeTab?.id else {
            return nil
        }
        return TerminalTarget(paneId: agentManager.activePaneId, tabId: tabId)
    }

    private func startPrefixMode() {
        state = .prefix
        notifyStateChange(.prefix)

        prefixTimer?.invalidate()
        let timeoutSeconds = TimeInterval(config.prefixTimeoutMs) / 1000.0
        prefixTimer = Timer.scheduledTimer(
            timeInterval: timeoutSeconds,
            target: self,
            selector: #selector(handlePrefixTimeout(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    private func clearPrefixMode() {
        state = .normal
        notifyStateChange(.normal)
        prefixTimer?.invalidate()
        prefixTimer = nil
    }

    private func notifyStateChange(_ nextState: KeybindingState) {
        MainActor.assumeIsolated {
            stateChangeHandler?(nextState)
        }
    }

    private func setControlKeyHeld(_ isHeld: Bool) {
        guard isControlKeyHeld != isHeld else { return }
        isControlKeyHeld = isHeld
        MainActor.assumeIsolated {
            controlKeyStateChangeHandler?(isHeld)
        }
    }

    @objc
    private func handlePrefixTimeout(_ timer: Timer) {
        clearPrefixMode()
    }

    private func executeBinding(_ binding: KeyBinding) {
        if binding.id.hasPrefix("select-window-"),
           let windowNumber = Int(binding.id.dropFirst("select-window-".count))
        {
            agentManager.activateWindow(number: windowNumber)
            return
        }

        switch binding.id {
        case "nav-left":
            agentManager.navigateToPane(direction: .left)
        case "nav-down":
            agentManager.navigateToPane(direction: .down)
        case "nav-up":
            agentManager.navigateToPane(direction: .up)
        case "nav-right":
            agentManager.navigateToPane(direction: .right)
        case "previous-window":
            agentManager.activatePreviousWindow()
        case "next-window":
            agentManager.activateNextWindow()

        case "resize-left":
            agentManager.resizePane(direction: .left, tickPercent: config.resizeTickPercent)
        case "resize-down":
            agentManager.resizePane(direction: .down, tickPercent: config.resizeTickPercent)
        case "resize-up":
            agentManager.resizePane(direction: .up, tickPercent: config.resizeTickPercent)
        case "resize-right":
            agentManager.resizePane(direction: .right, tickPercent: config.resizeTickPercent)

        case "split-horizontal":
            _ = agentManager.splitPane(direction: .horizontal, paneId: agentManager.activePaneId)
        case "split-vertical":
            _ = agentManager.splitPane(direction: .vertical, paneId: agentManager.activePaneId)
        case "close-pane", "kill-pane":
            agentManager.closePane(agentManager.activePaneId)
        case "maximize-pane":
            agentManager.toggleMaximize()

        case "new-pane-tab":
            _ = agentManager.addTabToPane(agentManager.activePaneId, type: .terminal)
        case "next-pane-tab":
            agentManager.nextTab(agentManager.activePaneId)
        case "prev-pane-tab":
            agentManager.prevTab(agentManager.activePaneId)
        case "close-pane-tab":
            closeActiveTab()

        case "launch-codex":
            _ = agentManager.spawnAgent("codex")
        case "launch-claude-code":
            _ = agentManager.spawnAgent("claude-code")
        case "launch-opencode":
            _ = agentManager.spawnAgent("opencode")

        case "command-palette":
            invokeDelegate { $0.keybindingOpenCommandPalette() }
        case "open-project":
            invokeDelegate { $0.keybindingOpenProjectSearch() }
        case "new-window":
            _ = agentManager.createWindow()
        case "new-terminal":
            _ = agentManager.spawnTerminal()
        case "close-active":
            agentManager.closePane(agentManager.activePaneId)
        case "save-session":
            invokeDelegate { $0.keybindingSaveSession() }
        case "toggle-sidebar":
            invokeDelegate { $0.keybindingToggleSidebar() }
        case "open-settings":
            invokeDelegate { $0.keybindingOpenSettings() }
        case "zoom-in":
            invokeDelegate { $0.keybindingZoom(delta: 1) }
        case "zoom-out":
            invokeDelegate { $0.keybindingZoom(delta: -1) }
        case "zoom-reset":
            invokeDelegate { $0.keybindingZoomReset() }
        default:
            break
        }
    }

    private func closeActiveTab() {
        let paneId = agentManager.activePaneId
        guard let pane = agentManager.panes[paneId],
              let tab = pane.activeTab
        else { return }

        agentManager.removeTabFromPane(paneId, tabId: tab.id)
    }

    private func invokeDelegate(_ action: @MainActor (KeybindingDelegate) -> Void) {
        guard let delegate else { return }
        MainActor.assumeIsolated {
            action(delegate)
        }
    }

}
