import AppKit
import Testing
@testable import SopranoAgents

@MainActor
struct KeymapTests {
    private func command(_ id: String, scopes: Set<FocusRegion> = [], keys: [String]) -> AppCommand {
        AppCommand(id: id, title: id, category: .app, scopes: scopes, defaultKeys: keys, perform: { _ in })
    }

    private var commands: [AppCommand] {
        [
            command("palette.open", keys: ["cmd+k", "prefix+k"]),
            command("view.toggleSidebar", keys: ["cmd+b", "b"]),
            command("timeline.next", scopes: [.timeline], keys: ["j"]),
            command("sidebar.next", scopes: [.sidebar], keys: ["j"]),
        ]
    }

    private func resolve(_ overrides: [String: BindingOverride], commands: [AppCommand]? = nil) -> Keymap {
        Keymap.resolve(commands: commands ?? self.commands, settings: KeybindingSettings(overrides: overrides))
    }

    /// Every default binding of docs/ARCHITECTURE.md, with the scope each module declares.
    /// Shell's own commands come from `ShellCommands.all`; the rest stand in for other modules.
    private static let notTerminal: Set<FocusRegion> = [.sidebar, .timeline, .composer, .rightPanel]
    private static var otherModulesDefaults: [(id: String, scopes: Set<FocusRegion>, keys: [String])] {
        var table: [(String, Set<FocusRegion>, [String])] = [
            ("chat.new", notTerminal, ["cmd+n", "cmd+shift+o"]),
            ("chat.newLocal", notTerminal, ["cmd+shift+n"]),
            ("chat.newWithoutProject", notTerminal, ["cmd+ctrl+n"]),
            ("project.add", [], []),
            ("thread.previous", [], ["cmd+shift+["]),
            ("thread.next", [], ["cmd+shift+]"]),
            ("thread.settle", notTerminal, ["cmd+shift+s"]),
            ("thread.pin", notTerminal, ["cmd+shift+p"]),
            // F2 is no KeyChord (no function keys); the sidebar handles it directly, like T3 Code's
            // hard-coded F2 rename.
            ("thread.rename", [.sidebar], []),
            ("thread.archive", [], []),
            ("thread.delete", [], []),
            ("thread.copyReference", notTerminal, ["cmd+shift+c"]),
            ("sidebar.search", [], []),
            ("chat.find", notTerminal, ["cmd+f"]),
            ("timeline.jumpToLatest", [.timeline], ["cmd+down"]),
            ("composer.focus", [], ["cmd+l"]),
            ("modelPicker.toggle", notTerminal, ["cmd+shift+m"]),
            ("composer.effort", notTerminal, ["cmd+shift+e"]),
            ("composer.mode", notTerminal, ["cmd+shift+a"]),
            ("composer.workspace", notTerminal, ["cmd+shift+x"]),
            ("composer.branch", notTerminal, ["cmd+shift+g"]),
            ("composer.togglePlan", [.composer], ["shift+tab"]),
            ("composer.sendAlternate", [.composer], ["cmd+enter"]),
            ("thread.stop", [], []),
            ("diff.toggle", notTerminal, ["cmd+d"]),
            ("terminal.new", [.terminal], ["cmd+n"]),
            ("terminal.close", [.terminal], ["cmd+w"]),
            ("editor.openFavorite", [], ["cmd+o"]),
            ("git.commit", [], []),
            ("git.push", [], []),
            ("git.createPR", [], []),
        ]
        for index in 1...9 {
            table.append(("thread.jump.\(index)", [], ["cmd+\(index)"]))
        }
        return table
    }

    @Test func theDefaultBindingTableResolvesWithoutWarningsOrConflicts() {
        let others = Self.otherModulesDefaults.map { command($0.id, scopes: $0.scopes, keys: $0.keys) }
        let keymap = Keymap.resolve(commands: ShellCommands.all + others, settings: KeybindingSettings())

        #expect(keymap.issues.map(\.message) == [])
        #expect(keymap.conflictingIDs.isEmpty)
        #expect(keymap.chords(for: "palette.open").map(\.canonicalString) == ["cmd+k"])
        #expect(keymap.chords(for: "settings.open").first?.keycaps(prefixKey: "a") == ["⌘,"])
        #expect(keymap.chords(for: "view.toggleRightPanel").first?.keycaps(prefixKey: "a") == ["⌃⌘B"])
    }

    @Test func shellCommandsCarryTheDocumentedDefaultKeys() {
        let expected: [String: [String]] = [
            "palette.open": ["cmd+k"],
            "settings.open": ["cmd+,"],
            "settings.openFile": [],
            "view.toggleSidebar": ["cmd+b"],
            "view.toggleThreadDetails": ["cmd+shift+b"],
            "view.toggleTerminal": ["cmd+j"],
            "view.toggleRightPanel": ["cmd+ctrl+b"],
        ]
        let actual = Dictionary(uniqueKeysWithValues: ShellCommands.all.map { ($0.id, $0.defaultKeys) })
        #expect(actual == expected)
    }

    @Test func defaultsComeFromTheRegisteredCommands() {
        let keymap = resolve([:])
        #expect(keymap.chords(for: "palette.open").map(\.canonicalString) == ["cmd+k", "prefix+k"])
        #expect(keymap.issues.isEmpty)
    }

    @Test func aStringOverrideReplacesEveryDefaultChord() {
        let keymap = resolve(["palette.open": .chords(["cmd+shift+k"])])
        #expect(keymap.chords(for: "palette.open").map(\.canonicalString) == ["cmd+shift+k"])
        #expect(keymap.customizedIDs == ["palette.open"])
    }

