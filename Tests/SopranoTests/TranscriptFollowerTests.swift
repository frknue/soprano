import AppKit
import Testing
@testable import Soprano

struct TranscriptFollowerTests {
    @Test func aTranscriptReadFromItsTailStillKnowsTheSessionDirectoryFromItsHeader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-follower-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")

        let filler = #"{"type":"title","title":""# + String(repeating: "x", count: 1_000) + #""}"#
        var lines = [#"{"type":"session","version":3,"id":"sess-1","timestamp":"2026-10-12T09:00:00.000Z","cwd":"/work/repo"}"#]
        lines += Array(repeating: filler, count: Int(TranscriptFollower.initialWindow / 1_000) + 100)
        lines += [
            #"{"type":"message","id":"u1","parentId":null,"timestamp":"2026-10-12T09:00:01.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"Read it"}]}}"#,
            #"{"type":"message","id":"u2","parentId":"u1","timestamp":"2026-10-12T09:00:02.000Z","message":{"role":"user","attribution":"user","content":[{"type":"text","text":"Again"}]}}"#,
            #"{"type":"message","id":"a1","parentId":"u2","timestamp":"2026-10-12T09:00:03.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-r","name":"read","arguments":{"path":"/work/repo/Sources/App.swift"}}]}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let source = try #require(AgentTranscriptSource(
            profileId: "omp",
            conversation: AgentConversation(id: "sess-1", transcriptPath: file.path)
        ))
        let timeline = try #require(source.makeReader(home: directory).readAppended())

        #expect(timeline.items.last?.toolCall?.summary == "Sources/App.swift")
    }
}
