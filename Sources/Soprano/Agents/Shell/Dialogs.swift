import AppKit

/// A button of a `Dialogs.choose` dialog, styled like T3 Code's AlertDialog buttons.
struct DialogButton: Equatable {
    enum Style: Equatable {
        case primary
        case outline
        case destructive
        case destructiveOutline
    }

    var title: String
    var style: Style

    init(_ title: String, style: Style = .outline) {
        self.title = title
        self.style = style
    }
}

/// The only modal UI. Every call presents a sheet on `window` (centered panel when nil) and
/// resolves when the user answers. Shell owns the presentation; other modules call these.
@MainActor
enum Dialogs {
    /// Two-button confirm ("Delete thread "X"?"). Returns true on confirm.
    static func confirm(title: String, message: String, confirmTitle: String, isDestructive: Bool = false, in window: NSWindow?) async -> Bool {
        let index = await choose(
            title: title,
            message: message,
            buttons: [DialogButton("Cancel"), DialogButton(confirmTitle, style: isDestructive ? .destructive : .primary)],
            in: window
        )
        return index == 1
    }

    /// Several buttons in display order (left to right); returns the chosen index, nil on Escape.
    /// The last button is the default (Return).
    static func choose(title: String, message: String, buttons: [DialogButton], in window: NSWindow?) async -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        // NSAlert lays buttons out right to left; the first added is the default.
        for button in buttons.reversed() {
            let added = alert.addButton(withTitle: button.title)
            added.hasDestructiveAction = button.style == .destructive || button.style == .destructiveOutline
        }
        let response = await present(alert, in: window)
        let offset = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard offset >= 0, offset < buttons.count else { return nil }
        return buttons.count - 1 - offset
    }

    /// Single-line text input. Returns the trimmed text, nil on cancel.
    static func prompt(title: String, message: String, placeholder: String = "", initialValue: String = "", confirmTitle: String = "OK", in window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initialValue
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = await present(alert, in: window)
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func alert(title: String, message: String, in window: NSWindow?) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert, in: window)
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
