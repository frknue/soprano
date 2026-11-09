//! Decoding script results and formatting them the way the Swift app prints them.

use serde_json::Value;

/// `WKError.javaScriptExceptionOccurred`'s description, which the Swift app reports for a
/// script that throws.
pub const EXCEPTION_MESSAGE: &str = "A JavaScript exception occurred";
/// `WKError.javaScriptResultTypeIsUnsupported`'s description.
pub const UNSUPPORTED_RESULT_MESSAGE: &str = "JavaScript execution returned a result of an unsupported type";
/// The page went away (navigation, closed pane) before the script answered.
pub const CANCELLED_MESSAGE: &str = "The page did not finish running the script";

/// A script's outcome as the Swift app's completion handler sees it: `None` is `nil`
/// (`undefined`), `Some(Value::Null)` is `NSNull`.
pub type ScriptResult = Result<Option<Value>, String>;

/// Decodes the JSON text the web view returns for a script wrapped by
/// [`crate::scripts::wrap_expression`] or [`crate::scripts::wrap_program`]: wry hands back the
/// envelope's string as a JSON string literal.
pub fn decode_envelope(raw: &str) -> ScriptResult {
    let envelope: String = serde_json::from_str(raw).map_err(|_| EXCEPTION_MESSAGE.to_string())?;
    let Value::Object(mut fields) =
        serde_json::from_str::<Value>(&envelope).map_err(|_| EXCEPTION_MESSAGE.to_string())?
    else {
        return Err(EXCEPTION_MESSAGE.to_string());
    };
    if fields.get("exception").is_some_and(|flag| flag == &Value::Bool(true)) {
        return Err(EXCEPTION_MESSAGE.to_string());
    }
    if fields.get("unsupported").is_some_and(|flag| flag == &Value::Bool(true)) {
        return Err(UNSUPPORTED_RESULT_MESSAGE.to_string());
    }
    if fields.get("undefined").is_some_and(|flag| flag == &Value::Bool(true)) {
        return Ok(None);
    }
    Ok(fields.remove("value"))
}

/// `printableJavaScriptValue`: arrays and objects as pretty JSON with sorted keys (Foundation's
/// `JSONSerialization` layout), anything else as `String(describing:)` would show it.
pub fn printable(value: Option<&Value>) -> String {
    match value {
        None => "null".to_string(),
        Some(value @ (Value::Array(_) | Value::Object(_))) => {
            let mut output = String::new();
            write_pretty(value, 0, &mut output);
            output
        }
        Some(Value::String(text)) => text.clone(),
        // NSNumber booleans describe themselves as 1 and 0.
        Some(Value::Bool(flag)) => if *flag { "1" } else { "0" }.to_string(),
        Some(Value::Number(number)) => number_description(number),
        Some(Value::Null) => "<null>".to_string(),
    }
}

/// The result of a script whose answer is a string (`value as? String ?? ""`).
pub fn string_result(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        _ => String::new(),
    }
}

/// The result of an action script: `{ok: true, output}` succeeds with `output` (or `ok`);
/// otherwise its `error`, or "Element not found" for `selector`.
pub fn action_result(value: Option<&Value>, selector: &str) -> Result<String, String> {
    let payload = value.and_then(Value::as_object);
    if payload.and_then(|fields| fields.get("ok")) == Some(&Value::Bool(true)) {
        let output = payload.and_then(|fields| fields.get("output")).and_then(Value::as_str);
        return Ok(output.unwrap_or("ok").to_string());
    }
    match payload.and_then(|fields| fields.get("error")).and_then(Value::as_str) {
        Some(message) => Err(message.to_string()),
        None => Err(format!("Element not found: {selector}")),
    }
}

fn number_description(number: &serde_json::Number) -> String {
    if let Some(integer) = number.as_i64() {
        return integer.to_string();
    }
    if let Some(integer) = number.as_u64() {
        return integer.to_string();
    }
    let float = number.as_f64().unwrap_or(0.0);
    if float.fract() == 0.0 && float.abs() < 1e15 { format!("{float:.0}") } else { float.to_string() }
}

