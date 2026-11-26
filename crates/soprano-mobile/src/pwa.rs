//! Embedded static assets for Soprano's mobile PWA.

const HTML: &str = "text/html; charset=utf-8";
const CSS: &str = "text/css; charset=utf-8";
const JS: &str = "application/javascript; charset=utf-8";
const MANIFEST: &str = "application/manifest+json; charset=utf-8";
const PNG: &str = "image/png";

macro_rules! asset {
    ($path:literal, $content_type:expr, $file:literal) => {
        ($path, $content_type, include_bytes!(concat!("../pwa/", $file)).as_slice())
    };
}

/// Every file the PWA is made of: URL path, content type, body. `/` is the app shell;
/// `sw.js` lists the same paths to keep them for offline starts.
pub const ASSETS: &[(&str, &str, &[u8])] = &[
    asset!("/", HTML, "index.html"),
    asset!("/app.css", CSS, "app.css"),
    asset!("/manifest.webmanifest", MANIFEST, "manifest.webmanifest"),
    asset!("/sw.js", JS, "sw.js"),
    asset!("/apple-touch-icon.png", PNG, "apple-touch-icon.png"),
    asset!("/icon-192.png", PNG, "icon-192.png"),
    asset!("/icon-512.png", PNG, "icon-512.png"),
    asset!("/js/main.js", JS, "js/main.js"),
    asset!("/js/api.js", JS, "js/api.js"),
    asset!("/js/cards.js", JS, "js/cards.js"),
    asset!("/js/diff.js", JS, "js/diff.js"),
    asset!("/js/dom.js", JS, "js/dom.js"),
    asset!("/js/markdown.js", JS, "js/markdown.js"),
    asset!("/js/model.js", JS, "js/model.js"),
    asset!("/js/nav.js", JS, "js/nav.js"),
    asset!("/js/socket.js", JS, "js/socket.js"),
    asset!("/js/store.js", JS, "js/store.js"),
    asset!("/js/timeline.js", JS, "js/timeline.js"),
    asset!("/js/screens/common.js", JS, "js/screens/common.js"),
    asset!("/js/screens/inbox.js", JS, "js/screens/inbox.js"),
    asset!("/js/screens/new-thread.js", JS, "js/screens/new-thread.js"),
    asset!("/js/screens/pair.js", JS, "js/screens/pair.js"),
    asset!("/js/screens/thread.js", JS, "js/screens/thread.js"),
];

/// The asset served at `path`: its content type and body. The pairing link's `/pair` is the
/// app shell too.
pub fn asset(path: &str) -> Option<(&'static str, &'static [u8])> {
    let path = if path == "/pair" { "/" } else { path };
    ASSETS.iter().find(|(served, _, _)| *served == path).map(|(_, content_type, body)| (*content_type, *body))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(path: &str) -> &'static str {
        std::str::from_utf8(asset(path).unwrap_or_else(|| panic!("{path} is served")).1).expect("utf-8")
    }

    /// The quoted strings in `source` that follow `marker`.
    fn quoted_after<'a>(source: &'a str, marker: &str) -> Vec<&'a str> {
        source
            .match_indices(marker)
            .filter_map(|(at, _)| {
                let rest = source[at + marker.len()..].trim_start();
                let quote = rest.chars().next().filter(|c| matches!(c, '\'' | '"'))?;
                rest[1..].split(quote).next()
            })
            .collect()
    }

    fn resolve(from: &str, import: &str) -> String {
        let mut parts: Vec<&str> = from.split('/').collect();
        parts.pop();
        for part in import.split('/') {
            match part {
                "." => {}
                ".." => {
                    parts.pop();
                }
                part => parts.push(part),
            }
        }
        parts.join("/")
    }

    #[test]
    fn every_module_a_script_imports_is_served() {
        for (path, _, _) in ASSETS.iter().filter(|(_, content_type, _)| *content_type == JS) {
            // `import … from './x.js';`, also when its names span lines (`} from './x.js';`).
            let imports = text(path)
                .lines()
                .filter(|line| line.starts_with("import ") || line.starts_with("} from "))
                .filter_map(|line| line.split(['\'', '"']).nth(1));
            for import in imports {
                let target = resolve(path, import);
                assert!(asset(&target).is_some(), "{path} imports {import}, but {target} is not served");
            }
        }
    }

    #[test]
    fn the_page_and_the_service_worker_only_name_served_files() {
        let index = text("/");
        for marker in ["href=", "src="] {
            for target in quoted_after(index, marker) {
                // `/theme.css` is rendered from the app's theme by the server.
                if target != "/theme.css" {
                    assert!(asset(target).is_some(), "index.html names {target}, which is not served");
                }
            }
        }
        let worker = text("/sw.js");
        let shell = &worker[worker.find("const SHELL = [").expect("shell list")..];
        let shell = &shell[..shell.find("];").expect("end of shell list")];
        let cached: Vec<&str> = shell.split('\'').skip(1).step_by(2).collect();
        for (path, _, _) in ASSETS.iter().filter(|(path, _, _)| *path != "/sw.js") {
            assert!(cached.contains(path), "sw.js does not keep {path} for offline starts");
        }
        for path in cached {
            assert!(asset(path).is_some(), "sw.js keeps {path}, which is not served");
        }
    }
}
