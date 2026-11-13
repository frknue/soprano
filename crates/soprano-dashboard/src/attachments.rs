//! What the composer's message brings along, without GPUI: files and pasted images. Every
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
