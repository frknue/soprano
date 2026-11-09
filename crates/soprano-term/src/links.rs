// Adapted from herdr-app (Apache-2.0)
//! Links in terminal text: Ghostty's URL and file path pattern, what a match
//! points to, and handing it to the system to open.

use fancy_regex::Regex;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

/// Ghostty's default link pattern (`src/config/url.zig`), unchanged.
static PATTERN: LazyLock<Regex> = LazyLock::new(|| {
    let schemes = r"https?://|mailto:|ftp://|file:|ssh:|git://|ssh://|tel:|magnet:|ipfs://|ipns://|gemini://|gopher://|news:";
    let ipv6 = r"(?:\[[:0-9a-fA-F]+(?:[:0-9a-fA-F]*)+\](?::[0-9]+)?)";
    let scheme_chars = r"[\w\-.~:/?#@!$&*+,;=%]";
    let path_chars = r"[\w\-.~:\/?#@!$&*+;=%]";
    let bracketed = r"(?:[\(\[]\w*[\)\]])?";
    let no_trailing_punctuation = r"(?<![,.])";
    let no_trailing_colon = r"(?<!:)";
    let dotted = r"(?=[\w\-.~:\/?#@!$&*+;=%]*\.)";
    let undotted = r"(?![\w\-.~:\/?#@!$&*+;=%]*\.)";
    let dotted_spaces = r"(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]*[\/.])*";
    let any_spaces = r"(?:(?<!:) (?!\w+:\/\/)(?!\.{0,2}\/)(?!~\/)[\w\-.~:\/?#@!$&*+;=%]+)*";
    let rooted = r"(?:\.\.\/|\.\/|(?<!\w)~\/|(?:[\w][\w\-.]*\/)*(?<!\w)\$[A-Za-z_]\w*\/|\.[\w][\w\-.]*\/|(?<![\w~\/])\/(?!\/))";
    let scheme_url = format!("(?:{schemes})(?:{ipv6}|{scheme_chars}+{bracketed})+{no_trailing_punctuation}");
    let rooted_path = format!(
        "{rooted}(?:{dotted}{path_chars}+{dotted_spaces}{no_trailing_colon}|{undotted}{path_chars}+{any_spaces}{no_trailing_colon})"
    );
    let bare_path = format!(r"{dotted}(?<!\$\d*)(?<!\w)[\w][\w\-.]*\/{path_chars}+{no_trailing_colon}");
    Regex::new(&format!("{scheme_url}|{rooted_path}|{bare_path}")).expect("link pattern")
});

/// The link in `text` that covers byte `at`.
pub fn find(text: &str, at: usize) -> Option<Range<usize>> {
    for m in PATTERN.find_iter(text) {
        let m = m.ok()?;
        if m.start() > at {
            return None;
        }
        if at < m.end() {
            return Some(m.range());
        }
    }
    None
}

#[derive(Clone, Debug, PartialEq)]
pub enum Target {
    Url(String),
    File(PathBuf),
}

/// What a link opens. File paths count only when they exist here; relative
/// ones need the terminal's folder.
pub fn resolve(link: &str, cwd: Option<&Path>) -> Option<Target> {
    let scheme = link.split_once(':').is_some_and(|(s, _)| {
        s.len() > 1
            && s.starts_with(|c: char| c.is_ascii_alphabetic())
            && s.chars().all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c))
    });
    if scheme {
        // Windows can't open a file URL whose path is percent-encoded, the way programs write them.
        if let Some(path) = file_url_path(link).filter(|p| p.exists()) {
            return Some(Target::File(path));
        }
        return Some(Target::Url(link.to_owned()));
    }
    let home = std::env::home_dir();
    let expanded = if let Some(rest) = link.strip_prefix("~/") {
        home?.join(rest)
    } else if let Some(var) = link.strip_prefix('$') {
        let (name, rest) = var.split_once('/').unwrap_or((var, ""));
        let base = match name {
            "PWD" => cwd?.to_path_buf(),
            "HOME" => home?,
            _ => PathBuf::from(std::env::var_os(name)?),
        };
        base.join(rest)
    } else {
        PathBuf::from(link)
    };
    let full = if expanded.is_absolute() { expanded } else { cwd?.join(expanded) };
    // Windows ignores a trailing period when checking whether a path exists.
    if !(cfg!(windows) && full.extension().is_some_and(|ext| ext.is_empty())) && full.exists() {
        return Some(Target::File(full));
    }
    // The period ending a sentence, or `:42` / `:42:7` naming a place in the file.
    let mut bare = full.to_str()?.strip_suffix('.').unwrap_or(full.to_str()?);
    for _ in 0..2 {
        match bare.rsplit_once(':') {
            Some((head, n)) if !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) => bare = head,
            _ => break,
        }
    }
    Path::new(bare).exists().then(|| Target::File(PathBuf::from(bare)))
}

