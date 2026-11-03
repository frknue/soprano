import Foundation
import SQLite3

/// Follows one OpenCode session in OpenCode's SQLite database. The database is
/// opened read-only and stays open; each read first compares a few aggregates
/// and returns nil when they did not move, then fetches only the messages
/// updated since the last read. OpenCode 2.x rewrites an assistant message in
/// place while it streams, so entries are kept per message and replaced.
/// Only the store's serial queue touches it.
final class OpenCodeTranscriptReader: AgentTranscriptReader, @unchecked Sendable {
    /// Messages read when a session is first opened; the first read grows
    /// this up to `TranscriptFollower.entryLimit` to reach
    /// `TranscriptFollower.minimumPrompts` prompts.
    static let initialMessages = 600
    /// Milliseconds a read waits while OpenCode holds a write lock.
    static let busyTimeout: Int32 = 2_000

    let source: AgentTranscriptSource
    private let home: URL
    private let environment: [String: String]
    private let fileManager: FileManager

    private var database: OpaquePointer?
    private var tables: Tables = .current
    private var lastLookup: Date?
    private var decoder = OpenCodeMessageDecoder()
    private var signature: Signature?
    private var messages: [String: Message] = [:]
    /// The oldest message kept; nil while every message of the session is.
    private var lowerBound: Position?
    /// The newest message read, which tells new rows from updated ones.
    private var newest: Position?
    /// Messages from here on were rewound and stay hidden.
    private var revertBoundary: Position?
    private var lastTimeline: AgentTimeline?

    /// Which generation of OpenCode's tables holds the session.
    private enum Tables {
        /// 2.x: `session_v2`, `session_message`, `session_part`.
        case current
        /// 1.x: `session`, `message`, `part`.
        case legacy
    }

    /// Where a message sits: `seq` in 2.x, `time_created` then id in 1.x.
    private struct Position: Comparable {
        var order: Int64
        var id: String

