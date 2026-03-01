import AppKit
import GhosttyKit

extension Notification.Name {
    static let ghosttyCloseSurface = Notification.Name("GhosttyCloseSurface")
}

@MainActor
final class GhosttyAppManager: @unchecked Sendable {
    static let shared = GhosttyAppManager()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
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
            wakeup_cb: { _ in
                Task { @MainActor in
                    GhosttyAppManager.shared.tick()
                }
            },
            action_cb: { _, _, _ in
                false
            },
            read_clipboard_cb: { userdata, location, state in
                guard let userdata else { return }
                let surfaceView = Unmanaged<TerminalSurfaceView>
                    .fromOpaque(userdata)
                    .takeUnretainedValue()
                guard let surface = surfaceView.surface else { return }

                let pasteboard: NSPasteboard = switch location {
                case GHOSTTY_CLIPBOARD_SELECTION:
                    NSPasteboard(name: .find)
                default:
                    .general
                }

                let content = pasteboard.string(forType: .string) ?? ""
                content.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
            },
            confirm_read_clipboard_cb: { userdata, content, state, _ in
                guard let userdata else { return }
                let surfaceView = Unmanaged<TerminalSurfaceView>
                    .fromOpaque(userdata)
                    .takeUnretainedValue()
                guard let surface = surfaceView.surface else { return }
                ghostty_surface_complete_clipboard_request(surface, content, state, true)
            },
            write_clipboard_cb: { _, location, content, len, _ in
                let pasteboard: NSPasteboard = switch location {
                case GHOSTTY_CLIPBOARD_SELECTION:
                    NSPasteboard(name: .find)
                default:
                    .general
                }

                pasteboard.clearContents()

                guard let content else { return }
                let count = Int(len)
                guard count > 0 else { return }

                let buffer = UnsafeBufferPointer(start: content, count: count)
                for item in buffer {
                    guard let mime = item.mime else { continue }
                    let mimeType = String(cString: mime)
                    guard mimeType == "text/plain", let data = item.data else { continue }
                    let text = String(cString: data)
                    pasteboard.setString(text, forType: .string)
                    break
                }
            },
            close_surface_cb: { userdata, shouldConfirm in
                guard let userdata else { return }
                let surfaceView = Unmanaged<TerminalSurfaceView>
                    .fromOpaque(userdata)
                    .takeUnretainedValue()
                guard let surface = surfaceView.surface else { return }
                NotificationCenter.default.post(
                    name: .ghosttyCloseSurface,
                    object: GhosttyAppManager.shared,
                    userInfo: [
                        "surface": surface,
                        "paneId": surfaceView.paneId,
                        "shouldConfirm": shouldConfirm,
                    ]
                )
            }
        )
    }
}
