import AppKit
import GhosttyKit
import QuartzCore

struct TerminalConfig {
    var command: String? = nil
    var args: [String] = []
    var workingDirectory: String?
    var env: [String: String] = [:]
    var launchScript: String?
    var waitAfterCommand: Bool = true

    static let defaultShell = TerminalConfig()

    static func forAgent(
        _ profile: AgentProfile,
        cwd: String? = nil,
        paneId: String,
        tabId: String
    ) -> TerminalConfig {
        var config = TerminalConfig()
        config.workingDirectory = cwd ?? profile.cwd
        config.waitAfterCommand = true
        config.env = profile.env ?? [:]

        let executable = Bundle.main.executableURL?.path
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        config.env["SOPRANO_BIN"] = executable
        config.env["SOPRANO_PANE_ID"] = paneId
        config.env["SOPRANO_TAB_ID"] = tabId
        config.env["SOPRANO_AGENT_PROFILE"] = profile.id
        config.env["SOPRANO_AGENT_NAME"] = profile.name
        config.env["TERM_PROGRAM"] = "Soprano"

        var arguments = profile.args
        switch profile.id {
        case "codex":
            arguments.append(contentsOf: codexIntegrationArguments(executable: executable))
        case "claude-code":
            if let settings = claudeIntegrationSettings() {
                arguments.append(contentsOf: ["--settings", settings])
            }
        case "opencode":
            if let pluginURL = Bundle.module.url(
                forResource: "SopranoOpenCodePlugin",
                withExtension: "js"
            ), let configContent = openCodeConfigContent(pluginURL: pluginURL) {
                config.env["OPENCODE_CONFIG_CONTENT"] = configContent
            }
        default:
            break
        }

        if let launchScript = profile.launchScript, !launchScript.isEmpty {
            config.launchScript = launchScript
            config.command = nil
        } else {
            let fullCommand = ([profile.command] + arguments)
                .map(shellQuoted)
                .joined(separator: " ")
            config.command = fullCommand.isEmpty ? nil : fullCommand
        }
        return config
    }

    private static func codexIntegrationArguments(executable: String) -> [String] {
        let notifyCommand = [
            executable,
            "agent-event",
            "needs-input",
            "--notify",
            "--title",
            "Codex",
            "--body",
            "Response ready",
        ]
        let notifyValue = notifyCommand.map(tomlQuoted).joined(separator: ",")
        return [
            "-c", "notify=[\(notifyValue)]",
            "-c", "tui.notifications=[\"approval-requested\"]",
            "-c", "tui.notification_method=\"osc9\"",
            "-c", "tui.notification_condition=\"always\"",
        ]
    }

