//! The JavaScript the browser pane injects for `soprano browser` automation. Each script
//! reproduces the Swift app's text exactly, including its layout, so pages see the same code.

/// Substitutes `«NAME»` markers in `template` in one pass, so a substituted value (a selector
/// or typed text) is never itself scanned for markers.
fn fill(template: &str, values: &[(&str, &str)]) -> String {
    let mut output = String::with_capacity(template.len() + 256);
    let mut rest = template;
    loop {
        let next = values
            .iter()
            .filter_map(|(marker, value)| rest.find(marker).map(|index| (index, *marker, *value)))
            .min_by_key(|(index, _, _)| *index);
        let Some((index, marker, value)) = next else {
            output.push_str(rest);
            return output;
        };
        output.push_str(&rest[..index]);
        output.push_str(value);
        rest = &rest[index + marker.len()..];
    }
}

/// A JavaScript string literal for `value`, encoded like Swift's `JSONEncoder` (which also
/// escapes `/`).
pub fn literal(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len() + 2);
    encoded.push('"');
    for character in value.chars() {
        match character {
            '"' => encoded.push_str("\\\""),
            '\\' => encoded.push_str("\\\\"),
            '/' => encoded.push_str("\\/"),
            '\n' => encoded.push_str("\\n"),
            '\r' => encoded.push_str("\\r"),
            '\t' => encoded.push_str("\\t"),
            '\u{8}' => encoded.push_str("\\b"),
            '\u{c}' => encoded.push_str("\\f"),
            control if u32::from(control) < 0x20 => {
                encoded.push_str(&format!("\\u{:04x}", u32::from(control)));
            }
            other => encoded.push(other),
        }
    }
    encoded.push('"');
    encoded
}

pub fn resolver_prelude(selector: &str) -> String {
    fill(
        r#"const selector = «SELECTOR»;
const resolve = (value) => {
  if (value.startsWith('@')) {
    return window.__sopranoElementRefs?.[value.slice(1)] || null;
  }
  try { return document.querySelector(value); } catch (_) { return null; }
};
const element = resolve(selector);
if (!element) return {ok: false, error: `Element not found: ${selector}`};"#,
        &[("«SELECTOR»", &literal(selector))],
    )
}

/// Assigns through the element's prototype setter. Frameworks such as React shadow
/// `value`/`checked` on the element itself to track the last value they set, and ignore an
/// `input` event that does not change it.
pub const NATIVE_SETTER_PRELUDE: &str = r#"const setNative = (target, property, value) => {
  for (let proto = Object.getPrototypeOf(target); proto; proto = Object.getPrototypeOf(proto)) {
    const setter = Object.getOwnPropertyDescriptor(proto, property)?.set;
    if (setter) { setter.call(target, value); return; }
  }
  target[property] = value;
};"#;

/// A real click toggles the box the way a user does (React listens for `click` on
/// checkboxes); the native setter covers a click that did not land, such as unchecking a radio
/// button.
fn checked_action(checked: bool) -> String {
    let checked = if checked { "true" } else { "false" };
    fill(
        r#"if (!('checked' in element)) return {ok: false, error: 'Element is not checkable'};
if (element.checked !== «CHECKED») element.click();
if (element.checked !== «CHECKED») {
  «SETTER»
  setNative(element, 'checked', «CHECKED»);
  element.dispatchEvent(new Event('input', {bubbles: true}));
  element.dispatchEvent(new Event('change', {bubbles: true}));
}"#,
        &[("«CHECKED»", checked), ("«SETTER»", NATIVE_SETTER_PRELUDE)],
    )
}

pub fn element_action_script(command: &str, selector: &str) -> String {
    let action = match command {
        "click" => "element.click();".to_string(),
        "dblclick" => {
            "element.dispatchEvent(new MouseEvent('dblclick', {bubbles: true, cancelable: true, view: window}));"
                .to_string()
        }
        "focus" => "element.focus();".to_string(),
        "hover" => "element.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, view: window}));\n\
                    element.dispatchEvent(new MouseEvent('mouseenter', {bubbles: false, view: window}));"
            .to_string(),
        "check" => checked_action(true),
        "uncheck" => checked_action(false),
        "scroll-into-view" => "element.scrollIntoView({block: 'center', inline: 'center'});".to_string(),
        _ => String::new(),
    };
    fill(
        r#"(() => {
  «PRELUDE»
  element.scrollIntoView({block: 'center', inline: 'center'});
  «ACTION»
  return {ok: true, output: «OUTPUT»};
})()"#,
        &[
            ("«PRELUDE»", &resolver_prelude(selector)),
            ("«ACTION»", &action),
            ("«OUTPUT»", &literal(&format!("{command} {selector}"))),
        ],
    )
}

