import AppKit

/// Fonts by T3 Code's Tailwind size scale. The UI font is the system font (T3 Code's
/// `-apple-system` stack); code is SF Mono.
enum Typography {
    /// `text-sm` 14 pt: titles, body, assistant prose.
    static let bodySize: CGFloat = 14
    /// Thread details rows (`text-[13px]`).
    static let rowSize: CGFloat = 13
    /// `text-xs` 12 pt: meta lines, pills, buttons xs.
    static let smallSize: CGFloat = 12
    /// `text-2xs` 11 pt: kbd hints, undo notice.
    static let tinySize: CGFloat = 11
    /// Code blocks, command output, diffs.
    static let codeSize: CGFloat = 13
    static let terminalSize: CGFloat = 12

    static func ui(_ size: CGFloat = bodySize, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat = codeSize, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Tabular digits for live durations ("Working for 12s").
    static func tabular(_ size: CGFloat = bodySize, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

/// Geometry from T3 Code (`index.css` tokens, component classes). Points equal CSS px at the
/// default 16 px root.
enum Metrics {
    static let topbarHeight: CGFloat = 52
    static let titlebarControlSize: CGFloat = 28
    /// Space the traffic lights need at the sidebar's top-left.
    static let windowControlsInset: CGFloat = 90

    static let sidebarWidth: CGFloat = 256
    static let sidebarMinWidth: CGFloat = 208
    /// Chat column keeps at least this when the sidebar grows.
    static let mainMinWidth: CGFloat = 640

    /// `--chat-content-max-width` (46rem): timeline lane and composer.
    static let chatMaxWidth: CGFloat = 736
    static let gutter: CGFloat = 20
    static let threadDetailsWidth: CGFloat = 280

    static let rightPanelWidth: CGFloat = 540
    static let rightPanelMinWidth: CGFloat = 360

    static let terminalHeight: CGFloat = 280
    static let terminalMinHeight: CGFloat = 180

    /// Sidebar card row (Pinned / Active) and slim row (shelves).
    static let cardRowHeight: CGFloat = 78
    static let slimRowHeight: CGFloat = 36

    static let windowDefaultSize = NSSize(width: 1100, height: 780)
    static let windowMinSize = NSSize(width: 840, height: 620)
}

/// Corner radii (Tailwind: sm 4, md 6, lg 8, xl 12, 2xl 16).
enum Radius {
    static let sm: CGFloat = 4
    /// Sidebar card rows, tooltips.
    static let md: CGFloat = 6
    /// Buttons, menus, popovers, code blocks, changed-files card (`--control-radius`).
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
    /// Composer, user bubbles, dialogs, plan cards, thread details card.
    static let xxl: CGFloat = 16
}

/// Motion: T3 Code's popups fade/scale in 150–200 ms; panel width animation is off by default.
enum Motion {
    static let fade: TimeInterval = 0.15

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// SF Symbols standing in for T3 Code's lucide icons, named by the lucide original.
enum Icon {
    static let squarePen = "square.and.pencil"           // New thread
    static let folderPlus = "folder.badge.plus"          // Add project
    static let listFilter = "line.3.horizontal.decrease" // Project filter
    static let search = "magnifyingglass"
    static let settings = "gearshape"
    static let pin = "pin.fill"
    static let check = "checkmark"
    static let undo = "arrow.uturn.backward"
    static let chevronRight = "chevron.right"
    static let chevronDown = "chevron.down"
    static let sidebarLeft = "sidebar.left"
    static let squareMenu = "rectangle.topthird.inset.filled"    // Toggle thread details
    static let panelBottom = "rectangle.bottomthird.inset.filled" // Toggle terminal drawer
    static let panelRight = "sidebar.right"                       // Toggle right panel
    static let circleDashed = "circle.dashed"                      // Working
    static let shieldQuestion = "exclamationmark.shield"           // Approval (macOS has no questionmark.shield)
    static let messageQuestion = "questionmark.bubble"             // Input
    static let circleAlert = "exclamationmark.circle"              // Failed
    static let circleCheck = "checkmark.circle"                    // Done
    static let terminal = "terminal"
    static let fileDiff = "doc.badge.ellipsis"
    static let gitBranch = "arrow.triangle.branch"
    static let gitFork = "arrow.triangle.branch"
    static let copy = "doc.on.doc"
    static let paperclip = "paperclip"
    static let arrowUp = "arrow.up"
    static let stop = "stop.fill"
    static let brain = "brain"
    static let eye = "eye"
    static let globe = "globe"
    static let wrench = "wrench.and.screwdriver"
    static let squarePenFile = "square.and.pencil"
    static let listTodo = "checklist"
    static let alarm = "alarm"
}

extension NSImage {
    /// SF Symbol at a point size, template-rendered so `contentTintColor` colors it.
    static func symbol(_ name: String, size: CGFloat = 16, weight: NSFont.Weight = .regular) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }
}

/// A layer-backed view that re-applies the palette when it changes. Subclasses override
/// `applyPalette(_:)` and never cache colors elsewhere.
class PaletteView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        PaletteCenter.shared.addObserver(self) { [weak self] palette in
            self?.applyPalette(palette)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var palette: Palette { PaletteCenter.shared.palette }

    /// Called once after `init` by subclasses (`applyPalette(palette)`) and on every palette change.
    func applyPalette(_ palette: Palette) {}
}
