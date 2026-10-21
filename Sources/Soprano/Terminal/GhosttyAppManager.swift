import AppKit
import GhosttyKit

extension Notification.Name {
    static let ghosttyCloseSurface = Notification.Name("GhosttyCloseSurface")
    static let ghosttyDesktopNotification = Notification.Name("GhosttyDesktopNotification")
    static let ghosttyDidFocusSurface = Notification.Name("GhosttyDidFocusSurface")
    /// Posted after `ghostty_app_update_config` handed every surface the new
    /// focused config, so surfaces without focus re-apply the unfocused one.
    static let ghosttyDidUpdateConfig = Notification.Name("GhosttyDidUpdateConfig")
}

@MainActor
final class GhosttyAppManager: @unchecked Sendable {
    static let shared = GhosttyAppManager()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// `config` plus the unfocused cursor color (`ghosttyUnfocusedConfiguration`),
    /// handed to each surface without keyboard focus. Nil when it could not
    /// be built; surfaces then keep the accent cursor.
    private var unfocusedConfig: ghostty_config_t?
    private(set) var clearsSelectionOnCopy = false
    let clipboardConfirmationCoordinator = ClipboardConfirmationCoordinator(
        presenter: AppKitClipboardConfirmationPresenter()
    )
    private var isInitialized = false
    private var didBecomeObserver: NSObjectProtocol?
    private var didResignObserver: NSObjectProtocol?

    private init() {}

    func initialize(theme: AppTheme) {
        if isInitialized {
            applyAppearance(theme: theme)
            return
        }

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            print("[Soprano] ghostty_init failed with code \(initResult)")
            return
        }

        guard let primary = createConfig(
            theme: theme,
            loadDefaultFiles: true
        ) else {
            print("[Soprano] Failed to create ghostty config")
            return
        }

        var runtimeConfig = makeRuntimeConfig()
        var loadsDefaultFiles = true

        if let primaryApp = ghostty_app_new(&runtimeConfig, primary.config) {
            config = primary.config
            clearsSelectionOnCopy = primary.clearsSelectionOnCopy
            app = primaryApp
        } else {
            ghostty_config_free(primary.config)
            guard let fallback = createConfig(
                theme: theme,
                loadDefaultFiles: false
            ) else {
                print("[Soprano] Failed to allocate fallback ghostty config")
                return
            }

            if let fallbackApp = ghostty_app_new(&runtimeConfig, fallback.config) {
                config = fallback.config
                clearsSelectionOnCopy = fallback.clearsSelectionOnCopy
                app = fallbackApp
                loadsDefaultFiles = false
            } else {
                ghostty_config_free(fallback.config)
                print("[Soprano] Failed to create ghostty app")
                return
            }
        }
        unfocusedConfig = createConfig(
            theme: theme,
            loadDefaultFiles: loadsDefaultFiles,
            unfocused: true
        )?.config

        guard let app else { return }

