import Foundation

/// omp's typing aids for the composer, the ones its terminal UI has.
///
/// - Word completion: `predict_word {text, cursor}` → `{suffix}` and `predict_word_feedback
///   {text, cursor, suggestion, accepted}` on one long-lived helper, `omp --mode rpc --no-session
///   --no-extensions --no-skills --no-rules --no-lsp` in the home folder (`OmpProtocol.probeArguments`),
///   started by the first prediction. omp's shared text-predict daemon does the work and honors
///   `spelling.autocomplete` (`off` answers null). omp runs one prediction at a time and answers a
///   superseded waiting one null. A helper that exits restarts with the next prediction; one that
///   fails to start is not retried for 30 s; one idle for 10 minutes is stopped.
/// - Preferences: `omp config list --json`, read fresh on every call (about 60 ms):
///   `spelling.typoDetection`, `spelling.autocorrect`, and `spelling.autocomplete` other than `off`.
public actor OmpTextAssistant: TextAssistant {
    static let startTimeout: TimeInterval = 20
    /// omp's own client budget: a prediction may wait out a cold text-predict daemon (up to three
    /// 30 s start rounds plus a 30 s first completion). A newer keystroke cancels it sooner.
    static let requestTimeout: TimeInterval = 155
    static let retryDelay: TimeInterval = 30
    static let idleTimeout: Duration = .seconds(600)

    private struct Helper {
        let process: LineProcess
        let client: OmpClient
    }

    private let executablePath: @Sendable () -> String?
    private let launchAdjustments: @Sendable () -> ProviderLaunchAdjustments
    private var helper: Helper?
    private var starting: Task<OmpClient?, Never>?
    private var failedAt: Date?
    private var idleTimer: Task<Void, Never>?
    private var isClosed = false

    public init(
        executablePath: @escaping @Sendable () -> String? = { nil },
        launchAdjustments: @escaping @Sendable () -> ProviderLaunchAdjustments = { .none }
    ) {
        self.executablePath = executablePath
        self.launchAdjustments = launchAdjustments
    }

    // MARK: TextAssistant

    public func preferences() async -> TextAssistPreferences {
        guard let executable = ExecutableLocator.locate("omp", explicitPath: executablePath()) else { return TextAssistPreferences() }
        let configuration = LineProcess.Configuration(
            executable: executable,
            arguments: ["config", "list", "--json"],
            environment: OmpProtocol.environment(launchAdjustments()),
            directory: NSHomeDirectory()
        )
        guard let output = try? await LineProcess.run(configuration, timeout: 10, label: "omp config list"),
              output.status == 0, let settings = try? JSONValue.parse(output.stdout) else { return TextAssistPreferences() }
        return Self.preferences(fromConfigList: settings)
    }

    public func predictWord(text: String, cursor: Int) async -> String? {
        guard let client = await client() else { return nil }
        armIdleTimer()
        let fields: [String: JSONValue] = ["text": .string(text), "cursor": .number(Double(cursor))]
        let data = try? await withProviderTimeout(Self.requestTimeout, label: "omp predict_word") {
            try await client.request("predict_word", fields)
        }
        return data?["suffix"]?.nonEmptyString
    }

    public func wordFeedback(text: String, cursor: Int, suggestion: String, accepted: Bool) async {
        guard let client = helper?.client else { return }
        let fields: [String: JSONValue] = [
            "text": .string(text),
            "cursor": .number(Double(cursor)),
            "suggestion": .string(suggestion),
            "accepted": .bool(accepted),
        ]
        _ = try? await withProviderTimeout(Self.requestTimeout, label: "omp predict_word_feedback") {
            try await client.request("predict_word_feedback", fields)
        }
    }

    public func close() async {
        isClosed = true
        stopHelper()
    }

    // MARK: Parsing

    /// The typing-aid settings in `omp config list --json` (`{key: {value?, type, description}}`);
    /// a missing or mistyped value keeps omp's default.
    static func preferences(fromConfigList settings: JSONValue) -> TextAssistPreferences {
        var preferences = TextAssistPreferences()
        if let value = settings["spelling.typoDetection"]?["value"]?.boolValue { preferences.typoDetection = value }
        if let value = settings["spelling.autocorrect"]?["value"]?.boolValue { preferences.autocorrect = value }
        if let value = settings["spelling.autocomplete"]?["value"]?.stringValue { preferences.wordCompletion = value != "off" }
        return preferences
    }

    // MARK: Helper process

    private func client() async -> OmpClient? {
        if let helper { return helper.client }
        if let starting { return await starting.value }
        guard !isClosed else { return nil }
        if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryDelay { return nil }
        let task = Task { await self.spawn() }
        starting = task
        let client = await task.value
        starting = nil
        return client
    }

    private func spawn() async -> OmpClient? {
        guard let executable = ExecutableLocator.locate("omp", explicitPath: executablePath()) else {
            failedAt = Date()
            return nil
        }
        let adjustments = launchAdjustments()
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: adjustments.arguments(before: OmpProtocol.probeArguments),
            environment: OmpProtocol.environment(adjustments),
            directory: NSHomeDirectory()
        ))
        do {
            try process.start()
        } catch {
            failedAt = Date()
            return nil
        }
        let client = OmpClient(transport: process)
        do {
            _ = try await withProviderTimeout(Self.startTimeout, label: "omp word completion start") {
                try await client.ready()
            }
        } catch {
            process.terminate()
            failedAt = Date()
            return nil
        }
        guard !isClosed else {
            process.terminate()
            return nil
        }
        failedAt = nil
        helper = Helper(process: process, client: client)
        // Unanswered frames (command lists, superseded responses) are dropped; the end of the
        // stream is the helper's exit.
        Task {
            for await _ in client.incoming {}
            self.helperExited(client)
        }
        return client
    }

    private func helperExited(_ client: OmpClient) {
        guard helper?.client === client else { return }
        helper = nil
        idleTimer?.cancel()
        idleTimer = nil
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task {
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self.stopHelper()
        }
    }

    private func stopHelper() {
        idleTimer?.cancel()
        idleTimer = nil
        helper?.process.terminate()
        helper = nil
    }
}
