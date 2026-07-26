import AppKit
import Testing
@testable import Soprano

/// A chime on every finished turn is the setting people disable once and never
/// re-enable, so silence is the default and the file has to be able to say so
/// in both directions.
struct NotificationSettingsTests {
    @Test func notificationSoundIsOffUntilItIsAskedFor() {
        #expect(AppSettings.defaultSettings.notificationSound == false)
        #expect(ResolvedConfig.defaults.settings.notificationSound == false)
    }

    @Test func theFileCanTurnTheSoundOn() {
        var config = SopranoConfig.empty
        config.notifications = .init(sound: true)

        let resolved = config.resolved()

        #expect(resolved.settings.notificationSound == true)
        #expect(resolved.issues.isEmpty)
    }

    @Test func theFileCanTurnTheSoundBackOffAgainstANonDefaultBase() {
        var base = AppSettings.defaultSettings
        base.notificationSound = true

        var config = SopranoConfig.empty
        config.notifications = .init(sound: false)

        #expect(config.resolved(baseSettings: base).settings.notificationSound == false)
    }

    @Test func omittingTheSectionLeavesWhateverTheBaseSaid() {
        var base = AppSettings.defaultSettings
        base.notificationSound = true

        #expect(SopranoConfig.empty.resolved(baseSettings: base).settings.notificationSound == true)
        #expect(SopranoConfig.empty.resolved().settings.notificationSound == false)
    }

    @Test func anEmptyNotificationsSectionIsNotAnError() {
        var config = SopranoConfig.empty
        config.notifications = .init(sound: nil)

        let resolved = config.resolved()

        #expect(resolved.settings.notificationSound == false)
        #expect(resolved.issues.isEmpty)
    }

    /// The stored payload predates this key. Decoding has to tolerate that, or
    /// the caller's `try?` throws away every other setting alongside it.
    @Test func settingsStoredBeforeTheKeyExistedStillDecode() throws {
        let legacy = """
        {"restoreLastSession":false,"themeId":"nord","projectDirectories":["/tmp"]}
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))

        #expect(decoded.restoreLastSession == false)
        #expect(decoded.themeId == "nord")
        #expect(decoded.projectDirectories == ["/tmp"])
        #expect(decoded.notificationSound == false)
    }

    @Test func aRoundTripThroughJSONKeepsTheSoundChoice() throws {
        var settings = AppSettings.defaultSettings
        settings.notificationSound = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded == settings)
    }

    /// Existing `settings.json` files have no `notifications` object at all, so
    /// the checkbox writes a nested key whose parent is missing. If that could
    /// not create the parent, the toggle would silently do nothing for every
    /// user who configured Soprano before this setting existed.
    @Test func togglingTheSoundWritesIntoAFileThatHasNoNotificationsSectionYet() throws {
        let existing = """
        {
          // A file written before notifications were configurable.
          "theme": "gruvbox-dark",
          "restoreLastSession": true
        }
        """

        let updated = try JSONCText.setting(true, at: ["notifications", "sound"], in: existing)

        #expect(updated.contains("\"notifications\""))
        #expect(updated.contains("\"sound\""))
        // The comment and the untouched keys have to survive the splice.
        #expect(updated.contains("// A file written before notifications were configurable."))
        #expect(updated.contains("\"theme\": \"gruvbox-dark\""))

        let decoded = try JSONCText.decode(SopranoConfig.self, from: updated)
        #expect(decoded.notifications?.sound == true)
        #expect(decoded.theme == "gruvbox-dark")
    }

    @Test func theTemplateDocumentsTheSettingANewUserWouldLookFor() {
        let template = ConfigFile.template(
            settings: .defaultSettings,
            keybindings: DefaultKeybindings.config
        )

        #expect(template.contains("\"notifications\""))
        #expect(template.contains("\"sound\": false"))
    }
}
