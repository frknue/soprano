//! Helpers shared by the crate's tests.

/// Marks a stand-in script (a fake shell or CLI) executable.
#[cfg(unix)]
pub(crate) fn make_executable(path: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}
