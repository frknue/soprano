import Foundation

struct BrowserCommandRequest: Equatable {
    let command: String
    let arguments: [String]
    let targetPaneId: String?

    static func parse(
        _ commandLine: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> BrowserCommandRequest? {
        guard commandLine.count >= 2, commandLine[1] == "browser" else { return nil }

        var tokens = Array(commandLine.dropFirst(2))
        if tokens.isEmpty || tokens == ["--help"] || tokens == ["help"] {
            return BrowserCommandRequest(command: "help", arguments: [], targetPaneId: nil)
        }

        var targetPaneId: String?
        var index = 0
        while index < tokens.count {
            if tokens[index] == "--pane" {
                guard index + 1 < tokens.count else {
                    throw BrowserAutomationError.invalidArguments("--pane requires a pane ID")
                }
                targetPaneId = tokens[index + 1]
                tokens.removeSubrange(index...(index + 1))
                continue
            }
            index += 1
        }

        guard let command = tokens.first else {
            return BrowserCommandRequest(command: "help", arguments: [], targetPaneId: targetPaneId)
        }
        var arguments = Array(tokens.dropFirst())

        if command == "screenshot", let path = arguments.first, !path.hasPrefix("/") {
            let workingDirectory = environment["PWD"] ?? FileManager.default.currentDirectoryPath
            arguments[0] = URL(
                fileURLWithPath: workingDirectory,
                isDirectory: true
            ).appendingPathComponent(path).standardizedFileURL.path
        }

        return BrowserCommandRequest(
            command: command,
            arguments: arguments,
            targetPaneId: targetPaneId
        )
    }
}

/// CLI entry point exposed inside every Soprano terminal through `$SOPRANO_BIN`.
/// Requests are routed only to the owning app process, then answered through a
/// request-scoped distributed notification.
enum BrowserCommand {
    private static let requestPrefix = "com.soprano.browser-request"
    private static let responsePrefix = "com.soprano.browser-response"
    private static let timeout: TimeInterval = 15

    static let help = """
    Usage:
      soprano browser open [url]
      soprano browser [--pane pane-id] goto <url>
      soprano browser [--pane pane-id] back|forward|reload|url|title
      soprano browser [--pane pane-id] snapshot [--interactive]
      soprano browser [--pane pane-id] eval <javascript>
      soprano browser [--pane pane-id] click|dblclick|focus|hover <selector|@ref>
      soprano browser [--pane pane-id] fill|type <selector|@ref> <text>
      soprano browser [--pane pane-id] check|uncheck|scroll-into-view <selector|@ref>
      soprano browser [--pane pane-id] press <key>
      soprano browser [--pane pane-id] get <text|html|value|attr|count> <selector> [attribute]
      soprano browser [--pane pane-id] is <visible|enabled|checked> <selector|@ref>
      soprano browser [--pane pane-id] screenshot <path.png>

    `snapshot` assigns ephemeral refs such as `e1`; pass them back as `@e1`.
    """

    static func requestName(appProcessId: String) -> Notification.Name {
        Notification.Name("\(requestPrefix).\(appProcessId)")
    }

    static func responseName(requestId: String) -> Notification.Name {
        Notification.Name("\(responsePrefix).\(requestId)")
    }

    static func run(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32? {
        let request: BrowserCommandRequest
        do {
            guard let parsed = try BrowserCommandRequest.parse(
                arguments,
                environment: environment
            ) else {
                return nil
            }
            request = parsed
        } catch {
            write(error.localizedDescription, to: .standardError)
            return 2
        }

        if request.command == "help" {
            write(help, to: .standardOutput)
            return 0
        }

        guard let appProcessId = environment["SOPRANO_APP_PID"], !appProcessId.isEmpty else {
            write(
                "Browser automation must run inside a Soprano terminal (SOPRANO_APP_PID is missing).",
                to: .standardError
            )
            return 2
        }

        let requestId = UUID().uuidString
        let responseNotification = responseName(requestId: requestId)
        let center = DistributedNotificationCenter.default()
        let responseBox = BrowserCommandResponseBox()
        let observer = center.addObserver(
            forName: responseNotification,
            object: nil,
            queue: nil
        ) { notification in
            let response = notification.userInfo?.reduce(into: [String: String]()) {
                guard let key = $1.key as? String, let value = $1.value as? String else { return }
                $0[key] = value
            }
            responseBox.set(response)
        }
        defer { center.removeObserver(observer) }

        let argumentData = (try? JSONEncoder().encode(request.arguments)) ?? Data("[]".utf8)
        var userInfo: [String: String] = [
            "requestId": requestId,
            "command": request.command,
            "arguments": String(data: argumentData, encoding: .utf8) ?? "[]",
        ]
        if let targetPaneId = request.targetPaneId {
            userInfo["targetPaneId"] = targetPaneId
        }
        if let callerPaneId = environment["SOPRANO_PANE_ID"] {
            userInfo["callerPaneId"] = callerPaneId
        }
        if let callerTabId = environment["SOPRANO_TAB_ID"] {
            userInfo["callerTabId"] = callerTabId
        }

        center.postNotificationName(
            requestName(appProcessId: appProcessId),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )

        let deadline = Date().addingTimeInterval(timeout)
        while responseBox.value == nil, Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
        }

        guard let response = responseBox.value else {
            write("Timed out waiting for Soprano browser automation.", to: .standardError)
            return 1
        }
        let succeeded = response["ok"] == "1"
        let output = response[succeeded ? "output" : "error"] ?? ""
        write(output, to: succeeded ? .standardOutput : .standardError)
        return succeeded ? 0 : 1
    }

