//! Where logins are kept as secrets: the macOS Keychain through the
//! `security` CLI (Claude Code's own item), and the OS secret store through
//! `keyring` (Soprano's stored logins, on every OS).

use std::time::Duration;

use crate::command::{CommandResult, CommandRunner, RunOptions};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SecretStoreError {
    #[error("Keychain: {0}")]
    CommandFailed(String),
    #[error("Keychain: could not store the login in \"{service}\".")]
    WriteNotStored { service: String },
    #[error("Secret store: {0}")]
    Unavailable(String),
}

/// Generic-password items keyed by service and account.
pub trait SecretStore: Send + Sync {
    /// The item's secret, or nil when there is no such item.
    fn read(&self, service: &str, account: &str) -> Result<Option<String>, SecretStoreError>;
    /// Creates or replaces the item.
    fn write(&self, service: &str, account: &str, secret: &str) -> Result<(), SecretStoreError>;
    /// Deletes the item; a missing item is not an error.
    fn delete(&self, service: &str, account: &str) -> Result<(), SecretStoreError>;
}

/// Generic-password items through `/usr/bin/security` (macOS).
///
/// Claude Code creates its credential item with `security`, so the item's
/// access list trusts that tool: going through it, Soprano reads and updates
/// the item without a Keychain prompt — and a rebuilt (re-signed) Soprano does
/// not lose access to it.
#[derive(Debug, Clone)]
pub(crate) struct KeychainCli {
    pub runner: CommandRunner,
    pub executable: String,
}

/// `errSecItemNotFound`, which `security` exits with for a missing item.
const NOT_FOUND_STATUS: i32 = 44;
const TIMEOUT: Duration = Duration::from_secs(15);

impl Default for KeychainCli {
    fn default() -> Self {
        Self { runner: CommandRunner::default(), executable: "/usr/bin/security".into() }
    }
}

impl KeychainCli {
    #[cfg(all(test, target_os = "macos"))]
    pub fn with_executable(executable: impl Into<String>) -> Self {
        Self { runner: CommandRunner::default(), executable: executable.into() }
    }

    /// `security -i` reads each line into a 4096-byte buffer and cuts longer
    /// ones; Claude Code switches to arguments above the same bound.
    pub const INTERACTIVE_LINE_LIMIT: usize = 4096 - 64;

    fn run(&self, arguments: &[&str], input: Option<Vec<u8>>) -> Result<CommandResult, SecretStoreError> {
        self.runner
            .run(&self.executable, arguments, None, TIMEOUT, RunOptions { input, ..RunOptions::default() })
            .map_err(|error| SecretStoreError::CommandFailed(error.to_string()))
    }

    /// The `security -i` line that stores `secret`. Service and account are
    /// Soprano's own constants, the user name, or UUIDs; none can contain a
    /// quote, so plain double-quoting is safe.
    pub fn add_command(service: &str, account: &str, secret: &str) -> String {
        debug_assert!(!service.contains('"') && !account.contains('"'));
        format!("add-generic-password -U -a \"{account}\" -s \"{service}\" -X \"{}\"\n", hex(secret))
    }

    /// `security -w` prints a secret that is not plain printable ASCII — JSON
    /// holding an organization name with an umlaut, say — as hex.
    pub fn decoded_secret(output: &str) -> String {
        if output.is_empty()
            || !output.len().is_multiple_of(2)
            || !output.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return output.to_owned();
        }
        let bytes: Option<Vec<u8>> = (0..output.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&output[index..index + 2], 16).ok())
            .collect();
        match bytes.and_then(|bytes| String::from_utf8(bytes).ok()) {
            Some(text) if text.starts_with('{') || text.starts_with('[') => text,
            _ => output.to_owned(),
        }
    }
}

fn hex(secret: &str) -> String {
    secret.bytes().map(|byte| format!("{byte:02x}")).collect()
}

