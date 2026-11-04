import AppKit
import Testing
@testable import Soprano

struct TimelineFormatTests {
    @Test func dayAwareTimestampsNameYesterdayAndOlderDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 15)))
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 9, minute: 5)))
        let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 9, minute: 5)))
        let older = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 9, minute: 5)))
        func format(_ date: Date) -> String {
            TimelineFormat.timestamp(date, now: now, calendar: calendar, locale: locale)
        }
        #expect(format(today).hasPrefix("9:05"))
        #expect(!format(today).contains("yesterday"))
        #expect(format(yesterday).hasPrefix("yesterday at "))
        #expect(format(older).hasPrefix("3/2"))
    }
}