        static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.order, lhs.id) < (rhs.order, rhs.id)
        }
    }

    private struct Message {
        var position: Position
        var entry: AgentTranscriptEntry
    }

    /// What a read compares to notice a change without loading messages.
    private struct Signature: Equatable {
        var messageCount: Int64
        var messagesUpdated: Int64
        var partCount: Int64
        var partsUpdated: Int64
        var revert: String?
        var directory: String?
        /// Bumped by every commit of another connection, so two writes in the
        /// same millisecond that only rewrite rows still count as a change.
        var dataVersion: Int64
    }

    private struct Row {
        var id: String
        var position: Position
        var type: String
        var data: Data
    }

    init(
        source: AgentTranscriptSource,
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.source = source
        self.home = home
        self.environment = environment
        self.fileManager = fileManager
    }

    deinit {
        sqlite3_close(database)
    }

    /// The timeline after reading what changed, or nil when nothing visible
    /// changed or the session is not in any database found.
    func readAppended() -> AgentTimeline? {
        guard let database = openDatabase() else { return nil }
        if tables == .legacy, contains(database, table: "session_v2") {
            // OpenCode 2.x migrated the session since it was opened.
            tables = .current
            reset()
        }

        // One read transaction, so the aggregates and the rows agree.
        guard exec(database, "BEGIN") else { return nil }
        let outcome = read(database)
        _ = exec(database, "COMMIT")
        switch outcome {
        case .missing:
            // The session was deleted; look for it again later.
            close()
            return nil
        case .unchanged:
            return nil
        case .changed(let timeline):
            return timeline
        }
    }

    private enum Outcome {
        case missing
        case unchanged
        case changed(AgentTimeline)
    }

    private func read(_ database: OpaquePointer) -> Outcome {
        guard let current = readSignature(database) else { return .missing }
        guard current != signature else { return .unchanged }
        let previous = signature
        signature = current
        decoder.cwd = current.directory

        let loaded: Bool
        if let previous,
           previous.revert == current.revert,
           previous.directory == current.directory,
           current.messageCount >= previous.messageCount,
           current.partCount >= previous.partCount,
           readChanges(database, since: previous, expectedCount: current.messageCount) {
            loaded = true
        } else {
            loaded = loadNewest(database)
        }
        guard loaded else {
            signature = nil
            return .unchanged
        }
        revertBoundary = current.revert.flatMap { position(database, ofRevert: $0) }

        let timeline = AgentTimeline(entries: messages.values
            .filter { message in revertBoundary.map { message.position < $0 } ?? true }
            .sorted { $0.position < $1.position }
            .map(\.entry))
        guard timeline != lastTimeline else { return .unchanged }
        lastTimeline = timeline
        return .changed(timeline)
    }

    // MARK: - Locating the database

    private func openDatabase() -> OpaquePointer? {
        if let database { return database }
        let now = Date()
        if let lastLookup, now.timeIntervalSince(lastLookup) < TranscriptFollower.lookupInterval { return nil }
        lastLookup = now

        var seen = Set<String>()
        for path in candidatePaths() where seen.insert(path).inserted {
            if let opened = open(path) {
                database = opened.database
                tables = opened.tables
                reset()
                return opened.database
            }
        }
        return nil
    }

    /// The path the plugin reported, then every `opencode*.db` in OpenCode's
    /// data directories, the default database first.
    private func candidatePaths() -> [String] {
        var paths = source.path.map { [$0] } ?? []
        var directories = [home.appendingPathComponent(".local/share/opencode", isDirectory: true)]
        if let dataHome = environment["XDG_DATA_HOME"], !dataHome.isEmpty {
            directories.append(URL(fileURLWithPath: dataHome, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true))
        }
        for directory in directories {
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            let databases = names
                .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
                .sorted { ($0 == "opencode.db" ? 0 : 1, $0) < ($1 == "opencode.db" ? 0 : 1, $1) }
            paths += databases.map { directory.appendingPathComponent($0).path }
        }
        return paths
    }

    /// The database at `path` opened read-only, when it holds the session.
    private func open(_ path: String) -> (database: OpaquePointer, tables: Tables)? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, Self.busyTimeout)
        if contains(handle, table: "session_v2") { return (handle, .current) }
        if contains(handle, table: "session") { return (handle, .legacy) }
        sqlite3_close(handle)
        return nil
    }

    private func contains(_ database: OpaquePointer, table: String) -> Bool {
        // Table names are fixed literals, never input.
        query(database, "SELECT 1 FROM \(table) WHERE id = ?", [source.conversationId]) { _ in true }?
            .isEmpty == false
    }

    private func close() {
        sqlite3_close(database)
        database = nil
        lastLookup = Date()
        reset()
    }

    private func reset() {
        signature = nil
        messages = [:]
        lowerBound = nil
        newest = nil
        revertBoundary = nil
        lastTimeline = nil
    }

    // MARK: - Reading

    private func readSignature(_ database: OpaquePointer) -> Signature? {
        let id = source.conversationId
        let session: (revert: String?, directory: String?)?
        let messageStats: (Int64, Int64)?
        let partStats: (Int64, Int64)?
        switch tables {
        case .current:
            session = query(database, "SELECT revert, directory FROM session_v2 WHERE id = ?", [id]) {
                (text($0, 0), text($0, 1))
            }?.first
            messageStats = aggregates(database, table: "session_message")
            // Older 2.x databases have no part table yet.
            partStats = aggregates(database, table: "session_part") ?? (0, 0)
        case .legacy:
            session = query(database, "SELECT revert, directory FROM session WHERE id = ?", [id]) {
                (text($0, 0), text($0, 1))
            }?.first
            messageStats = aggregates(database, table: "message")
            partStats = aggregates(database, table: "part")
        }
        guard let session, let messageStats, let partStats,
              let dataVersion = query(database, "PRAGMA data_version", [], { sqlite3_column_int64($0, 0) })?.first
        else { return nil }
        return Signature(
            messageCount: messageStats.0,
            messagesUpdated: messageStats.1,
            partCount: partStats.0,
            partsUpdated: partStats.1,
            revert: session.revert,
            directory: session.directory,
            dataVersion: dataVersion
        )
    }

    private func aggregates(_ database: OpaquePointer, table: String) -> (Int64, Int64)? {
        query(database, "SELECT count(*), coalesce(max(time_updated), 0) FROM \(table) WHERE session_id = ?",
              [source.conversationId]) {
            (sqlite3_column_int64($0, 0), sqlite3_column_int64($0, 1))
        }?.first
    }

    /// Reads the newest messages, more of them until enough prompts show.
    private func loadNewest(_ database: OpaquePointer) -> Bool {
        let sql = switch tables {
        case .current:
            "SELECT id, seq, type, data FROM session_message WHERE session_id = ? ORDER BY seq DESC LIMIT ?"
        case .legacy:
            "SELECT id, time_created, '', data FROM message WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT ?"
        }
        var limit = Self.initialMessages
        while true {
            guard let rows = query(database, sql, [source.conversationId, Int64(limit)], row)?.reversed() else {
                return false
            }
            messages = [:]
            for row in rows {
                messages[row.id] = Message(position: row.position, entry: entry(database, for: row))
            }
            lowerBound = rows.count < limit ? nil : rows.first?.position
            newest = rows.last?.position
            let prompts = messages.values.reduce(0) { count, message in
                count + message.entry.items.filter(\.isPrompt).count
            }
            if lowerBound == nil || prompts >= TranscriptFollower.minimumPrompts || limit >= TranscriptFollower.entryLimit {
                return true
            }
            limit = min(limit * 4, TranscriptFollower.entryLimit)
        }
    }

    /// Re-reads the messages updated since `previous`, and those whose parts
    /// were. Returns false when rows went missing, which needs a full reload.
    private func readChanges(_ database: OpaquePointer, since previous: Signature, expectedCount: Int64) -> Bool {
        let id = source.conversationId
        let changedSQL: String
        let partsSQL: String
        let messageSQL: String
        switch tables {
        case .current:
            changedSQL = "SELECT id, seq, type, data FROM session_message WHERE session_id = ? AND time_updated >= ?"
            partsSQL = "SELECT DISTINCT message_id FROM session_part WHERE session_id = ? AND time_updated >= ?"
            messageSQL = "SELECT id, seq, type, data FROM session_message WHERE session_id = ? AND id = ?"
        case .legacy:
            changedSQL = "SELECT id, time_created, '', data FROM message WHERE session_id = ? AND time_updated >= ?"
            partsSQL = "SELECT DISTINCT message_id FROM part WHERE session_id = ? AND time_updated >= ?"
            messageSQL = "SELECT id, time_created, '', data FROM message WHERE session_id = ? AND id = ?"
        }

        guard var rows = query(database, changedSQL, [id, previous.messagesUpdated], row) else { return false }
        var changedIds = Set(rows.map(\.id))
        if signature?.partCount ?? 0 > 0 {
            guard let partOwners = query(database, partsSQL, [id, previous.partsUpdated], { text($0, 0) }) else {
                return false
            }
            for case let messageId? in partOwners where changedIds.insert(messageId).inserted {
                guard let owner = query(database, messageSQL, [id, messageId], row) else { return false }
                rows += owner
            }
        }

        let added = rows.filter { row in newest.map { row.position > $0 } ?? true }
        guard previous.messageCount + Int64(added.count) == expectedCount else { return false }

        for row in rows where lowerBound.map({ row.position >= $0 }) ?? true {
            messages[row.id] = Message(position: row.position, entry: entry(database, for: row))
        }
        if let last = added.map(\.position).max() {
            newest = last
        }
        if messages.count > TranscriptFollower.entryLimit {
            let kept = messages.values.map(\.position).sorted().suffix(TranscriptFollower.entryLimit)
            lowerBound = kept.first
            messages = messages.filter { message in kept.first.map { message.value.position >= $0 } ?? true }
        }
        return true
    }

    private func entry(_ database: OpaquePointer, for row: Row) -> AgentTranscriptEntry {
        let id = source.conversationId
        switch tables {
        case .current:
            var parts: [OpenCodeMessageDecoder.PartRow] = []
            if row.type == "assistant", signature?.partCount ?? 0 > 0 {
                parts = query(
                    database,
                    "SELECT type, data FROM session_part WHERE session_id = ? AND message_id = ? ORDER BY ordinal",
                    [id, row.id]
                ) { OpenCodeMessageDecoder.PartRow(type: text($0, 0) ?? "", data: blob($0, 1)) } ?? []
            }
            return decoder.entry(id: row.id, type: row.type, data: row.data, parts: parts)
        case .legacy:
            let parts = query(
                database,
                "SELECT data FROM part WHERE session_id = ? AND message_id = ? ORDER BY id",
                [id, row.id]
            ) { blob($0, 0) } ?? []
            return decoder.legacyEntry(id: row.id, data: row.data, parts: parts)
        }
    }

    /// Where the message a rewind returned to sits; it and everything after
    /// it are hidden until the rewind is undone or committed.
    private func position(_ database: OpaquePointer, ofRevert revert: String) -> Position? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(revert.utf8))) as? [String: Any],
              let messageId = object["messageID"] as? String
        else { return nil }
        let sql = switch tables {
        case .current: "SELECT seq FROM session_message WHERE session_id = ? AND id = ?"
        case .legacy: "SELECT time_created FROM message WHERE session_id = ? AND id = ?"
        }
        return query(database, sql, [source.conversationId, messageId]) {
            Position(order: sqlite3_column_int64($0, 0), id: messageId)
        }?.first
    }

    private func row(_ statement: OpaquePointer) -> Row {
        let id = text(statement, 0) ?? ""
        return Row(
            id: id,
            position: Position(order: sqlite3_column_int64(statement, 1), id: id),
            type: text(statement, 2) ?? "",
            data: blob(statement, 3)
        )
    }

    // MARK: - SQLite

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ database: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Every row `sql` returns, or nil when it cannot run, such as for a
    /// table this database does not have.
    private func query<T>(
        _ database: OpaquePointer,
        _ sql: String,
        _ arguments: [Any],
        _ makeRow: (OpaquePointer) -> T
    ) -> [T]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() {
            let position = Int32(index + 1)
            switch argument {
            case let value as Int64: sqlite3_bind_int64(statement, position, value)
            case let value as String: sqlite3_bind_text(statement, position, value, -1, Self.sqliteTransient)
            default: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(makeRow(statement))
            case SQLITE_DONE: return rows
            default: return nil
            }
        }
    }
}

private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
}

private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
    guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
}
