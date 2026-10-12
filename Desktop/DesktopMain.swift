import AppKit
import Carbon

@main
struct DesktopMain {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let target = Bundle.main.object(forInfoDictionaryKey: "SopranoLauncherTarget") as? String
        let command = arguments.first
        if target != nil || (command != nil && (!command!.hasPrefix("--") || command == "--help")) {
            NSApp.setActivationPolicy(.prohibited)
            Task {
                do {
                    if let target {
                        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else {
                            throw DesktopError.message("The target app is no longer installed")
                        }
                        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    } else if let command {
                        try await runCommand(command, arguments: Array(arguments.dropFirst()))
                    }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    exit(1)
                }
            }
            NSApp.run()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let delegate = DesktopAppDelegate(initialAction: arguments.contains("--overview") ? "overview" : nil)
        NSApp.delegate = delegate
        withExtendedLifetime(delegate) { NSApp.run() }
    }

    @MainActor
    private static func runCommand(_ command: String, arguments: [String]) async throws {
        switch command {
        case "render-assets":
            let directory = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Desktop.support.appendingPathComponent("assets")
            try AssetRenderer.renderAssets(at: directory)
            try Desktop.report(["assets": directory.path, "screens": NSScreen.screens.count])
        case "apply-theme":
            let failures = try SystemSetup.apply()
            try Desktop.report(["backup": SystemSetup.backupURL.path, "failures": failures])
            if !failures.isEmpty { exit(1) }
        case "restore-theme":
            let failures = try SystemSetup.restore()
            try Desktop.report(["restored": failures.isEmpty, "failures": failures])
            if !failures.isEmpty { exit(1) }
        case "overview", "dashboard", "permissions", "dismiss", "quit", "status":
            try send(command, arguments: arguments)
        case "snapshot":
            guard arguments.count == 2, ["overview", "dashboard", "desktop"].contains(arguments[0]), arguments[1].hasPrefix("/") else {
                throw DesktopError.message("Usage: SopranoDesktop snapshot overview|dashboard|desktop /absolute/output.png")
            }
            try send(command, arguments: arguments)
        case "bar":
            let metrics = SystemMetrics.read()
            let now = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            let tool = Desktop.support.appendingPathComponent("bin/sketchybar").path
            try Desktop.run(tool, ["--set", "clock", "label=\(now)", "--set", "battery", "label=power  \(metrics.battery)",
                "--set", "memory", "label=ram  \(metrics.memory)", "--set", "apps", "label=\(metrics.appCount) apps"])
        case "help", "--help":
            print("Soprano Desktop\n  overview | dashboard | permissions | dismiss | quit | status\n  snapshot overview|dashboard|desktop /absolute/output.png\n  render-assets [directory]\n  apply-theme | restore-theme\n\nGlobal shortcuts: Ctrl–Option–Space overview; Ctrl–Option–D dashboard.\n")
        default: throw DesktopError.message("Unknown desktop command: \(command). Use help.")
        }
    }

    @MainActor
    private static func send(_ action: String, arguments: [String]) throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Desktop.bundleID)
            .filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }).isEmpty else {
            throw DesktopError.message("Soprano Desktop is not running. Open /Applications/Soprano Desktop.app first.")
        }
        var info = ["action": action]
        if action == "snapshot" { info["surface"] = arguments[0]; info["path"] = arguments[1] }
        DistributedNotificationCenter.default().postNotificationName(Desktop.commandNotification, object: Desktop.bundleID,
            userInfo: info, deliverImmediately: true)
        print("Sent \(action) to Soprano Desktop")
    }
}

