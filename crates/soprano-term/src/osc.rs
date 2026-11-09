//! Operating system commands the terminal handles itself: the working directory a shell
//! reports (OSC 7 and friends) and OSC 52 clipboard reads, which wait for the user.

/// The directory a shell reported, as a local path; `None` for another host's directory or
/// an empty report (Ghostty ignores both).
///
/// OSC 7 sends `file://host/path` (percent-encoded), also as `kitty-shell-cwd://`; OSC 9;9
/// and OSC 1337 CurrentDir send a bare path.
pub fn decode_pwd(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let Some(rest) = raw.strip_prefix("file://").or_else(|| raw.strip_prefix("kitty-shell-cwd://")) else {
        return Some(raw.to_owned());
    };
    let slash = rest.find('/')?;
    let (host, path) = (&rest[..slash], &rest[slash..]);
    if !host.is_empty() && !host.eq_ignore_ascii_case("localhost") && !is_local_host(host) {
        return None;
    }
    let path = percent_decode(path)?;
    // `/C:/Users/...` names `C:\Users\...` on Windows.
    if cfg!(windows) && path.as_bytes().get(2) == Some(&b':') && path.as_bytes()[1].is_ascii_alphabetic() {
        return Some(path[1..].replace('/', "\\"));
    }
    Some(path)
}

fn is_local_host(host: &str) -> bool {
    crate::os::hostname().is_some_and(|name| {
        name.eq_ignore_ascii_case(host)
            // `host.local` (mDNS) and the bare name are the same machine.
            || name.split('.').next().is_some_and(|short| short.eq_ignore_ascii_case(host.split('.').next().unwrap_or(host)))
    })
}

fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = s.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// A program asked to read the clipboard (`OSC 52 ; <selection> ; ?`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Osc52Read {
    /// The selection letters the program named (`c` when it named none).
    pub selection: String,
}

impl Osc52Read {
    /// Whether the program asked for the selection clipboard (`p` or `s`) rather than the
    /// standard one.
    pub fn wants_selection_clipboard(&self) -> bool {
        matches!(self.selection.chars().next(), Some('p' | 's'))
    }

    /// The answer the program reads: the text base64-encoded, empty when denied.
    pub fn reply(&self, text: &str) -> Vec<u8> {
        use base64::Engine;
        let kind = self.selection.chars().next().unwrap_or('c');
        let encoded = base64::engine::general_purpose::STANDARD.encode(text);
        format!("\x1b]52;{kind};{encoded}\x1b\\").into_bytes()
    }
}

/// Finds OSC 52 read requests in the program's output, also when one arrives split across
/// reads. libghostty-vt answers reads only from inside its callback, which can't wait for
/// the user, so reads are answered later by writing the reply to the program.
#[derive(Debug, Default)]
pub struct Osc52ReadScanner {
    state: ScanState,
    body: Vec<u8>,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum ScanState {
    #[default]
    Ground,
    Escape,
    Osc,
    OscEscape,
}

/// Longer OSC bodies can't be a read request (`52;` + a few selection letters + `;?`).
const MAX_READ_BODY: usize = 32;

impl Osc52ReadScanner {
    pub fn scan(&mut self, bytes: &[u8]) -> Vec<Osc52Read> {
        let mut found = Vec::new();
        for &b in bytes {
            self.state = match (self.state, b) {
                (ScanState::Ground, 0x1b) => ScanState::Escape,
                (ScanState::Ground, _) => ScanState::Ground,
                (ScanState::Escape, b']') => {
                    self.body.clear();
                    ScanState::Osc
                }
                (ScanState::Escape, 0x1b) => ScanState::Escape,
                (ScanState::Escape, _) => ScanState::Ground,
                (ScanState::Osc, 0x07) => {
                    found.extend(self.finish());
                    ScanState::Ground
                }
                (ScanState::Osc, 0x1b) => ScanState::OscEscape,
                (ScanState::Osc, b) => {
                    if self.body.len() <= MAX_READ_BODY {
                        self.body.push(b);
                    }
                    ScanState::Osc
                }
                (ScanState::OscEscape, b'\\') => {
                    found.extend(self.finish());
                    ScanState::Ground
                }
                // ESC inside an OSC aborts it and starts a new sequence.
                (ScanState::OscEscape, b']') => {
                    self.body.clear();
                    ScanState::Osc
                }
                (ScanState::OscEscape, 0x1b) => ScanState::Escape,
                (ScanState::OscEscape, _) => ScanState::Ground,
            };
        }
        found
    }

    fn finish(&mut self) -> Option<Osc52Read> {
        let body = std::mem::take(&mut self.body);
        if body.len() > MAX_READ_BODY {
            return None;
        }
        let body = std::str::from_utf8(&body).ok()?;
        let rest = body.strip_prefix("52;")?;
        let (selection, data) = rest.split_once(';')?;
        if data != "?" || !selection.chars().all(|c| c.is_ascii_alphanumeric()) {
            return None;
        }
        Some(Osc52Read { selection: if selection.is_empty() { "c".into() } else { selection.into() } })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn osc7_file_urls_decode_to_local_paths() {
        assert_eq!(decode_pwd("file:///Users/me/my%20dir").as_deref(), Some("/Users/me/my dir"));
        assert_eq!(decode_pwd("file://localhost/tmp").as_deref(), Some("/tmp"));
        assert_eq!(decode_pwd("kitty-shell-cwd:///tmp/x").as_deref(), Some("/tmp/x"));
        if let Some(host) = crate::os::hostname() {
            assert_eq!(decode_pwd(&format!("file://{host}/srv")).as_deref(), Some("/srv"));
        }
    }

    #[test]
    fn another_hosts_directory_and_empty_reports_are_ignored() {
        assert_eq!(decode_pwd("file://some-remote-box-that-is-not-here/home/x"), None);
        assert_eq!(decode_pwd(""), None);
        assert_eq!(decode_pwd("file:///bad%zz"), None);
    }

    #[test]
    fn bare_paths_pass_through() {
        assert_eq!(decode_pwd("/home/me").as_deref(), Some("/home/me"));
    }

    #[test]
    fn osc52_reads_are_found_across_reads_and_writes_are_not() {
        let mut scanner = Osc52ReadScanner::default();
        assert!(scanner.scan(b"hello \x1b]52;c;aGk=\x07").is_empty());
        assert!(scanner.scan(b"\x1b]52;c").is_empty());
        assert_eq!(scanner.scan(b";?\x1b\\"), vec![Osc52Read { selection: "c".into() }]);
        assert_eq!(scanner.scan(b"\x1b]52;;?\x07"), vec![Osc52Read { selection: "c".into() }]);
        let read = scanner.scan(b"\x1b]52;p;?\x07").remove(0);
        assert!(read.wants_selection_clipboard());
        assert!(scanner.scan(b"\x1b]0;title ;?\x07").is_empty());
    }

    #[test]
    fn a_read_is_answered_in_base64_with_the_requested_clipboard() {
        let read = Osc52Read { selection: "c".into() };
        assert_eq!(read.reply("hello"), b"\x1b]52;c;aGVsbG8=\x1b\\");
        assert_eq!(read.reply(""), b"\x1b]52;c;\x1b\\");
    }
}
