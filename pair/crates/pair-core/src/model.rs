//! Types shared by the state machine, the backends and the UI.

use serde::{Deserialize, Serialize};

use crate::version::IosVersion;

/// A device as usbmuxd reports it. Only USB devices ever become one of these.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachedDevice {
    pub udid: String,
    /// usbmuxd's id for this attachment; changes on every replug or reboot.
    pub mux_id: u32,
}

/// What the tool shows about a device.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceInfo {
    pub udid: String,
    /// The name set on the phone ("林晓的 iPhone"). Before Trust lockdownd may
    /// withhold it, so it can be a placeholder until the device is paired.
    pub name: String,
    /// Marketing model name ("iPhone 15 Pro") or the raw ProductType.
    pub model: String,
    pub product_type: String,
    /// ProductVersion as the phone reports it ("18.6.2").
    pub ios: String,
}

impl DeviceInfo {
    pub fn version(&self) -> Option<IosVersion> {
        IosVersion::parse(&self.ios)
    }
}

/// Which pairing record a device gets, by iOS version.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RecordKind {
    /// iOS 17.4+: RemotePairing keys merged with the lockdown record.
    RemotePairing,
    /// iOS 16 and 17.0–17.3: the lockdown record alone.
    Lockdown,
}

/// How the RemotePairing half was produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RpVia {
    /// `com.apple.dt.remotepairingdeviced.lockdown` over the trusted lockdown connection.
    LockdownService,
    /// CoreDeviceProxy software tunnel → untrusted tunnel service (fallback).
    CoreDeviceProxy,
    /// A cached record the device still accepted.
    Cached,
}

/// Which house_arrest command opened the container.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WriteVia {
    VendContainer,
    VendDocuments,
}

/// LoopCtrl as found on the device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppMatch {
    pub bundle_id: String,
    pub name: String,
    pub version: Option<String>,
    /// How it was recognised.
    pub matched_by: MatchedBy,
    /// `UIFileSharingEnabled`, needed when only `vend_documents` works.
    pub file_sharing: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MatchedBy {
    /// The Info.plist marker key (`LoopCtrlPairingDropbox`). Strongest.
    Marker,
    /// Bundle ID ends with `.loopctrl`.
    BundleSuffix,
    /// CFBundleDisplayName / CFBundleName is "LoopCtrl".
    DisplayName,
}

/// Outcome of the Trust step.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrustOutcome {
    /// usbmuxd already had a record the device accepts.
    AlreadyTrusted,
    /// The user tapped Trust just now.
    Paired,
    /// The phone is locked; ask the user to unlock it and try again.
    Locked,
}

/// Environment check result.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvReport {
    /// "windows", "macos", "android" or "linux".
    pub os: String,
    pub os_version: String,
    /// usbmuxd (macOS/Linux) or Apple Mobile Device Service (Windows) answers.
    pub usbmux_ok: bool,
    /// Where we looked ("/var/run/usbmuxd", "127.0.0.1:27015").
    pub usbmux_addr: String,
    pub detail: Option<String>,
}

/// Every failure the UI knows how to explain.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ErrorCode {
    /// Windows: Apple Mobile Device Service not reachable (Apple Devices missing).
    NoDriver,
    /// macOS/Linux: usbmuxd not reachable.
    NoUsbmux,
    /// The user tapped "Don't Trust".
    Untrusted,
    /// Developer Mode prompt after the reboot was dismissed or cancelled.
    DevModeCancelled,
    /// The phone did not come back within the reboot timeout.
    RebootTimeout,
    /// iOS older than 16.
    Unsupported,
    /// Neither RemotePairing path produced a record.
    RecordFailed,
    /// LoopCtrl is not installed.
    AppNotFound,
    /// house_arrest refused both vend commands, or AFC failed.
    WriteFailed,
    /// The phone did not accept the record we just wrote.
    VerifyFailed,
    /// Unplugged in the middle of a step.
    Disconnected,
    /// Anything else.
    Internal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairError {
    pub code: ErrorCode,
    /// Technical detail for the log and the "details" line; never the main message.
    pub detail: String,
}

impl PairError {
    pub fn new(code: ErrorCode, detail: impl Into<String>) -> Self {
        Self { code, detail: detail.into() }
    }
    pub fn internal(detail: impl Into<String>) -> Self {
        Self::new(ErrorCode::Internal, detail)
    }
}

impl std::fmt::Display for PairError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.code, self.detail)
    }
}

impl std::error::Error for PairError {}

/// Commands the user (or the batch auto-start) sends to one device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UserCommand {
    /// Leave the "device recognised" screen and start (single mode).
    Begin,
    /// Retry the step that failed (or keep waiting, after a reboot timeout).
    Retry,
    /// Start over from the Developer Mode check.
    Recheck,
    /// Give up on this device; it goes back to `Detected`.
    Cancel,
}
