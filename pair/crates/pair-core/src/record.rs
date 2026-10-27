//! The pairing file handed to LoopCtrl (see docs/handoff.md).
//!
//! One XML plist. Its top level is what LoopCtrl's `PairingFileStore` and
//! idevice already parse:
//! * lockdown keys (`HostID`, `SystemBUID`, `HostCertificate`, … , `UDID`), always;
//! * RemotePairing keys (`public_key`, `private_key`, `identifier`, optional
//!   `alt_irk`) on iOS 17.4+;
//! * a `LoopCtrlPair` dictionary with metadata, which both parsers ignore.

use std::time::SystemTime;

use plist::{Dictionary, Value};

use crate::model::{ErrorCode, PairError, RecordKind, RpVia};

/// Bumped only for changes an older LoopCtrl would misread.
pub const FORMAT_VERSION: u64 = 1;
/// Key of the metadata dictionary.
pub const META_KEY: &str = "LoopCtrlPair";
/// Drop location inside the app container (relative to the container root).
pub const DROPBOX_DIR: &str = "Documents/.pairing-dropbox";
pub const DROPBOX_FILE: &str = "pairingFile.plist";
/// Written first, then renamed, so the app never sees a half-written file.
pub const DROPBOX_TEMP_FILE: &str = "pairingFile.plist.partial";

/// Keys idevice's `PairingFile` requires (LoopCtrl checks the same list).
pub const LOCKDOWN_KEYS: [&str; 8] = [
    "DeviceCertificate",
    "HostCertificate",
    "HostPrivateKey",
    "RootCertificate",
    "RootPrivateKey",
    "SystemBUID",
    "HostID",
    "WiFiMACAddress",
];
const RP_KEYS: [&str; 4] = ["public_key", "private_key", "identifier", "alt_irk"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordMeta {
    pub kind: RecordKind,
    pub udid: String,
    pub host_name: String,
    pub ios: String,
    pub rp_via: Option<RpVia>,
    pub tool_version: String,
}

/// What a pairing file contains, as far as LoopCtrl cares.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordSummary {
    pub has_lockdown: bool,
    pub has_rp: bool,
    pub format_version: Option<u64>,
    pub udid: Option<String>,
}

impl RecordSummary {
    /// The rule LoopCtrl applies at import: RP keys on 17+, lockdown keys on 16.
    pub fn usable_for(&self, kind: RecordKind) -> bool {
        match kind {
            RecordKind::RemotePairing => self.has_rp,
            RecordKind::Lockdown => self.has_lockdown,
        }
    }
}

fn bad(detail: impl Into<String>) -> PairError {
    PairError::new(ErrorCode::RecordFailed, detail)
}

fn parse_dict(bytes: &[u8], what: &str) -> Result<Dictionary, PairError> {
    plist::from_bytes::<Dictionary>(bytes).map_err(|e| bad(format!("{what} is not a plist dictionary: {e}")))
}

fn to_xml(dict: &Dictionary) -> Result<Vec<u8>, PairError> {
    let mut out = Vec::new();
    plist::to_writer_xml(&mut out, &Value::Dictionary(dict.clone()))
        .map_err(|e| PairError::internal(format!("plist serialize: {e}")))?;
    Ok(out)
}

fn has_lockdown_keys(d: &Dictionary) -> bool {
    LOCKDOWN_KEYS.iter().all(|k| d.contains_key(k))
}

fn has_rp_keys(d: &Dictionary) -> bool {
    let key32 = |k: &str| d.get(k).and_then(Value::as_data).is_some_and(|b| b.len() == 32);
    key32("public_key") && key32("private_key") && d.get("identifier").and_then(Value::as_string).is_some()
}

/// Apple's XML plist parser (`PropertyListSerialization`, `plutil`) rejects
/// `<date>` values with fractional seconds, which the plist crate writes.
fn whole_seconds(t: SystemTime) -> SystemTime {
    let secs = t.duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs)
}

