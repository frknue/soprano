import AppKit
import Testing
@testable import Soprano

@MainActor
struct SettingsWindowTransitionTests {
    @Test func openingAndClosingSettingsPreservesTheRealMainContentFrame() async throws {
        let suiteName = "SettingsWindowTransitionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let agentManager = AgentManager()
        let themeManager = ThemeManager(themeId: "gruvbox-dark")
        let contentViewController = MainContentViewController(
            agentManager: agentManager,
            sessionManager: SessionManager(
                agentManager: agentManager,
                defaults: defaults
            ),
            themeManager: themeManager,
            gitBranchMonitor: GitBranchMonitor(),
            splitTreeViewFactory: { agentManager, themeManager in
                SplitTreeView(
                    agentManager: agentManager,
                    themeManager: themeManager,
                    terminalViewFactory: { _, _, _ in NSView() }
                )
            }
        )
        let originalFrame = NSRect(x: 200, y: 140, width: 1800, height: 1000)
        let window = NSWindow(
            contentRect: originalFrame,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        window.setFrame(originalFrame, display: false)

        contentViewController.showSettings(
            settings: .defaultSettings,
            keybindingConfig: DefaultKeybindings.config
        )
        await waitForDeferredAppKitLayout()

        #expect(window.frame == originalFrame)
        let generalItem = navItem("General", in: contentViewController.view)
        #expect(generalItem != nil)
        #expect(generalItem?.isHidden == false)
        #expect(generalItem?.frame.width ?? 0 > 0)
        #expect(generalItem?.frame.height ?? 0 > 0)
        // Sections cap at the 768 pt page column instead of stretching across
        // a wide window.
        let appearanceGroup = sectionGroup("Appearance", in: contentViewController.view)
        #expect(appearanceGroup?.frame.width == SettingsViewController.pageMaxWidth)

        #expect(navItem("Keyboard Shortcuts", in: contentViewController.view)?.accessibilityPerformPress() == true)
        await waitForDeferredAppKitLayout()

        #expect(window.frame == originalFrame)
        let navigationGroup = sectionGroup("Navigation", in: contentViewController.view)
        #expect(navigationGroup?.frame.width == SettingsViewController.pageMaxWidth)

        let userResizedFrame = NSRect(
            x: 260,
            y: 180,
            width: 900,
            height: 650
        )
        window.setFrame(userResizedFrame, display: false)
        await waitForDeferredAppKitLayout()

        // The card keeps 32 pt clear of each window edge and the page column
        // narrows with it.
        #expect(window.frame == userResizedFrame)
        let cardWidth = userResizedFrame.width - SettingsOverlayView.margin * 2
        #expect(sectionGroup("Navigation", in: contentViewController.view)?.frame.width
            == SettingsViewController.pageWidth(for: cardWidth))

        contentViewController.closeSettings()
        await waitForDeferredAppKitLayout()

        #expect(window.frame == userResizedFrame)
    }

    @Test func escWhileRecordingThePrefixEndsTheRecordingAndKeepsSettingsOpen() async throws {
        let suiteName = "SettingsPrefixEscTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let agentManager = AgentManager()
        let themeManager = ThemeManager(themeId: "gruvbox-dark")
        let contentViewController = MainContentViewController(
            agentManager: agentManager,
            sessionManager: SessionManager(agentManager: agentManager, defaults: defaults),
            themeManager: themeManager,
            gitBranchMonitor: GitBranchMonitor(),
            splitTreeViewFactory: { agentManager, themeManager in
                SplitTreeView(
                    agentManager: agentManager,
                    themeManager: themeManager,
                    terminalViewFactory: { _, _, _ in NSView() }
                )
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 140, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        contentViewController.showSettings(
            settings: .defaultSettings,
            keybindingConfig: DefaultKeybindings.config
        )
        await waitForDeferredAppKitLayout()

        let prefix = try #require(
            allSubviews(in: contentViewController.view)
                .compactMap { $0 as? NSControl }
                .first { $0.accessibilityLabel() == "Prefix key" }
        )
        #expect(prefix.accessibilityPerformPress())
        #expect(window.firstResponder === prefix)
        #expect(prefix.accessibilityValue() as? String == "⌃…")

        let esc = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        #expect(window.performKeyEquivalent(with: esc))

        #expect(prefix.window === window)
        #expect(prefix.accessibilityValue() as? String == "⌃A")

        // Not recording, the same Esc reaches the overlay and closes Settings.
        #expect(window.performKeyEquivalent(with: esc))
        #expect(prefix.window == nil)
    }

    private func waitForDeferredAppKitLayout() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                continuation.resume()
            }
        }
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(in:))
    }

    /// Esc in the shortcut filter clears a typed query first; the next Esc
    /// closes the screen.
    @Test func escInTheShortcutFilterClearsTheQueryBeforeClosing() async throws {
        let suiteName = "SettingsFilterEscTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let agentManager = AgentManager()
        let contentViewController = MainContentViewController(
            agentManager: agentManager,
            sessionManager: SessionManager(agentManager: agentManager, defaults: defaults),
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            gitBranchMonitor: GitBranchMonitor(),
            splitTreeViewFactory: { agentManager, themeManager in
                SplitTreeView(
                    agentManager: agentManager,
                    themeManager: themeManager,
                    terminalViewFactory: { _, _, _ in NSView() }
                )
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 140, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        contentViewController.showSettings(settings: .defaultSettings, keybindingConfig: DefaultKeybindings.config)
        #expect(navItem("Keyboard Shortcuts", in: contentViewController.view)?.accessibilityPerformPress() == true)
        await waitForDeferredAppKitLayout()

        let filter = try #require(allSubviews(in: contentViewController.view)
            .compactMap { $0 as? NSTextField }
            .first { $0.identifier == SettingsViewController.filterIdentifier })
        #expect(window.makeFirstResponder(filter))
        filter.currentEditor()?.insertText("split")
        await waitForDeferredAppKitLayout()
        #expect(sectionGroup("Navigation", in: contentViewController.view) == nil)
        #expect(sectionGroup("Layout & splits", in: contentViewController.view) != nil)

        let esc = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
        #expect(window.performKeyEquivalent(with: esc))
        #expect(contentViewController.isShowingSettings)
        #expect(sectionGroup("Navigation", in: contentViewController.view) != nil)

        #expect(window.performKeyEquivalent(with: esc))
        #expect(!contentViewController.isShowingSettings)
    }

    private func navItem(_ title: String, in view: NSView) -> SettingsNavItem? {
        allSubviews(in: view)
            .compactMap { $0 as? SettingsNavItem }
            .first { $0.accessibilityLabel() == title }
    }

    /// The grouped card under a section title (16 pt semibold).
    private func sectionGroup(_ title: String, in view: NSView) -> SettingsGroupView? {
        let label = allSubviews(in: view)
            .compactMap { $0 as? SettingsLabel }
            .first { $0.stringValue == title && $0.font?.pointSize == 16 }
        var ancestor = label?.superview
        while let current = ancestor {
            if let group = current.subviews.compactMap({ $0 as? SettingsGroupView }).first {
                return group
            }
            ancestor = current.superview
        }
        return nil
    }
}
