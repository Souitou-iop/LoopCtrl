//! The USB side of the built-in usbmuxd on desktop Linux (and Raspberry Pi
//! class boards): what Android's `UsbHost.kt` does through `UsbManager`, done
//! with sysfs and usbfs directly. No libusb, no udev library, nothing GPL.
//!
//! * Finds iPhones by polling `/sys/bus/usb/devices` once a second (Apple
//!   vendor id, the product ids usbmuxd accepts).
//! * Reads every configuration from the world-readable sysfs `descriptors`
//!   file and picks the one with the usbmux interface (class 255, subclass
//!   254, protocol 2): the active one if it has it, otherwise the one with the
//!   fewest interfaces, like the Android host.
//! * Opens `/dev/bus/usb/BBB/DDD` read-write (needs the udev rule in
//!   packaging/linux, or root), switches the configuration if needed (kernel
//!   drivers of the old one are unbound first, as usbmuxd does), claims the
//!   interface and hands a [`UsbfsPipe`] to the [`Hub`].
//! * If the interface is held already, usually by the system usbmuxd, the
//!   device is reported as [`UsbState::Busy`] instead of fighting over it.
//!
//! Parsing is platform independent (and tested everywhere); opening devices
//! is Linux only.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::hub::{DeviceInfo, Hub, udid_from_serial};

pub const APPLE_VENDOR_ID: u16 = 0x05ac;
pub const SYSFS_USB_DEVICES: &str = "/sys/bus/usb/devices";

const MUX_CLASS: u8 = 255;
const MUX_SUBCLASS: u8 = 254;
const MUX_PROTOCOL: u8 = 2;
const SCAN_INTERVAL: Duration = Duration::from_secs(1);
/// After a failed attach, wait this long before trying the same device again.
const RETRY_AFTER: Duration = Duration::from_secs(5);

/// The product id range usbmuxd accepts (iPhone, iPad, iPod touch).
pub fn is_mux_product(product_id: u16) -> bool {
    (0x1290..=0x12af).contains(&product_id) || (0x1901..=0x1905).contains(&product_id)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub address: u8,
    pub attributes: u8,
    pub max_packet: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Interface {
    pub number: u8,
    pub alternate: u8,
    pub class: u8,
    pub subclass: u8,
    pub protocol: u8,
    pub endpoints: Vec<Endpoint>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Configuration {
    pub value: u8,
    pub interfaces: Vec<Interface>,
}

/// Where to talk usbmux on a device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MuxInterface {
    pub configuration: u8,
    pub interface: u8,
    pub ep_in: u8,
    pub ep_out: u8,
    pub max_packet_out: u16,
    /// Interface numbers of that configuration (drivers to unbind on a switch).
    pub siblings: Vec<u8>,
}

/// Parses the sysfs `descriptors` file: the device descriptor followed by
/// every configuration descriptor with its interfaces and endpoints.
pub fn parse_descriptors(raw: &[u8]) -> Vec<Configuration> {
    let mut configs = Vec::new();
    let mut i = 0;
    while i + 2 <= raw.len() {
        let len = raw[i] as usize;
        if len < 2 || i + len > raw.len() {
            break;
        }
        let kind = raw[i + 1];
        let d = &raw[i..i + len];
        match kind {
            2 if len >= 9 => configs.push(Configuration {
                value: d[5],
                interfaces: Vec::new(),
            }),
            4 if len >= 9 => {
                if let Some(c) = configs.last_mut() {
                    c.interfaces.push(Interface {
                        number: d[2],
                        alternate: d[3],
                        class: d[5],
                        subclass: d[6],
                        protocol: d[7],
                        endpoints: Vec::new(),
                    });
                }
            }
            5 if len >= 7 => {
                if let Some(intf) = configs.last_mut().and_then(|c| c.interfaces.last_mut()) {
                    intf.endpoints.push(Endpoint {
                        address: d[2],
                        attributes: d[3],
                        max_packet: u16::from_le_bytes([d[4], d[5]]) & 0x7ff,
                    });
                }
            }
            _ => {}
        }
        i += len;
    }
    configs
}

fn mux_in(config: &Configuration) -> Option<MuxInterface> {
    let intf = config.interfaces.iter().find(|i| {
        i.alternate == 0
            && (i.class, i.subclass, i.protocol) == (MUX_CLASS, MUX_SUBCLASS, MUX_PROTOCOL)
            && i.endpoints.len() == 2
    })?;
    let bulk = |dir_in: bool| {
        intf.endpoints
            .iter()
            .find(|e| e.attributes & 3 == 2 && (e.address & 0x80 != 0) == dir_in)
    };
    let (ep_in, ep_out) = (bulk(true)?, bulk(false)?);
    let mut siblings: Vec<u8> = config.interfaces.iter().map(|i| i.number).collect();
    siblings.sort_unstable();
    siblings.dedup();
    Some(MuxInterface {
        configuration: config.value,
        interface: intf.number,
        ep_in: ep_in.address,
        ep_out: ep_out.address,
        max_packet_out: ep_out.max_packet.max(1),
        siblings,
    })
}

/// The usbmux interface to use: in the active configuration if it has one
/// (no switch, so tethering and the like keep working), otherwise in the
/// configuration with the fewest interfaces.
pub fn choose_mux(configs: &[Configuration], active: Option<u8>) -> Option<MuxInterface> {
    if let Some(found) = configs
        .iter()
        .filter(|c| Some(c.value) == active)
        .find_map(mux_in)
    {
        return Some(found);
    }
    configs
        .iter()
        .filter_map(|c| mux_in(c).map(|m| (m.siblings.len(), m)))
        .min_by_key(|(n, _)| *n)
        .map(|(_, m)| m)
}

/// An Apple mobile device seen in sysfs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbCandidate {
    /// sysfs name, "1-2.3".
    pub name: String,
    pub busnum: u32,
    pub devnum: u32,
    pub product_id: u16,
    pub serial: String,
    /// Mbit/s.
    pub speed_mbps: u32,
    pub active_config: Option<u8>,
    pub sysfs: PathBuf,
}