impl SecretStore for KeychainCli {
    fn read(&self, service: &str, account: &str) -> Result<Option<String>, SecretStoreError> {
        let result = self.run(&["find-generic-password", "-s", service, "-a", account, "-w"], None)?;
        if result.status == NOT_FOUND_STATUS {
            return Ok(None);
        }
        if !result.succeeded() {
            return Err(SecretStoreError::CommandFailed(result.failure_message()));
        }
        let output = result.stdout.strip_suffix('\n').unwrap_or(&result.stdout);
        Ok(Some(Self::decoded_secret(output)))
    }

    /// The secret goes in on stdin through `security -i`, hex-encoded the way
    /// Claude Code writes it, so it never shows up in a process listing —
    /// unless the line would be too long for `security -i` (a Claude login
    /// with MCP tokens beside it). Then, like Claude Code, it goes in as an
    /// argument, visible to `ps` while `security` runs.
    fn write(&self, service: &str, account: &str, secret: &str) -> Result<(), SecretStoreError> {
        let command = Self::add_command(service, account, secret);
        let result = if command.len() <= Self::INTERACTIVE_LINE_LIMIT {
            self.run(&["-i"], Some(command.into_bytes()))?
        } else {
            let hex = hex(secret);
            self.run(&["add-generic-password", "-U", "-a", account, "-s", service, "-X", &hex], None)?
        };
        // `security -i` reports a failed command on stderr but can still exit
        // 0, so the only proof of a write is reading the item back.
        if self.read(service, account)?.as_deref() != Some(secret) {
            if !result.stderr.is_empty() {
                return Err(SecretStoreError::CommandFailed(result.failure_message()));
            }
            return Err(SecretStoreError::WriteNotStored { service: service.to_owned() });
        }
        Ok(())
    }

    fn delete(&self, service: &str, account: &str) -> Result<(), SecretStoreError> {
        let result = self.run(&["delete-generic-password", "-s", service, "-a", account], None)?;
        if result.succeeded() || result.status == NOT_FOUND_STATUS {
            Ok(())
        } else {
            Err(SecretStoreError::CommandFailed(result.failure_message()))
        }
    }
}

/// The OS secret store through `keyring`: the login Keychain on macOS, the
/// Credential Manager on Windows, the Secret Service on Linux.
#[derive(Debug, Clone, Copy, Default)]
pub struct KeyringStore;

fn keyring_error(error: keyring::Error) -> SecretStoreError {
    SecretStoreError::Unavailable(error.to_string())
}

impl SecretStore for KeyringStore {
    fn read(&self, service: &str, account: &str) -> Result<Option<String>, SecretStoreError> {
        let entry = keyring::Entry::new(service, account).map_err(keyring_error)?;
        match entry.get_password() {
            Ok(secret) => Ok(Some(secret)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(keyring_error(error)),
        }
    }

    fn write(&self, service: &str, account: &str, secret: &str) -> Result<(), SecretStoreError> {
        let entry = keyring::Entry::new(service, account).map_err(keyring_error)?;
        entry.set_password(secret).map_err(keyring_error)?;
        if entry.get_password().ok().as_deref() != Some(secret) {
            return Err(SecretStoreError::WriteNotStored { service: service.to_owned() });
        }
        Ok(())
    }

    fn delete(&self, service: &str, account: &str) -> Result<(), SecretStoreError> {
        let entry = keyring::Entry::new(service, account).map_err(keyring_error)?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(keyring_error(error)),
        }
    }
}

/// A secret store in memory, for tests.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct MemorySecretStore {
    pub items: std::sync::Mutex<std::collections::BTreeMap<(String, String), String>>,
}

#[cfg(test)]
impl SecretStore for MemorySecretStore {
    fn read(&self, service: &str, account: &str) -> Result<Option<String>, SecretStoreError> {
        Ok(self.items.lock().unwrap().get(&(service.to_owned(), account.to_owned())).cloned())
    }

    fn write(&self, service: &str, account: &str, secret: &str) -> Result<(), SecretStoreError> {
        self.items.lock().unwrap().insert((service.to_owned(), account.to_owned()), secret.to_owned());
        Ok(())
    }

