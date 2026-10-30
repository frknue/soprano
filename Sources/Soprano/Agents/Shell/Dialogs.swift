import AppKit

/// A button of a `Dialogs.choose` dialog, styled as alert-dialog buttons.
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

/// The only modal UI. Every call presents an alert dialog over `window` (a child window
/// with a dimmed backdrop and a centered card) and resolves when the user answers. Return picks
/// the last button, Escape or a click outside cancels. Without a window it falls back to the
/// app's main window, then to a plain `NSAlert`. Shell owns the presentation; other modules call these.
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
        guard let host = host(for: window) else {
            return fallbackChoose(title: title, message: message, buttons: buttons)
        }
        let result = await present(DialogContent(title: title, message: message, buttons: buttons, field: nil), over: host)
        return result.index
    }

    /// Single-line text input. Returns the trimmed text, nil on cancel or when empty.
    static func prompt(title: String, message: String, placeholder: String = "", initialValue: String = "", confirmTitle: String = "OK", in window: NSWindow?) async -> String? {
        let buttons = [DialogButton("Cancel"), DialogButton(confirmTitle, style: .primary)]
        let field = DialogContent.Field(placeholder: placeholder, initialValue: initialValue)
        let result: DialogResult
        if let host = host(for: window) {
            result = await present(DialogContent(title: title, message: message, buttons: buttons, field: field), over: host)
        } else {
            result = fallbackPrompt(title: title, message: message, field: field, confirmTitle: confirmTitle)
        }
        guard result.index == 1 else { return nil }
        let value = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func alert(title: String, message: String, in window: NSWindow?) async {
        _ = await choose(title: title, message: message, buttons: [DialogButton("OK", style: .primary)], in: window)
    }

    // MARK: - Presentation

    private static func host(for window: NSWindow?) -> NSWindow? {
        let candidate = window ?? NSApp.mainWindow ?? NSApp.windows.first { $0 is MainWindow && $0.isVisible }
        // Present over the main window even when called with one of its overlays.
        if let overlay = candidate as? OverlayWindow { return overlay.parent ?? overlay }
        return candidate
    }

    private static func present(_ content: DialogContent, over parent: NSWindow) async -> DialogResult {
        await withCheckedContinuation { continuation in
            let controller = DialogController(content: content) { result in
                continuation.resume(returning: result)
            }
            controller.present(over: parent)
        }
    }

    private static func fallbackChoose(title: String, message: String, buttons: [DialogButton]) -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        // NSAlert lays buttons out right to left; the first added is the default.
        for button in buttons.reversed() {
            let added = alert.addButton(withTitle: button.title)
            added.hasDestructiveAction = button.style == .destructive || button.style == .destructiveOutline
        }
        let offset = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard offset >= 0, offset < buttons.count else { return nil }
        return buttons.count - 1 - offset
    }

    private static func fallbackPrompt(title: String, message: String, field spec: DialogContent.Field, confirmTitle: String) -> DialogResult {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = spec.placeholder
        field.stringValue = spec.initialValue
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        return DialogResult(index: confirmed ? 1 : nil, text: field.stringValue)
    }
}

/// What a dialog shows.
struct DialogContent {
    struct Field {
        var placeholder: String
        var initialValue: String
    }

    var title: String
    var message: String
    var buttons: [DialogButton]
    var field: Field?
}

struct DialogResult {
    var index: Int?
    var text: String = ""
}

/// The alert dialog: `max-w-lg` card centered over the backdrop; header `p-6 gap-2`
/// (title, muted description, optional input), footer `border-t bg-muted/72 px-6 py-4` with the
/// buttons right-aligned. Return = last button, Escape = cancel.
@MainActor
final class DialogController {
    let content: DialogContent
    private let window = OverlayWindow()
    private var completion: ((DialogResult) -> Void)?
    private var input: InputField?

    static let width: CGFloat = 512

    init(content: DialogContent, completion: @escaping (DialogResult) -> Void) {
        self.content = content
        self.completion = completion
    }

    func present(over parent: NSWindow) {
        window.owner = self
        let card = OverlayCardView(surface: .background)
        card.translatesAutoresizingMaskIntoConstraints = false
        window.backdrop.addSubview(card)
        let maxWidth = card.widthAnchor.constraint(equalToConstant: Self.width)
        maxWidth.priority = .overlayPreferred
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: window.backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: window.backdrop.centerYAnchor),
            maxWidth,
            card.widthAnchor.constraint(lessThanOrEqualTo: window.backdrop.widthAnchor, constant: -32),
        ])
        build(in: card.content)

        window.backdrop.onClick = { [weak self] in self?.finish(index: nil) }
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        window.present(over: parent, focus: input?.field)
        if let input {
            input.field.currentEditor()?.selectAll(nil)
        }
    }

    private func build(in container: NSView) {
        let title = ThemedLabel(content.title, size: 16, weight: .semibold, wrapping: true)
        let message = ThemedLabel(content.message, wrapping: true) { $0.mutedForeground }
        message.isSelectable = true

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        header.addArrangedSubview(title)
        if !content.message.isEmpty { header.addArrangedSubview(message) }
        if let spec = content.field {
            let field = InputField(value: spec.initialValue, placeholder: spec.placeholder)
            header.setCustomSpacing(16, after: header.arrangedSubviews.last!)
            header.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -48).isActive = true
            field.onCommand = { [weak self] selector in
                guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
                self?.finish(index: (self?.content.buttons.count ?? 1) - 1)
                return true
            }
            input = field
        }
        for label in [title, message] {
            label.preferredMaxLayoutWidth = Self.width - 48
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        let footer = DialogFooterView()
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for (index, spec) in content.buttons.enumerated() {
            let button = TextButton(spec.title, variant: variant(spec.style), size: .regular)
            button.onClick = { [weak self] in self?.finish(index: index) }
            buttons.addArrangedSubview(button)
        }

        for view in [header, footer, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(header)
        container.addSubview(footer)
        footer.addSubview(buttons)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: header.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.topAnchor.constraint(equalTo: footer.topAnchor, constant: 16),
            buttons.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor, constant: 24),
        ])
    }

    private func variant(_ style: DialogButton.Style) -> TextButton.Variant {
        switch style {
        case .primary: .primary
        case .outline: .outline
        case .destructive: .destructive
        case .destructiveOutline: .destructiveOutline
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let stroke = KeyStroke(event: event) else { return false }
        let plain = !stroke.ctrl && !stroke.meta && !stroke.option
        if stroke.key == "\u{1B}", plain {
            finish(index: nil)
            return true
        }
        if stroke.key == "\r", plain, !stroke.shift {
            finish(index: content.buttons.count - 1)
            return true
        }
        return false
    }

    /// Closes with the chosen button index (nil = cancelled).
    func finish(index: Int?) {
        guard let completion else { return }
        self.completion = nil
        let text = input?.stringValue ?? ""
        window.dismiss()
        completion(DialogResult(index: index, text: text))
    }
}

/// `border-t bg-muted/72` strip under the dialog body.
private final class DialogFooterView: PaletteView {
    private let rule = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(rule)
        applyPalette(palette)
    }

    override func layout() {
        super.layout()
        rule.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.foreground.withAlphaComponent(palette.isDark ? 0.03 : 0.025).cgColor
        rule.backgroundColor = palette.border.cgColor
    }
}
