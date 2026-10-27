//! iOS version parsing and the record-kind decision.

use std::fmt;

use crate::model::RecordKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct IosVersion {
    pub major: u16,
    pub minor: u16,
    pub patch: u16,
}

impl IosVersion {
    pub const fn new(major: u16, minor: u16, patch: u16) -> Self {
        Self { major, minor, patch }
    }

    /// Parses "18", "17.4" or "16.7.10". Anything else is `None`.
    pub fn parse(s: &str) -> Option<Self> {
        let mut parts = s.trim().split('.');
        let major = parts.next()?.parse().ok()?;
        let minor = parts.next().map(str::parse).transpose().ok()?.unwrap_or(0);
        let patch = parts.next().map(str::parse).transpose().ok()?.unwrap_or(0);
        if parts.next().is_some() {
            return None;
        }
        Some(Self { major, minor, patch })
    }

    /// Lowest version LoopCtrl supports at all.
    pub const MIN_SUPPORTED: Self = Self::new(16, 0, 0);
    /// First version with `com.apple.dt.remotepairingdeviced.lockdown` /
    /// CoreDeviceProxy over plain USB lockdown.
    pub const MIN_REMOTE_PAIRING: Self = Self::new(17, 4, 0);

    pub fn is_supported(self) -> bool {
        self >= Self::MIN_SUPPORTED
    }

    /// iOS 17.4+ gets an RP record (with the lockdown record merged in);
    /// iOS 16 and 17.0–17.3 get the lockdown record only.
    pub fn record_kind(self) -> RecordKind {
        if self >= Self::MIN_REMOTE_PAIRING {
            RecordKind::RemotePairing
        } else {
            RecordKind::Lockdown
        }
    }
}

impl fmt::Display for IosVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.patch == 0 {
            write!(f, "{}.{}", self.major, self.minor)
        } else {
            write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_forms() {
        assert_eq!(IosVersion::parse("18"), Some(IosVersion::new(18, 0, 0)));
        assert_eq!(IosVersion::parse("17.4"), Some(IosVersion::new(17, 4, 0)));
        assert_eq!(IosVersion::parse("16.7.10"), Some(IosVersion::new(16, 7, 10)));
        assert_eq!(IosVersion::parse(" 26.0.1 "), Some(IosVersion::new(26, 0, 1)));
        assert_eq!(IosVersion::parse("abc"), None);
        assert_eq!(IosVersion::parse("1.2.3.4"), None);
        assert_eq!(IosVersion::parse("17.x"), None);
    }

    #[test]
    fn record_kind_boundaries() {
        let k = |s| IosVersion::parse(s).unwrap().record_kind();
        assert_eq!(k("16.7.10"), RecordKind::Lockdown);
        assert_eq!(k("17.0"), RecordKind::Lockdown);
        assert_eq!(k("17.3.1"), RecordKind::Lockdown);
        assert_eq!(k("17.4"), RecordKind::RemotePairing);
        assert_eq!(k("18.6.2"), RecordKind::RemotePairing);
        assert_eq!(k("26.0.1"), RecordKind::RemotePairing);
    }

    #[test]
    fn support_floor() {
        assert!(!IosVersion::parse("15.8").unwrap().is_supported());
        assert!(IosVersion::parse("16.0").unwrap().is_supported());
    }

    #[test]
    fn display() {
        assert_eq!(IosVersion::new(17, 4, 0).to_string(), "17.4");
        assert_eq!(IosVersion::new(16, 7, 10).to_string(), "16.7.10");
    }
}
