import AppKit

/// A modal surface over the main window, like T3 Code's dialogs, command palette and settings
/// route modal: a borderless child window covering the parent with a dimmed backdrop
/// (`dialog-backdrop`) and one card on it. Child windows (not sheets or `NSPopover`) so the
/// snapshot harness renders them with the window.
///
/// Keys reach `keyHandler` before the focused view (and before menu key equivalents), so the
/// owner handles ↑ ↓ ↩ Esc and ⌘ chords while a text field keeps everything else.
@MainActor
final class OverlayWindow: NSWindow {
    /// Called with every key press while the overlay is key; return true when handled.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Called after the overlay closed (any path).
    var onClose: (() -> Void)?
    /// The controller driving the overlay, kept alive while it shows.
    var owner: AnyObject?

    let backdrop: OverlayBackdropView
    private weak var hostWindow: NSWindow?
    private var parentObservers: [NSObjectProtocol] = []
    private(set) var isClosing = false

    init() {
        backdrop = OverlayBackdropView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = backdrop
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The parent may sit outside every screen (snapshot harness); follow it there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Covers `parent` and takes the keyboard. Fades in unless Reduce Motion is on.
    func present(over parent: NSWindow, focus responder: NSResponder? = nil) {
        hostWindow = parent
        appearance = parent.appearance
        setFrame(parent.frame, display: false)
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

    /// The topmost visible overlay over `window`.
    static func topmost(over window: NSWindow?) -> OverlayWindow? {
        window?.childWindows?.compactMap { $0 as? OverlayWindow }.last { $0.isVisible && !$0.isClosing }
    }
}

/// T3 Code's `dialog-backdrop`: the window dimmed with the background at 60 % (dark 64 %).
/// Clicks outside the card land here.
final class OverlayBackdropView: PaletteView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.withAlphaComponent(palette.isDark ? 0.64 : 0.6).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The card of an overlay (`dialog-glass … rounded-2xl border`): rounded fill and a 1 pt
/// border, with the dialog shadow `0 24px 64px -24px rgb(0 0 0 / 65%)` drawn by a companion
/// view behind it (drawn content, so the snapshot harness renders it too). Content goes into
/// `content`, which clips to the corners.
final class OverlayCardView: PaletteView {
    enum Surface {
        /// `bg-background` (dialogs, settings).
        case background
        /// `bg-popover` (command palette).
        case popover
    }

    let content = ClippingView()
    private let surface: Surface
    private let radius: CGFloat
    private var shadowView: OverlayShadowView?

    init(surface: Surface = .background, radius: CGFloat = Radius.xxl) {
        self.surface = surface
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
        let shadow = OverlayShadowView(radius: radius)
        shadow.translatesAutoresizingMaskIntoConstraints = false
        superview.addSubview(shadow, positioned: .below, relativeTo: self)
        let inset = OverlayShadowView.inset
        NSLayoutConstraint.activate([
            shadow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -inset),
            shadow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: inset),
            shadow.topAnchor.constraint(equalTo: topAnchor, constant: -inset),
            shadow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: inset),
        ])
        shadowView = shadow
    }

    override func applyPalette(_ palette: Palette) {
        let fill = surface == .popover ? palette.popover : palette.background
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (palette.isDark ? NSColor.white.withAlphaComponent(0.08) : palette.foreground.withAlphaComponent(0.1)).cgColor
    }
}

/// Draws the card's drop shadow around a rounded rect `inset` points inside its bounds.
final class OverlayShadowView: PaletteView {
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
final class ClippingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}

extension NSLayoutConstraint.Priority {
    /// Preferred card sizes: below the window's "stay put" priority (500), so a card never
    /// grows its overlay window past the main window.
    static let overlayPreferred = NSLayoutConstraint.Priority(450)
}
