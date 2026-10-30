import Foundation

/// omp (oh-my-pi) driver: `--mode rpc-ui` sessions, catalog probing and `omp -p` generation.
public struct OmpDriver: ProviderDriver {
    public let kind = ProviderKind.omp
    static let probeTimeout: TimeInterval = 45
    static let generationTimeout: TimeInterval = 180

    private let executablePath: @Sendable () -> String?

    /// `executablePath` returns the settings override, read on every use; nil = search PATH.
    public init(executablePath: @escaping @Sendable () -> String? = { nil }) {
        self.executablePath = executablePath
    }

    public func makeSession() -> any ProviderSession {
        OmpSession(executablePath: executablePath)
    }

    /// `omp --version` ("omp/18.14.0"), then a short-lived `omp --mode rpc --no-session
    /// --no-extensions --no-skills --no-rules --no-lsp`: `negotiate_protocol` v2, `get_state`
    /// (the configured model and thinking level) and `get_available_models` (chunked: ~2 MB).
    /// 45 s budget. No available models → unauthenticated.
    public func probe() async -> ProviderStatus {
        let fallback = ProviderCatalog.fallback(.omp)
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("omp", explicitPath: explicit) else {
            return ProviderStatus(kind: .omp, health: .notInstalled, models: fallback, message: ProviderError.notInstalled(.omp, path: explicit).localizedDescription)
        }
        let version: String?
        do {
            let output = try await LineProcess.run(
                LineProcess.Configuration(executable: executable, arguments: ["--version"], environment: OmpProtocol.environment(), directory: NSHomeDirectory()),
                timeout: Self.probeTimeout,
                label: "omp status check"
            )
            guard output.status == 0 else {
                return ProviderStatus(kind: .omp, health: .error, models: fallback, message: ProviderError.processExited(.omp, status: output.status, stderr: output.stderr).localizedDescription)
            }
            version = OmpProtocol.version(fromVersionOutput: output.stdout)
        } catch {
            return ProviderStatus(kind: .omp, health: .error, models: fallback, message: error.localizedDescription)
        }
        do {
            let (state, available) = try await Self.catalog(executable: executable, includeModels: true)
            let models = OmpProtocol.models(available: available, state: state)
            guard models.count > 1 else {
                return ProviderStatus(kind: .omp, health: .unauthenticated, version: version, models: models, message: "omp has no usable models. Run `omp` and sign in with /login.")
            }
            return ProviderStatus(kind: .omp, health: .ready, version: version, accountLabel: nil, models: models)
        } catch {
            return ProviderStatus(kind: .omp, health: .error, version: version, models: fallback, message: error.localizedDescription)
        }
    }

    /// `get_state` (and `get_available_models` when `includeModels`) from a throwaway
    /// `omp --mode rpc --no-session …` process.
    static func catalog(executable: String, includeModels: Bool) async throws -> (state: JSONValue, models: JSONValue) {
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: OmpProtocol.probeArguments,
            environment: OmpProtocol.environment(),
            directory: NSHomeDirectory()
        ))
        do {
            try process.start()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        defer { process.terminate() }
        let client = OmpClient(transport: process)
        return try await withProviderTimeout(probeTimeout, label: "omp status check") {
            let ready = try await client.ready()
            if ready["supportedProtocolVersions"]?.arrayValue?.contains(2) == true {
                _ = try await client.request("negotiate_protocol", ["protocolVersion": 2])
            }
            let state = try await client.request("get_state")
            let models = includeModels ? try await client.request("get_available_models") : .null
            return (state, models)
        }
    }

    /// omp's configured default model (`provider`, `id`) as a fresh process reports it.
    static func configuredModel(executable: String) async throws -> (provider: String, id: String)? {
        let state = try await catalog(executable: executable, includeModels: false).state
        guard let provider = state["model"]?["provider"]?.stringValue, let id = state["model"]?["id"]?.stringValue else { return nil }
        return (provider, id)
    }

    /// `omp -p --no-session --no-tools --no-extensions --no-skills --no-rules --no-context-files
    /// --no-lsp [--model <provider/id>] --thinking low` with the prompt (plus the schema and a
    /// JSON-only instruction) on stdin, in `cwd`, 180 s timeout. Returns the first JSON object
    /// of stdout.
    public func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue {
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("omp", explicitPath: explicit) else {
            throw ProviderError.notInstalled(.omp, path: explicit)
        }
        let output = try await LineProcess.run(
            LineProcess.Configuration(
                executable: executable,
                arguments: OmpProtocol.generationArguments(model: model),
                environment: OmpProtocol.environment(),
                directory: FileManager.default.fileExists(atPath: cwd) ? cwd : NSTemporaryDirectory()
            ),
            input: OmpProtocol.generationPrompt(prompt, schema: schema),
            timeout: Self.generationTimeout,
            label: "omp text generation"
        )
        guard output.status == 0 else {
            throw ProviderError.processExited(.omp, status: output.status, stderr: output.stderr.isEmpty ? output.stdout : output.stderr)
        }
        return try OmpProtocol.firstJSONObject(in: output.stdout)
    }
}
