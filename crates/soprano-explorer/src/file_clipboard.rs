//! ⌘C in the explorer puts the selected files themselves on the clipboard, so Finder,
//! Explorer or a file manager can paste them. GPUI's clipboard carries text only, so each
//! OS gets its native file clipboard here.

use std::path::PathBuf;

/// Puts `paths` on the clipboard as files. Returns false when this system has no file
/// clipboard the app can reach; the caller then copies the paths as text.
pub fn copy_files(paths: &[PathBuf]) -> bool {
    !paths.is_empty() && platform::copy_files(paths)
}

#[cfg(target_os = "macos")]
mod platform {
    use std::path::PathBuf;

    use objc2::rc::Retained;
    use objc2::runtime::ProtocolObject;
    use objc2_app_kit::{NSPasteboard, NSPasteboardWriting};
    use objc2_foundation::{NSArray, NSString, NSURL};

    pub(super) fn copy_files(paths: &[PathBuf]) -> bool {
        let urls: Vec<Retained<ProtocolObject<dyn NSPasteboardWriting>>> = paths
            .iter()
            .map(|path| {
                let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
                ProtocolObject::from_retained(url)
            })
            .collect();
        let array = NSArray::from_retained_slice(&urls);
        let pasteboard = NSPasteboard::generalPasteboard();
        pasteboard.clearContents();
        pasteboard.writeObjects(&array)
    }
}

#[cfg(windows)]
mod platform {
    use std::path::PathBuf;

    pub(super) fn copy_files(paths: &[PathBuf]) -> bool {
        let paths: Vec<String> = paths.iter().map(|path| path.to_string_lossy().into_owned()).collect();
        clipboard_win::set_clipboard(clipboard_win::formats::FileList, paths.as_slice()).is_ok()
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
mod platform {
    use std::io::Write;
    use std::path::PathBuf;
    use std::process::{Command, Stdio};

    /// `text/uri-list` through `wl-copy` on Wayland or `xclip` on X11, which own the
    /// selection after the app hands it over.
    pub(super) fn copy_files(paths: &[PathBuf]) -> bool {
        let list: String = paths.iter().map(|path| format!("{}\r\n", file_uri(path))).collect();
        let commands: [(&str, &[&str]); 2] = if std::env::var_os("WAYLAND_DISPLAY").is_some() {
            [
                ("wl-copy", &["--type", "text/uri-list"]),
                ("xclip", &["-selection", "clipboard", "-t", "text/uri-list"]),
            ]
        } else {
            [
                ("xclip", &["-selection", "clipboard", "-t", "text/uri-list"]),
                ("wl-copy", &["--type", "text/uri-list"]),
            ]
        };
        commands.iter().any(|(program, arguments)| {
            let Ok(mut child) = Command::new(program)
                .args(*arguments)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
            else {
                return false;
            };
            let written =
                child.stdin.take().is_some_and(|mut stdin| stdin.write_all(list.as_bytes()).is_ok());
            written && child.wait().is_ok_and(|status| status.success())
        })
    }

    fn file_uri(path: &std::path::Path) -> String {
        let mut uri = String::from("file://");
        for byte in path.to_string_lossy().bytes() {
            match byte {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => {
                    uri.push(byte as char)
                }
                _ => uri.push_str(&format!("%{byte:02X}")),
            }
        }
        uri
    }

    #[cfg(test)]
    mod tests {
        #[test]
        fn file_uris_escape_spaces_and_other_reserved_bytes() {
            assert_eq!(super::file_uri(std::path::Path::new("/tmp/a b#c")), "file:///tmp/a%20b%23c");
        }
    }
}