pub fn text_action_script(command: &str, selector: &str, text: &str) -> String {
    let fill_command = command == "fill";
    let assignment = if fill_command {
        "setNative(element, 'value', text);"
    } else {
        "setNative(element, 'value', String(element.value || '') + text);"
    };
    let content = if fill_command { "text" } else { "String(element.textContent || '') + text" };
    fill(
        r#"(() => {
  «PRELUDE»
  const text = «TEXT»;
  «SETTER»
  element.focus();
  if (element.isContentEditable) {
    element.textContent = «CONTENT»;
  } else if ('value' in element) {
    «ASSIGNMENT»
  } else {
    return {ok: false, error: 'Element is not editable'};
  }
  element.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: text}));
  element.dispatchEvent(new Event('change', {bubbles: true}));
  return {ok: true, output: «OUTPUT»};
})()"#,
        &[
            ("«PRELUDE»", &resolver_prelude(selector)),
            ("«TEXT»", &literal(text)),
            ("«SETTER»", NATIVE_SETTER_PRELUDE),
            ("«CONTENT»", content),
            ("«ASSIGNMENT»", assignment),
            ("«OUTPUT»", &literal(&format!("{command} {selector}"))),
        ],
    )
}

pub fn key_press_script(key: &str) -> String {
    fill(
        r#"(() => {
  const element = document.activeElement || document.body;
  «SETTER»
  const key = «KEY»;
  const aliases = {Enter: 'Enter', Escape: 'Escape', Tab: 'Tab', Space: ' '};
  const resolved = aliases[key] || key;
  element.dispatchEvent(new KeyboardEvent('keydown', {key: resolved, bubbles: true, cancelable: true}));
  if (resolved === 'Enter') {
    if (element.form?.requestSubmit) element.form.requestSubmit();
    else if (element.click) element.click();
  } else if (resolved.length === 1 && 'value' in element) {
    setNative(element, 'value', String(element.value || '') + resolved);
    element.dispatchEvent(new InputEvent('input', {bubbles: true, data: resolved}));
  }
  element.dispatchEvent(new KeyboardEvent('keyup', {key: resolved, bubbles: true, cancelable: true}));
  return {ok: true, output: `pressed ${key}`};
})()"#,
        &[("«SETTER»", NATIVE_SETTER_PRELUDE), ("«KEY»", &literal(key))],
    )
}

pub fn get_script(kind: &str, selector: &str, attribute: Option<&str>) -> String {
    let expression = match kind {
        "text" => "element.innerText ?? element.textContent ?? ''".to_string(),
        "html" => "element.outerHTML".to_string(),
        "value" => "element.value ?? ''".to_string(),
        "attr" => format!("element.getAttribute({}) ?? ''", literal(attribute.unwrap_or(""))),
        "count" => {
            return fill(
                r#"(() => {
  const selector = «SELECTOR»;
  if (selector.startsWith('@')) {
    return {ok: true, output: window.__sopranoElementRefs?.[selector.slice(1)] ? '1' : '0'};
  }
  try {
    return {ok: true, output: String(document.querySelectorAll(selector).length)};
  } catch (_) {
    return {ok: false, error: `Invalid selector: ${selector}`};
  }
})()"#,
                &[("«SELECTOR»", &literal(selector))],
            );
        }
        _ => return format!("({{ok: false, error: {}}})", literal(&format!("Unsupported getter: {kind}"))),
    };
    fill(
        r#"(() => {
  «PRELUDE»
  return {ok: true, output: String(«EXPRESSION»)};
})()"#,
        &[("«PRELUDE»", &resolver_prelude(selector)), ("«EXPRESSION»", &expression)],
    )
}

pub fn state_script(kind: &str, selector: &str) -> String {
    let expression = match kind {
        "visible" => {
            r#"(() => {
  const style = getComputedStyle(element);
  const rect = element.getBoundingClientRect();
  return style.visibility !== 'hidden' && style.display !== 'none' &&
    rect.width > 0 && rect.height > 0;
})()"#
        }
        "enabled" => "!element.disabled && element.getAttribute('aria-disabled') !== 'true'",
        "checked" => "Boolean(element.checked || element.getAttribute('aria-checked') === 'true')",
        _ => {
            return format!(
                "({{ok: false, error: {}}})",
                literal(&format!("Unsupported state check: {kind}"))
            );
        }
    };
    fill(
        r#"(() => {
  «PRELUDE»
  return {ok: true, output: String(Boolean(«EXPRESSION»))};
})()"#,
        &[("«PRELUDE»", &resolver_prelude(selector)), ("«EXPRESSION»", expression)],
    )
}

