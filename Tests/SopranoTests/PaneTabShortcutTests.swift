import AppKit
import Testing
@testable import Soprano

@MainActor
struct PaneTabShortcutTests {
    /// `KeybindingManager.filter` looks up the event's window through `NSApp`.
    init() {
        _ = NSApplication.shared
    }

    @Test func controlCommandTArrowsAndWOpenCycleAndCloseTabsInsideTheFocusedSplitOnly() throws {
        let manager = AgentManager()
        let leftPaneId = manager.activePaneId
        let rightPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: leftPaneId))
        let keybindings = KeybindingManager(agentManager: manager, config: DefaultKeybindings.config)
        let right = try #require(manager.panes[rightPaneId])
        #expect(manager.activePaneId == rightPaneId)

        #expect(keybindings.filter(try chord("t", keyCode: 17)) == nil)
        #expect(keybindings.filter(try chord("t", keyCode: 17)) == nil)
        #expect(right.tabs.count == 3)
        #expect(right.activeTabIndex == 2)
        #expect(manager.panes[leftPaneId]?.tabs.count == 1)

        #expect(keybindings.filter(try arrow(.left)) == nil)
        #expect(right.activeTabIndex == 1)
        #expect(keybindings.filter(try arrow(.right)) == nil)
        #expect(keybindings.filter(try arrow(.right)) == nil)
        #expect(right.activeTabIndex == 0)

        let closedTabId = try #require(right.activeTab?.id)
        #expect(keybindings.filter(try chord("w", keyCode: 13)) == nil)
        #expect(right.tabs.count == 2)
        #expect(!right.tabs.contains { $0.id == closedTabId })
        #expect(manager.panes[leftPaneId]?.tabs.count == 1)
    }

    @Test func commandWAndPrefixXCloseOnlyTheActivePaneTabUntilTheLastOneTakesThePane() throws {
        let manager = AgentManager()
        let leftPaneId = manager.activePaneId
        let rightPaneId = try #require(manager.splitPane(direction: .horizontal, paneId: leftPaneId))
        _ = try #require(manager.addTabToPane(rightPaneId, type: .terminal))
        _ = try #require(manager.addTabToPane(rightPaneId, type: .terminal))
        let keybindings = KeybindingManager(agentManager: manager, config: DefaultKeybindings.config)
        let right = try #require(manager.panes[rightPaneId])
        #expect(right.tabs.count == 3)

        let commandW = try keyEvent("w", [.command], keyCode: 13)
        let firstClosed = try #require(right.activeTab?.id)
        #expect(keybindings.filter(commandW) == nil)
        #expect(manager.panes[rightPaneId] != nil)
        #expect(right.tabs.count == 2)
        #expect(!right.tabs.contains { $0.id == firstClosed })

        let secondClosed = try #require(right.activeTab?.id)
        #expect(keybindings.filter(try keyEvent("a", [.control], keyCode: 0)) == nil)
        #expect(keybindings.filter(try keyEvent("x", [], keyCode: 7)) == nil)
        #expect(manager.panes[rightPaneId] != nil)
        #expect(right.tabs.count == 1)
        #expect(!right.tabs.contains { $0.id == secondClosed })

        #expect(keybindings.filter(commandW) == nil)
        #expect(manager.panes[rightPaneId] == nil)
        #expect(manager.panes[leftPaneId]?.tabs.count == 1)
    }

    @Test func controlArrowWithoutCommandStillReachesTheTerminal() throws {
        let manager = AgentManager()
        let paneId = manager.activePaneId
        _ = try #require(manager.addTabToPane(paneId, type: .terminal))
        let keybindings = KeybindingManager(agentManager: manager, config: DefaultKeybindings.config)

        // ⌃→ (word jump, Spaces) goes on to the terminal untouched.
        let controlRight = try keyEvent(
            String(UnicodeScalar(NSRightArrowFunctionKey)!),
            [.control, .function, .numericPad],
            keyCode: 124
        )
        #expect(keybindings.filter(controlRight) === controlRight)
        #expect(manager.panes[paneId]?.activeTabIndex == 1)
    }

    private enum Direction { case left, right }

    private func arrow(_ direction: Direction) throws -> NSEvent {
        let scalar = direction == .left ? NSLeftArrowFunctionKey : NSRightArrowFunctionKey
        return try keyEvent(
            String(UnicodeScalar(scalar)!),
            [.control, .command, .function, .numericPad],
            keyCode: direction == .left ? 123 : 124
        )
    }

    private func chord(_ key: String, keyCode: UInt16) throws -> NSEvent {
        try keyEvent(key, [.control, .command], keyCode: keyCode)
    }

    private func keyEvent(_ key: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
        ))
    }
}