    private static func claudeIntegrationSettings() -> String? {
        func command(_ state: String, notify: Bool = false, body: String? = nil) -> String {
            var value = "test -z \"$SOPRANO_BIN\" || \"$SOPRANO_BIN\" agent-event \(state)"
            if notify {
                value += " --notify --title \"Claude Code\""
            }
            if let body {
                value += " --body \"\(body)\""
            }
            return value
        }

        func hook(_ command: String) -> [[String: Any]] {
            [["hooks": [["type": "command", "command": command, "timeout": 5]]]]
        }

        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": hook(command("ready")),
                "UserPromptSubmit": hook(command("running")),
                "Stop": hook(command("needs-input", notify: true, body: "Response ready")),
                "Notification": [[
                    "matcher": "permission_prompt|elicitation_dialog",
                    "hooks": [[
                        "type": "command",
                        "command": command(
                            "needs-input",
                            notify: true,
                            body: "Approval or input required"
                        ),
                        "timeout": 5,
                    ]],
                ]],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func openCodeConfigContent(pluginURL: URL) -> String? {
        let inherited = ProcessInfo.processInfo.environment["OPENCODE_CONFIG_CONTENT"]
        var content: [String: Any] = [:]

        if let inherited, !inherited.isEmpty {
            guard let data = inherited.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any]
            else { return nil }
            content = dictionary
        }

        var plugins = content["plugin"] as? [String] ?? []
        if !plugins.contains(pluginURL.absoluteString) {
            plugins.append(pluginURL.absoluteString)
        }
        content["plugin"] = plugins

        guard let data = try? JSONSerialization.data(withJSONObject: content) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func tomlQuoted(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return encoded
    }
}

final class TerminalSurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    let paneId: String
    let tabId: String
    var onFocusRequested: (() -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onAgentInputSubmitted: (() -> Void)?
    private let config: TerminalConfig
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0
    private var lastXScale: CGFloat = 0
    private var lastYScale: CGFloat = 0

    init(paneId: String, tabId: String, config: TerminalConfig = .defaultShell) {
        self.paneId = paneId
        self.tabId = tabId

        var scopedConfig = config
        let executable = Bundle.main.executableURL?.path
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        scopedConfig.env["SOPRANO_BIN"] = executable
        scopedConfig.env["SOPRANO_PANE_ID"] = paneId
        scopedConfig.env["SOPRANO_TAB_ID"] = tabId
        scopedConfig.env["TERM_PROGRAM"] = "Soprano"
        self.config = scopedConfig
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setup()
        createSurface()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
    }

    private func createSurface() {
        guard let app = GhosttyAppManager.shared.app else { return }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        surfaceConfig.scale_factor = scale

        surfaceConfig.wait_after_command = config.waitAfterCommand

        let envPairs = Array(config.env)
        var envVars = Array(
            repeating: ghostty_env_var_s(key: nil, value: nil),
            count: envPairs.count
        )

        func withEnvCStrings(_ index: Int, _ body: () -> Void) {
            guard index < envPairs.count else {
                body()
                return
            }

            let entry = envPairs[index]
            entry.key.withCString { cKey in
                entry.value.withCString { cValue in
                    envVars[index] = ghostty_env_var_s(key: cKey, value: cValue)
                    withEnvCStrings(index + 1, body)
                }
            }
        }

        withEnvCStrings(0) {
            surfaceConfig.env_var_count = envVars.count
            envVars.withUnsafeMutableBufferPointer { envBuffer in
                surfaceConfig.env_vars = envBuffer.baseAddress

                withOptionalCString(config.workingDirectory) { cDir in
                    surfaceConfig.working_directory = cDir

                    withOptionalCString(config.command) { cCommand in
                        surfaceConfig.command = cCommand

                        let initialInput = config.launchScript.map { "\($0)\n" }
                        withOptionalCString(initialInput) { cInitialInput in
                            surfaceConfig.initial_input = cInitialInput
                            surface = ghostty_surface_new(app, &surfaceConfig)
                        }
                    }
                }
            }
        }

        guard let surface else {
            print("[Soprano] Failed to create ghostty surface for pane \(paneId)")
            return
        }

        if let screen = window?.screen ?? NSScreen.main,
           let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        let backingSize = convertToBacking(bounds).size
        let xScale = bounds.width > 0 ? backingSize.width / bounds.width : scale
        let yScale = bounds.height > 0 ? backingSize.height / bounds.height : scale
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        let wpx = UInt32(max(1, floor(backingSize.width)))
        let hpx = UInt32(max(1, floor(backingSize.height)))
        ghostty_surface_set_size(surface, wpx, hpx)
        lastPixelWidth = wpx
        lastPixelHeight = hpx
        lastXScale = xScale
        lastYScale = yScale
    }

    func terminalTitleDidChange(_ title: String) {
        onTitleChanged?(title)
    }

    func terminalDesktopNotification(title: String, body: String) {
        NotificationCenter.default.post(
            name: .ghosttyDesktopNotification,
            object: self,
            userInfo: [
                "paneId": paneId,
                "tabId": tabId,
                "title": title,
                "body": body,
            ]
        )
    }

    private func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        if let value, !value.isEmpty {
            return value.withCString(body)
        }
        return body(nil)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
            NotificationCenter.default.post(
                name: .ghosttyDidFocusSurface,
                object: self,
                userInfo: ["paneId": paneId, "tabId": tabId]
            )
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateSurfaceSize()
            if let surface,
               let screen = window?.screen ?? NSScreen.main,
               let displayID = screen.displayID,
               displayID != 0 {
                ghostty_surface_set_display_id(surface, displayID)
            }
        }
    }

    /// The renderer vsyncs against a CVDisplayLink keyed by display ID. Without
    /// this, moving the window to another screen leaves the surface synced to the
    /// old display and content stops updating (appears frozen).
    @objc private func windowDidChangeScreen(_ notification: Notification) {
        guard let window,
              let changedWindow = notification.object as? NSWindow,
              changedWindow == window,
              let screen = window.screen,
              let surface
        else { return }

        ghostty_surface_set_display_id(surface, screen.displayID ?? 0)

        // The new screen may have a different scale factor.
        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface, let window else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let backingSize = convertToBacking(NSRect(origin: .zero, size: size)).size
        guard backingSize.width > 0, backingSize.height > 0 else { return }

        let xScale = backingSize.width / size.width
        let yScale = backingSize.height / size.height
        let layerScale = max(1.0, window.backingScaleFactor)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = layerScale
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = CGSize(
                width: floor(backingSize.width),
                height: floor(backingSize.height)
            )
        }
        CATransaction.commit()

        let wpx = UInt32(max(1, floor(backingSize.width)))
        let hpx = UInt32(max(1, floor(backingSize.height)))

        let scaleChanged = abs(xScale - lastXScale) > 0.001 || abs(yScale - lastYScale) > 0.001
        let sizeChanged = wpx != lastPixelWidth || hpx != lastPixelHeight
        guard scaleChanged || sizeChanged else { return }

        if scaleChanged {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }

        if sizeChanged {
            ghostty_surface_set_size(surface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }

        let translationEvent = translationEvent(for: event, surface: surface)
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let text = translationEvent.ghosttyCharacters

        sendKeyEvent(
            action,
            event: event,
            translationEvent: translationEvent,
            text: text
        )

        if (event.keyCode == 36 || event.keyCode == 76),
           !event.modifierFlags.contains(.shift) {
            onAgentInputSubmitted?()
        }
    }

    override func keyUp(with event: NSEvent) {
        guard surface != nil else {
            super.keyUp(with: event)
            return
        }

        sendKeyEvent(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard surface != nil else {
            super.flagsChanged(with: event)
            return
        }

        sendKeyEvent(GHOSTTY_ACTION_PRESS, event: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else {
            super.mouseDown(with: event)
            return
        }
        onFocusRequested?()
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
        ghostty_surface_mouse_pos(surface, pt.x, bounds.height - pt.y, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else {
            super.mouseUp(with: event)
            return
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pt.x, bounds.height - pt.y, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pt.x, bounds.height - pt.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else {
            super.scrollWheel(with: event)
            return
        }
        let scrollMods = ghostty_input_scroll_mods_t(modsFromEvent(event).rawValue)
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else {
            super.rightMouseDown(with: event)
            return
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else {
            super.rightMouseUp(with: event)
            return
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func sendKeyEvent(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) {
        guard let surface else { return }

        var keyEvent = ghosttyKeyEvent(
            action,
            event: event,
            translationEvent: translationEvent,
            composing: composing
        )

        if let text, text.count > 0,
           let codepoint = text.utf8.first, codepoint >= 0x20 {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    private func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        composing: Bool = false
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = consumedMods(
            originalFlags: event.modifierFlags,
            translationFlags: translationEvent?.modifierFlags
        )
        keyEvent.text = nil
        keyEvent.composing = composing
        keyEvent.unshifted_codepoint = unshiftedCodepoint(for: event)
        return keyEvent
    }

    private func consumedMods(
        originalFlags: NSEvent.ModifierFlags,
        translationFlags: NSEvent.ModifierFlags?
    ) -> ghostty_input_mods_e {
        let textFlags = (translationFlags ?? originalFlags).subtracting([.control, .command])
        return modsFromFlags(textFlags)
    }

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private func unshiftedCodepoint(for event: NSEvent) -> UInt32 {
        guard (event.type == .keyDown || event.type == .keyUp),
              let chars = event.characters(byApplyingModifiers: []),
              let codepoint = chars.unicodeScalars.first
        else {
            return 0
        }

        return codepoint.value
    }

    private func translationEvent(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
        let translatedGhosttyMods = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        let translatedFlags = mergeTranslationFlags(
            event.modifierFlags,
            translatedFlags: modifierFlags(from: translatedGhosttyMods)
        )

        if translatedFlags == event.modifierFlags {
            return event
        }

        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translatedFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: translatedFlags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func mergeTranslationFlags(
        _ originalFlags: NSEvent.ModifierFlags,
        translatedFlags: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        var merged = originalFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translatedFlags.contains(flag) {
                merged.insert(flag)
            } else {
                merged.remove(flag)
            }
        }
        return merged
    }

    private func modifierFlags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    func destroySurface() {
        if let surface {
            ghostty_surface_free(surface)
            self.surface = nil
        }
    }

    func sendText(_ text: String) {
        guard let surface else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    func recreateSurface() {
        destroySurface()
        createSurface()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated {
            destroySurface()
        }
    }
}

extension NSScreen {
    var displayID: UInt32? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return screenNumber.uint32Value
    }
}

private extension NSEvent {
    var ghosttyCharacters: String? {
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
