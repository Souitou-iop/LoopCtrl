//! One-shot operations outside the state machine, for the headless CLI
//! (`loopctrl-pair devices | write | verify`). They work on any [`Backend`],
//! so the mock backend exercises the same code.
//!
//! The full flow (`loopctrl-pair pair`) does not live here: it runs the
//! [`ManagerHandle`](crate::ManagerHandle) exactly like the apps do.

use std::time::Duration;

use serde::Serialize;
use tokio::sync::mpsc;

use crate::app_match::find_loopctrl;
use crate::backend::{Backend, DeviceConn, WatchEvent};
use crate::cache::HostIdentity;
use crate::model::*;
use crate::record;

/// A phone on USB, as `loopctrl-pair devices` lists it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceSummary {
    pub udid: String,
    pub mux_id: u32,
    pub info: Option<DeviceInfo>,
    /// Why `info` is missing.
    pub error: Option<PairError>,
    /// Which record this phone needs, by its iOS version.
    pub record_kind: Option<RecordKind>,
    pub supported: Option<bool>,
}

/// Phones attached now. Waits `settle` for usbmuxd to report them.
pub async fn attached<B: Backend>(backend: &B, settle: Duration) -> Result<Vec<AttachedDevice>, PairError> {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let watch = backend.watch(tx);
    tokio::pin!(watch);
    let mut out: Vec<AttachedDevice> = Vec::new();
    let deadline = tokio::time::sleep(settle);
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            r = &mut watch => {
                // The watcher ended before the deadline: usbmuxd is gone.
                r?;
                break;
            }
            Some(ev) = rx.recv() => match ev {
                WatchEvent::Attached(d) => {
                    out.retain(|x| x.udid != d.udid);
                    out.push(d);
                }
                WatchEvent::Detached { mux_id } => out.retain(|x| x.mux_id != mux_id),
            },
            _ = &mut deadline => break,
        }
    }
    Ok(out)
}

/// Every phone with what lockdown tells about it.
pub async fn list<B: Backend>(backend: &B, settle: Duration) -> Result<Vec<DeviceSummary>, PairError> {
    let mut out = Vec::new();
    for dev in attached(backend, settle).await? {
        let mut conn = backend.open(&dev);
        let (info, error) = match conn.info().await {
            Ok(i) => (Some(i), None),
            Err(e) => (None, Some(e)),
        };
        let version = info.as_ref().and_then(DeviceInfo::version);
        out.push(DeviceSummary {
            udid: dev.udid,
            mux_id: dev.mux_id,
            record_kind: version.map(|v| v.record_kind()),
            supported: version.map(|v| v.is_supported()),
            info,
            error,
        });
    }
    Ok(out)
}

