//! What a composer's message brings along, without GPUI: files and pasted images. Every
//! agent takes them the same way, as paths at the end of the message, which works for a
//! prompt on a command line, text typed into a terminal and a chat session alike. A pasted
//! image has no file yet, so the composer writes one.

use std::borrow::Cow;
use std::fs::OpenOptions;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use soprano_platform::shell::path_word;

/// The image files the composer shows as a thumbnail.
const THUMBNAIL_EXTENSIONS: [&str; 8] = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff"];
/// The pasted formats no agent's model reads: kept as PNG instead.
const CONVERTED_EXTENSIONS: [&str; 3] = ["tiff", "tif", "bmp"];

/// A file a message brings along.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attachment {
    pub path: PathBuf,
    /// The composer wrote this file for a pasted image; taken out of the message unsent, the
    /// file goes again.
    pub pasted: bool,
}

impl Attachment {
    /// A file that exists already (a drop, copied files).
    pub fn file(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into(), pasted: false }
    }

    /// The file's name, as its chip and tooltip show it.
    pub fn name(&self) -> String {
        self.path.file_name().map_or_else(
            || self.path.to_string_lossy().into_owned(),
            |name| name.to_string_lossy().into_owned(),
        )
    }

    /// Whether the composer shows the file itself rather than its name.
    pub fn is_image(&self) -> bool {
        self.path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| THUMBNAIL_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str()))
    }

    /// Forgets an attachment that was not sent: the file of a pasted image is removed.
    pub fn discard(self) {
        if self.pasted {
            // Nothing refers to it; a file that cannot be removed only takes room.
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

/// Writes a pasted image (`bytes` in the format `extension` names) into `folder` and returns
/// it as an attachment. TIFF and BMP, which macOS apps copy but models do not read, become
/// PNG.
pub fn store_pasted_image(
    folder: &Path,
    extension: &str,
    bytes: &[u8],
    now: SystemTime,
) -> io::Result<Attachment> {
    let (extension, bytes) = if CONVERTED_EXTENSIONS.contains(&extension) {
        ("png", Cow::Owned(as_png(bytes)?))
    } else {
        (extension, Cow::Borrowed(bytes))
    };
    std::fs::create_dir_all(folder)?;
    let stamp = now.duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs());
    // Two images pasted within a second: the second takes the next free name.
    for copy in 1u32.. {
        let name = match copy {
            1 => format!("pasted-{stamp}.{extension}"),
            _ => format!("pasted-{stamp}-{copy}.{extension}"),
        };
        let path = folder.join(name);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(mut file) => {
                file.write_all(&bytes)?;
                return Ok(Attachment { path, pasted: true });
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }
    Err(io::Error::other("no free file name"))
}

fn as_png(bytes: &[u8]) -> io::Result<Vec<u8>> {
    let image = image::load_from_memory(bytes).map_err(io::Error::other)?;
    let mut png = io::Cursor::new(Vec::new());
    image.write_to(&mut png, image::ImageFormat::Png).map_err(io::Error::other)?;
    Ok(png.into_inner())
}

/// The message as the agent reads it: the trimmed text, then the attached files' paths on a
/// line of their own, each one word. `None` when there is neither.
pub fn message_text(draft: &str, attachments: &[Attachment]) -> Option<String> {
    let text = draft.trim();
    let paths =
        attachments.iter().map(|attachment| path_word(&attachment.path)).collect::<Vec<_>>().join(" ");
    match (text.is_empty(), paths.is_empty()) {
        (true, true) => None,
        (false, true) => Some(text.to_owned()),
        (true, false) => Some(paths),
        (false, false) => Some(format!("{text}\n{paths}")),
    }
}

/// Splits trailing attachment path line(s) (as produced by [`message_text`] or dropped files)
/// back out of a user message so the timeline can show image thumbnails and file chips instead
/// of raw paths. Returns `(body, attachments)`.
pub fn split_message_attachments(text: &str) -> (String, Vec<Attachment>) {
    let lines: Vec<&str> = text.lines().collect();
    let mut end = lines.len();
    while end > 0 && lines[end - 1].trim().is_empty() {
        end -= 1;
    }

    let mut groups: Vec<Vec<Attachment>> = Vec::new();
    let mut split_at = end;
    while split_at > 0 {
        let idx = split_at - 1;
        let line = lines[idx];
        if line.trim().is_empty() {
            // Stop at a blank separator unless another path line sits immediately above it.
            break;
        }
        if inside_code_fence(&lines[..idx]) {
            break;
        }
        let Some(paths) = parse_attachment_line(line) else {
            break;
        };
        groups.push(paths.into_iter().map(Attachment::file).collect());
        split_at = idx;
    }

    if groups.is_empty() {
        return (text.to_owned(), Vec::new());
    }

    groups.reverse();
    let attachments: Vec<Attachment> = groups.into_iter().flatten().collect();
    let body = lines[..split_at].join("\n").trim_end().to_owned();
    (body, attachments)
}

fn inside_code_fence(lines_above: &[&str]) -> bool {
    let fences = lines_above
        .iter()
        .filter(|line| {
            let trimmed = line.trim_start();
            trimmed.starts_with("```") || trimmed.starts_with("~~~")
        })
        .count();
    fences % 2 == 1
}

/// Parses a line containing one or more shell-word file paths (matching [`path_word`] on Unix
/// and Windows, plus single/double-quoted paths). Returns `None` if any word on the line is
/// not an attachment file path.
fn parse_attachment_line(line: &str) -> Option<Vec<PathBuf>> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut paths = Vec::new();
    let mut chars = trimmed.chars().peekable();
    while let Some(&ch) = chars.peek() {
        if ch == ' ' || ch == '\t' {
            chars.next();
            continue;
        }
        let token = if ch == '"' || ch == '\'' {
            let quote = ch;
            chars.next();
            let mut word = String::new();
            let mut closed = false;
            for c in chars.by_ref() {
                if c == quote {
                    closed = true;
                    break;
                }
                word.push(c);
            }
            if !closed {
                return None;
            }
            if let Some(&next) = chars.peek()
                && next != ' '
                && next != '\t'
            {
                return None;
            }
            word
        } else {
            let rest: String = chars.clone().take(3).collect();
            let windows_unquoted = is_windows_prefix(&rest);
            let mut word = String::new();
            while let Some(c) = chars.next() {
                if c == ' ' || c == '\t' {
                    break;
                }
                if !windows_unquoted && c == '\\' {
                    if let Some(escaped) = chars.next() {
                        word.push(escaped);
                    } else {
                        word.push('\\');
                    }
                } else {
                    word.push(c);
                }
            }
            word
        };
        if !is_attachment_path(&token) {
            return None;
        }
        paths.push(PathBuf::from(token));
    }
    (!paths.is_empty()).then_some(paths)
}

fn is_windows_prefix(s: &str) -> bool {
    let bytes = s.as_bytes();
    (bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'\\')
        || s.starts_with("\\\\")
}

fn is_attachment_path(token: &str) -> bool {
    if token.is_empty() || token.contains("://") {
        return false;
    }
    let (segments, last_name): (usize, &str) = if let Some(rest) = token.strip_prefix('/') {
        if rest.is_empty() || rest.starts_with('/') || rest.ends_with('/') {
            return false;
        }
        let parts: Vec<&str> = rest.split('/').filter(|p| !p.is_empty()).collect();
        (parts.len(), *parts.last().unwrap_or(&""))
    } else if let Some(rest) = strip_windows_drive(token) {
        if rest.is_empty() || rest.ends_with('\\') || rest.ends_with('/') {
            return false;
        }
        let parts: Vec<&str> = rest.split(['\\', '/']).filter(|p| !p.is_empty()).collect();
        (parts.len(), *parts.last().unwrap_or(&""))
    } else if let Some(rest) = token.strip_prefix("\\\\") {
        if rest.is_empty() || rest.ends_with('\\') {
            return false;
        }
        let parts: Vec<&str> = rest.split('\\').filter(|p| !p.is_empty()).collect();
        if parts.len() < 3 {
            return false;
        }
        (parts.len(), *parts.last().unwrap_or(&""))
    } else {
        return false;
    };

    if segments < 2 || last_name.is_empty() {
        return false;
    }

    has_plausible_extension(last_name) || Path::new(token).is_file()
}

fn strip_windows_drive(token: &str) -> Option<&str> {
    let bytes = token.as_bytes();
    if bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/')
    {
        Some(&token[3..])
    } else {
        None
    }
}

fn has_plausible_extension(name: &str) -> bool {
    let Some((stem, ext)) = name.rsplit_once('.') else {
        return false;
    };
    !stem.is_empty() && !ext.is_empty() && ext.len() <= 12 && ext.chars().all(|c| c.is_ascii_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_names_its_attachments_after_the_text_one_word_each() {
        let files = [Attachment::file("/tmp/shots/a.png"), Attachment::file("/tmp/shots/b.png")];
        assert_eq!(message_text("  hello\n", &[]), Some("hello".into()));
        assert_eq!(message_text(" \n", &[]), None);
        assert_eq!(
            message_text(" Compare these ", &files).as_deref(),
            Some("Compare these\n/tmp/shots/a.png /tmp/shots/b.png")
        );
        // An image alone is a message too.
        assert_eq!(message_text("", &files[..1]).as_deref(), Some("/tmp/shots/a.png"));
    }

    #[test]
    fn splitting_message_attachments_round_trips_text_and_escaped_paths() {
        let files = [
            Attachment::file("/tmp/shots/Screen Shot [draft] #1.png"),
            Attachment::file("/Users/me/Desktop/notes.pdf"),
        ];
        let sent = message_text("Compare these two", &files).expect("message");
        let (body, parsed) = split_message_attachments(&sent);
        assert_eq!(body, "Compare these two");
        assert_eq!(parsed, files);

        // Attachment-only message yields empty body + attachments.
        let only = message_text("", &files[..1]).expect("only");
        let (body, parsed) = split_message_attachments(&only);
        assert_eq!(body, "");
        assert_eq!(parsed, &files[..1]);
    }

    #[test]
    fn splitting_handles_multiple_trailing_lines_and_windows_paths() {
        let multi = "Review these\n/tmp/shots/a.png\n/tmp/shots/b.md";
        let (body, parsed) = split_message_attachments(multi);
        assert_eq!(body, "Review these");
        assert_eq!(parsed, [Attachment::file("/tmp/shots/a.png"), Attachment::file("/tmp/shots/b.md")]);

        let win = "Look\n\"C:\\Users\\me\\My Shot.png\" C:\\Users\\me\\notes.md";
        let (body, parsed) = split_message_attachments(win);
        assert_eq!(body, "Look");
        assert_eq!(
            parsed,
            [Attachment::file("C:\\Users\\me\\My Shot.png"), Attachment::file("C:\\Users\\me\\notes.md")]
        );
    }

    #[test]
    fn splitting_leaves_prose_slash_commands_urls_and_code_blocks_untouched() {
        for plain in [
            "Check /tmp/shots/a.png please",
            "/compact",
            "https://example.com/a.png",
            "Endpoint:\n/api/v1/users",
            "```\n/tmp/shots/a.png\n```",
            "```\n/tmp/shots/a.png",
        ] {
            let (body, parsed) = split_message_attachments(plain);
            assert_eq!(body, plain, "unexpected split for: {plain}");
            assert!(parsed.is_empty(), "unexpected attachments for: {plain}");
        }
    }

    #[test]
    fn splitting_recognizes_existing_extensionless_files_on_disk() {
        let folder = tempfile::tempdir().expect("folder");
        let makefile = folder.path().join("Makefile");
        std::fs::write(&makefile, "all:\n").expect("makefile");
        let sent = message_text("Check build", &[Attachment::file(&makefile)]).expect("sent");
        let (body, parsed) = split_message_attachments(&sent);
        assert_eq!(body, "Check build");
        assert_eq!(parsed, [Attachment::file(&makefile)]);
    }

    #[test]
    fn a_pasted_image_becomes_a_file_of_its_own_that_goes_again_when_discarded() {
        let folder = tempfile::tempdir().expect("folder");
        // The folder is made on the first paste.
        let attachments = folder.path().join("attachments");
        let now = UNIX_EPOCH + std::time::Duration::from_secs(1_794_490_348);

        let first = store_pasted_image(&attachments, "png", b"first", now).expect("first");
        let second = store_pasted_image(&attachments, "png", b"second", now).expect("second");
        assert_eq!(first.name(), "pasted-1794490348.png");
        assert_eq!(second.name(), "pasted-1794490348-2.png");
        assert_eq!(std::fs::read(&second.path).expect("second file"), b"second");
        assert!(first.is_image() && first.pasted);

        let path = first.path.clone();
        first.discard();
        assert!(!path.exists());
    }

    #[test]
    fn a_file_the_person_attached_stays_when_it_is_taken_out_again() {
        let folder = tempfile::tempdir().expect("folder");
        let path = folder.path().join("notes.md");
        std::fs::write(&path, "notes").expect("file");
        let attachment = Attachment::file(&path);
        assert!(!attachment.is_image());
        attachment.discard();
        assert!(path.exists());
    }

    #[test]
    fn a_pasted_tiff_is_kept_as_png() {
        let folder = tempfile::tempdir().expect("folder");
        let mut tiff = io::Cursor::new(Vec::new());
        image::RgbaImage::from_pixel(2, 2, image::Rgba([10, 20, 30, 255]))
            .write_to(&mut tiff, image::ImageFormat::Tiff)
            .expect("tiff");

        let stored = store_pasted_image(folder.path(), "tiff", tiff.get_ref(), UNIX_EPOCH).expect("stored");
        assert_eq!(stored.name(), "pasted-0.png");
        let png = image::open(&stored.path).expect("png").to_rgba8();
        assert_eq!(png.get_pixel(1, 1), &image::Rgba([10, 20, 30, 255]));
    }
}
