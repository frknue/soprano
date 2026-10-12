import Foundation

/// Where one agent's conversation is written, in which CLI's format.
struct AgentTranscriptSource: Hashable, Sendable {
    let format: AgentTranscriptFormat
    let conversationId: String
    /// The file the agent's hooks reported; located from the id when nil.
    let path: String?

    /// The transcript of an agent's current conversation, when its CLI writes
    /// one the dashboard can read.
    init?(profileId: String, conversation: AgentConversation?) {
        guard let format = AgentTranscriptFormat(profileId: profileId),
              let conversation,
              AgentConversation.validID(conversation.id)
        else { return nil }
        self.format = format
        conversationId = conversation.id
        path = conversation.transcriptPath
    }
}

/// Follows the transcripts of the agents on the Agent Dashboard. A file is read
/// from its end when first seen and afterwards only for the bytes appended
/// since; parsing runs on a background queue and finished timelines arrive on
/// the main actor. The dashboard owns the store, so nothing is read while it is
/// closed.
@MainActor
final class AgentTranscriptStore {
    /// Called with a dashboard entry id whenever that agent's timeline changed.
    var onChange: ((String) -> Void)?

    private let home: URL
    private let queue = DispatchQueue(label: "com.soprano.agent-transcripts", qos: .utility)
    private var followers: [String: TranscriptFollower] = [:]
    private var timelines: [String: AgentTimeline] = [:]
    private var reading: Set<ObjectIdentifier> = []

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func isTracking(_ entryId: String) -> Bool {
        followers[entryId] != nil
    }

    func timeline(for entryId: String) -> AgentTimeline? {
        timelines[entryId]
    }

    /// Follows `sources`, keyed by dashboard entry id, and drops every other
    /// transcript. A source whose file or conversation changed starts over.
    func track(_ sources: [String: AgentTranscriptSource]) {
        for entryId in followers.keys where sources[entryId] == nil {
            followers[entryId] = nil
            timelines[entryId] = nil
        }
        for (entryId, source) in sources where followers[entryId]?.source != source {
            followers[entryId] = TranscriptFollower(source: source, home: home)
            timelines[entryId] = nil
            read(entryId)
        }
    }

    /// Picks up whatever the followed transcripts gained since the last call.
    /// The dashboard calls this every second; a file that did not grow is only
    /// opened and measured.
    func refresh() {
        for entryId in followers.keys {
            read(entryId)
        }
    }

    private func read(_ entryId: String) {
        guard let follower = followers[entryId],
              reading.insert(ObjectIdentifier(follower)).inserted
        else { return }
        queue.async { [weak self] in
            let timeline = follower.readAppended()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reading.remove(ObjectIdentifier(follower))
                // A follower replaced while it was reading reports nothing.
                guard self.followers[entryId] === follower, let timeline else { return }
                self.timelines[entryId] = timeline
                self.onChange?(entryId)
            }
        }
    }
}

/// One transcript being followed. Only the store's serial queue touches it.
final class TranscriptFollower: @unchecked Sendable {
    /// Bytes read from the end of a transcript when it is first opened.
    static let initialWindow: UInt64 = 2 << 20
    /// The first read grows its window up to this size to reach at least
    /// `minimumPrompts` prompts: one Claude Code record can hold a whole file or
    /// an image, so a fixed tail sometimes covers only part of a turn.
    static let maximumWindow: UInt64 = 32 << 20
    static let minimumPrompts = 2
    /// Entries kept per transcript; older ones fall off the front.
    static let entryLimit = 4_000
    /// Seconds between searches for a transcript that has not been found.
    static let lookupInterval: TimeInterval = 5

    let source: AgentTranscriptSource
    private let home: URL
    private var url: URL?
    private var lastLookup: Date?
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var decoder: any AgentTranscriptDecoding
    private var entries: [AgentTranscriptEntry] = []

    init(source: AgentTranscriptSource, home: URL) {
        self.source = source
        self.home = home
        decoder = source.format.makeDecoder()
        url = source.path.map { URL(fileURLWithPath: $0) }
    }

    /// The timeline after reading what the file gained, or nil when the file is
    /// missing or nothing visible changed.
    func readAppended() -> AgentTimeline? {
        guard let url = resolvedURL(),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        if size < offset {
            // Rewritten in place: start over from its end.
            reset()
        }
        guard size > offset else { return nil }

        let changed: Bool
        if offset == 0 {
            loadTail(of: handle, size: size)
            changed = true
        } else {
            changed = consume(read(handle, from: offset, to: size), skippingFirstLine: false)
            offset = size
        }
        return changed ? AgentTimeline(entries: entries) : nil
    }

