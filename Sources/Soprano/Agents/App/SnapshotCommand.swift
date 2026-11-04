import AppKit
import SopranoAgentsCore

/// `SopranoAgents snapshot --out <png> [--fixture demo] [--size 1440x900] [--appearance light|dark]
/// [--theme <id>] [--hide-sidebar] [--details] [--terminal] [--right-panel]
/// [--diff thread|turn:<n>|uncommitted] [--perform <command id>]… [--type "<text>"] [--keys "<chord> …"]
/// [--hover <accessibility label>] [--click <accessibility label>]… [--settings <page>] [--dialog confirm|choose|prompt|alert]
/// [--accounts none|demo|empty|pending] [--work-log detailed|minimal] [--wait <seconds>]`
///
/// Builds the real main window offscreen (no Dock icon, never shown, no persisted state) on a
/// `DemoFixtures` scenario, applies the panel flags, runs commands by id (`--perform palette.open`),
/// opens the settings screen on a page, presents a sample dialog, types text into the first
/// responder (of the topmost overlay or key-taking child window when one shows), replays keys through the keyboard router,
/// clicks controls (`--click`, in order, after the keys), sets a hover state, waits for async
/// work, and writes a PNG of the window plus its child windows (palette, popovers, dialogs) rendered
/// through Core Animation. Agents verify UI with it and read the PNG; they never launch the GUI.
@MainActor
enum SnapshotCommand {
    struct Options: Equatable {
        var output: URL?
        var fixture = "demo"
        var size = NSSize(width: 1440, height: 900)
        var dark = false
        var theme: String?
        var hideSidebar = false
        var details = false
        var terminal = false
        var rightPanel = false
        var diff: String?
        var openFiles: [String] = []
        var perform: [String] = []
        var type: String?
        var keys: [String] = []
        var hover: String?
        var clicks: [String] = []
        var settings: SettingsPage?
        var dialog: String?
        /// The `AccountFixtures` snapshot the account button, usage card and Settings → Accounts show.
        var accounts = "none"
        /// Overrides `chat.workLog` in memory (settings.json stays untouched).
        var workLog: AppSettings.WorkLog?
        var wait: Double = 0.4
    }

    static let usage = """
    usage: SopranoAgents snapshot --out <png> [--fixture \(DemoFixtures.scenarios.joined(separator: "|"))]
                                  [--size WxH] [--appearance light|dark] [--theme <id>]
                                  [--hide-sidebar] [--details] [--terminal] [--right-panel]
                                  [--diff thread|turn:<n>|uncommitted] [--open-file <path>]… [--perform <command id>]…
                                  [--type "<text>"] [--keys "<chord> …"] [--hover <label>] [--click <label>]…
                                  [--settings \(SettingsPage.allCases.map(\.rawValue).joined(separator: "|"))]
                                  [--dialog \(dialogs.joined(separator: "|"))] [--accounts \(AccountFixtures.scenarios.joined(separator: "|"))]
                                  [--work-log detailed|minimal] [--wait <seconds>]
    """

    nonisolated static let dialogs = ["confirm", "choose", "prompt", "alert"]

    struct CaptureError: Error, CustomStringConvertible {
        var description: String
    }

