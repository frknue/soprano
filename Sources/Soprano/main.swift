import AppKit

if !AgentEventCommand.handle() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
