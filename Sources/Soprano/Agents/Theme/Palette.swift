import AppKit

/// Color tokens of the app, named after T3 Code's CSS variables (`apps/web/src/index.css`).
/// Every view colors itself only from the current `Palette`.
///
/// The default theme `t3` is T3 Code's own zinc/black palette with its blue primary, following
/// macOS light/dark. Any Soprano theme id (`soprano`, `folio`, …) maps Soprano's `ThemeColors`
/// onto the same tokens, so the layout stays T3 Code while the colors join the Soprano family.
struct Palette: Equatable {
    var isDark: Bool

    // Surfaces
    var background: NSColor
    var foreground: NSColor
    var card: NSColor
    var popover: NSColor
    /// Changed-files card, subtle fills.
    var secondary: NSColor
    var muted: NSColor
    /// Hover fill of ghost controls and menu rows.
    var accent: NSColor
    var border: NSColor
    /// Outline of inputs and outline buttons.
    var input: NSColor

    // Text
    var mutedForeground: NSColor
    /// Meta lines (project name, branch, timestamps).
    var secondaryLabel: NSColor
    var placeholder: NSColor

    // Brand
    var primary: NSColor
    var primaryForeground: NSColor

    // Messages
    var messageSurface: NSColor
    var messageForeground: NSColor

    // Sidebar (T3 Code's `[data-app-sidebar]` overrides)
    var sidebar: NSColor
    var sidebarForeground: NSColor
    var sidebarMutedForeground: NSColor
    var sidebarRowHover: NSColor
    var sidebarRowActive: NSColor
    var sidebarRowSelected: NSColor
    var sidebarBorder: NSColor

    // Status
    var error: NSColor
    var errorForeground: NSColor
    var warning: NSColor
    var warningForeground: NSColor
    var success: NSColor
    var successForeground: NSColor
    var info: NSColor
    var infoForeground: NSColor
    /// "Input" status pill (indigo).
    var inputForeground: NSColor
    /// Merged pull requests (violet).
    var mergedForeground: NSColor

    // Diff
    var diffAdditionForeground: NSColor
    var diffDeletionForeground: NSColor
    var diffAdditionBackground: NSColor
    var diffDeletionBackground: NSColor
    var diffAdditionWord: NSColor
    var diffDeletionWord: NSColor

    // Code and terminal
    var codeBackground: NSColor
    var terminalBackground: NSColor
    var terminalForeground: NSColor
    var terminalCursor: NSColor
    var terminalSelection: NSColor

    var appearance: NSAppearance {
        NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    /// Color for the Working / Waiting / Done … pills.
    func color(for status: ThreadStatusTone) -> NSColor {
        switch status {
        case .working: infoForeground
        case .approval: warningForeground
        case .input: inputForeground
        case .failed: errorForeground
        case .done: successForeground
        case .muted: mutedForeground
        }
    }
}

enum ThreadStatusTone {
    case working, approval, input, failed, done, muted
}

private func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xff) / 255,
        green: CGFloat((value >> 8) & 0xff) / 255,
        blue: CGFloat(value & 0xff) / 255,
        alpha: alpha
    )
}

private func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

