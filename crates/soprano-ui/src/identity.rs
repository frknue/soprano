//! Project identity: the monogram and its color (`ShellProjectIdentity`, `ShellMonogramView`)
//! and Herdr's 18 px letter avatar (HERDR-UI.md §5.2) colored the same way.

use gpui::{
    App, FontWeight, Hsla, IntoElement, ParentElement, RenderOnce, SharedString, Styled, Window, div,
};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

use crate::fonts::{self, size};
use crate::theme::ActiveSopranoTheme;

/// NFKC, trimmed (`precomposedStringWithCompatibilityMapping` + whitespace trim).
fn normalized(name: &str) -> String {
    name.nfkc().collect::<String>().trim().to_owned()
}

/// Swift's `CharacterSet.letters ∪ .decimalDigits`: the L* and M* categories and Nd.
fn is_word_scalar(c: char) -> bool {
    use unicode_general_category::{GeneralCategory as G, get_general_category};
    matches!(
        get_general_category(c),
        G::UppercaseLetter
            | G::LowercaseLetter
            | G::TitlecaseLetter
            | G::ModifierLetter
            | G::OtherLetter
            | G::NonspacingMark
            | G::SpacingMark
            | G::EnclosingMark
            | G::DecimalNumber
    )
}

/// Han ideographs with a Unicode numeric type (Unihan kPrimaryNumeric, kAccountingNumeric and
/// kOtherNumeric), which Swift's `Character.isNumber` counts though their category is Lo.
const HAN_NUMERALS: &str =
    "〇零一二三四五六七八九十百千万萬亿億兆壹贰貳弍叁參弎肆伍陆陸柒捌玖拾佰仟廿卅卌两兩弌";

/// `Character.isNumber`: the cluster's first scalar has a numeric type (Nd, Nl, No, or a
/// numeric Han ideograph).
fn is_number(grapheme: &str) -> bool {
    grapheme.chars().next().is_some_and(|c| c.is_numeric() || HAN_NUMERALS.contains(c))
}

/// Two glyphs for a project name (`ShellProjectIdentity.monogram`), by grapheme cluster: the
/// first one, then the first number after it in the first word, else the first glyph of the
/// last word, else the word's last glyph. "PR" without letters or digits.
pub fn monogram(name: &str) -> String {
    let normalized = normalized(name);
    let words: Vec<&str> = normalized.split(|c: char| !is_word_scalar(c)).filter(|w| !w.is_empty()).collect();
    let Some(first_word) = words.first() else { return "PR".into() };
    let glyphs: Vec<&str> = first_word.graphemes(true).collect();
    let Some(first) = glyphs.first().copied() else { return "PR".into() };
    let second = glyphs[1..]
        .iter()
        .copied()
        .find(|g| is_number(g))
        .or_else(|| {
            if words.len() > 1 {
                words.last().and_then(|w| w.graphemes(true).next())
            } else {
                glyphs.last().copied()
            }
        })
        .unwrap_or(first);
    format!("{first}{second}").to_uppercase().graphemes(true).take(2).collect()
}

/// Index into the project colors: `(index * 31 + codePoint) % count` over the lowercased,
/// normalized name ("project" when empty).
pub fn project_color_index(name: &str, count: usize) -> usize {
    if count == 0 {
        return 0;
    }
    let normalized = normalized(name);
    let seed = if normalized.is_empty() { "project".to_owned() } else { normalized.to_lowercase() };
    seed.chars().fold(0usize, |index, scalar| (index * 31 + scalar as usize) % count)
}

/// The project color for `name` in the current theme.
pub fn project_color(name: &str, cx: &App) -> Hsla {
    let colors = &cx.soprano_theme().project_colors;
    colors[project_color_index(name, colors.len())]
}

/// Herdr's avatar: an 18×18 r5 tile in the project color with the name's first letter in
/// white, 10.5 px bold.
#[derive(IntoElement)]
pub struct Avatar {
    name: SharedString,
    color: Option<Hsla>,
    size: f32,
}

impl Avatar {
    pub fn new(name: impl Into<SharedString>) -> Self {
        Self { name: name.into(), color: None, size: 18.0 }
    }

    /// Overrides the fill (e.g. `dim` for the home space).
    pub fn color(mut self, color: Hsla) -> Self {
        self.color = Some(color);
        self
    }

    /// Side in designed px (18 by default); the radius and letter scale with it.
    pub fn size(mut self, size: f32) -> Self {
        self.size = size;
        self
    }

