import AppKit
import Testing
@testable import Soprano

@MainActor
struct MenuBarSwitcherTests {
    private struct Fixture {
        let switcher: MenuBarSwitcher
        let sopranoMenu: NSMenu
        let agentsMenu: NSMenu
        let sopranoWindow: NSWindow
        let agentsWindow: NSWindow
    }

    private func makeFixture() -> Fixture {
        let sopranoMenu = NSMenu(title: "Soprano")
        let agentsMenu = NSMenu(title: "Agents")
        let sopranoWindow = Self.window()
        let agentsWindow = Self.window()
        let switcher = MenuBarSwitcher(soprano: .init(menu: sopranoMenu)) { window in
            if window === agentsWindow { return .agents }
            if window === sopranoWindow { return .soprano }
            return nil
        }
        switcher.start()
        switcher.setAgentsBar(.init(menu: agentsMenu))
        return Fixture(
            switcher: switcher,
            sopranoMenu: sopranoMenu,
            agentsMenu: agentsMenu,
            sopranoWindow: sopranoWindow,
            agentsWindow: agentsWindow
        )
    }

    private static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func eachWindowBringsItsOwnMenuBarWhenItBecomesKey() {
        let fixture = makeFixture()

        fixture.switcher.windowBecameKey(fixture.agentsWindow)
        #expect(NSApp.mainMenu === fixture.agentsMenu)
        #expect(fixture.switcher.current == .agents)

        fixture.switcher.windowBecameKey(fixture.sopranoWindow)
        #expect(NSApp.mainMenu === fixture.sopranoMenu)
        #expect(fixture.switcher.current == .soprano)
    }

    @Test func aPanelHangingOffTheAgentsWindowKeepsTheAgentsMenuBar() {
        let fixture = makeFixture()
        let palette = Self.window()
        fixture.agentsWindow.addChildWindow(palette, ordered: .above)
        defer { fixture.agentsWindow.removeChildWindow(palette) }

        fixture.switcher.windowBecameKey(fixture.sopranoWindow)
        fixture.switcher.windowBecameKey(palette)

        #expect(MenuBarSwitcher.rootWindow(of: palette) === fixture.agentsWindow)
        #expect(NSApp.mainMenu === fixture.agentsMenu)
    }

    @Test func aWindowThatBelongsToNeitherLeavesTheMenuBarAlone() {
        let fixture = makeFixture()
        fixture.switcher.windowBecameKey(fixture.agentsWindow)

        fixture.switcher.windowBecameKey(Self.window())

        #expect(NSApp.mainMenu === fixture.agentsMenu)
        #expect(fixture.switcher.current == .agents)
    }

    @Test func aRebuiltAgentsMenuBarReplacesTheShownOneAtOnce() {
        let fixture = makeFixture()
        fixture.switcher.windowBecameKey(fixture.agentsWindow)
        let rebuilt = NSMenu(title: "Agents, rebound")

        fixture.switcher.setAgentsBar(.init(menu: rebuilt))

        #expect(NSApp.mainMenu === rebuilt)
    }

    @Test func aRebuiltAgentsMenuBarWaitsWhileTheTerminalWindowIsKey() {
        let fixture = makeFixture()
        fixture.switcher.windowBecameKey(fixture.sopranoWindow)

        fixture.switcher.setAgentsBar(.init(menu: NSMenu(title: "Agents, rebound")))

        #expect(NSApp.mainMenu === fixture.sopranoMenu)
    }

    @Test func closingTheAgentsWindowHandsTheMenuBarBackEvenWhenNoWindowBecomesKey() {
        // Soprano's own window may be minimized: then nothing becomes key after the close,
        // and the Agents bar must not stay behind acting on a closed window.
        let fixture = makeFixture()
        fixture.switcher.windowBecameKey(fixture.agentsWindow)

        fixture.switcher.windowWillClose(fixture.agentsWindow)

        #expect(NSApp.mainMenu === fixture.sopranoMenu)
        #expect(fixture.switcher.current == .soprano)
    }
}