@MainActor
final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    private let catalog = WindowCatalog()
    private var overview: OverviewController!
    private var dashboard: DashboardController!
    private var statusItem: NSStatusItem?
    private var observer: NSObjectProtocol?
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var shortcutErrors: [String] = []
    private let initialAction: String?

    init(initialAction: String?) { self.initialAction = initialAction }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Desktop.bundleID)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy != .prohibited }) {
            NSApp.terminate(nil)
            return
        }
        overview = OverviewController(catalog: catalog)
        dashboard = DashboardController()
        overview.onPermissions = { [weak self] in self?.permissions() }
        dashboard.onPermissions = { [weak self] in self?.permissions() }
        dashboard.onOverview = { [weak self] in self?.overview.show(); self?.writeStatus() }
        dashboard.showOnDesktop()
        installMenu()
        installShortcuts()
        observer = DistributedNotificationCenter.default().addObserver(forName: Desktop.commandNotification,
            object: Desktop.bundleID, queue: .main) { [weak self] notification in
            let command = notification.userInfo as? [String: String] ?? [:]
            Task { @MainActor [weak self] in
                await self?.command(command)
            }
        }
        if initialAction == "overview" { overview.show() }
        writeStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        for key in hotKeys { UnregisterEventHotKey(key) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func installMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.attributedTitle = RetroText.display("MC", color: Desktop.theme.colors.accent, tracking: 0)
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            ("Window Overview  ⌃⌥Space", #selector(toggleOverview)),
            ("Dashboard  ⌃⌥D", #selector(toggleDashboard)),
            ("Permissions…", #selector(openPermissions)),
            ("Quit Soprano Desktop", #selector(quit))
        ]
        for (title, action) in entries {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
    }

    private func installShortcuts() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID(signature: 0, id: 0)
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            MainActor.assumeIsolated {
                let delegate = Unmanaged<DesktopAppDelegate>.fromOpaque(context).takeUnretainedValue()
                if id.id == 1 { delegate.toggleOverview() } else if id.id == 2 { delegate.toggleDashboard() }
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard result == noErr else { shortcutErrors.append("Hotkey handler: \(result)"); return }
        for (code, identifier) in [(UInt32(kVK_Space), UInt32(1)), (UInt32(kVK_ANSI_D), UInt32(2))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(controlKey | optionKey),
                EventHotKeyID(signature: 0x53504454, id: identifier), GetApplicationEventTarget(), 0, &reference)
            if result == noErr, let reference { hotKeys.append(reference) }
            else { shortcutErrors.append("Shortcut \(identifier): \(result)") }
        }
        if !shortcutErrors.isEmpty { NSLog("Soprano Desktop shortcuts: %@", shortcutErrors.joined(separator: "; ")) }
    }

    private func command(_ info: [String: String]) async {
        do {
            switch info["action"] {
            case "overview": overview.toggle()
            case "dashboard": dashboard.toggle()
            case "permissions": permissions()
            case "dismiss": overview.hide(); dashboard.lower()
            case "snapshot":
                guard let path = info["path"], path.hasPrefix("/") else { throw DesktopError.message("Snapshot output must be absolute") }
                let url = URL(fileURLWithPath: path)
                if info["surface"] == "desktop" { try await catalog.snapshotDesktop(to: url) }
                else if info["surface"] == "overview" { try overview.snapshot(to: url) }
                else { try dashboard.snapshot(to: url) }
            case "quit": NSApp.terminate(nil)
            case "status": break
            default: throw DesktopError.message("Unknown desktop notification command")
            }
            writeStatus()
        } catch { NSLog("Soprano Desktop: %@", error.localizedDescription) }
    }

    private func permissions() {
        catalog.requestPermissions()
        let alert = NSAlert()
        alert.messageText = "Finish Soprano Desktop setup"
        var links: [(String, String)] = []
        var steps: [String] = []
        if !catalog.screenPermission {
            links.append(("Screen Recording", "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
            steps.append("Screen & System Audio Recording → enable Soprano Desktop for real previews.")
        }
        if !catalog.accessibilityPermission {
            links.append(("Accessibility", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
            steps.append("Accessibility → enable Soprano Desktop to select the exact window.")
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            links.append(("Motion", "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Motion"))
            steps.append("Accessibility → Motion → turn Reduce Motion off to enable animations.")
        }
        alert.informativeText = steps.isEmpty ? "All required settings are enabled." : steps.joined(separator: "\n\n")
        for (title, _) in links { alert.addButton(withTitle: title) }
        alert.addButton(withTitle: steps.isEmpty ? "OK" : "Later")
        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if links.indices.contains(index) { NSWorkspace.shared.open(URL(string: links[index].1)!) }
        writeStatus()
    }

    private func writeStatus() {
        do {
            let status: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                "screenRecording": catalog.screenPermission, "accessibility": catalog.accessibilityPermission,
                "shortcutErrors": shortcutErrors, "overviewVisible": overview.isVisible,
                "windowIDs": overview.visibleWindowIDs, "dashboardVisible": dashboard.window.isVisible]
            let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Desktop.support.appendingPathComponent("runtime-status.json"), options: .atomic)
        } catch { NSLog("Soprano Desktop status: %@", error.localizedDescription) }
    }

    @objc private func toggleOverview() { overview.toggle(); writeStatus() }
    @objc private func toggleDashboard() { dashboard.toggle(); writeStatus() }
    @objc private func openPermissions() { permissions() }
    @objc private func quit() { NSApp.terminate(nil) }
}
