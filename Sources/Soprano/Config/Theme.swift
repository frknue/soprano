import AppKit

/// A complete color theme for the app and terminal.
struct AppTheme: Identifiable {
    /// Whether the palette is light ink-on-paper or dark. Drives the window,
    /// popover and alert appearance plus every per-mode derived token.
    enum Appearance: String, CaseIterable, Sendable {
        case light
        case dark

        /// The AppKit appearance windows, popovers and alerts adopt so system
        /// controls match the theme. This is the only place Soprano names the
        /// aqua appearances.
        var nsAppearance: NSAppearance {
            switch self {
            case .light: NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
            case .dark: NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
            }
        }

        /// Maps an effective appearance (including the high-contrast and
        /// vibrant variants) onto light or dark.
        init(_ appearance: NSAppearance) {
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            self = match == .darkAqua ? .dark : .light
        }
    }

    let id: String
    let name: String
    let colors: ThemeColors
    let terminalColors: TerminalColors

    var appearance: Appearance { colors.appearance }
    var backgroundColor: NSColor { colors.bgBase }
    var panelColor: NSColor { colors.bgPanel }
    var textColor: NSColor { colors.textPrimary }
    var accentColor: NSColor { colors.accent }
}

struct ThemeColors {
    let bgBase: NSColor
    let bgPanel: NSColor
    let bgRaised: NSColor
    let bgOverlay: NSColor
    let textPrimary: NSColor
    let textMuted: NSColor
    let accent: NSColor
    let accentStrong: NSColor
    let borderSubtle: NSColor
    let borderStrong: NSColor
    let success: NSColor
    let danger: NSColor
    let blue: NSColor
    let cyan: NSColor
    let yellow: NSColor
    let gray: NSColor
    /// Third-party palettes are all dark; only Folio Paper is light.
    var appearance: AppTheme.Appearance = .dark
}

/// A layer shadow recipe for elevation `e2` (popovers, toasts, HUD) and `e3`
/// (palette, launcher, switcher). `blur` is the CSS blur radius; Core
/// Animation's `shadowRadius` is half of it.
struct ThemeShadow {
    let color: NSColor
    let opacity: Float
    let offsetY: CGFloat
    let blur: CGFloat
    /// The 1 px contact ring drawn around the elevated surface.
    let ring: NSColor

    /// Applies the shadow and contact ring to `layer`. `layer` must not mask
    /// to bounds, or the shadow is clipped away.
    func apply(to layer: CALayer) {
        layer.masksToBounds = false
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = opacity
        layer.shadowOffset = CGSize(width: 0, height: -offsetY)
        layer.shadowRadius = blur / 2
        layer.borderWidth = 1
        layer.borderColor = ring.cgColor
    }
}

/// Derived tokens: formulas over the 16 slots (Folio spec §4), so third-party
/// themes inherit every idiom without declaring anything new.
extension ThemeColors {
    private var isLight: Bool { appearance == .light }

    // MARK: Surfaces

    /// Hover fill for rows, tabs, icon buttons and standard buttons.
    var hover: NSColor { bgOverlay }

    /// The raised surface: focused header, selected tab, cards, fields,
    /// overlays. Themes whose `bgRaised` equals `bgPanel` (Gruvbox,
    /// Solarized) get 5 % ink mixed into the panel so it still separates.
    var raised: NSColor {
        guard bgRaised.contrastRatio(with: bgPanel) < 1.05 else { return bgRaised }
        return bgPanel.mixed(with: textPrimary, fraction: 0.05)
    }

    /// Built-in command tile behind a 16 px glyph.
    var glyphTile: NSColor {
        isLight ? bgOverlay : bgRaised.mixed(with: textPrimary, fraction: 0.09)
    }

    /// Dimmed backdrop behind a modal overlay.
    var scrim: NSColor {
        isLight ? textPrimary.withAlphaComponent(0.20) : NSColor.black.withAlphaComponent(0.45)
    }

