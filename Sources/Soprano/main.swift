import AppKit

let launchArguments = CommandLine.arguments
if launchArguments.count > 1, launchArguments[1] == "agents-snapshot" {
    // Offscreen render of the Soprano Agents window on a demo fixture; never returns.
    SnapshotCommand.run(arguments: Array(launchArguments.dropFirst(2)))
}

if let markdownCommandExitCode = MarkdownCommand.run() {
    exit(markdownCommandExitCode)
} else if let browserCommandExitCode = BrowserCommand.run() {
    exit(browserCommandExitCode)
} else if !AgentEventCommand.handle() && !PaneNavigationCommand.handle() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