impl UsbCandidate {
    pub fn dev_path(&self) -> PathBuf {
        PathBuf::from(format!(
            "/dev/bus/usb/{:03}/{:03}",
            self.busnum, self.devnum
        ))
    }

    pub fn location_id(&self) -> u32 {
        (self.busnum << 16) | self.devnum
    }

    pub fn descriptors(&self) -> std::io::Result<Vec<Configuration>> {
        Ok(parse_descriptors(&std::fs::read(
            self.sysfs.join("descriptors"),
        )?))
    }

    /// Driver bound to one of this device's interfaces in the active
    /// configuration ("usbfs" means a user-space program such as usbmuxd).
    pub fn interface_driver(&self, config: u8, interface: u8) -> Option<String> {
        let dir = self
            .sysfs
            .join(format!("{}:{config}.{interface}", self.name));
        let link = std::fs::read_link(dir.join("driver")).ok()?;
        link.file_name().map(|n| n.to_string_lossy().into_owned())
    }
}

fn attr(dir: &Path, name: &str) -> Option<String> {
    std::fs::read_to_string(dir.join(name))
        .ok()
        .map(|s| s.trim().to_owned())
}

/// Apple devices that speak usbmux, from a sysfs tree such as
/// `/sys/bus/usb/devices`.
pub fn scan(root: &Path) -> Vec<UsbCandidate> {
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        // Interfaces ("1-2:1.0") and root hubs' interfaces are not devices.
        if name.contains(':') {
            continue;
        }
        let dir = entry.path();
        let hex = |n: &str| attr(&dir, n).and_then(|v| u16::from_str_radix(&v, 16).ok());
        if hex("idVendor") != Some(APPLE_VENDOR_ID) {
            continue;
        }
        let Some(product_id) = hex("idProduct").filter(|p| is_mux_product(*p)) else {
            continue;
        };
        let num = |n: &str| attr(&dir, n).and_then(|v| v.parse::<u32>().ok());
        let (Some(busnum), Some(devnum)) = (num("busnum"), num("devnum")) else {
            continue;
        };
        out.push(UsbCandidate {
            name,
            busnum,
            devnum,
            product_id,
            serial: attr(&dir, "serial").unwrap_or_default(),
            speed_mbps: attr(&dir, "speed")
                .and_then(|v| v.parse::<f32>().ok())
                .unwrap_or(480.0) as u32,
            active_config: attr(&dir, "bConfigurationValue").and_then(|v| v.parse().ok()),
            sysfs: dir,
        });
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// What happened to one iPhone the host found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UsbState {
    Opening,
    /// Handed to the hub under this id.
    Attached(u32),
    /// `/dev/bus/usb/...` could not be opened: no udev rule (or not root).
    PermissionDenied,
    /// The usbmux interface is held by someone else; `holder` is the driver
    /// name sysfs reports ("usbfs": another program, most likely usbmuxd).
    Busy {
        holder: Option<String>,
    },
    NoMuxInterface,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbDeviceStatus {
    pub name: String,
    pub dev_path: String,
    pub udid: String,
    pub product_id: u16,
    pub state: UsbState,
}

struct Tracked {
    devnum: u32,
    status: UsbDeviceStatus,
    since: Instant,
}

/// Watches sysfs and keeps the hub's USB devices in step with what is
/// plugged in. Dropping it stops the scan (attached devices stay until
/// unplugged).
pub struct LinuxUsbHost {
    tracked: Arc<Mutex<HashMap<String, Tracked>>>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for LinuxUsbHost {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl LinuxUsbHost {
    /// Starts scanning on the current tokio runtime.
    pub fn start(hub: Hub) -> Self {
        Self::start_at(hub, PathBuf::from(SYSFS_USB_DEVICES))
    }

    pub fn start_at(hub: Hub, root: PathBuf) -> Self {
        let tracked: Arc<Mutex<HashMap<String, Tracked>>> = Arc::default();
        let t = tracked.clone();
        let task = tokio::spawn(async move {
            loop {
                Self::tick(&hub, &root, &t);
                tokio::time::sleep(SCAN_INTERVAL).await;
            }
        });
        LinuxUsbHost { tracked, task }
    }

    /// Every iPhone seen, with what became of it.
    pub fn status(&self) -> Vec<UsbDeviceStatus> {
        let mut v: Vec<_> = self
            .tracked
            .lock()
            .unwrap()
            .values()
            .map(|t| t.status.clone())
            .collect();
        v.sort_by(|a, b| a.name.cmp(&b.name));
        v
    }

    fn tick(hub: &Hub, root: &Path, tracked: &Arc<Mutex<HashMap<String, Tracked>>>) {
        let found = scan(root);
        let attached: Vec<u32> = hub.devices().iter().map(|d| d.id).collect();
        let mut map = tracked.lock().unwrap();
        // Gone, or replugged (new devnum): forget, detach from the hub.
        map.retain(|name, t| {
            let still = found
                .iter()
                .any(|c| &c.name == name && c.devnum == t.devnum);
            if !still {
                if let UsbState::Attached(id) = t.status.state {
                    hub.remove_device(id);
                }
            }
            still
        });
        for cand in found {
            let retry = match map.get(&cand.name) {
                None => true,
                Some(t) => match t.status.state {
                    UsbState::Opening => false,
                    // The link dropped (handshake failure, I/O error) but the
                    // device is still there: try again.
                    UsbState::Attached(id) => !attached.contains(&id),
                    _ => t.since.elapsed() >= RETRY_AFTER,
                },
            };
            if !retry {
                continue;
            }
            let status = UsbDeviceStatus {
                name: cand.name.clone(),
                dev_path: cand.dev_path().display().to_string(),
                udid: udid_from_serial(&cand.serial),
                product_id: cand.product_id,
                state: UsbState::Opening,
            };
            map.insert(
                cand.name.clone(),
                Tracked {
                    devnum: cand.devnum,
                    status,
                    since: Instant::now(),
                },
            );
            let (hub, tracked) = (hub.clone(), tracked.clone());
            tokio::spawn(async move {
                let state = attach(&hub, &cand).await;
                match &state {
                    UsbState::Attached(_) => tracing::info!("usb {}: attached", cand.name),
                    s => tracing::warn!("usb {} ({}): {s:?}", cand.name, cand.dev_path().display()),
                }
                if let Some(t) = tracked.lock().unwrap().get_mut(&cand.name) {
                    if t.devnum == cand.devnum {
                        t.status.state = state;
                        t.since = Instant::now();
                    }
                }
            });
        }
    }
}

async fn attach(hub: &Hub, cand: &UsbCandidate) -> UsbState {
    let c = cand.clone();
    let opened = tokio::task::spawn_blocking(move || open::open(&c)).await;
    let pipe = match opened {
        Ok(Ok(pipe)) => pipe,
        Ok(Err(state)) => return state,
        Err(e) => return UsbState::Failed(e.to_string()),
    };
    let info = DeviceInfo {
        udid: udid_from_serial(&cand.serial),
        product_id: cand.product_id,
        location_id: cand.location_id(),
        speed: u64::from(cand.speed_mbps) * 1_000_000,
    };
    match hub.add_device(pipe, info).await {
        Ok(id) => UsbState::Attached(id),
        Err(e) => UsbState::Failed(e.to_string()),
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod open {
    use std::ffi::c_void;
    use std::fs::OpenOptions;
    use std::io;
    use std::os::fd::{AsRawFd, OwnedFd};
    use std::os::unix::fs::OpenOptionsExt;
    use std::sync::Arc;

    use super::{UsbCandidate, UsbState, choose_mux};
    use crate::pipe::UsbPipe;
    use crate::usbfs::*;

    fn ioctl(fd: &OwnedFd, request: u32, arg: *mut c_void) -> io::Result<i32> {
        loop {
            // SAFETY: callers pass a pointer to the structure `request` expects.
            let r = unsafe { libc::ioctl(fd.as_raw_fd(), request as _, arg) };
            if r >= 0 {
                return Ok(r);
            }
            let e = io::Error::last_os_error();
            if e.kind() != io::ErrorKind::Interrupted {
                return Err(e);
            }
        }
    }

    fn driver_of(fd: &OwnedFd, interface: u8) -> Option<String> {
        let mut gd = GetDriver {
            interface: u32::from(interface),
            driver: [0; 256],
        };
        ioctl(fd, USBDEVFS_GETDRIVER, &mut gd as *mut _ as *mut c_void).ok()?;
        let end = gd
            .driver
            .iter()
            .position(|b| *b == 0)
            .unwrap_or(gd.driver.len());
        Some(String::from_utf8_lossy(&gd.driver[..end]).into_owned())
    }

    /// Unbinds the kernel driver of an interface (ENODATA: there is none).
    fn disconnect(fd: &OwnedFd, interface: u8) -> io::Result<()> {
        let mut req = UsbIoctl {
            ifno: i32::from(interface),
            ioctl_code: USBDEVFS_DISCONNECT as i32,
            data: std::ptr::null_mut(),
        };
        match ioctl(fd, USBDEVFS_IOCTL, &mut req as *mut _ as *mut c_void) {
            Err(e) if e.raw_os_error() == Some(libc::ENODATA) => Ok(()),
            r => r.map(|_| ()),
        }
    }

    pub(super) fn open(c: &UsbCandidate) -> Result<Arc<dyn UsbPipe>, UsbState> {
        let configs = c
            .descriptors()
            .map_err(|e| UsbState::Failed(format!("descriptors: {e}")))?;
        let mux = choose_mux(&configs, c.active_config).ok_or(UsbState::NoMuxInterface)?;
        // Held by another program already? Do not touch the device at all.
        if c.active_config == Some(mux.configuration)
            && c.interface_driver(mux.configuration, mux.interface)
                .as_deref()
                == Some("usbfs")
        {
            return Err(UsbState::Busy {
                holder: Some("usbfs".into()),
            });
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_CLOEXEC)
            .open(c.dev_path())
            .map_err(|e| match e.kind() {
                io::ErrorKind::PermissionDenied => UsbState::PermissionDenied,
                _ => UsbState::Failed(format!("open {}: {e}", c.dev_path().display())),
            })?;
        let fd: OwnedFd = file.into();

        if c.active_config != Some(mux.configuration) {
            if let Some(active) = c.active_config {
                if let Some(cfg) = configs.iter().find(|x| x.value == active) {
                    let mut numbers: Vec<u8> = cfg.interfaces.iter().map(|i| i.number).collect();
                    numbers.dedup();
                    for n in numbers {
                        if driver_of(&fd, n).as_deref() == Some("usbfs") {
                            return Err(UsbState::Busy {
                                holder: Some("usbfs".into()),
                            });
                        }
                        let _ = disconnect(&fd, n);
                    }
                }
            }
            let mut value = u32::from(mux.configuration);
            ioctl(
                &fd,
                USBDEVFS_SETCONFIGURATION,
                &mut value as *mut _ as *mut c_void,
            )
            .map_err(|e| {
                if e.raw_os_error() == Some(libc::EBUSY) {
                    UsbState::Busy { holder: None }
                } else {
                    UsbState::Failed(format!("set configuration {}: {e}", mux.configuration))
                }
            })?;
        }

        match driver_of(&fd, mux.interface).as_deref() {
            Some("usbfs") => {
                return Err(UsbState::Busy {
                    holder: Some("usbfs".into()),
                });
            }
            Some(_) => {
                let _ = disconnect(&fd, mux.interface);
            }
            None => {}
        }
        let mut ifno = u32::from(mux.interface);
        ioctl(
            &fd,
            USBDEVFS_CLAIMINTERFACE,
            &mut ifno as *mut _ as *mut c_void,
        )
        .map_err(|e| {
            if e.raw_os_error() == Some(libc::EBUSY) {
                UsbState::Busy {
                    holder: driver_of(&fd, mux.interface),
                }
            } else {
                UsbState::Failed(format!("claim interface {}: {e}", mux.interface))
            }
        })?;
        let pipe = UsbfsPipe::new(fd, mux.ep_in, mux.ep_out, usize::from(mux.max_packet_out));
        Ok(Arc::new(pipe))
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
mod open {
    use std::sync::Arc;

    use super::{UsbCandidate, UsbState};
    use crate::pipe::UsbPipe;

    pub(super) fn open(_c: &UsbCandidate) -> Result<Arc<dyn UsbPipe>, UsbState> {
        Err(UsbState::Failed("usbfs is only available on Linux".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Descriptors of an iPhone as Linux reports them: configuration 1 (PTP),
    /// 2 (PTP + audio), 3 (PTP + usbmux), 4 (PTP + usbmux + Ethernet).
    /// Interface number, class, subclass, protocol, endpoints (address, attributes).
    type Intf<'a> = (u8, u8, u8, u8, &'a [(u8, u8)]);

    pub fn iphone_descriptors() -> Vec<u8> {
        let mut d = vec![
            18, 1, 0, 2, 0, 0, 0, 64, 0xac, 0x05, 0xa8, 0x12, 0, 0x16, 1, 2, 3, 4,
        ];
        let cfg = |value: u8, interfaces: &[Intf]| {
            let mut body = Vec::new();
            for &(num, class, sub, proto, eps) in interfaces {
                body.extend_from_slice(&[9, 4, num, 0, eps.len() as u8, class, sub, proto, 0]);
                for &(addr, attrs) in eps {
                    body.extend_from_slice(&[7, 5, addr, attrs, 0x00, 0x02, 0]);
                }
            }
            let total = (9 + body.len()) as u16;
            let mut out = vec![
                9,
                2,
                total as u8,
                (total >> 8) as u8,
                interfaces.len() as u8,
                value,
                0,
                0xc0,
                250,
            ];
            out.extend(body);
            out
        };
        let ptp: Intf = (0, 6, 1, 1, &[(0x81, 2), (0x02, 2), (0x83, 3)]);
        let mux: Intf = (1, 255, 254, 2, &[(0x84, 2), (0x05, 2)]);
        let eth: Intf = (2, 255, 253, 1, &[(0x86, 2), (0x07, 2)]);
        let audio: Intf = (1, 1, 1, 0, &[]);
        d.extend(cfg(1, &[ptp]));
        d.extend(cfg(2, &[ptp, audio]));
        d.extend(cfg(3, &[ptp, mux]));
        d.extend(cfg(4, &[ptp, mux, eth]));
        d
    }

    #[test]
    fn parses_every_configuration() {
        let configs = parse_descriptors(&iphone_descriptors());
        assert_eq!(
            configs.iter().map(|c| c.value).collect::<Vec<_>>(),
            vec![1, 2, 3, 4]
        );
        assert_eq!(
            configs[2].interfaces[1].endpoints[0],
            Endpoint {
                address: 0x84,
                attributes: 2,
                max_packet: 512
            }
        );
    }

    #[test]
    fn keeps_the_active_configuration_when_it_has_usbmux() {
        let configs = parse_descriptors(&iphone_descriptors());
        let m = choose_mux(&configs, Some(4)).unwrap();
        assert_eq!(
            (
                m.configuration,
                m.interface,
                m.ep_in,
                m.ep_out,
                m.max_packet_out
            ),
            (4, 1, 0x84, 0x05, 512)
        );
        assert_eq!(m.siblings, vec![0, 1, 2]);
    }

    #[test]
    fn otherwise_picks_the_smallest_configuration_with_usbmux() {
        let configs = parse_descriptors(&iphone_descriptors());
        assert_eq!(choose_mux(&configs, Some(1)).unwrap().configuration, 3);
        assert_eq!(choose_mux(&configs, None).unwrap().configuration, 3);
        assert_eq!(choose_mux(&configs[..2], Some(1)), None);
    }

    #[test]
    fn truncated_descriptors_do_not_panic() {
        let raw = iphone_descriptors();
        for n in 0..raw.len() {
            let _ = parse_descriptors(&raw[..n]);
        }
        assert!(parse_descriptors(&[0, 0, 0]).is_empty());
    }

    #[test]
    fn product_ids_match_usbmuxd() {
        assert!(is_mux_product(0x12a8));
        assert!(is_mux_product(0x1905));
        assert!(!is_mux_product(0x12b0));
        assert!(!is_mux_product(0x8600));
    }

    fn fake_sysfs(dir: &Path, name: &str, vendor: &str, product: &str) {
        let d = dir.join(name);
        std::fs::create_dir_all(&d).unwrap();
        for (k, v) in [
            ("idVendor", vendor),
            ("idProduct", product),
            ("busnum", "3"),
            ("devnum", "12"),
            ("serial", "00008030001C1D2E0A68802E"),
            ("speed", "480"),
            ("bConfigurationValue", "4"),
        ] {
            std::fs::write(d.join(k), format!("{v}\n")).unwrap();
        }
        std::fs::write(d.join("descriptors"), iphone_descriptors()).unwrap();
    }

    #[test]
    fn scans_a_sysfs_tree() {
        let tmp = std::env::temp_dir().join(format!("usbmux-sysfs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        fake_sysfs(&tmp, "3-1", "05ac", "12a8");
        fake_sysfs(&tmp, "3-2", "046d", "c52b"); // a mouse
        fake_sysfs(&tmp, "3-3", "05ac", "8600"); // an Apple keyboard hub
        // An interface entry, skipped by the scan (no colons in names on Windows).
        #[cfg(unix)]
        std::fs::create_dir_all(tmp.join("3-1:4.1")).unwrap();
        let found = scan(&tmp);
        assert_eq!(found.len(), 1);
        let c = &found[0];
        assert_eq!(
            (c.name.as_str(), c.busnum, c.devnum, c.product_id),
            ("3-1", 3, 12, 0x12a8)
        );
        assert_eq!(c.dev_path(), PathBuf::from("/dev/bus/usb/003/012"));
        assert_eq!(c.location_id(), (3 << 16) | 12);
        assert_eq!(c.active_config, Some(4));
        assert_eq!(udid_from_serial(&c.serial), "00008030-001C1D2E0A68802E");
        assert_eq!(
            choose_mux(&c.descriptors().unwrap(), c.active_config)
                .unwrap()
                .configuration,
            4
        );
        assert_eq!(c.interface_driver(4, 1), None);
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