/// The path a `file:` URL names on this computer, percent-decoded.
fn file_url_path(link: &str) -> Option<PathBuf> {
    let rest = link.strip_prefix("file://")?;
    let rest = rest.strip_prefix("localhost").unwrap_or(rest);
    // Another host's file, or no path.
    if !rest.starts_with('/') {
        return None;
    }
    let rest = rest.split(['?', '#']).next()?;
    let mut bytes = Vec::with_capacity(rest.len());
    let mut i = 0;
    while i < rest.len() {
        if rest.as_bytes()[i] == b'%' {
            bytes.push(u8::from_str_radix(rest.get(i + 1..i + 3)?, 16).ok()?);
            i += 3;
        } else {
            bytes.push(rest.as_bytes()[i]);
            i += 1;
        }
    }
    let path = String::from_utf8(bytes).ok()?;
    // `/C:/Users/...` names `C:\Users\...`.
    if cfg!(windows) && path.as_bytes().get(2) == Some(&b':') && path.as_bytes()[1].is_ascii_alphabetic() {
        return Some(PathBuf::from(path[1..].replace('/', "\\")));
    }
    Some(PathBuf::from(path))
}

/// Hands the target to the system's default handler (Ghostty opens a clicked link the same
/// way when the app doesn't).
pub fn open(target: &Target) {
    let arg = match target {
        Target::Url(u) => u.clone(),
        Target::File(p) => p.to_string_lossy().into_owned(),
    };
    if let Err(e) = soprano_platform::system::open_default(&arg) {
        tracing::warn!("cannot open link: {e:#}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn first(text: &str) -> Option<&str> {
        PATTERN.find(text).unwrap().map(|m| m.as_str())
    }

    /// Ghostty's own cases (`src/config/url.zig`).
    #[test]
    fn matches_like_ghostty() {
        let cases = [
            ("hello https://example.com world", "https://example.com"),
            ("https://example.com/foo(bar) more", "https://example.com/foo(bar)"),
            ("https://example.com/foo(bar)baz more", "https://example.com/foo(bar)baz"),
            ("Link inside (https://example.com) parens", "https://example.com"),
            ("Link period https://example.com. More text.", "https://example.com"),
            ("Link trailing comma https://example.com, more text.", "https://example.com"),
            ("Link in double quotes \"https://example.com\" and more", "https://example.com"),
            ("Link in single quotes 'https://example.com' and more", "https://example.com"),
            ("some file with https://google.com https://duckduckgo.com links.", "https://google.com"),
            (
                "and links in it. links https://yahoo.com mailto:test@example.com ssh://1.2.3.4",
                "https://yahoo.com",
            ),
            ("also match http://example.com non-secure links", "http://example.com"),
            ("match tel://+12123456789 phone numbers", "tel://+12123456789"),
            (
                "match with query url https://example.com?query=1&other=2 and more text.",
                "https://example.com?query=1&other=2",
            ),
            (
                "url with dashes [mode 2027](https://github.com/contour-terminal/terminal-unicode-core) for better unicode support",
                "https://github.com/contour-terminal/terminal-unicode-core",
            ),
            ("dot.http://example.com", "http://example.com"),
            (
                "weird characters https://example.com/~user/?query=1&other=2#hash and more",
                "https://example.com/~user/?query=1&other=2#hash",
            ),
            ("square brackets https://example.com/[foo] and more", "https://example.com/[foo]"),
            (
                "[13]:TooManyStatements: TempFile#assign_temp_file_to_entity has approx 7 statements [https://example.com/docs/Too-Many-Statements.md]",
                "https://example.com/docs/Too-Many-Statements.md",
            ),
            ("match ftp://example.com ftp links", "ftp://example.com"),
            ("match file://example.com file links", "file://example.com"),
            ("match ssh://example.com ssh links", "ssh://example.com"),
            ("match git://example.com git links", "git://example.com"),
            ("/tmp/test.txt http://www.google.com", "/tmp/test.txt"),
            ("match tel:+18005551234 tel links", "tel:+18005551234"),
            ("match magnet:?xt=urn:btih:1234567890 magnet links", "magnet:?xt=urn:btih:1234567890"),
            ("match ipfs://QmSomeHashValue ipfs links", "ipfs://QmSomeHashValue"),
            ("match ipns://QmSomeHashValue ipns links", "ipns://QmSomeHashValue"),
            ("match gemini://example.com gemini links", "gemini://example.com"),
            ("match gopher://example.com gopher links", "gopher://example.com"),
            (
                "match news:comp.infosystems.www.servers.unix news links",
                "news:comp.infosystems.www.servers.unix",
            ),
            ("/Users/ghostty.user/code/example.py", "/Users/ghostty.user/code/example.py"),
            ("/Users/ghostty.user/code/../example.py", "/Users/ghostty.user/code/../example.py"),
            ("/Users/ghostty.user/code/../example.py hello world", "/Users/ghostty.user/code/../example.py"),
            ("../example.py", "../example.py"),
            ("../example.py ", "../example.py"),
            ("first time ../example.py contributor ", "../example.py"),
            ("[link](/home/user/ghostty.user/example)", "/home/user/ghostty.user/example"),
            ("Serving HTTP on :: port 8000 (http://[::]:8000/)", "http://[::]:8000/"),
            ("IPv6 address https://[2001:db8::1]:8080/path", "https://[2001:db8::1]:8080/path"),
            ("IPv6 localhost http://[::1]:3000", "http://[::1]:3000"),
            (
                "Complex IPv6 https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
                "https://[2001:db8:85a3:8d3:1319:8a2e:370:7348]:443/",
            ),
            (
                "IPv6 with path https://[2001:db8::1]/path/to/resource",
                "https://[2001:db8::1]/path/to/resource",
            ),
            (
                "IPv6 with query https://[2001:db8::1]:8080/api?param=value&other=123",
                "https://[2001:db8::1]:8080/api?param=value&other=123",
            ),
            ("IPv6 compressed http://[2001:db8::]:80/", "http://[2001:db8::]:80/"),
            ("IPv6 multiple zeros http://[2001:0:0:0:0:0:0:1]", "http://[2001:0:0:0:0:0:0:1]"),
            ("IPv6 link-local https://[fe80::1234:5678:9abc]", "https://[fe80::1234:5678:9abc]"),
            ("IPv6 multicast http://[ff02::1]/stream", "http://[ff02::1]/stream"),
            ("IPv6 in markdown [link](http://[2001:db8::1]/docs)", "http://[2001:db8::1]/docs"),
            ("./spaces-end.   ", "./spaces-end."),
            ("./space middle", "./space middle"),
            ("../test folder/file.txt", "../test folder/file.txt"),
            ("/tmp/test folder/file.txt", "/tmp/test folder/file.txt"),
            ("/tmp/test  folder/file.txt", "/tmp/test"),
            (
                "diff --git a/src/font/shaper/harfbuzz.zig b/src/font/shaper/harfbuzz.zig",
                "a/src/font/shaper/harfbuzz.zig",
            ),
            ("/tmp/foo /tmp/bar", "/tmp/foo"),
            ("/tmp/foo.txt /tmp/bar.txt", "/tmp/foo.txt"),
            ("src/config/url.zig", "src/config/url.zig"),
            ("app/folder/file.rb:1", "app/folder/file.rb:1"),
            ("modified:   src/config/url.zig", "src/config/url.zig"),
            ("lib/ghostty/terminal.zig:42:10", "lib/ghostty/terminal.zig:42:10"),
            ("some-pkg/src/file.txt more text", "some-pkg/src/file.txt"),
            ("src/foo.c,baz.txt", "src/foo.c"),
            ("~/foo/bar.txt", "~/foo/bar.txt"),
            ("open ~/Documents/notes.md please", "~/Documents/notes.md"),
            ("~/.config/ghostty/config", "~/.config/ghostty/config"),
            ("directory: ~/src/ghostty-org/ghostty", "~/src/ghostty-org/ghostty"),
            ("$HOME/src/config/url.zig", "$HOME/src/config/url.zig"),
            ("space dir: $PWD/src/ghostty/main.zig", "$PWD/src/ghostty/main.zig"),
            ("foo/$BAR/baz", "foo/$BAR/baz"),
            (".foo/bar/$VAR", ".foo/bar/$VAR"),
            (".config/ghostty/config", ".config/ghostty/config"),
            ("loaded from .local/share/ghostty/state.db now", ".local/share/ghostty/state.db"),
            ("../some/where", "../some/where"),
            ("  - shared/src/foo/SomeItem.m:12, shared/src/", "shared/src/foo/SomeItem.m:12"),
            ("foo.local/share", "foo.local/share"),
            ("2024/report.txt", "2024/report.txt"),
            ("./foo bar,baz", "./foo bar"),
            ("/tmp/foo bar,baz", "/tmp/foo bar"),
            ("./.config/ghostty: Needs upstream (main)", "./.config/ghostty"),
            ("./Downloads: Operation not permitted", "./Downloads"),
        ];
        for (input, expect) in cases {
            assert_eq!(first(input), Some(expect), "{input:?}");
        }
        for input in [
            "input/output",
            "foo/bar",
            "$10/bar",
            "$10/$20",
            "$10/bar.txt",
            "foo/bar,baz.txt",
            "foo$BAR/baz.txt",
            "foo~/bar.txt",
            "// foo bar",
            "//foo",
        ] {
            assert_eq!(first(input), None, "{input:?}");
        }
    }

    #[test]
    fn query_links_keep_their_full_target() {
        for url in [
            "https://example.com/?a=1&b=2",
            "https://localhost:17480/login?t=abc%3D%3D",
            "file:///C:/Windows/System32/winver.exe",
        ] {
            let text = format!("Dashboard: {url}");
            let range = find(&text, text.find(url).unwrap()).unwrap();
            assert_eq!(&text[range.clone()], url);
            // winver.exe exists on Windows, where it opens as the file.
            let expected = match url.strip_prefix("file:///") {
                Some(path) if cfg!(windows) => Target::File(path.replace('/', "\\").into()),
                _ => Target::Url(url.into()),
            };
            assert_eq!(resolve(&text[range], None), Some(expected));
        }
    }

    #[test]
    fn finds_the_link_under_the_pointer() {
        let text = "see https://a.com and /tmp/x.txt.";
        assert_eq!(find(text, 0), None);
        assert_eq!(find(text, 4).map(|r| &text[r]), Some("https://a.com"));
        assert_eq!(find(text, 16).map(|r| &text[r]), Some("https://a.com"));
        assert_eq!(find(text, 17), None);
        assert_eq!(find(text, 25).map(|r| &text[r]), Some("/tmp/x.txt."));
    }

    #[test]
    fn files_resolve_only_when_they_exist() {
        let dir = std::env::temp_dir().join(format!("soprano-term-links-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("src/main.rs"), "").unwrap();
        let file = Target::File(dir.join("src/main.rs"));
        assert_eq!(resolve("src/main.rs", Some(&dir)), Some(file.clone()));
        assert_eq!(resolve("src/main.rs:42:7", Some(&dir)), Some(file.clone()));
        assert_eq!(resolve("src/main.rs.", Some(&dir)), Some(file.clone()));
        assert_eq!(resolve("src/.", Some(&dir)), Some(Target::File(dir.join("src/."))));
        assert_eq!(resolve("src/..", Some(&dir)), Some(Target::File(dir.join("src/.."))));
        assert_eq!(resolve("$PWD/src/main.rs", Some(&dir)), Some(file.clone()));
        assert_eq!(resolve(dir.join("src/main.rs").to_str().unwrap(), None), Some(file));
        assert_eq!(resolve("src/gone.rs", Some(&dir)), None);
        assert_eq!(resolve("src/main.rs", None), None);
        assert_eq!(resolve("https://a.com/x", None), Some(Target::Url("https://a.com/x".into())));
        #[cfg(unix)]
        {
            let dotted = dir.join("src/main.rs.");
            std::fs::write(&dotted, "").unwrap();
            assert_eq!(resolve("src/main.rs.", Some(&dir)), Some(Target::File(dotted)));
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn file_urls_open_as_the_file_they_name() {
        let dir = std::env::temp_dir().join(format!("soprano-term-file-urls-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("测试 #1.txt");
        std::fs::write(&path, "").unwrap();
        // As programs write them: every byte outside the unreserved set encoded.
        let slashed = path.to_str().unwrap().replace('\\', "/");
        let encoded: String = slashed
            .bytes()
            .map(|b| {
                if b.is_ascii_alphanumeric() || b"/-._~:".contains(&b) {
                    (b as char).to_string()
                } else {
                    format!("%{b:02X}")
                }
            })
            .collect();
        let root = if cfg!(windows) { "/" } else { "" };
        let file = Some(Target::File(path.clone()));
        assert_eq!(resolve(&format!("file://{root}{encoded}"), None), file);
        assert_eq!(resolve(&format!("file://localhost{root}{encoded}"), None), file);
        assert_eq!(resolve(&format!("file://{root}{}", slashed.replace('#', "%23")), None), file);
        for url in [
            format!("file://{root}{encoded}.gone"),
            format!("file://{root}{encoded}%ZZ"),
            format!("file://box{root}{encoded}"),
        ] {
            assert_eq!(resolve(&url, None), Some(Target::Url(url.clone())), "{url}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
}
