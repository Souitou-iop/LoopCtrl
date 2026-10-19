//! Environment check: is there a usbmuxd to talk to?
//!
//! * Windows: Apple Mobile Device Service on 127.0.0.1:27015, installed with
//!   Apple Devices (Microsoft Store) or iTunes. We cannot ship Apple's driver.
//! * macOS: the system usbmuxd at /var/run/usbmuxd, always there.
//! * Android: the app's built-in usbmuxd (crates/usbmux) on a private socket.
//! * Linux: the system usbmuxd if the user installed it, otherwise the
//!   app's built-in one over usbfs (crates/pair-host decides and fills in
//!   [`LinuxEnv`](crate::LinuxEnv)).
//!
//! `USBMUXD_SOCKET_ADDRESS` overrides the address (idevice convention).

use std::time::Duration;

use idevice::usbmuxd::UsbmuxdAddr;

use crate::model::EnvReport;

/// Microsoft Store product page of Apple Devices.
pub const APPLE_DEVICES_STORE_URL: &str = "ms-windows-store://pdp/?ProductId=9NP83LWLPZ9K";
pub const APPLE_DEVICES_WEB_URL: &str = "https://apps.microsoft.com/detail/9NP83LWLPZ9K";

pub fn host_os() -> EnvReport {
    let info = os_info::get();
    let os = if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "android") {
        "android"
    } else {
        "linux"
    };
    EnvReport {
        os: os.into(),
        os_version: info.version().to_string(),
        usbmux_ok: false,
        usbmux_addr: String::new(),
        detail: None,
        transport: String::new(),
        linux: None,
    }
}

fn describe(addr: &UsbmuxdAddr) -> String {
    match addr {
        #[cfg(unix)]
        UsbmuxdAddr::UnixSocket(p) => p.clone(),
        UsbmuxdAddr::TcpSocket(a) => a.to_string(),
    }
}

/// Connects to usbmuxd and lists devices once.
pub async fn check_usbmux() -> EnvReport {
    check_usbmux_at(UsbmuxdAddr::from_env_var().unwrap_or_default()).await
}

/// Same, for a usbmuxd at `addr`.
pub async fn check_usbmux_at(addr: UsbmuxdAddr) -> EnvReport {
    let mut r = host_os();
    r.usbmux_addr = describe(&addr);
    let probe = async {
        let mut c = addr.connect(0).await?;
        c.get_devices().await.map(|_| ())
    };
    match tokio::time::timeout(Duration::from_millis(2500), probe).await {
        Ok(Ok(())) => r.usbmux_ok = true,
        Ok(Err(e)) => r.detail = Some(e.to_string()),
        Err(_) => r.detail = Some("timed out".into()),
    }
    r
}
