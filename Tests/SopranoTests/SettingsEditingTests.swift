import AppKit
import Testing
@testable import Soprano

@MainActor
struct SettingsEditingTests {
    @Test func keybindingFieldsSendActionsWhenEditingEndsWhileProjectAddRemainsExplicit() {
        let controller = SettingsViewController(
            themeManager: ThemeManager(themeId: "gruvbox-dark"),
            settings: .defaultSettings,
            keybindingConfig: DefaultKeybindings.config
        )

        let fields = editableTextFields(in: controller.view)
        let prefixField = fields.first { $0.stringValue == DefaultKeybindings.config.prefixKey }
        let timeoutField = fields.first {
            $0.stringValue == "\(DefaultKeybindings.config.prefixTimeoutMs)"
        }
        let resizeField = fields.first {
            $0.stringValue == "\(Int(DefaultKeybindings.config.resizeTickPercent))"
        }
        let projectAddField = fields.first { $0.placeholderString == "Folder path" }

        #expect(prefixField?.cell?.sendsActionOnEndEditing == true)
        #expect(timeoutField?.cell?.sendsActionOnEndEditing == true)
        #expect(resizeField?.cell?.sendsActionOnEndEditing == true)
        #expect(projectAddField?.cell?.sendsActionOnEndEditing == false)
        #expect(projectAddField?.target === controller)
        #expect(projectAddField?.action != nil)
    }

    private func editableTextFields(in view: NSView) -> [NSTextField] {
        let directFields = view.subviews.compactMap { $0 as? NSTextField }
            .filter(\.isEditable)
        return directFields + view.subviews.flatMap(editableTextFields(in:))
    }
}
