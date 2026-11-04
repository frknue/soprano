import AppKit
import SQLite3
import Testing
@testable import SopranoAgentsCore

/// `OmpUsageStatistics` against a scratch database with omp's `messages` table (never the
/// user's `~/.omp/stats.db`, and never `omp stats`).
@MainActor
struct OmpUsageStatisticsTests {
    private static let schema = """
    CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_file TEXT NOT NULL, entry_id TEXT NOT NULL, folder TEXT NOT NULL,
        model TEXT NOT NULL, provider TEXT NOT NULL, api TEXT NOT NULL, timestamp INTEGER NOT NULL,
        duration INTEGER, ttft INTEGER, stop_reason TEXT NOT NULL, error_message TEXT,
        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
        cache_read_tokens INTEGER NOT NULL, cache_write_tokens INTEGER NOT NULL,
        total_tokens INTEGER NOT NULL, premium_requests REAL NOT NULL,
        cost_input REAL NOT NULL, cost_output REAL NOT NULL, cost_cache_read REAL NOT NULL,
        cost_cache_write REAL NOT NULL, cost_total REAL NOT NULL, cost_no_cache_input REAL,
        cost_unpriced INTEGER NOT NULL DEFAULT 0, agent_type TEXT NOT NULL DEFAULT 'main',
        service_tier TEXT, UNIQUE(session_file, entry_id)
    );
    """

    private struct Row {
        var at: Date
        var provider = "anthropic"
        var model = "claude-opus-5-5"
        var agent = "main"
        var folder = "-git-app"
        var stopReason = "stop"
        var tokens = (input: 100, output: 50, cacheRead: 1000, cacheWrite: 200)
        var costs = (input: 0.125, output: 0.5, cacheRead: 0.0625, cacheWrite: 0.25)
        var noCacheInput: Double? = 1
    }

