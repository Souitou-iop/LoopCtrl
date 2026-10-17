//! Runs the state machines: one worker per phone, a usbmuxd watcher, and the
//! manager that routes events between them. Everything lives on one thread
//! with a single-threaded tokio runtime; the UI talks to it through
//! [`ManagerHandle`].

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tokio::sync::{mpsc, oneshot};
use tokio::time::sleep;

use crate::app_match::find_loopctrl;
use crate::backend::{Backend, DeviceConn, WatchEvent};
use crate::cache::{Cache, HostIdentity};
use crate::machine::{Action, Input, Machine, Phase, Step};
use crate::model::*;
use crate::record::{self, RecordMeta};

#[derive(Debug, Clone)]
pub struct Config {
    pub cache_dir: PathBuf,
    /// Batch mode: start every phone without waiting for Begin.
    pub auto_begin: bool,
    /// How long to wait for the phone after the Developer Mode reboot.
    pub reboot_timeout: Duration,
    /// How long to wait for "Turn On" after the reboot.
    pub confirm_timeout: Duration,
    /// Pause between Trust attempts while the phone is locked.
    pub trust_retry: Duration,
    pub tool_version: String,
}

impl Config {
    pub fn new(cache_dir: impl Into<PathBuf>) -> Self {
        Self {
            cache_dir: cache_dir.into(),
            auto_begin: false,
            reboot_timeout: Duration::from_secs(180),
            confirm_timeout: Duration::from_secs(120),
            trust_retry: Duration::from_secs(1),
            tool_version: env!("CARGO_PKG_VERSION").to_owned(),
        }
    }
}

/// Everything the UI shows about one phone.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceView {
    pub udid: String,
    /// 1-based attach order, shown as "USB #n".
    pub order: u32,
    pub connected: bool,
    pub info: Option<DeviceInfo>,
    pub phase: Phase,
    pub error: Option<PairError>,
    pub failed_at: Option<Step>,
    pub progress: f32,
    pub attention: bool,
    pub dev_mode_was_off: bool,
    pub record_kind: Option<RecordKind>,
    pub rp_via: Option<RpVia>,
    pub app: Option<AppMatch>,
    pub write_via: Option<WriteVia>,
    /// Phone is locked during Trust.
    pub locked: bool,
    /// Unix ms when the current phase began (reboot clock).
    pub phase_since: u64,
    /// Unix ms when the phone finished.
    pub done_at: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    Device { device: Box<DeviceView> },
    Removed { udid: String },
    /// usbmuxd connection state.
    Watch { ok: bool, detail: Option<String> },
}

#[derive(Debug)]
enum DeviceMsg {
    Attached(AttachedDevice),
    Detached,
    User(UserCommand),
    AutoBegin(bool),
}

enum Cmd {
    User { udid: String, cmd: UserCommand },
    AutoBegin(bool),
    Forget(String),
    Snapshot(oneshot::Sender<Vec<DeviceView>>),
    Env(oneshot::Sender<EnvReport>),
    Shutdown,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Handle to a running manager. Dropping it stops the manager thread.
pub struct ManagerHandle {
    tx: mpsc::UnboundedSender<Cmd>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl ManagerHandle {
    pub fn start<B, F>(backend: B, config: Config, on_event: F) -> Self
    where
        B: Backend + Send,
        F: Fn(Event) + Send + 'static,
    {
        let (tx, rx) = mpsc::unbounded_channel();
        let thread = std::thread::Builder::new()
            .name("pair-core".into())
            .spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("tokio runtime");
                let local = tokio::task::LocalSet::new();
                local.block_on(&rt, manager_loop(backend, config, rx, on_event));
            })
            .expect("spawn pair-core thread");
        Self { tx, thread: Some(thread) }
    }

    pub fn command(&self, udid: &str, cmd: UserCommand) {
        let _ = self.tx.send(Cmd::User { udid: udid.to_owned(), cmd });
    }

    pub fn set_auto_begin(&self, on: bool) {
        let _ = self.tx.send(Cmd::AutoBegin(on));
    }

