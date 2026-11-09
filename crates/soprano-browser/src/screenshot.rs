//! `soprano browser screenshot`: a PNG of the visible page.

/// Errors that end a screenshot, worded as the Swift app's `BrowserAutomationError.screenshot`.
pub const ENCODE_FAILED_MESSAGE: &str = "WebKit could not encode the screenshot";

/// The answer on platforms whose web view has no snapshot API wired up (WebView2, WebKitGTK).
pub const UNSUPPORTED_MESSAGE: &str = "Screenshots are not supported by this platform's web view";

/// Captures the page and calls `done` once on the UI thread with the PNG bytes.
#[cfg(target_os = "macos")]
pub fn capture_png(webview: &wry::WebView, done: impl FnOnce(Result<Vec<u8>, String>) + 'static) {
    use std::cell::Cell;

    use block2::RcBlock;
    use objc2_app_kit::{NSBitmapImageFileType, NSBitmapImageRep, NSImage};
    use objc2_foundation::{NSDictionary, NSError};
    use wry::WebViewExtMacOS as _;

    let done = Cell::new(Some(done));
    let handler = RcBlock::new(move |image: *mut NSImage, error: *mut NSError| {
        let Some(done) = done.take() else { return };
        // SAFETY: WebKit passes either null or a valid object for the duration of the call.
        let (image, error) = unsafe { (image.as_ref(), error.as_ref()) };
        if let Some(error) = error {
            done(Err(error.localizedDescription().to_string()));
            return;
        }
        let png = image.and_then(|image| {
            let tiff = image.TIFFRepresentation()?;
            let bitmap = NSBitmapImageRep::imageRepWithData(&tiff)?;
            // SAFETY: an empty properties dictionary is a valid argument.
            unsafe {
                bitmap.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new())
            }
        });
        match png {
            Some(data) => done(Ok(data.to_vec())),
            None => done(Err(ENCODE_FAILED_MESSAGE.to_string())),
        }
    });
    let view = webview.webview();
    // SAFETY: called on the main thread that owns the web view; a nil configuration snapshots
    // the visible bounds.
    unsafe { view.takeSnapshotWithConfiguration_completionHandler(None, &handler) };
}

#[cfg(not(target_os = "macos"))]
pub fn capture_png(_webview: &wry::WebView, done: impl FnOnce(Result<Vec<u8>, String>) + 'static) {
    done(Err(UNSUPPORTED_MESSAGE.to_string()));
}

/// Writes `png` to `path`, creating its folder, and returns the absolute path written.
pub fn write_png(path: &std::path::Path, png: &[u8]) -> Result<String, String> {
    let path = std::path::absolute(path).map_err(|error| error.to_string())?;
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder).map_err(|error| error.to_string())?;
    }
    // Write beside the target, then rename, like `Data.write(options: .atomic)`.
    let staging = path.with_extension("png.soprano-tmp");
    std::fs::write(&staging, png).map_err(|error| error.to_string())?;
    std::fs::rename(&staging, &path).map_err(|error| {
        let _ = std::fs::remove_file(&staging);
        error.to_string()
    })?;
    Ok(path.to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests {
    use super::write_png;

    #[test]
    fn screenshots_create_their_folder_and_report_the_absolute_path() {
        let root = std::env::temp_dir().join(format!("soprano-browser-shot-{}", std::process::id()));
        let path = root.join("nested/shot.png");
        let written = write_png(&path, b"png").expect("written");
        assert_eq!(written, path.to_string_lossy());
        assert_eq!(std::fs::read(&path).expect("readable"), b"png");
        std::fs::remove_dir_all(&root).expect("cleanup");
    }
}
