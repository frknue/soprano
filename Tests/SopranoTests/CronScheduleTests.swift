import AppKit
import Testing
@testable import Soprano

struct CronScheduleTests {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String, _ calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    @Test func aWeekdayScheduleDueOnFridayEveningNextRunsOnMondayMorning() throws {
        let calendar = berlin
        let schedule = try CronSchedule(parsing: "0 9 * * 1-5")

        // 2026-10-30 is a Friday.
        let next = schedule.nextOccurrence(after: date("2026-10-30 10:00", calendar), calendar: calendar)

        #expect(next == date("2026-11-02 09:00", calendar))
    }

    @Test func theNextOccurrenceIsStrictlyAfterTheTimeItIsAskedFrom() throws {
        let calendar = berlin
        let schedule = try CronSchedule(parsing: "30 * * * *")

        let next = schedule.nextOccurrence(after: date("2026-10-29 08:30", calendar), calendar: calendar)

        #expect(next == date("2026-10-29 09:30", calendar))
    }

    @Test func whenBothDayFieldsAreRestrictedEitherOneMatchingRuns() throws {
        let calendar = berlin
        // The 13th, or any Friday — cron's rule, not "Friday the 13th".
        let schedule = try CronSchedule(parsing: "0 12 13 * 5")

        // 2026-10-29 is a Thursday; Friday the 30th comes before November 13.
        let next = schedule.nextOccurrence(after: date("2026-10-29 13:00", calendar), calendar: calendar)

        #expect(next == date("2026-10-30 12:00", calendar))
    }

    @Test func stepsRangesListsAndNamesExpandToTheTimesTheyName() throws {
        let schedule = try CronSchedule(parsing: "*/15 9-11,14 * jan-mar MON-fri")

        #expect(schedule.minutes == [0, 15, 30, 45])
        #expect(schedule.hours == [9, 10, 11, 14])
        #expect(schedule.months == [1, 2, 3])
        #expect(schedule.weekdays == [1, 2, 3, 4, 5])
    }

    @Test func sevenAndZeroBothMeanSunday() throws {
        #expect(try CronSchedule(parsing: "0 9 * * 7").weekdays == [0])
        #expect(try CronSchedule(parsing: "0 9 * * 0").weekdays == [0])
    }

    @Test func aValueOutsideItsFieldIsRejectedWithTheFieldAndRangeNamed() {
        #expect(throws: CronSchedule.ParseError(message: "61 is outside the minute range 0–59.")) {
            try CronSchedule(parsing: "61 * * * *")
        }
    }

    @Test func anExpressionWithoutFiveFieldsIsRejected() {
        #expect(throws: CronSchedule.ParseError.self) {
            try CronSchedule(parsing: "0 9 * *")
        }
    }

    @Test func aDateThatNeverComesHasNoNextOccurrence() throws {
        let schedule = try CronSchedule(parsing: "0 0 31 2 *")

        #expect(schedule.nextOccurrence(after: Date()) == nil)
    }

    @Test func aTimeTheClocksSkipIsNotRunThatDay() throws {
        let calendar = berlin
        let schedule = try CronSchedule(parsing: "30 2 * * *")

        // Clocks in Berlin jump from 02:00 to 03:00 on 2026-03-29.
        let next = schedule.nextOccurrence(after: date("2026-03-28 03:00", calendar), calendar: calendar)

        #expect(next == date("2026-03-30 02:30", calendar))
    }

    @Test func theLatestOccurrenceOfASpanIsTheLastOneNotAfterItsEnd() throws {
        let calendar = berlin
        let schedule = try CronSchedule(parsing: "15 * * * *")

        let latest = schedule.latestOccurrence(
            from: date("2026-10-29 01:15", calendar),
            through: date("2026-10-29 07:40", calendar),
            calendar: calendar
        )

        #expect(latest == date("2026-10-29 07:15", calendar))
    }

    @Test func theEditorsPresetsAreRecognizedFromTheirCronAndWrittenBackTheSame() throws {
        let presets: [AutomationCadence] = [
            .hourly(minute: 15),
            .daily(hour: 16, minute: 30),
            .weekdays(hour: 9, minute: 0),
            .weekly(weekday: 4, hour: 14, minute: 0),
        ]
        for preset in presets {
            let schedule = try CronSchedule(parsing: preset.expression)
            #expect(AutomationCadence(schedule) == preset)
        }
    }

    @Test func aScheduleNoPresetDescribesStaysCustom() throws {
        let schedule = try CronSchedule(parsing: "0 9,17 * * 1-5")

        #expect(AutomationCadence(schedule) == .custom("0 9,17 * * 1-5"))
    }

    @Test func presetsSummarizeTheWayTheEditorNamesThem() {
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: "UTC")!

        #expect(AutomationCadence.hourly(minute: 5).summary(locale: locale, calendar: calendar) == "Hourly at :05")
        #expect(
            AutomationCadence.weekly(weekday: 4, hour: 14, minute: 0).summary(locale: locale, calendar: calendar)
                .hasPrefix("Thursdays at 2:00")
        )
    }
}
