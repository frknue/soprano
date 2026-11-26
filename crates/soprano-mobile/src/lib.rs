//! soprano-mobile: private mobile PWA access over Tailscale HTTPS with one-scan QR pairing.
//!
//! Pure Rust (no GPUI dependency):
//! - [`tailscale`]: probes `tailscale status --json` and manages private `tailscale serve`
//!   forwarding to Soprano's loopback server.
//! - [`pairing`]: single-use expiring pairing offers, QR matrix encoding, and SHA-256 hashed
//!   device session storage in [`soprano_platform::StateStore`].
//! - [`server`]: embedded loopback `axum` HTTP + WebSocket server serving the PWA and JSON API.
//! - [`controller`]: app-lifetime [`MobileController`] implementing [`MobileSource`] for Settings.

pub mod controller;
pub mod pairing;
pub mod protocol;
pub mod pwa;
pub mod server;
pub mod tailscale;

pub use controller::{MobileController, MobileObserver, MobileSource, MobileStateSnapshot};
pub use pairing::{DEVICES_STATE_KEY, PAIRING_TTL_SECONDS, PairError, PairedDevice, PairingOffer, QrMatrix};
pub use protocol::{
    MobileAction, MobileActionResponse, MobileAgentProfile, MobileApproval, MobileApprovalOption,
    MobileCommand, MobileConfigOption, MobileConfigOptionValue, MobileFileChange, MobileProject,
    MobileSnapshot, MobileTheme, MobileThreadDetail, MobileThreadSummary, MobileTurn, MobileTurnItem,
    MobileUserInput, MobileUserQuestion, MobileUserQuestionOption, ServerEvent, approval_from_request,
    turns_from_chat_thread, user_input_from_request,
};
pub use tailscale::{
    CommandOutput, ServeOutcome, SystemTailscaleRunner, TAILSCALE_DNS_ADMIN_URL, TailscaleNodeInfo,
    TailscaleRunner, TailscaleStatus,
};
