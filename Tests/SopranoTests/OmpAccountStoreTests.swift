import AppKit
import SQLite3
import Testing
@testable import Soprano

struct OmpAccountStoreTests {
    /// omp's `auth_credentials` table and its change-revision trigger, as
    /// omp 18 creates them.
    private static let schema = """
        CREATE TABLE auth_credentials (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            credential_type TEXT NOT NULL,
            data TEXT NOT NULL,
            disabled_cause TEXT DEFAULT NULL,
            identity_key TEXT DEFAULT NULL,
            created_at INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE auth_change_revision (id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL);
        INSERT INTO auth_change_revision VALUES (1, 0);
        CREATE TRIGGER bump AFTER UPDATE ON auth_credentials
        BEGIN UPDATE auth_change_revision SET revision = revision + 1 WHERE id = 1; END;
        INSERT INTO auth_credentials (provider, credential_type, data, identity_key) VALUES
            ('anthropic', 'oauth', '{}', 'email:ada@example.com|org:org-personal'),
            ('anthropic', 'oauth', '{}', 'email:ada@example.com|org:org-team'),
            ('openai-codex', 'oauth', '{}', 'email:ada@example.com|org:org-personal'),
            ('anthropic', 'api_key', '{}', NULL);
        """

    private func makeDatabase(_ sql: String = schema) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-omp-\(UUID().uuidString).db").path
        var database: OpaquePointer?
        #expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        return path
    }

    private func rows(_ path: String) -> [(id: Int64, provider: String, cause: String?)] {
        var database: OpaquePointer?
        sqlite3_open(path, &database)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(database, "SELECT id, provider, disabled_cause FROM auth_credentials ORDER BY id", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var result: [(Int64, String, String?)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let cause = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            result.append((sqlite3_column_int64(statement, 0), String(cString: sqlite3_column_text(statement, 1)), cause))
        }
        return result
    }

    @Test func removingAnOmpLoginMarksOnlyThatOrganizationsRowDeletedTheWayOmpDoes() throws {
        let path = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let removed = try OmpAccountManager.softDeleteLogin(
            databasePath: path,
            providerId: "anthropic",
            identity: AccountIdentity(email: "Ada@Example.com", organizationId: "org-team")
        )

        #expect(removed)
        let causes = rows(path).map(\.cause)
        #expect(causes == [nil, "deleted by user", nil, nil])
    }

    @Test func removingALoginOmpNoLongerHasReportsNothingRemoved() throws {
        let path = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let identity = AccountIdentity(email: "ada@example.com", organizationId: "org-personal")

        #expect(try OmpAccountManager.softDeleteLogin(databasePath: path, providerId: "anthropic", identity: identity))
        // Already deleted: a second removal must not touch the tombstone again.
        #expect(try !OmpAccountManager.softDeleteLogin(databasePath: path, providerId: "anthropic", identity: identity))
        // The same person's Codex login is a different provider's row.
        #expect(rows(path)[2].cause == nil)
    }

    @Test func anOmpDatabaseWithoutIdentityKeysIsRefusedRatherThanGuessedAt() throws {
        let path = try makeDatabase("""
            CREATE TABLE auth_credentials (id INTEGER PRIMARY KEY, provider TEXT, credential_type TEXT, data TEXT);
            INSERT INTO auth_credentials (provider, credential_type, data) VALUES ('anthropic', 'oauth', '{}');
            """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: OmpAccountError.self) {
            try OmpAccountManager.softDeleteLogin(
                databasePath: path,
                providerId: "anthropic",
                identity: AccountIdentity(email: "ada@example.com")
            )
        }
    }

    @Test func identityKeysMatchOnLowercasedEmailAndTheOrganizationOrAccount() {
        let identity = AccountIdentity(email: "Ada@Example.com", organizationId: "ws-1")
        #expect(OmpAccountManager.identityKey("email:ada@example.com|org:ws-1", matches: identity))
        #expect(OmpAccountManager.identityKey("account:ws-1|email:ada@example.com", matches: identity))
        #expect(!OmpAccountManager.identityKey("email:ada@example.com|org:ws-2", matches: identity))
        #expect(!OmpAccountManager.identityKey("email:bob@example.com|org:ws-1", matches: identity))
    }

    @Test func theOverlayWithoutPreferencesIsAnEmptyMappingOmpAccepts() {
        let text = OmpAccountManager.overlay(preferences: [])
        #expect(text.hasSuffix("\n{}\n"))
        #expect(!text.contains("accountPolicies"))
    }

    @Test func theOverlayGivesEachPreferredAccountAPriorityPolicyWithQuotedSelectors() {
        let text = OmpAccountManager.overlay(preferences: [
            ("anthropic", OmpPreference(email: "ada@example.com", orgId: "org-1")),
            ("openai-codex", OmpPreference(email: #"odd"name@example.com"#, orgId: nil)),
        ])

        #expect(text.contains("""
            auth:
              accountPolicies:
                - provider: "anthropic"
                  account:
                    email: "ada@example.com"
                    orgId: "org-1"
                  priority: 100
                - provider: "openai-codex"
                  account:
                    email: "odd\\"name@example.com"
                  priority: 100
            """))
    }
}