    /// Elevation for popovers, toasts and the HUD.
    var shadowE2: ThemeShadow {
        isLight
            ? ThemeShadow(color: Self.paperShadow, opacity: 0.12, offsetY: 6, blur: 18,
                          ring: Self.paperShadow.withAlphaComponent(0.04))
            : ThemeShadow(color: .black, opacity: 0.40, offsetY: 8, blur: 24,
                          ring: NSColor.black.withAlphaComponent(0.30))
    }

    /// Elevation for the palette, launcher and switcher.
    var shadowE3: ThemeShadow {
        isLight
            ? ThemeShadow(color: Self.paperShadow, opacity: 0.16, offsetY: 12, blur: 36,
                          ring: Self.paperShadow.withAlphaComponent(0.05))
            : ThemeShadow(color: .black, opacity: 0.55, offsetY: 14, blur: 40,
                          ring: NSColor.black.withAlphaComponent(0.35))
    }

    private static let paperShadow = NSColor.fromHex("#2b2620")

    // MARK: Selection and focus

    /// Selected row in the focused list: a sienna wash on Paper, a neutral
    /// 11 % ink fill on every dark theme (the pencil tick carries the accent).
    var selection: NSColor {
        isLight ? accent.withAlphaComponent(0.12) : textPrimary.withAlphaComponent(0.11)
    }

    /// Selected row in an unfocused list. No tick.
    var selectionMuted: NSColor {
        textPrimary.withAlphaComponent(isLight ? 0.06 : 0.07)
    }

    /// The 2×14 pencil tick inside a focused selection pill.
    var pencilTick: NSColor { accent }
    /// The 2 px rule under the focused pane or region header.
    var focusMark: NSColor { accent }
    /// Text caret and the focused terminal cursor.
    var caret: NSColor { accent }
    /// Matched characters on the selected row only; other rows match in ink.
    var matchOnSelection: NSColor { accentStrong }
    /// Selected text in fields and text views.
    var textSelection: NSColor { accent.withAlphaComponent(0.22) }

    /// Attention (a pane or row that wants you): blue, or yellow when the
    /// theme's accent sits within 40° of blue so focus and attention never
    /// share a hue.
    var attention: NSColor {
        accent.hueDistance(to: blue) < 40 ? yellow : blue
    }

    /// Header wash of an attention pane.
    var attentionWash: NSColor { attention.withAlphaComponent(0.10) }
    /// Full-bleed wash of an attention row in a list.
    var attentionRowWash: NSColor { attention.withAlphaComponent(0.06) }

    /// Unfocused-pane veil color. Paper composites `bgPanel` with a multiply
    /// blend (`unfocusedVeilCompositingFilter`); dark themes lay black @ 18 %.
    var unfocusedVeil: NSColor {
        isLight ? bgPanel : NSColor.black.withAlphaComponent(0.18)
    }

    /// Core Animation `compositingFilter` for the veil layer, or nil for a
    /// normal blend.
    var unfocusedVeilCompositingFilter: String? {
        isLight ? "multiplyBlendMode" : nil
    }

    // MARK: Status

    /// Lamp of a terminal running a command, apart from the agent colors so a
    /// dev server never reads as an agent at work.
    var runningCommand: NSColor { cyan }
    /// Idle shell: a 6 px gray dot at 60 %.
    var idleMark: NSColor { gray.withAlphaComponent(0.60) }
    /// Pane-header wash for NEEDS INPUT.
    var needsInputWash: NSColor { yellow.withAlphaComponent(0.10) }
    /// Pane-header wash for ERROR.
    var errorWash: NSColor { danger.withAlphaComponent(0.10) }

    // MARK: Controls

    /// Primary buttons, checked checkboxes and on-switch tracks are ink.
    var inkButtonFill: NSColor { textPrimary }
    var inkButtonLabel: NSColor { bgRaised }
    var inkButtonPressed: NSColor { textPrimary.mixed(with: bgRaised, fraction: 0.15) }
    var dangerButtonFill: NSColor { danger }
    var dangerButtonLabel: NSColor { bgRaised }
    var dangerButtonHover: NSColor { danger.mixed(with: textPrimary, fraction: 0.12) }
    /// Edge of a focused text field (the caret carries the accent).
    var fieldFocusEdge: NSColor { bgRaised.mixed(with: textPrimary, fraction: 0.38) }
    /// Off-switch knob: a raised knob would vanish on dark cards.
    var switchKnobOff: NSColor { isLight ? bgRaised : textMuted }
    var keycapFill: NSColor { raised }
    var keycapEdge: NSColor { borderStrong }
    var scrollbarThumb: NSColor { textPrimary.withAlphaComponent(0.22) }

