import AppKit

if let markdownCommandExitCode = MarkdownCommand.run() {
    exit(markdownCommandExitCode)
} else if let browserCommandExitCode = BrowserCommand.run() {
    exit(browserCommandExitCode)
} else if !AgentEventCommand.handle() && !PaneNavigationCommand.handle() {
    let environment = ProcessInfo.processInfo.environment
    switch LaunchDispatch.decide(
        arguments: CommandLine.arguments,
        environment: environment,
        runsOwningApp: LaunchDispatch.runsOwningApp(
            executablePath: Bundle.main.executableURL?.path, environment: environment
        )
    ) {
    case .help:
        FileHandle.standardOutput.write(Data((LaunchDispatch.usage + "\n").utf8))
        exit(0)
    case .usageError:
        FileHandle.standardError.write(Data((LaunchDispatch.usage + "\n").utf8))
        exit(2)
    case .startApp:
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // A local here, not a top-level global: keep the weakly held delegate alive.
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
