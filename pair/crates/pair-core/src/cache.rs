//! Local cache: this computer's RemotePairing host name and, per UDID, the
//! records made for that phone. Nothing here is ever uploaded.
//!
//! Layout under the app-data folder:
//! ```text
//! host.json                         {"hostName": "LoopCtrl-Pair-3F9A1C"}
//! devices/<UDID>/lockdown.plist     lockdown record (also saved to usbmuxd)
//! devices/<UDID>/pairingFile.plist  the file handed to LoopCtrl
//! ```
//! Directories are 0700 and files 0600 on Unix. On Windows the folder sits in
//! the user's profile (%APPDATA%), which only that user can read by default.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use rand::Rng;
use serde::{Deserialize, Serialize};

use crate::model::PairError;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostIdentity {
    /// Sent to the phone as the RemotePairing host name; the RP identifier is
    /// derived from it, so it stays the same for this install.
    pub host_name: String,
}

#[derive(Debug, Clone)]
pub struct Cache {
    root: PathBuf,
}

fn io(e: std::io::Error, what: &Path) -> PairError {
    PairError::internal(format!("{}: {e}", what.display()))
}

/// UDIDs are hex and dashes; anything else must not reach a path.
fn safe_udid(udid: &str) -> Result<&str, PairError> {
    if !udid.is_empty() && udid.len() <= 64 && udid.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        Ok(udid)
    } else {
        Err(PairError::internal(format!("refusing odd UDID {udid:?}")))
    }
}

impl Cache {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn ensure_dir(path: &Path) -> Result<(), PairError> {
        fs::create_dir_all(path).map_err(|e| io(e, path))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|e| io(e, path))?;
        }
        Ok(())
    }

    /// Writes via a temporary file and rename; the file is 0600 before any
    /// byte of the secret lands in it.
    fn write_private(path: &Path, bytes: &[u8]) -> Result<(), PairError> {
        if let Some(dir) = path.parent() {
            Self::ensure_dir(dir)?;
        }
        let tmp = path.with_extension("tmp");
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp).map_err(|e| io(e, &tmp))?;
        f.write_all(bytes).map_err(|e| io(e, &tmp))?;
        f.sync_all().map_err(|e| io(e, &tmp))?;
        drop(f);
        fs::rename(&tmp, path).map_err(|e| io(e, path))
    }

    /// This install's host identity, created on first use.
    pub fn host_identity(&self) -> Result<HostIdentity, PairError> {
        let path = self.root.join("host.json");
        if let Ok(bytes) = fs::read(&path) {
            if let Ok(h) = serde_json::from_slice::<HostIdentity>(&bytes) {
                if !h.host_name.is_empty() {
                    return Ok(h);
                }
            }
        }
        let suffix: u32 = rand::thread_rng().gen_range(0..0x100_0000);
        let h = HostIdentity { host_name: format!("LoopCtrl-Pair-{suffix:06X}") };
        let json = serde_json::to_vec_pretty(&h).map_err(|e| PairError::internal(e.to_string()))?;
        Self::write_private(&path, &json)?;
        Ok(h)
    }

    fn device_dir(&self, udid: &str) -> Result<PathBuf, PairError> {
        Ok(self.root.join("devices").join(safe_udid(udid)?))
    }

    pub fn save_lockdown(&self, udid: &str, bytes: &[u8]) -> Result<(), PairError> {
        Self::write_private(&self.device_dir(udid)?.join("lockdown.plist"), bytes)
    }

    pub fn load_lockdown(&self, udid: &str) -> Option<Vec<u8>> {
        fs::read(self.device_dir(udid).ok()?.join("lockdown.plist")).ok()
    }

    pub fn save_pairing_file(&self, udid: &str, bytes: &[u8]) -> Result<PathBuf, PairError> {
        let path = self.device_dir(udid)?.join("pairingFile.plist");
        Self::write_private(&path, bytes)?;
        Ok(path)
    }

    pub fn load_pairing_file(&self, udid: &str) -> Option<Vec<u8>> {
        fs::read(self.device_dir(udid).ok()?.join("pairingFile.plist")).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_identity_is_stable() {
        let dir = tempfile::tempdir().unwrap();
        let c = Cache::new(dir.path());
        let a = c.host_identity().unwrap();
        let b = c.host_identity().unwrap();
        assert_eq!(a, b);
        assert!(a.host_name.starts_with("LoopCtrl-Pair-") && a.host_name.len() == 20);
    }

    #[test]
    fn records_round_trip_with_private_permissions() {
        let dir = tempfile::tempdir().unwrap();
        let c = Cache::new(dir.path());
        let p = c.save_pairing_file("00008110-000A1B2C", b"<plist/>").unwrap();
        c.save_lockdown("00008110-000A1B2C", b"ld").unwrap();
        assert_eq!(c.load_pairing_file("00008110-000A1B2C").unwrap(), b"<plist/>");
        assert_eq!(c.load_lockdown("00008110-000A1B2C").unwrap(), b"ld");
        assert!(c.load_pairing_file("other").is_none());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o600);
            let d = p.parent().unwrap();
            assert_eq!(fs::metadata(d).unwrap().permissions().mode() & 0o777, 0o700);
        }
        let _ = p;
    }

    #[test]
    fn rejects_path_like_udid() {
        let dir = tempfile::tempdir().unwrap();
        let c = Cache::new(dir.path());
        assert!(c.save_pairing_file("../evil", b"x").is_err());
        assert!(c.save_pairing_file("", b"x").is_err());
    }
}
