import AppKit

// Soprano Agents' modal surface (`Shell/OverlayWindow.swift`) and alert dialogs
// (`Shell/Dialogs.swift`), ported for every Soprano dialog: confirmations, notices,
// name prompts, the unsaved-changes question, the clipboard confirmation and the
// Automations editor's card.

/// A modal surface over the main window: a borderless child window covering the parent with a
/// dimmed backdrop (`dialog-backdrop`) and one card on it.
///
/// Keys reach `keyHandler` before the focused view (and before menu key equivalents), so the
/// owner handles Return, Esc and ⌘ chords while a text field keeps everything else.
@MainActor
final class ShellDialogOverlayWindow: NSWindow {
    /// Called with every key press while the overlay is key; return true when handled.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Called after the overlay closed (any path).
    var onClose: (() -> Void)?
    /// The controller driving the overlay, kept alive while it shows.
    var owner: AnyObject?

    let backdrop: ShellDialogBackdropView
    private(set) weak var hostWindow: NSWindow?
    private var parentObservers: [NSObjectProtocol] = []
    private(set) var isClosing = false

    init() {
        backdrop = ShellDialogBackdropView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = backdrop
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The parent may sit outside every screen; follow it there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    /// The dialog's own chords first, then its controls'. Every other chord stops here instead
    /// of reaching the main menu, so ⌘P or ⇧⌘D cannot open the palette or the dashboard behind
    /// an open dialog. Editing chords still go on to the Edit menu, which sends them to the
    /// dialog's focused field, and quitting or hiding Soprano still works.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, keyHandler?(event) == true { return true }
        if super.performKeyEquivalent(with: event) { return true }
        return attachedSheet == nil && !Self.passesToMenu(event)
    }

    /// Chords the main menu keeps while a dialog shows: cut, copy, paste, select all, undo,
    /// redo, and quit or hide the app.
    static func passesToMenu(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch modifiers {
        case .command: return ["x", "c", "v", "a", "z", "q", "h"].contains(key)
        case [.command, .shift]: return key == "z"
        case [.command, .option]: return key == "h"
        default: return false
        }
    }

    /// Sizes the overlay to `parent` and lays its card out, without showing it.
    func cover(_ parent: NSWindow) {
        hostWindow = parent
        appearance = PaletteCenter.shared.palette.appearance
        setFrame(parent.frame, display: false)
        backdrop.layoutSubtreeIfNeeded()
    }

    /// Covers `parent` and takes the keyboard. Fades in unless Reduce Motion is on.
    func present(over parent: NSWindow, focus responder: NSResponder? = nil) {
        cover(parent)
        parent.addChildWindow(self, ordered: .above)
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            parentObservers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followParent() }
            })
        }
        if Motion.reduceMotion {
            alphaValue = 1
        } else {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.fade
                animator().alphaValue = 1
            }
        }
        makeKeyAndOrderFront(nil)
        if let responder { makeFirstResponder(responder) }
    }

    private func followParent() {
        guard let hostWindow else { return }
        setFrame(hostWindow.frame, display: true)
    }

    /// Removes the overlay and gives the keyboard back to the parent.
    func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        keyHandler = nil
        for observer in parentObservers { NotificationCenter.default.removeObserver(observer) }
        parentObservers = []
        let parent = hostWindow
        parent?.removeChildWindow(self)
        orderOut(nil)
        if let parent, parent.isVisible { parent.makeKeyAndOrderFront(nil) }
        onClose?()
        onClose = nil
        owner = nil
    }
}

/// The dialog backdrop: the window dimmed with the background at 60 % (dark 64 %).
/// Clicks outside the card land here; clicks on card space no control handles travel up the
/// responder chain to here too and are ignored.
final class ShellDialogBackdropView: PaletteView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.withAlphaComponent(palette.isDark ? 0.64 : 0.6).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        let point = superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard hitTest(point) === self else { return }
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The card of an overlay (`dialog-glass … rounded-2xl border`): rounded fill and a 1 pt
/// border, with the dialog shadow `0 24px 64px -24px rgb(0 0 0 / 65%)` drawn by a companion
/// view behind it. Content goes into `content`, which clips to the corners.
final class ShellDialogCardView: PaletteView {
    let content = ShellDialogClippingView()
    private let radius: CGFloat
    private var shadowView: ShellDialogShadowView?