extension Palette {
    /// T3 Code light (`:root`). Tailwind v4 oklch values converted to sRGB.
    static let t3Light = Palette(
        isDark: false,
        background: hex(0xfcfcfc),            // zinc-25
        foreground: hex(0x18181b),            // zinc-900
        card: hex(0xffffff),
        popover: hex(0xffffff),
        secondary: hex(0xfafafa),             // zinc-50
        muted: hex(0xfafafa),
        accent: hex(0xf4f4f5),                // zinc-100
        border: hex(0xe4e4e7),                // zinc-200
        input: hex(0xd4d4d8),                 // zinc-300
        mutedForeground: hex(0x71717b),       // zinc-500
        secondaryLabel: hex(0x71717b),
        placeholder: hex(0x71717b),
        primary: hex(0x1b4ed8),               // oklch(0.488 0.217 264)
        primaryForeground: hex(0xffffff),
        messageSurface: hex(0xebebed),        // zinc-200 55% + zinc-100
        messageForeground: hex(0x18181b),
        sidebar: hex(0xfafafa),
        sidebarForeground: hex(0x18181b),
        sidebarMutedForeground: hex(0x71717b),
        sidebarRowHover: hex(0xfcfcfc),
        sidebarRowActive: hex(0xffffff),
        sidebarRowSelected: hex(0xffffff),
        sidebarBorder: hex(0xe4e4e7),
        error: hex(0xfb2c36),                 // red-500
        errorForeground: hex(0xc10007),       // red-700
        warning: hex(0xfe9a00),               // amber-500
        warningForeground: hex(0xbb4d00),     // amber-700
        success: hex(0x00bc7d),               // emerald-500
        successForeground: hex(0x007a55),     // emerald-700
        info: hex(0x2b7fff),                  // blue-500
        infoForeground: hex(0x1447e6),        // blue-700
        inputForeground: hex(0x4f39f6),       // indigo-600
        mergedForeground: hex(0x7f22fe),      // violet-600
        diffAdditionForeground: hex(0x007a55),
        diffDeletionForeground: hex(0xc10007),
        diffAdditionBackground: hex(0x00bc7d, 0.10),
        diffDeletionBackground: hex(0xfb2c36, 0.08),
        diffAdditionWord: hex(0x00bc7d, 0.25),
        diffDeletionWord: hex(0xfb2c36, 0.20),
        codeBackground: hex(0xfefefe),
        terminalBackground: hex(0xfcfcfc),
        terminalForeground: hex(0x18181b),
        terminalCursor: hex(0x26384e),
        terminalSelection: hex(0x253f63, 0.20)
    )

    /// T3 Code dark (`@variant dark`): pure black canvas, neutral-950 cards.
    static let t3Dark = Palette(
        isDark: true,
        background: hex(0x000000),
        foreground: hex(0xf5f5f5),            // neutral-100
        card: hex(0x111111),                  // neutral-950 97% + white
        popover: hex(0x111111),
        secondary: white(0.03),
        muted: white(0.03),
        accent: white(0.04),
        border: white(0.08),
        input: white(0.11),
        mutedForeground: hex(0xa1a1a1),       // neutral-400
        secondaryLabel: hex(0x8f8f8f),
        placeholder: hex(0xa1a1a1),
        primary: hex(0x346bf1),               // oklch(0.571 0.21 264)
        primaryForeground: hex(0xffffff),
        messageSurface: hex(0x1e1e1e),        // neutral-950 92% + white
        messageForeground: hex(0xf5f5f5),
        sidebar: hex(0x000000),
        sidebarForeground: hex(0xf1f3f7),
        sidebarMutedForeground: hex(0xa3a3a3),
        sidebarRowHover: hex(0xf1f3f7, 0.08),
        sidebarRowActive: hex(0xf1f3f7, 0.11),
        sidebarRowSelected: hex(0xf1f3f7, 0.07),
        sidebarBorder: white(0.08),
        error: hex(0xfb414a),                 // red-500 90% + white
        errorForeground: hex(0xff6467),       // red-400
        warning: hex(0xfe9a00),
        warningForeground: hex(0xffb900),     // amber-400
        success: hex(0x00bc7d),
        successForeground: hex(0x00d492),     // emerald-400
        info: hex(0x2b7fff),
        infoForeground: hex(0x51a2ff),        // blue-400
        inputForeground: hex(0xa3b3ff),       // indigo-300
        mergedForeground: hex(0xc4b4ff),      // violet-300
        diffAdditionForeground: hex(0x00d492),
        diffDeletionForeground: hex(0xff6467),
        diffAdditionBackground: hex(0x00bc7d, 0.12),
        diffDeletionBackground: hex(0xfb2c36, 0.12),
        diffAdditionWord: hex(0x00bc7d, 0.28),
        diffDeletionWord: hex(0xfb2c36, 0.28),
        codeBackground: hex(0x0f0f0f),
        terminalBackground: hex(0x000000),
        terminalForeground: hex(0xf5f5f5),
        terminalCursor: hex(0xb4cbff),
        terminalSelection: hex(0xb4cbff, 0.25)
    )

