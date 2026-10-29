import AppKit
import Testing
@testable import Soprano

@MainActor
struct AutomationStoreTests {
    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-automation-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("automations.json")
    }

    private func run(_ number: Int, status: AutomationRun.Status, automationId: String = "audit") -> AutomationRun {
        AutomationRun(
            id: UUID().uuidString,
            automationId: automationId,
            number: number,
            trigger: .scheduled,
            startedAt: Date(timeIntervalSince1970: TimeInterval(number * 60)),
            status: status,
            profileId: "omp",
            folder: "/tmp"
        )
    }

    @Test func runsAndScheduleTimesSurviveAReopenedStore() {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let next = Date(timeIntervalSince1970: 1_800_000_000)

        let store = AutomationStore(fileURL: url)
        store.insert(run(1, status: .completed))
        store.setSchedule(.init(signature: "on 0 9 * * *", nextRunAt: next), for: "audit")

        let reopened = AutomationStore(fileURL: url)
        #expect(reopened.runs(for: "audit").map(\.number) == [1])
        #expect(reopened.schedules["audit"]?.nextRunAt == next)
        #expect(reopened.nextRunNumber(for: "audit") == 2)
    }

    @Test func onlyTheNewestHundredFinishedRunsAreKeptButUnfinishedOnesAlwaysStay() {
        let store = AutomationStore(fileURL: nil)
        store.insert(run(1, status: .running))
        for number in 2...(AutomationStore.finishedRunLimit + 6) {
            store.insert(run(number, status: .completed))
        }
        store.insert(run(500, status: .completed, automationId: "other"))

        let audit = store.runs(for: "audit")
        #expect(audit.filter(\.status.isFinal).count == AutomationStore.finishedRunLimit)
        #expect(audit.contains { $0.number == 1 })
        #expect(!audit.contains { $0.number == 2 })
        #expect(audit.first?.number == AutomationStore.finishedRunLimit + 6)
        #expect(store.runs(for: "other").count == 1)
    }

    @Test func deletingAnAutomationForgetsItsRunsAndScheduleOnly() {
        let store = AutomationStore(fileURL: nil)
        store.insert(run(1, status: .completed))
        store.insert(run(1, status: .completed, automationId: "other"))
        store.setSchedule(.init(signature: "on 0 9 * * *", nextRunAt: Date()), for: "audit")

        store.removeAll(for: "audit")

        #expect(store.runs(for: "audit").isEmpty)
        #expect(store.schedules["audit"] == nil)
        #expect(store.runs(for: "other").count == 1)
    }
}
