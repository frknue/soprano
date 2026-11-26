//! Embedded static assets for Soprano's mobile PWA.

pub const INDEX_HTML: &str = include_str!("../pwa/index.html");
pub const STYLES_CSS: &str = include_str!("../pwa/styles.css");
pub const APP_JS: &str = include_str!("../pwa/app.js");
pub const MANIFEST_JSON: &str = include_str!("../pwa/manifest.webmanifest");
pub const SERVICE_WORKER_JS: &str = include_str!("../pwa/sw.js");
pub const ICON_SVG: &str = include_str!("../pwa/icon.svg");