        ghostty_app_set_focus(app, NSApp.isActive)
        observeApplicationFocusChanges()
        isInitialized = true
    }

    /// Rebuilds the terminal config for every surface, so a theme change
    /// (including `folio` following the system appearance) reaches the
    /// terminal palette.
    func applyAppearance(theme: AppTheme) {
        guard isInitialized, let app else { return }
        guard let updated = createConfig(
            theme: theme,
            loadDefaultFiles: true
        ) else {
            print("[Soprano] Failed to apply terminal theme \(theme.id)")
            return
        }
        let updatedUnfocused = createConfig(
            theme: theme,
            loadDefaultFiles: true,
            unfocused: true
        )?.config

        // Every surface derives its own copy synchronously, so the old
        // configs can be freed as soon as the surfaces have the new ones.
        let previous = config
        let previousUnfocused = unfocusedConfig
        config = updated.config
        unfocusedConfig = updatedUnfocused
        clearsSelectionOnCopy = updated.clearsSelectionOnCopy
        ghostty_app_update_config(app, updated.config)
        NotificationCenter.default.post(name: .ghosttyDidUpdateConfig, object: self)
        if let previous {
            ghostty_config_free(previous)
        }
        if let previousUnfocused {
            ghostty_config_free(previousUnfocused)
        }
    }

    /// Gives `surface` the focused config (accent block cursor) or the
    /// unfocused one (hollow cursor in fg @ 55 %). Called only on focus
    /// changes and after a theme apply, never per frame. Returns whether a
    /// config was applied.
    @discardableResult
    func applyFocusConfig(to surface: ghostty_surface_t, focused: Bool) -> Bool {
        guard let selected = focused ? config : unfocusedConfig else { return false }
        ghostty_surface_update_config(surface, selected)
        return true
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func createConfig(
        theme: AppTheme,
        loadDefaultFiles: Bool,
        unfocused: Bool = false
    ) -> (config: ghostty_config_t, clearsSelectionOnCopy: Bool)? {
        guard let cfg = ghostty_config_new() else { return nil }
        if loadDefaultFiles {
            ghostty_config_load_default_files(cfg)
        }
        let clearsSelectionOnCopy = applySopranoCopyModeConfig(to: cfg)
        guard applyTerminalThemeConfig(theme, to: cfg) else {
            ghostty_config_free(cfg)
            return nil
        }
        if unfocused,
           !loadGeneratedConfig(
               theme.terminalColors.ghosttyUnfocusedConfiguration,
               named: "terminal-unfocused",
               into: cfg
           )
        {
            ghostty_config_free(cfg)
            return nil
        }
        ghostty_config_finalize(cfg)
        return (cfg, clearsSelectionOnCopy)
    }

    private func applySopranoCopyModeConfig(to config: ghostty_config_t) -> Bool {
        guard let configURL = SopranoResources.bundle.url(
            forResource: "SopranoCopyMode",
            withExtension: "conf"
        ) else {
            return false
        }

        configURL.path.withCString {
            ghostty_config_load_file(config, $0)
        }
        return true
    }

    private func applyTerminalThemeConfig(
        _ theme: AppTheme,
        to config: ghostty_config_t
    ) -> Bool {
        guard loadGeneratedConfig(
            theme.terminalColors.ghosttyConfiguration,
            named: "terminal-theme",
            into: config
        ) else {
            print("[Soprano] Failed to prepare terminal theme \(theme.id)")
            return false
        }
        return true
    }

    /// Ghostty only loads configuration from files, so generated lines go
    /// through a throwaway temp file that is removed once loaded.
    private func loadGeneratedConfig(
        _ contents: String,
        named name: String,
        into config: ghostty_config_t
    ) -> Bool {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "soprano-\(name)-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).conf"
            )

        do {
            try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("[Soprano] Failed to write generated ghostty config \(name): \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        fileURL.path.withCString {
            ghostty_config_load_file(config, $0)
        }
        return true
    }

    private func observeApplicationFocusChanges() {
        didBecomeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard let app = GhosttyAppManager.shared.app else { return }
                ghostty_app_set_focus(app, true)
            }
        }

        didResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard let app = GhosttyAppManager.shared.app else { return }
                ghostty_app_set_focus(app, false)
            }
        }
    }

    private func makeRuntimeConfig() -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: ghosttyWakeup,
            action_cb: ghosttyAction,
            read_clipboard_cb: ghosttyReadClipboard,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboard,
            write_clipboard_cb: ghosttyWriteClipboard,
            close_surface_cb: ghosttyCloseSurface
        )
    }
}

// MARK: - Runtime Callbacks
//
// libghostty invokes these from its own threads (wakeup) or from the main
// thread during ghostty_app_tick (clipboard, close). They must stay
// nonisolated: closures declared inside the @MainActor class inherit its
// isolation and trip Swift's dynamic actor checks when ghostty calls them
// from a background thread.

private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    // Called from any thread; schedule the tick on the main actor.
    Task { @MainActor in
        GhosttyAppManager.shared.tick()
    }
}

private func ghosttyAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard target.tag == GHOSTTY_TARGET_SURFACE,
          let surface = target.target.surface,
          let userdata = ghostty_surface_userdata(surface)
    else { return false }

    nonisolated(unsafe) let ud = userdata
    let surfaceView = MainActor.assumeIsolated {
        Unmanaged<TerminalSurfaceView>
            .fromOpaque(ud)
            .takeUnretainedValue()
    }

    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        guard let titlePointer = action.action.set_title.title,
              let title = String(validatingCString: titlePointer)
        else { return true }
        MainActor.assumeIsolated {
            surfaceView.terminalTitleDidChange(title)
        }
        return true

    case GHOSTTY_ACTION_PWD:
        guard let pwdPointer = action.action.pwd.pwd,
              let workingDirectory = String(validatingCString: pwdPointer)
        else { return true }
        MainActor.assumeIsolated {
            surfaceView.terminalWorkingDirectoryDidChange(workingDirectory)
        }
        return true

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
        let title = action.action.desktop_notification.title
            .flatMap { String(validatingCString: $0) } ?? ""
        let body = action.action.desktop_notification.body
            .flatMap { String(validatingCString: $0) } ?? ""
        MainActor.assumeIsolated {
            surfaceView.terminalDesktopNotification(title: title, body: body)
        }
        return true

    case GHOSTTY_ACTION_COMMAND_FINISHED:
        let rawExitCode = action.action.command_finished.exit_code
        let exitCode = rawExitCode >= 0 ? Int32(rawExitCode) : nil
        MainActor.assumeIsolated {
            surfaceView.terminalCommandDidFinish(exitCode: exitCode)
        }
        return true

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        let exitCode = Int32(
            truncatingIfNeeded: action.action.child_exited.exit_code
        )
        MainActor.assumeIsolated {
            surfaceView.terminalChildDidExit(exitCode: exitCode)
        }
        return false

    default:
        return false
    }
}