    /// Drops a phone that is unplugged (or done) from the list.
    pub fn forget(&self, udid: &str) {
        let _ = self.tx.send(Cmd::Forget(udid.to_owned()));
    }

    pub async fn snapshot(&self) -> Vec<DeviceView> {
        let (tx, rx) = oneshot::channel();
        let _ = self.tx.send(Cmd::Snapshot(tx));
        rx.await.unwrap_or_default()
    }

    pub async fn env_check(&self) -> Option<EnvReport> {
        let (tx, rx) = oneshot::channel();
        let _ = self.tx.send(Cmd::Env(tx));
        rx.await.ok()
    }
}

impl Drop for ManagerHandle {
    fn drop(&mut self) {
        let _ = self.tx.send(Cmd::Shutdown);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

struct Entry {
    mux_id: Option<u32>,
    inbox: mpsc::UnboundedSender<DeviceMsg>,
    view: Option<DeviceView>,
    task: tokio::task::JoinHandle<()>,
}

async fn manager_loop<B: Backend, F: Fn(Event)>(
    backend: B,
    config: Config,
    mut rx: mpsc::UnboundedReceiver<Cmd>,
    on_event: F,
) {
    let backend = std::rc::Rc::new(backend);
    let cache = Cache::new(&config.cache_dir);
    let host = match cache.host_identity() {
        Ok(h) => h,
        Err(e) => {
            log::error!("host identity: {e}");
            HostIdentity { host_name: "LoopCtrl-Pair-000000".into() }
        }
    };
    let mut auto_begin = config.auto_begin;

    // usbmuxd watcher, reconnecting every 2 s when the connection drops.
    let (watch_tx, mut watch_rx) = mpsc::unbounded_channel::<WatchEvent>();
    let (state_tx, mut state_rx) = mpsc::unbounded_channel::<(bool, Option<String>)>();
    {
        let backend = backend.clone();
        tokio::task::spawn_local(async move {
            loop {
                let _ = state_tx.send((true, None));
                let r = backend.watch(watch_tx.clone()).await;
                let detail = r.err().map(|e| e.detail);
                if state_tx.send((false, detail)).is_err() {
                    return;
                }
                sleep(Duration::from_secs(2)).await;
            }
        });
    }

    let (view_tx, mut view_rx) = mpsc::unbounded_channel::<DeviceView>();
    let mut devices: HashMap<String, Entry> = HashMap::new();
    let mut order = 0u32;
    let mut watch_ok: Option<bool> = None;

    loop {
        tokio::select! {
            cmd = rx.recv() => match cmd {
                None | Some(Cmd::Shutdown) => break,
                Some(Cmd::User { udid, cmd }) => {
                    if let Some(e) = devices.get(&udid) { let _ = e.inbox.send(DeviceMsg::User(cmd)); }
                }
                Some(Cmd::AutoBegin(on)) => {
                    auto_begin = on;
                    for e in devices.values() { let _ = e.inbox.send(DeviceMsg::AutoBegin(on)); }
                }
                Some(Cmd::Forget(udid)) => {
                    let gone = devices.get(&udid).is_some_and(|e| e.mux_id.is_none()
                        || e.view.as_ref().is_some_and(|v| v.phase == Phase::Done));
                    if gone {
                        if let Some(e) = devices.remove(&udid) { e.task.abort(); }
                        on_event(Event::Removed { udid });
                    }
                }
                Some(Cmd::Snapshot(tx)) => {
                    let mut v: Vec<_> = devices.values().filter_map(|e| e.view.clone()).collect();
                    v.sort_by_key(|d| d.order);
                    let _ = tx.send(v);
                }
                Some(Cmd::Env(tx)) => { let _ = tx.send(backend.env_check().await); }
            },
            Some(ev) = watch_rx.recv() => match ev {
                WatchEvent::Attached(dev) => {
                    if let Some(e) = devices.get_mut(&dev.udid) {
                        e.mux_id = Some(dev.mux_id);
                        let _ = e.inbox.send(DeviceMsg::Attached(dev));
                    } else {
                        order += 1;
                        let (itx, irx) = mpsc::unbounded_channel();
                        let conn = backend.open(&dev);
                        let worker = Worker {
                            udid: dev.udid.clone(),
                            order,
                            connected: true,
                            machine: Machine::new(auto_begin),
                            conn,
                            cache: cache.clone(),
                            host: host.clone(),
                            config: config.clone(),
                            lockdown: None,
                            merged: None,
                            locked: false,
                            phase_since: now_ms(),
                            done_at: None,
                            views: view_tx.clone(),
                        };
                        let task = tokio::task::spawn_local(worker.run(irx));
                        let _ = itx.send(DeviceMsg::Attached(dev.clone()));
                        devices.insert(dev.udid.clone(), Entry { mux_id: Some(dev.mux_id), inbox: itx, view: None, task });
                    }
                }
                WatchEvent::Detached { mux_id } => {
                    if let Some(e) = devices.values_mut().find(|e| e.mux_id == Some(mux_id)) {
                        e.mux_id = None;
                        let _ = e.inbox.send(DeviceMsg::Detached);
                    }
                }
            },
            Some((ok, detail)) = state_rx.recv() => {
                if !ok {
                    // usbmuxd went away: every phone is effectively unplugged.
                    for e in devices.values_mut() {
                        if e.mux_id.take().is_some() { let _ = e.inbox.send(DeviceMsg::Detached); }
                    }
                }
                if watch_ok != Some(ok) || detail.is_some() {
                    watch_ok = Some(ok);
                    on_event(Event::Watch { ok, detail });
                }
            },
            Some(view) = view_rx.recv() => {
                if let Some(e) = devices.get_mut(&view.udid) { e.view = Some(view.clone()); }
                on_event(Event::Device { device: Box::new(view) });
            },
        }
    }
    for (_, e) in devices.drain() {
        e.task.abort();
    }
}

struct Worker<C: DeviceConn> {
    udid: String,
    order: u32,
    connected: bool,
    machine: Machine,
    conn: C,
    cache: Cache,
    host: HostIdentity,
    config: Config,
    lockdown: Option<Vec<u8>>,
    merged: Option<Vec<u8>>,
    locked: bool,
    phase_since: u64,
    done_at: Option<u64>,
    views: mpsc::UnboundedSender<DeviceView>,
}

impl<C: DeviceConn> Worker<C> {
    fn view(&self) -> DeviceView {
        let m = &self.machine;
        DeviceView {
            udid: self.udid.clone(),
            order: self.order,
            connected: self.connected,
            info: m.info.clone(),
            phase: m.phase,
            error: m.error.clone(),
            failed_at: m.failed_at,
            progress: m.progress(),
            attention: m.needs_attention(),
            dev_mode_was_off: m.dev_mode_was_off,
            record_kind: m.record_kind,
            rp_via: m.rp_via,
            app: m.app.clone(),
            write_via: m.write_via,
            locked: self.locked && m.phase == Phase::Trusting,
            phase_since: self.phase_since,
            done_at: self.done_at,
        }
    }

    fn emit(&self) {
        let _ = self.views.send(self.view());
    }

    /// Feeds an input; returns the next action if the machine wants one.
    fn feed(&mut self, input: Input) -> Option<Action> {
        if let Input::Trust(t) = &input {
            self.locked = *t == TrustOutcome::Locked;
        }
        let before = self.machine.phase;
        let next = self.machine.step(input);
        if self.machine.phase != before {
            self.phase_since = now_ms();
            if self.machine.phase == Phase::Done {
                self.done_at = Some(self.phase_since);
            }
            log::info!("{}: {:?} → {:?}", self.udid, before, self.machine.phase);
        }
        self.emit();
        next
    }

    fn on_msg(&mut self, msg: DeviceMsg) -> Option<Action> {
        match msg {
            DeviceMsg::Attached(dev) => {
                self.connected = true;
                self.conn.rebind(&dev);
                self.feed(Input::Attached)
            }
            DeviceMsg::Detached => {
                self.connected = false;
                self.feed(Input::Detached)
            }
            DeviceMsg::User(cmd) => self.feed(Input::User(cmd)),
            DeviceMsg::AutoBegin(on) => {
                self.machine.auto_begin = on;
                if on && self.machine.phase == Phase::Detected {
                    self.feed(Input::User(UserCommand::Begin))
                } else {
                    None
                }
            }
        }
    }

    async fn run(mut self, mut inbox: mpsc::UnboundedReceiver<DeviceMsg>) {
        self.emit();
        let mut action = Action::Idle;
        loop {
            let mut interrupt = None;
            let mut outcome = None;
            {
                let job = Self::execute(
                    action,
                    &mut self.conn,
                    &self.config,
                    &self.cache,
                    &self.host,
                    &self.udid,
                    &mut self.lockdown,
                    &mut self.merged,
                    self.machine.info.clone(),
                    self.machine.app.clone(),
                );
                tokio::pin!(job);
                loop {
                    tokio::select! {
                        r = &mut job => { outcome = Some(r); break; }
                        msg = inbox.recv() => {
                            let Some(msg) = msg else { return };
                            if let DeviceMsg::AutoBegin(on) = msg {
                                self.machine.auto_begin = on;
                            }
                            if interrupts(&self.machine, &msg) {
                                interrupt = Some(msg);
                                break;
                            }
                        }
                    }
                }
            }
            if let Some(msg) = interrupt {
                // `None`: nothing changed, so the dropped action runs again.
                action = self.on_msg(msg).unwrap_or(action);
                continue;
            }
            let Some(o) = outcome else { continue };
            if let Some(info) = o.info {
                self.machine.info = Some(info);
            }
            action = match o.input {
                Some(input) => self.feed(input).unwrap_or(Action::Idle),
                None => Action::Idle,
            };
        }
    }

    /// Runs one action and returns what it produced.
    #[allow(clippy::too_many_arguments)]
    async fn execute(
        action: Action,
        conn: &mut C,
        config: &Config,
        cache: &Cache,
        host: &HostIdentity,
        udid: &str,
        lockdown: &mut Option<Vec<u8>>,
        merged: &mut Option<Vec<u8>>,
        info: Option<DeviceInfo>,
        app: Option<AppMatch>,
    ) -> Outcome {
        let fail = |e: PairError| Outcome::input(Input::Failed(e));
        match action {
            Action::Idle | Action::AwaitReboot => std::future::pending::<Outcome>().await,
            Action::ReadInfo => match conn.info().await {
                Ok(i) => Outcome::input(Input::Info(i)),
                Err(e) => fail(e),
            },
            Action::Trust | Action::TrustAfterDelay => {
                if action == Action::TrustAfterDelay {
                    sleep(config.trust_retry).await;
                }
                match conn.trust(host).await {
                    Ok(r) => {
                        if let Some(ld) = r.lockdown {
                            if let Err(e) = cache.save_lockdown(udid, &ld) {
                                log::warn!("cache lockdown: {e}");
                            }
                            *lockdown = Some(ld);
                        }
                        let input = Input::Trust(r.outcome);
                        if r.outcome != TrustOutcome::Locked {
                            if let Ok(fresh) = conn.info().await {
                                if Some(&fresh) != info.as_ref() {
                                    return Outcome { input: Some(input), info: Some(fresh) };
                                }
                            }
                        }
                        Outcome::input(input)
                    }
                    Err(e) => fail(e),
                }
            }
            Action::ReadDevMode => match conn.dev_mode_status().await {
                Ok(on) => Outcome::input(Input::DevMode(on)),
                Err(e) => fail(e),
            },
            Action::RevealDevMode => match conn.reveal_dev_mode().await {
                Ok(()) => Outcome::input(Input::Revealed),
                Err(e) => fail(e),
            },
            Action::AwaitReconnect => {
                sleep(config.reboot_timeout).await;
                Outcome::input(Input::Timeout)
            }
            Action::ConfirmDevMode => {
                let deadline = tokio::time::Instant::now() + config.confirm_timeout;
                let mut asked = false;
                loop {
                    // Right after boot lockdownd may refuse sessions until the
                    // first unlock; every error here just means "not yet".
                    if !asked && conn.accept_dev_mode().await.is_ok() {
                        asked = true;
                    }
                    if let Ok(true) = conn.dev_mode_status().await {
                        return Outcome::input(Input::DevMode(true));
                    }
                    if tokio::time::Instant::now() >= deadline {
                        return Outcome::input(Input::Timeout);
                    }
                    sleep(Duration::from_secs(2)).await;
                }
            }
            Action::Generate(kind) => {
                if lockdown.is_none() {
                    *lockdown = cache.load_lockdown(udid);
                }
                let Some(ld) = lockdown.clone() else {
                    return fail(PairError::new(ErrorCode::RecordFailed, "no lockdown record"));
                };
                if let Err(e) = conn.set_lockdown(&ld) {
                    return fail(e);
                }
                if let Err(e) = conn.enable_wifi_debugging().await {
                    // Only needed for a later wireless refresh; not fatal.
                    log::warn!("{udid}: EnableWifiDebugging: {e}");
                }
                let (rp, via) = match kind {
                    RecordKind::RemotePairing => {
                        let cached = cache.load_pairing_file(udid).and_then(|f| record::rp_part(&f).ok().flatten());
                        match conn.generate_rp(host, cached.as_deref()).await {
                            Ok((rp, via)) => (Some(rp), Some(via)),
                            Err(e) => return fail(e),
                        }
                    }
                    RecordKind::Lockdown => (None, None),
                };
                let meta = RecordMeta {
                    kind,
                    udid: udid.to_owned(),
                    host_name: host.host_name.clone(),
                    ios: info.map(|i| i.ios).unwrap_or_default(),
                    rp_via: via,
                    tool_version: config.tool_version.clone(),
                };
                match record::build(&ld, rp.as_deref(), &meta) {
                    Ok(file) => {
                        if let Err(e) = cache.save_pairing_file(udid, &file) {
                            log::warn!("cache pairing file: {e}");
                        }
                        *merged = Some(file);
                        Outcome::input(Input::Generated { kind, via })
                    }
                    Err(e) => fail(e),
                }
            }
            Action::FindApp => match conn.list_apps().await {
                Ok(apps) => Outcome::input(Input::App(find_loopctrl(&apps))),
                Err(e) => fail(e),
            },
            Action::Write => {
                let (Some(file), Some(app)) = (merged.as_ref(), app) else {
                    return fail(PairError::internal("nothing to write"));
                };
                match conn.write_dropbox(&app.bundle_id, file).await {
                    Ok(via) => Outcome::input(Input::Written(via)),
                    Err(e) => fail(e),
                }
            }
            Action::Verify(kind) => {
                let Some(file) = merged.as_ref() else {
                    return fail(PairError::internal("nothing to verify"));
                };
                let r = match kind {
                    RecordKind::RemotePairing => match record::rp_part(file) {
                        Ok(Some(rp)) => conn.verify_rp(host, &rp).await,
                        Ok(None) => Err(PairError::new(ErrorCode::VerifyFailed, "no RP keys")),
                        Err(e) => Err(e),
                    },
                    RecordKind::Lockdown => match record::lockdown_part(file) {
                        Ok(ld) => conn.verify_lockdown(&ld).await,
                        Err(e) => Err(e),
                    },
                };
                match r {
                    Ok(()) => Outcome::input(Input::Verified),
                    Err(e) => fail(e),
                }
            }
        }
    }
}

/// The result of one action.
struct Outcome {
    input: Option<Input>,
    /// Fresh device info (the real name, once trusted).
    info: Option<DeviceInfo>,
}

impl Outcome {
    fn input(input: Input) -> Self {
        Self { input: Some(input), info: None }
    }
}

/// Whether a message mid-action should cancel the action. Plug events always
/// do; commands only when the machine would act on them.
fn interrupts(m: &Machine, msg: &DeviceMsg) -> bool {
    match msg {
        DeviceMsg::Attached(_) | DeviceMsg::Detached => true,
        DeviceMsg::User(cmd) => m.clone().step(Input::User(*cmd)).is_some(),
        DeviceMsg::AutoBegin(on) => *on && m.phase == Phase::Detected,
    }
}
