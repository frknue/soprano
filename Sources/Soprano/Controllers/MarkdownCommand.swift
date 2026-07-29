import Foundation

struct MarkdownCommandRequest: Equatable {
    let fileURL: URL
    let opensNewPane: Bool

    static func parse(
        _ commandLine: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MarkdownCommandRequest? {
        guard commandLine.count >= 2 else { return nil }

        let tokens: [String]
        let isNamedCommand = commandLine[1] == "markdown" || commandLine[1] == "md"
        let isDirectCommand = isMarkdownPath(commandLine[1])
            || (
                commandLine[1] == "--new"
                    && commandLine.count >= 3
                    && isMarkdownPath(commandLine[2])
            )
        if isNamedCommand {
            tokens = Array(commandLine.dropFirst(2))
        } else if isDirectCommand {
            tokens = Array(commandLine.dropFirst())
        } else {
            return nil
        }

        if isNamedCommand,
           (tokens.isEmpty || tokens == ["--help"] || tokens == ["help"]) {
            throw MarkdownCommandError.helpRequested
        }

        var opensNewPane = false
        var path: String?
        for token in tokens {
            if token == "--new" {
                opensNewPane = true
            } else if token.hasPrefix("-") {
                throw MarkdownCommandError.invalidArguments("Unknown option: \(token)")
            } else if path == nil {
                path = token
            } else {
                throw MarkdownCommandError.invalidArguments(
                    "Only one Markdown file can be opened at a time."
                )
            }
        }

        guard let path, !path.isEmpty else {
            throw MarkdownCommandError.invalidArguments("A Markdown file path is required.")
        }
        let expanded = NSString(string: path).expandingTildeInPath
        let fileURL: URL
        if expanded.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: expanded)
        } else {
            let workingDirectory = environment["PWD"]
                ?? FileManager.default.currentDirectoryPath
            fileURL = URL(
                fileURLWithPath: workingDirectory,
                isDirectory: true
            ).appendingPathComponent(expanded)
        }

        return MarkdownCommandRequest(
            fileURL: fileURL.standardizedFileURL,
            opensNewPane: opensNewPane
        )
    }

    private static func isMarkdownPath(_ value: String) -> Bool {
        let pathExtension = NSString(string: value).pathExtension.lowercased()
        return pathExtension == "md" || pathExtension == "markdown"
    }
}

enum MarkdownCommandError: LocalizedError {
    case helpRequested
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .invalidArguments(let message):
            return message
        }
    }
}

/// Opens local Markdown in the Soprano process that owns the calling terminal.
enum MarkdownCommand {
    private static let requestPrefix = "com.soprano.markdown-request"
    private static let responsePrefix = "com.soprano.markdown-response"
    private static let timeout: TimeInterval = 15

