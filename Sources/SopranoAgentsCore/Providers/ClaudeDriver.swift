import Foundation

/// Claude Code driver: stream-json sessions, probing and one-shot structured generation.
public struct ClaudeDriver: ProviderDriver {
    public let kind = ProviderKind.claude
    static let probeTimeout: TimeInterval = 20
    static let generationTimeout: TimeInterval = 180

    private let executablePath: @Sendable () -> String?

    /// `executablePath` returns the settings override (`providers.claudePath`), read on every
    /// use; nil = search PATH.
    public init(executablePath: @escaping @Sendable () -> String? = { nil }) {
        self.executablePath = executablePath
    }

    public func makeSession() -> any ProviderSession {
        ClaudeSession(executablePath: executablePath)
    }

    /// `claude --version` ("2.1.314 (Claude Code)") and `claude auth status --json`
    /// (`loggedIn`, `subscriptionType`). The CLI has no model listing, so models are the
    /// built-in catalog.
    public func probe() async -> ProviderStatus {
        let models = ProviderCatalog.fallback(.claude)
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("claude", explicitPath: explicit) else {
            return ProviderStatus(kind: .claude, health: .notInstalled, models: models, message: ProviderError.notInstalled(.claude, path: explicit).localizedDescription)
        }
        func run(_ arguments: [String]) async throws -> LineProcess.Output {
            try await LineProcess.run(
                LineProcess.Configuration(executable: executable, arguments: arguments, environment: ClaudeProtocol.environment(), directory: NSHomeDirectory()),
                timeout: Self.probeTimeout,
                label: "Claude Code status check"
            )
        }
        let version: String
        do {
            let output = try await run(["--version"])
            guard output.status == 0, let first = output.stdout.split(separator: " ").first else {
                return ProviderStatus(kind: .claude, health: .error, models: models, message: ProviderError.processExited(.claude, status: output.status, stderr: output.stderr).localizedDescription)
            }
            version = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ProviderStatus(kind: .claude, health: .error, models: models, message: error.localizedDescription)
        }
        // `auth status` exits 1 when signed out but still prints the JSON.
        guard let output = try? await run(["auth", "status", "--json"]),
              let status = try? JSONValue.parse(output.stdout), status.objectValue != nil else {
            return ProviderStatus(kind: .claude, health: .ready, version: version, models: models)
        }
        let account = ClaudeProtocol.account(fromAuthStatus: status)
        guard account.authenticated else {
            return ProviderStatus(kind: .claude, health: .unauthenticated, version: version, models: models, message: "Sign in with `claude auth login`.")
        }
        return ProviderStatus(kind: .claude, health: .ready, version: version, accountLabel: account.label, models: models)
    }

    /// `claude -p --output-format json --json-schema <schema> --model <model> --tools ""
    /// --disable-slash-commands --permission-mode dontAsk --no-session-persistence` with the
    /// prompt on stdin, in `cwd`, 180 s timeout. Returns `structured_output`, else the result
    /// text parsed as JSON.
    public func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue {
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("claude", explicitPath: explicit) else {
            throw ProviderError.notInstalled(.claude, path: explicit)
        }
        let arguments = [
            "-p",
            "--output-format", "json",
            "--json-schema", schema.jsonString(),
            "--model", model,
            "--tools", "",
            "--disable-slash-commands",
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
        ]
        let output = try await LineProcess.run(
            LineProcess.Configuration(
                executable: executable,
                arguments: arguments,
                environment: ClaudeProtocol.environment(),
                directory: FileManager.default.fileExists(atPath: cwd) ? cwd : NSTemporaryDirectory()
            ),
            input: prompt,
            timeout: Self.generationTimeout,
            label: "Claude Code text generation"
        )
        return try Self.structuredOutput(stdout: output.stdout, stderr: output.stderr, status: output.status)
    }

    static func structuredOutput(stdout: String, stderr: String, status: Int32) throws -> JSONValue {
        guard let result = try? JSONValue.parse(stdout.trimmingCharacters(in: .whitespacesAndNewlines)), result.objectValue != nil else {
            throw ProviderError.processExited(.claude, status: status, stderr: stderr.isEmpty ? stdout : stderr)
        }
        if result["is_error"]?.boolValue == true {
            throw ProviderError.message(result["result"]?.nonEmptyString ?? "Claude Code text generation failed.")
        }
        if let structured = result["structured_output"], structured.objectValue != nil {
            return structured
        }
        return try StructuredOutput.parse(result["result"]?.stringValue ?? "")
    }
}
