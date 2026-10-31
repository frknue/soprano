import AppKit
import Testing
@testable import SopranoAgentsCore

/// `OmpSubagentMapper` against a live omp 18.14 `--mode rpc-ui` trace
/// (`set_subagent_subscription {level:"events"}`, claude-haiku-5-5): the agent spawns a detached
/// `sonic` subagent "Reader" that runs `cat a.txt` and `cat b.txt`; it is steered mid-run
/// (`steer_subagent`), gets a background-job notice, answers, and completes.
struct OmpSubagentMapperTests {
    private static func trace() throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/omp-subagent.jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }
    }

    private static func replay() throws -> [(id: String, event: SubagentEvent)] {
        var mapper = OmpSubagentMapper(cwd: "/tmp/omp-sub")
        return try trace().flatMap { mapper.map($0) }.compactMap { event in
            guard case let .subagent(id, subagentEvent) = event else { return nil }
            return (id, subagentEvent)
        }
    }

    @Test func aSubagentRunIsReportedFromItsFirstMessageToItsEnd() throws {
        let events = try Self.replay()
        #expect(Set(events.map(\.id)) == ["Reader"])

        let lifecycle = events.compactMap { event -> String? in
            switch event.event {
            case let .runStarted(message): "run: \(message?.split(separator: "\n").first ?? "")"
            case let .message(text): "message: \(text)"
            case let .runEnded(outcome, error): "end: \(outcome.rawValue)\(error.map { " \($0)" } ?? "")"
            case let .updated(info) where info.status != nil && info.status != .running: "status: \(info.status!.rawValue)"
            default: nil
            }
        }
        #expect(lifecycle == [
            "run: Complete assignment thoroughly:",
            "message: Also say DONE at the end.",
            "end: completed",
            "status: completed",
        ])

        guard case let .updated(first)? = events.first?.event else {
            Issue.record("the first event is not the subagent's facts")
            return
        }
        #expect(first.agent == "sonic")
        #expect(first.status == .running)
        #expect(first.isDetached == true)
        #expect(first.parentToolCallID == "toolu_01SzsiW5tpzDJEPZUJdn5XeM")
        #expect(first.sessionFile?.hasSuffix("/Reader.jsonl") == true)

        let intents = events.compactMap { event -> String? in
            if case let .updated(info) = event.event { return info.lastIntent }
            return nil
        }
        #expect(intents.contains("Reading b.txt contents"))
    }

    @Test func itsToolsTextAndNoticesBecomeItemsOfTheRun() throws {
        var items: [String: TurnItem] = [:]
        var order: [String] = []
        var seen: Set<String> = []
        var texts: [String: String] = [:]
        for (_, event) in try Self.replay() {
            switch event {
            case let .itemUpdated(item):
                if seen.insert(item.id).inserted { order.append(item.id) }
                items[item.id] = item
            case let .assistantDelta(itemID, delta):
                if seen.insert(itemID).inserted { order.append(itemID) }
                texts[itemID, default: ""] += delta
            default:
                break
            }
        }
        let commands = order.compactMap { id -> String? in
            if case let .command(execution)? = items[id]?.kind { return "\(execution.command) → \(execution.output.prefix(5))" }
            return nil
        }
        #expect(commands == ["cat a.txt → alpha", "cat b.txt → beta\n"])
        #expect(order.allSatisfy { items[$0]?.status.isActive != true })

        let notices = order.compactMap { id -> String? in
            if case let .notice(text)? = items[id]?.kind { return text }
            return nil
        }
        #expect(notices == ["Background job bg_2 has completed. Resume your work using the result below."])

        let answers = order.compactMap { id -> String? in
            if case let .assistantMessage(text, _)? = items[id]?.kind { return text }
            return texts[id]
        }
        #expect(answers.contains { $0.hasSuffix("DONE") })
        // One item per assistant message: subagent events carry no messageId, so the mapper
        // numbers the messages; equal ids would merge the three answers.
        #expect(answers.count == 3)
        #expect(answers.last?.hasPrefix("Background job bg_2 finished") == true)
    }

    @Test func runningSubagentsAreAbortedWhenTheProcessGoesAway() throws {
        var mapper = OmpSubagentMapper()
        let started = try JSONValue.parse(#"{"type":"subagent_lifecycle","payload":{"id":"Lister","agent":"sonic","status":"started","index":0}}"#)
        let run = try JSONValue.parse(#"{"type":"subagent_event","payload":{"id":"Lister","event":{"type":"agent_start"}}}"#)
        _ = mapper.map(started)
        _ = mapper.map(run)
        #expect(mapper.runningIDs == ["Lister"])

        let events = mapper.abortAll()
        #expect(events == [
            .subagent(id: "Lister", .runEnded(outcome: .interrupted, error: nil)),
            .subagent(id: "Lister", .updated(SubagentInfo(status: .aborted))),
        ])
        #expect(mapper.runningIDs.isEmpty)
        #expect(mapper.abortAll().isEmpty)
    }
}
