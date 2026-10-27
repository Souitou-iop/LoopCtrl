//! A scripted backend: fake iPhones that behave like real ones, for demos,
//! UI work and tests without hardware. Selected with `LOOPCTRL_PAIR_MOCK=1`
//! or the developer toggle in Settings.
//!
//! Each phone either acts on its own after a delay (batch demo) or waits for
//! the "phone side" to be driven through [`MockBackend::phone`] (single mode:
//! tap Trust, restart, tap Turn On…).

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::sync::mpsc::UnboundedSender;
use tokio::time::sleep;

use super::{AppList, Backend, DeviceConn, TrustResult, WatchEvent};
use crate::cache::HostIdentity;
use crate::model::*;

/// Things the person holding the phone can do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PhoneAction {
    /// Tap "Trust" and enter the passcode.
    Trust,
    /// Tap "Don't Trust".
    DontTrust,
    /// Unlock the phone (it was locked during Trust).
    Unlock,
    /// Settings › Developer Mode → on → Restart.
    Restart,
    /// Tap "Turn On" in the prompt after the reboot.
    TurnOn,
    /// Dismiss / cancel that prompt.
    Cancel,
    /// Install LoopCtrl.
    InstallApp,
    Unplug,
    Plug,
}

/// Ready-made phones.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Scenario {
    /// iOS 18.6.2, Developer Mode on, LoopCtrl installed.
    Ready,
    /// iOS 17.5.1, Developer Mode off.
    DevModeOff,
    /// iOS 26.0.1, `remotepairingdeviced.lockdown` missing → CoreDeviceProxy.
    NoRpService,
    /// iOS 16.7.10: lockdown record only.
    Legacy16,
    /// iOS 17.2: lockdown record only.
    Early17,
    /// LoopCtrl not installed.
    NoApp,
    /// Developer Mode off, and the phone never comes back from the reboot.
    RebootHangs,
    /// iOS 15.8.
    Unsupported,
    /// Locked when Trust starts.
    Locked,
}

#[derive(Debug, Clone)]
struct Phone {
    info: DeviceInfo,
    mux_id: Option<u32>,
    trusted: bool,
    locked: bool,
    dev_mode: bool,
    revealed: bool,
    /// Rebooted with the toggle on; the prompt is up until TurnOn/Cancel.
    prompt_pending: bool,
    app: Option<(String, String)>,
    rp_service: bool,
    reboot_returns: bool,
    /// Pending decision for the Trust dialog.
    trust_answer: Option<bool>,
    /// Automatic behaviour (batch demo). `None` = wait for [`PhoneAction`]s.
    auto: Option<AutoScript>,
}

/// Delays for a phone that acts on its own.
#[derive(Debug, Clone, Copy)]
struct AutoScript {
    trust_after: Duration,
    restart_after: Duration,
    turn_on_after: Duration,
}

struct World {
    phones: BTreeMap<String, Phone>,
    next_mux: u32,
    next_serial: u32,
    watchers: Vec<UnboundedSender<WatchEvent>>,
    driver_missing: bool,
    /// Scales every delay (tests use 0).
    speed: f32,
}

#[derive(Clone)]
pub struct MockBackend {
    world: Arc<Mutex<World>>,
}

impl Default for MockBackend {
    fn default() -> Self {
        Self::new()
    }
}

const NAMES: [(&str, &str, &str); 6] = [
    ("林晓的 iPhone", "iPhone 15 Pro", "iPhone16,1"),
    ("王磊的 iPhone", "iPhone 12", "iPhone13,2"),
    ("张敏的 iPhone", "iPhone 16", "iPhone17,3"),
    ("前台备用机", "iPhone XR", "iPhone11,8"),
    ("测试机 05", "iPhone 11", "iPhone12,1"),
    ("测试机 06", "iPhone 13 mini", "iPhone14,4"),
];