pub fn snapshot_script(interactive_only: bool) -> String {
    fill(
        r#"(() => {
  window.__sopranoElementRefs = {};
  let nextRef = 1;
  const interactiveOnly = «INTERACTIVE»;
  const implicitRoles = {
    A: 'link', BUTTON: 'button', INPUT: 'textbox', SELECT: 'combobox',
    TEXTAREA: 'textbox', IMG: 'img', H1: 'heading', H2: 'heading',
    H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading',
    LI: 'listitem', OPTION: 'option', SUMMARY: 'button'
  };
  const interactiveRoles = new Set([
    'button', 'link', 'textbox', 'searchbox', 'combobox', 'checkbox',
    'radio', 'slider', 'spinbutton', 'switch', 'tab', 'menuitem', 'option'
  ]);
  const visible = (element) => {
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.visibility !== 'hidden' && style.display !== 'none' &&
      rect.width > 0 && rect.height > 0;
  };
  const roleFor = (element) => {
    const explicit = element.getAttribute('role');
    if (explicit) return explicit;
    if (element.tagName === 'INPUT') {
      const type = (element.getAttribute('type') || 'text').toLowerCase();
      if (type === 'checkbox') return 'checkbox';
      if (type === 'radio') return 'radio';
      if (['button', 'submit', 'reset'].includes(type)) return 'button';
      if (type === 'range') return 'slider';
      if (type === 'search') return 'searchbox';
    }
    return implicitRoles[element.tagName] || '';
  };
  const nameFor = (element) => {
    const labelledBy = element.getAttribute('aria-labelledby');
    if (labelledBy) {
      const text = labelledBy.split(/\s+/).map((id) =>
        document.getElementById(id)?.innerText || ''
      ).join(' ').trim();
      if (text) return text;
    }
    const aria = element.getAttribute('aria-label');
    if (aria) return aria.trim();
    if (element.labels?.length) {
      const text = Array.from(element.labels).map((label) => label.innerText).join(' ').trim();
      if (text) return text;
    }
    return (
      element.getAttribute('alt') ||
      element.getAttribute('title') ||
      element.getAttribute('placeholder') ||
      (element.type === 'password' ? '' : element.value) ||
      element.innerText ||
      element.textContent ||
      ''
    ).replace(/\s+/g, ' ').trim().slice(0, 160);
  };
  const lines = [];
  for (const element of document.querySelectorAll('*')) {
    if (!visible(element)) continue;
    const role = roleFor(element);
    if (!role) continue;
    const interactive = interactiveRoles.has(role) ||
      element.matches('a[href],button,input,select,textarea,[tabindex]:not([tabindex="-1"])');
    if (interactiveOnly && !interactive) continue;
    const name = nameFor(element).replaceAll('"', '\\"');
    let suffix = '';
    if (interactive) {
      const ref = `e${nextRef++}`;
      window.__sopranoElementRefs[ref] = element;
      suffix += ` [ref=${ref}]`;
    }
    if (role === 'heading' && /^H[1-6]$/.test(element.tagName)) {
      suffix += ` [level=${element.tagName.slice(1)}]`;
    }
    if (element.disabled || element.getAttribute('aria-disabled') === 'true') {
      suffix += ' [disabled]';
    }
    if (element.checked || element.getAttribute('aria-checked') === 'true') {
      suffix += ' [checked]';
    }
    lines.push(`- ${role}${name ? ` "${name}"` : ''}${suffix}`);
  }
  return lines.length ? lines.join('\n') : '(no accessible elements)';
})()"#,
        &[("«INTERACTIVE»", if interactive_only { "true" } else { "false" })],
    )
}

/// The script `document.title` reads through for the `title` command.
pub const TITLE_SCRIPT: &str = "document.title";

