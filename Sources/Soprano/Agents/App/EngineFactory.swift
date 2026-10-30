import AppKit
import SopranoAgentsCore

/// Where the app keeps its data. Dev and installed builds use their bundle name, so they never
/// share threads; `SOPRANO_AGENTS_DATA_DIR` (absolute) overrides it.
enum AppPaths {
    static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["SOPRANO_AGENTS_DATA_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Soprano Agents"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent(name, isDirectory: true)
    }
}

/// Executable overrides from settings.json, readable from the drivers' background tasks.
final class ExecutablePaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [ProviderKind: String] = [:]

    func update(_ settings: EngineSettings) {
        lock.withLock {
            paths = [:]
            paths[.omp] = settings.ompPath
            paths[.codex] = settings.codexPath
            paths[.claude] = settings.claudePath
        }
    }

    func path(for kind: ProviderKind) -> String? {
        lock.withLock { paths[kind] }
    }
}

/// The account each new Codex and omp process starts with, read from the vendored
/// `AccountLaunchState` that `AccountsController` publishes into: the chosen Codex account's
/// `CODEX_HOME` (linking whatever `~/.codex` gained since), and omp's `--config` overlay with
/// the preferred accounts. Claude Code switches its login for the whole Mac, so it gets nothing.
enum AccountLaunchBridge {
    static func adjustments(for kind: ProviderKind, state: AccountLaunchState = .shared) -> ProviderLaunchAdjustments {
        let profile: String
        switch kind {
        case .codex: profile = "codex"
        case .omp: profile = "omp"
        case .claude: return .none
        }
        let adjustments = state.adjustments(forProfile: profile)
        return ProviderLaunchAdjustments(environment: adjustments.environment, arguments: adjustments.arguments)
    }
}

/// Builds the engine the app runs with: JSON-file store, git CLI, omp, Codex and Claude drivers.
@MainActor
enum EngineFactory {
    /// Executable overrides the drivers read on every spawn; the app delegate keeps them current.
    static let executablePaths = ExecutablePaths()

    static func live(settings: EngineSettings) -> AgentEngine {
        let dataDirectory = AppPaths.dataDirectory()
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        executablePaths.update(settings)
        let paths = executablePaths
        let environment = EngineEnvironment(
            drivers: [
                .omp: OmpDriver(
                    executablePath: { paths.path(for: .omp) },
                    launchAdjustments: { AccountLaunchBridge.adjustments(for: .omp) }
                ),
                .codex: CodexDriver(
                    executablePath: { paths.path(for: .codex) },
                    launchAdjustments: { AccountLaunchBridge.adjustments(for: .codex) }
                ),
                .claude: ClaudeDriver(executablePath: { paths.path(for: .claude) }),
            ],
            git: LiveGitService(),
            store: JSONFileThreadStore(directory: dataDirectory),
            dataDirectory: dataDirectory
        )
        return AgentEngine(environment: environment, settings: settings)
    }
}
