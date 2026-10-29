import Foundation

/// A five-field cron expression — minute, hour, day of month, month, day of
/// week — evaluated in the Mac's own time zone.
///
/// Fields take `*`, numbers, `a-b` ranges, `,` lists, and `/n` steps. Day of
/// week runs 0–7, where both 0 and 7 are Sunday, and months and weekdays also
/// take their three-letter English names (`jan`, `mon`). As in cron, when both
/// day fields are restricted a day matching either one runs.
struct CronSchedule: Equatable, Sendable {
    struct ParseError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The expression as written, whitespace collapsed.
    let expression: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    /// 0 = Sunday … 6 = Saturday.
    let weekdays: Set<Int>
    let restrictsDayOfMonth: Bool
    let restrictsWeekday: Bool

    private struct Field {
        let name: String
        let range: ClosedRange<Int>
        var names: [String: Int] = [:]
    }

    private static let fields = [
        Field(name: "minute", range: 0...59),
        Field(name: "hour", range: 0...23),
        Field(name: "day of month", range: 1...31),
        Field(
            name: "month",
            range: 1...12,
            names: Dictionary(uniqueKeysWithValues: [
                "jan", "feb", "mar", "apr", "may", "jun",
                "jul", "aug", "sep", "oct", "nov", "dec",
            ].enumerated().map { ($1, $0 + 1) })
        ),
        Field(
            name: "day of week",
            range: 0...7,
            names: Dictionary(uniqueKeysWithValues: [
                "sun", "mon", "tue", "wed", "thu", "fri", "sat",
            ].enumerated().map { ($1, $0) })
        ),
    ]

    init(parsing text: String) throws {
        let parts = text.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        guard parts.count == 5 else {
            throw ParseError(message: "A schedule has five fields: minute, hour, day of month, month, day of week.")
        }
        var sets: [Set<Int>] = []
        for (part, field) in zip(parts, Self.fields) {
            sets.append(try Self.values(of: part, field: field))
        }
        expression = parts.joined(separator: " ")
        minutes = sets[0]
        hours = sets[1]
        daysOfMonth = sets[2]
        months = sets[3]
        weekdays = Set(sets[4].map { $0 % 7 })
        restrictsDayOfMonth = !parts[2].hasPrefix("*")
        restrictsWeekday = !parts[4].hasPrefix("*")
    }

    init?(_ text: String) {
        guard let schedule = try? CronSchedule(parsing: text) else { return nil }
        self = schedule
    }

    private static func values(of part: String, field: Field) throws -> Set<Int> {
        var result = Set<Int>()
        for item in part.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !item.isEmpty else {
                throw ParseError(message: "The \(field.name) field has an empty list item.")
            }
            let pieces = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard pieces.count <= 2 else {
                throw ParseError(message: "The \(field.name) field has more than one step in \"\(item)\".")
            }
            var step = 1
            if pieces.count == 2 {
                guard let value = Int(pieces[1]), value > 0 else {
                    throw ParseError(message: "The \(field.name) step in \"\(item)\" must be a positive number.")
                }
                step = value
            }
            let bounds: ClosedRange<Int>
            if pieces[0] == "*" {
                bounds = field.range
            } else {
                let ends = pieces[0].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                guard ends.count <= 2 else {
                    throw ParseError(message: "The \(field.name) field has a malformed range \"\(item)\".")
                }
                let low = try value(ends[0], field: field)
                let high = ends.count == 2 ? try value(ends[1], field: field) : (pieces.count == 2 ? field.range.upperBound : low)
                guard low <= high else {
                    throw ParseError(message: "The \(field.name) range \"\(pieces[0])\" runs backwards.")
                }
                bounds = low...high
            }
            result.formUnion(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
        }
        return result
    }

    private static func value(_ text: String, field: Field) throws -> Int {
        if let number = Int(text) {
            guard field.range.contains(number) else {
                throw ParseError(
                    message: "\(number) is outside the \(field.name) range \(field.range.lowerBound)–\(field.range.upperBound)."
                )
            }
            return number
        }
        if let named = field.names[text] { return named }
        throw ParseError(message: "\"\(text)\" is not a valid \(field.name).")
    }

    // MARK: - Occurrences

    /// Whether the schedule runs on the day `components` names.
    private func runs(onDay day: Int, weekday: Int) -> Bool {
        let dayMatches = daysOfMonth.contains(day)
        let weekdayMatches = weekdays.contains(weekday)
        switch (restrictsDayOfMonth, restrictsWeekday) {
        case (true, true): return dayMatches || weekdayMatches
        case (true, false): return dayMatches
        case (false, true): return weekdayMatches
        case (false, false): return true
        }
    }