/// Evaluation envelope. WebKit, WebView2 and WebKitGTK disagree on how they report exceptions
/// and non-JSON results (wry drops both), so every script runs inside this wrapper, which
/// always returns a JSON string: `{"exception":true}`, `{"unsupported":true}`,
/// `{"undefined":true}` or `{"value":…}` with booleans, numbers, strings, `null`, arrays and plain
/// objects, the result types WebKit hands back to the Swift app.
///
/// `body` is a JavaScript expression evaluating to the result.
fn envelope(body: &str) -> String {
    fill(
        r#"(() => {
  let value;
  try {
    value = «BODY»;
  } catch (_) {
    return JSON.stringify({exception: true});
  }
  if (value === undefined) return JSON.stringify({undefined: true});
  const unsupported = {};
  const seen = new Set();
  const convert = (item) => {
    if (item === null || item === undefined) return null;
    const type = typeof item;
    if (type === 'string' || type === 'boolean') return item;
    if (type === 'number') return Number.isFinite(item) ? item : null;
    if (type !== 'object') throw unsupported;
    if (item instanceof Date) return item.toISOString();
    if (seen.has(item)) throw unsupported;
    seen.add(item);
    let result;
    if (Array.isArray(item)) {
      result = item.map(convert);
    } else {
      const proto = Object.getPrototypeOf(item);
      if (proto !== Object.prototype && proto !== null) throw unsupported;
      result = {};
      for (const key of Object.keys(item)) result[key] = convert(item[key]);
    }
    seen.delete(item);
    return result;
  };
  try {
    return JSON.stringify({value: convert(value)});
  } catch (_) {
    return JSON.stringify({unsupported: true});
  }
})()"#,
        &[("«BODY»", body)],
    )
}

/// Wraps one of this module's scripts (each a single expression).
pub fn wrap_expression(script: &str) -> String {
    envelope(&format!("(\n{script}\n)"))
}

/// Wraps `soprano browser eval` input: a whole program whose completion value is the result,
/// as `WKWebView.evaluateJavaScript` treats it. It runs through a global (indirect) `eval`.
pub fn wrap_program(program: &str) -> String {
    envelope(&format!("(0, eval)({})", literal(program)))
}