/// Builds the file LoopCtrl imports, from the lockdown record and (17.4+) the
/// RP record, both as plist bytes in idevice's own serialization.
pub fn build(lockdown: &[u8], rp: Option<&[u8]>, meta: &RecordMeta) -> Result<Vec<u8>, PairError> {
    let mut out = parse_dict(lockdown, "lockdown record")?;
    if !has_lockdown_keys(&out) {
        let missing: Vec<_> = LOCKDOWN_KEYS.iter().filter(|k| !out.contains_key(k)).collect();
        return Err(bad(format!("lockdown record misses {missing:?}")));
    }
    // jitterbug convention: the record names its device.
    out.insert("UDID".into(), Value::String(meta.udid.clone()));

    match (meta.kind, rp) {
        (RecordKind::RemotePairing, Some(rp)) => {
            let rp = parse_dict(rp, "RemotePairing record")?;
            if !has_rp_keys(&rp) {
                return Err(bad("RemotePairing record lacks 32-byte keys or identifier"));
            }
            for k in RP_KEYS {
                if let Some(v) = rp.get(k) {
                    out.insert(k.into(), v.clone());
                }
            }
        }
        (RecordKind::RemotePairing, None) => return Err(bad("iOS 17.4+ needs a RemotePairing record")),
        (RecordKind::Lockdown, _) => {}
    }

    let mut m = Dictionary::new();
    m.insert("FormatVersion".into(), Value::Integer(FORMAT_VERSION.into()));
    m.insert(
        "Kind".into(),
        Value::String(
            match meta.kind {
                RecordKind::RemotePairing => "remotePairing+lockdown",
                RecordKind::Lockdown => "lockdown",
            }
            .into(),
        ),
    );
    m.insert("HostName".into(), Value::String(meta.host_name.clone()));
    m.insert("ProductVersion".into(), Value::String(meta.ios.clone()));
    if let Some(via) = meta.rp_via {
        let via = match via {
            RpVia::LockdownService => "remotepairingdeviced.lockdown",
            RpVia::CoreDeviceProxy => "coreDeviceProxy",
            RpVia::Cached => "cached",
        };
        m.insert("RemotePairingVia".into(), Value::String(via.into()));
    }
    m.insert("CreatedAt".into(), Value::Date(whole_seconds(SystemTime::now()).into()));
    m.insert("Tool".into(), Value::String(format!("LoopCtrl Pair {}", meta.tool_version)));
    out.insert(META_KEY.into(), Value::Dictionary(m));

    to_xml(&out)
}

/// Reads back what a pairing file holds.
pub fn inspect(bytes: &[u8]) -> Result<RecordSummary, PairError> {
    let d = parse_dict(bytes, "pairing file")?;
    let format_version = d
        .get(META_KEY)
        .and_then(Value::as_dictionary)
        .and_then(|m| m.get("FormatVersion"))
        .and_then(Value::as_unsigned_integer);
    Ok(RecordSummary {
        has_lockdown: has_lockdown_keys(&d),
        has_rp: has_rp_keys(&d),
        format_version,
        udid: d.get("UDID").and_then(Value::as_string).map(str::to_owned),
    })
}

/// The lockdown half alone, for `PairingFile::from_bytes`.
pub fn lockdown_part(bytes: &[u8]) -> Result<Vec<u8>, PairError> {
    let d = parse_dict(bytes, "pairing file")?;
    let mut out = Dictionary::new();
    for k in LOCKDOWN_KEYS.iter().copied().chain(["EscrowBag", "UDID"]) {
        if let Some(v) = d.get(k) {
            out.insert(k.into(), v.clone());
        }
    }
    if !has_lockdown_keys(&out) {
        return Err(bad("no lockdown record in pairing file"));
    }
    to_xml(&out)
}

