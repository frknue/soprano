//! Loose JSON access in the style the Swift decoders used (`record["x"] as? String`): every
//! accessor returns `None` when the key is missing or holds another type.

use serde_json::{Map, Value};

pub type Object = Map<String, Value>;

/// The JSON value `JsonValue` names in the agent protocols (the Swift `JSONValue`).
pub type JsonValue = Value;

/// Swift `JSONValue` conveniences on `serde_json::Value`.
pub trait JsonValueExt {
    /// A string that holds more than whitespace.
    fn non_empty_string(&self) -> Option<&str>;
    /// The number truncated toward zero (Swift `Int(double)`).
    fn int(&self) -> Option<i64>;
}

impl JsonValueExt for Value {
    fn non_empty_string(&self) -> Option<&str> {
        self.as_str().filter(|s| !s.trim().is_empty())
    }

    fn int(&self) -> Option<i64> {
        self.as_i64().or_else(|| self.as_u64().map(|v| v as i64)).or_else(|| self.as_f64().map(|v| v as i64))
    }
}

/// The deepest nesting `JSONSerialization` reads. serde_json alone stops at 128, which would
/// drop records Swift kept (and with them, for tree transcripts, the history before them).
pub const MAX_NESTING_DEPTH: usize = 512;

/// One JSON document, nested up to [`MAX_NESTING_DEPTH`] levels; `None` when malformed or
/// deeper.
pub fn parse_value(bytes: &[u8]) -> Option<Value> {
    if nesting_depth(bytes) > MAX_NESTING_DEPTH {
        return None;
    }
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    // Bounded by the scan above, so the recursion stays within the stack.
    deserializer.disable_recursion_limit();
    let value = serde::Deserialize::deserialize(&mut deserializer).ok()?;
    deserializer.end().ok()?;
    Some(value)
}

/// The deepest array/object nesting in `bytes`, ignoring brackets inside strings.
fn nesting_depth(bytes: &[u8]) -> usize {
    let (mut depth, mut deepest) = (0usize, 0usize);
    let (mut in_string, mut escaped) = (false, false);
    for &byte in bytes {
        if in_string {
            match byte {
                _ if escaped => escaped = false,
                b'\\' => escaped = true,
                b'"' => in_string = false,
                _ => {}
            }
            continue;
        }
        match byte {
            b'"' => in_string = true,
            b'[' | b'{' => {
                depth += 1;
                deepest = deepest.max(depth);
            }
            b']' | b'}' => depth = depth.saturating_sub(1),
            _ => {}
        }
    }
    deepest
}

pub(crate) fn parse_object(bytes: &[u8]) -> Option<Object> {
    match parse_value(bytes)? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

pub(crate) fn str_at<'a>(object: &'a Object, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

pub(crate) fn obj_at<'a>(object: &'a Object, key: &str) -> Option<&'a Object> {
    object.get(key).and_then(Value::as_object)
}

/// `value as? [String: Any] ?? [:]`.
pub(crate) fn dict(value: Option<&Value>) -> &Object {
    static EMPTY: std::sync::LazyLock<Object> = std::sync::LazyLock::new(Object::new);
    value.and_then(Value::as_object).unwrap_or(&EMPTY)
}

pub(crate) fn bool_true(object: &Object, key: &str) -> bool {
    object.get(key).and_then(Value::as_bool) == Some(true)
}

/// `value as? [[String: Any]]`: an array whose every element is an object.
pub(crate) fn objects(value: Option<&Value>) -> Option<Vec<&Object>> {
    value?.as_array()?.iter().map(Value::as_object).collect()
}

pub(crate) fn objects_at<'a>(object: &'a Object, key: &str) -> Vec<&'a Object> {
    objects(object.get(key)).unwrap_or_default()
}

/// `value as? [String]`.
pub(crate) fn strings(value: Option<&Value>) -> Option<Vec<&str>> {
    value?.as_array()?.iter().map(Value::as_str).collect()
}

/// `(value as? NSNumber)?.intValue`: numbers truncate, booleans count as 0 or 1.
pub(crate) fn number_int(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Bool(b) => Some(i64::from(*b)),
        v @ Value::Number(_) => v.int(),
        _ => None,
    }
}

pub(crate) fn number_f64(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        Value::Number(n) => n.as_f64(),
        _ => None,
    }
}

/// A string that holds more than whitespace.
pub(crate) fn non_empty(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str).filter(|s| !s.trim().is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn nested(depth: usize) -> String {
        format!("{}1{}", "[".repeat(depth), "]".repeat(depth))
    }

    #[test]
    fn documents_nested_as_deep_as_foundation_reads_them_parse() {
        assert!(parse_value(nested(300).as_bytes()).is_some());
        assert!(parse_value(nested(MAX_NESTING_DEPTH).as_bytes()).is_some());
        assert!(parse_value(nested(MAX_NESTING_DEPTH + 1).as_bytes()).is_none());
    }

    #[test]
    fn brackets_inside_strings_do_not_count_as_nesting() {
        let text = format!(r#"{{"a":"{}\"]["}}"#, "[".repeat(1_000));
        assert_eq!(parse_value(text.as_bytes()).and_then(|v| v["a"].as_str().map(str::len)), Some(1_003));
        assert!(parse_value(b"{} trailing").is_none());
    }
}
