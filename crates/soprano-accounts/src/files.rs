//! File and JSON helpers for the login files of other tools, which must never
//! be half-written, world-readable, or replaced when they are symlinks.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use serde_json::{Map, Value};

/// A JSON object, as the other tools' login files hold them.
pub type JsonObject = Map<String, Value>;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AccountFileError {
    #[error("{0} is not valid JSON; Soprano left it untouched.")]
    Unreadable(String),
    #[error("Could not write {0}: {1}")]
    WriteFailed(String, String),
}

/// Replaces `path`'s contents atomically. The temporary file is created with
/// `permissions` before any byte is written, so a credential file is never
/// readable by others, not even briefly. A symlink is written through, not
/// replaced, so dotfile-managed configs stay linked. (`permissions` is a Unix
/// mode; Windows files inherit the folder's ACL, which is per-user under the
/// home folder.)
pub fn write(data: &[u8], path: &Path, permissions: u32) -> Result<(), AccountFileError> {
    let failed = |reason: String| AccountFileError::WriteFailed(path.display().to_string(), reason);
    let target = resolving_symlinks(path);
    let directory = target.parent().map(Path::to_path_buf).unwrap_or_default();
    let name = target.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary =
        directory.join(format!(".{name}.soprano-{}", uuid::Uuid::new_v4().to_string().to_uppercase()));

    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(permissions);
    }
    #[cfg(not(unix))]
    let _ = permissions;
    let mut file = options.open(&temporary).map_err(|error| failed(error.to_string()))?;
    let written = file.write_all(data).and_then(|()| file.sync_all());
    drop(file);
    if let Err(error) = written {
        let _ = fs::remove_file(&temporary);
        return Err(failed(error.to_string()));
    }
    if let Err(error) = fs::rename(&temporary, &target) {
        let _ = fs::remove_file(&temporary);
        return Err(failed(error.to_string()));
    }
    Ok(())
}

/// `path` with its symlinks resolved, as far as the path exists: a missing
/// file resolves its folder and keeps its name; a dangling link resolves to
/// where it points.
pub(crate) fn resolving_symlinks(path: &Path) -> PathBuf {
    let mut current = path.to_path_buf();
    for _ in 0..32 {
        if let Ok(resolved) = fs::canonicalize(&current) {
            return strip_verbatim(resolved);
        }
        match fs::read_link(&current) {
            Ok(destination) => {
                current = match current.parent() {
                    Some(parent) if destination.is_relative() => parent.join(destination),
                    _ => destination,
                };
            }
            Err(_) => break,
        }
    }
    match (current.parent(), current.file_name()) {
        (Some(parent), Some(name)) => {
            fs::canonicalize(parent).map(|parent| strip_verbatim(parent).join(name)).unwrap_or(current)
        }
        _ => current,
    }
}

/// Windows' `canonicalize` returns `\\?\C:\…`; tools given such a path (in an
/// environment variable, say) may not understand it. Plain drive paths are
/// returned without the prefix. Elsewhere this is the identity.
pub(crate) fn strip_verbatim(path: PathBuf) -> PathBuf {
    #[cfg(windows)]
    {
        let text = path.to_string_lossy();
        if let Some(rest) = text.strip_prefix(r"\\?\")
            && rest.as_bytes().get(1) == Some(&b':')
        {
            return PathBuf::from(rest);
        }
    }
    path
}

/// The JSON object in `path`; nil when the file does not exist. Fails when it
/// exists but is not a JSON object, so a caller never mistakes a file it
/// cannot read for an empty one and overwrites it.
pub fn json_object_at(path: &Path) -> Result<Option<JsonObject>, AccountFileError> {
    if !path.exists() {
        return Ok(None);
    }
    let unreadable = || AccountFileError::Unreadable(path.display().to_string());
    let data = fs::read(path).map_err(|_| unreadable())?;
    match serde_json::from_slice::<Value>(&data) {
        Ok(Value::Object(object)) => Ok(Some(object)),
        _ => Err(unreadable()),
    }
}

/// The JSON object in `text`, if it is one.
pub fn json_object(text: &str) -> Option<JsonObject> {
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    }
}

pub fn json_data(object: &JsonObject, pretty: bool) -> Vec<u8> {
    let result = if pretty { serde_json::to_vec_pretty(object) } else { serde_json::to_vec(object) };
    // A map of JSON values always serializes.
    result.unwrap_or_default()
}

pub fn json_string(object: &JsonObject) -> String {
    Value::Object(object.clone()).to_string()
}

/// The claims of a JWT, without verifying it: only used to read who a token
/// says it belongs to and when it expires.
pub fn jwt_claims(token: &str) -> Option<JsonObject> {
    let payload = token.split('.').filter(|part| !part.is_empty()).nth(1)?;
    let normalized = payload.replace('+', "-").replace('/', "_");
    let engine = GeneralPurpose::new(
        &base64::alphabet::URL_SAFE,
        GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
    );
    let data = engine.decode(normalized.as_bytes()).ok()?;
    match serde_json::from_slice::<Value>(&data) {
        Ok(Value::Object(object)) => Some(object),
        _ => None,
    }
}

/// The string at `key`, if it is one.
pub(crate) fn string<'a>(object: Option<&'a JsonObject>, key: &str) -> Option<&'a str> {
    object?.get(key)?.as_str()
}

/// The object at `key`, if it is one.
pub(crate) fn object<'a>(object: Option<&'a JsonObject>, key: &str) -> Option<&'a JsonObject> {
    object?.get(key)?.as_object()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_write_replaces_the_file_through_a_symlink_and_keeps_the_link() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real.json");
        fs::write(&real, b"{}").unwrap();
        let link = dir.path().join("link.json");
        #[cfg(unix)]
        std::os::unix::fs::symlink(&real, &link).unwrap();
        #[cfg(not(unix))]
        fs::copy(&real, &link).unwrap();

        write(br#"{"a":1}"#, &link, 0o600).unwrap();

        #[cfg(unix)]
        {
            assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
            assert_eq!(fs::read_to_string(&real).unwrap(), r#"{"a":1}"#);
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&real).unwrap().permissions().mode() & 0o777, 0o600);
        }
        assert_eq!(fs::read_to_string(&link).unwrap(), r#"{"a":1}"#);
        // No temporary file is left behind.
        assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 2);
    }

    #[test]
    fn a_file_that_is_not_a_json_object_is_unreadable_not_empty() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.json");
        assert_eq!(json_object_at(&path), Ok(None));
        fs::write(&path, b"[1]").unwrap();
        assert!(matches!(json_object_at(&path), Err(AccountFileError::Unreadable(_))));
    }

    #[test]
    fn jwt_claims_are_read_without_padding() {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(br#"{"email":"a@b.c"}"#);
        let claims = jwt_claims(&format!("eyJhbGciOiJub25lIn0.{payload}.signature")).unwrap();
        assert_eq!(claims["email"], "a@b.c");
        assert!(jwt_claims("not-a-jwt").is_none());
    }
}
