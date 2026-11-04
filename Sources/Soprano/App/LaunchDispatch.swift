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
      soprano agents-snapshot --out <png> ...

    Subcommands drive the Soprano instance that owns the calling terminal.
    Start the app itself from Finder, Spotlight, or `open -a Soprano`.
    """

    /// Decides for an invocation that no subcommand handled.
    static func decide(arguments: [String], environment: [String: String]) -> LaunchDispatch {
        let firstArgument = arguments.dropFirst().first
        if let firstArgument, ["--help", "-h", "help"].contains(firstArgument) {
            return .help
        }
        // Inside a Soprano terminal every invocation is a CLI call; the owning
        // app is already running.
        if let appProcessId = environment["SOPRANO_APP_PID"], !appProcessId.isEmpty {
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
}