    init(radius: CGFloat = Radius.xxl) {
        self.radius = radius
        super.init(frame: .zero)
        layer?.cornerRadius = radius
        content.layer?.cornerRadius = radius
        content.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyPalette(palette)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        shadowView?.removeFromSuperview()
        shadowView = nil
        guard let superview else { return }
        let shadow = ShellDialogShadowView(radius: radius)
        shadow.translatesAutoresizingMaskIntoConstraints = false
        superview.addSubview(shadow, positioned: .below, relativeTo: self)
        let inset = ShellDialogShadowView.inset
        NSLayoutConstraint.activate([
            shadow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -inset),
            shadow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: inset),
            shadow.topAnchor.constraint(equalTo: topAnchor, constant: -inset),
            shadow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: inset),
        ])
        shadowView = shadow
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = palette.foreground.withAlphaComponent(palette.isDark ? 0.08 : 0.1).cgColor
    }
}

/// Draws the card's drop shadow around a rounded rect `inset` points inside its bounds.
final class ShellDialogShadowView: PaletteView {
    static let inset: CGFloat = 80
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = palette.isDark
        context.saveGState()
        // Flipped view: positive y moves the shadow down.
        context.setShadow(
            offset: CGSize(width: 0, height: 18),
            blur: dark ? 56 : 44,
            color: NSColor.black.withAlphaComponent(dark ? 0.7 : 0.28).cgColor
        )
        let card = bounds.insetBy(dx: Self.inset + 12, dy: Self.inset + 12)
        context.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }
}

/// A flipped, layer-backed container that clips its subviews to its rounded layer.
final class ShellDialogClippingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}

/// `border-t bg-muted/72` strip under a dialog's body, holding its buttons.
final class ShellDialogFooterView: PaletteView {
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

extension NSLayoutConstraint.Priority {
    /// Preferred card sizes: below the window's "stay put" priority (500), so a card never
    /// grows its overlay window past the main window.
    static let shellDialogPreferred = NSLayoutConstraint.Priority(450)
}

// MARK: - Dialogs

/// A button of a `ShellDialogs` dialog, styled as alert-dialog buttons.
struct ShellDialogButton: Equatable {
    enum Style: Equatable {
        case primary
        case outline
        case destructive
        case destructiveOutline
    }

    var title: String
    var style: Style
    /// A shortcut besides Return and Esc (`d` with `.command` for Don't Save). In the
    /// system-alert fallback it is the button's key equivalent, so Esc (`"\u{1b}"`, no
    /// modifiers) there picks a cancel button not titled Cancel.
    var keyEquivalent: String
    var keyModifiers: NSEvent.ModifierFlags

    init(_ title: String, style: Style = .outline, keyEquivalent: String = "", keyModifiers: NSEvent.ModifierFlags = []) {
        self.title = title
        self.style = style
        self.keyEquivalent = keyEquivalent
        self.keyModifiers = keyModifiers
    }

    var isDestructive: Bool { style == .destructive || style == .destructiveOutline }
}

/// What a dialog shows.
struct ShellDialogContent {
    struct Field {
        var placeholder: String
        var initialValue: String
    }

    var title: String
    var message: String
    /// In display order (left to right); the last one is the default (Return).
    var buttons: [ShellDialogButton]
    /// A one-line text input under the message.
    var field: Field?
    /// A view under the message (and field), as wide as the card's text.
    var accessory: NSView?

