//! Device backends: the real one (idevice over usbmuxd) and a scripted mock
//! for demos and UI work without an iPhone.

use std::collections::HashMap;

use tokio::sync::mpsc::UnboundedSender;

use crate::cache::HostIdentity;
use crate::model::{AttachedDevice, DeviceInfo, EnvReport, PairError, RpVia, TrustOutcome, WriteVia};

pub mod mock;
pub mod real;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WatchEvent {
    /// A USB device appeared (network devices are filtered out by the backend).
    Attached(AttachedDevice),
    Detached { mux_id: u32 },
}

/// Result of the Trust step: the outcome and, when trusted, the lockdown
/// record as plist bytes.
#[derive(Debug, Clone)]
pub struct TrustResult {
    pub outcome: TrustOutcome,
    pub lockdown: Option<Vec<u8>>,
}

/// installation_proxy lookup: bundle ID → Info dictionary.
pub type AppList = HashMap<String, plist::Value>;

/// One backend for the whole app. Futures need not be `Send`: everything
/// runs on the manager's single-threaded runtime.
#[allow(async_fn_in_trait)]
pub trait Backend: 'static {
    type Conn: DeviceConn;

    async fn env_check(&self) -> EnvReport;

    /// Streams attach/detach events until the usbmuxd connection drops.
    /// Devices already attached are reported first.
    async fn watch(&self, tx: UnboundedSender<WatchEvent>) -> Result<(), PairError>;

    fn open(&self, dev: &AttachedDevice) -> Self::Conn;
}

/// Operations on one phone. Each call opens what it needs (lockdown session,
/// service connection) and closes it again, so a replug only needs `rebind`.
#[allow(async_fn_in_trait)]
pub trait DeviceConn: 'static {
    /// The phone came back with a new usbmuxd id.
    fn rebind(&mut self, dev: &AttachedDevice);

    /// Lockdown values. Before Trust some may be withheld.
    async fn info(&mut self) -> Result<DeviceInfo, PairError>;

    /// Lockdown pair; waits while the Trust dialog is up. Uses an existing
    /// usbmuxd record when the phone still accepts it.
    async fn trust(&mut self, host: &HostIdentity) -> Result<TrustResult, PairError>;

    /// Gives the connection a lockdown record to use for sessions (from the cache).
    fn set_lockdown(&mut self, lockdown: &[u8]) -> Result<(), PairError>;

    /// DeveloperModeStatus in `com.apple.security.mac.amfi`.
    async fn dev_mode_status(&mut self) -> Result<bool, PairError>;

    /// AMFI action 0: show the hidden toggle in Settings.
    async fn reveal_dev_mode(&mut self) -> Result<(), PairError>;

    /// AMFI action 2 after the reboot. Best effort; the phone shows its own
    /// prompt after unlock anyway.
    async fn accept_dev_mode(&mut self) -> Result<(), PairError>;

    /// `EnableWifiDebugging` in `com.apple.mobile.wireless_lockdown`.
    async fn enable_wifi_debugging(&mut self) -> Result<(), PairError>;

    /// RemotePairing record via `remotepairingdeviced.lockdown`, falling back
    /// to the CoreDeviceProxy tunnel. `cached` is tried first (pair-verify).
    async fn generate_rp(&mut self, host: &HostIdentity, cached: Option<&[u8]>) -> Result<(Vec<u8>, RpVia), PairError>;

    async fn list_apps(&mut self) -> Result<AppList, PairError>;

    /// house_arrest (`vend_container`, then `vend_documents`) + AFC write of
    /// the drop file, atomically, with read-back.
    async fn write_dropbox(&mut self, bundle_id: &str, bytes: &[u8]) -> Result<WriteVia, PairError>;

    /// RP pair-verify with the record just written.
    async fn verify_rp(&mut self, host: &HostIdentity, rp: &[u8]) -> Result<(), PairError>;

    /// iOS 16 / 17.0–17.3: start a lockdown session with the record.
    async fn verify_lockdown(&mut self, lockdown: &[u8]) -> Result<(), PairError>;
}
