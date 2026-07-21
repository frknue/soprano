import AppKit

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
    private(set) var isControlKeyHeld: Bool

    var stateChangeHandler: (@MainActor (KeybindingState) -> Void)?
    var controlKeyStateChangeHandler: (@MainActor (Bool) -> Void)?

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
        self.config = DefaultKeybindings.load()
        self.isControlKeyHeld = NSEvent.modifierFlags.contains(.control)
        startMonitoring()
        observeApplicationDeactivation()
    }

    deinit {
        stopMonitoring()
        prefixTimer?.invalidate()
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
        }
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
            executeBinding(binding)
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
        guard binding.key == key else { return false }

        return hasCtrl(flags) == (binding.ctrl == true)
            && hasMeta(flags) == (binding.meta == true)
            && hasShift(flags) == (binding.shift == true)
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
