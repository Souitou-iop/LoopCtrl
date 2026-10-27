//! Where LoopCtrl Pair finds iPhones, for the desktop app and the CLI.
//!
//! pair-core only needs the address of something that speaks the usbmuxd
//! protocol. This crate decides which one:
//!
//! * **system**: the platform's usbmuxd. macOS has it built in; Windows gets
//!   it with Apple Devices; on Linux it is the `usbmuxd` package, which the
//!   user installs (it is GPL, so it is never bundled).
//! * **built-in**: our own usbmuxd (`crates/usbmux`) on a private socket. On
//!   Linux it opens iPhones itself through usbfs; on any OS it can also take
//!   iPhones from USB bridges over TCP (`--bridge-listen`, see
//!   docs/hardware-helpers.md).
//!
//! [`MuxMode::Auto`] (the default) picks the system usbmuxd when it answers or
//! is installed (it starts on demand when an iPhone is plugged in), and the
//! built-in one otherwise. Override with `LOOPCTRL_PAIR_MUX=system|builtin`
//! or the CLI's `--mux`.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::time::Duration;

use pair_core::{EnvReport, LinuxEnv, UsbmuxdAddr};
use usbmux::{FilePairStore, Hub};

/// Our udev rule, shipped in the .deb and offered by the app and the CLI.
pub const UDEV_RULE: &str = include_str!("../../../packaging/linux/70-loopctrl-pair.rules");
pub const UDEV_RULE_NAME: &str = "70-loopctrl-pair.rules";
/// Where udev rules live; the first is where an admin installs one by hand.
pub const UDEV_RULE_DIRS: [&str; 3] = ["/etc/udev/rules.d", "/usr/lib/udev/rules.d", "/lib/udev/rules.d"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum MuxMode {
    #[default]
    Auto,
    System,
    BuiltIn,
}

impl FromStr for MuxMode {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, String> {
        match s.to_ascii_lowercase().as_str() {
            "auto" | "" => Ok(Self::Auto),
            "system" => Ok(Self::System),
            "builtin" | "built-in" | "builtIn" => Ok(Self::BuiltIn),
            _ => Err(format!("unknown usbmuxd mode {s:?} (auto, system or builtin)")),
        }
    }
}

impl MuxMode {
    /// `LOOPCTRL_PAIR_MUX`, or Auto.
    pub fn from_env() -> Self {
        std::env::var("LOOPCTRL_PAIR_MUX").ok().and_then(|v| v.parse().ok()).unwrap_or_default()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    System,
    BuiltIn,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::System => "system",
            Kind::BuiltIn => "builtIn",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Options {
    pub mode: MuxMode,
    /// Private folder: the built-in usbmuxd keeps its lockdown records in
    /// `lockdown/` here.
    pub data_dir: PathBuf,
    /// Accept USB bridges on this address (forces the built-in usbmuxd).
    pub bridge_listen: Option<SocketAddr>,
    /// Built-in mode only: open iPhones on local USB (Linux). Off for a
    /// bridge-only host.
    pub local_usb: bool,
}

impl Options {
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        Self { mode: MuxMode::from_env(), data_dir: data_dir.into(), bridge_listen: None, local_usb: true }
    }
}

/// The running choice. Keep it alive as long as pair-core uses its address:
/// dropping it stops the built-in usbmuxd.
pub struct Transport {
    mode: MuxMode,
    kind: Kind,
    addr: UsbmuxdAddr,
    built_in: Option<BuiltIn>,
}

struct BuiltIn {
    #[cfg(target_os = "linux")]
    usb: Option<usbmux::linux::LinuxUsbHost>,
    #[cfg(unix)]
    socket: PathBuf,
    bridge: Option<SocketAddr>,
    _hub: Hub,
    // Last, so the tasks above are aborted before the runtime goes.
    rt: tokio::runtime::Runtime,
}

impl Drop for BuiltIn {
    fn drop(&mut self) {
        #[cfg(target_os = "linux")]
        drop(self.usb.take());
        #[cfg(unix)]
        let _ = std::fs::remove_file(&self.socket);
        let _ = &self.rt;
    }
}

/// The system usbmuxd's address (`USBMUXD_SOCKET_ADDRESS` overrides it).
pub fn system_addr() -> UsbmuxdAddr {
    UsbmuxdAddr::from_env_var().unwrap_or_default()
}

/// Something accepts connections on the system usbmuxd address.
pub fn system_answers() -> bool {
    match system_addr() {
        #[cfg(unix)]
        UsbmuxdAddr::UnixSocket(p) => std::os::unix::net::UnixStream::connect(p).is_ok(),
        UsbmuxdAddr::TcpSocket(a) => std::net::TcpStream::connect_timeout(&a, Duration::from_millis(500)).is_ok(),
    }
}

/// The usbmuxd package is installed: its binary, or its udev rule (which
/// starts it when an iPhone is plugged in).
pub fn usbmuxd_installed() -> bool {
    usbmuxd_installed_under(Path::new("/"))
}

fn usbmuxd_installed_under(root: &Path) -> bool {
    let bins = ["usr/sbin/usbmuxd", "usr/bin/usbmuxd", "sbin/usbmuxd", "usr/local/sbin/usbmuxd"];
    let rules = UDEV_RULE_DIRS.iter().map(|d| format!("{}/39-usbmuxd.rules", d.trim_start_matches('/')));
    bins.iter().map(|b| b.to_string()).chain(rules).any(|p| root.join(p).exists())
}

/// Our udev rule (or a copy under its name) is installed.
pub fn udev_rule_installed() -> bool {
    UDEV_RULE_DIRS.iter().any(|d| Path::new(d).join(UDEV_RULE_NAME).exists())
}

/// Auto mode's decision, from what is installed and running.
fn decide(mode: MuxMode, linux: bool, env_override: bool, answers: bool, installed: bool, bridge: bool) -> Kind {
    match mode {
        MuxMode::System => Kind::System,
        MuxMode::BuiltIn => Kind::BuiltIn,
        MuxMode::Auto if bridge => Kind::BuiltIn,
        MuxMode::Auto if env_override || !linux => Kind::System,
        MuxMode::Auto if answers || installed => Kind::System,
        MuxMode::Auto => Kind::BuiltIn,
    }
}

impl Transport {
    pub fn start(opts: &Options) -> Result<Self, String> {
        let linux = cfg!(target_os = "linux");
        let env_override = std::env::var_os("USBMUXD_SOCKET_ADDRESS").is_some();
        let kind = decide(
            opts.mode,
            linux,
            env_override,
            linux && system_answers(),
            linux && usbmuxd_installed(),
            opts.bridge_listen.is_some(),
        );
        log::info!("usbmuxd: {} (mode {:?})", kind.as_str(), opts.mode);
        match kind {
            Kind::System => Ok(Self { mode: opts.mode, kind, addr: system_addr(), built_in: None }),
            Kind::BuiltIn => {
                let (addr, built_in) = start_built_in(opts)?;
                Ok(Self { mode: opts.mode, kind, addr, built_in: Some(built_in) })
            }
        }
    }

    pub fn kind(&self) -> Kind {
        self.kind
    }

    /// What to give `RealBackend::at`.
    pub fn addr(&self) -> UsbmuxdAddr {
        self.addr.clone()
    }

    pub fn bridge_addr(&self) -> Option<SocketAddr> {
        self.built_in.as_ref().and_then(|b| b.bridge)
    }

    /// iPhones the built-in host found on local USB, with their state.
    pub fn usb_status(&self) -> Vec<usbmux::linux::UsbDeviceStatus> {
        #[cfg(target_os = "linux")]
        if let Some(usb) = self.built_in.as_ref().and_then(|b| b.usb.as_ref()) {
            return usb.status();
        }
        Vec::new()
    }

    /// Auto mode chose the built-in usbmuxd, but the system one has started
    /// since (the user installed it): switching avoids fighting over iPhones.
    pub fn should_switch_to_system(&self) -> bool {
        self.mode == MuxMode::Auto && self.kind == Kind::BuiltIn && self.bridge_addr().is_none() && system_answers()
    }

    /// Adds what pair-core cannot know to its environment report.
    pub fn decorate(&self, r: &mut EnvReport) {
        r.transport = self.kind.as_str().into();
        if r.os != "linux" {
            return;
        }
        let devices = self.usb_status();
        let running = system_answers();
        let denied: Vec<&str> = devices
            .iter()
            .filter(|d| d.state == usbmux::linux::UsbState::PermissionDenied)
            .map(|d| d.dev_path.as_str())
            .collect();
        let busy = devices.iter().any(|d| matches!(d.state, usbmux::linux::UsbState::Busy { .. }));
        let conflict = busy.then(|| if running { "systemTookDevice" } else { "deviceBusy" }.to_owned());
        if !denied.is_empty() && r.detail.is_none() {
            r.detail = Some(format!("permission denied: {}", denied.join(", ")));
        }
        r.linux = Some(LinuxEnv {
            usbmuxd_installed: usbmuxd_installed(),
            usbmuxd_running: running,
            built_in: self.kind == Kind::BuiltIn,
            udev_rule: udev_rule_installed(),
            usb_access: (!devices.is_empty()).then_some(denied.is_empty()),
            usb_devices: devices.len() as u32,
            conflict,
        });
    }
}

/// A unix socket path short enough for `sun_path`: the runtime dir if there
/// is one, else the data dir, else a private folder in /tmp.
#[cfg(unix)]
fn socket_path(data_dir: &Path) -> PathBuf {
    let fits = |p: &Path| p.as_os_str().len() <= 100;
    if let Some(run) = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from) {
        let p = run.join("loopctrl-pair").join("usbmuxd.sock");
        if run.is_dir() && fits(&p) {
            return p;
        }
    }
    let p = data_dir.join("usbmuxd.sock");
    if fits(&p) {
        return p;
    }
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/loopctrl-pair-{uid}/usbmuxd.sock"))
}

fn start_built_in(opts: &Options) -> Result<(UsbmuxdAddr, BuiltIn), String> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("usbmux")
        .enable_all()
        .build()
        .map_err(|e| format!("runtime: {e}"))?;
    let hub = Hub::new(Box::new(FilePairStore::new(opts.data_dir.join("lockdown"))));
    let _guard = rt.enter();

    #[cfg(unix)]
    let (addr, socket) = {
        let path = socket_path(&opts.data_dir);
        if let Some(dir) = path.parent() {
            use std::os::unix::fs::PermissionsExt;
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
            let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
        }
        let std_listener = usbmux::bind_private_socket(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let listener = tokio::net::UnixListener::from_std(std_listener).map_err(|e| e.to_string())?;
        rt.spawn(usbmux::server::serve_unix(listener, hub.clone()));
        (UsbmuxdAddr::UnixSocket(path.to_string_lossy().into_owned()), path)
    };
    #[cfg(not(unix))]
    let addr = {
        let std_listener = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
        std_listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let local = std_listener.local_addr().map_err(|e| e.to_string())?;
        let listener = tokio::net::TcpListener::from_std(std_listener).map_err(|e| e.to_string())?;
        rt.spawn(usbmux::server::serve_tcp(listener, hub.clone()));
        UsbmuxdAddr::TcpSocket(local)
    };

    let bridge = match opts.bridge_listen {
        Some(want) => {
            let std_listener = std::net::TcpListener::bind(want).map_err(|e| format!("bridge {want}: {e}"))?;
            std_listener.set_nonblocking(true).map_err(|e| e.to_string())?;
            let local = std_listener.local_addr().map_err(|e| e.to_string())?;
            let listener = tokio::net::TcpListener::from_std(std_listener).map_err(|e| e.to_string())?;
            rt.spawn(usbmux::bridge::serve_tcp(listener, hub.clone()));
            log::info!("accepting USB bridges on {local}");
            Some(local)
        }
        None => None,
    };

    #[cfg(target_os = "linux")]
    let usb = opts.local_usb.then(|| usbmux::linux::LinuxUsbHost::start(hub.clone()));
    drop(_guard);

    Ok((
        addr,
        BuiltIn {
            #[cfg(target_os = "linux")]
            usb,
            #[cfg(unix)]
            socket,
            bridge,
            _hub: hub,
            rt,
        },
    ))
}

/// A shell command that installs the udev rule with root rights through
/// polkit (`pkexec`), for the desktop app's "install" button.
pub fn udev_install_script() -> String {
    format!(
        "set -e\nmkdir -p /etc/udev/rules.d\ncat > /etc/udev/rules.d/{UDEV_RULE_NAME} <<'LOOPCTRL_RULE'\n{}LOOPCTRL_RULE\nchmod 0644 /etc/udev/rules.d/{UDEV_RULE_NAME}\nudevadm control --reload-rules\nudevadm trigger --subsystem-match=usb --attr-match=idVendor=05ac\n",
        UDEV_RULE
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_parse() {
        assert_eq!("builtin".parse::<MuxMode>(), Ok(MuxMode::BuiltIn));
        assert_eq!("System".parse::<MuxMode>(), Ok(MuxMode::System));
        assert_eq!("auto".parse::<MuxMode>(), Ok(MuxMode::Auto));
        assert!("libusb".parse::<MuxMode>().is_err());
    }

    #[test]
    fn auto_prefers_the_system_usbmuxd() {
        use Kind::*;
        use MuxMode::Auto;
        // decide(mode, linux, env_override, answers, installed, bridge)
        assert_eq!(decide(Auto, false, false, false, false, false), System); // macOS / Windows
        assert_eq!(decide(Auto, true, false, true, true, false), System); // running
        assert_eq!(decide(Auto, true, false, false, true, false), System); // starts on plug
        assert_eq!(decide(Auto, true, false, false, false, false), BuiltIn); // nothing installed
        assert_eq!(decide(Auto, true, true, false, false, false), System); // USBMUXD_SOCKET_ADDRESS
        assert_eq!(decide(Auto, false, false, true, true, true), BuiltIn); // bridges
        assert_eq!(decide(MuxMode::BuiltIn, true, false, true, true, false), BuiltIn);
        assert_eq!(decide(MuxMode::System, true, false, false, false, false), System);
    }

    #[test]
    fn finds_an_installed_usbmuxd() {
        let root = std::env::temp_dir().join(format!("pair-host-root-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("usr/lib/udev/rules.d")).unwrap();
        assert!(!usbmuxd_installed_under(&root));
        std::fs::write(root.join("usr/lib/udev/rules.d/39-usbmuxd.rules"), "").unwrap();
        assert!(usbmuxd_installed_under(&root));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_udev_rule_covers_usbmux_devices() {
        assert!(UDEV_RULE.contains("ATTR{idVendor}==\"05ac\""));
        assert!(UDEV_RULE.contains("12[9a][0-9a-f]"));
        assert!(UDEV_RULE.contains("TAG+=\"uaccess\""));
        let script = udev_install_script();
        assert!(script.contains("/etc/udev/rules.d/70-loopctrl-pair.rules"));
        assert!(script.contains("udevadm control --reload-rules"));
    }

    #[test]
    fn built_in_serves_a_socket_and_bridges() {
        let dir = std::env::temp_dir().join(format!("ph-{}", std::process::id()));
        let opts = Options {
            mode: MuxMode::BuiltIn,
            data_dir: dir.clone(),
            bridge_listen: Some("127.0.0.1:0".parse().unwrap()),
            local_usb: false,
        };
        let t = Transport::start(&opts).unwrap();
        assert_eq!(t.kind(), Kind::BuiltIn);
        assert!(t.bridge_addr().is_some());
        // pair-core sees a working usbmuxd with no devices.
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let r = rt.block_on(pair_core::env::check_usbmux_at(t.addr()));
        assert!(r.usbmux_ok, "{r:?}");
        drop(t);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
