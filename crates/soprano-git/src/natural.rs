//! Finder's "natural" name order, the cross-platform stand-in for Foundation's
//! `localizedStandardCompare`: case- and diacritic-insensitive ("Ärger" sorts with the
//! A's), with runs of digits compared by value ("file2" before "file10").

use std::cmp::Ordering;
use std::iter::Peekable;

use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// Compares `lhs` and `rhs` the way Finder orders names. Names that differ only in case,
/// accents (or leading zeros) compare equal; callers break such ties themselves.
pub fn natural_compare(lhs: &str, rhs: &str) -> Ordering {
    let mut left = folded(lhs);
    let mut right = folded(rhs);
    loop {
        match (left.peek().copied(), right.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(l), Some(r)) if l.is_ascii_digit() && r.is_ascii_digit() => {
                let a = take_digits(&mut left);
                let b = take_digits(&mut right);
                let a = a.trim_start_matches('0');
                let b = b.trim_start_matches('0');
                let order = a.len().cmp(&b.len()).then_with(|| a.cmp(b));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(l), Some(r)) => {
                left.next();
                right.next();
                let order = l.cmp(&r);
                if order != Ordering::Equal {
                    return order;
                }
            }
        }
    }
}

/// Natural order with exact code-point order breaking ties, so sorting is total.
pub fn natural_compare_then_exact(lhs: &str, rhs: &str) -> Ordering {
    natural_compare(lhs, rhs).then_with(|| lhs.cmp(rhs))
}

/// Decomposed, without combining marks, lowercased.
fn folded(text: &str) -> Peekable<impl Iterator<Item = char> + '_> {
    text.nfd().filter(|c| !is_combining_mark(*c)).flat_map(char::to_lowercase).peekable()
}

fn take_digits(chars: &mut Peekable<impl Iterator<Item = char>>) -> String {
    let mut digits = String::new();
    while let Some(c) = chars.peek().copied().filter(char::is_ascii_digit) {
        digits.push(c);
        chars.next();
    }
    digits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_compare_by_value_and_letters_ignore_case() {
        assert_eq!(natural_compare("file2", "file10"), Ordering::Less);
        assert_eq!(natural_compare("a.md", "B.md"), Ordering::Less);
        assert_eq!(natural_compare("Docs", "docs"), Ordering::Equal);
        assert_eq!(natural_compare(".env", "a.md"), Ordering::Less);
        assert_eq!(natural_compare_then_exact("Docs", "docs"), Ordering::Less);
    }

    #[test]
    fn accented_letters_sort_with_their_base_letter() {
        assert_eq!(natural_compare("Ärger", "Zoo"), Ordering::Less);
        assert_eq!(natural_compare("Ärger", "Apfel"), Ordering::Greater);
        assert_eq!(natural_compare("école", "ecole"), Ordering::Equal);
        assert_ne!(natural_compare_then_exact("école", "ecole"), Ordering::Equal);
    }
}