    static func t3(dark: Bool) -> Palette { dark ? .t3Dark : .t3Light }

    /// Maps a Soprano theme onto the T3 Code tokens.
    init(soprano theme: AppTheme) {
        let colors = theme.colors
        let dark = theme.appearance == .dark
        self.init(
            isDark: dark,
            background: colors.bgBase,
            foreground: colors.textPrimary,
            card: colors.bgPanel,
            popover: colors.bgRaised,
            secondary: colors.bgPanel,
            muted: colors.bgPanel,
            accent: colors.hover,
            border: colors.borderSubtle,
            input: colors.borderStrong,
            mutedForeground: colors.textMuted,
            secondaryLabel: colors.textMuted,
            placeholder: colors.textMuted,
            primary: colors.accent,
            primaryForeground: dark ? colors.bgBase : NSColor.white,
            messageSurface: colors.raised,
            messageForeground: colors.textPrimary,
            sidebar: colors.bgPanel,
            sidebarForeground: colors.textPrimary,
            sidebarMutedForeground: colors.textMuted,
            sidebarRowHover: colors.hover,
            sidebarRowActive: colors.selection,
            sidebarRowSelected: colors.selectionMuted,
            sidebarBorder: colors.borderSubtle,
            error: colors.danger,
            errorForeground: colors.danger,
            warning: colors.yellow,
            warningForeground: colors.yellow,
            success: colors.success,
            successForeground: colors.success,
            info: colors.blue,
            infoForeground: colors.blue,
            inputForeground: colors.cyan,
            mergedForeground: colors.accent,
            diffAdditionForeground: colors.success,
            diffDeletionForeground: colors.danger,
            diffAdditionBackground: colors.diffAdd,
            diffDeletionBackground: colors.diffDelete,
            diffAdditionWord: colors.diffAddWord,
            diffDeletionWord: colors.diffDeleteWord,
            codeBackground: colors.bgPanel,
            terminalBackground: colors.bgBase,
            terminalForeground: colors.textPrimary,
            terminalCursor: colors.accent,
            terminalSelection: colors.selection
        )
    }
}

/// The live palette. Views read `PaletteCenter.shared.palette` when they build and re-color
/// in their observer.
@MainActor
final class PaletteCenter {
    static let shared = PaletteCenter()

    /// Theme ids that select T3 Code's own palette.
    nonisolated static let t3ThemeIDs = ["t3", "t3-light", "t3-dark"]

    private(set) var palette: Palette = .t3Light
    private(set) var setting = "t3"
    /// Forced appearance (snapshot `--appearance`); wins over macOS.
    var forcedDark: Bool? {
        didSet { resolve() }
    }

    private let observers = ObserverList<Palette>()
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        ThemeCenter.shared.addObserver(self) { [weak self] _ in
            self?.resolve()
        }
    }

    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (Palette) -> Void) {
        observers.add(owner, handler)
    }

    /// Applies the `theme` setting: a T3 id, "soprano", or any Soprano theme id.
    func apply(setting: String) {
        self.setting = setting
        if !Self.t3ThemeIDs.contains(setting) {
            ThemeCenter.shared.apply(setting: setting)
        }
        resolve()
    }

    /// Follows macOS light/dark changes. Called once at launch; snapshots and tests never do.
    func startFollowingSystemAppearance() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.resolve() }
        }
    }

    private func systemIsDark() -> Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func resolve() {
        let next: Palette
        switch setting {
        case "t3-light": next = .t3Light
        case "t3-dark": next = .t3Dark
        case "t3": next = .t3(dark: forcedDark ?? systemIsDark())
        default:
            if let forcedDark {
                ThemeCenter.shared.forcedThemeID = AppTheme.theme(for: ThemeCenter.shared.theme.id, appearance: forcedDark ? .dark : .light).id
            }
            next = Palette(soprano: ThemeCenter.shared.theme)
        }
        guard next != palette else { return }
        palette = next
        observers.notify(next)
    }
}
