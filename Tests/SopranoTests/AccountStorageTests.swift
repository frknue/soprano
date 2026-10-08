import AppKit
import Testing
@testable import Soprano

struct AccountStorageTests {
    @Test func aKeychainSecretSecurityPrintsAsHexIsReadBackAsTheJSONItWas() {
        let json = #"{"oauthAccount":{"organizationName":"Müller's Organization"}}"#
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()

        #expect(KeychainCLI.decodedSecret(hex) == json)
        // A plain secret that merely looks like hex is left alone.
        #expect(KeychainCLI.decodedSecret("cafe") == "cafe")
        #expect(KeychainCLI.decodedSecret(json) == json)
    }

    @Test func theKeychainWriteCommandCarriesTheSecretHexEncodedOnly() {
        let command = KeychainCLI.addCommand(service: "Claude Code-credentials", account: "ada", secret: #"{"a":"b c"}"#)
        #expect(command == "add-generic-password -U -a \"ada\" -s \"Claude Code-credentials\" -X \"7b2261223a22622063227d\"\n")
    }

    @Test @MainActor func savedAccountStateFromBeforeOmpPreferencesStillLoads() throws {
        let defaults = UserDefaults(suiteName: "soprano-accounts-\(UUID().uuidString)")!
        let older = #"{"claudeCode":{"accounts":[],"activeAccountId":null},"codexCLI":{"activeAccountId":"c1"}}"#
        defaults.set(Data(older.utf8), forKey: "soprano-accounts")

        let store = AccountStateStore(defaults: defaults)

        #expect(store.state.codexCLI.activeAccountId == "c1")
        #expect(store.state.codexCLI.accounts.isEmpty)
        #expect(store.state.ompPreferred.isEmpty)
    }
}