    static let help = """
    Usage:
      soprano <file.md> [--new]
      soprano --new <file.md>
      soprano markdown [--new] <file>
      soprano md [--new] <file>

    Opens a live Markdown reader to the right of the calling terminal.
    Reuses that terminal's reader unless --new is supplied.
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
        let request: MarkdownCommandRequest
        do {
            guard let parsed = try MarkdownCommandRequest.parse(
                arguments,
                environment: environment
            ) else {
                return nil
            }
            request = parsed
        } catch MarkdownCommandError.helpRequested {
            write(help, to: .standardOutput)
            return 0
        } catch {
            write(error.localizedDescription, to: .standardError)
            write(help, to: .standardError)
            return 2
        }

        guard validateReadableFile(request.fileURL) else {
            write(
                "Cannot read Markdown file: \(request.fileURL.path)",
                to: .standardError
            )
            return 2
        }
        guard let appProcessId = environment["SOPRANO_APP_PID"], !appProcessId.isEmpty else {
            write(
                "Markdown readers must be opened inside a Soprano terminal "
                    + "(SOPRANO_APP_PID is missing).",
                to: .standardError
            )
            return 2
        }

        let requestId = UUID().uuidString
        let center = DistributedNotificationCenter.default()
        let responseBox = MarkdownCommandResponseBox()
        let observer = center.addObserver(
            forName: responseName(requestId: requestId),
            object: nil,
            queue: nil
        ) { notification in
            let response = notification.userInfo?.reduce(into: [String: String]()) {
                guard let key = $1.key as? String, let value = $1.value as? String else {
                    return
                }
                $0[key] = value
            }
            responseBox.set(response)
        }
        defer { center.removeObserver(observer) }

        var userInfo: [String: String] = [
            "requestId": requestId,
            "fileURL": request.fileURL.absoluteString,
            "opensNewPane": request.opensNewPane ? "1" : "0",
        ]
        if let paneId = environment["SOPRANO_PANE_ID"] {
            userInfo["callerPaneId"] = paneId
        }
        if let tabId = environment["SOPRANO_TAB_ID"] {
            userInfo["callerTabId"] = tabId
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
            write("Timed out waiting for Soprano to open the Markdown file.", to: .standardError)
            return 1
        }
        let succeeded = response["ok"] == "1"
        let output = response[succeeded ? "output" : "error"] ?? ""
        write(output, to: succeeded ? .standardOutput : .standardError)
        return succeeded ? 0 : 1
    }

    static func validateReadableFile(_ fileURL: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        )
            && !isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: fileURL.path)
    }

    private static func write(_ value: String, to handle: FileHandle) {
        let terminated = value.hasSuffix("\n") ? value : "\(value)\n"
        if let data = terminated.data(using: .utf8) {
            handle.write(data)
        }
    }
}

private final class MarkdownCommandResponseBox: @unchecked Sendable {
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

private struct MarkdownCommandPayload: Sendable {
    let requestId: String
    let fileURL: URL
    let opensNewPane: Bool
    let callerPaneId: String?
    let callerTabId: String?

    init?(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let requestId = userInfo["requestId"] as? String,
              let fileURLString = userInfo["fileURL"] as? String,
              let fileURL = URL(string: fileURLString),
              fileURL.isFileURL
        else { return nil }

        self.requestId = requestId
        self.fileURL = fileURL.standardizedFileURL
        self.opensNewPane = userInfo["opensNewPane"] as? String == "1"
        self.callerPaneId = userInfo["callerPaneId"] as? String
        self.callerTabId = userInfo["callerTabId"] as? String
    }
}

final class MarkdownCommandController: @unchecked Sendable {
    private let agentManager: AgentManager
    private var observer: NSObjectProtocol?

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
        let processId = String(ProcessInfo.processInfo.processIdentifier)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: MarkdownCommand.requestName(appProcessId: processId),
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let payload = MarkdownCommandPayload(notification) else { return }
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
    private func handle(_ payload: MarkdownCommandPayload) {
        guard MarkdownCommand.validateReadableFile(payload.fileURL) else {
            respond(
                requestId: payload.requestId,
                result: .failure(MarkdownCommandError.invalidArguments(
                    "Cannot read Markdown file: \(payload.fileURL.path)"
                ))
            )
            return
        }

        if !payload.opensNewPane,
           let callerPaneId = payload.callerPaneId,
           let target = agentManager.markdownPreviewTarget(ownerPaneId: callerPaneId)
        {
            agentManager.focusTab(paneId: target.paneId, tabId: target.tabId)
            agentManager.updateMarkdownDocument(
                paneId: target.paneId,
                tabId: target.tabId,
                to: payload.fileURL
            )
            respond(requestId: payload.requestId, result: .success(target.paneId))
            return
        }

        if let callerPaneId = payload.callerPaneId,
           let callerTabId = payload.callerTabId,
           agentManager.panes[callerPaneId]?.tabs.contains(where: {
               $0.id == callerTabId
           }) == true
        {
            agentManager.focusTab(paneId: callerPaneId, tabId: callerTabId)
        }

        let ownerPaneId = payload.opensNewPane ? nil : payload.callerPaneId
        guard let paneId = agentManager.spawnMarkdown(
            fileURL: payload.fileURL,
            previewOwnerPaneId: ownerPaneId
        ) else {
            respond(
                requestId: payload.requestId,
                result: .failure(MarkdownCommandError.invalidArguments(
                    "Could not create a Markdown reader (pane limit reached)."
                ))
            )
            return
        }
        respond(requestId: payload.requestId, result: .success(paneId))
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
            MarkdownCommand.responseName(requestId: requestId),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }
}
