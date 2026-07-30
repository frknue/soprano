import AppKit
import Testing
@testable import Soprano

struct WindowBarSettingsTests {
    @Test func theWindowBarRemainsVisibleByDefault() {
        #expect(AppSettings.defaultSettings.hideWindowBar == false)
        #expect(ResolvedConfig.defaults.settings.hideWindowBar == false)
    }

    @Test func theFileCanHideAndRestoreTheWindowBar() {
        var config = SopranoConfig.empty
        config.hideWindowBar = true
        #expect(config.resolved().settings.hideWindowBar == true)

        var base = AppSettings.defaultSettings
        base.hideWindowBar = true
        config.hideWindowBar = false
        #expect(config.resolved(baseSettings: base).settings.hideWindowBar == false)
    }

    @Test func aLegacyStoredPayloadKeepsTheWindowBarVisible() throws {
        let legacy = """
        {"restoreLastSession":false,"themeId":"nord","projectDirectories":[]}
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

        #expect(decoded.hideWindowBar == false)
        #expect(decoded.restoreLastSession == false)
        #expect(decoded.themeId == "nord")
    }

    @Test func theTemplateDocumentsTheOptInSetting() {
        let template = ConfigFile.template(
            settings: .defaultSettings,
            keybindings: DefaultKeybindings.config
        )

        #expect(template.contains("\"hideWindowBar\": false"))
        #expect(template.contains("Off by default"))
    }
}

@MainActor
struct MainWindowAppearanceTests {
    @Test func hidingAndRestoringTheWindowBarPreservesTheFrame() {
        let frame = NSRect(x: 160, y: 120, width: 1200, height: 800)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = contentView
        window.setFrame(frame, display: false)

        MainWindowAppearance.apply(hideWindowBar: true, to: window)

        #expect(!window.styleMask.contains(.titled))
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(contentView.safeAreaInsets.top == 0)
        #expect(window.frame == frame)

        MainWindowAppearance.apply(hideWindowBar: false, to: window)

        #expect(window.styleMask.contains(.titled))
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(contentView.safeAreaInsets.top > 0)
        #expect(window.frame == frame)
    }
}