    // MARK: Diff

    /// Added-line wash. Paper uses a chromatic green because success @ 12 %
    /// reads gray on paper.
    var diffAdd: NSColor { diffAddTint.withAlphaComponent(0.16) }
    var diffAddWord: NSColor { diffAddTint.withAlphaComponent(isLight ? 0.30 : 0.28) }
    var diffDelete: NSColor { danger.withAlphaComponent(0.10) }
    var diffDeleteWord: NSColor { danger.withAlphaComponent(0.22) }
    var diffFiller: NSColor { textPrimary.withAlphaComponent(0.03) }
    private var diffAddTint: NSColor { isLight ? .fromHex("#5f8f3a") : success }

    // MARK: Syntax (no accent; keywords are bold ink)

    var syntaxKeyword: NSColor { textPrimary }
    var syntaxType: NSColor { cyan }
    var syntaxString: NSColor { success }
    var syntaxComment: NSColor { textMuted }
    var syntaxNumber: NSColor { yellow }
    var syntaxFunction: NSColor { blue }
    var syntaxAttribute: NSColor { yellow }
    var syntaxPlain: NSColor { textPrimary }
}

extension AppTheme {
    /// Commit-graph lane colors: a graphite trunk (lane 0) and seven hues,
    /// never the accent.
    var graphLanes: [NSColor] {
        [
            colors.textMuted,
            colors.blue,
            colors.success,
            terminalColors.magenta,
            colors.cyan,
            colors.yellow,
            terminalColors.brightMagenta,
            terminalColors.brightBlue,
        ]
    }
}