    private static func local(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private static func makeDatabase(_ rows: [Row]) throws -> String {
        let path = EngineHarness.temporaryDirectory().appendingPathComponent("stats.db").path
        var handle: OpaquePointer?
        try #require(sqlite3_open(path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK)
        for (index, row) in rows.enumerated() {
            let total = row.costs.input + row.costs.output + row.costs.cacheRead + row.costs.cacheWrite
            let tokens = row.tokens.input + row.tokens.output + row.tokens.cacheRead + row.tokens.cacheWrite
            let sql = """
            INSERT INTO messages (session_file, entry_id, folder, model, provider, api, timestamp, stop_reason,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, total_tokens, premium_requests,
                cost_input, cost_output, cost_cache_read, cost_cache_write, cost_total, cost_no_cache_input, agent_type)
            VALUES ('s.jsonl', 'e\(index)', '\(row.folder)', '\(row.model)', '\(row.provider)', 'api',
                \(Int64(row.at.timeIntervalSince1970 * 1000)), '\(row.stopReason)',
                \(row.tokens.input), \(row.tokens.output), \(row.tokens.cacheRead), \(row.tokens.cacheWrite), \(tokens), 0,
                \(row.costs.input), \(row.costs.output), \(row.costs.cacheRead), \(row.costs.cacheWrite), \(total),
                \(row.noCacheInput.map { "\($0)" } ?? "NULL"), '\(row.agent)')
            """
            try #require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        }
        return path
    }

    private static let rows: [Row] = [
        Row(at: local(30, 10, 15)),
        Row(at: local(30, 10, 45), stopReason: "error", noCacheInput: nil),
        Row(at: local(30, 11, 5), agent: "subagent"),
        Row(at: local(30, 12, 0), provider: "xai-oauth", model: "grok-5", costs: (0, 0, 0, 0), noCacheInput: nil),
        Row(at: local(29, 23, 59)),
    ]

    @Test func requestsAreSummedPerLocalHourModelAgentAndFolderSinceTheCutoff() throws {
        let path = try Self.makeDatabase(Self.rows)

        let groups = try OmpUsageStatistics.read(databasePath: path, since: Self.local(30, 0, 0), granularity: .hour, calendar: .current)
            .sorted { ($0.start, $0.model) < ($1.start, $1.model) }

        #expect(groups.map(\.start) == [Self.local(30, 10, 0), Self.local(30, 11, 0), Self.local(30, 12, 0)])
        let ten = try #require(groups.first)
        #expect(ten.totals.requests == 2)
        #expect(ten.totals.failedRequests == 1)
        #expect(ten.totals.inputTokens == 200)
        #expect(ten.totals.cacheReadTokens == 2000)
        #expect(ten.totals.cost == 1.875)
        // Only the request that reported its uncached price counts toward the savings.
        #expect(ten.totals.cachedPromptCost == 0.4375)
        #expect(ten.totals.uncachedPromptCost == 1)
        #expect(groups[1].agent == "subagent")
        #expect(groups[2].provider == "xai-oauth")
        #expect(groups[2].totals.unpricedRequests == 1)
        #expect(groups.allSatisfy { $0.folder == "-git-app" })
    }

    @Test func dailyGroupingMergesTheHoursOfALocalDay() throws {
        let path = try Self.makeDatabase(Self.rows)

        let groups = try OmpUsageStatistics.read(databasePath: path, since: nil, granularity: .day, calendar: .current)
        let opusMain = groups.filter { $0.model == "claude-opus-5-5" && $0.agent == "main" }
            .sorted { $0.start < $1.start }

        #expect(opusMain.map(\.start) == [Self.local(29, 0, 0), Self.local(30, 0, 0)])
        #expect(opusMain.map(\.totals.requests) == [1, 2])
    }

    @Test func noDatabaseYetIsNoHistory() throws {
        let path = EngineHarness.temporaryDirectory().appendingPathComponent("stats.db").path
        #expect(try OmpUsageStatistics.read(databasePath: path, since: nil, granularity: .day, calendar: .current).isEmpty)
    }

    @Test func aDatabaseWithoutOmpsTableIsAnError() throws {
        let path = EngineHarness.temporaryDirectory().appendingPathComponent("stats.db").path
        var handle: OpaquePointer?
        try #require(sqlite3_open(path, &handle) == SQLITE_OK)
        sqlite3_exec(handle, "CREATE TABLE other (id INTEGER)", nil, nil, nil)
        sqlite3_close(handle)

        #expect(throws: UsageStatisticsError.self) {
            try OmpUsageStatistics.read(databasePath: path, since: nil, granularity: .day, calendar: .current)
        }
    }

    /// When clocks go back, the repeated local hour is two real hours and two bars.
    @Test func theRepeatedHourOfAClockChangeStaysTwoHours() throws {
        let zone = TimeZone.current
        var probe = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01
        var fallBack: Date?
        while let next = zone.nextDaylightSavingTimeTransition(after: probe), next < Date(timeIntervalSince1970: 1_798_761_600) {
            if zone.secondsFromGMT(for: next) < zone.secondsFromGMT(for: next.addingTimeInterval(-1)) { fallBack = next; break }
            probe = next
        }
        guard let fallBack else { return } // No clock change in this time zone.
        let first = fallBack.addingTimeInterval(-1800)
        let second = fallBack.addingTimeInterval(1800)
        let path = try Self.makeDatabase([Row(at: first), Row(at: second)])

        let groups = try OmpUsageStatistics.read(databasePath: path, since: nil, granularity: .hour, calendar: .current)
            .sorted { $0.start < $1.start }

        #expect(groups.map(\.start) == [fallBack.addingTimeInterval(-3600), fallBack])
        #expect(groups.map(\.totals.requests) == [1, 1])
        let history = UsageHistory(period: .day, now: second.addingTimeInterval(60), groups: groups)
        #expect(history.summary().buckets.suffix(2).map(\.totals.requests) == [1, 1])
    }

    @Test func theDatabaseLivesInOmpsConfigRoot() {
        let home = "/Users/ada"
        #expect(OmpUsageStatistics.defaultDatabasePath(environment: [:], home: home) == "/Users/ada/.omp/stats.db")
        #expect(OmpUsageStatistics.defaultDatabasePath(environment: ["PI_CONFIG_DIR": ".omp-work"], home: home) == "/Users/ada/.omp-work/stats.db")
        // omp joins the setting onto home (`path.join`), absolute or not.
        #expect(OmpUsageStatistics.defaultDatabasePath(environment: ["PI_CONFIG_DIR": "/srv/omp"], home: home) == "/Users/ada/srv/omp/stats.db")
    }
}
