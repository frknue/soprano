import AppKit
import Testing
@testable import Soprano

@MainActor
struct StatusBarViewTests {
    @Test func uptimeIsOptInAndReadsHoursMinutesAndSeconds() throws {
        #expect(StatusBarView.uptimeText(0) == "Up 0:00:00")
        #expect(StatusBarView.uptimeText(2 * 3600 + 14 * 60 + 7) == "Up 2:14:07")
        #expect(StatusBarView.uptimeText(123 * 3600) == "Up 123:00:00")

        let statusBar = makeStatusBar(manager: AgentManager())
        #expect(label("status-uptime", in: statusBar) == nil)
        statusBar.showsUptime = true
        let uptime = try #require(label("status-uptime", in: statusBar))
        #expect(uptime.stringValue.hasPrefix("Up "))
        statusBar.showsUptime = false
        #expect(label("status-uptime", in: statusBar) == nil)
    }

    @Test func theBarHasNoBrandOrMissionClockAndShowsTheModeChipCountsAndKeyHints() throws {
        let manager = AgentManager()
        let statusBar = makeStatusBar(manager: manager)
        let texts = descendants(of: statusBar, as: NSTextField.self).map(\.stringValue)
        #expect(!texts.contains("SOPRANO"))
        #expect(!texts.contains { $0.hasPrefix("T+") })

        let chip = try #require(descendants(of: statusBar, as: ChromeModeChip.self).first)
        #expect(chip.displayedText == "NORMAL")
        statusBar.setKeybindingMode(.prefix)
        #expect(chip.displayedText == "PREFIX")

        #expect(label("status-counts", in: statusBar)?.stringValue == "1 session · 1 window · 1 pane")
        // The caps follow settings.json, so read the expected chords from it.
        let keybindings = ConfigStore.shared.keybindings
        let palette = keybindings.bindings.first { $0.id == "command-palette" }
            .map { MainWindowController.keycaps(for: $0, prefixKey: keybindings.prefixKey) } ?? []
        let groups = hintGroups(in: statusBar)
        #expect(groups.map(\.caps) == [palette, ["⌃" + keybindings.prefixKey.uppercased()]].filter { !$0.isEmpty })
        #expect(groups.allSatisfy { $0.style == .small && $0.tone == .muted })
    }

    @Test func thePaletteHintFollowsPrefixBindingsShiftInferenceAndRemoval() {
        let statusBar = makeStatusBar(manager: AgentManager())
        var config = DefaultKeybindings.config
        config.prefixKey = "b"
        let index = config.bindings.firstIndex { $0.id == "command-palette" }!
        let palette = config.bindings[index]

        // A prefix binding is the prefix cap, then the key.
        config.bindings[index] = KeyBinding(
            id: palette.id, label: palette.label, description: palette.description,
            category: palette.category, defaultKeys: "Prefix → P", mode: .prefix, key: "p"
        )
        statusBar.refreshKeyHints(config)
        #expect(hintGroups(in: statusBar).map(\.caps) == [["⌃B", "P"], ["⌃B"]])

        // Shift that the key needs anyway is not drawn; special keys get legends.
        config.bindings[index] = KeyBinding(
            id: palette.id, label: palette.label, description: palette.description,
            category: palette.category, defaultKeys: "⌘|", mode: .direct, key: "|", meta: true, shift: true
        )
        statusBar.refreshKeyHints(config)
        #expect(hintGroups(in: statusBar).first?.caps == ["⌘|"])

        // A disabled palette binding drops its hint.
        config.bindings.remove(at: index)
        statusBar.refreshKeyHints(config)
        #expect(hintGroups(in: statusBar).map(\.caps) == [["⌃B"]])
    }

    /// Hints left out of the bar are detached, so only shown groups are found.
    private func hintGroups(in statusBar: StatusBarView) -> [ChromeKeycapGroupView] {
        descendants(of: statusBar, as: ChromeKeycapGroupView.self)
    }

    private func makeStatusBar(manager: AgentManager) -> StatusBarView {
        let statusBar = StatusBarView(agentManager: manager, themeManager: ThemeManager(themeId: "folio-paper"))
        statusBar.frame = NSRect(x: 0, y: 0, width: 1200, height: StatusBarView.height)
        statusBar.layoutSubtreeIfNeeded()
        return statusBar
    }

    private func label(_ identifier: String, in view: NSView) -> NSTextField? {
        descendants(of: view, as: NSTextField.self).first { $0.identifier?.rawValue == identifier }
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { subview in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: subview, as: type)
        }
    }
}