extension NSColor {
    /// Linear sRGB mix: `fraction` 0 is `self`, 1 is `other`. Alpha mixes too.
    func mixed(with other: NSColor, fraction: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else {
            return self
        }
        let t = min(max(fraction, 0), 1)
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t
        )
    }

    /// WCAG contrast ratio between two opaque colors (1…21).
    func contrastRatio(with other: NSColor) -> CGFloat {
        let l1 = relativeLuminance
        let l2 = other.relativeLuminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Shortest distance between two hues, in degrees (0…180).
    func hueDistance(to other: NSColor) -> CGFloat {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else {
            return 180
        }
        let delta = abs(a.hueComponent - b.hueComponent) * 360
        return min(delta, 360 - delta)
    }

    private var relativeLuminance: CGFloat {
        guard let color = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}

struct TerminalColors {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let cursorAccent: NSColor
    let selectionBackground: NSColor
    let black: NSColor
    let red: NSColor
    let green: NSColor
    let yellow: NSColor
    let blue: NSColor
    let magenta: NSColor
    let cyan: NSColor
    let white: NSColor
    let brightBlack: NSColor
    let brightRed: NSColor
    let brightGreen: NSColor
    let brightYellow: NSColor
    let brightBlue: NSColor
    let brightMagenta: NSColor
    let brightCyan: NSColor
    let brightWhite: NSColor
}

extension TerminalColors {
    /// Ghostty only exposes file-based configuration loading through its C API.
    /// Keep the generated override here, next to Soprano's source-of-truth
    /// palette, so the terminal renderer cannot drift from the AppKit theme.
    var ghosttyConfiguration: String {
        let colors = [
            background,
            foreground,
            cursor,
            cursorAccent,
            selectionBackground,
        ] + palette
        let hex = colors.map(\.ghosttyRGBHex)

        return """
        background = \(hex[0])
        foreground = \(hex[1])
        cursor-color = \(hex[2])
        cursor-text = \(hex[3])
        selection-background = \(hex[4])
        \(hex.dropFirst(5).enumerated().map { "palette = \($0.offset)=\($0.element)" }.joined(separator: "\n"))
        """
    }

    private var palette: [NSColor] {
        [
            black,
            red,
            green,
            yellow,
            blue,
            magenta,
            cyan,
            white,
            brightBlack,
            brightRed,
            brightGreen,
            brightYellow,
            brightBlue,
            brightMagenta,
            brightCyan,
            brightWhite,
        ]
    }
}

private extension NSColor {
    var ghosttyRGBHex: String {
        guard let color = usingColorSpace(.sRGB) else {
            return "ffffff"
        }
        return String(
            format: "%02x%02x%02x",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}

// MARK: - Built-in Themes

extension AppTheme {
    /// The default theme id. It is not a palette of its own: it resolves to
    /// Folio Paper or Folio Ink from the effective appearance.
    static let folioId = "folio"

    /// Folio Paper: ink on warm paper with one sienna pencil mark.
    static let folioPaper = AppTheme(
        id: "folio-paper",
        name: "Folio Paper",
        colors: ThemeColors(
            bgBase: .fromHex("#f6f2ea"),
            bgPanel: .fromHex("#ede7db"),
            bgRaised: .fromHex("#fcfaf5"),
            bgOverlay: .fromHex("#e5dece"),
            textPrimary: .fromHex("#2b2620"),
            textMuted: .fromHex("#62594d"),
            accent: .fromHex("#a34a17"),
            accentStrong: .fromHex("#863a0f"),
            borderSubtle: .fromHex("#e0d8c9"),
            borderStrong: .fromHex("#cbc0ad"),
            success: .fromHex("#456b30"),
            danger: .fromHex("#ae2f3c"),
            blue: .fromHex("#2f5f8a"),
            cyan: .fromHex("#266b66"),
            yellow: .fromHex("#835f0b"),
            gray: .fromHex("#857c6e"),
            appearance: .light
        ),
        terminalColors: TerminalColors(
            background: .fromHex("#f6f2ea"),
            foreground: .fromHex("#2b2620"),
            cursor: .fromHex("#a34a17"),
            cursorAccent: .fromHex("#f6f2ea"),
            selectionBackground: .fromHex("#e4cdbc"),
            black: .fromHex("#2b2620"),
            red: .fromHex("#ae2f3c"),
            green: .fromHex("#456b30"),
            yellow: .fromHex("#835f0b"),
            blue: .fromHex("#2f5f8a"),
            magenta: .fromHex("#8a3f78"),
            cyan: .fromHex("#266b66"),
            white: .fromHex("#6f665a"),
            brightBlack: .fromHex("#5a5248"),
            brightRed: .fromHex("#c0414a"),
            brightGreen: .fromHex("#557f3b"),
            brightYellow: .fromHex("#9a7212"),
            brightBlue: .fromHex("#3d72a3"),
            brightMagenta: .fromHex("#a04f8d"),
            brightCyan: .fromHex("#2f817b"),
            brightWhite: .fromHex("#8f8678")
        )
    )

    /// Folio Ink: Paper's dark counterpart.
    static let folioInk = AppTheme(
        id: "folio-ink",
        name: "Folio Ink",
        colors: ThemeColors(
            bgBase: .fromHex("#1d1b18"),
            bgPanel: .fromHex("#181613"),
            bgRaised: .fromHex("#26231f"),
            bgOverlay: .fromHex("#2f2b26"),
            textPrimary: .fromHex("#e2dacb"),
            textMuted: .fromHex("#a0968a"),
            accent: .fromHex("#e08a52"),
            accentStrong: .fromHex("#f0a774"),
            borderSubtle: .fromHex("#322e29"),
            borderStrong: .fromHex("#443e37"),
            success: .fromHex("#97ae76"),
            danger: .fromHex("#e0707a"),
            blue: .fromHex("#86a6cb"),
            cyan: .fromHex("#74b3a9"),
            yellow: .fromHex("#d6aa4f"),
            gray: .fromHex("#776f64"),
            appearance: .dark
        ),
        terminalColors: TerminalColors(
            background: .fromHex("#1d1b18"),
            foreground: .fromHex("#e2dacb"),
            cursor: .fromHex("#e08a52"),
            cursorAccent: .fromHex("#1d1b18"),
            selectionBackground: .fromHex("#483325"),
            black: .fromHex("#2a2622"),
            red: .fromHex("#e0707a"),
            green: .fromHex("#97ae76"),
            yellow: .fromHex("#d6aa4f"),
            blue: .fromHex("#86a6cb"),
            magenta: .fromHex("#c191b8"),
            cyan: .fromHex("#74b3a9"),
            white: .fromHex("#cfc6b5"),
            brightBlack: .fromHex("#7d7469"),
            brightRed: .fromHex("#ec8f97"),
            brightGreen: .fromHex("#b0c592"),
            brightYellow: .fromHex("#e8c272"),
            brightBlue: .fromHex("#a3bfdf"),
            brightMagenta: .fromHex("#d5aacd"),
            brightCyan: .fromHex("#93c9bf"),
            brightWhite: .fromHex("#f4efe5")
        )
    )

    static let gruvboxDark = AppTheme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        colors: ThemeColors(
            bgBase: .fromHex("#282828"),
            bgPanel: .fromHex("#1d2021"),
            bgRaised: .fromHex("#1d2021"),
            bgOverlay: .fromHex("#3c3836"),
            textPrimary: .fromHex("#ebdbb2"),
            textMuted: .fromHex("#a89984"),
            accent: .fromHex("#fe8019"),
            accentStrong: .fromHex("#fabd2f"),
            borderSubtle: .fromHex("#3c3836"),
            borderStrong: .fromHex("#504945"),
            success: .fromHex("#b8bb26"),
            danger: .fromHex("#fb4934"),
            blue: .fromHex("#83a598"),
            cyan: .fromHex("#8ec07c"),
            yellow: .fromHex("#fabd2f"),
            gray: .fromHex("#665c54")
        ),
        terminalColors: TerminalColors(
            background: .fromHex("#282828"),
            foreground: .fromHex("#ebdbb2"),
            cursor: .fromHex("#ebdbb2"),
            cursorAccent: .fromHex("#282828"),
            selectionBackground: .fromHex("#504945").withAlphaComponent(0.6),
            black: .fromHex("#282828"),
            red: .fromHex("#cc241d"),
            green: .fromHex("#98971a"),
            yellow: .fromHex("#d79921"),
            blue: .fromHex("#458588"),
            magenta: .fromHex("#b16286"),
            cyan: .fromHex("#689d6a"),
            white: .fromHex("#a89984"),
            brightBlack: .fromHex("#928374"),
            brightRed: .fromHex("#fb4934"),
            brightGreen: .fromHex("#b8bb26"),
            brightYellow: .fromHex("#fabd2f"),
            brightBlue: .fromHex("#83a598"),
            brightMagenta: .fromHex("#d3869b"),
            brightCyan: .fromHex("#8ec07c"),
            brightWhite: .fromHex("#ebdbb2")
        )
    )

    static let catppuccinMocha = AppTheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        colors: ThemeColors(
            bgBase: .fromHex("#1e1e2e"),
            bgPanel: .fromHex("#181825"),
            bgRaised: .fromHex("#11111b"),
            bgOverlay: .fromHex("#313244"),
            textPrimary: .fromHex("#cdd6f4"),
            textMuted: .fromHex("#a6adc8"),
            accent: .fromHex("#cba6f7"),
            accentStrong: .fromHex("#f5c2e7"),
            borderSubtle: .fromHex("#313244"),
            borderStrong: .fromHex("#45475a"),
            success: .fromHex("#a6e3a1"),
            danger: .fromHex("#f38ba8"),
            blue: .fromHex("#89b4fa"),
            cyan: .fromHex("#94e2d5"),
            yellow: .fromHex("#f9e2af"),
            gray: .fromHex("#45475a")
        ),
        terminalColors: TerminalColors(
            background: .fromHex("#1e1e2e"),
            foreground: .fromHex("#cdd6f4"),
            cursor: .fromHex("#f5e0dc"),
            cursorAccent: .fromHex("#1e1e2e"),
            selectionBackground: .fromHex("#45475a").withAlphaComponent(0.6),
            black: .fromHex("#45475a"),
            red: .fromHex("#f38ba8"),
            green: .fromHex("#a6e3a1"),
            yellow: .fromHex("#f9e2af"),
            blue: .fromHex("#89b4fa"),
            magenta: .fromHex("#cba6f7"),
            cyan: .fromHex("#94e2d5"),
            white: .fromHex("#bac2de"),
            brightBlack: .fromHex("#585b70"),
            brightRed: .fromHex("#f38ba8"),
            brightGreen: .fromHex("#a6e3a1"),
            brightYellow: .fromHex("#f9e2af"),
            brightBlue: .fromHex("#89b4fa"),
            brightMagenta: .fromHex("#cba6f7"),
            brightCyan: .fromHex("#94e2d5"),
            brightWhite: .fromHex("#a6adc8")
        )
    )

    static let dracula = AppTheme(
        id: "dracula",
        name: "Dracula",
        colors: ThemeColors(
            bgBase: .fromHex("#282a36"),
            bgPanel: .fromHex("#21222c"),
            bgRaised: .fromHex("#343746"),
            bgOverlay: .fromHex("#44475a"),
            textPrimary: .fromHex("#f8f8f2"),
            textMuted: .fromHex("#6272a4"),
            accent: .fromHex("#bd93f9"),
            accentStrong: .fromHex("#ff79c6"),
            borderSubtle: .fromHex("#44475a"),
            borderStrong: .fromHex("#6272a4"),
            success: .fromHex("#50fa7b"),
            danger: .fromHex("#ff5555"),
            blue: .fromHex("#bd93f9"),
            cyan: .fromHex("#8be9fd"),
            yellow: .fromHex("#f1fa8c"),
            gray: .fromHex("#6272a4")
        ),
        terminalColors: TerminalColors(
            background: .fromHex("#282a36"),
            foreground: .fromHex("#f8f8f2"),
            cursor: .fromHex("#f8f8f2"),
            cursorAccent: .fromHex("#282a36"),
            selectionBackground: .fromHex("#44475a"),
            black: .fromHex("#21222c"),
            red: .fromHex("#ff5555"),
            green: .fromHex("#50fa7b"),
            yellow: .fromHex("#f1fa8c"),
            blue: .fromHex("#bd93f9"),
            magenta: .fromHex("#ff79c6"),
            cyan: .fromHex("#8be9fd"),
            white: .fromHex("#f8f8f2"),
            brightBlack: .fromHex("#6272a4"),
            brightRed: .fromHex("#ff6e6e"),
            brightGreen: .fromHex("#69ff94"),
            brightYellow: .fromHex("#ffffa5"),
            brightBlue: .fromHex("#d6acff"),
            brightMagenta: .fromHex("#ff92df"),
            brightCyan: .fromHex("#a4ffff"),
            brightWhite: .fromHex("#ffffff")
        )
    )

    static let solarizedDark = AppTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        colors: ThemeColors(
            bgBase: .fromHex("#002b36"),
            bgPanel: .fromHex("#073642"),
            bgRaised: .fromHex("#073642"),
            bgOverlay: .fromHex("#586e75"),
            textPrimary: .fromHex("#93a1a1"),
            textMuted: .fromHex("#657b83"),
            accent: .fromHex("#268bd2"),
            accentStrong: .fromHex("#6c71c4"),
            borderSubtle: .fromHex("#073642"),
            borderStrong: .fromHex("#586e75"),
            success: .fromHex("#859900"),
            danger: .fromHex("#dc322f"),
            blue: .fromHex("#268bd2"),
            cyan: .fromHex("#2aa198"),
            yellow: .fromHex("#b58900"),
            gray: .fromHex("#586e75")
        ),
        terminalColors: TerminalColors(
            background: .fromHex("#002b36"),
            foreground: .fromHex("#839496"),
            cursor: .fromHex("#839496"),
            cursorAccent: .fromHex("#073642"),
            selectionBackground: .fromHex("#073642"),
            black: .fromHex("#073642"),
            red: .fromHex("#dc322f"),
            green: .fromHex("#859900"),
            yellow: .fromHex("#b58900"),
            blue: .fromHex("#268bd2"),
            magenta: .fromHex("#d33682"),
            cyan: .fromHex("#2aa198"),
            white: .fromHex("#eee8d5"),
            brightBlack: .fromHex("#335e69"),
            brightRed: .fromHex("#cb4b16"),
            brightGreen: .fromHex("#586e75"),
            brightYellow: .fromHex("#657b83"),
            brightBlue: .fromHex("#839496"),
            brightMagenta: .fromHex("#6c71c4"),
            brightCyan: .fromHex("#93a1a1"),
            brightWhite: .fromHex("#fdf6e3")
        )
    )

    static let nord = AppTheme(
        id: "nord",
        name: "Nord",
        colors: ThemeColors(
            bgBase: .fromHex("#2e3440"),
            bgPanel: .fromHex("#3b4252"),
            bgRaised: .fromHex("#434c5e"),
            bgOverlay: .fromHex("#4c566a"),
            textPrimary: .fromHex("#eceff4"),
            textMuted: .fromHex("#81a1c1"),
            accent: .fromHex("#88c0d0"),
            accentStrong: .fromHex("#8fbcbb"),
            borderSubtle: .fromHex("#434c5e"),
            borderStrong: .fromHex("#4c566a"),
            success: .fromHex("#a3be8c"),
            danger: .fromHex("#bf616a"),
            blue: .fromHex("#81a1c1"),
            cyan: .fromHex("#88c0d0"),
            yellow: .fromHex("#ebcb8b"),
            gray: .fromHex("#4c566a")
        ),
        terminalColors: TerminalColors(
            background: .fromHex("#2e3440"),
            foreground: .fromHex("#d8dee9"),
            cursor: .fromHex("#eceff4"),
            cursorAccent: .fromHex("#282828"),
            selectionBackground: .fromHex("#eceff4"),
            black: .fromHex("#3b4252"),
            red: .fromHex("#bf616a"),
            green: .fromHex("#a3be8c"),
            yellow: .fromHex("#ebcb8b"),
            blue: .fromHex("#81a1c1"),
            magenta: .fromHex("#b48ead"),
            cyan: .fromHex("#88c0d0"),
            white: .fromHex("#e5e9f0"),
            brightBlack: .fromHex("#596377"),
            brightRed: .fromHex("#bf616a"),
            brightGreen: .fromHex("#a3be8c"),
            brightYellow: .fromHex("#ebcb8b"),
            brightBlue: .fromHex("#81a1c1"),
            brightMagenta: .fromHex("#b48ead"),
            brightCyan: .fromHex("#8fbcbb"),
            brightWhite: .fromHex("#eceff4")
        )
    )

    static let tokyoNight = AppTheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        colors: ThemeColors(
            bgBase: .fromHex("#1a1b26"),
            bgPanel: .fromHex("#15161e"),
            bgRaised: .fromHex("#24283b"),
            bgOverlay: .fromHex("#292e42"),
            textPrimary: .fromHex("#c0caf5"),
            textMuted: .fromHex("#565f89"),
            accent: .fromHex("#7aa2f7"),
            accentStrong: .fromHex("#bb9af7"),
            borderSubtle: .fromHex("#292e42"),
            borderStrong: .fromHex("#414868"),
            success: .fromHex("#9ece6a"),
            danger: .fromHex("#f7768e"),
            blue: .fromHex("#7aa2f7"),
            cyan: .fromHex("#7dcfff"),
            yellow: .fromHex("#e0af68"),
            gray: .fromHex("#414868")
        ),
        terminalColors: TerminalColors(
            background: .fromHex("#1a1b26"),
            foreground: .fromHex("#c0caf5"),
            cursor: .fromHex("#c0caf5"),
            cursorAccent: .fromHex("#15161e"),
            selectionBackground: .fromHex("#33467c"),
            black: .fromHex("#15161e"),
            red: .fromHex("#f7768e"),
            green: .fromHex("#9ece6a"),
            yellow: .fromHex("#e0af68"),
            blue: .fromHex("#7aa2f7"),
            magenta: .fromHex("#bb9af7"),
            cyan: .fromHex("#7dcfff"),
            white: .fromHex("#a9b1d6"),
            brightBlack: .fromHex("#414868"),
            brightRed: .fromHex("#f7768e"),
            brightGreen: .fromHex("#9ece6a"),
            brightYellow: .fromHex("#e0af68"),
            brightBlue: .fromHex("#7aa2f7"),
            brightMagenta: .fromHex("#bb9af7"),
            brightCyan: .fromHex("#7dcfff"),
            brightWhite: .fromHex("#c0caf5")
        )
    )

    static let atomOneDark = AppTheme(
        id: "atom-one-dark",
        name: "Atom One Dark",
        colors: ThemeColors(
            bgBase: .fromHex("#21252b"),
            bgPanel: .fromHex("#1b1f23"),
            bgRaised: .fromHex("#282c34"),
            bgOverlay: .fromHex("#323844"),
            textPrimary: .fromHex("#abb2bf"),
            textMuted: .fromHex("#5c6370"),
            accent: .fromHex("#61afef"),
            accentStrong: .fromHex("#c678dd"),
            borderSubtle: .fromHex("#323844"),
            borderStrong: .fromHex("#4b5263"),
            success: .fromHex("#98c379"),
            danger: .fromHex("#e06c75"),
            blue: .fromHex("#61afef"),
            cyan: .fromHex("#56b6c2"),
            yellow: .fromHex("#e5c07b"),
            gray: .fromHex("#5c6370")
        ),
        terminalColors: TerminalColors(
            background: .fromHex("#21252b"),
            foreground: .fromHex("#abb2bf"),
            cursor: .fromHex("#abb2bf"),
            cursorAccent: .fromHex("#21252b"),
            selectionBackground: .fromHex("#323844"),
            black: .fromHex("#21252b"),
            red: .fromHex("#e06c75"),
            green: .fromHex("#98c379"),
            yellow: .fromHex("#e5c07b"),
            blue: .fromHex("#61afef"),
            magenta: .fromHex("#c678dd"),
            cyan: .fromHex("#56b6c2"),
            white: .fromHex("#abb2bf"),
            brightBlack: .fromHex("#767676"),
            brightRed: .fromHex("#e06c75"),
            brightGreen: .fromHex("#98c379"),
            brightYellow: .fromHex("#e5c07b"),
            brightBlue: .fromHex("#61afef"),
            brightMagenta: .fromHex("#c678dd"),
            brightCyan: .fromHex("#56b6c2"),
            brightWhite: .fromHex("#abb2bf")
        )
    )

    /// Every concrete palette. `folio` is not listed: it resolves to one of
    /// the first two.
    static let allThemes: [AppTheme] = [
        folioPaper,
        folioInk,
        gruvboxDark,
        catppuccinMocha,
        dracula,
        solarizedDark,
        nord,
        tokyoNight,
        atomOneDark,
    ]

    /// One entry of the theme picker and the `theme` key's allowed values.
    struct Option: Equatable {
        let id: String
        let name: String
    }

    /// Every id `settings.json` accepts, in picker order: Folio (following
    /// the appearance), then each concrete palette.
    static let options: [Option] = [Option(id: folioId, name: "Folio")]
        + allThemes.map { Option(id: $0.id, name: $0.name) }

    static func isKnownId(_ id: String) -> Bool {
        options.contains { $0.id == id }
    }

    /// The palette for `id`. `folio`, and any unknown id, resolves to Folio
    /// Paper or Folio Ink from `appearance`.
    static func theme(for id: String, appearance: Appearance) -> AppTheme {
        if let theme = allThemes.first(where: { $0.id == id }) {
            return theme
        }
        return appearance == .light ? folioPaper : folioInk
    }
}
