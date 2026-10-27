//! UniFFI exports for the native Android app (android/app).
//!
//! One [`PairBridge`] per process. It runs the built-in usbmuxd (crates/usbmux)
//! on a private unix socket in the app's data folder and a pair-core manager
//! that talks to it, exactly as the desktop app talks to the system usbmuxd.
//! The app's USB host code hands over iPhones it opened with
//! [`PairBridge::attach_usb_device`].
//!
//! Views, events and environment reports cross as JSON in pair-core's serde
//! shape (the same the desktop UI consumes); commands as their camelCase names.

use std::collections::HashMap;
use std::os::fd::{BorrowedFd, RawFd};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use pair_core::{
    Config, Event, ManagerHandle, MockBackend, PhoneAction, RealBackend, Scenario, UsbmuxdAddr, UserCommand,
};
use usbmux::{location_id, udid_from_serial, DeviceInfo, FilePairStore, Hub};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BridgeError {
    #[error("{detail}")]
    Failed { detail: String },
}

fn failed(what: &str, e: impl std::fmt::Display) -> BridgeError {
    BridgeError::Failed { detail: format!("{what}: {e}") }
}

/// Receives pair-core events as JSON (`{"type":"device","device":{…}}`,
/// `removed`, `watch`). Called from the manager thread; must not block.
#[uniffi::export(with_foreign)]
pub trait PairListener: Send + Sync {
    fn on_event(&self, json: String);
}

struct Core {
    manager: Option<ManagerHandle>,
    mock: Option<MockBackend>,
    auto_begin: bool,
}

#[derive(uniffi::Object)]
pub struct PairBridge {
    data_dir: PathBuf,
    tool_version: String,
    listener: Arc<dyn PairListener>,
    /// Runs the muxer: the socket server and one task set per iPhone.
    rt: tokio::runtime::Runtime,
    hub: Hub,
    socket: Option<UsbmuxdAddr>,
    socket_error: Option<String>,
    /// Name Android gave the USB device → hub id.
    attached: Mutex<HashMap<String, u32>>,
    core: Mutex<Core>,
}

fn init_logging() {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default().with_max_level(log::LevelFilter::Info).with_tag("LoopCtrlPair"),
    );
}

#[uniffi::export]
impl PairBridge {
    /// Starts the muxer and the manager. `data_dir` is the app's private
    /// files folder; records and the socket live there.
    #[uniffi::constructor]
    pub fn new(data_dir: String, tool_version: String, mock: bool, listener: Arc<dyn PairListener>) -> Arc<Self> {
        init_logging();
        let data_dir = PathBuf::from(data_dir);
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("usbmux")
            .enable_all()
            .build()
            .expect("tokio runtime for the muxer");
        // Records the muxer keeps, like /var/lib/lockdown on a computer.
        let hub = Hub::new(Box::new(FilePairStore::new(data_dir.join("lockdown"))));
        let path = data_dir.join("usbmuxd.sock");
        let (socket, socket_error) = match usbmux::bind_private_socket(&path) {
            Ok(listener) => {
                let serving = hub.clone();
                rt.spawn(async move {
                    match tokio::net::UnixListener::from_std(listener) {
                        Ok(l) => usbmux::server::serve_unix(l, serving).await,
                        Err(e) => log::error!("usbmux server: {e}"),
                    }
                });
                (Some(UsbmuxdAddr::UnixSocket(path.to_string_lossy().into_owned())), None)
            }
            Err(e) => {
                log::error!("usbmux socket {}: {e}", path.display());
                (None, Some(e.to_string()))
            }
        };
        let bridge = Arc::new(Self {
            data_dir,
            tool_version,
            listener,
            rt,
            hub,
            socket,
            socket_error,
            attached: Mutex::new(HashMap::new()),
            core: Mutex::new(Core { manager: None, mock: None, auto_begin: false }),
        });
        bridge.start(mock);
        bridge
    }

    /// Adds an iPhone the app opened through `UsbManager` (mux interface
    /// claimed). The muxer works on a duplicate of `fd`; the caller keeps
    /// its own open while the phone is attached. `name` is the device path,
    /// used again in [`Self::detach_usb_device`].
    #[allow(clippy::too_many_arguments)]
    pub async fn attach_usb_device(
        &self,
        fd: i32,
        serial: String,
        product_id: u16,
        ep_in: u8,
        ep_out: u8,
        max_packet_out: u32,
        name: String,
    ) -> Result<(), BridgeError> {
        if let Some(id) = self.attached.lock().unwrap().remove(&name) {
            self.hub.remove_device(id);
        }
        // SAFETY: the caller keeps `fd` open for this call; it is duplicated
        // at once so the two lifetimes are independent.
        let owned = unsafe { BorrowedFd::borrow_raw(fd as RawFd) }
            .try_clone_to_owned()
            .map_err(|e| failed("duplicate the USB descriptor", e))?;
        let pipe = new_pipe(owned, ep_in, ep_out, max_packet_out as usize)?;
        let info = DeviceInfo {
            udid: udid_from_serial(&serial),
            product_id,
            location_id: location_id(&name),
            speed: 480_000_000,
        };
        log::info!("attaching {} ({name})", info.udid);
        let hub = self.hub.clone();
        let id = self
            .rt
            .spawn(async move { hub.add_device(pipe, info).await })
            .await
            .map_err(|e| failed("attach", e))?
            .map_err(|e| failed("attach", e))?;
        self.attached.lock().unwrap().insert(name, id);
        Ok(())
    }

    /// The phone was unplugged (or the app let go of it).
    pub fn detach_usb_device(&self, name: String) {
        if let Some(id) = self.attached.lock().unwrap().remove(&name) {
            self.hub.remove_device(id);
        }
    }