    /// The letter shown: the first letter or digit, uppercased.
    pub fn letter(name: &str) -> String {
        name.chars().find(|c| c.is_alphanumeric()).map(|c| c.to_uppercase().collect()).unwrap_or_default()
    }
}

impl RenderOnce for Avatar {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let fill = self.color.unwrap_or_else(|| project_color(&self.name, cx));
        let theme = cx.soprano_theme();
        let scale = self.size / 18.0;
        div()
            .flex()
            .flex_none()
            .items_center()
            .justify_center()
            .size(theme.z(self.size))
            .rounded(theme.z(5.0 * scale))
            .bg(fill)
            .text_color(theme.avatar_letter)
            .text_size(theme.z(size::BADGE * scale))
            .font_weight(FontWeight::BOLD)
            .font_family(fonts::UI_FONT_FAMILY)
            .child(SharedString::from(Self::letter(&self.name)))
    }
}

/// Soprano Agents' monogram tile: two glyphs in the project color on a 14 % tint of it,
/// rounded 25 %, mono 8.25 bold at the 16 px design size.
#[derive(IntoElement)]
pub struct Monogram {
    name: SharedString,
    size: f32,
}

impl Monogram {
    pub fn new(name: impl Into<SharedString>) -> Self {
        Self { name: name.into(), size: 16.0 }
    }

    pub fn size(mut self, size: f32) -> Self {
        self.size = size;
        self
    }
}

impl RenderOnce for Monogram {
    fn render(self, _: &mut Window, cx: &mut App) -> impl IntoElement {
        let color = project_color(&self.name, cx);
        let theme = cx.soprano_theme();
        let scale = self.size / 16.0;
        div()
            .flex()
            .flex_none()
            .items_center()
            .justify_center()
            .size(theme.z(self.size))
            .rounded(theme.z(self.size * 0.25))
            .bg(color.opacity(color.a * 0.14))
            .text_color(color)
            .text_size(theme.z(8.25 * scale))
            .font_weight(FontWeight::BOLD)
            .font_family(fonts::MONO_FONT_FAMILY)
            .child(SharedString::from(monogram(&self.name)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_monogram_takes_the_first_letters_of_the_first_and_last_words() {
        assert_eq!(monogram("storefront theme"), "ST");
        assert_eq!(monogram("my-cool-app"), "MA");
        assert_eq!(monogram("  soprano  "), "SO");
    }

    #[test]
    fn a_digit_in_the_first_word_wins_the_second_glyph() {
        assert_eq!(monogram("web3 dashboard"), "W3");
        assert_eq!(monogram("h2o"), "H2");
    }

    #[test]
    fn a_one_letter_name_doubles_it_and_no_letters_read_pr() {
        assert_eq!(monogram("x"), "XX");
        assert_eq!(monogram("---"), "PR");
        assert_eq!(monogram(""), "PR");
    }

    #[test]
    fn monograms_work_on_grapheme_clusters_and_count_han_numerals_as_numbers() {
        assert_eq!(monogram("第三版"), "第三");
        // Devanagari vowel signs are marks: the whole word is one word of clusters.
        assert_eq!(
            monogram("हिन्दी"),
            format!("हि{}", "हिन्दी".graphemes(true).next_back().unwrap_or_default())
        );
        assert_eq!(monogram("e\u{301}clair"), "ÉR");
    }

    #[test]
    fn compatibility_forms_are_normalized() {
        // Full-width letters fold to ASCII under NFKC.
        assert_eq!(monogram("ｓｏｐｒａｎｏ"), "SO");
    }

    #[test]
    fn the_color_index_hashes_the_lowercased_name() {
        let index = |name| project_color_index(name, 7);
        assert_eq!(index("Soprano"), index("soprano"));
        assert_eq!(index(" soprano "), index("soprano"));
        assert_eq!(index(""), index("project"));
        let expected = "soprano".chars().fold(0usize, |i, c| (i * 31 + c as usize) % 7);
        assert_eq!(index("soprano"), expected);
        assert!(index("anything") < 7);
    }

    #[test]
    fn the_avatar_letter_is_the_first_letter_uppercased() {
        assert_eq!(Avatar::letter("dotfiles"), "D");
        assert_eq!(Avatar::letter("~"), "");
        assert_eq!(Avatar::letter("~/work"), "W");
    }
}
