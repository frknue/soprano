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

/// Executable override from settings.json, readable from the driver's background tasks.
final class ExecutablePaths: @unchecked Sendable {
    private let lock = NSLock()
    private var ompPath: String?

    func update(_ settings: EngineSettings) {
        lock.withLock { ompPath = settings.ompPath }
    }

    /// `providers.ompPath`, or nil to search PATH.
    var omp: String? {
        lock.withLock { ompPath }
    }
}

/// The accounts each new omp process starts with, read from the vendored `AccountLaunchState`
/// that `AccountsController` publishes into: omp's `--config` overlay with the preferred accounts.
enum AccountLaunchBridge {
    static func ompAdjustments(state: AccountLaunchState = .shared) -> ProviderLaunchAdjustments {
        let adjustments = state.adjustments(forProfile: "omp")
        return ProviderLaunchAdjustments(environment: adjustments.environment, arguments: adjustments.arguments)
    }
}

/// Builds the engine the app runs with: JSON-file store, git CLI, the omp driver, omp's usage
/// statistics and omp's typing aids.
@MainActor
enum EngineFactory {
    /// The executable override the driver reads on every spawn; the app delegate keeps it current.
    static let executablePaths = ExecutablePaths()

    static func live(settings: EngineSettings) -> AgentEngine {
        let dataDirectory = AppPaths.dataDirectory()
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        executablePaths.update(settings)
        let paths = executablePaths
        let environment = EngineEnvironment(
            drivers: [
                .omp: OmpDriver(
                    executablePath: { paths.omp },
                    launchAdjustments: { AccountLaunchBridge.ompAdjustments() }
                ),
            ],
            git: LiveGitService(),
            store: JSONFileThreadStore(directory: dataDirectory),
            dataDirectory: dataDirectory,
            usage: OmpUsageStatistics(executablePath: { paths.omp }),
            textAssistants: [
                .omp: OmpTextAssistant(
                    executablePath: { paths.omp },
                    launchAdjustments: { AccountLaunchBridge.ompAdjustments() }
                ),
            ]
        )
        return AgentEngine(environment: environment, settings: settings)
    }
}
