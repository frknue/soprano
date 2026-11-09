//! Finder's "natural" name order, the cross-platform stand-in for Foundation's
//! `localizedStandardCompare`: case-insensitive, with runs of digits compared by value
//! ("file2" before "file10").

use std::cmp::Ordering;

/// Compares `lhs` and `rhs` the way Finder orders names. Names that differ only in case
/// (or in leading zeros) compare equal; callers break such ties themselves.
pub fn natural_compare(lhs: &str, rhs: &str) -> Ordering {
    let mut left = lhs.chars().peekable();
    let mut right = rhs.chars().peekable();
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
                let order = l.to_lowercase().cmp(r.to_lowercase());
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

fn take_digits(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> String {
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
}