    /// `EnvReport` as JSON. Without a muxer socket, `usbmuxOk` is false.
    pub async fn env_check(&self) -> String {
        let fut = self.core.lock().unwrap().manager.as_ref().map(|m| m.env_check());
        let mut report = match fut {
            Some(f) => f.await,
            None => None,
        }
        .unwrap_or_else(pair_core::env::host_os);
        if let Some(e) = &self.socket_error {
            report.usbmux_ok = false;
            report.detail = Some(e.clone());
        }
        serde_json::to_string(&report).unwrap_or_default()
    }

    /// Every phone's `DeviceView`, as a JSON array.
    pub async fn devices(&self) -> String {
        let fut = self.core.lock().unwrap().manager.as_ref().map(|m| m.snapshot());
        let views = match fut {
            Some(f) => f.await,
            None => Vec::new(),
        };
        serde_json::to_string(&views).unwrap_or_else(|_| "[]".into())
    }

    /// `begin`, `retry`, `recheck` or `cancel`.
    pub fn command(&self, udid: String, cmd: String) -> Result<(), BridgeError> {
        let cmd: UserCommand = parse(&cmd)?;
        if let Some(m) = &self.core.lock().unwrap().manager {
            m.command(&udid, cmd);
        }
        Ok(())
    }

    pub fn set_auto_begin(&self, on: bool) {
        let mut core = self.core.lock().unwrap();
        core.auto_begin = on;
        if let Some(m) = &core.manager {
            m.set_auto_begin(on);
        }
    }

    pub fn forget(&self, udid: String) {
        if let Some(m) = &self.core.lock().unwrap().manager {
            m.forget(&udid);
        }
    }

    pub fn cache_dir(&self) -> String {
        self.data_dir.display().to_string()
    }

    // Simulated iPhones, for demos and work on the UI without hardware.

    pub fn is_mock(&self) -> bool {
        self.core.lock().unwrap().mock.is_some()
    }

    pub fn set_mock(&self, on: bool) {
        self.start(on);
    }

    pub fn mock_plug(&self, scenario: String) -> Result<(), BridgeError> {
        let s: Scenario = parse(&scenario)?;
        self.with_mock(|m| {
            m.plug(s);
        })
    }

    pub fn mock_batch(&self) -> Result<(), BridgeError> {
        self.with_mock(|m| {
            m.plug_batch();
        })
    }

    pub fn mock_phone(&self, udid: String, action: String) -> Result<(), BridgeError> {
        let a: PhoneAction = parse(&action)?;
        self.with_mock(|m| m.phone(&udid, a))
    }

    pub fn mock_reset(&self) -> Result<(), BridgeError> {
        self.with_mock(|m| m.reset())
    }
}

impl PairBridge {
    fn start(&self, mock: bool) {
        let mut core = self.core.lock().unwrap();
        // Stop the old manager first: two watchers would both act.
        core.manager = None;
        let mut cfg = Config::new(self.data_dir.join("pair"));
        cfg.auto_begin = core.auto_begin;
        cfg.tool_version = self.tool_version.clone();
        let listener = self.listener.clone();
        let on_event = move |e: Event| {
            if let Ok(json) = serde_json::to_string(&e) {
                listener.on_event(json);
            }
        };
        if mock {
            cfg.reboot_timeout = Duration::from_secs(20);
            cfg.confirm_timeout = Duration::from_secs(15);
            let m = core.mock.get_or_insert_with(MockBackend::new).clone();
            core.manager = Some(ManagerHandle::start(m, cfg, on_event));
        } else {
            core.mock = None;
            // No socket: an address nothing listens on, so the watcher keeps
            // reporting the muxer as missing.
            let addr = self.socket.clone().unwrap_or_else(|| {
                UsbmuxdAddr::UnixSocket(self.data_dir.join("usbmuxd.sock").to_string_lossy().into_owned())
            });
            core.manager = Some(ManagerHandle::start(RealBackend::at(addr), cfg, on_event));
        }
        log::info!("pair-core started ({})", if mock { "mock" } else { "built-in usbmuxd" });
    }

    fn with_mock(&self, f: impl FnOnce(&MockBackend)) -> Result<(), BridgeError> {
        let core = self.core.lock().unwrap();
        let m = core.mock.as_ref().ok_or_else(|| failed("mock", "not in mock mode"))?;
        f(m);
        Ok(())
    }
}

fn parse<T: serde::de::DeserializeOwned>(name: &str) -> Result<T, BridgeError> {
    serde_json::from_value(serde_json::Value::String(name.to_owned())).map_err(|e| failed(name, e))
}

#[cfg(any(target_os = "android", target_os = "linux"))]
fn new_pipe(
    fd: std::os::fd::OwnedFd,
    ep_in: u8,
    ep_out: u8,
    max_packet_out: usize,
) -> Result<Arc<dyn usbmux::pipe::UsbPipe>, BridgeError> {
    Ok(Arc::new(usbmux::usbfs::UsbfsPipe::new(fd, ep_in, ep_out, max_packet_out)))
}

/// usbfs exists on Linux and Android only; elsewhere the bridge is built for
/// tests and binding generation.
#[cfg(not(any(target_os = "android", target_os = "linux")))]
fn new_pipe(
    _fd: std::os::fd::OwnedFd,
    _ep_in: u8,
    _ep_out: u8,
    _max_packet_out: usize,
) -> Result<Arc<dyn usbmux::pipe::UsbPipe>, BridgeError> {
    Err(failed("USB", "usbfs is only available on Android and Linux"))
}