impl MockBackend {
    pub fn new() -> Self {
        Self {
            world: Arc::new(Mutex::new(World {
                phones: BTreeMap::new(),
                next_mux: 1,
                next_serial: 0,
                watchers: Vec::new(),
                driver_missing: false,
                speed: 1.0,
            })),
        }
    }

    /// All delays multiplied by `speed` (0 for tests).
    pub fn with_speed(self, speed: f32) -> Self {
        self.world.lock().unwrap().speed = speed;
        self
    }

    fn delay(&self, ms: u64) -> Duration {
        let s = self.world.lock().unwrap().speed;
        Duration::from_millis((ms as f32 * s) as u64)
    }

    fn broadcast(w: &mut World, ev: WatchEvent) {
        w.watchers.retain(|tx| tx.send(ev.clone()).is_ok());
    }

    fn attach(w: &mut World, udid: &str) {
        let mux = w.next_mux;
        w.next_mux += 1;
        if let Some(p) = w.phones.get_mut(udid) {
            p.mux_id = Some(mux);
        }
        Self::broadcast(w, WatchEvent::Attached(AttachedDevice { udid: udid.to_owned(), mux_id: mux }));
    }

    fn detach(w: &mut World, udid: &str) {
        if let Some(mux) = w.phones.get_mut(udid).and_then(|p| p.mux_id.take()) {
            Self::broadcast(w, WatchEvent::Detached { mux_id: mux });
        }
    }

    fn make_phone(serial: u32, scenario: Scenario) -> Phone {
        let (name, model, pt) = NAMES[(serial as usize) % NAMES.len()];
        let ios = match scenario {
            Scenario::Ready | Scenario::NoApp | Scenario::Locked => "18.6.2",
            Scenario::DevModeOff | Scenario::RebootHangs => "17.5.1",
            Scenario::NoRpService => "26.0.1",
            Scenario::Legacy16 => "16.7.10",
            Scenario::Early17 => "17.2",
            Scenario::Unsupported => "15.8",
        };
        Phone {
            info: DeviceInfo {
                udid: format!("00008{serial:03}-MOCK{serial:011}"),
                name: name.into(),
                model: model.into(),
                product_type: pt.into(),
                ios: ios.into(),
            },
            mux_id: None,
            trusted: false,
            locked: scenario == Scenario::Locked,
            dev_mode: !matches!(scenario, Scenario::DevModeOff | Scenario::RebootHangs),
            revealed: false,
            prompt_pending: false,
            app: (scenario != Scenario::NoApp).then(|| ("com.customer.loopctrl".into(), "1.4".into())),
            rp_service: scenario != Scenario::NoRpService,
            reboot_returns: scenario != Scenario::RebootHangs,
            trust_answer: None,
            auto: None,
        }
    }

    /// Plugs in a new phone. Returns its UDID.
    pub fn plug(&self, scenario: Scenario) -> String {
        let mut w = self.world.lock().unwrap();
        let serial = w.next_serial;
        w.next_serial += 1;
        let phone = Self::make_phone(serial, scenario);
        let udid = phone.info.udid.clone();
        w.phones.insert(udid.clone(), phone);
        Self::attach(&mut w, &udid);
        udid
    }

    /// Plugs in a phone that does everything asked of it by itself (Trust,
    /// the Developer Mode restart, "Turn On"), for demos and the CLI.
    pub fn plug_auto(&self, scenario: Scenario) -> String {
        let mut w = self.world.lock().unwrap();
        let serial = w.next_serial;
        w.next_serial += 1;
        let mut p = Self::make_phone(serial, scenario);
        p.auto = Some(AutoScript {
            trust_after: Duration::from_millis(1500),
            restart_after: Duration::from_millis(1000),
            turn_on_after: Duration::from_millis(1000),
        });
        let udid = p.info.udid.clone();
        w.phones.insert(udid.clone(), p);
        Self::attach(&mut w, &udid);
        udid
    }

