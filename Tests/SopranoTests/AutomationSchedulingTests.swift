import AppKit
import Testing
@testable import Soprano

struct AutomationSchedulingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func automation(schedule: String = "0 9 * * *", enabled: Bool = true, graceMinutes: Int = 60) -> Automation {
        Automation(
            id: "audit",
            name: "Audit",
            agentId: "omp",
            folder: "/tmp",
            prompt: "Audit the repository.",
            schedule: try! CronSchedule(parsing: schedule),
            enabled: enabled,
            workspace: .folder,
            session: .fresh,
            graceMinutes: graceMinutes,
            precheck: nil,
            precheckTimeoutSeconds: 60,
            model: nil
        )
    }

    private func state(for automation: Automation, nextRunAt: Date?) -> AutomationStore.ScheduleState {
        .init(signature: AutomationScheduling.signature(of: automation), nextRunAt: nextRunAt)
    }

    @Test func aNewAutomationWaitsForItsNextTimeInsteadOfRunningOneThatAlreadyPassed() {
        let audit = automation()

        let (state, decision) = AutomationScheduling.evaluate(
            audit, state: nil, now: date("2026-10-29 09:30"), calendar: calendar
        )

        #expect(decision == nil)
        #expect(state.nextRunAt == date("2026-10-30 09:00"))
    }

    @Test func aRunThatCameDueStartsAndTheNextOneIsSetFromNow() {
        let audit = automation()

        let (state, decision) = AutomationScheduling.evaluate(
            audit,
            state: state(for: audit, nextRunAt: date("2026-10-29 09:00")),
            now: date("2026-10-29 09:00"),
            calendar: calendar
        )

        #expect(decision == .run(scheduledFor: date("2026-10-29 09:00")))
        #expect(state.nextRunAt == date("2026-10-30 09:00"))
    }

    @Test func aMacThatSleptThroughSeveralRunsStartsOnlyTheLatest() {
        let hourly = automation(schedule: "0 * * * *", graceMinutes: 30)

        let (state, decision) = AutomationScheduling.evaluate(
            hourly,
            state: state(for: hourly, nextRunAt: date("2026-10-29 02:00")),
            now: date("2026-10-29 07:10"),
            calendar: calendar
        )

        #expect(decision == .run(scheduledFor: date("2026-10-29 07:00")))
        #expect(state.nextRunAt == date("2026-10-29 08:00"))
    }

    @Test func aRunPastItsGracePeriodIsRecordedAsMissedInsteadOfStartingLate() {
        let audit = automation(graceMinutes: 60)

        let (state, decision) = AutomationScheduling.evaluate(
            audit,
            state: state(for: audit, nextRunAt: date("2026-10-29 09:00")),
            now: date("2026-10-29 11:00"),
            calendar: calendar
        )

        #expect(decision == .missed(scheduledFor: date("2026-10-29 09:00")))
        #expect(state.nextRunAt == date("2026-10-30 09:00"))
    }

    @Test func aRunWithoutGraceStillStartsWhenTheCheckLandsWithinAMinuteOfIt() {
        let audit = automation(graceMinutes: 0)

        let (_, decision) = AutomationScheduling.evaluate(
            audit,
            state: state(for: audit, nextRunAt: date("2026-10-29 09:00")),
            now: date("2026-10-29 09:00").addingTimeInterval(45),
            calendar: calendar
        )

        #expect(decision == .run(scheduledFor: date("2026-10-29 09:00")))
    }

    @Test func aPausedAutomationHasNoNextRunAndStartsNothing() {
        let running = automation()
        let paused = automation(enabled: false)

        let (state, decision) = AutomationScheduling.evaluate(
            paused,
            state: state(for: running, nextRunAt: date("2026-10-29 09:00")),
            now: date("2026-10-29 09:05"),
            calendar: calendar
        )

        #expect(decision == nil)
        #expect(state.nextRunAt == nil)
    }

    @Test func resumingAPausedAutomationCountsFromNowRatherThanCatchingUp() {
        let paused = automation(enabled: false)
        let resumed = automation(enabled: true)

        let (state, decision) = AutomationScheduling.evaluate(
            resumed,
            state: state(for: paused, nextRunAt: nil),
            now: date("2026-10-29 09:05"),
            calendar: calendar
        )

        #expect(decision == nil)
        #expect(state.nextRunAt == date("2026-10-30 09:00"))
    }

    @Test func editingTheScheduleRecomputesTheNextRunWithoutStartingOne() {
        let old = automation(schedule: "0 9 * * *")
        let edited = automation(schedule: "30 18 * * *")

        let (state, decision) = AutomationScheduling.evaluate(
            edited,
            state: state(for: old, nextRunAt: date("2026-10-29 09:00")),
            now: date("2026-10-29 10:00"),
            calendar: calendar
        )

        #expect(decision == nil)
        #expect(state.nextRunAt == date("2026-10-29 18:30"))
    }
}
