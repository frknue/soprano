import Foundation

/// Command-line bridge used by nested terminal multiplexers and editors to
/// bubble pane navigation out to the Soprano instance that owns the terminal.
enum PaneNavigationCommand {
    private static let navigateCommand = "navigate-pane"
    private static let passthroughCommand = "navigation-passthrough"
    private static let notificationPrefix = "com.soprano.navigate-pane"

    static func handle(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        handle(
            arguments: arguments,
            environment: environment,
            tmuxNavigator: PaneNavigationCommand.navigateWithinTmux
        )
    }

    static func handle(
        arguments: [String],
        environment: [String: String],
        tmuxNavigator: (NavigationDirection, [String: String]) -> Bool
    ) -> Bool {
        guard arguments.count >= 2 else { return false }

        switch arguments[1] {
        case navigateCommand:
            return handleNavigation(
                arguments: arguments,
                environment: environment,
                tmuxNavigator: tmuxNavigator
            )
        case passthroughCommand:
            return handlePassthrough(arguments: arguments, environment: environment)
        default:
            return false
        }
    }

    static func notificationName(appProcessId: String) -> Notification.Name {
        Notification.Name("\(notificationPrefix).\(appProcessId)")
    }

    static func notificationEnvelope(
        arguments: [String],
        environment: [String: String]
    ) -> DistributedNotificationEnvelope? {
        guard arguments.count >= 2,
              let appProcessId = environment["SOPRANO_APP_PID"], !appProcessId.isEmpty,
              let paneId = environment["SOPRANO_PANE_ID"], !paneId.isEmpty,
              let tabId = environment["SOPRANO_TAB_ID"], !tabId.isEmpty
        else { return nil }

        let name = notificationName(appProcessId: appProcessId)
        switch arguments[1] {
        case navigateCommand:
            guard arguments.count >= 3,
                  let direction = NavigationDirection(rawValue: arguments[2])
            else { return nil }
            return DistributedNotificationEnvelope(
                name: name,
                userInfo: [
                    "paneId": paneId,
                    "tabId": tabId,
                    "direction": direction.rawValue,
                ]
            )
        case passthroughCommand:
            guard arguments.count >= 4,
                  arguments[2] == "enable" || arguments[2] == "disable",
                  !arguments[3].isEmpty
            else { return nil }
            return DistributedNotificationEnvelope(
                name: name,
                userInfo: [
                    "paneId": paneId,
                    "tabId": tabId,
                    "passthrough": arguments[2],
                    "source": arguments[3],
                ]
            )
        default:
            return nil
        }
    }

    private static func handleNavigation(
        arguments: [String],
        environment: [String: String],
        tmuxNavigator: (NavigationDirection, [String: String]) -> Bool
    ) -> Bool {
        guard arguments.count >= 3,
              let direction = NavigationDirection(rawValue: arguments[2])
        else { return true }

        guard let envelope = notificationEnvelope(arguments: arguments, environment: environment)
        else { return true }

        if tmuxNavigator(direction, environment) {
            return true
        }

        DistributedNotificationCenter.default().postNotificationName(
            envelope.name,
            object: nil,
            userInfo: envelope.userInfo,
            deliverImmediately: true
        )
        return true
    }

    private static func handlePassthrough(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        guard let envelope = notificationEnvelope(arguments: arguments, environment: environment)
        else { return true }

        DistributedNotificationCenter.default().postNotificationName(
            envelope.name,
            object: nil,
            userInfo: envelope.userInfo,
            deliverImmediately: true
        )
        return true
    }

    /// If the command originated inside tmux, navigate an adjacent tmux pane
    /// first. Returning false at a tmux boundary lets the request continue to
    /// the outer Soprano layout.
    private static func navigateWithinTmux(
        direction: NavigationDirection,
        environment: [String: String]
    ) -> Bool {
        guard environment["TMUX"]?.isEmpty == false else { return false }

        let paneId = environment["TMUX_PANE"] ?? runTmux(
            ["display-message", "-p", "#{pane_id}"],
            environment: environment
        ).output
        guard !paneId.isEmpty else { return false }

        let boundary = runTmux(
            [
                "display-message",
                "-p",
                "-t",
                paneId,
                "#{pane_at_\(direction.tmuxBoundaryName)}",
            ],
            environment: environment
        )
        guard boundary.succeeded, boundary.output == "0" else { return false }

        return runTmux(
            ["select-pane", "-t", paneId, direction.tmuxSelectFlag],
            environment: environment
        ).succeeded
    }

    private static func runTmux(
        _ arguments: [String],
        environment: [String: String]
    ) -> (succeeded: Bool, output: String) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + arguments
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, "")
        }
    }
}

private extension NavigationDirection {
    var tmuxBoundaryName: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .up: return "top"
        case .down: return "bottom"
        }
    }

    var tmuxSelectFlag: String {
        switch self {
        case .left: return "-L"
        case .right: return "-R"
        case .up: return "-U"
        case .down: return "-D"
        }
    }
}
