import AppKit

/// Color tokens of the app. Every view colors itself only from the current `Palette`, which is
/// always derived from a Soprano theme (`Palette(soprano:)`): `theme: "soprano"` follows
/// Soprano's own theme and appearance, any other value is a Soprano theme id (`folio` follows
/// macOS light/dark, `folio-paper`, `folio-ink`, `nord`, …).
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

    // Sidebar
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
    /// The 16 ANSI colors (black … bright white) of the Soprano theme's terminal palette.
    var terminalANSI: [NSColor]

    /// Project monogram tints, picked per project name (`ProjectIdentity.colorIndex`).
    var projectIconColors: [NSColor]

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


extension Palette {
    /// Claude's brand orange for its provider mark, same in light and dark.
    var claudeBrand: NSColor { hex(0xd97757) }
}

extension Palette {
    /// Maps a Soprano theme onto the app's tokens.
    init(soprano theme: AppTheme) {
        let colors = theme.colors
        let terminal = theme.terminalColors
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
            terminalBackground: terminal.background,
            terminalForeground: terminal.foreground,
            terminalCursor: terminal.cursor,
            terminalSelection: terminal.selectionBackground,
            terminalANSI: [
                terminal.black, terminal.red, terminal.green, terminal.yellow,
                terminal.blue, terminal.magenta, terminal.cyan, terminal.white,
                terminal.brightBlack, terminal.brightRed, terminal.brightGreen, terminal.brightYellow,
                terminal.brightBlue, terminal.brightMagenta, terminal.brightCyan, terminal.brightWhite,
            ],
            projectIconColors: [colors.blue, colors.success, colors.yellow, colors.cyan, colors.accent, colors.danger, colors.gray]
        )
    }
}

/// The live palette. Views read `PaletteCenter.shared.palette` when they build and re-color
/// in their observer. It follows `ThemeCenter` (the `theme` setting, Soprano's own theme for
/// "soprano") and the snapshot harness's forced appearance.
@MainActor
final class PaletteCenter {
    static let shared = PaletteCenter()

    private(set) var palette = Palette(soprano: ThemeCenter.shared.theme)
    /// Forced appearance (snapshot `--appearance`); wins over macOS and Soprano.
    var forcedDark: Bool? {
        didSet { resolve() }
    }

    private let observers = ObserverList<Palette>()

    init() {
        ThemeCenter.shared.addObserver(self) { [weak self] _ in
            self?.resolve()
        }
    }

    func addObserver(_ owner: AnyObject, _ handler: @escaping @MainActor (Palette) -> Void) {
        observers.add(owner, handler)
    }

    /// Applies the `theme` setting: "soprano" or a Soprano theme id.
    func apply(setting: String) {
        ThemeCenter.shared.apply(setting: setting)
        resolve()
    }

    private func resolve() {
        if let forcedDark {
            // Folio has a light and a dark palette; every other theme has one appearance.
            let current = ThemeCenter.shared.theme.id
            let isFolio = current == AppTheme.folioPaper.id || current == AppTheme.folioInk.id
            ThemeCenter.shared.forcedThemeID = isFolio ? (forcedDark ? AppTheme.folioInk : AppTheme.folioPaper).id : current
        }
        let next = Palette(soprano: ThemeCenter.shared.theme)
        guard next != palette else { return }
        palette = next
        observers.notify(next)
    }
}
