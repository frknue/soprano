//! Shared helpers for the panels' GPUI tests.

use std::cell::RefCell;
use std::path::Path;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::time::{Duration, Instant};

use gpui::{Entity, EventEmitter, TestAppContext, VisualTestContext};

use crate::SidebarEvent;

pub(crate) fn init(cx: &mut TestAppContext) {
    cx.update(soprano_ui::init_for_tests);
    cx.executor().allow_parking();
}

/// Lets real threads (file watcher, git) and timers run until `condition` holds.
pub(crate) fn wait_until(
    cx: &mut VisualTestContext,
    mut condition: impl FnMut(&mut VisualTestContext) -> bool,
) {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        cx.run_until_parked();
        if condition(cx) {
            return;
        }
        assert!(Instant::now() < deadline, "timed out");
        cx.executor().advance_clock(Duration::from_millis(100));
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Records every event `entity` emits.
pub(crate) fn record<T: EventEmitter<SidebarEvent>>(
    entity: &Entity<T>,
    cx: &mut VisualTestContext,
) -> Rc<RefCell<Vec<SidebarEvent>>> {
    let events = Rc::new(RefCell::new(Vec::new()));
    let sink = events.clone();
    cx.update(|_, cx| {
        cx.subscribe(entity, move |_, event: &SidebarEvent, _| sink.borrow_mut().push(event.clone()))
            .detach();
    });
    events
}

pub(crate) fn has_git() -> bool {
    soprano_git::reader::executable().is_some()
}

pub(crate) fn git(arguments: &[&str], directory: &Path) {
    let status = Command::new(soprano_git::reader::executable().expect("git"))
        .arg("-C")
        .arg(directory)
        .args(arguments)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("git runs");
    assert!(status.success(), "git {arguments:?}");
}

/// A repository whose `app.txt` is committed as "one\ntwo\nthree\n".
pub(crate) fn repository() -> tempfile::TempDir {
    let root = tempfile::tempdir().expect("temp dir");
    git(&["init", "-q"], root.path());
    std::fs::write(root.path().join("app.txt"), "one\ntwo\nthree\n").expect("write");
    git(&["add", "app.txt"], root.path());
    git(
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
            "-c",
            "core.hooksPath=/dev/null",
            "commit",
            "-qm",
            "init",
        ],
        root.path(),
    );
    root
}
