import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct SettingsScreenTests {
    private struct Fixture {
        let directory: URL
        let center: SettingsCenter
        let router: KeyboardRouter
        let controller: SettingsController
    }

    private func makeFixture() throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sa-screen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = CommandRegistry()
        registry.register([
            AppCommand(id: "palette.open", title: "Command Palette", category: .app, defaultKeys: ["cmd+k"], perform: { _ in }),
        ])
        let center = SettingsCenter(fileURL: directory.appendingPathComponent("settings.json"), registry: registry)
        center.start(watching: false)
        let router = KeyboardRouter(registry: registry, keymap: { center.keymap }, context: { nil })
        let parent = MainWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        parent.allowsOffscreenFrame = true
        parent.isReleasedWhenClosed = false
        let engine = try DemoFixtures.build("empty").engine
        let controller = SettingsController(engine: engine, center: center, parent: parent, router: router)
        return Fixture(directory: directory, center: center, router: router, controller: controller)
    }

    @Test func recordingAChordWritesItForTheCommandAndReleasesTheKeyboard() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.controller.startRecording("palette.open")
        #expect(fixture.router.capture != nil)
        fixture.router.capture?(KeyStroke(key: "p", meta: true, shift: true))

        #expect(fixture.router.capture == nil)
        #expect(fixture.controller.recordingCommandID == nil)
        #expect(fixture.center.keybindingSettings.overrides["palette.open"] == .chords(["cmd+shift+p"]))
        #expect(fixture.center.chords(for: "palette.open").map(\.canonicalString) == ["cmd+shift+p"])
    }

    @Test func aPrefixChordIsRecordedFromTwoPresses() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.controller.startRecording("palette.open")
        fixture.router.capture?(KeyStroke(key: "a", ctrl: true))
        #expect(fixture.controller.recordingPrompt == "⌃A … now the key")
        fixture.router.capture?(KeyStroke(key: "k"))

        #expect(fixture.center.keybindingSettings.overrides["palette.open"] == .chords(["prefix+k"]))
    }

    @Test func escapeCancelsRecordingWithoutWriting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.controller.startRecording("palette.open")
        fixture.router.capture?(KeyStroke(key: "\u{1B}"))

        #expect(fixture.router.capture == nil)
        #expect(fixture.center.keybindingSettings.overrides.isEmpty)
        #expect(fixture.center.chords(for: "palette.open").map(\.canonicalString) == ["cmd+k"])
    }

    @Test func keybindingFilterMatchesTitleIdAndShortcut() throws {
        let command = AppCommand(id: "view.toggleSidebar", title: "Toggle Sidebar", category: .view, defaultKeys: ["cmd+b"], perform: { _ in })
        let chords = try [#require(KeyChord.parse("cmd+b"))]
        for query in ["sidebar", "view.toggle", "⌘B", ""] {
            #expect(SettingsController.keybindingMatches(command, query: query, chords: chords, prefixKey: "a"), "\(query)")
        }
        #expect(!SettingsController.keybindingMatches(command, query: "terminal", chords: chords, prefixKey: "a"))
    }

    @Test func scopesReadAsPlaceNames() {
        #expect(SettingsController.scopeText([]) == nil)
        #expect(SettingsController.scopeText([.sidebar, .timeline, .composer, .rightPanel]) == "Not in terminal")
        #expect(SettingsController.scopeText([.composer]) == "In composer")
        #expect(SettingsController.scopeText([.terminal, .sidebar]) == "In sidebar, terminal")
    }
}
