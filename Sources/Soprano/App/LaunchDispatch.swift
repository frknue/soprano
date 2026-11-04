import Foundation

/// What `main.swift` does with an invocation no subcommand claimed. The app
/// binary doubles as `$SOPRANO_BIN`, so a bare `soprano`, a typo, or a
/// non-Markdown path typed in a pane must never start a second full app that
/// restores the same session and writes the same stores.
enum LaunchDispatch: Equatable {
    case startApp
    case help
    case usageError

    static let usage = """
    Usage:
      soprano <file.md> [--new]            open a Markdown reader in this pane
      soprano markdown|md [--new] <file>
      soprano browser [--pane pane-id] <command> ...   (soprano browser --help)
      soprano navigate-pane left|right|up|down
      soprano navigation-passthrough enable|disable <source>
      soprano agent-event <state> [options]

    Subcommands drive the Soprano instance that owns the calling terminal.
    Start the app itself from Finder, Spotlight, or `open -a Soprano`.
    """

    /// Decides for an invocation that no subcommand handled. `runsOwningApp`: this binary is the
    /// one of the app that owns the calling terminal (see `runsOwningApp(executablePath:environment:)`).
    static func decide(
        arguments: [String],
        environment: [String: String],
        runsOwningApp: Bool = true
    ) -> LaunchDispatch {
        let firstArgument = arguments.dropFirst().first
        if let firstArgument, ["--help", "-h", "help"].contains(firstArgument) {
            return .help
        }
        // Inside a Soprano terminal a call of that app's own binary is a CLI call: the app is
        // already running. Another build (`.build/debug/Soprano`) starts as it would outside.
        if runsOwningApp, let appProcessId = environment["SOPRANO_APP_PID"], !appProcessId.isEmpty {
            return .usageError
        }
        guard let firstArgument else { return .startApp }
        // AppKit, LaunchServices and Xcode pass single-dash arguments
        // (`-NSDocumentRevisionsDebugMode YES`, `-psn_0_12345`).
        if firstArgument.hasPrefix("-"), !firstArgument.hasPrefix("--") {
            return .startApp
        }
        return .usageError
    }

    /// Whether `executablePath` is the binary of the app owning the calling terminal, which
    /// exports it as `SOPRANO_BIN` (panes call it through the `soprano` symlink). Without a
    /// recorded binary a call from a pane counts as the owning app's.
    static func runsOwningApp(executablePath: String?, environment: [String: String]) -> Bool {
        guard let owner = environment["SOPRANO_BIN"], !owner.isEmpty, let executablePath else { return true }
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return resolved(executablePath) == resolved(owner)
    }
}
