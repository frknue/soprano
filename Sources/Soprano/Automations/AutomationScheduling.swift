import Foundation

/// When an automation is due, worked out from its schedule and the time its
/// next run was last set for. Kept free of timers and storage so the rules
/// read, and test, as plain values.
enum AutomationScheduling {
    enum Decision: Equatable {
        /// Start the run that was due at `scheduledFor`.
        case run(scheduledFor: Date)
        /// The run due at `scheduledFor` is past its grace period: record it
        /// as skipped instead of starting it hours late.
        case missed(scheduledFor: Date)
    }

    /// How far past its grace a check may land and still run: the scheduler
    /// looks every half minute, so a run due right at the edge is not lost.
    static let checkSlack: TimeInterval = 60

    static func signature(of automation: Automation) -> String {
        "\(automation.enabled ? "on" : "off") \(automation.schedule.expression)"
    }

    /// The state to keep after a check at `now`, and what to do. Only the
    /// latest due time runs: a Mac that slept through six hourly runs starts
    /// one, not six. A new, changed, or re-enabled schedule counts from `now`,
    /// so editing one never starts a run that was due before the edit.
    static func evaluate(
        _ automation: Automation,
        state: AutomationStore.ScheduleState?,
        now: Date,
        calendar: Calendar = .current
    ) -> (state: AutomationStore.ScheduleState, decision: Decision?) {
        let signature = signature(of: automation)
        func next() -> Date? {
            automation.enabled ? automation.schedule.nextOccurrence(after: now, calendar: calendar) : nil
        }
        guard let state, state.signature == signature else {
            return (.init(signature: signature, nextRunAt: next()), nil)
        }
        guard automation.enabled, let due = state.nextRunAt, due <= now else {
            return (state, nil)
        }
        let latest = automation.schedule.latestOccurrence(from: due, through: now, calendar: calendar) ?? due
        let lateness = now.timeIntervalSince(latest)
        let decision: Decision = lateness > TimeInterval(automation.graceMinutes * 60) + checkSlack
            ? .missed(scheduledFor: latest)
            : .run(scheduledFor: latest)
        return (.init(signature: signature, nextRunAt: next()), decision)
    }
}
