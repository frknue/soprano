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
        let generalButton = allSubviews(in: contentViewController.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "General" }
        #expect(generalButton != nil)
        #expect(generalButton?.isHidden == false)
        #expect(generalButton?.frame.width ?? 0 > 0)
        #expect(generalButton?.frame.height ?? 0 > 0)
        // Cards cap at the 680pt card column instead of stretching across a
        // wide window; anything past ~600 proves layout settled.
        let appearanceCard = cardContainingLabel(
            "Appearance",
            in: contentViewController.view
        )
        #expect(appearanceCard?.frame.width ?? 0 > 600)
        #expect(appearanceCard?.frame.width ?? 0 < 700)

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
        #expect(navigationCard?.frame.width ?? 0 > 600)
        #expect(navigationCard?.frame.width ?? 0 < 700)

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

        // Not recording, the same Esc reaches Done and closes Settings.
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

    private func cardContainingLabel(_ text: String, in view: NSView) -> NSView? {
        // Section titles render as uppercase eyebrows in the margin column;
        // the card is the nearest rounded, hairline-edged view beside them.
        let label = allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == text.uppercased() }
        var ancestor = label?.superview
        while let current = ancestor {
            if let card = current.subviews.first(where: {
                $0.layer?.cornerRadius == Chrome.Radius.card && $0.layer?.borderWidth == Chrome.hairline
            }) {
                return card
            }
            ancestor = current.superview
        }
        return nil
    }
}
