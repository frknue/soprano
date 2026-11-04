import AppKit
import Testing
@testable import SopranoAgentsCore

struct UsageSummaryTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func group(
        _ start: Date,
        model: String = "claude-opus-5-5",
        provider: String = "anthropic",
        agent: String = "main",
        folder: String = "-git-app",
        requests: Int = 1,
        cost: Double = 1
    ) -> UsageGroup {
        UsageGroup(start: start, provider: provider, model: model, agent: agent, folder: folder, totals: UsageTotals(
            requests: requests,
            inputTokens: 10,
            outputTokens: 20,
            cacheReadTokens: 60,
            cacheWriteTokens: 10,
            inputCost: cost * 0.125,
            outputCost: cost * 0.5,
            cacheReadCost: cost * 0.25,
            cacheWriteCost: cost * 0.125
        ))
    }

    @Test func the24HourPeriodIsTheLast24HoursInHourlyBars() {
        let now = Self.date(2026, 10, 31, 14, 25)
        let buckets = UsagePeriod.day.buckets(now: now, earliest: nil, calendar: Self.calendar)

        #expect(UsagePeriod.day.start(now: now, calendar: Self.calendar) == Self.date(2026, 10, 30, 14, 25))
        #expect(buckets.unit == .hour)
        #expect(buckets.starts.count == 25)
        #expect(buckets.starts.first == Self.date(2026, 10, 30, 14))
        #expect(buckets.starts.last == Self.date(2026, 10, 31, 14))
    }

    @Test func dayPeriodsEndTodayAndCountWholeLocalDays() {
        let now = Self.date(2026, 10, 31, 9)
        for (period, days) in [(UsagePeriod.week, 7), (.month, 30), (.quarter, 90)] {
            let buckets = period.buckets(now: now, earliest: nil, calendar: Self.calendar)
            #expect(buckets.unit == .day)
            #expect(buckets.starts.count == days, "\(period)")
            #expect(buckets.starts.last == Self.date(2026, 10, 31))
        }
        // Across the DST change (Oct 25 in Berlin) days stay calendar days.
        let week = UsagePeriod.week.buckets(now: now, earliest: nil, calendar: Self.calendar).starts
        #expect(week.first == Self.date(2026, 10, 25))
    }

    @Test func allIsWeeklyFromTheFirstRequestAndMonthlyBeyondHalfAYear() {
        let now = Self.date(2026, 10, 31, 12)
        let weekly = UsagePeriod.all.buckets(now: now, earliest: Self.date(2026, 9, 23, 18), calendar: Self.calendar)
        #expect(weekly.unit == .week)
        #expect(weekly.starts.first == Self.date(2026, 9, 21))
        #expect(weekly.starts.last == Self.date(2026, 10, 26))

        let monthly = UsagePeriod.all.buckets(now: now, earliest: Self.date(2025, 12, 3), calendar: Self.calendar)
        #expect(monthly.unit == .month)
        #expect(monthly.starts.first == Self.date(2025, 12, 1))
        #expect(monthly.starts.count == 11)

        let empty = UsagePeriod.all.buckets(now: now, earliest: nil, calendar: Self.calendar)
        #expect(empty.starts == [Self.date(2026, 10, 26)])
    }

    @Test func groupsLandInTheBucketThatContainsThem() {
        let now = Self.date(2026, 10, 31, 12)
        let history = UsageHistory(period: .all, now: now, groups: [
            Self.group(Self.date(2026, 10, 20, 9), cost: 1),
            Self.group(Self.date(2026, 10, 25, 23), cost: 2),
            Self.group(Self.date(2026, 10, 26, 0), cost: 4),
            Self.group(Self.date(2026, 10, 31, 11), cost: 8),
        ], calendar: Self.calendar)

        let summary = history.summary()

        #expect(summary.buckets.map(\.start) == [Self.date(2026, 10, 19), Self.date(2026, 10, 26)])
        #expect(summary.buckets.map(\.totals.cost) == [3, 12])
        #expect(summary.totals.cost == 15)
        #expect(summary.totals.requests == 4)
    }

    @Test func aModelFilterNarrowsEverythingButTheModelList() {
        let now = Self.date(2026, 10, 31, 12)
        let start = Self.date(2026, 10, 31, 9)
        let history = UsageHistory(period: .week, now: now, groups: [
            Self.group(start, agent: "main", folder: "-git-app", cost: 5),
            Self.group(start, agent: "subagent", folder: "-git-site", cost: 3),
            Self.group(start, model: "gpt-6.1-sol", provider: "openai-codex", agent: "main", folder: "-git-site", cost: 1),
        ], calendar: Self.calendar)
        let sol = UsageModelKey(provider: "openai-codex", model: "gpt-6.1-sol")

        let all = history.summary()
        let filtered = history.summary(model: sol)

        #expect(all.models.map(\.key.model) == ["claude-opus-5-5", "gpt-6.1-sol"])
        #expect(all.models.map(\.totals.cost) == [8, 1])
        #expect(filtered.models.map(\.key.model) == ["claude-opus-5-5", "gpt-6.1-sol"])
        #expect(filtered.totals.cost == 1)
        #expect(filtered.buckets.last?.totals.cost == 1)
        #expect(filtered.folders.map(\.key) == ["-git-site"])
        #expect(filtered.agents.map(\.key) == ["main"])
        #expect(all.folders.map(\.key) == ["-git-app", "-git-site"])
        #expect(all.agents.map(\.totals.cost) == [6, 3])
    }

    @Test func cacheSavingsAndHitRateComeFromThePromptCosts() {
        let totals = UsageTotals(
            inputTokens: 100,
            cacheReadTokens: 800,
            cacheWriteTokens: 100,
            inputCost: 0.5,
            cacheReadCost: 0.4,
            cacheWriteCost: 0.6,
            cachedPromptCost: 1.5,
            uncachedPromptCost: 5
        )
        #expect(totals.cacheSavings == 3.5)
        #expect(totals.cacheHitRate == 0.8)
        #expect(UsageTotals(cachedPromptCost: 2, uncachedPromptCost: 1).cacheSavings == 0)
        #expect(UsageTotals(outputTokens: 10).cacheHitRate == nil)
    }

    /// omp's stats keep the session folder name with every `--` turned into `/` (and a leading
    /// `--` into `/`): `--private-tmp--` is stored as `/private-tmp/`.
    @Test func folderNamesFollowOmpsStatsFolders() throws {
        let home = "/Users/ada"
        let temporary = "/var/tmp-sandbox"
        #expect(UsageFolderName.encode("/Users/ada/git/private/soprano-agents", home: home, temporaryDirectory: temporary) == "-git-private-soprano-agents")
        #expect(UsageFolderName.encode("/Users/ada", home: home, temporaryDirectory: temporary) == "-")
        #expect(UsageFolderName.encode("/opt/work/app", home: home, temporaryDirectory: temporary) == "/opt-work-app/")
        #expect(UsageFolderName.encode("/var/tmp-sandbox/scratch/x", home: home, temporaryDirectory: temporary) == "-tmp-scratch-x")
        #expect(UsageFolderName.encode("/Users/adam/app", home: home, temporaryDirectory: temporary) == "/Users-adam-app/")
        #expect(UsageFolderName.encode("/Users/ada/a-/b", home: home, temporaryDirectory: temporary) == "-a/b")
        // Symlinks resolve as Node's realpath does: /tmp is /private/tmp on macOS.
        let directory = "/tmp/soprano-usage-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        #expect(UsageFolderName.encode(directory, home: home, temporaryDirectory: temporary) == "/private-tmp-\(directory.dropFirst(5))/")
        #expect(UsageFolderName.fallbackTitle("-git-app") == "git-app")
        #expect(UsageFolderName.fallbackTitle("/private-tmp/") == "private-tmp")
        #expect(UsageFolderName.fallbackTitle("-") == "~")
    }
}