    private static func write(_ value: String, to handle: FileHandle) {
        let terminated = value.hasSuffix("\n") ? value : "\(value)\n"
        if let data = terminated.data(using: .utf8) {
            handle.write(data)
        }
    }
}

private final class BrowserCommandResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: [String: String]?

    var value: [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func set(_ value: [String: String]?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private struct BrowserAutomationNotificationPayload: Sendable {
    let requestId: String
    let command: String
    let arguments: [String]
    let targetPaneId: String?

    init?(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let requestId = userInfo["requestId"] as? String,
              let command = userInfo["command"] as? String,
              let encodedArguments = userInfo["arguments"] as? String,
              let data = encodedArguments.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String].self, from: data)
        else {
            return nil
        }
        self.requestId = requestId
        self.command = command
        self.arguments = arguments
        self.targetPaneId = userInfo["targetPaneId"] as? String
    }
}

final class BrowserAutomationController: @unchecked Sendable {
    private let agentManager: AgentManager
    private var observer: NSObjectProtocol?

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
        let processId = String(ProcessInfo.processInfo.processIdentifier)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: BrowserCommand.requestName(appProcessId: processId),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let payload = BrowserAutomationNotificationPayload(notification) else { return }
            Task { @MainActor [weak self] in
                self?.handle(payload)
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    @MainActor
    private func handle(_ payload: BrowserAutomationNotificationPayload) {
        let requestId = payload.requestId
        let command = payload.command
        let arguments = payload.arguments
        if ["open", "open-split", "new"].contains(command) {
            let paneId = agentManager.spawnBrowser(url: arguments.first)
            if let paneId {
                respond(requestId: requestId, result: .success(paneId))
            } else {
                respond(
                    requestId: requestId,
                    result: .failure(BrowserAutomationError.invalidArguments(
                        "Could not create a browser pane (pane limit reached)."
                    ))
                )
            }
            return
        }

        let requestedPaneId = payload.targetPaneId
        guard let target = resolveTarget(requestedPaneId: requestedPaneId) else {
            respond(
                requestId: requestId,
                result: .failure(BrowserAutomationError.invalidArguments(
                    requestedPaneId.map { "No browser tab exists in \($0)." }
                        ?? "No browser pane exists. Run `soprano browser open [url]` first."
                ))
            )
            return
        }

        agentManager.focusTab(paneId: target.paneId, tabId: target.tabId)
        guard let view = BrowserPaneRegistry.shared.view(for: target) else {
            respond(
                requestId: requestId,
                result: .failure(BrowserAutomationError.invalidArguments(
                    "Browser \(target.paneId) is not currently available."
                ))
            )
            return
        }

        view.performAutomation(command: command, arguments: arguments) { [weak self] result in
            self?.respond(requestId: requestId, result: result)
        }
    }

    @MainActor
    private func resolveTarget(requestedPaneId: String?) -> BrowserTarget? {
        if let requestedPaneId {
            guard let pane = agentManager.panes[requestedPaneId] else { return nil }
            if let active = pane.activeTab, active.type == .browser {
                return BrowserTarget(paneId: requestedPaneId, tabId: active.id)
            }
            return pane.tabs.first(where: { $0.type == .browser }).map {
                BrowserTarget(paneId: requestedPaneId, tabId: $0.id)
            }
        }

        let activePaneId = agentManager.activePaneId
        if let activeTab = agentManager.panes[activePaneId]?.activeTab,
           activeTab.type == .browser
        {
            return BrowserTarget(paneId: activePaneId, tabId: activeTab.id)
        }

        for paneId in agentManager.layout?.orderedLeafIds ?? [] {
            if let browser = agentManager.panes[paneId]?.tabs.first(where: {
                $0.type == .browser
            }) {
                return BrowserTarget(paneId: paneId, tabId: browser.id)
            }
        }
        return nil
    }

    private func respond(requestId: String, result: Result<String, Error>) {
        let userInfo: [String: String]
        switch result {
        case .success(let output):
            userInfo = ["ok": "1", "output": output]
        case .failure(let error):
            userInfo = ["ok": "0", "error": error.localizedDescription]
        }
        DistributedNotificationCenter.default().postNotificationName(
            BrowserCommand.responseName(requestId: requestId),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}