    /// Five phones on a hub that act on their own, like the approved demo:
    /// three finish, one needs Developer Mode, one lacks LoopCtrl.
    pub fn plug_batch(&self) -> Vec<String> {
        let ms = Duration::from_millis;
        let plan: [(Scenario, bool, u64); 5] = [
            (Scenario::Ready, true, 0),
            (Scenario::Ready, false, 4200),
            (Scenario::Legacy16, false, 1800),
            (Scenario::NoRpService, false, 2600),
            (Scenario::NoApp, true, 0),
        ];
        let mut out = Vec::new();
        for (i, (scenario, trusted, trust_ms)) in plan.into_iter().enumerate() {
            let mut w = self.world.lock().unwrap();
            let serial = w.next_serial;
            w.next_serial += 1;
            let mut p = Self::make_phone(serial, scenario);
            p.trusted = trusted;
            // Phone 3 needs a human for Developer Mode, as in the demo.
            if i == 2 {
                p.dev_mode = false;
            }
            p.auto = Some(AutoScript { trust_after: ms(trust_ms), restart_after: ms(0), turn_on_after: ms(0) });
            if i == 2 {
                // Trust on its own, Developer Mode by hand.
                p.auto = Some(AutoScript {
                    trust_after: ms(trust_ms),
                    restart_after: Duration::MAX,
                    turn_on_after: Duration::MAX,
                });
            }
            let udid = p.info.udid.clone();
            w.phones.insert(udid.clone(), p);
            Self::attach(&mut w, &udid);
            out.push(udid);
        }
        out
    }

    /// Unplugs and forgets every phone.
    pub fn reset(&self) {
        let mut w = self.world.lock().unwrap();
        let udids: Vec<_> = w.phones.keys().cloned().collect();
        for u in udids {
            Self::detach(&mut w, &u);
        }
        w.phones.clear();
    }

    /// Pretend Apple Devices is (not) installed.
    pub fn set_driver_missing(&self, missing: bool) {
        self.world.lock().unwrap().driver_missing = missing;
    }

    /// Developer Mode state of a phone not yet checked (the demo switch).
    pub fn set_dev_mode(&self, udid: &str, on: bool) {
        if let Some(p) = self.world.lock().unwrap().phones.get_mut(udid) {
            p.dev_mode = on;
        }
    }

    /// Does what the person holding the phone would do.
    pub fn phone(&self, udid: &str, action: PhoneAction) {
        if action == PhoneAction::Restart {
            return self.restart(udid);
        }
        {
            let mut w = self.world.lock().unwrap();
            let Some(p) = w.phones.get_mut(udid) else { return };
            match action {
                PhoneAction::Trust => p.trust_answer = Some(true),
                PhoneAction::DontTrust => p.trust_answer = Some(false),
                PhoneAction::Unlock => p.locked = false,
                PhoneAction::TurnOn if p.prompt_pending => {
                    p.prompt_pending = false;
                    p.dev_mode = true;
                }
                PhoneAction::Cancel => p.prompt_pending = false,
                PhoneAction::InstallApp => p.app = Some(("com.customer.loopctrl".into(), "1.4".into())),
                PhoneAction::Unplug => Self::detach(&mut w, udid),
                PhoneAction::Plug => {
                    if w.phones.get(udid).is_some_and(|p| p.mux_id.is_none()) {
                        Self::attach(&mut w, udid);
                    }
                }
                PhoneAction::Restart | PhoneAction::TurnOn => {}
            }
        }
    }

    /// The Developer Mode restart: off the bus, back after a few seconds.
    fn restart(&self, udid: &str) {
        let back = {
            let mut w = self.world.lock().unwrap();
            let Some(p) = w.phones.get_mut(udid) else { return };
            if !p.revealed || p.mux_id.is_none() {
                return;
            }
            p.prompt_pending = true;
            let back = p.reboot_returns;
            Self::detach(&mut w, udid);
            back
        };
        if back {
            let me = self.clone();
            let udid = udid.to_owned();
            after(self.delay(3500), move || {
                let mut w = me.world.lock().unwrap();
                Self::attach(&mut w, &udid);
            });
        }
    }