    private func resolvedURL() -> URL? {
        if let url { return url }
        let now = Date()
        if let lastLookup, now.timeIntervalSince(lastLookup) < Self.lookupInterval { return nil }
        lastLookup = now
        url = AgentTranscriptLocator.transcriptURL(
            format: source.format,
            conversationId: source.conversationId,
            home: home
        )
        return url
    }

    private func loadTail(of handle: FileHandle, size: UInt64) {
        var window = Self.initialWindow
        while true {
            reset()
            let start = size > window ? size - window : 0
            consume(read(handle, from: start, to: size), skippingFirstLine: start > 0)
            offset = size
            let prompts = entries.reduce(0) { count, entry in
                count + entry.items.filter(\.isPrompt).count
            }
            if start == 0 || prompts >= Self.minimumPrompts || window >= Self.maximumWindow {
                return
            }
            window *= 4
        }
    }

    private func read(_ handle: FileHandle, from start: UInt64, to end: UInt64) -> Data {
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(end - start))
        else { return Data() }
        return data
    }

    /// Decodes every complete line in `data` and keeps a trailing partial line
    /// for the next read. Returns whether any entry was added.
    @discardableResult
    private func consume(_ data: Data, skippingFirstLine: Bool) -> Bool {
        var buffer = remainder
        buffer.append(data)
        var lineStart = buffer.startIndex
        if skippingFirstLine {
            // A tail starts mid-record; that partial line cannot parse.
            guard let newline = buffer.firstIndex(of: 0x0A) else {
                remainder = buffer
                return false
            }
            lineStart = buffer.index(after: newline)
        }

        var added = false
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            if newline > lineStart,
               let entry = decoder.entry(forLine: buffer[lineStart..<newline])
            {
                entries.append(entry)
                added = true
            }
            lineStart = buffer.index(after: newline)
        }
        remainder = Data(buffer[lineStart...])
        if entries.count > Self.entryLimit {
            entries.removeFirst(entries.count - Self.entryLimit)
        }
        return added
    }

    private func reset() {
        offset = 0
        remainder = Data()
        entries = []
        decoder = source.format.makeDecoder()
    }
}

/// Finds a conversation's transcript when no hook reported its path:
/// workspaces saved before Soprano kept it, Codex without its opt-in hooks,
/// and agents started outside Soprano's launcher.
enum AgentTranscriptLocator {
    static func transcriptURL(
        format: AgentTranscriptFormat,
        conversationId: String,
        home: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        // Valid ids are plain file-name characters, so they cannot escape the
        // directories searched below.
        guard AgentConversation.validID(conversationId) else { return nil }
        switch format {
        case .claudeCode:
            // ~/.claude/projects/<encoded cwd>/<session id>.jsonl
            let projects = home.appendingPathComponent(".claude/projects", isDirectory: true)
            let directories = (try? fileManager.contentsOfDirectory(
                at: projects,
                includingPropertiesForKeys: nil
            )) ?? []
            return directories.lazy
                .map { $0.appendingPathComponent("\(conversationId).jsonl") }
                .first { fileManager.fileExists(atPath: $0.path) }
        case .codex:
            // ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl
            return newestFile(
                under: home.appendingPathComponent(".codex/sessions", isDirectory: true),
                named: { $0.hasPrefix("rollout-") && $0.hasSuffix("-\(conversationId).jsonl") },
                fileManager: fileManager
            )
        case .omp:
            // ~/.omp/agent/sessions/<encoded cwd>/<time>_<session id>.jsonl
            return newestFile(
                under: home.appendingPathComponent(".omp/agent/sessions", isDirectory: true),
                named: { $0.hasSuffix("_\(conversationId).jsonl") },
                fileManager: fileManager
            )
        }
    }

    private static func newestFile(
        under root: URL,
        named matches: (String) -> Bool,
        fileManager: FileManager
    ) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where matches(url.lastPathComponent) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest.map({ date > $0.date }) ?? true {
                newest = (url, date)
            }
        }
        return newest?.url
    }
}

extension AgentTranscriptFormat {
    func makeDecoder() -> any AgentTranscriptDecoding {
        switch self {
        case .claudeCode: ClaudeTranscriptDecoder()
        case .codex: CodexRolloutDecoder()
        case .omp: OmpSessionDecoder()
        }
    }
}