    init(title: String, message: String, buttons: [ShellDialogButton], field: Field? = nil, accessory: NSView? = nil) {
        self.title = title
        self.message = message
        self.buttons = buttons
        self.field = field
        self.accessory = accessory
    }
}

struct ShellDialogResult: Equatable {
    /// The chosen button, nil when cancelled (Esc, a click outside).
    var index: Int?
    /// The text input's value, empty without one.
    var text: String = ""

    /// A prompt's answer: the trimmed text on confirm (the last button), nil on cancel or
    /// when empty.
    var promptValue: String? {
        guard let index, index > 0 else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Every Soprano dialog. Each call presents an alert dialog over `window` (a child window with
/// a dimmed backdrop and a centered card). Return picks the last button, Escape or a click
/// outside cancels. Without a window it falls back to the main window; when that is not on
/// screen (closed, minimized, hidden), to a plain `NSAlert`.
///
/// The plain calls answer through a completion; the `…Modally` ones block in a modal session on
/// the overlay for callers that need the answer before they return.
@MainActor
enum ShellDialogs {
    /// Two-button confirm ("Delete X?"). Calls `completion` with true on confirm.
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = false,
        in window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        choose(
            title: title,
            message: message,
            buttons: confirmButtons(confirmTitle, isDestructive: isDestructive),
            in: window
        ) { completion($0 == 1) }
    }

    static func alert(title: String, message: String, in window: NSWindow?, completion: (() -> Void)? = nil) {
        choose(title: title, message: message, buttons: [ShellDialogButton("OK", style: .primary)], in: window) { _ in
            completion?()
        }
    }

    /// Several buttons in display order (left to right); `completion` gets the chosen index,
    /// nil on Escape. The last button is the default (Return). Returns the shown dialog, nil
    /// when the answer came from the system-alert fallback already.
    @discardableResult
    static func choose(
        title: String,
        message: String,
        buttons: [ShellDialogButton],
        accessory: NSView? = nil,
        in window: NSWindow?,
        completion: @escaping (Int?) -> Void
    ) -> ShellDialogController? {
        present(
            ShellDialogContent(title: title, message: message, buttons: buttons, accessory: accessory),
            in: window
        ) { completion($0.index) }
    }

    /// Single-line text input with Cancel and `confirmTitle`; the field starts with
    /// `initialValue` selected. `completion` gets the trimmed text, nil on cancel or when empty.
    static func prompt(
        title: String,
        message: String,
        placeholder: String = "",
        initialValue: String = "",
        confirmTitle: String = "OK",
        in window: NSWindow?,
        completion: @escaping (String?) -> Void
    ) {
        present(
            promptContent(title: title, message: message, placeholder: placeholder, initialValue: initialValue, confirmTitle: confirmTitle),
            in: window
        ) { completion($0.promptValue) }
    }

    /// `choose`, answered before it returns.
    static func chooseModally(
        title: String,
        message: String,
        buttons: [ShellDialogButton],
        in window: NSWindow?
    ) -> Int? {
        let content = ShellDialogContent(title: title, message: message, buttons: buttons)
        guard let host = host(for: window) else { return fallback(content).index }
        return ShellDialogController(content: content).runModal(over: host).index
    }

    /// `confirm`, answered before it returns.
    static func confirmModally(
        title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = false,
        in window: NSWindow?
    ) -> Bool {
        chooseModally(title: title, message: message, buttons: confirmButtons(confirmTitle, isDestructive: isDestructive), in: window) == 1
    }

    /// `alert`, returning once it is dismissed.
    static func alertModally(title: String, message: String, in window: NSWindow?) {
        _ = chooseModally(title: title, message: message, buttons: [ShellDialogButton("OK", style: .primary)], in: window)
    }

    // MARK: - Presentation

    static func promptContent(title: String, message: String, placeholder: String, initialValue: String, confirmTitle: String) -> ShellDialogContent {
        ShellDialogContent(
            title: title,
            message: message,
            buttons: [ShellDialogButton("Cancel"), ShellDialogButton(confirmTitle, style: .primary)],
            field: ShellDialogContent.Field(placeholder: placeholder, initialValue: initialValue)
        )
    }

    private static func confirmButtons(_ confirmTitle: String, isDestructive: Bool) -> [ShellDialogButton] {
        [ShellDialogButton("Cancel"), ShellDialogButton(confirmTitle, style: isDestructive ? .destructive : .primary)]
    }

    @discardableResult
    private static func present(
        _ content: ShellDialogContent,
        in window: NSWindow?,
        completion: @escaping (ShellDialogResult) -> Void
    ) -> ShellDialogController? {
        guard let host = host(for: window) else {
            completion(fallback(content))
            return nil
        }
        let controller = ShellDialogController(content: content, completion: completion)
        controller.present(over: host)
        return controller
    }

    /// The window to present over; nil (a plain `NSAlert`) when it is closed, minimized or
    /// hidden, so a dialog raised late never pops up a backdrop of its own.
    static func host(for window: NSWindow?) -> NSWindow? {
        let candidate = window ?? NSApp.mainWindow ?? NSApp.windows.first { $0 is MainWindow && $0.isVisible }
        // Present over the main window even when called with one of its overlays.
        let host = (candidate as? ShellDialogOverlayWindow).map { $0.hostWindow ?? $0 } ?? candidate
        return host?.isVisible == true ? host : nil
    }

    /// The system alert standing in when no window is on screen.
    private static func fallback(_ content: ShellDialogContent) -> ShellDialogResult {
        let alert = NSAlert()
        alert.messageText = content.title
        alert.informativeText = content.message
        // NSAlert lays buttons out right to left; the first added is the default.
        for button in content.buttons.reversed() {
            let added = alert.addButton(withTitle: button.title)
            added.hasDestructiveAction = button.isDestructive
            if !button.keyEquivalent.isEmpty {
                added.keyEquivalent = button.keyEquivalent
                added.keyEquivalentModifierMask = button.keyModifiers
            }
        }
        var field: NSTextField?
        if let spec = content.field {
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            input.placeholderString = spec.placeholder
            input.stringValue = spec.initialValue
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            field = input
        } else if let accessory = content.accessory {
            let width = ShellDialogController.width - 48
            accessory.frame = NSRect(x: 0, y: 0, width: width, height: max(accessory.fittingSize.height, 24))
            alert.accessoryView = accessory
        }
        let offset = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let count = content.buttons.count
        let index = offset >= 0 && offset < count ? count - 1 - offset : nil
        return ShellDialogResult(index: index, text: field?.stringValue ?? "")
    }
}

/// The alert dialog: `max-w-lg` card centered over the backdrop; header `p-6 gap-2`
/// (title, muted description, optional input and accessory), footer
/// `border-t bg-muted/72 px-6 py-4` with the buttons right-aligned. Return = last button,
/// Escape or a click outside = cancel.
@MainActor
final class ShellDialogController {
    static let width: CGFloat = 512

    let window = ShellDialogOverlayWindow()
    let content: ShellDialogContent
    /// The text input of a prompt.
    private(set) var input: AutoUIInputField?
    private var completion: ((ShellDialogResult) -> Void)?
    private var isRunningModal = false

    init(content: ShellDialogContent, completion: ((ShellDialogResult) -> Void)? = nil) {
        self.content = content
        self.completion = completion
        build()
    }

    /// Shows the dialog over `parent`; it answers through the completion.
    func present(over parent: NSWindow) {
        window.owner = self
        window.present(over: parent, focus: input?.field)
        input?.field.currentEditor()?.selectAll(nil)
    }

    /// Shows the dialog over `parent` and blocks in a modal session on the overlay until a
    /// button, Return, Esc or a click outside answers it. `session` runs that session (tests
    /// answer inside it instead).
    func runModal(
        over parent: NSWindow,
        session: (ShellDialogOverlayWindow) -> Void = { window in
            // Asked while Soprano is in the background (quitting from the Dock): come forward.
            if !NSApp.isActive { NSApp.activate() }
            _ = NSApp.runModal(for: window)
        }
    ) -> ShellDialogResult {
        var answer = ShellDialogResult(index: nil)
        let previous = completion
        completion = { result in
            answer = result
            previous?(result)
        }
        isRunningModal = true
        present(over: parent)
        session(window)
        isRunningModal = false
        // A session that ended some other way cancels.
        finish(index: nil)
        // The parent cannot take the keyboard back while the session still runs.
        if parent.isVisible, !parent.isKeyWindow { parent.makeKeyAndOrderFront(nil) }
        return answer
    }

    private func build() {
        let card = ShellDialogCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        window.backdrop.addSubview(card)
        let maxWidth = card.widthAnchor.constraint(equalToConstant: Self.width)
        maxWidth.priority = .shellDialogPreferred
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: window.backdrop.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: window.backdrop.centerYAnchor),
            maxWidth,
            card.widthAnchor.constraint(lessThanOrEqualTo: window.backdrop.widthAnchor, constant: -32),
        ])
        let container = card.content

