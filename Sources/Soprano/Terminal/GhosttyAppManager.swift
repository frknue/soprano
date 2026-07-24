import AppKit
import GhosttyKit

extension Notification.Name {
    static let ghosttyCloseSurface = Notification.Name("GhosttyCloseSurface")
    static let ghosttyDesktopNotification = Notification.Name("GhosttyDesktopNotification")
    static let ghosttyDidFocusSurface = Notification.Name("GhosttyDidFocusSurface")
}

@MainActor
final class GhosttyAppManager: @unchecked Sendable {
    static let shared = GhosttyAppManager()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    let clipboardConfirmationCoordinator = ClipboardConfirmationCoordinator(
        presenter: AppKitClipboardConfirmationPresenter()
    )
    private var isInitialized = false
    private var didBecomeObserver: NSObjectProtocol?
    private var didResignObserver: NSObjectProtocol?

    private init() {}

    func initialize() {
        guard !isInitialized else { return }

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            print("[Soprano] ghostty_init failed with code \(initResult)")
            return
        }

        guard let primaryConfig = createPrimaryConfig() else {
            print("[Soprano] Failed to create ghostty config")
            return
        }

        config = primaryConfig
        var runtimeConfig = makeRuntimeConfig()

        if let primaryApp = ghostty_app_new(&runtimeConfig, primaryConfig) {
            app = primaryApp
        } else {
            let fallbackConfig = ghostty_config_new()
            guard fallbackConfig != nil else {
                print("[Soprano] Failed to allocate fallback ghostty config")
                return
            }
            ghostty_config_finalize(fallbackConfig)

            if let fallbackApp = ghostty_app_new(&runtimeConfig, fallbackConfig) {
                config = fallbackConfig
                app = fallbackApp
            } else {
                print("[Soprano] Failed to create ghostty app")
                return
            }
        }

        guard let app else { return }

        ghostty_app_set_focus(app, NSApp.isActive)
        observeApplicationFocusChanges()
        isInitialized = true
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func createPrimaryConfig() -> ghostty_config_t? {
        let cfg = ghostty_config_new()
        guard cfg != nil else { return nil }
        ghostty_config_load_default_files(cfg)
        ghostty_config_finalize(cfg)
        return cfg
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
            surfaceView.terminalCommandDidFinish(exitCode: exitCode)
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
