//! Find in the editor (⌘F / ⌘G / ⇧⌘G): case-insensitive "contains" matching, as the
//! editor's find bar is configured (NSTextFinder's default "Ignore Case", "Contains").
//! Ranges are UTF-8 byte ranges of the searched text; next and previous wrap around.

use std::ops::Range;

/// Every non-overlapping match of `query` in `text`, in order. An empty query matches nothing.
pub fn find_all(text: &str, query: &str) -> Vec<Range<usize>> {
    let mut matches = Vec::new();
    let mut from = 0;
    while let Some(found) = match_at_or_after(text, query, from) {
        from = found.end;
        matches.push(found);
    }
    matches
}

/// The first match starting at or after `from`, wrapping to the start of the text.
pub fn find_next(text: &str, query: &str, from: usize) -> Option<Range<usize>> {
    match_at_or_after(text, query, from.min(text.len())).or_else(|| match_at_or_after(text, query, 0))
}

/// The last match ending at or before `before`, wrapping to the end of the text.
pub fn find_previous(text: &str, query: &str, before: usize) -> Option<Range<usize>> {
    let matches = find_all(text, query);
    matches.iter().rev().find(|found| found.end <= before).or_else(|| matches.last()).cloned()
}

fn match_at_or_after(text: &str, query: &str, from: usize) -> Option<Range<usize>> {
    if query.is_empty() {
        return None;
    }
    if query.is_ascii() {
        // ASCII bytes only ever start ASCII characters, so every hit is on a boundary.
        let needle = query.as_bytes();
        let haystack = text.as_bytes();
        if haystack.len() < needle.len() {
            return None;
        }
        return (from..=haystack.len() - needle.len())
            .find(|start| haystack[*start..*start + needle.len()].eq_ignore_ascii_case(needle))
            .map(|start| start..start + needle.len());
    }
    let folded: Vec<char> = query.chars().flat_map(char::to_lowercase).collect();
    text.char_indices().filter(|(start, _)| *start >= from).find_map(|(start, _)| {
        let mut wanted = folded.iter();
        let mut end = start;
        for character in text[start..].chars() {
            for lower in character.to_lowercase() {
                if wanted.next() != Some(&lower) {
                    return None;
                }
            }
            end += character.len_utf8();
            if wanted.len() == 0 {
                return Some(start..end);
            }
        }
        None
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matching_ignores_case_and_returns_byte_ranges() {
        let text = "Let a = 1\nlet B = 2\nLET";
        assert_eq!(find_all(text, "let"), [0..3, 10..13, 20..23]);
        assert_eq!(find_all("Grüße GRÜSSE grüße", "GRÜẞE"), [0..7, 16..23]);
        assert_eq!(find_all("Grüße GRÜßE", "grüße"), [0..7, 8..15]);
        assert!(find_all(text, "").is_empty());
    }

    #[test]
    fn next_and_previous_wrap_around_the_text() {
        let text = "one two one two";
        assert_eq!(find_next(text, "two", 0), Some(4..7));
        assert_eq!(find_next(text, "two", 5), Some(12..15));
        assert_eq!(find_next(text, "two", 13), Some(4..7));
        assert_eq!(find_previous(text, "one", 8), Some(0..3));
        assert_eq!(find_previous(text, "one", 2), Some(8..11));
        assert_eq!(find_next(text, "three", 0), None);
    }
}
