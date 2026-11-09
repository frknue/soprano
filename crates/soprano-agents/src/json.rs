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

pub(crate) fn parse_object(bytes: &[u8]) -> Option<Object> {
    match serde_json::from_slice::<Value>(bytes).ok()? {
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