    fn delete(&self, service: &str, account: &str) -> Result<(), SecretStoreError> {
        self.items.lock().unwrap().remove(&(service.to_owned(), account.to_owned()));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_keychain_secret_security_prints_as_hex_is_read_back_as_the_json_it_was() {
        let json = r#"{"oauthAccount":{"organizationName":"Müller's Organization"}}"#;
        let hex = hex(json);

        assert_eq!(KeychainCli::decoded_secret(&hex), json);
        // A plain secret that merely looks like hex is left alone.
        assert_eq!(KeychainCli::decoded_secret("cafe"), "cafe");
        assert_eq!(KeychainCli::decoded_secret(json), json);
    }

    #[test]
    fn the_keychain_write_command_carries_the_secret_hex_encoded_only() {
        let command = KeychainCli::add_command("Claude Code-credentials", "ada", r#"{"a":"b c"}"#);
        assert_eq!(
            command,
            "add-generic-password -U -a \"ada\" -s \"Claude Code-credentials\" -X \"7b2261223a22622063227d\"\n"
        );
    }

    /// Speaks the `security` commands Soprano uses, filing generic passwords
    /// as plain files. Like the real tool, `-i` reads each input line into a
    /// 4096-byte buffer, so a longer line is cut.
    #[cfg(target_os = "macos")]
    pub(crate) const FAKE_SECURITY: &str = r#"#!/bin/bash
set -u
dir="$(dirname "$0")/items"
mkdir -p "$dir"
name() { printf '%s' "$1|$2" | shasum | cut -d' ' -f1; }
lookup() {
    service=""; account=""; hex=""
    while [ $# -gt 0 ]; do
        case "$1" in -s) service="$2"; shift 2;; -a) account="$2"; shift 2;; -X) hex="$2"; shift 2;; *) shift;; esac
    done
    item="$dir/$(name "$service" "$account")"
}
case "${1:-}" in
    find-generic-password)
        shift; lookup "$@"
        [ -f "$item" ] || exit 44
        cat "$item"; echo ;;
    delete-generic-password)
        shift; lookup "$@"
        [ -f "$item" ] || exit 44
        rm "$item" ;;
    add-generic-password)
        shift; lookup "$@"
        printf '%s' "$hex" | xxd -r -p > "$item" ;;
    -i)
        while IFS= read -r line; do
            line="${line:0:4095}"
            account=$(sed -E 's/.* -a "([^"]*)".*/\1/' <<<"$line")
            service=$(sed -E 's/.* -s "([^"]*)".*/\1/' <<<"$line")
            hex=$(sed -E 's/.* -X "([^"]*)".*/\1/' <<<"$line")
            printf '%s' "$hex" | xxd -r -p > "$dir/$(name "$service" "$account")"
        done ;;
esac
"#;

    #[cfg(target_os = "macos")]
    fn fake_keychain(dir: &std::path::Path) -> KeychainCli {
        let security = dir.join("security");
        std::fs::write(&security, FAKE_SECURITY).unwrap();
        crate::command::tests::make_executable(&security);
        KeychainCli::with_executable(security.to_string_lossy())
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_login_too_long_for_one_security_input_line_is_still_stored() {
        let dir = tempfile::tempdir().unwrap();
        let keychain = fake_keychain(dir.path());
        // MCP OAuth tokens beside the login push the item past 2 KB, its hex past 4 KB.
        let secret = format!(
            r#"{{"claudeAiOauth":{{"accessToken":"a"}},"mcpOAuth":{{"server":"{}"}}}}"#,
            "t".repeat(3_000)
        );

        keychain.write("Claude Code-credentials", "ada", &secret).unwrap();

        assert_eq!(keychain.read("Claude Code-credentials", "ada").unwrap(), Some(secret));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_security_cli_round_trips_and_deletes_items() {
        let dir = tempfile::tempdir().unwrap();
        let keychain = fake_keychain(dir.path());

        assert_eq!(keychain.read("s", "a").unwrap(), None);
        keychain.write("s", "a", r#"{"k":"Müller"}"#).unwrap();
        assert_eq!(keychain.read("s", "a").unwrap().as_deref(), Some(r#"{"k":"Müller"}"#));
        keychain.delete("s", "a").unwrap();
        keychain.delete("s", "a").unwrap();
        assert_eq!(keychain.read("s", "a").unwrap(), None);
    }
}
