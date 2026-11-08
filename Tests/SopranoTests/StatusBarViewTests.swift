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

    @Test func theBarHasNoBrandOrMissionClockAndShowsTheModePillCountsAndKeyHints() throws {
        let manager = AgentManager()
        let statusBar = makeStatusBar(manager: manager)
        let texts = descendants(of: statusBar, as: NSTextField.self).map(\.stringValue)
        #expect(!texts.contains("SOPRANO"))
        #expect(!texts.contains { $0.hasPrefix("T+") })

        // A quiet pill in title case: no uppercase status words.
        let mode = try #require(descendants(of: statusBar, as: DashStatusModeView.self).first)
        #expect(mode.displayedText == "Normal")
        statusBar.setKeybindingMode(.prefix)
        #expect(mode.displayedText == "Prefix")
        statusBar.setKeybindingMode(.copy)
        #expect(mode.displayedText == "Copy")
        statusBar.setKeybindingMode(.copySelection)
        #expect(mode.displayedText == "Select")

        #expect(label("status-counts", in: statusBar)?.stringValue == "1 session · 1 window · 1 pane")
        #expect(label("status-counts", in: statusBar)?.font?.pointSize == Typography.smallSize)
        // The caps follow settings.json, so read the expected chords from it.
        let keybindings = ConfigStore.shared.keybindings
        let palette = keybindings.bindings.first { $0.id == "command-palette" }
            .map { MainWindowController.keycaps(for: $0, prefixKey: keybindings.prefixKey) } ?? []
        let groups = hintGroups(in: statusBar)
        #expect(groups.map(\.caps) == [palette, ["⌃" + keybindings.prefixKey.uppercased()]].filter { !$0.isEmpty })
        // One Agents `KbdView` per cap.
        #expect(groups.allSatisfy { descendants(of: $0, as: KbdView.self).count == $0.caps.count })
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

    @Test func theUsageCardHostsTheAccountsCardAsAgentsPopoverContentThatEscapeCloses() throws {
        let content = DashUsageCardContent(themeManager: ThemeManager(themeId: "folio-paper"))
        content.layoutSubtreeIfNeeded()
        #expect(content.subviews.first === content.controller.view)
        #expect(content.fittingSize.width == AccountUsagePopoverViewController.width)
        var closed = false
        content.requestClose = { closed = true }
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        #expect(content.handleKey(escape))
        #expect(closed)
    }

    /// Hints left out of the bar are detached, so only shown groups are found.
    private func hintGroups(in statusBar: StatusBarView) -> [DashStatusHintView] {
        descendants(of: statusBar, as: DashStatusHintView.self)
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