    fn get<T>(&self, udid: &str, f: impl FnOnce(&mut Phone) -> T) -> Result<T, PairError> {
        let mut w = self.world.lock().unwrap();
        match w.phones.get_mut(udid) {
            Some(p) if p.mux_id.is_some() => Ok(f(p)),
            _ => Err(PairError::new(ErrorCode::Disconnected, "mock: not attached")),
        }
    }
}

/// Runs `f` after `d` on a plain thread: phone actions come from UI threads
/// that have no async runtime.
fn after(d: Duration, f: impl FnOnce() + Send + 'static) {
    std::thread::spawn(move || {
        std::thread::sleep(d);
        f();
    });
}

impl Backend for MockBackend {
    type Conn = MockConn;

    async fn env_check(&self) -> EnvReport {
        let missing = self.world.lock().unwrap().driver_missing;
        let mut r = crate::env::host_os();
        r.usbmux_ok = !missing;
        r.usbmux_addr = "mock".into();
        r.transport = "mock".into();
        r.detail = missing.then(|| "mock: Apple Devices not installed".into());
        r
    }

    async fn watch(&self, tx: UnboundedSender<WatchEvent>) -> Result<(), PairError> {
        {
            let mut w = self.world.lock().unwrap();
            for (udid, p) in &w.phones {
                if let Some(mux) = p.mux_id {
                    let _ = tx.send(WatchEvent::Attached(AttachedDevice { udid: udid.clone(), mux_id: mux }));
                }
            }
            w.watchers.push(tx.clone());
        }
        tx.closed().await;
        Ok(())
    }

    fn open(&self, dev: &AttachedDevice) -> MockConn {
        MockConn { backend: self.clone(), udid: dev.udid.clone() }
    }
}

pub struct MockConn {
    backend: MockBackend,
    udid: String,
}

impl MockConn {
    async fn wait(&self, ms: u64) {
        sleep(self.backend.delay(ms)).await;
    }
    fn phone<T>(&self, f: impl FnOnce(&mut Phone) -> T) -> Result<T, PairError> {
        self.backend.get(&self.udid, f)
    }
}

impl DeviceConn for MockConn {
    fn rebind(&mut self, _dev: &AttachedDevice) {}

    async fn info(&mut self) -> Result<DeviceInfo, PairError> {
        self.wait(300).await;
        self.phone(|p| {
            let mut i = p.info.clone();
            if !p.trusted {
                // lockdownd hides the name until Trust.
                i.name = "iPhone".into();
            }
            i
        })
    }

    async fn trust(&mut self, _host: &HostIdentity) -> Result<TrustResult, PairError> {
        self.wait(400).await;
        let (trusted, auto) = self.phone(|p| (p.trusted, p.auto))?;
        if trusted {
            return Ok(TrustResult { outcome: TrustOutcome::AlreadyTrusted, lockdown: Some(sample_lockdown()) });
        }
        if self.phone(|p| p.locked)? {
            return Ok(TrustResult { outcome: TrustOutcome::Locked, lockdown: None });
        }
        if let Some(a) = auto {
            sleep(self.backend.delay(a.trust_after.as_millis() as u64)).await;
            self.phone(|p| p.trust_answer = Some(true))?;
        }
        loop {
            match self.phone(|p| p.trust_answer.take())? {
                Some(true) => {
                    self.phone(|p| p.trusted = true)?;
                    return Ok(TrustResult { outcome: TrustOutcome::Paired, lockdown: Some(sample_lockdown()) });
                }
                Some(false) => return Err(PairError::new(ErrorCode::Untrusted, "mock: UserDeniedPairing")),
                None => self.wait(150).await,
            }
        }
    }

    fn set_lockdown(&mut self, _lockdown: &[u8]) -> Result<(), PairError> {
        Ok(())
    }

    async fn dev_mode_status(&mut self) -> Result<bool, PairError> {
        self.wait(900).await;
        self.phone(|p| p.dev_mode)
    }

