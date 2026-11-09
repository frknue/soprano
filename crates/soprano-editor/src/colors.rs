//! The colors the file surfaces paint with: Herdr's roles from the active theme's tokens, plus
//! the Swift palette roles the editor, diff and Markdown views colored text with
//! (`mergedForeground`, `infoForeground`, … in `AgentsStyle/Palette.swift`), and the two syntax
//! color maps they used: the editor/diff map (`DiffStyle.syntaxColor`) and the chat/reader map
//! (`MarkdownRenderer.syntaxColor`, the reader's `tok-*` CSS).

use gpui::{App, Hsla};
use soprano_text::SyntaxTokenKind;
use soprano_ui::ActiveSopranoTheme;
use soprano_ui::color::hsla;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SurfaceColors {
    pub is_dark: bool,
    pub background: Hsla,
    pub foreground: Hsla,
    pub muted: Hsla,
    pub dim: Hsla,
    pub border: Hsla,
    pub hover: Hsla,
    pub selected: Hsla,
    pub raised: Hsla,
    pub popover: Hsla,
    pub input: Hsla,
    /// Selected text (Herdr's `selection`).
    pub selection: Hsla,
    /// Focus and find highlights (Herdr's `accent`).
    pub accent: Hsla,
    pub cursor: Hsla,
    /// `mergedForeground`: the theme's accent (keywords).
    pub merged: Hsla,
    /// `infoForeground`: blue (links, strings in the editor).
    pub info: Hsla,
    /// `warningForeground`: yellow ("Modified", numbers).
    pub warning: Hsla,
    /// `successForeground`: green.
    pub success: Hsla,
    /// `errorForeground`: red ("Changed on disk").
    pub error: Hsla,
    /// `inputForeground`: cyan (types in the editor).
    pub input_tone: Hsla,
    pub diff_add: Hsla,
    pub diff_add_word: Hsla,
    pub diff_delete: Hsla,
    pub diff_delete_word: Hsla,
    pub diff_add_foreground: Hsla,
    pub diff_delete_foreground: Hsla,
}

impl SurfaceColors {
    /// The active theme's colors.
    pub fn of(cx: &App) -> Self {
        let theme = cx.soprano_theme();
        let palette = &theme.theme().colors;
        Self {
            is_dark: theme.is_dark(),
            background: theme.background,
            foreground: theme.foreground,
            muted: theme.muted,
            dim: theme.dim,
            border: theme.border,
            hover: theme.hover,
            selected: theme.selected,
            raised: theme.raised,
            popover: theme.popover,
            input: theme.input,
            selection: theme.selection,
            accent: theme.accent,
            cursor: theme.cursor,
            merged: hsla(palette.accent),
            info: hsla(palette.blue),
            warning: hsla(palette.yellow),
            success: hsla(palette.success),
            error: hsla(palette.danger),
            input_tone: hsla(palette.cyan),
            diff_add: theme.diff_add,
            diff_add_word: theme.diff_add_word,
            diff_delete: theme.diff_delete,
            diff_delete_word: theme.diff_delete_word,
            diff_add_foreground: theme.diff_add_foreground,
            diff_delete_foreground: theme.diff_delete_foreground,
        }
    }

    /// The editor's and the diff's syntax colors (`DiffStyle.syntaxColor`).
    pub fn code_syntax(&self, kind: SyntaxTokenKind) -> Hsla {
        match kind {
            SyntaxTokenKind::Keyword | SyntaxTokenKind::Tag | SyntaxTokenKind::Heading => self.merged,
            SyntaxTokenKind::String => self.info,
            SyntaxTokenKind::Comment => self.muted,
            SyntaxTokenKind::Number | SyntaxTokenKind::Attribute => self.warning,
            SyntaxTokenKind::Type => self.input_tone,
            SyntaxTokenKind::Function | SyntaxTokenKind::Key => self.foreground,
            SyntaxTokenKind::Inserted => self.diff_add_foreground,
            SyntaxTokenKind::Deleted => self.diff_delete_foreground,
        }
    }

    /// Code blocks in chat answers and the reader (`MarkdownRenderer.syntaxColor`, `tok-*`).
    pub fn markdown_syntax(&self, kind: SyntaxTokenKind) -> Hsla {
        match kind {
            SyntaxTokenKind::Keyword | SyntaxTokenKind::Tag => self.merged,
            SyntaxTokenKind::Heading => self.foreground,
            SyntaxTokenKind::String | SyntaxTokenKind::Inserted => self.success,
            SyntaxTokenKind::Comment => self.muted,
            SyntaxTokenKind::Number | SyntaxTokenKind::Attribute => self.warning,
            SyntaxTokenKind::Type | SyntaxTokenKind::Function | SyntaxTokenKind::Key => self.info,
            SyntaxTokenKind::Deleted => self.error,
        }
    }

    /// The background of a Markdown code block: the input wash in dark themes, a raised
    /// panel in light ones (`CodeBlockView.applyPalette`).
    pub fn code_block_background(&self) -> Hsla {
        if self.is_dark { self.foreground.opacity(0.045) } else { self.raised }
    }

    /// The muted strip behind a diff fold and the filler of a missing split side.
    pub fn wash(&self, dark: f32, light: f32) -> Hsla {
        self.foreground.opacity(if self.is_dark { dark } else { light })
    }
}