/// The RP half alone, for `RpPairingFile::from_bytes`.
pub fn rp_part(bytes: &[u8]) -> Result<Option<Vec<u8>>, PairError> {
    let d = parse_dict(bytes, "pairing file")?;
    if !has_rp_keys(&d) {
        return Ok(None);
    }
    let mut out = Dictionary::new();
    for k in RP_KEYS {
        if let Some(v) = d.get(k) {
            out.insert(k.into(), v.clone());
        }
    }
    to_xml(&out).map(Some)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A syntactically complete lockdown record with dummy bytes. idevice's
    /// parser would reject the certificates; the format code does not care.
    pub fn sample_lockdown() -> Vec<u8> {
        let mut d = Dictionary::new();
        for k in ["DeviceCertificate", "HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey"] {
            d.insert(k.into(), Value::Data(b"-----BEGIN-----".to_vec()));
        }
        d.insert("SystemBUID".into(), Value::String("BUID-1".into()));
        d.insert("HostID".into(), Value::String("HOST-1".into()));
        d.insert("WiFiMACAddress".into(), Value::String("aa:bb:cc:dd:ee:ff".into()));
        d.insert("EscrowBag".into(), Value::Data(vec![1, 2, 3]));
        to_xml(&d).unwrap()
    }

    pub fn sample_rp() -> Vec<u8> {
        let mut d = Dictionary::new();
        d.insert("public_key".into(), Value::Data(vec![7; 32]));
        d.insert("private_key".into(), Value::Data(vec![9; 32]));
        d.insert("identifier".into(), Value::String("2E9C…".into()));
        to_xml(&d).unwrap()
    }

    fn meta(kind: RecordKind) -> RecordMeta {
        RecordMeta {
            kind,
            udid: "00008110-000A".into(),
            host_name: "LoopCtrl-Pair-ABC123".into(),
            ios: "18.6.2".into(),
            rp_via: (kind == RecordKind::RemotePairing).then_some(RpVia::LockdownService),
            tool_version: "0.1.0".into(),
        }
    }

    #[test]
    fn dates_have_no_fractional_seconds() {
        let out = build(&sample_lockdown(), Some(&sample_rp()), &meta(RecordKind::RemotePairing)).unwrap();
        let text = String::from_utf8(out.clone()).unwrap();
        let date = text.split("<date>").nth(1).unwrap().split("</date>").next().unwrap();
        assert!(!date.contains('.'), "{date}");
        // The parser LoopCtrl uses must accept the file.
        #[cfg(target_os = "macos")]
        {
            let dir = tempfile::tempdir().unwrap();
            let f = dir.path().join("pairingFile.plist");
            std::fs::write(&f, &out).unwrap();
            let lint = std::process::Command::new("plutil").arg("-lint").arg(&f).output().unwrap();
            assert!(lint.status.success(), "{}", String::from_utf8_lossy(&lint.stdout));
        }
    }

    #[test]
    fn merged_file_has_both_halves_and_meta() {
        let out = build(&sample_lockdown(), Some(&sample_rp()), &meta(RecordKind::RemotePairing)).unwrap();
        let s = inspect(&out).unwrap();
        assert!(s.has_lockdown && s.has_rp);
        assert_eq!(s.format_version, Some(FORMAT_VERSION));
        assert_eq!(s.udid.as_deref(), Some("00008110-000A"));
        assert!(s.usable_for(RecordKind::RemotePairing) && s.usable_for(RecordKind::Lockdown));
        let text = String::from_utf8(out).unwrap();
        assert!(text.starts_with("<?xml"), "LoopCtrl expects an XML plist");
        assert!(text.contains("remotepairingdeviced.lockdown"));
    }

    #[test]
    fn lockdown_only_file_for_ios16() {
        let mut m = meta(RecordKind::Lockdown);
        m.ios = "16.7.10".into();
        let out = build(&sample_lockdown(), None, &m).unwrap();
        let s = inspect(&out).unwrap();
        assert!(s.has_lockdown && !s.has_rp);
        assert!(s.usable_for(RecordKind::Lockdown));
        assert!(!s.usable_for(RecordKind::RemotePairing));
    }

    #[test]
    fn lockdown_kind_ignores_stray_rp() {
        let out = build(&sample_lockdown(), Some(&sample_rp()), &meta(RecordKind::Lockdown)).unwrap();
        assert!(!inspect(&out).unwrap().has_rp);
    }

    #[test]
    fn rp_kind_requires_rp() {
        let e = build(&sample_lockdown(), None, &meta(RecordKind::RemotePairing)).unwrap_err();
        assert_eq!(e.code, ErrorCode::RecordFailed);
    }

    #[test]
    fn rejects_incomplete_inputs() {
        let mut d = Dictionary::new();
        d.insert("HostID".into(), Value::String("x".into()));
        let partial = to_xml(&d).unwrap();
        assert!(build(&partial, None, &meta(RecordKind::Lockdown)).is_err());

        let mut short = Dictionary::new();
        short.insert("public_key".into(), Value::Data(vec![1; 31]));
        short.insert("private_key".into(), Value::Data(vec![1; 32]));
        short.insert("identifier".into(), Value::String("i".into()));
        let short = to_xml(&short).unwrap();
        assert!(build(&sample_lockdown(), Some(&short), &meta(RecordKind::RemotePairing)).is_err());
        assert!(build(b"not a plist", None, &meta(RecordKind::Lockdown)).is_err());
    }

    #[test]
    fn halves_round_trip() {
        let out = build(&sample_lockdown(), Some(&sample_rp()), &meta(RecordKind::RemotePairing)).unwrap();
        let ld = inspect(&lockdown_part(&out).unwrap()).unwrap();
        assert!(ld.has_lockdown && !ld.has_rp && ld.udid.is_some());
        let rp = rp_part(&out).unwrap().unwrap();
        let rp_s = inspect(&rp).unwrap();
        assert!(rp_s.has_rp && !rp_s.has_lockdown);
        let lockdown_only = build(&sample_lockdown(), None, &meta(RecordKind::Lockdown)).unwrap();
        assert!(rp_part(&lockdown_only).unwrap().is_none());
    }

    #[test]
    fn idevice_parses_rp_half() {
        let gen = idevice::remote_pairing::RpPairingFile::generate("LoopCtrl-Pair-TEST");
        let out = build(&sample_lockdown(), Some(&gen.to_bytes()), &meta(RecordKind::RemotePairing)).unwrap();
        // idevice must load the merged file directly, extra keys and all.
        let back = idevice::remote_pairing::RpPairingFile::from_bytes(&out).unwrap();
        assert_eq!(back.identifier, gen.identifier);
        assert_eq!(back.public_key_bytes(), gen.public_key_bytes());
    }
}