    async fn reveal_dev_mode(&mut self) -> Result<(), PairError> {
        self.wait(1200).await;
        let auto = self.phone(|p| {
            p.revealed = true;
            p.auto
        })?;
        if let Some(a) = auto.filter(|a| a.restart_after != Duration::MAX) {
            let b = self.backend.clone();
            let udid = self.udid.clone();
            after(self.backend.delay(a.restart_after.as_millis() as u64 + 1500), move || b.restart(&udid));
        }
        Ok(())
    }

    async fn accept_dev_mode(&mut self) -> Result<(), PairError> {
        let auto = self.phone(|p| p.auto)?;
        if let Some(a) = auto.filter(|a| a.turn_on_after != Duration::MAX) {
            sleep(self.backend.delay(a.turn_on_after.as_millis() as u64 + 1200)).await;
            self.backend.phone(&self.udid, PhoneAction::TurnOn);
        }
        Ok(())
    }

    async fn enable_wifi_debugging(&mut self) -> Result<(), PairError> {
        self.phone(|_| ())
    }

    async fn generate_rp(&mut self, host: &HostIdentity, cached: Option<&[u8]>) -> Result<(Vec<u8>, RpVia), PairError> {
        self.wait(1100).await;
        let svc = self.phone(|p| p.rp_service)?;
        if let Some(c) = cached {
            return Ok((c.to_vec(), RpVia::Cached));
        }
        let rp = idevice::remote_pairing::RpPairingFile::generate(&host.host_name).to_bytes();
        if !svc {
            self.wait(900).await;
        }
        Ok((rp, if svc { RpVia::LockdownService } else { RpVia::CoreDeviceProxy }))
    }

    async fn list_apps(&mut self) -> Result<AppList, PairError> {
        self.wait(900).await;
        let app = self.phone(|p| p.app.clone())?;
        let mut out = AppList::new();
        let mut wx = plist::Dictionary::new();
        wx.insert("CFBundleDisplayName".into(), "微信".into());
        out.insert("com.tencent.xin".into(), plist::Value::Dictionary(wx));
        if let Some((id, ver)) = app {
            let mut d = plist::Dictionary::new();
            d.insert("CFBundleDisplayName".into(), "LoopCtrl".into());
            d.insert("CFBundleShortVersionString".into(), ver.into());
            out.insert(id, plist::Value::Dictionary(d));
        }
        Ok(out)
    }

    async fn write_dropbox(&mut self, _bundle_id: &str, bytes: &[u8]) -> Result<WriteVia, PairError> {
        self.wait(1000).await;
        crate::record::inspect(bytes).map_err(|e| PairError::new(ErrorCode::WriteFailed, e.detail))?;
        self.phone(|_| WriteVia::VendContainer)
    }

    async fn verify_rp(&mut self, _host: &HostIdentity, rp: &[u8]) -> Result<(), PairError> {
        self.wait(900).await;
        idevice::remote_pairing::RpPairingFile::from_bytes(rp)
            .map_err(|e| PairError::new(ErrorCode::VerifyFailed, e.to_string()))?;
        self.phone(|_| ())
    }

    async fn verify_lockdown(&mut self, _lockdown: &[u8]) -> Result<(), PairError> {
        self.wait(900).await;
        self.phone(|_| ())
    }
}

/// A lockdown record with the right keys and dummy contents.
fn sample_lockdown() -> Vec<u8> {
    let mut d = plist::Dictionary::new();
    for k in ["DeviceCertificate", "HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey"] {
        d.insert(k.into(), plist::Value::Data(b"mock".to_vec()));
    }
    d.insert("SystemBUID".into(), "MOCK-BUID".into());
    d.insert("HostID".into(), uuid::Uuid::new_v4().to_string().to_uppercase().into());
    d.insert("WiFiMACAddress".into(), "00:00:00:00:00:00".into());
    let mut out = Vec::new();
    plist::to_writer_xml(&mut out, &plist::Value::Dictionary(d)).expect("plist");
    out
}
