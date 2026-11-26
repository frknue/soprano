//! Device pairing, QR matrix generation, and hashed session-token storage.
//!
//! Plaintext session tokens are issued once during `POST /api/pair` and never persisted on
//! disk; Soprano stores only their SHA-256 hashes alongside device metadata in [`StateStore`].

use std::sync::Mutex;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Duration, Utc};
use qrcode::{Color, EcLevel, QrCode};
use rand::RngCore as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use soprano_platform::StateStore;

/// StateStore key holding paired mobile devices (metadata + SHA-256 token hashes).
pub const DEVICES_STATE_KEY: &str = "soprano-mobile-devices";
/// How long a generated pairing QR code stays valid before expiring.
pub const PAIRING_TTL_SECONDS: i64 = 300;
/// Minimum interval between persisting `last_seen` updates for an active device.
const LAST_SEEN_TOUCH_SECONDS: i64 = 60;

/// Square boolean QR matrix (dark = `true`, light = `false`) ready for direct canvas painting.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QrMatrix {
    pub width: usize,
    pub modules: Vec<bool>,
}

impl QrMatrix {
    /// Encodes `content` as a QR matrix using medium error correction.
    pub fn encode(content: &str) -> Result<Self, String> {
        let code = QrCode::with_error_correction_level(content.as_bytes(), EcLevel::M)
            .map_err(|err| format!("Could not generate QR code: {err}"))?;
        let width = code.width();
        let modules = code.into_colors().into_iter().map(|c| c == Color::Dark).collect();
        Ok(Self { width, modules })
    }

    pub fn is_dark(&self, x: usize, y: usize) -> bool {
        self.modules.get(y * self.width + x).copied().unwrap_or(false)
    }
}

/// One active, single-use pairing code and its rendered QR matrix.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairingOffer {
    pub token: String,
    pub url: String,
    pub qr: QrMatrix,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

impl PairingOffer {
    pub fn is_expired_at(&self, now: DateTime<Utc>) -> bool {
        now >= self.expires_at
    }
}

/// Public metadata for one paired phone/tablet (safe to display in Settings).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairedDevice {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tailscale_user: Option<String>,
    pub paired_at: DateTime<Utc>,
    pub last_seen: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct StoredDevice {
    device: PairedDevice,
    token_hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PairError {
    MissingOffer,
    Expired,
    InvalidToken,
}

impl PairError {
    pub fn message(&self) -> &'static str {
        match self {
            Self::MissingOffer => {
                "No active pairing code. Open Settings ▸ Mobile in Soprano to generate one."
            }
            Self::Expired => "That pairing code has expired. Regenerate it in Settings ▸ Mobile.",
            Self::InvalidToken => "Invalid pairing code. Scan the QR code in Settings ▸ Mobile again.",
        }
    }
}

struct PairingInner {
    offer: Option<PairingOffer>,
    devices: Vec<StoredDevice>,
}

/// Thread-safe registry of paired devices and the currently active one-time pairing offer.
pub struct PairingStore {
    state: StateStore,
    inner: Mutex<PairingInner>,
}

impl PairingStore {
    pub fn new(state: StateStore) -> Self {
        let devices = state.get::<Vec<StoredDevice>>(DEVICES_STATE_KEY).unwrap_or_default();
        Self { state, inner: Mutex::new(PairingInner { offer: None, devices }) }
    }

    /// Generates a fresh 256-bit single-use pairing code targeting `base_url` (e.g.
    /// `https://mac.tail.ts.net:8443`).
    pub fn create_offer(&self, base_url: &str) -> Result<PairingOffer, String> {
        let now = Utc::now();
        let token = random_token(32);
        let trimmed = base_url.trim_end_matches('/');
        let url = format!("{trimmed}/pair#t={token}");
        let qr = QrMatrix::encode(&url)?;
        let offer = PairingOffer {
            token,
            url,
            qr,
            created_at: now,
            expires_at: now + Duration::seconds(PAIRING_TTL_SECONDS),
        };
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.offer = Some(offer.clone());
        Ok(offer)
    }

    /// Clears the current pairing offer (e.g. when Mobile Access is disabled).
    pub fn clear_offer(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.offer = None;
    }

    /// Returns the active pairing offer if it has not expired.
    pub fn active_offer(&self) -> Option<PairingOffer> {
        let now = Utc::now();
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if inner.offer.as_ref().is_some_and(|offer| offer.is_expired_at(now)) {
            inner.offer = None;
        }
        inner.offer.clone()
    }