        let titleLabel = AutoUIThemedLabel(content.title, size: 16, weight: .semibold, wrapping: true)
        let messageLabel = AutoUIThemedLabel(content.message, wrapping: true) { $0.mutedForeground }
        messageLabel.isSelectable = true

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        header.addArrangedSubview(titleLabel)
        if !content.message.isEmpty { header.addArrangedSubview(messageLabel) }
        for label in [titleLabel, messageLabel] {
            label.preferredMaxLayoutWidth = Self.width - 48
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        if let spec = content.field {
            let field = AutoUIInputField(value: spec.initialValue, placeholder: spec.placeholder)
            field.onCommand = { [weak self] selector in
                guard let self, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
                finish(index: content.buttons.count - 1)
                return true
            }
            addBodyView(field, to: header)
            input = field
        }
        if let accessory = content.accessory {
            addBodyView(accessory, to: header)
        }

        let footer = ShellDialogFooterView()
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        for (index, spec) in content.buttons.enumerated() {
            let variant: TextButton.Variant = switch spec.style {
            case .primary: .primary
            case .outline: .outline
            case .destructive: .destructive
            case .destructiveOutline: .destructiveOutline
            }
            let button = TextButton(spec.title, variant: variant, size: .regular)
            button.onClick = { [weak self] in self?.finish(index: index) }
            row.addArrangedSubview(button)
        }

        for view in [header, footer, row] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        container.addSubview(header)
        container.addSubview(footer)
        footer.addSubview(row)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: header.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.topAnchor.constraint(equalTo: footer.topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -16),
            row.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor, constant: 24),
        ])

        window.backdrop.onClick = { [weak self] in self?.finish(index: nil) }
        window.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
    }

    /// A full-width view under the header's text, 16 pt below it.
    private func addBodyView(_ view: NSView, to header: NSStackView) {
        if let last = header.arrangedSubviews.last { header.setCustomSpacing(16, after: last) }
        view.translatesAutoresizingMaskIntoConstraints = false
        header.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -48).isActive = true
    }

    /// Return picks the last button, Esc cancels, a button's own shortcut picks it.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, flags.isEmpty {
            finish(index: nil)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76, flags.isEmpty {
            finish(index: content.buttons.count - 1)
            return true
        }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if !flags.isEmpty, let index = content.buttons.firstIndex(where: {
            !$0.keyEquivalent.isEmpty && $0.keyEquivalent.lowercased() == key && $0.keyModifiers == flags
        }) {
            finish(index: index)
            return true
        }
        return false
    }

    /// Closes with the chosen button index (nil = cancelled).
    func finish(index: Int?) {
        guard let completion else { return }
        self.completion = nil
        let text = input?.stringValue ?? ""
        if isRunningModal, NSApp.modalWindow === window { NSApp.stopModal() }
        window.dismiss()
        completion(ShellDialogResult(index: index, text: text))
    }
}
