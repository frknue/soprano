//! Errors of account actions. Each displays as the message Settings shows.

use crate::command::CommandError;
use crate::files::AccountFileError;
use crate::secrets::SecretStoreError;

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ClaudeAccountError {
    #[error("Claude sign-in failed: {0}")]
    LoginFailed(String),
    #[error("Claude Code finished signing in, but Soprano could not find the login it stored.")]
    NoCredentials,
    #[error("Claude Code finished signing in, but did not say which account it signed in to.")]
    NoIdentity,
    #[error("{0} is already added.")]
    Duplicate(String),
    #[error("Signed in as {signed_in}, not {expected}. Sign in to {expected} in the browser and try again.")]
    WrongAccount { expected: String, signed_in: String },
    #[error("Soprano no longer has the login for {0}. Re-authenticate it.")]
    MissingCredentials(String),
    #[error("That account is no longer in the list.")]
    UnknownAccount,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CodexAccountError {
    #[error("Codex sign-in failed: {0}")]
    LoginFailed(String),
    #[error("codex login finished, but no ChatGPT login was saved.")]
    NoCredentials,
    #[error("{0} is already added.")]
    Duplicate(String),
    #[error("Signed in as {signed_in}, not {expected}. The previous login was kept.")]
    WrongAccount { expected: String, signed_in: String },
    #[error("That account is no longer in the list.")]
    UnknownAccount,
    #[error("{0} is not a Soprano-managed Codex home; it was left alone.")]
    NotManaged(String),
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum OmpAccountError {
    #[error("omp: {0}")]
    Unavailable(String),
    #[error("omp sign-in failed: {0}")]
    LoginFailed(String),
    #[error("omp has no login for {0} any more.")]
    NotStored(String),
    #[error("This omp version stores logins differently ({0}). Remove the account with /logout in omp.")]
    UnsupportedStore(String),
}

/// Any failed account action.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum AccountError {
    #[error(transparent)]
    Claude(#[from] ClaudeAccountError),
    #[error(transparent)]
    Codex(#[from] CodexAccountError),
    #[error(transparent)]
    Omp(#[from] OmpAccountError),
    #[error(transparent)]
    File(#[from] AccountFileError),
    #[error(transparent)]
    SecretStore(#[from] SecretStoreError),
    #[error(transparent)]
    Command(#[from] CommandError),
    #[error("{0}")]
    Io(String),
}

impl From<std::io::Error> for AccountError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

impl AccountError {
    /// The user cancelled a sign-in: nothing to report.
    pub fn is_cancelled(&self) -> bool {
        matches!(self, Self::Command(CommandError::Cancelled))
    }
}

pub type AccountResult<T> = Result<T, AccountError>;
