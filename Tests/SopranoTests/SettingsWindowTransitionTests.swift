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
            keybindingConfig: DefaultKeybindings.config,
            onSettingsChanged: { _ in },
            onKeybindingConfigChanged: { _ in }
        )
        await waitForDeferredAppKitLayout()

        #expect(window.frame == originalFrame)
        let generalButton = allSubviews(in: contentViewController.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "General" }
        #expect(generalButton != nil)
        #expect(generalButton?.isHidden == false)
        #expect(generalButton?.frame.width ?? 0 > 0)
        #expect(generalButton?.frame.height ?? 0 > 0)
        let appearanceCard = cardContainingLabel(
            "Appearance",
            in: contentViewController.view
        )
        #expect(appearanceCard?.frame.width ?? 0 > 900)

        let keyboardShortcutsButton = allSubviews(in: contentViewController.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "Keyboard Shortcuts" }
        keyboardShortcutsButton?.performClick(nil)
        await waitForDeferredAppKitLayout()

        #expect(window.frame == originalFrame)
        let navigationCard = cardContainingLabel(
            "Navigation",
            in: contentViewController.view
        )
        #expect(navigationCard?.frame.width ?? 0 > 900)

        let userResizedFrame = NSRect(
            x: 260,
            y: 180,
            width: 900,
            height: 650
        )
        window.setFrame(userResizedFrame, display: false)
        await waitForDeferredAppKitLayout()

        #expect(window.frame == userResizedFrame)
        #expect(navigationCard?.frame.width ?? 0 > 600)
        #expect(navigationCard?.frame.width ?? 0 < 800)

        contentViewController.closeSettings()
        await waitForDeferredAppKitLayout()

        #expect(window.frame == userResizedFrame)
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

    private func cardContainingLabel(_ text: String, in view: NSView) -> NSView? {
        let label = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == text }
        return label?.superview?.superview
    }
}