/// Runs at document start in the main frame of every page. It reports same-document
/// navigations (`pushState`, `replaceState`, fragments, back/forward), the history buttons'
/// state, the page taking focus, and the browser shortcuts typed while the page has the
/// keyboard (`⌘L`, `⌘[`, `⌘]`, `⌘R`; Control elsewhere) to the pane through `window.ipc`.
pub fn bridge_script(command_modifier: &str) -> String {
    fill(
        r#"(() => {
  if (window.__sopranoBridge) return;
  window.__sopranoBridge = true;
  const send = (message) => {
    try { window.ipc.postMessage(JSON.stringify(message)); } catch (_) {}
  };
  const location = () => {
    const nav = window.navigation;
    send({
      type: 'location',
      url: window.location.href,
      canGoBack: nav ? Boolean(nav.canGoBack) : history.length > 1,
      canGoForward: nav ? Boolean(nav.canGoForward) : true
    });
  };
  for (const name of ['pushState', 'replaceState']) {
    const original = history[name];
    history[name] = function (...args) {
      const result = original.apply(this, args);
      location();
      return result;
    };
  }
  window.addEventListener('popstate', location);
  window.addEventListener('hashchange', location);
  window.addEventListener('pageshow', location);
  window.addEventListener('DOMContentLoaded', location);
  window.navigation?.addEventListener?.('currententrychange', location);
  window.addEventListener('focus', () => send({type: 'focus'}));
  window.addEventListener('mousedown', () => send({type: 'focus'}), true);
  const shortcuts = {l: 'focus-address', '[': 'back', ']': 'forward', r: 'reload'};
  window.addEventListener('keydown', (event) => {
    if (!event.«MODIFIER» || event.altKey) return;
    const other = '«MODIFIER»' === 'metaKey' ? event.ctrlKey : event.metaKey;
    if (other) return;
    const name = shortcuts[(event.key || '').toLowerCase()];
    if (!name) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    send({type: 'shortcut', name});
  }, true);
})();"#,
        &[("«MODIFIER»", command_modifier)],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literals_escape_like_swift_json_encoder() {
        assert_eq!(literal(r#"a"b\c/d"#), r#""a\"b\\c\/d""#);
        assert_eq!(literal("line\nnext\u{1}"), r#""line\nnext\u0001""#);
    }

    #[test]
    fn substituted_values_are_never_scanned_for_markers() {
        let script = element_action_script("click", "«ACTION»");
        assert!(script.contains(r#"const selector = "«ACTION»";"#));
        assert!(script.contains("  element.click();\n"));
    }

    #[test]
    fn element_actions_resolve_the_selector_scroll_and_report_the_command() {
        let script = element_action_script("click", "#save");
        assert_eq!(
            script,
            r##"(() => {
  const selector = "#save";
const resolve = (value) => {
  if (value.startsWith('@')) {
    return window.__sopranoElementRefs?.[value.slice(1)] || null;
  }
  try { return document.querySelector(value); } catch (_) { return null; }
};
const element = resolve(selector);
if (!element) return {ok: false, error: `Element not found: ${selector}`};
  element.scrollIntoView({block: 'center', inline: 'center'});
  element.click();
  return {ok: true, output: "click #save"};
})()"##
        );
    }

    #[test]
    fn checking_clicks_first_and_falls_back_to_the_native_setter() {
        let script = element_action_script("uncheck", "@e3");
        assert!(script.contains("if (element.checked !== false) element.click();"));
        assert!(script.contains("setNative(element, 'checked', false);"));
        assert!(script.contains("const setNative = (target, property, value) => {"));
        assert!(script.contains(r#"output: "uncheck @e3""#));
    }

    #[test]
    fn unknown_element_commands_only_scroll() {
        let script = element_action_script("wiggle", "a");
        assert!(script.contains("  element.scrollIntoView({block: 'center', inline: 'center'});\n  \n"));
    }

    #[test]
    fn fill_replaces_the_value_and_type_appends_to_it() {
        let fill = text_action_script("fill", "#name", "Ada");
        assert!(fill.contains("    setNative(element, 'value', text);"));
        assert!(fill.contains("    element.textContent = text;"));
        assert!(fill.contains(r#"const text = "Ada";"#));

        let typed = text_action_script("type", "#name", "Ada");
        assert!(typed.contains("setNative(element, 'value', String(element.value || '') + text);"));
        assert!(typed.contains("element.textContent = String(element.textContent || '') + text;"));
        assert!(typed.contains(r#"output: "type #name""#));
    }

    #[test]
    fn key_presses_encode_the_key_literal() {
        let script = key_press_script("Enter");
        assert!(script.contains(r#"const key = "Enter";"#));
        assert!(script.contains("element.form.requestSubmit();"));
    }

    #[test]
    fn getters_cover_text_html_value_attributes_and_counts() {
        assert!(
            get_script("text", "h1", None).contains("String(element.innerText ?? element.textContent ?? '')")
        );
        assert!(get_script("html", "h1", None).contains("String(element.outerHTML)"));
        assert!(get_script("value", "input", None).contains("String(element.value ?? '')"));
        assert!(
            get_script("attr", "a", Some("href")).contains(r#"String(element.getAttribute("href") ?? '')"#)
        );
        let count = get_script("count", "li", None);
        assert!(count.contains("String(document.querySelectorAll(selector).length)"));
        assert!(!count.contains("const resolve"));
        assert_eq!(get_script("size", "li", None), r#"({ok: false, error: "Unsupported getter: size"})"#);
    }

    #[test]
    fn state_checks_cover_visible_enabled_and_checked() {
        assert!(state_script("visible", "#a").contains("return {ok: true, output: String(Boolean((() => {"));
        assert!(state_script("enabled", "#a").contains("!element.disabled"));
        assert!(state_script("checked", "#a").contains("aria-checked"));
        assert_eq!(
            state_script("focused", "#a"),
            r#"({ok: false, error: "Unsupported state check: focused"})"#
        );
    }

    #[test]
    fn snapshots_reset_refs_and_hide_passwords() {
        let script = snapshot_script(true);
        assert!(script.starts_with("(() => {\n  window.__sopranoElementRefs = {};"));
        assert!(script.contains("const interactiveOnly = true;"));
        assert!(script.contains("(element.type === 'password' ? '' : element.value)"));
        assert!(script.contains(r#".replaceAll('"', '\\"')"#));
        assert!(script.contains(r"labelledBy.split(/\s+/)"));
        assert!(script.contains(r"lines.join('\n')"));
        assert!(snapshot_script(false).contains("const interactiveOnly = false;"));
    }

    #[test]
    fn programs_run_through_a_global_eval_inside_the_envelope() {
        let wrapped = wrap_program("1 + 1");
        assert!(wrapped.contains(r#"value = (0, eval)("1 + 1");"#));
        assert!(wrapped.contains("JSON.stringify({exception: true})"));
        assert!(wrap_expression("document.title").contains("value = (\ndocument.title\n);"));
    }

    #[test]
    fn the_bridge_listens_for_the_platform_command_modifier() {
        assert!(bridge_script("metaKey").contains("if (!event.metaKey || event.altKey) return;"));
        assert!(bridge_script("ctrlKey").contains("'ctrlKey' === 'metaKey'"));
    }
}
