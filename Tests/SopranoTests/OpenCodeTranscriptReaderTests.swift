import AppKit
import SQLite3
import Testing
@testable import Soprano

struct OpenCodeTranscriptReaderTests {
    private static let sessionId = "ses_test1"

    /// The columns of OpenCode 2.x's tables the reader uses.
    private static let currentSchema = """
        CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT NOT NULL, revert TEXT, time_updated INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE session_message (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL, seq INTEGER NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
        CREATE TABLE session_part (
            message_id TEXT NOT NULL, session_id TEXT NOT NULL, ordinal INTEGER NOT NULL, type TEXT NOT NULL,
            call_id TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL,
            PRIMARY KEY (message_id, ordinal)
        );
        """

    /// The columns of OpenCode 1.x's tables the reader uses.
    private static let legacySchema = """
        CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL, revert TEXT);
        CREATE TABLE message (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        CREATE TABLE part (
            id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
            time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
        );
        """

    @Test func aStreamingAssistantMessageUpdatesItsItemsInPlace() throws {
        let fixture = try Fixture()
        try fixture.exec("""
            \(Self.currentSchema)
            INSERT INTO session_v2 (id, directory) VALUES ('\(Self.sessionId)', '/work/repo');
            \(message("msg_1", seq: 1, type: "user", updated: 100, data: #"{"text":"Run the tests","time":{"created":100}}"#))
            \(message("msg_2", seq: 2, type: "assistant", updated: 101, data: #"{"time":{"created":101},"content":[{"type":"tool","id":"call_1","name":"shell","state":{"status":"running","input":{"command":"swift test"},"metadata":{}},"time":{"created":101}}]}"#))
            """)
        let reader = fixture.reader()

        let first = try #require(reader.readAppended())
        #expect(first.items.map(\.id) == ["msg_1", "call_1"])
        #expect(first.items.last?.toolCall?.state == .running)

        try fixture.exec("""
            UPDATE session_message SET time_updated = 105, data = '{"time":{"created":101},"content":[{"type":"tool","id":"call_1","name":"shell","state":{"status":"completed","input":{"command":"swift test"},"content":[{"type":"text","text":"All passed"}],"metadata":{"exit":0}},"time":{"created":101,"completed":105}},{"type":"text","text":"Green."}]}'
            WHERE id = 'msg_2';
            """)
        let second = try #require(reader.readAppended())
        #expect(second.items.map(\.id) == ["msg_1", "call_1", "msg_2#1"])
        #expect(second.items[1].toolCall?.state == .succeeded)
        #expect(second.items[1].toolCall?.output == "All passed")
        #expect(second.items[2].kind == .reply("Green."))
    }

