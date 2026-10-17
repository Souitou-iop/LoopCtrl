//! End-to-end runs of the manager against the mock backend (no delays).

use std::sync::mpsc::{channel, Receiver};
use std::time::{Duration, Instant};

use pair_core::*;

struct Rig {
    mock: MockBackend,
    events: Receiver<Event>,
    handle: ManagerHandle,
    _dir: tempfile::TempDir,
    cache: std::path::PathBuf,
    latest: std::cell::RefCell<std::collections::HashMap<String, DeviceView>>,
}

fn rig(auto_begin: bool) -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let mock = MockBackend::new().with_speed(0.0);
    let (tx, events) = channel();
    let mut cfg = Config::new(dir.path());
    cfg.auto_begin = auto_begin;
    cfg.reboot_timeout = Duration::from_millis(300);
    cfg.confirm_timeout = Duration::from_millis(300);
    cfg.trust_retry = Duration::from_millis(10);
    let handle = ManagerHandle::start(mock.clone(), cfg, move |e| {
        let _ = tx.send(e);
    });
    let cache = dir.path().to_path_buf();
    Rig { mock, events, handle, _dir: dir, cache, latest: Default::default() }
}

impl Rig {
    /// Waits until the latest view of `udid` satisfies `pred`.
    fn wait(&self, udid: &str, pred: impl Fn(&DeviceView) -> bool) -> DeviceView {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(v) = self.latest.borrow().get(udid).filter(|v| pred(v)) {
                return v.clone();
            }
            let left = deadline.saturating_duration_since(Instant::now());
            match self.events.recv_timeout(left) {
                Ok(Event::Device { device }) => {
                    let hit = device.udid == udid && pred(&device);
                    let v = (*device).clone();
                    self.latest.borrow_mut().insert(device.udid.clone(), *device);
                    if hit {
                        return v;
                    }
                }
                Ok(_) => {}
                Err(_) => panic!("timed out waiting for {udid}: last {:?}", self.latest.borrow().get(udid).map(|v| v.phase)),
            }
        }
    }
    fn phase(&self, udid: &str, p: Phase) -> DeviceView {
        self.wait(udid, |v| v.phase == p)
    }
}

#[test]
fn ready_phone_single_mode() {
    let r = rig(false);
    let udid = r.mock.plug(Scenario::Ready);
    let v = r.wait(&udid, |v| v.info.is_some());
    assert_eq!(v.phase, Phase::Detected);
    r.handle.command(&udid, UserCommand::Begin);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::Trust);
    let done = r.phase(&udid, Phase::Done);
    assert_eq!(done.record_kind, Some(RecordKind::RemotePairing));
    assert_eq!(done.rp_via, Some(RpVia::LockdownService));
    assert_eq!(done.app.as_ref().unwrap().version.as_deref(), Some("1.4"));
    assert_eq!(done.info.as_ref().unwrap().name, "林晓的 iPhone", "real name after Trust");
    assert!(done.done_at.is_some());
    // Cached, merged, private.
    let file = std::fs::read(r.cache.join("devices").join(&udid).join("pairingFile.plist")).unwrap();
    let s = record::inspect(&file).unwrap();
    assert!(s.has_rp && s.has_lockdown);
    assert_eq!(s.format_version, Some(record::FORMAT_VERSION));
}

#[test]
fn second_run_reuses_cached_rp() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::Ready);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::Trust);
    r.phase(&udid, Phase::Done);
    // Unplug, forget, plug again: trusted already, RP from cache.
    r.mock.phone(&udid, PhoneAction::Unplug);
    r.wait(&udid, |v| !v.connected);
    r.handle.forget(&udid);
    // Forget and the next attach travel on different channels.
    std::thread::sleep(Duration::from_millis(200));
    r.mock.phone(&udid, PhoneAction::Plug);
    let v = r.wait(&udid, |v| v.phase == Phase::Done && v.order == 2);
    assert_eq!(v.rp_via, Some(RpVia::Cached));
}

#[test]
fn developer_mode_off_flow() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::DevModeOff);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::Trust);
    let g = r.phase(&udid, Phase::DevModeGuide);
    assert!(g.attention && g.dev_mode_was_off);
    r.mock.phone(&udid, PhoneAction::Restart);
    r.phase(&udid, Phase::ConfirmingDevMode);
    r.mock.phone(&udid, PhoneAction::TurnOn);
    let done = r.phase(&udid, Phase::Done);
    assert!(done.dev_mode_was_off);
}

