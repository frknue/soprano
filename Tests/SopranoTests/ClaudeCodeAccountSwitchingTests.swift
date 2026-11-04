import AppKit
import Testing
@testable import Soprano

/// Switching Claude Code logins against a stand-in `security` tool that files
/// generic passwords as plain files, so no test touches the real Keychain.
@MainActor
struct ClaudeCodeAccountSwitchingTests {
    /// Speaks the `security` commands Soprano uses. Like the real tool, `-i`
    /// reads each input line into a 4096-byte buffer, so a longer line is cut.
    private static let fakeSecurity = #"""
        #!/bin/bash
        set -u
        dir="$(dirname "$0")/items"
        mkdir -p "$dir"
        name() { printf '%s' "$1|$2" | shasum | cut -d' ' -f1; }
        lookup() {
            service=""; account=""; hex=""
            while [ $# -gt 0 ]; do
                case "$1" in -s) service="$2"; shift 2;; -a) account="$2"; shift 2;; -X) hex="$2"; shift 2;; *) shift;; esac
            done
            item="$dir/$(name "$service" "$account")"
        }
        case "${1:-}" in
            find-generic-password)
                shift; lookup "$@"
                [ -f "$item" ] || exit 44
                cat "$item"; echo ;;
            delete-generic-password)
                shift; lookup "$@"
                [ -f "$item" ] || exit 44
                rm "$item" ;;
            add-generic-password)
                shift; lookup "$@"
                printf '%s' "$hex" | xxd -r -p > "$item" ;;
            -i)
                while IFS= read -r line; do
                    line="${line:0:4095}"
                    account=$(sed -E 's/.* -a "([^"]*)".*/\1/' <<<"$line")
                    service=$(sed -E 's/.* -s "([^"]*)".*/\1/' <<<"$line")
                    hex=$(sed -E 's/.* -X "([^"]*)".*/\1/' <<<"$line")
                    printf '%s' "$hex" | xxd -r -p > "$dir/$(name "$service" "$account")"
                done ;;
        esac
        """#

    /// A login shell whose `claude auth login` files a new login in the
    /// config-scoped Keychain item, prints its sign-in URL and then waits for
    /// the browser, as the real one does.
    private static func fakeClaudeLogin(security: String, user: String) -> String {
        #"""
        #!/bin/bash
        service="Claude Code-credentials-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"
        hex=$(printf '%s' '{"claudeAiOauth":{"accessToken":"n-a","refreshToken":"n-r"}}' | xxd -p | tr -d '\n')
        printf 'add-generic-password -U -a "%s" -s "%s" -X "%s"\n' '\#(user)' "$service" "$hex" | '\#(security)' -i
        echo "Open https://claude.ai/oauth/authorize?code=true"
        exec sleep 30
        """#
    }

    private struct Fixture {
        let manager: ClaudeCodeAccountManager
        let store: AccountStateStore
        let keychain: KeychainCLI
        let paths: AccountPaths
        let root: URL
    }

    private let user = ClaudeCodeAccountManager.keychainUser

    private func makeFixture(profiles: [String: AccountIdentity] = [:], fakeSignIn: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-claude-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        let security = root.appendingPathComponent("security")
        try Data(Self.fakeSecurity.utf8).write(to: security)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: security.path)

        var runner = CommandRunner()
        if fakeSignIn {
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let scripts = [
                "shell": "#!/bin/bash\nexport PATH=\"\(bin.path):$PATH\"\nexec /bin/bash -c \"$2\"\n",
                "bin/claude": Self.fakeClaudeLogin(security: security.path, user: user),
            ]
            for (name, text) in scripts {
                let url = root.appendingPathComponent(name)
                try Data(text.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            runner.shell = root.appendingPathComponent("shell").path
        }

        let keychain = KeychainCLI(executable: security.path)
        let paths = AccountPaths(home: home, supportDirectory: root.appendingPathComponent("support"))
        let store = AccountStateStore(defaults: UserDefaults(suiteName: "soprano-claude-\(UUID().uuidString)")!)
        let manager = ClaudeCodeAccountManager(
            store: store,
            keychain: keychain,
            runner: runner,
            paths: paths,
            profile: { token in profiles[token] }
        )
        return Fixture(manager: manager, store: store, keychain: keychain, paths: paths, root: root)
    }

    private func json(_ text: String?) -> [String: Any]? {
        text.flatMap(AccountFiles.jsonObject)
    }

    private func liveBlob(_ fixture: Fixture) async throws -> [String: Any] {
        try #require(json(try await fixture.keychain.read(service: ClaudeCodeAccountManager.liveService, account: user)))
    }

    private func liveEmail(_ fixture: Fixture) throws -> String? {
        let config = try AccountFiles.jsonObject(at: fixture.paths.claudeGlobalConfigFile)
        return (config?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    private func accessToken(_ blob: [String: Any]?) -> String? {
        (blob?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
    }

    /// Claude Code signed in as me@own.dev, with an MCP token beside the login,
    /// and one managed account x@team.dev that Soprano already stores.
    private func seed(_ fixture: Fixture) async throws {
        try await fixture.keychain.write(
            service: ClaudeCodeAccountManager.liveService,
            account: user,
            secret: #"{"claudeAiOauth":{"accessToken":"own-a","refreshToken":"own-r"},"mcpOAuth":{"server":"mcp-token"}}"#
        )
        try Data(#"{"oauthAccount":{"emailAddress":"me@own.dev","organizationUuid":"org-own"},"projects":{"/p":{}}}"#.utf8)
            .write(to: fixture.paths.claudeGlobalConfigFile)
        try await fixture.keychain.write(
            service: ClaudeCodeAccountManager.managedService,
            account: "x",
            secret: #"{"claudeAiOauth":{"accessToken":"x-a","refreshToken":"x-r"},"oauthAccount":{"emailAddress":"x@team.dev","organizationUuid":"org-x"}}"#
        )
        fixture.store.update { state in
            state.claudeCode.accounts = [ManagedAccountRecord(
                id: "x",
                identity: AccountIdentity(email: "x@team.dev", organizationId: "org-x"),
                createdAt: Date(),
                lastAuthenticatedAt: Date()
            )]
        }
    }

    @Test func choosingAnAccountSignsClaudeCodeInWithItAndKeepsEverythingElseInItsStores() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await seed(fixture)
        let plaintext = fixture.paths.claudeConfigDirectory.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"own-a"}}"#.utf8).write(to: plaintext)

        try await fixture.manager.select("x")

        let live = try await liveBlob(fixture)
        #expect(accessToken(live) == "x-a")
        #expect((live["mcpOAuth"] as? [String: Any])?["server"] as? String == "mcp-token")
        #expect(accessToken(try AccountFiles.jsonObject(at: plaintext)) == "x-a")
        #expect(try liveEmail(fixture) == "x@team.dev")
        let config = try #require(try AccountFiles.jsonObject(at: fixture.paths.claudeGlobalConfigFile))
        #expect(config["projects"] != nil)
        #expect(fixture.store.state.claudeCode.activeAccountId == "x")
        #expect(fixture.store.state.claudeCode.systemDefault?.identity.email == "me@own.dev")
    }

    @Test func choosingSystemDefaultPutsClaudeCodesOwnLoginBack() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await seed(fixture)

        try await fixture.manager.select("x")
        try await fixture.manager.select(nil)

        let live = try await liveBlob(fixture)
        #expect(accessToken(live) == "own-a")
        #expect((live["mcpOAuth"] as? [String: Any])?["server"] as? String == "mcp-token")
        #expect(try liveEmail(fixture) == "me@own.dev")
        #expect(fixture.store.state.claudeCode.activeAccountId == nil)
    }

    @Test func tokensClaudeCodeRefreshedUnderAnAccountStayWithThatAccount() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await seed(fixture)
        try await fixture.manager.select("x")

        // Claude Code refreshes: the stored refresh token "x-r" is now spent.
        var live = try await liveBlob(fixture)
        live["claudeAiOauth"] = ["accessToken": "x-a2", "refreshToken": "x-r2"]
        try await fixture.keychain.write(
            service: ClaudeCodeAccountManager.liveService,
            account: user,
            secret: AccountFiles.jsonString(live)
        )
        try await fixture.manager.select(nil)
        try await fixture.manager.select("x")

        #expect(accessToken(try await liveBlob(fixture)) == "x-a2")
    }

    @Test func aSignInMadeOutsideSopranoBecomesTheSystemDefault() async throws {
        let fixture = try makeFixture(profiles: ["z-a": AccountIdentity(email: "z@else.dev", organizationId: "org-z")])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await seed(fixture)
        try await fixture.manager.select("x")

        // `claude auth login` with another account, in a terminal.
        try await fixture.keychain.write(
            service: ClaudeCodeAccountManager.liveService,
            account: user,
            secret: #"{"claudeAiOauth":{"accessToken":"z-a","refreshToken":"z-r"}}"#
        )
        try Data(#"{"oauthAccount":{"emailAddress":"z@else.dev","organizationUuid":"org-z"}}"#.utf8)
            .write(to: fixture.paths.claudeGlobalConfigFile)

        let list = await fixture.manager.list()

        #expect(list.selectedAccountId == nil)
        #expect(list.systemDefault?.identity.email == "z@else.dev")
        // The managed account keeps its own tokens, not the stranger's.
        let stored = json(try await fixture.keychain.read(service: ClaudeCodeAccountManager.managedService, account: "x"))
        #expect(accessToken(stored) == "x-a")
    }

    @Test func removingTheActiveAccountPutsTheSystemDefaultBackAndForgetsTheLogin() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await seed(fixture)
        try await fixture.manager.select("x")

        try await fixture.manager.remove("x")

        #expect(accessToken(try await liveBlob(fixture)) == "own-a")
        #expect(fixture.store.state.claudeCode.accounts.isEmpty)
        #expect(try await fixture.keychain.read(service: ClaudeCodeAccountManager.managedService, account: "x") == nil)
    }

    @Test func aSwitchThatFailsHalfwayPutsTheLiveLoginBackSoNoAccountGetsAnothersTokens() async throws {
        let fixture = try makeFixture()
        let home = fixture.paths.claudeGlobalConfigFile.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try await seed(fixture)
        try await fixture.keychain.write(
            service: ClaudeCodeAccountManager.managedService,
            account: "y",
            secret: #"{"claudeAiOauth":{"accessToken":"y-a","refreshToken":"y-r"},"oauthAccount":{"emailAddress":"y@team.dev","organizationUuid":"org-y"}}"#
        )
        fixture.store.update { state in
            state.claudeCode.accounts.append(ManagedAccountRecord(
                id: "y",
                identity: AccountIdentity(email: "y@team.dev", organizationId: "org-y"),
                createdAt: Date(),
                lastAuthenticatedAt: Date()
            ))
        }
        try await fixture.manager.select("x")

        // ~/.claude.json cannot be replaced, so the switch to y fails after
        // the Keychain item already took y's tokens.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        await #expect(throws: (any Error).self) { try await fixture.manager.select("y") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)

        #expect(accessToken(try await liveBlob(fixture)) == "x-a")
        #expect((try await liveBlob(fixture)["mcpOAuth"] as? [String: Any])?["server"] as? String == "mcp-token")
        let list = await fixture.manager.list()
        #expect(list.selectedAccountId == "x")
        let storedX = json(try await fixture.keychain.read(service: ClaudeCodeAccountManager.managedService, account: "x"))
        #expect(accessToken(storedX) == "x-a")
    }

    @Test func aLoginTooLongForOneSecurityInputLineIsStillStored() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // MCP OAuth tokens beside the login push the item past 2 KB, its hex past 4 KB.
        let secret = #"{"claudeAiOauth":{"accessToken":"a"},"mcpOAuth":{"server":""#
            + String(repeating: "t", count: 3_000) + #""}}"#

        try await fixture.keychain.write(service: ClaudeCodeAccountManager.liveService, account: user, secret: secret)

        #expect(try await fixture.keychain.read(service: ClaudeCodeAccountManager.liveService, account: user) == secret)
    }

    @Test func cancellingASignInStillDeletesTheLoginClaudeCodeStoredForIt() async throws {
        let fixture = try makeFixture(fakeSignIn: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let items = fixture.root.appendingPathComponent("items")
        let opened = SignInPages()

        let manager = fixture.manager
        let signIn = Task { try await manager.addAccount(onSignInURL: { _ in opened.record() }) }
        let deadline = Date().addingTimeInterval(15)
        while opened.count == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(opened.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: items.path).count == 1)

        signIn.cancel()
        _ = await signIn.result

        #expect(try FileManager.default.contentsOfDirectory(atPath: items.path).isEmpty)
        #expect(fixture.store.state.claudeCode.accounts.isEmpty)
    }

    /// Counts sign-in pages opened, from the command runner's reader thread.
    private final class SignInPages: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func record() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    @Test func claudeCodesScopedKeychainNameHashesTheConfigDirectoryLikeClaudeCodeDoes() {
        // Claude Code 2.1: "Claude Code-credentials-" + sha256(NFC(dir)).hex[0..<8].
        #expect(
            ClaudeCodeAccountManager.scopedService(configDirectory: "/Users/test/.claude")
                == "Claude Code-credentials-462977e4"
        )
    }
}
