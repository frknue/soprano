//! Where Soprano keeps things on each OS, and the few OS services every crate needs.
//!
//! Everything platform-specific that is not UI lives behind this crate so the other crates
//! stay free of `#[cfg]`: app identity (release vs dev build), data/config/resource
//! locations, the persisted app-state store that replaces macOS `UserDefaults`, and
//! opening/revealing/trashing files.

pub mod identity;
pub mod paths;
pub mod shell;
pub mod state;
pub mod system;

pub use identity::AppIdentity;
pub use state::StateStore;
