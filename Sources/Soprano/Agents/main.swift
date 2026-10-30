import AppKit

// Sub-commands run before the normal app launch and never return.
let launchArguments = CommandLine.arguments
if launchArguments.count > 1, launchArguments[1] == "snapshot" {
    SnapshotCommand.run(arguments: Array(launchArguments.dropFirst(2)))
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