#[test]
fn reboot_that_never_returns_times_out() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::RebootHangs);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::Trust);
    r.phase(&udid, Phase::DevModeGuide);
    r.mock.phone(&udid, PhoneAction::Restart);
    r.phase(&udid, Phase::Rebooting);
    let f = r.phase(&udid, Phase::Failed);
    assert_eq!(f.error.unwrap().code, ErrorCode::RebootTimeout);
}

#[test]
fn prompt_cancelled_times_out_as_dev_mode_cancelled() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::DevModeOff);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::Trust);
    r.phase(&udid, Phase::DevModeGuide);
    r.mock.phone(&udid, PhoneAction::Restart);
    r.phase(&udid, Phase::ConfirmingDevMode);
    r.mock.phone(&udid, PhoneAction::Cancel);
    let f = r.phase(&udid, Phase::Failed);
    assert_eq!(f.error.unwrap().code, ErrorCode::DevModeCancelled);
    r.handle.command(&udid, UserCommand::Retry);
    r.phase(&udid, Phase::CheckingDevMode);
}

#[test]
fn dont_trust_then_replug() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::Ready);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::DontTrust);
    let f = r.phase(&udid, Phase::Failed);
    assert_eq!(f.error.unwrap().code, ErrorCode::Untrusted);
    r.mock.phone(&udid, PhoneAction::Unplug);
    r.mock.phone(&udid, PhoneAction::Plug);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::Trust);
    r.phase(&udid, Phase::Done);
}

#[test]
fn locked_phone_waits_for_unlock() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::Locked);
    r.wait(&udid, |v| v.phase == Phase::Trusting && v.locked);
    r.mock.phone(&udid, PhoneAction::Unlock);
    r.mock.phone(&udid, PhoneAction::Trust);
    r.phase(&udid, Phase::Done);
}

#[test]
fn missing_app_then_install_and_retry() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::NoApp);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::Trust);
    let f = r.phase(&udid, Phase::Failed);
    assert_eq!(f.error.unwrap().code, ErrorCode::AppNotFound);
    r.mock.phone(&udid, PhoneAction::InstallApp);
    r.handle.command(&udid, UserCommand::Retry);
    r.phase(&udid, Phase::Done);
}

#[test]
fn legacy_versions_get_lockdown_records() {
    for s in [Scenario::Legacy16, Scenario::Early17] {
        let r = rig(true);
        let udid = r.mock.plug(s);
        r.phase(&udid, Phase::Trusting);
        r.mock.phone(&udid, PhoneAction::Trust);
        let done = r.phase(&udid, Phase::Done);
        assert_eq!(done.record_kind, Some(RecordKind::Lockdown));
        assert_eq!(done.rp_via, None);
        let file = std::fs::read(r.cache.join("devices").join(&udid).join("pairingFile.plist")).unwrap();
        let s = record::inspect(&file).unwrap();
        assert!(s.has_lockdown && !s.has_rp);
    }
}

#[test]
fn rp_service_missing_falls_back() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::NoRpService);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::Trust);
    assert_eq!(r.phase(&udid, Phase::Done).rp_via, Some(RpVia::CoreDeviceProxy));
}

#[test]
fn unsupported_ios() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::Unsupported);
    let f = r.phase(&udid, Phase::Failed);
    assert_eq!(f.error.unwrap().code, ErrorCode::Unsupported);
}

#[test]
fn unplug_mid_flow_and_resume() {
    let r = rig(true);
    let udid = r.mock.plug(Scenario::Ready);
    r.phase(&udid, Phase::Trusting);
    r.mock.phone(&udid, PhoneAction::Trust);
    r.phase(&udid, Phase::CheckingDevMode);
    r.mock.phone(&udid, PhoneAction::Unplug);
    let f = r.phase(&udid, Phase::Failed);
    assert_eq!(f.error.unwrap().code, ErrorCode::Disconnected);
    r.mock.phone(&udid, PhoneAction::Plug);
    r.phase(&udid, Phase::Done);
}

#[test]
fn batch_preset_runs_independently() {
    let r = rig(true);
    let udids = r.mock.plug_batch();
    assert_eq!(udids.len(), 5);
    // Phone 3 waits for a human; phone 5 lacks LoopCtrl; the others finish.
    for i in [0, 1, 3] {
        r.phase(&udids[i], Phase::Done);
    }
    r.phase(&udids[2], Phase::DevModeGuide);
    assert_eq!(r.phase(&udids[4], Phase::Failed).error.unwrap().code, ErrorCode::AppNotFound);
}
