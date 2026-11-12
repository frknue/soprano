//! Why the app closed: every panic's message, place and backtrace, appended to `panic.log` in
//! the app's data folder. A panic ends the process with an exit, not a signal, so the system
//! writes no crash report, and an app started from the Dock has no terminal to print to:
//! without this file nothing says why Soprano closed.

use std::backtrace::Backtrace;
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// The log's name in the data folder.
pub const FILE_NAME: &str = "panic.log";
/// The log starts over once it is this long: it holds the last panics, not a history.
const MAXIMUM_BYTES: u64 = 256 * 1024;

/// Records every panic of this process in `path`, then lets it take its usual course.
pub fn install(path: PathBuf) {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current();
        let when = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f %:z").to_string();
        let entry = format!(
            "{when} Soprano {} thread {}\n{info}\n{}\n\n",
            soprano_platform::identity::app_version(),
            thread.name().unwrap_or("unnamed"),
            Backtrace::force_capture(),
        );
        // Nothing can be done about a log that cannot be written while panicking.
        let _ = append(&path, &entry, MAXIMUM_BYTES);
        previous(info);
    }));
}

/// Adds `entry` to the log at `path`, creating its folder; a log already `maximum` bytes long
/// starts over with it.
fn append(path: &Path, entry: &str, maximum: u64) -> std::io::Result<()> {
    if let Some(folder) = path.parent() {
        std::fs::create_dir_all(folder)?;
    }
    let full = std::fs::metadata(path).is_ok_and(|log| log.len() >= maximum);
    let mut log =
        std::fs::OpenOptions::new().create(true).append(!full).write(true).truncate(full).open(path)?;
    log.write_all(entry.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_log_keeps_earlier_panics_until_it_is_full_then_starts_over() {
        let folder = tempfile::tempdir().expect("folder");
        // The data folder may not exist yet on a first launch.
        let path = folder.path().join("com.soprano.test").join(FILE_NAME);

        append(&path, "first\n", 16).expect("first");
        append(&path, "second panic\n", 16).expect("second");
        assert_eq!(std::fs::read_to_string(&path).expect("log"), "first\nsecond panic\n");

        append(&path, "third\n", 16).expect("third");
        assert_eq!(std::fs::read_to_string(&path).expect("log"), "third\n");
    }

    #[test]
    fn a_panic_leaves_its_message_and_place_in_the_log() {
        let folder = tempfile::tempdir().expect("folder");
        let path = folder.path().join(FILE_NAME);
        install(path.clone());
        let outcome = std::panic::catch_unwind(|| panic!("the pane fell over"));
        // Back to the standard hook for the rest of the test run.
        drop(std::panic::take_hook());

        assert!(outcome.is_err());
        let log = std::fs::read_to_string(&path).expect("log");
        assert!(log.contains("the pane fell over"), "{log}");
        assert!(log.contains(file!()), "{log}");
    }
}