fn write_pretty(value: &Value, depth: usize, output: &mut String) {
    let indent = |depth: usize, output: &mut String| output.push_str(&"  ".repeat(depth));
    match value {
        Value::Array(items) => {
            output.push_str("[\n");
            for (index, item) in items.iter().enumerate() {
                indent(depth + 1, output);
                write_pretty(item, depth + 1, output);
                if index + 1 < items.len() {
                    output.push(',');
                }
                output.push('\n');
            }
            if items.is_empty() {
                output.push('\n');
            }
            indent(depth, output);
            output.push(']');
        }
        Value::Object(fields) => {
            let mut keys: Vec<&String> = fields.keys().collect();
            keys.sort();
            output.push_str("{\n");
            for (index, key) in keys.iter().enumerate() {
                indent(depth + 1, output);
                output.push_str(&crate::scripts::literal(key));
                output.push_str(" : ");
                write_pretty(&fields[*key], depth + 1, output);
                if index + 1 < keys.len() {
                    output.push(',');
                }
                output.push('\n');
            }
            if keys.is_empty() {
                output.push('\n');
            }
            indent(depth, output);
            output.push('}');
        }
        Value::String(text) => output.push_str(&crate::scripts::literal(text)),
        Value::Bool(flag) => output.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => output.push_str(&number_description(number)),
        Value::Null => output.push_str("null"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn wrapped(envelope: Value) -> String {
        serde_json::to_string(&envelope.to_string()).expect("a JSON string")
    }

    #[test]
    fn envelopes_decode_values_undefined_and_failures() {
        assert_eq!(decode_envelope(&wrapped(json!({"value": "hi"}))), Ok(Some(json!("hi"))));
        assert_eq!(decode_envelope(&wrapped(json!({"value": null}))), Ok(Some(Value::Null)));
        assert_eq!(decode_envelope(&wrapped(json!({"undefined": true}))), Ok(None));
        assert_eq!(decode_envelope(&wrapped(json!({"exception": true}))), Err(EXCEPTION_MESSAGE.to_string()));
        assert_eq!(
            decode_envelope(&wrapped(json!({"unsupported": true}))),
            Err(UNSUPPORTED_RESULT_MESSAGE.to_string())
        );
        assert_eq!(decode_envelope(""), Err(EXCEPTION_MESSAGE.to_string()));
    }

    #[test]
    fn printable_values_match_foundation_descriptions() {
        assert_eq!(printable(None), "null");
        assert_eq!(printable(Some(&Value::Null)), "<null>");
        assert_eq!(printable(Some(&json!("name=Ada,agree=true"))), "name=Ada,agree=true");
        assert_eq!(printable(Some(&json!(true))), "1");
        assert_eq!(printable(Some(&json!(false))), "0");
        assert_eq!(printable(Some(&json!(42))), "42");
        assert_eq!(printable(Some(&json!(42.0))), "42");
        assert_eq!(printable(Some(&json!(3.5))), "3.5");
    }

    #[test]
    fn collections_print_as_pretty_json_with_sorted_keys() {
        assert_eq!(
            printable(Some(&json!({"b": [1, true], "a": "x/y", "c": {}}))),
            "{\n  \"a\" : \"x\\/y\",\n  \"b\" : [\n    1,\n    true\n  ],\n  \"c\" : {\n\n  }\n}"
        );
        assert_eq!(printable(Some(&json!([]))), "[\n\n]");
    }

    #[test]
    fn action_results_report_output_errors_or_a_missing_element() {
        assert_eq!(
            action_result(Some(&json!({"ok": true, "output": "click #a"})), "#a"),
            Ok("click #a".into())
        );
        assert_eq!(action_result(Some(&json!({"ok": true})), "#a"), Ok("ok".into()));
        assert_eq!(
            action_result(Some(&json!({"ok": false, "error": "Element is not editable"})), "#a"),
            Err("Element is not editable".into())
        );
        assert_eq!(action_result(Some(&json!(7)), "#a"), Err("Element not found: #a".into()));
        assert_eq!(action_result(None, "@e9"), Err("Element not found: @e9".into()));
    }

    #[test]
    fn string_results_fall_back_to_empty() {
        assert_eq!(string_result(Some(&json!("- button \"Go\" [ref=e1]"))), "- button \"Go\" [ref=e1]");
        assert_eq!(string_result(Some(&json!(1))), "");
        assert_eq!(string_result(None), "");
    }
}
