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

    static let allThemes: [AppTheme] = [gruvboxDark, catppuccinMocha]

    static func theme(for id: String) -> AppTheme {
        allThemes.first { $0.id == id } ?? gruvboxDark
    }
}
