import AppKit
import Testing
@testable import Soprano

struct CodexAccountTests {
    private func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(payload).signature"
    }

    private func makeDirectories() throws -> (source: URL, home: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-codex-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("dot-codex", isDirectory: true)
        let home = root.appendingPathComponent("managed/home", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (source, home, root)
    }

    private func write(_ text: String, _ url: URL, modified: Date? = nil) throws {
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func linkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    @Test func aCodexLoginIsIdentifiedByTheIdTokensEmailAndTheChatGPTAccount() throws {
        let auth = """
            {"tokens": {
              "id_token": "\(jwt([
                  "email": "eric@example.com",
                  "https://api.openai.com/auth": ["chatgpt_account_id": "ws-1", "chatgpt_plan_type": "prolite"],
              ]))",
              "access_token": "\(jwt(["exp": 1_900_000_000]))",
              "account_id": "ws-1"
            }}
            """
        let parsed = try #require(CodexAuth.parse(Data(auth.utf8)))

        #expect(parsed.identity == AccountIdentity(email: "eric@example.com", organizationId: "ws-1"))
        #expect(parsed.plan == "prolite")
        #expect(parsed.accessTokenExpiry == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test func anAPIKeyLoginWithoutTokensIsNotAChatGPTAccount() {
        #expect(CodexAuth.parse(Data(#"{"OPENAI_API_KEY": "sk-test", "tokens": null}"#.utf8)) == nil)
    }

    @Test func aManagedHomeSharesEverythingButTheLoginItsModelCacheAndSQLiteJournals() throws {
        let (source, home, root) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["config.toml", "auth.json", "models_cache.json", "state_5.sqlite", "state_5.sqlite-wal", "history.jsonl"] {
            try write(name, source.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sessions"), withIntermediateDirectories: true)

        try CodexHomeLinker.sync(home: home, source: source)

        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: home.path))
        #expect(entries == ["config.toml", "state_5.sqlite", "history.jsonl", "sessions"])
        #expect(linkTarget(home.appendingPathComponent("sessions")) == source.appendingPathComponent("sessions").path)
    }

    @Test func aSharedFileCodexRewroteInTheManagedHomeIsFoldedBackWhenNewer() throws {
        let (source, home, root) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = source.appendingPathComponent("config.toml")
        try write("model = \"old\"", shared, modified: Date(timeIntervalSinceNow: -600))
        // Codex saved its settings by renaming a new file over the link.
        let rewritten = home.appendingPathComponent("config.toml")
        try write("model = \"new\"", rewritten, modified: Date())

        try CodexHomeLinker.sync(home: home, source: source)

        #expect(try String(contentsOf: shared, encoding: .utf8) == "model = \"new\"")
        #expect(linkTarget(rewritten) == shared.path)
    }

    @Test func anOlderRewrittenCopyLosesToTheSharedFile() throws {
        let (source, home, root) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = source.appendingPathComponent("config.toml")
        try write("model = \"edited by hand\"", shared, modified: Date())
        let stale = home.appendingPathComponent("config.toml")
        try write("model = \"stale\"", stale, modified: Date(timeIntervalSinceNow: -600))

        try CodexHomeLinker.sync(home: home, source: source)

        #expect(try String(contentsOf: shared, encoding: .utf8) == "model = \"edited by hand\"")
        #expect(linkTarget(stale) == shared.path)
    }

    @Test func linksToDeletedEntriesAreDroppedAndCodexsOwnDirectoriesKept() throws {
        let (source, home, root) = try makeDirectories()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = source.appendingPathComponent("prompts")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try CodexHomeLinker.sync(home: home, source: source)
        try FileManager.default.removeItem(at: gone)
        let own = home.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("log"), withIntermediateDirectories: true)

        try CodexHomeLinker.sync(home: home, source: source)

        #expect(linkTarget(home.appendingPathComponent("prompts")) == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("prompts").path))
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: own.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(linkTarget(own) == nil)
    }
}
