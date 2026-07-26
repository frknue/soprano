import AppKit

/// A complete color theme for the app and terminal.
struct AppTheme: Identifiable {
    let id: String
    let name: String
    let colors: ThemeColors
    let terminalColors: TerminalColors

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
}

extension ThemeColors {
    /// Background tint for the selected group in a list (the active logical
    /// window and its panes).
    ///
    /// Derived from the accent rather than reusing `bgRaised`: themes are free to
    /// define `bgRaised` identical to `bgPanel` (Gruvbox Dark does), which makes a
    /// raised-background highlight completely invisible on a panel surface.
    var bgSelected: NSColor { accent.withAlphaComponent(0.14) }

    /// Stronger tint for the single focused row inside the selected group.
    var bgSelectedStrong: NSColor { accent.withAlphaComponent(0.26) }

    /// Leading edge rail marking rows that belong to the active window.
    var railMuted: NSColor { accent.withAlphaComponent(0.45) }
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

    static let allThemes: [AppTheme] = [
        gruvboxDark,
        catppuccinMocha,
        dracula,
        solarizedDark,
        nord,
        tokyoNight,
        atomOneDark,
    ]

    static func theme(for id: String) -> AppTheme {
        allThemes.first { $0.id == id } ?? gruvboxDark
    }
}