    nonisolated static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(_ option: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CaptureError(description: "\(option) needs a value") }
            return arguments[index]
        }
        while index < arguments.count {
            let option = arguments[index]
            switch option {
            case "--out": options.output = URL(fileURLWithPath: try value(option))
            case "--fixture": options.fixture = try value(option)
            case "--size":
                let parts = try value(option).split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2 else { throw CaptureError(description: "--size must be WxH") }
                options.size = NSSize(width: parts[0], height: parts[1])
            case "--appearance":
                let raw = try value(option)
                guard raw == "light" || raw == "dark" else { throw CaptureError(description: "--appearance must be light or dark") }
                options.dark = raw == "dark"
            case "--theme": options.theme = try value(option)
            case "--hide-sidebar": options.hideSidebar = true
            case "--details": options.details = true
            case "--terminal": options.terminal = true
            case "--right-panel": options.rightPanel = true
            case "--diff": options.diff = try value(option)
            case "--open-file": options.openFiles.append(try value(option))
            case "--perform": options.perform.append(try value(option))
            case "--type": options.type = try value(option)
            case "--keys": options.keys = try value(option).split(separator: " ").map(String.init)
            case "--hover": options.hover = try value(option)
            case "--click": options.clicks.append(try value(option))
            case "--settings":
                let raw = try value(option)
                guard let page = SettingsPage(rawValue: raw) else {
                    throw CaptureError(description: "--settings must be one of \(SettingsPage.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                options.settings = page
            case "--dialog":
                let raw = try value(option)
                guard dialogs.contains(raw) else { throw CaptureError(description: "--dialog must be one of \(dialogs.joined(separator: ", "))") }
                options.dialog = raw
            case "--accounts":
                let raw = try value(option)
                guard AccountFixtures.scenarios.contains(raw) else {
                    throw CaptureError(description: "--accounts must be one of \(AccountFixtures.scenarios.joined(separator: ", "))")
                }
                options.accounts = raw
            case "--work-log":
                let raw = try value(option)
                guard let workLog = AppSettings.WorkLog(rawValue: raw) else { throw CaptureError(description: "--work-log must be detailed or minimal") }
                options.workLog = workLog
            case "--wait": options.wait = Double(try value(option)) ?? options.wait
            default: throw CaptureError(description: "unknown option \(option)")
            }
            index += 1
        }
        guard options.output != nil else { throw CaptureError(description: "--out is required") }
        return options
    }

    static func run(arguments: [String]) -> Never {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n\(usage)\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        // No Dock icon and never activated: nothing appears on the user's screen.
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await capture(options)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
        exit(1)
    }

    static func capture(_ options: Options) async throws {
        let settings = SettingsCenter.shared
        settings.start(createIfMissing: false, watching: false)
        if let workLog = options.workLog {
            let text = (try? SettingsFile.read(at: settings.fileURL)) ?? nil
            settings.apply(text: try JSONCText.setting(workLog.rawValue, at: ["chat", "workLog"], in: text ?? "{}"), notify: false)
        }
        ThemeCenter.shared.forcedAppearance = options.dark ? .dark : .light
        PaletteCenter.shared.apply(setting: options.theme ?? AppTheme.folioId)
        NSApp.appearance = PaletteCenter.shared.palette.appearance
        if CommandRegistry.shared.commands.isEmpty {
            AllCommands.registerAll()
        }
        settings.reloadKeymap()
        // Before the window is built: its views read the accounts source when they load.
        AccountsCenter.source = FixtureAccountsSource(snapshot: try AccountFixtures.snapshot(options.accounts))

        let built = try DemoFixtures.build(options.fixture)
        let state = WorkspaceState()
        state.select(built.selection)
        state.setSidebarVisible(!options.hideSidebar)
        state.setThreadDetailsVisible(options.details)
        state.setTerminalVisible(options.terminal)
        if options.rightPanel { state.setRightPanelVisible(true) }
        if let diff = options.diff {
            state.showDiff(try diffScope(diff))
        }
        for path in options.openFiles {
            state.showRightPanel(.file(path))
        }

        // Far outside every display: real window-server backing, never seen.
        let frame = NSRect(x: -30000, y: -30000, width: options.size.width, height: options.size.height)
        let defaults = UserDefaults(suiteName: "SopranoAgentsSnapshot-\(UUID().uuidString)") ?? .standard
        let controller = MainWindowController(engine: built.engine, state: state, defaults: defaults, persistsFrame: false, frame: frame)
        guard let window = controller.mainWindow else { throw CaptureError(description: "no window") }
        window.allowsOffscreenFrame = true
        window.rendersAsKey = true
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        await settle(0.3)

        for id in options.perform {
            guard CommandRegistry.shared.command(id) != nil else {
                throw CaptureError(description: "--perform: no command \"\(id)\"")
            }
            controller.perform(id)
            await settle(0.2)
        }
        if let page = options.settings {
            SettingsController.present(page: page, engine: built.engine, over: window)
            await settle(0.25)
        }
        if let dialog = options.dialog {
            presentSampleDialog(dialog, in: window)
            await settle(0.25)
        }
        if let text = options.type {
            // The palette or a key-taking composer popover (the side-question panel).
            let child = window.childWindows?.last { $0.isVisible && $0.canBecomeKey }
            let target = OverlayWindow.topmost(over: window) ?? child ?? window
            guard let responder = target.firstResponder as? NSTextView else {
                throw CaptureError(description: "--type: the first responder is not a text view")
            }
            responder.insertText(text, replacementRange: responder.selectedRange())
            await settle(0.15)
        }
        for token in options.keys {
            for event in try events(for: token, in: window) {
                deliver(event, controller: controller, window: window)
                await settle(0.12)
            }
        }
        for label in options.clicks {
            guard let view = findInteractive(labeled: label, in: window.contentView) else {
                throw CaptureError(description: "--click: no control labeled \"\(label)\"")
            }
            click(view, in: window)
            await settle(0.25)
        }
        if let label = options.hover {
            guard let view = findInteractive(labeled: label, in: window.contentView) else {
                throw CaptureError(description: "--hover: no control labeled \"\(label)\"")
            }
            view.setHoveredForTesting(true)
        }
        await settle(options.wait)

        let image = try render(window: window)
        try writePNG(image, to: options.output!)
    }

    /// Presents one of the harness's sample dialogs without waiting for an answer.
    static func presentSampleDialog(_ kind: String, in window: NSWindow) {
        Task { @MainActor in
            switch kind {
            case "choose":
                _ = await Dialogs.choose(
                    title: "Uncommitted changes",
                    message: "The worktree has changes that are not committed yet. Commit them before pushing, or push only what is committed.",
                    buttons: [DialogButton("Cancel"), DialogButton("Push committed only"), DialogButton("Commit & push", style: .primary)],
                    in: window
                )
            case "prompt":
                _ = await Dialogs.prompt(
                    title: "Rename thread",
                    message: "Give the thread a short, descriptive title.",
                    placeholder: "Thread title",
                    initialValue: "Fix SSO login redirect loop",
                    confirmTitle: "Rename",
                    in: window
                )
            case "alert":
                await Dialogs.alert(title: "Couldn’t start a new thread", message: "omp is unavailable: `omp` was not found on PATH.", in: window)
            default:
                _ = await Dialogs.confirm(
                    title: "Delete thread \"Fix SSO login redirect loop\"?",
                    message: "This permanently clears conversation history for this thread.",
                    confirmTitle: "Delete",
                    isDestructive: true,
                    in: window
                )
            }
        }
    }

    static func diffScope(_ raw: String) throws -> WorkspaceState.DiffScope {
        if raw == "thread" { return .thread }
        if raw == "uncommitted" { return .uncommitted }
        if raw.hasPrefix("turn:"), let ordinal = Int(raw.dropFirst(5)) { return .turn(ordinal) }
        throw CaptureError(description: "--diff must be thread, uncommitted or turn:<n>")
    }

    /// A left click at the view's center, sent through `NSApp` like a real one: local event
    /// monitors (open popovers closing on outside clicks) see it first, then the window
    /// hit-tests the point, so a view covering the control swallows the click as it would live.
    private static func click(_ view: NSView, in window: NSWindow) {
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// The first visible `InteractiveView` with that accessibility label or tooltip.
    private static func findInteractive(labeled label: String, in view: NSView?) -> InteractiveView? {
        guard let view, !view.isHidden else { return nil }
        if let interactive = view as? InteractiveView,
           interactive.accessibilityLabel() == label || interactive.toolTip == label {
            return interactive
        }
        for subview in view.subviews {
            if let match = findInteractive(labeled: label, in: subview) { return match }
        }
        return nil
    }

    // MARK: - Keys

    /// Events for one `--keys` token ("cmd+k", "shift+tab", "enter", "j").
    static func events(for token: String, in window: NSWindow) throws -> [NSEvent] {
        guard let chord = KeyChord.parse(token) else {
            throw CaptureError(description: "--keys: \"\(token)\" is not a chord")
        }
        var events: [NSEvent] = []
        if chord.mode == .prefix {
            let prefixKey = SettingsCenter.shared.keymap.prefixKey
            events.append(makeEvent(key: prefixKey, ctrl: true, meta: false, shift: false, window: window))
        }
        events.append(makeEvent(key: chord.key, ctrl: chord.ctrl, meta: chord.meta, shift: chord.shift, window: window))
        return events
    }

    static func makeEvent(key: String, ctrl: Bool, meta: Bool, shift: Bool, window: NSWindow) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if ctrl { flags.insert(.control) }
        if meta { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        let characters = shift && key.count == 1 && key.first?.isLetter == true ? key.uppercased() : key
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: ctrl && key.count == 1 && key.first?.isLetter == true
                ? String(UnicodeScalar(UInt8(key.unicodeScalars.first!.value & 0x1F)))
                : characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode(for: key)
        ) ?? NSEvent()
    }

    static func keyCode(for key: String) -> UInt16 {
        let named: [String: UInt16] = [
            "\r": 36, "\t": 48, " ": 49, "\u{7F}": 51, "\u{1B}": 53,
            "\u{F702}": 123, "\u{F703}": 124, "\u{F701}": 125, "\u{F700}": 126,
        ]
        if let code = named[key] { return code }
        let letters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
            "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32,
            "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "]": 30, "?": 44,
        ]
        return key.first.flatMap { letters[$0] } ?? 0
    }

    /// The key child window (palette, popover) takes keys while shown; else the router, then the window.
    static func deliver(_ event: NSEvent, controller: MainWindowController, window: NSWindow) {
        if let child = window.childWindows?.last(where: { $0.isVisible && $0.canBecomeKey }) {
            child.sendEvent(event)
            return
        }
        guard let passed = controller.router.dispatch(event) else { return }
        window.sendEvent(passed)
    }

    // MARK: - Waiting

    static func settle(_ seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    // MARK: - Rendering

    /// Renders the window and its visible child windows through Core Animation, so layer-backed
    /// content (fills, borders, shadows) appears exactly as on screen.
    static func render(window: NSWindow) throws -> CGImage {
        let scale = max(1, window.backingScaleFactor)
        let size = window.frame.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CaptureError(description: "no bitmap context") }
        context.scaleBy(x: scale, y: scale)

        var layers: [NSWindow] = [window]
        if let sheet = window.attachedSheet { layers.append(sheet) }
        for child in window.childWindows ?? [] where child.isVisible && !layers.contains(child) {
            layers.append(child)
        }
        for (index, layerWindow) in layers.enumerated() {
            let origin = NSPoint(x: layerWindow.frame.minX - window.frame.minX, y: layerWindow.frame.minY - window.frame.minY)
            if index > 0, layerWindow.hasShadow, layerWindow.isOpaque {
                drawShadow(for: NSRect(origin: origin, size: layerWindow.frame.size), in: context)
            }
            try draw(layerWindow, at: origin, in: context)
        }
        guard let image = context.makeImage() else { throw CaptureError(description: "no image") }
        return image
    }

    private static func draw(_ window: NSWindow, at origin: NSPoint, in context: CGContext) throws {
        guard let view = window.contentView else { return }
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.display()
        CATransaction.flush()
        guard let layer = view.layer else { throw CaptureError(description: "content view has no layer") }
        context.saveGState()
        if window.isOpaque, window.backgroundColor.alphaComponent > 0 {
            context.setFillColor(window.backgroundColor.cgColor)
            context.fill(CGRect(origin: origin, size: window.frame.size))
        }
        context.translateBy(x: origin.x, y: origin.y)
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        context.restoreGState()
    }

    private static func drawShadow(for rect: NSRect, in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CaptureError(description: "PNG encoding failed")
        }
        try data.write(to: url)
    }
}
