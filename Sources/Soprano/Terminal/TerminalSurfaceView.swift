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

    static func forAgent(_ profile: AgentProfile, cwd: String? = nil) -> TerminalConfig {
        var config = TerminalConfig()
        config.workingDirectory = cwd ?? profile.cwd
        config.waitAfterCommand = true

        if let launchScript = profile.launchScript, !launchScript.isEmpty {
            config.launchScript = launchScript
            config.command = nil
        } else {
            let fullCommand = ([profile.command] + profile.args).joined(separator: " ")
            config.command = fullCommand.isEmpty ? nil : fullCommand
        }

        config.env = profile.env ?? [:]
        return config
    }
}

final class TerminalSurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    let paneId: String
    var onFocusRequested: (() -> Void)?
    private let config: TerminalConfig
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0
    private var lastXScale: CGFloat = 0
    private var lastYScale: CGFloat = 0

    init(paneId: String, config: TerminalConfig = .defaultShell) {
        self.paneId = paneId
        self.config = config
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        setup()
        createSurface()
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

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0

        let text = event.characters ?? ""
        if text.isEmpty {
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        } else {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else {
            super.keyUp(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else {
            super.flagsChanged(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
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