    /// The first minute strictly after `date` the schedule runs at. Searches
    /// up to eight years ahead, far enough for any February 29th; nil means
    /// the expression names a date that never comes, such as `0 0 31 2 *`.
    func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        guard let startMinute = calendar.dateInterval(of: .minute, for: date)?.start,
              let first = calendar.date(byAdding: .minute, value: 1, to: startMinute)
        else { return nil }
        let sortedHours = hours.sorted()
        let sortedMinutes = minutes.sorted()
        var day = calendar.startOfDay(for: first)
        for _ in 0..<(366 * 8) {
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday,
               months.contains(month), runs(onDay: dayOfMonth, weekday: weekday - 1) {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        var wanted = parts
                        wanted.weekday = nil
                        wanted.hour = hour
                        wanted.minute = minute
                        wanted.second = 0
                        guard let candidate = calendar.date(from: wanted), candidate >= first else { continue }
                        // A time the clocks skip (a spring-forward gap) resolves
                        // to another hour; that minute does not exist that day.
                        let landed = calendar.dateComponents([.hour, .minute], from: candidate)
                        guard landed.hour == hour, landed.minute == minute else { continue }
                        return candidate
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// The latest occurrence in `start...end`, where `start` is itself an
    /// occurrence (the run that was due), or nil when `start` is after `end`.
    func latestOccurrence(from start: Date, through end: Date, calendar: Calendar = .current) -> Date? {
        guard start <= end else { return nil }
        var latest = start
        while let next = nextOccurrence(after: latest, calendar: calendar), next <= end {
            latest = next
        }
        return latest
    }
}

/// The schedules the editor offers by name; anything else is custom cron.
enum AutomationCadence: Equatable, Sendable {
    case hourly(minute: Int)
    case daily(hour: Int, minute: Int)
    case weekdays(hour: Int, minute: Int)
    /// 0 = Sunday … 6 = Saturday.
    case weekly(weekday: Int, hour: Int, minute: Int)
    case custom(String)

    init(_ schedule: CronSchedule) {
        let everyDay = !schedule.restrictsDayOfMonth && schedule.months.count == 12
        guard everyDay, schedule.minutes.count == 1, let minute = schedule.minutes.first else {
            self = .custom(schedule.expression)
            return
        }
        if schedule.hours.count == 24, !schedule.restrictsWeekday {
            self = .hourly(minute: minute)
            return
        }
        guard schedule.hours.count == 1, let hour = schedule.hours.first else {
            self = .custom(schedule.expression)
            return
        }
        if !schedule.restrictsWeekday || schedule.weekdays.count == 7 {
            self = .daily(hour: hour, minute: minute)
        } else if schedule.weekdays == Set(1...5) {
            self = .weekdays(hour: hour, minute: minute)
        } else if schedule.weekdays.count == 1, let weekday = schedule.weekdays.first {
            self = .weekly(weekday: weekday, hour: hour, minute: minute)
        } else {
            self = .custom(schedule.expression)
        }
    }

    var expression: String {
        switch self {
        case .hourly(let minute): "\(minute) * * * *"
        case .daily(let hour, let minute): "\(minute) \(hour) * * *"
        case .weekdays(let hour, let minute): "\(minute) \(hour) * * 1-5"
        case .weekly(let weekday, let hour, let minute): "\(minute) \(hour) * * \(weekday)"
        case .custom(let expression): expression
        }
    }

    /// "Weekdays at 9:00 AM", "Hourly at :15", "Thursdays at 2:00 PM".
    func summary(locale: Locale = .current, calendar: Calendar = .current) -> String {
        switch self {
        case .hourly(let minute):
            return String(format: "Hourly at :%02d", minute)
        case .daily(let hour, let minute):
            return "Daily at \(Self.time(hour: hour, minute: minute, locale: locale, calendar: calendar))"
        case .weekdays(let hour, let minute):
            return "Weekdays at \(Self.time(hour: hour, minute: minute, locale: locale, calendar: calendar))"
        case .weekly(let weekday, let hour, let minute):
            var symbols = calendar
            symbols.locale = locale
            let name = symbols.weekdaySymbols[weekday % 7]
            return "\(name)s at \(Self.time(hour: hour, minute: minute, locale: locale, calendar: calendar))"
        case .custom(let expression):
            return expression
        }
    }

    static func time(hour: Int, minute: Int, locale: Locale = .current, calendar: Calendar = .current) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        guard let date = calendar.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        return formatter.string(from: date)
    }
}