    /// Exchanges a one-time pairing token for a long-lived device session token.
    /// Consumes the pairing offer immediately on success.
    pub fn redeem(
        &self,
        candidate_token: &str,
        device_name: &str,
        tailscale_user: Option<String>,
    ) -> Result<(PairedDevice, String), PairError> {
        let now = Utc::now();
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let Some(offer) = inner.offer.as_ref() else {
            return Err(PairError::MissingOffer);
        };
        if offer.is_expired_at(now) {
            inner.offer = None;
            return Err(PairError::Expired);
        }
        if !constant_time_eq(offer.token.as_bytes(), candidate_token.trim().as_bytes()) {
            return Err(PairError::InvalidToken);
        }
        // Single-use: burn the offer as soon as it matches.
        inner.offer = None;

        let raw_session = random_token(32);
        let token_hash = sha256_hex(&raw_session);
        let clean_name = sanitize_device_name(device_name);
        let device = PairedDevice {
            id: random_token(12),
            name: clean_name,
            tailscale_user: tailscale_user.map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()),
            paired_at: now,
            last_seen: now,
        };
        inner.devices.push(StoredDevice { device: device.clone(), token_hash });
        self.persist_locked(&inner.devices);
        Ok((device, raw_session))
    }

    /// Verifies a session cookie value against stored device hashes.
    pub fn verify_session(&self, raw_token: &str) -> Option<PairedDevice> {
        let candidate_hash = sha256_hex(raw_token);
        let now = Utc::now();
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let mut updated = false;
        let mut matched = None;
        for stored in &mut inner.devices {
            if constant_time_eq(stored.token_hash.as_bytes(), candidate_hash.as_bytes()) {
                if (now - stored.device.last_seen).num_seconds() >= LAST_SEEN_TOUCH_SECONDS {
                    stored.device.last_seen = now;
                    updated = true;
                }
                matched = Some(stored.device.clone());
                break;
            }
        }
        if updated {
            self.persist_locked(&inner.devices);
        }
        matched
    }

    /// Lists all paired devices, newest first.
    pub fn devices(&self) -> Vec<PairedDevice> {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let mut list: Vec<PairedDevice> = inner.devices.iter().map(|s| s.device.clone()).collect();
        list.sort_by_key(|a| std::cmp::Reverse(a.last_seen));
        list
    }

    /// Revokes one paired device by id. Returns `true` if it existed.
    pub fn revoke(&self, device_id: &str) -> bool {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let before = inner.devices.len();
        inner.devices.retain(|stored| stored.device.id != device_id);
        let removed = inner.devices.len() != before;
        if removed {
            self.persist_locked(&inner.devices);
        }
        removed
    }

    /// Revokes every paired device. Returns the count removed.
    pub fn revoke_all(&self) -> usize {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let count = inner.devices.len();
        if count > 0 {
            inner.devices.clear();
            self.persist_locked(&inner.devices);
        }
        count
    }

    fn persist_locked(&self, devices: &[StoredDevice]) {
        self.state.set(DEVICES_STATE_KEY, devices);
    }
}

fn sanitize_device_name(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return "Mobile device".into();
    }
    trimmed.chars().take(48).collect()
}

fn random_token(byte_len: usize) -> String {
    let mut bytes = vec![0u8; byte_len];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn sha256_hex(input: &str) -> String {
    let digest = Sha256::digest(input.as_bytes());
    hex::encode(digest)
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (&x, &y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_offer_is_single_use_and_persists_hashed_device_session() {
        let state = StateStore::in_memory();
        let store = PairingStore::new(state.clone());
        let offer = store.create_offer("https://mac.tail.ts.net:8443").expect("offer");
        assert!(offer.url.starts_with("https://mac.tail.ts.net:8443/pair#t="));
        assert!(offer.qr.width >= 21);

        assert_eq!(store.redeem("wrong-token", "iPhone", None), Err(PairError::InvalidToken));

        let (device, session_token) =
            store.redeem(&offer.token, "Furkan's iPhone", Some("furkan@example.com".into())).expect("paired");
        assert_eq!(device.name, "Furkan's iPhone");
        assert_eq!(device.tailscale_user.as_deref(), Some("furkan@example.com"));

        // Redeeming the same code a second time fails.
        assert_eq!(store.redeem(&offer.token, "Other", None), Err(PairError::MissingOffer));

        // Persisted JSON never contains the plaintext session token.
        let raw_saved = state.get_raw(DEVICES_STATE_KEY).expect("saved").to_string();
        assert!(!raw_saved.contains(&session_token));

        // Reopening from the same StateStore still validates the session token.
        let reopened = PairingStore::new(state);
        assert_eq!(reopened.verify_session(&session_token).map(|d| d.id), Some(device.id.clone()));
        assert_eq!(reopened.verify_session("invalid"), None);

        assert!(reopened.revoke(&device.id));
        assert_eq!(reopened.verify_session(&session_token), None);
        assert!(reopened.devices().is_empty());
    }
}
