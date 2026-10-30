import AppKit

/// Routes key presses in a main window to registered commands (ARCHITECTURE.md
/// "Keyboard model"): an `NSEvent` local keyDown monitor like Soprano's
/// `KeybindingManager`, with a ⌃A prefix mode, focus-region scopes, the
/// text-input rule, ⌥ passthrough, symbol keys matching ignoring Shift, and
/// disabled commands letting the event pass.
@MainActor
final class KeyboardRouter {
    enum State: Equatable {
        case normal
        case prefix
    }

    enum Disposition: Equatable {
        /// A command ran or the prefix consumed the key; swallow the event.
        case handled
        /// Deliver the event unchanged (no binding, disabled, text input, ⌥, literal ⌃A).
        case passThrough
    }

    let registry: CommandRegistry
    /// The live keymap (settings overrides applied).
    var keymap: () -> Keymap
    /// Where a command would run; nil keeps the router out (no main window).
    var context: () -> CommandContext?

    private(set) var state: State = .normal {
        didSet {
            if state != oldValue { onStateChange?(state) }
        }
    }
    var onStateChange: ((State) -> Void)?
    /// Called after a command ran through the router (toolbar/menu refresh hooks).
    var onCommandPerformed: ((String) -> Void)?
    /// While set, every key press goes here instead of to commands, menus or
    /// the focused view (the settings screen's shortcut recorder).
    var capture: ((KeyStroke) -> Void)? {
        didSet { clearPrefix() }
    }

    private weak var window: NSWindow?
    private var monitor: Any?
    private var prefixTask: Task<Void, Never>?

    init(
        registry: CommandRegistry = .shared,
        keymap: @escaping () -> Keymap,
        context: @escaping () -> CommandContext?
    ) {
        self.registry = registry
        self.keymap = keymap
        self.context = context
    }

    // MARK: - Monitoring

    /// Starts routing keyDowns aimed at `window` while it is key and no sheet
    /// or panel (dialog, palette, shortcut sheet) has the keyboard.
    func startMonitoring(window: NSWindow) {
        self.window = window
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // The monitor runs on the main thread; NSEvent is not Sendable, so
            // hand the result out of the isolated block through a local.
            nonisolated(unsafe) let incoming = event
            nonisolated(unsafe) var outgoing: NSEvent? = event
            MainActor.assumeIsolated {
                guard let self else { return }
                outgoing = self.route(incoming)
            }
            return outgoing
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        clearPrefix()
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, NSApp.keyWindow === window, window.attachedSheet == nil else {
            return event
        }
        return dispatch(event)
    }

    /// Routes one event without the key-window check (the snapshot harness
    /// replays keys into an offscreen window that is never key).
    func dispatch(_ event: NSEvent) -> NSEvent? {
        guard let stroke = KeyStroke(event: event) else { return event }
        if let capture {
            capture(stroke)
            return nil
        }
        guard let context = context() else { return event }
        return handle(stroke, in: context) == .handled ? nil : event
    }

    // MARK: - Resolution

    func handle(_ stroke: KeyStroke, in context: CommandContext) -> Disposition {
        let keymap = keymap()

        // ⌥ chords are text on many layouts (German @ [ ] { } | ~).
        if stroke.option {
            clearPrefix()
            return .passThrough
        }

        let isPrefixChord = stroke.ctrl && !stroke.meta && !stroke.shift && stroke.key == keymap.prefixKey
        if isPrefixChord {
            if state == .prefix {
                // ⌃A ⌃A: the second one reaches the first responder literally.
                clearPrefix()
                return .passThrough
            }
            startPrefix(timeoutMs: keymap.prefixTimeoutMs)
            return .handled
        }

        if state == .prefix {
            clearPrefix()
            // Any key ends prefix mode; it never leaks into the focused view.
            if let command = candidates(for: stroke, mode: .prefix, focus: context.focus, keymap: keymap)
                .first(where: { $0.isEnabled(context) }) {
                perform(command, in: context)
            }
            return .handled
        }

        if context.isTextInput, !stroke.ctrl, !stroke.meta {
            return .passThrough
        }

        guard let command = candidates(for: stroke, mode: .direct, focus: context.focus, keymap: keymap)
            .first(where: { $0.isEnabled(context) })
        else {
            return .passThrough
        }
        perform(command, in: context)
        return .handled
    }

    /// Commands bound to the stroke that may fire in `focus`: region-scoped
    /// ones first (region beats global), then global ones, registry order within.
    func candidates(for stroke: KeyStroke, mode: KeyBindingMode, focus: FocusRegion?, keymap: Keymap) -> [AppCommand] {
        var scoped: [AppCommand] = []
        var global: [AppCommand] = []
        for command in registry.commands {
            guard keymap.chords(for: command.id).contains(where: { stroke.matches($0, mode: mode) }) else { continue }
            if command.scopes.isEmpty {
                global.append(command)
            } else if let focus, command.scopes.contains(focus) {
                scoped.append(command)
            }
        }
        return scoped + global
    }

    private func perform(_ command: AppCommand, in context: CommandContext) {
        command.perform(context)
        onCommandPerformed?(command.id)
    }

    // MARK: - Prefix

    private func startPrefix(timeoutMs: Int) {
        prefixTask?.cancel()
        state = .prefix
        prefixTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(timeoutMs))
            guard !Task.isCancelled else { return }
            self?.clearPrefix()
        }
    }

    func clearPrefix() {
        prefixTask?.cancel()
        prefixTask = nil
        state = .normal
    }
}