    @Test func anArrayOverrideBindsSeveralChords() {
        let keymap = resolve(["view.toggleSidebar": .chords(["cmd+shift+l", "s", "prefix+b"])])
        #expect(keymap.chords(for: "view.toggleSidebar").map(\.canonicalString) == ["cmd+shift+l", "s", "prefix+b"])
    }

    @Test func nullUnbindsTheCommand() {
        let keymap = resolve(["view.toggleSidebar": .disabled])
        #expect(keymap.chords(for: "view.toggleSidebar").isEmpty)
        #expect(keymap.issues.isEmpty)
    }

    @Test func anUnknownCommandIDIsAWarning() {
        let keymap = resolve(["thread.teleport": .chords(["cmd+y"])])
        #expect(keymap.issues.map(\.message) == ["keybindings.bindings: unknown command \"thread.teleport\"."])
        #expect(keymap.issues.allSatisfy { $0.severity == .warning })
    }

    @Test func aBadChordIsAWarningAndKeepsTheDefaults() {
        let keymap = resolve(["palette.open": .chords(["alt+k"])])
        #expect(keymap.chords(for: "palette.open").map(\.canonicalString) == ["cmd+k", "prefix+k"])
        #expect(keymap.issues.map(\.message) == ["keybindings.bindings.palette.open: \"alt+k\" is not a valid chord."])
    }

    @Test func aPartlyBadListKeepsItsValidChords() {
        let keymap = resolve(["palette.open": .chords(["cmd+shift+k", "hyper+k"])])
        #expect(keymap.chords(for: "palette.open").map(\.canonicalString) == ["cmd+shift+k"])
        #expect(keymap.issues.count == 1)
    }

    @Test func twoGlobalCommandsOnOneChordConflict() {
        let keymap = resolve(["palette.open": .chords(["cmd+b"])])
        #expect(keymap.issues.count == 1)
        #expect(keymap.issues.first?.message.contains("\"view.toggleSidebar\" and \"palette.open\"") == true)
        #expect(keymap.conflictingIDs == ["view.toggleSidebar", "palette.open"])
    }

    @Test func overlappingScopesConflictButARegionOverAGlobalBindingDoesNot() {
        // timeline.next "j" (timeline) vs sidebar.next "j" (sidebar): disjoint → fine.
        // view.toggleSidebar "b" (global) vs a timeline-scoped "b": region beats global → fine.
        var commands = commands
        commands.append(command("timeline.branch", scopes: [.timeline], keys: ["b"]))
        #expect(resolve([:], commands: commands).issues.isEmpty)
        #expect(resolve([:], commands: commands).conflictingIDs.isEmpty)

        let conflicting = resolve([:], commands: commands + [
            command("timeline.down", scopes: [.timeline, .composer], keys: ["j"]),
        ])
        #expect(conflicting.issues.map(\.message) == [
            "\"timeline.down\" and \"timeline.next\" are both bound to J in timeline; only \"timeline.next\" will fire.",
        ])
    }

    @Test func symbolChordsConflictRegardlessOfShift() {
        let keymap = resolve([:], commands: [
            command("help.shortcuts", keys: ["?"]),
            command("other", keys: ["shift+?"]),
        ])
        #expect(keymap.issues.count == 1)
    }

    @Test func bindingThePrefixChordItselfIsAWarning() {
        let keymap = resolve(["palette.open": .chords(["ctrl+a"])])
        #expect(keymap.issues.count == 1)
        #expect(keymap.issues.first?.message.contains("prefix key") == true)
        #expect(keymap.conflictingIDs == ["palette.open"])
    }

    @Test func settingsCenterMergesRegistryDefaultsWithOverridesForDisplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sa-keymap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = CommandRegistry()
        registry.register(commands)
        let center = SettingsCenter(fileURL: directory.appendingPathComponent("settings.json"), registry: registry)
        center.apply(text: """
        { "keybindings": { "prefixKey": "b", "bindings": { "palette.open": ["prefix+shift+k", "cmd+k"], "view.toggleSidebar": null } } }
        """)

        #expect(center.shortcutText(for: "palette.open") == "Prefix → Shift+K")
        #expect(center.keycaps(for: "palette.open") == ["⌃B", "⇧K"])
        #expect(center.keycaps(for: "view.toggleSidebar") == nil)
        #expect(center.keycaps(for: "timeline.next") == ["J"])
        #expect(center.chords(for: "palette.open").count == 2)
        #expect(center.keymap.prefixKey == "b")
    }

    @Test func keycapsShowOneCapPerChordAndPrefixSequencesAsSeparateCaps() throws {
        let cases: [(String, [String])] = [
            ("cmd+b", ["⌘B"]), ("cmd+shift+o", ["⇧⌘O"]), ("cmd+1", ["⌘1"]), ("cmd+ctrl+b", ["⌃⌘B"]),
            ("cmd+,", ["⌘,"]), ("cmd+enter", ["⌘↵"]), ("shift+tab", ["⇧⇥"]), ("cmd+down", ["⌘↓"]),
            ("prefix+p", ["⌃A", "P"]), ("prefix+shift+s", ["⌃A", "⇧S"]), ("j", ["J"]), ("escape", ["esc"]),
        ]
        for (text, expected) in cases {
            #expect(try #require(KeyChord.parse(text)).keycaps(prefixKey: "a") == expected, "\(text)")
        }
    }
}
