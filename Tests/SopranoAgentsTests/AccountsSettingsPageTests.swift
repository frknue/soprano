import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct AccountsSettingsPageTests {
    private struct Fixture {
        let directory: URL
        let source: FixtureAccountsSource
        let controller: SettingsController
    }

    private func makeFixture(_ snapshot: AccountsSnapshot) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sa-accounts-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let center = SettingsCenter(fileURL: directory.appendingPathComponent("settings.json"), registry: CommandRegistry())
        center.start(watching: false)
        let parent = MainWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        parent.allowsOffscreenFrame = true
        parent.isReleasedWhenClosed = false
        let source = FixtureAccountsSource(snapshot: snapshot)
        let engine = try DemoFixtures.build("empty").engine
        let controller = SettingsController(engine: engine, center: center, accounts: source, parent: parent, router: nil)
        return Fixture(directory: directory, source: source, controller: controller)
    }

    /// Every label and button title in `views`, top to bottom.
    private func texts(_ views: [NSView]) -> [String] {
        func collect(_ view: NSView, into result: inout [String]) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty {
                result.append(field.stringValue)
            } else if let button = view as? TextButton {
                result.append(button.title)
                return
            }
            for subview in view.subviews { collect(subview, into: &result) }
        }
        var result: [String] = []
        for view in views { collect(view, into: &result) }
        return result
    }

    private func buttons(_ views: [NSView], titled title: String) -> [TextButton] {
        func collect(_ view: NSView, into result: inout [TextButton]) {
            if let button = view as? TextButton, button.title == title { result.append(button) }
            for subview in view.subviews { collect(subview, into: &result) }
        }
        var result: [TextButton] = []
        for view in views { collect(view, into: &result) }
        return result
    }

    @Test func thePageListsEveryAccountListWithItsLoginsAndActions() throws {
        let fixture = try makeFixture(AccountFixtures.demo())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let sections = fixture.controller.buildPage(.accounts, form: SettingsForm(width: 768))
        let shown = texts(sections)

        #expect(sections.count == 1 + AccountListID.all.count)
        for title in ["Claude · omp", "Claude · Claude Code", "Codex · omp", "Codex · Codex CLI"] {
            #expect(shown.contains(title), "\(title)")
        }
        #expect(shown.contains("Updated 4m ago"))
        #expect(shown.contains("Automatic"))
        #expect(shown.filter { $0 == "ada@example.com" }.count == 1)
        #expect(shown.contains("grace@example.com"))
        #expect(shown.filter { $0 == "System default" }.count == 2)
        #expect(shown.filter { $0 == "Prefer" }.count == 2)
        #expect(shown.filter { $0 == "Add Account" }.count == 4)
        #expect(shown.contains { $0.contains("Soprano") && !$0.contains("Soprano Agents") } == false)
    }

    @Test func actionsGoToTheAccountsSource() throws {
        let fixture = try makeFixture(AccountFixtures.demo())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let sections = fixture.controller.buildPage(.accounts, form: SettingsForm(width: 768))

        buttons(sections, titled: "Prefer").first?.onClick?()
        buttons(sections, titled: "Add Account").first?.onClick?()
        buttons(sections, titled: "Refresh").first?.onClick?()

        #expect(fixture.source.actions == ["select:omp-claude:ada@example.com|org-ada", "add:omp-claude", "refresh:force"])
        #expect(fixture.source.snapshot.lists[.ompClaude]?.selectedAccountId == "ada@example.com|org-ada")
    }

    @Test func aPendingSignInOffersTheSignInPageAndCancelAndBlocksOtherSignIns() throws {
        let fixture = try makeFixture(try AccountFixtures.snapshot("pending"))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let sections = fixture.controller.buildPage(.accounts, form: SettingsForm(width: 768))
        let shown = texts(sections)

        #expect(shown.contains("Waiting for sign-in in your browser…"))
        #expect(shown.contains("Open Sign-in Page"))
        #expect(shown.contains("Cancel"))
        #expect(shown.contains("Keychain: could not store the login in \"Soprano Claude Code Accounts\"."))
        #expect(shown.contains("Dismiss"))
        #expect(buttons(sections, titled: "Add Account").allSatisfy { !$0.isEnabled })
        #expect(buttons(sections, titled: "Re-authenticate").allSatisfy { !$0.isEnabled })

        buttons(sections, titled: "Cancel").first?.onClick?()
        buttons(sections, titled: "Dismiss").first?.onClick?()
        #expect(fixture.source.snapshot.pendingLogin == nil)
        #expect(fixture.source.snapshot.errors.isEmpty)
    }

    @Test func anEmptySnapshotShowsSignedOutDefaults() throws {
        let fixture = try makeFixture(AccountFixtures.empty())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let shown = texts(fixture.controller.buildPage(.accounts, form: SettingsForm(width: 768)))

        #expect(shown.filter { $0 == "Not signed in" }.count == 2)
        #expect(shown.filter { $0 == "Balance by usage" }.count == 2)
        #expect(!shown.contains("Re-authenticate"))
    }

    @Test func listsThatNeverLoadedSaySo() throws {
        let fixture = try makeFixture(AccountsSnapshot())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let shown = texts(fixture.controller.buildPage(.accounts, form: SettingsForm(width: 768)))

        #expect(shown.filter { $0 == "Accounts not loaded yet." }.count == AccountListID.all.count)
        #expect(shown.contains("Not updated yet"))
    }

    @Test func theUsageCardShowsEveryLoginGroupedByProviderAndFollowsChanges() throws {
        let card = UsageCardContent(snapshot: AccountFixtures.demo())
        let shown = texts([card])

        #expect(shown.contains("CLAUDE"))
        #expect(shown.contains("CODEX"))
        #expect(shown.contains("omp · automatic"))
        #expect(shown.contains("System default — ada@example.com"))
        #expect(shown.contains("93%"))
        #expect(!shown.contains("No accounts yet."))

        var refreshing = AccountFixtures.empty()
        refreshing.isRefreshing = true
        card.render(refreshing)
        #expect(texts([card]).contains("No accounts yet."))
        #expect(texts([card]).contains("Refreshing…"))
    }
}
