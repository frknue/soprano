import Foundation
import SQLite3

/// omp's usage history: `omp stats` ingests every session file into `~/.omp/stats.db` (one row
/// per model request with tokens and its API-equivalent cost), which this reads directly, so any
/// period and grouping is one query. A sync runs `omp stats --summary` (it ingests what was
/// written since the last run, then prints a summary this ignores). `PI_CONFIG_DIR` moves
/// `~/.omp` under home as it does for omp.
public struct OmpUsageStatistics: UsageStatisticsService {
    private let executablePath: @Sendable () -> String?
    private let databasePath: @Sendable () -> String

    static let syncTimeout: TimeInterval = 120

    public init(
        executablePath: @escaping @Sendable () -> String? = { nil },
        databasePath: @escaping @Sendable () -> String = { OmpUsageStatistics.defaultDatabasePath() }
    ) {
        self.executablePath = executablePath
        self.databasePath = databasePath
    }

    /// `~/<PI_CONFIG_DIR or .omp>/stats.db`. omp joins the setting onto home (Node's
    /// `path.join`), so even an absolute value stays under home.
    public static func defaultDatabasePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        let directory = environment["PI_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? ".omp"
        let root = URL(fileURLWithPath: home + "/" + directory).standardizedFileURL.path
        return (root as NSString).appendingPathComponent("stats.db")
    }

    public func groups(since: Date?, granularity: UsageGranularity) async throws -> [UsageGroup] {
        let path = databasePath()
        return try await Task.detached(priority: .userInitiated) {
            try Self.read(databasePath: path, since: since, granularity: granularity, calendar: .current)
        }.value
    }

    public func sync() async throws {
        let explicit = executablePath()
        guard let executable = ExecutableLocator.locate("omp", explicitPath: explicit) else {
            throw ProviderError.notInstalled(.omp, path: explicit)
        }
        let output = try await LineProcess.run(
            LineProcess.Configuration(
                executable: executable,
                arguments: ["stats", "--summary"],
                environment: OmpProtocol.environment(),
                directory: NSHomeDirectory()
            ),
            timeout: Self.syncTimeout,
            label: "omp stats"
        )
        guard output.status == 0 else {
            throw ProviderError.processExited(.omp, status: output.status, stderr: output.stderr.isEmpty ? output.stdout : output.stderr)
        }
    }

    // MARK: - stats.db

    /// The grouped query: requests (`stop_reason = 'error'` counts as failed), tokens, cost per
    /// token kind, unpriced requests (omp's own rule: tokens but no cost, from `xai-oauth` or
    /// marked `cost_unpriced`) and the cached / uncached prompt cost behind the cache savings.
    /// Hours are keyed by the epoch second their local hour starts (the local UTC offset of each
    /// request, so the repeated hour of a clock change stays two hours and half-hour zones
    /// work); days by their local date.
    static func query(granularity: UsageGranularity) -> String {
        let bucket = switch granularity {
        case .hour:
            """
            (timestamp / 1000) - (((timestamp / 1000) + CAST(ROUND((julianday(timestamp / 1000, 'unixepoch', 'localtime')
                - julianday(timestamp / 1000, 'unixepoch')) * 86400) AS INTEGER)) % 3600)
            """
        case .day:
            "strftime('%Y-%m-%d', timestamp / 1000, 'unixepoch', 'localtime')"
        }
        return """
        SELECT \(bucket) AS bucket,
            provider, model, agent_type, folder,
            COUNT(*),
            SUM(CASE WHEN stop_reason = 'error' THEN 1 ELSE 0 END),
            SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), SUM(cache_write_tokens),
            TOTAL(cost_input), TOTAL(cost_output), TOTAL(cost_cache_read), TOTAL(cost_cache_write),
            SUM(CASE WHEN total_tokens > 0 AND cost_total = 0
                AND (provider = 'xai-oauth' OR cost_unpriced = 1) THEN 1 ELSE 0 END),
            TOTAL(CASE WHEN cost_no_cache_input > 0
                THEN cost_input + cost_cache_read + cost_cache_write ELSE 0 END),
            TOTAL(CASE WHEN cost_no_cache_input > 0 THEN cost_no_cache_input ELSE 0 END)
        FROM messages
        WHERE timestamp >= ?1
        GROUP BY 1, 2, 3, 4, 5
        """
    }

    /// Reads the grouped history; no database yet (omp never synced) is no history.
    static func read(databasePath: String, since: Date?, granularity: UsageGranularity, calendar: Calendar) throws -> [UsageGroup] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw UsageStatisticsError.database(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)

        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, query(granularity: granularity), -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw UsageStatisticsError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let sinceMilliseconds = since.map { Int64(($0.timeIntervalSince1970 * 1000).rounded(.down)) } ?? Int64.min
        sqlite3_bind_int64(statement, 1, sinceMilliseconds)

        var groups: [UsageGroup] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw UsageStatisticsError.database(String(cString: sqlite3_errmsg(db))) }
            let start: Date? = switch granularity {
            case .hour: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0)))
            case .day: dayStart(text(statement, 0), calendar: calendar)
            }
            guard let start else { continue }
            groups.append(UsageGroup(
                start: start,
                provider: text(statement, 1),
                model: text(statement, 2),
                agent: text(statement, 3),
                folder: text(statement, 4),
                totals: UsageTotals(
                    requests: integer(statement, 5),
                    failedRequests: integer(statement, 6),
                    inputTokens: integer(statement, 7),
                    outputTokens: integer(statement, 8),
                    cacheReadTokens: integer(statement, 9),
                    cacheWriteTokens: integer(statement, 10),
                    inputCost: sqlite3_column_double(statement, 11),
                    outputCost: sqlite3_column_double(statement, 12),
                    cacheReadCost: sqlite3_column_double(statement, 13),
                    cacheWriteCost: sqlite3_column_double(statement, 14),
                    unpricedRequests: integer(statement, 15),
                    cachedPromptCost: sqlite3_column_double(statement, 16),
                    uncachedPromptCost: sqlite3_column_double(statement, 17)
                )
            ))
        }
        return groups
    }

    /// `2026-10-31`, a local date → the start of that day.
    static func dayStart(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func integer(_ statement: OpaquePointer, _ column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }
}

public enum UsageStatisticsError: Error, LocalizedError, Equatable {
    case database(String)

    public var errorDescription: String? {
        switch self {
        case let .database(message): "Couldn’t read omp’s usage statistics: \(message)."
        }
    }
}
