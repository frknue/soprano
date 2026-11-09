//! `BrowserAddressResolver`: turns what the user typed into the address bar (or passed to
//! `soprano browser open|goto`) into a URL.

/// Schemes that are URLs without `//` (`about:blank`). Anything else written as `name:rest`
/// without `://` is a host and port (`myapp.test:3000`), not a scheme.
const SCHEMES_WITHOUT_SLASHES: [&str; 3] = ["about", "data", "mailto"];

/// Resolves address-bar input: bare local development addresses (`localhost:5173`,
/// `127.0.0.1:3000/app`, `0.0.0.0`, `[::1]`) load over HTTP, explicit URLs load as written,
/// other hostnames (`example.com/docs`, `myapp.test:3000`) load over HTTPS, and everything else
/// is a DuckDuckGo search. Returns `None` for blank or unparseable input.
///
/// The result keeps the text as written (no trailing `/` is added), like Foundation's
/// `URL.absoluteString`.
pub fn resolve(input: &str) -> Option<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }

    let lowercased = trimmed.to_lowercase();
    let is_local = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"]
        .iter()
        .any(|host| lowercased == *host || lowercased.starts_with(&format!("{host}:")));
    if is_local {
        return parsed(format!("http://{trimmed}"));
    }

    // `myapp.test:3000` parses as the scheme `myapp.test`; only an explicit `scheme://` or a
    // known scheme without slashes is one.
    if let Some(scheme) = scheme_of(trimmed)
        && (trimmed.contains("://") || SCHEMES_WITHOUT_SLASHES.contains(&scheme.to_lowercase().as_str()))
        && url::Url::parse(trimmed).is_ok()
    {
        return Some(trimmed.to_string());
    }

    if !trimmed.contains(char::is_whitespace) && (trimmed.contains('.') || trimmed.contains(':')) {
        return parsed(format!("https://{trimmed}"));
    }

    Some(format!("https://duckduckgo.com/?q={}", encode_query_value(trimmed)))
}

fn parsed(candidate: String) -> Option<String> {
    if candidate.contains(char::is_whitespace) || url::Url::parse(&candidate).is_err() {
        return None;
    }
    Some(candidate)
}

/// The RFC 3986 scheme before the first `:`, if the text starts with one.
fn scheme_of(text: &str) -> Option<&str> {
    let (scheme, _) = text.split_once(':')?;
    let mut chars = scheme.chars();
    let first = chars.next()?;
    (first.is_ascii_alphabetic() && chars.all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c)))
        .then_some(scheme)
}

/// Percent-encodes a query item value the way `URLComponents.queryItems` does: everything outside
/// the URL query character set, plus the `&` and `=` that would split the item. `+` stays as is.
fn encode_query_value(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        let keep = byte.is_ascii_alphanumeric() || b"-._~!$'()*+,;:@/?".contains(&byte);
        if keep {
            encoded.push(char::from(byte));
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::resolve;

    #[test]
    fn browser_addresses_prefer_http_for_local_development() {
        assert_eq!(resolve("localhost:5173").as_deref(), Some("http://localhost:5173"));
        assert_eq!(resolve("127.0.0.1:3000/app").as_deref(), Some("http://127.0.0.1:3000/app"));
        assert_eq!(resolve("example.com/docs").as_deref(), Some("https://example.com/docs"));
        assert!(
            resolve("swift appkit browser")
                .expect("a search URL")
                .contains("duckduckgo.com/?q=swift%20appkit%20browser")
        );
    }

    #[test]
    fn browser_addresses_with_a_port_but_no_scheme_load_over_https() {
        assert_eq!(resolve("myapp.test:3000").as_deref(), Some("https://myapp.test:3000"));
        assert_eq!(resolve("example.com:8443/docs").as_deref(), Some("https://example.com:8443/docs"));
        assert_eq!(resolve("file:///tmp/index.html").as_deref(), Some("file:///tmp/index.html"));
        assert_eq!(resolve("about:blank").as_deref(), Some("about:blank"));
        assert_eq!(resolve("http://example.com").as_deref(), Some("http://example.com"));
    }

    #[test]
    fn blank_input_resolves_to_nothing() {
        assert_eq!(resolve("   \n"), None);
    }

    #[test]
    fn local_addresses_are_matched_case_insensitively_and_trimmed() {
        assert_eq!(resolve("  LOCALHOST:8080 ").as_deref(), Some("http://LOCALHOST:8080"));
        assert_eq!(resolve("[::1]:4000").as_deref(), Some("http://[::1]:4000"));
        assert_eq!(resolve("0.0.0.0").as_deref(), Some("http://0.0.0.0"));
    }

    #[test]
    fn search_queries_encode_ampersands_but_keep_plus_signs() {
        assert_eq!(resolve("c++ & rust").as_deref(), Some("https://duckduckgo.com/?q=c++%20%26%20rust"));
    }
}