/// The one phone to act on: `udid` if given, otherwise the only one attached.
pub async fn pick<B: Backend>(backend: &B, udid: Option<&str>, settle: Duration) -> Result<AttachedDevice, PairError> {
    let all = attached(backend, settle).await?;
    match udid {
        Some(u) => all
            .into_iter()
            .find(|d| d.udid.eq_ignore_ascii_case(u))
            .ok_or_else(|| PairError::new(ErrorCode::Disconnected, format!("{u} is not connected over USB"))),
        None => match all.len() {
            0 => Err(PairError::new(ErrorCode::Disconnected, "no iPhone connected over USB")),
            1 => Ok(all.into_iter().next().unwrap()),
            n => Err(PairError::internal(format!("{n} iPhones connected; choose one with --udid"))),
        },
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteReport {
    pub udid: String,
    pub app: AppMatch,
    pub write_via: WriteVia,
}

/// Writes a pairing file into LoopCtrl on the phone (with read-back), using
/// the file's own lockdown record to open the sessions.
pub async fn write<B: Backend>(backend: &B, dev: &AttachedDevice, file: &[u8]) -> Result<WriteReport, PairError> {
    let summary = record::inspect(file)?;
    if let Some(u) = &summary.udid {
        if !u.eq_ignore_ascii_case(&dev.udid) {
            return Err(PairError::new(ErrorCode::WriteFailed, format!("this file is for {u}, not {}", dev.udid)));
        }
    }
    let mut conn = backend.open(dev);
    conn.set_lockdown(&record::lockdown_part(file)?)?;
    let apps = conn.list_apps().await?;
    let app =
        find_loopctrl(&apps).ok_or_else(|| PairError::new(ErrorCode::AppNotFound, "LoopCtrl is not installed"))?;
    let write_via = conn.write_dropbox(&app.bundle_id, file).await?;
    Ok(WriteReport { udid: dev.udid.clone(), app, write_via })
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VerifyReport {
    pub udid: String,
    pub record_kind: RecordKind,
    pub ios: String,
}

/// Checks that the phone accepts a pairing file: RP pair-verify on 17.4+,
/// a lockdown session on iOS 16 and 17.0–17.3.
pub async fn verify<B: Backend>(
    backend: &B,
    dev: &AttachedDevice,
    host: &HostIdentity,
    file: &[u8],
) -> Result<VerifyReport, PairError> {
    let lockdown = record::lockdown_part(file)?;
    let mut conn = backend.open(dev);
    conn.set_lockdown(&lockdown)?;
    let info = conn.info().await?;
    let kind = info.version().map(|v| v.record_kind()).unwrap_or(RecordKind::Lockdown);
    match kind {
        RecordKind::RemotePairing => {
            let rp = record::rp_part(file)?
                .ok_or_else(|| PairError::new(ErrorCode::VerifyFailed, "the file has no RemotePairing keys"))?;
            conn.verify_rp(host, &rp).await?;
        }
        RecordKind::Lockdown => conn.verify_lockdown(&lockdown).await?,
    }
    Ok(VerifyReport { udid: dev.udid.clone(), record_kind: kind, ios: info.ios })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::mock::{MockBackend, PhoneAction, Scenario};
    use crate::record::tests::sample_lockdown;
    use crate::record::{build, RecordMeta};

    fn file_for(udid: &str, rp: bool) -> Vec<u8> {
        let meta = RecordMeta {
            kind: if rp { RecordKind::RemotePairing } else { RecordKind::Lockdown },
            udid: udid.into(),
            host_name: "LoopCtrl-Pair-TEST01".into(),
            ios: "18.6.2".into(),
            rp_via: rp.then_some(RpVia::LockdownService),
            tool_version: "test".into(),
        };
        // A real RP record, so the mock's pair-verify can parse it.
        let rp_bytes = rp.then(|| idevice::remote_pairing::RpPairingFile::generate("LoopCtrl-Pair-TEST01").to_bytes());
        build(&sample_lockdown(), rp_bytes.as_deref(), &meta).unwrap()
    }

    fn host() -> HostIdentity {
        HostIdentity { host_name: "LoopCtrl-Pair-TEST01".into() }
    }

    #[tokio::test]
    async fn lists_writes_and_verifies_on_the_mock() {
        let m = MockBackend::new().with_speed(0.0);
        let udid = m.plug(Scenario::Ready);
        m.phone(&udid, PhoneAction::Trust);
        let list = list(&m, Duration::from_millis(50)).await.unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].record_kind, Some(RecordKind::RemotePairing));
        assert_eq!(list[0].supported, Some(true));

        let dev = pick(&m, None, Duration::from_millis(50)).await.unwrap();
        let file = file_for(&udid, true);
        let w = write(&m, &dev, &file).await.unwrap();
        assert_eq!(w.app.bundle_id, "com.customer.loopctrl");
        let v = verify(&m, &dev, &host(), &file).await.unwrap();
        assert_eq!(v.record_kind, RecordKind::RemotePairing);

        // A lockdown-only file is not enough for an 18.x phone.
        let e = verify(&m, &dev, &host(), &file_for(&udid, false)).await.unwrap_err();
        assert_eq!(e.code, ErrorCode::VerifyFailed);
    }

    #[tokio::test]
    async fn refuses_a_file_for_another_phone_and_missing_app() {
        let m = MockBackend::new().with_speed(0.0);
        let udid = m.plug(Scenario::NoApp);
        let dev = pick(&m, Some(&udid), Duration::from_millis(50)).await.unwrap();
        let e = write(&m, &dev, &file_for("00008000-OTHER", true)).await.unwrap_err();
        assert_eq!(e.code, ErrorCode::WriteFailed);
        let e = write(&m, &dev, &file_for(&udid, true)).await.unwrap_err();
        assert_eq!(e.code, ErrorCode::AppNotFound);
    }

    #[tokio::test]
    async fn pick_needs_a_choice_with_several_phones() {
        let m = MockBackend::new().with_speed(0.0);
        assert_eq!(pick(&m, None, Duration::from_millis(20)).await.unwrap_err().code, ErrorCode::Disconnected);
        m.plug(Scenario::Ready);
        m.plug(Scenario::Legacy16);
        assert_eq!(pick(&m, None, Duration::from_millis(20)).await.unwrap_err().code, ErrorCode::Internal);
        assert!(pick(&m, Some("nope"), Duration::from_millis(20)).await.is_err());
    }
}