private func ghosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) {
    guard let userdata else { return }
    // Safe: assumeIsolated verifies we are already on the main thread, so the
    // pointers never actually cross an isolation boundary.
    nonisolated(unsafe) let ud = userdata
    nonisolated(unsafe) let st = state
    MainActor.assumeIsolated {
        let surfaceView = Unmanaged<TerminalSurfaceView>
            .fromOpaque(ud)
            .takeUnretainedValue()
        guard let surface = surfaceView.surface else { return }

        let content = ghosttyPasteboard(for: location)?
            .string(forType: .string) ?? ""
        content.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, st, false)
        }
    }
}

private func ghosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ content: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    let ownedContent = content
        .flatMap { String(validatingCString: $0) } ?? ""
    let kind: ClipboardConfirmationKind?
    switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
        kind = .paste
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
        kind = .osc52Read
    case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
        kind = .osc52Write
    default:
        kind = nil
    }

    guard let userdata else { return }
    nonisolated(unsafe) let ud = userdata
    nonisolated(unsafe) let st = state
    MainActor.assumeIsolated {
        let surfaceView = Unmanaged<TerminalSurfaceView>
            .fromOpaque(ud)
            .takeUnretainedValue()
        guard let surface = surfaceView.surface else { return }
        guard let kind else {
            completeClipboardRequest(
                surface: surface,
                content: "",
                state: st,
                confirmed: true
            )
            return
        }

        GhosttyAppManager.shared.clipboardConfirmationCoordinator.enqueue(
            surface: ObjectIdentifier(surfaceView),
            kind: kind,
            content: ownedContent,
            parentWindow: surfaceView.window
        ) { allowed in
            completeClipboardRequest(
                surface: surface,
                content: allowed ? ownedContent : "",
                state: st,
                confirmed: true
            )
        }
    }
}

private func ghosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    let ownedContent = copyClipboardContent(content, count: len)

    nonisolated(unsafe) let ud = userdata
    MainActor.assumeIsolated {
        guard let pasteboard = ghosttyPasteboard(for: location) else { return }

        if !confirm {
            pasteboard.clearContents()
            guard let text = ownedContent.first(where: { $0.mime == "text/plain" })?.data else {
                return
            }
            pasteboard.setString(text, forType: .string)
            return
        }

        guard let userdata = ud,
              let text = ownedContent.first(where: { $0.mime == "text/plain" })?.data
        else { return }
        let surfaceView = Unmanaged<TerminalSurfaceView>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard surfaceView.surface != nil else { return }

        GhosttyAppManager.shared.clipboardConfirmationCoordinator.enqueue(
            surface: ObjectIdentifier(surfaceView),
            kind: .osc52Write,
            content: text,
            parentWindow: surfaceView.window
        ) { allowed in
            guard allowed else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}

private struct OwnedClipboardContent {
    let mime: String
    let data: String
}

private func copyClipboardContent(
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    count: Int
) -> [OwnedClipboardContent] {
    guard let content, count > 0 else { return [] }

    let buffer = UnsafeBufferPointer(start: content, count: count)
    return buffer.compactMap { item in
        guard let mime = item.mime.flatMap({ String(validatingCString: $0) }),
              let data = item.data.flatMap({ String(validatingCString: $0) })
        else { return nil }
        return OwnedClipboardContent(mime: mime, data: data)
    }
}

@MainActor
private func ghosttyPasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
    switch location {
    case GHOSTTY_CLIPBOARD_STANDARD:
        .general
    case GHOSTTY_CLIPBOARD_SELECTION:
        NSPasteboard(name: NSPasteboard.Name("com.mitchellh.ghostty.selection"))
    default:
        nil
    }
}

@MainActor
private func completeClipboardRequest(
    surface: ghostty_surface_t,
    content: String,
    state: UnsafeMutableRawPointer?,
    confirmed: Bool
) {
    content.withCString { pointer in
        ghostty_surface_complete_clipboard_request(
            surface,
            pointer,
            state,
            confirmed
        )
    }
}

private func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ shouldConfirm: Bool) {
    guard let userdata else { return }
    nonisolated(unsafe) let ud = userdata
    MainActor.assumeIsolated {
        let surfaceView = Unmanaged<TerminalSurfaceView>
            .fromOpaque(ud)
            .takeUnretainedValue()
        guard let surface = surfaceView.surface else { return }
        NotificationCenter.default.post(
            name: .ghosttyCloseSurface,
            object: GhosttyAppManager.shared,
            userInfo: [
                "surface": surface,
                "paneId": surfaceView.paneId,
                "tabId": surfaceView.tabId,
                "shouldConfirm": shouldConfirm,
            ]
        )
    }
}