    @Test func aRewriteInTheSameMillisecondAsTheLastReadStillShows() throws {
        let fixture = try Fixture()
        try fixture.exec("""
            \(Self.currentSchema)
            INSERT INTO session_v2 (id, directory) VALUES ('\(Self.sessionId)', '/work/repo');
            \(message("msg_1", seq: 1, type: "assistant", updated: 100, data: #"{"time":{"created":100},"content":[{"type":"text","text":"Half a"}]}"#))
            """)
        let reader = fixture.reader()
        #expect(reader.readAppended()?.items.map(\.kind) == [.reply("Half a")])

        try fixture.exec(#"UPDATE session_message SET data = '{"time":{"created":100},"content":[{"type":"text","text":"Half a reply."}]}' WHERE id = 'msg_1';"#)
        #expect(reader.readAppended()?.items.map(\.kind) == [.reply("Half a reply.")])
    }

    @Test func anUnchangedDatabaseReadsAsNothingNew() throws {
        let fixture = try Fixture()
        try fixture.exec("""
            \(Self.currentSchema)
            INSERT INTO session_v2 (id, directory) VALUES ('\(Self.sessionId)', '/work/repo');
            \(message("msg_1", seq: 1, type: "user", updated: 100, data: #"{"text":"Hello","time":{"created":100}}"#))
            """)
        let reader = fixture.reader()
        #expect(reader.readAppended()?.items.map(\.kind) == [.prompt("Hello")])
        #expect(reader.readAppended() == nil)

        try fixture.exec(message("msg_2", seq: 3, type: "user", updated: 200, data: #"{"text":"Again","time":{"created":200}}"#))
        #expect(reader.readAppended()?.items.map(\.kind) == [.prompt("Hello"), .prompt("Again")])
        #expect(reader.readAppended() == nil)
    }

    @Test func rewindingHidesTheMessageItReturnedToAndEverythingAfter() throws {
        let fixture = try Fixture()
        try fixture.exec("""
            \(Self.currentSchema)
            INSERT INTO session_v2 (id, directory) VALUES ('\(Self.sessionId)', '/work/repo');
            \(message("msg_1", seq: 1, type: "user", updated: 100, data: #"{"text":"Plan it","time":{"created":100}}"#))
            \(message("msg_2", seq: 2, type: "assistant", updated: 101, data: #"{"time":{"created":101},"content":[{"type":"text","text":"Here is a plan."}]}"#))
            \(message("msg_3", seq: 4, type: "user", updated: 102, data: #"{"text":"Old direction","time":{"created":102}}"#))
            \(message("msg_4", seq: 5, type: "assistant", updated: 103, data: #"{"time":{"created":103},"content":[{"type":"text","text":"Going the old way."}]}"#))
            """)
        let reader = fixture.reader()
        #expect(reader.readAppended()?.items.count == 4)

        try fixture.exec(#"UPDATE session_v2 SET revert = '{"messageID":"msg_3"}' WHERE id = '\#(Self.sessionId)';"#)
        #expect(reader.readAppended()?.items.map(\.kind) == [.prompt("Plan it"), .reply("Here is a plan.")])

        // Committing the rewind deletes the hidden rows and clears it.
        try fixture.exec("""
            DELETE FROM session_message WHERE seq >= 4;
            UPDATE session_v2 SET revert = NULL WHERE id = '\(Self.sessionId)';
            \(message("msg_5", seq: 6, type: "user", updated: 300, data: #"{"text":"New direction","time":{"created":300}}"#))
            """)
        #expect(reader.readAppended()?.items.map(\.kind) == [
            .prompt("Plan it"), .reply("Here is a plan."), .prompt("New direction"),
        ])
    }

    @Test func partRowsOverrideAnAssistantMessagesInlineContentAndTheirUpdatesShow() throws {
        let fixture = try Fixture()
        try fixture.exec("""
            \(Self.currentSchema)
            INSERT INTO session_v2 (id, directory) VALUES ('\(Self.sessionId)', '/work/repo');
            \(message("msg_1", seq: 1, type: "assistant", updated: 100, data: #"{"time":{"created":100},"content":[]}"#))
            INSERT INTO session_part VALUES ('msg_1', '\(Self.sessionId)', 0, 'reasoning', NULL, 100, 100, '{"text":"Plan first."}');
            INSERT INTO session_part VALUES ('msg_1', '\(Self.sessionId)', 1, 'tool', 'call_1', 100, 100, '{"id":"call_1","name":"read","state":{"status":"running","input":{"path":"/work/repo/App.swift"},"metadata":{}},"time":{"created":100}}');
            """)
        let reader = fixture.reader()
        let first = try #require(reader.readAppended())
        #expect(first.items.map(\.kind) == [.thinking("Plan first."), .tool(AgentToolCall(name: "Read", summary: "App.swift"))])

        // Only the part changes; its message row keeps its old time.
        try fixture.exec("""
            UPDATE session_part SET time_updated = 150, data = '{"id":"call_1","name":"read","state":{"status":"completed","input":{"path":"/work/repo/App.swift"},"content":[{"type":"text","text":"1: import AppKit"}]},"time":{"created":100,"completed":150}}'
            WHERE message_id = 'msg_1' AND ordinal = 1;
            """)
        let second = try #require(reader.readAppended())
        #expect(second.items.last?.toolCall?.state == .succeeded)
        #expect(second.items.last?.toolCall?.output == "1: import AppKit")
    }

    @Test func theDatabaseIsFoundInOpenCodesDataDirectoryWhenTheReportedOneLacksTheSession() throws {
        let fixture = try Fixture()
        try fixture.exec("\(Self.currentSchema)\nINSERT INTO session_v2 (id, directory) VALUES ('ses_other', '/elsewhere');")
        let dataDirectory = fixture.home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let found = dataDirectory.appendingPathComponent("opencode-beta.db").path
        try Fixture.exec(at: found, """
            \(Self.currentSchema)
            INSERT INTO session_v2 (id, directory) VALUES ('\(Self.sessionId)', '/work/repo');
            \(message("msg_1", seq: 1, type: "user", updated: 100, data: #"{"text":"Found me","time":{"created":100}}"#))
            """)

        let reader = fixture.reader()
        #expect(reader.readAppended()?.items.map(\.kind) == [.prompt("Found me")])
    }

    @Test func sessionsStillInOpenCode1TablesReadFromMessagesAndParts() throws {
        let fixture = try Fixture()
        try fixture.exec("""
            \(Self.legacySchema)
            INSERT INTO session (id, directory) VALUES ('\(Self.sessionId)', '/work/repo');
            INSERT INTO message VALUES ('msg_1', '\(Self.sessionId)', 100, 100, '{"role":"user","time":{"created":100}}');
            INSERT INTO part VALUES ('prt_1', 'msg_1', '\(Self.sessionId)', 100, 100, '{"type":"text","text":"Fix the build"}');
            INSERT INTO message VALUES ('msg_2', '\(Self.sessionId)', 101, 101, '{"role":"assistant","time":{"created":101}}');
            INSERT INTO part VALUES ('prt_2', 'msg_2', '\(Self.sessionId)', 101, 101, '{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"running","input":{"command":"swift build"},"time":{"start":101}}}');
            """)
        let reader = fixture.reader()
        let first = try #require(reader.readAppended())
        #expect(first.items.map(\.kind) == [.prompt("Fix the build"), .tool(AgentToolCall(name: "Bash", summary: "swift build"))])

        // 1.x streams into part rows and leaves the message row alone.
        try fixture.exec("""
            UPDATE part SET time_updated = 200, data = '{"type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","input":{"command":"swift build"},"output":"Build complete!","metadata":{"exit":0},"time":{"start":101,"end":200}}}' WHERE id = 'prt_2';
            INSERT INTO part VALUES ('prt_3', 'msg_2', '\(Self.sessionId)', 200, 200, '{"type":"text","text":"Fixed."}');
            """)
        let second = try #require(reader.readAppended())
        #expect(second.items.map(\.id) == ["msg_1", "call_1", "msg_2#1"])
        #expect(second.items[1].toolCall?.output == "Build complete!")
        #expect(second.items[2].kind == .reply("Fixed."))
    }

    // MARK: - Helpers

    private func message(_ id: String, seq: Int, type: String, updated: Int, data: String) -> String {
        "INSERT INTO session_message VALUES ('\(id)', '\(Self.sessionId)', '\(type)', \(seq), \(updated), \(updated), '\(data)');"
    }

    /// A temporary home holding the database the plugin reports.
    private struct Fixture {
        let home: URL
        let path: String

        init() throws {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("soprano-opencode-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            path = home.appendingPathComponent("reported.db").path
        }

        func reader() -> OpenCodeTranscriptReader {
            let source = AgentTranscriptSource(
                profileId: "opencode",
                conversation: AgentConversation(id: OpenCodeTranscriptReaderTests.sessionId, transcriptPath: path)
            )!
            return OpenCodeTranscriptReader(source: source, home: home, environment: [:])
        }

        func exec(_ sql: String) throws {
            try Self.exec(at: path, sql)
        }

        static func exec(at path: String, _ sql: String) throws {
            var database: OpaquePointer?
            #expect(sqlite3_open(path, &database) == SQLITE_OK)
            defer { sqlite3_close(database) }
            var error: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(database, sql, nil, nil, &error)
            let message = error.map { String(cString: $0) } ?? ""
            sqlite3_free(error)
            try #require(status == SQLITE_OK, "\(message)")
        }
    }
}
