import AppKit
import Testing
@testable import Soprano

struct AutomationConfigTests {
    private func resolve(_ json: String) -> ResolvedConfig {
        let config = try! JSONCText.decode(SopranoConfig.self, from: json)
        return config.resolved()
    }

    @Test func aCompleteEntryResolvesWithTheDefaultsItLeftOut() {
        let resolved = resolve("""
        {
          "automations": {
            "weekday-audit": {
              "name": "Weekday repo audit",
              "agent": "omp",
              "folder": "~/",
              "prompt": "  Review the repository.  ",
              "schedule": "0 9 * * 1-5"
            }
          }
        }
        """)

        #expect(resolved.issues.isEmpty)
        let automation = try! #require(resolved.automations.first)
        #expect(automation.id == "weekday-audit")
        #expect(automation.folder == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
        #expect(automation.prompt == "Review the repository.")
        #expect(automation.cadence == .weekdays(hour: 9, minute: 0))
        #expect(automation.enabled)
        #expect(automation.workspace == .folder)
        #expect(automation.session == .fresh)
        #expect(automation.graceMinutes == Automation.defaultGraceMinutes)
        #expect(automation.precheckTimeoutSeconds == Automation.defaultPrecheckTimeoutSeconds)
        #expect(automation.model == nil)
    }

    @Test func entriesMissingWhatARunNeedsAreLeftOutAndNamedInTheIssues() {
        let resolved = resolve("""
        {
          "automations": {
            "no-prompt": { "agent": "omp", "folder": "/tmp", "schedule": "0 9 * * *" },
            "no-folder": { "agent": "omp", "prompt": "x", "schedule": "0 9 * * *" },
            "no-agent": { "folder": "/tmp", "prompt": "x", "schedule": "0 9 * * *" },
            "bad-cron": { "agent": "omp", "folder": "/tmp", "prompt": "x", "schedule": "0 25 * * *" },
            "shell": { "agent": "terminal", "folder": "/tmp", "prompt": "x", "schedule": "0 9 * * *" }
          }
        }
        """)

        #expect(resolved.automations.isEmpty)
        #expect(resolved.issues.count == 5)
        for id in ["no-prompt", "no-folder", "no-agent", "bad-cron", "shell"] {
            #expect(resolved.issues.contains { $0.message.hasPrefix("automations.\(id):") })
        }
        #expect(resolved.issues.contains { $0.message.contains("25 is outside the hour range") })
    }

    @Test func reusingTheLastAgentCannotBeCombinedWithAWorktreeAndFallsBackToFresh() {
        let resolved = resolve("""
        {
          "automations": {
            "nightly": {
              "agent": "claude-code", "folder": "/tmp", "prompt": "x", "schedule": "0 2 * * *",
              "worktree": true, "session": "reuse"
            }
          }
        }
        """)

        let automation = try! #require(resolved.automations.first)
        #expect(automation.session == .fresh)
        #expect(automation.workspace == .worktree(baseBranch: nil))
        #expect(resolved.issues.count == 1)
    }

    @Test func anOutOfRangeGracePeriodFallsBackToTheDefaultWithAWarning() {
        let resolved = resolve("""
        {
          "automations": {
            "audit": { "agent": "omp", "folder": "/tmp", "prompt": "x", "schedule": "0 9 * * *", "graceMinutes": -5 }
          }
        }
        """)

        #expect(resolved.automations.first?.graceMinutes == Automation.defaultGraceMinutes)
        #expect(resolved.issues.count == 1)
    }

    @Test func automationsAreListedByName() {
        let resolved = resolve("""
        {
          "automations": {
            "a": { "name": "Zebra", "agent": "omp", "folder": "/tmp", "prompt": "x", "schedule": "0 9 * * *" },
            "b": { "name": "apple", "agent": "omp", "folder": "/tmp", "prompt": "x", "schedule": "0 9 * * *" }
          }
        }
        """)

        #expect(resolved.automations.map(\.name) == ["apple", "Zebra"])
    }

    @Test func aNewIdComesFromTheNameAndNeverCollidesWithAnExistingOne() {
        #expect(Automation.makeId(from: "Weekday repo audit!", existing: []) == "weekday-repo-audit")
        #expect(Automation.makeId(from: "Weekday repo audit", existing: ["weekday-repo-audit"]) == "weekday-repo-audit-2")
        #expect(Automation.makeId(from: "  ✨ ", existing: []) == "automation")
    }

    @MainActor
    @Test func anAutomationSavedFromTheAppReadsBackUnchangedAndLeavesTheRestOfTheFileAlone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-automation-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(fileURL: directory.appendingPathComponent("settings.json"))
        try ConfigFile.write("""
        {
          // keep me
          "theme": "nord"
        }
        """, to: store.fileURL)
        store.start(watching: false, seedSettings: .defaultSettings, seedKeybindings: DefaultKeybindings.config)

        let automation = Automation(
            id: "nightly",
            name: "Nightly review",
            agentId: "codex",
            folder: directory.path,
            prompt: "- Review yesterday's commits\n- List anything risky",
            schedule: try CronSchedule(parsing: "30 2 * * *"),
            enabled: false,
            workspace: .worktree(baseBranch: "origin/main"),
            session: .fresh,
            graceMinutes: 180,
            precheck: "git log --since=yesterday --oneline | grep -q .",
            precheckTimeoutSeconds: 30,
            model: "gpt-5.2"
        )
        #expect(store.write(automation.configObject, at: ["automations", automation.id]))

        #expect(store.text.contains("// keep me"))
        #expect(store.settings.themeId == "nord")
        #expect(store.resolved.automations == [automation])
    }
}
