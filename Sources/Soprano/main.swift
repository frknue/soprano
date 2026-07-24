import AppKit

if let browserCommandExitCode = BrowserCommand.run() {
    exit(browserCommandExitCode)
} else if !AgentEventCommand.handle() && !PaneNavigationCommand.handle() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
