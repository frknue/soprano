import Foundation

/// Codex CLI driver: sessions on `codex app-server`, probing, and `codex exec` text generation.
public struct CodexDriver: ProviderDriver {
    public let kind = ProviderKind.codex
    /// Probe budget (T3 Code's `CODEX_AUTH_PROBE_TIMEOUT_MS`).
    static let probeTimeout: TimeInterval = 20
    static let generationTimeout: TimeInterval = 180

    private let executablePath: @Sendable () -> String?

    /// `executablePath` returns the settings override (`providers.codexPath`), read on every
    /// use so settings changes apply to the next session; nil = search PATH.
    public init(executablePath: @escaping @Sendable () -> String? = { nil }) {
        self.executablePath = executablePath
    }

    public func makeSession() -> any ProviderSession {
        CodexSession(executablePath: executablePath)
    }

    /// `codex app-server`: `initialize` (version from `userAgent`), `account/read`
    /// (unauthenticated when `account == null && requiresOpenaiAuth`), then `model/list`
    /// paginated with `{cursor}` until `nextCursor` is null. 20 s budget.
    public func probe() async -> ProviderStatus {
        let fallback = ProviderCatalog.fallback(.codex)
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("codex", explicitPath: explicit) else {
            return ProviderStatus(kind: .codex, health: .notInstalled, models: fallback, message: ProviderError.notInstalled(.codex, path: explicit).localizedDescription)
        }
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: ["app-server"],
            environment: ExecutableLocator.childEnvironment(overrides: CodexProtocol.originatorEnvironment),
            directory: NSHomeDirectory()
        ))
        do {
            try process.start()
        } catch {
            return ProviderStatus(kind: .codex, health: .error, models: fallback, message: ProviderError.spawnFailed(error.localizedDescription).localizedDescription)
        }
        defer { process.terminate() }
        let client = CodexAppServerClient(transport: process)
        do {
            return try await withProviderTimeout(Self.probeTimeout, label: "Codex status check") {
                let initialize = try await client.request("initialize", params: CodexProtocol.initializeParams(version: ProviderPrompt.clientVersion, forProbe: true))
                try await client.notify("initialized")
                let version = initialize["userAgent"]?.stringValue.flatMap(CodexProtocol.version(fromUserAgent:))
                let account = CodexProtocol.account(from: try await client.request("account/read", params: [:]))
                guard account.authenticated else {
                    return ProviderStatus(kind: .codex, health: .unauthenticated, version: version, models: fallback, message: "Sign in with `codex login`.")
                }
                var models: [ProviderModel] = []
                var cursor: String?
                var visited = Set<String>()
                repeat {
                    let params: JSONValue = cursor.map { ["cursor": .string($0)] } ?? [:]
                    let page = try await client.request("model/list", params: params)
                    models += CodexProtocol.models(fromModelList: page)
                    cursor = page["nextCursor"]?.stringValue
                } while cursor.map { visited.insert($0).inserted } == true
                return ProviderStatus(kind: .codex, health: .ready, version: version, accountLabel: account.label, models: models.isEmpty ? fallback : models)
            }
        } catch {
            return ProviderStatus(kind: .codex, health: .error, models: fallback, message: error.localizedDescription)
        }
    }

    /// `codex exec --ephemeral --skip-git-repo-check -s read-only --model <model>
    /// --config model_reasoning_effort="low" --output-schema <tmp>/schema.json
    /// --output-last-message <tmp>/output.json -` with the prompt on stdin, in `cwd`, 180 s
    /// timeout. Returns the parsed last message.
    public func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue {
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("codex", explicitPath: explicit) else {
            throw ProviderError.notInstalled(.codex, path: explicit)
        }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("soprano-agents-codex-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let schemaURL = directory.appendingPathComponent("schema.json")
        let outputURL = directory.appendingPathComponent("output.json")
        try Data(schema.jsonString().utf8).write(to: schemaURL)

        let arguments = [
            "exec", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
            "--model", model,
            "--config", "model_reasoning_effort=\"low\"",
            "--output-schema", schemaURL.path,
            "--output-last-message", outputURL.path,
            "-",
        ]
        let output = try await LineProcess.run(
            LineProcess.Configuration(
                executable: executable,
                arguments: arguments,
                environment: ExecutableLocator.childEnvironment(overrides: CodexProtocol.originatorEnvironment),
                directory: fileManager.fileExists(atPath: cwd) ? cwd : directory.path
            ),
            input: prompt,
            timeout: Self.generationTimeout,
            label: "Codex text generation"
        )
        guard output.status == 0 else {
            throw ProviderError.processExited(.codex, status: output.status, stderr: output.stderr.isEmpty ? output.stdout : output.stderr)
        }
        guard let data = fileManager.contents(atPath: outputURL.path) else {
            throw ProviderError.invalidOutput("Codex wrote no output.")
        }
        return try StructuredOutput.parse(String(decoding: data, as: UTF8.self))
    }
}

/// Parsing of model-produced JSON text.
enum StructuredOutput {
    /// Parses `text` as a JSON object, tolerating surrounding whitespace and Markdown fences.
    static func parse(_ text: String) throws -> JSONValue {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if body.hasSuffix("```") { body = String(body.dropLast(3)) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let value = try? JSONValue.parse(body), value.objectValue != nil else {
            throw ProviderError.invalidOutput("The model did not return a JSON object.")
        }
        return value
    }
}
