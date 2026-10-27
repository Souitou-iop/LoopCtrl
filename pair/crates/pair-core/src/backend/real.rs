//! The real backend: idevice over usbmuxd (macOS system daemon, Windows Apple
//! Mobile Device Service, the app's built-in one on Android).

use std::future::Future;
use std::pin::Pin;

use futures_util::StreamExt;
use idevice::afc::opcode::AfcFopenMode;
use idevice::amfi::AmfiClient;
use idevice::core_device_proxy::CoreDeviceProxy;
use idevice::house_arrest::HouseArrestClient;
use idevice::installation_proxy::InstallationProxyClient;
use idevice::lockdown::LockdownClient;
use idevice::pairing_file::PairingFile;
use idevice::provider::{IdeviceProvider, UsbmuxdProvider};
use idevice::remote_pairing::{
    RemotePairingClient, RemotePairingLockdownService, RpPairingFile, RpPairingSocketProvider,
};
use idevice::rsd::RsdHandshake;
use idevice::usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection, UsbmuxdDevice, UsbmuxdListenEvent};
use idevice::{Idevice, IdeviceError, IdeviceService, RemoteXpcClient};
use tokio::sync::mpsc::UnboundedSender;

use super::{AppList, Backend, DeviceConn, TrustResult, WatchEvent};
use crate::cache::HostIdentity;
use crate::model::*;
use crate::record::{DROPBOX_DIR, DROPBOX_FILE, DROPBOX_TEMP_FILE};

/// Label idevice sends with every lockdown request.
const LABEL: &str = "LoopCtrl-Pair";
/// What the phone lists under trusted computers.
const PAIR_HOST_NAME: &str = "LoopCtrl Pair";
const UNTRUSTED_TUNNEL_SERVICE: &str = "com.apple.internal.dt.coredevice.untrusted.tunnelservice";

#[derive(Debug, Clone)]
pub struct RealBackend {
    addr: UsbmuxdAddr,
    allow_network: bool,
}

impl Default for RealBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl RealBackend {
    pub fn new() -> Self {
        Self::at(UsbmuxdAddr::from_env_var().unwrap_or_default())
    }

    /// usbmuxd at `addr` (Android: the built-in one's private socket).
    pub fn at(addr: UsbmuxdAddr) -> Self {
        Self { addr, allow_network: false }
    }

    /// Testing only: also take Wi-Fi devices that usbmuxd already has a pair
    /// record for. A first Trust is impossible over the network (lockdownd
    /// answers `PairingProhibitedOverThisConnection`), so v1 ships USB only.
    pub fn allow_network(mut self, on: bool) -> Self {
        self.allow_network = on;
        self
    }
}

fn err(code: ErrorCode, what: &str, e: impl std::fmt::Display) -> PairError {
    PairError::new(code, format!("{what}: {e}"))
}

/// Maps an idevice error, keeping the codes the UI explains on their own.
fn map(code: ErrorCode, what: &str, e: IdeviceError) -> PairError {
    match e {
        IdeviceError::UserDeniedPairing => err(ErrorCode::Untrusted, what, e),
        IdeviceError::DeviceNotFound => err(ErrorCode::Disconnected, what, e),
        e => err(code, what, e),
    }
}

impl Backend for RealBackend {
    type Conn = RealConn;

    async fn env_check(&self) -> EnvReport {
        crate::env::check_usbmux_at(self.addr.clone()).await
    }

    async fn watch(&self, tx: UnboundedSender<WatchEvent>) -> Result<(), PairError> {
        let usbmux = |e| err(ErrorCode::NoUsbmux, "usbmuxd", e);
        let mut conn = self.addr.connect(1).await.map_err(usbmux)?;
        let mut events = conn.listen().await.map_err(usbmux)?;
        while let Some(ev) = events.next().await {
            let ev = ev.map_err(usbmux)?;
            let out = match ev {
                // Wi-Fi sync devices show up too; v1 is USB only.
                UsbmuxdListenEvent::Connected(UsbmuxdDevice { connection_type: Connection::Usb, udid, device_id }) => {
                    WatchEvent::Attached(AttachedDevice { udid, mux_id: device_id })
                }
                UsbmuxdListenEvent::Connected(UsbmuxdDevice {
                    connection_type: Connection::Network(_),
                    udid,
                    device_id,
                }) if self.allow_network => WatchEvent::Attached(AttachedDevice { udid, mux_id: device_id }),
                UsbmuxdListenEvent::Connected(_) => continue,
                UsbmuxdListenEvent::Disconnected(mux_id) => WatchEvent::Detached { mux_id },
            };
            if tx.send(out).is_err() {
                return Ok(());
            }
        }
        Err(PairError::new(ErrorCode::NoUsbmux, "usbmuxd closed the listen connection"))
    }

    fn open(&self, dev: &AttachedDevice) -> RealConn {
        RealConn { provider: self.provider(dev), addr: self.addr.clone(), record: None }
    }
}

impl RealBackend {
    fn provider(&self, dev: &AttachedDevice) -> UsbmuxdProvider {
        UsbmuxdDevice { connection_type: Connection::Usb, udid: dev.udid.clone(), device_id: dev.mux_id }
            .to_provider(self.addr.clone(), LABEL)
    }
}

/// usbmuxd provider that hands out our own lockdown record when we have one,
/// instead of asking usbmuxd for its copy.
#[derive(Debug)]
struct Paired<'a> {
    inner: &'a UsbmuxdProvider,
    record: Option<PairingFile>,
}

impl IdeviceProvider for Paired<'_> {
    fn connect(&self, port: u16) -> Pin<Box<dyn Future<Output = Result<Idevice, IdeviceError>> + Send>> {
        self.inner.connect(port)
    }

    fn label(&self) -> &str {
        self.inner.label()
    }

    fn get_pairing_file(&self) -> Pin<Box<dyn Future<Output = Result<PairingFile, IdeviceError>> + Send>> {
        match &self.record {
            Some(r) => {
                let r = r.clone();
                Box::pin(async move { Ok(r) })
            }
            None => self.inner.get_pairing_file(),
        }
    }
}

pub struct RealConn {
    provider: UsbmuxdProvider,
    addr: UsbmuxdAddr,
    record: Option<PairingFile>,
}

impl RealConn {
    fn paired(&self) -> Paired<'_> {
        Paired { inner: &self.provider, record: self.record.clone() }
    }

    fn udid(&self) -> &str {
        &self.provider.udid
    }

    /// Lockdown client with a TLS session, using our record.
    async fn session(&self) -> Result<LockdownClient, PairError> {
        let p = self.paired();
        let record = p.get_pairing_file().await.map_err(|e| map(ErrorCode::Internal, "pair record", e))?;
        let mut l = LockdownClient::connect(&p).await.map_err(|e| map(ErrorCode::Disconnected, "lockdown", e))?;
        l.start_session(&record).await.map_err(|e| map(ErrorCode::Internal, "StartSession", e))?;
        Ok(l)
    }

    fn serialize(&self, record: &PairingFile) -> Result<Vec<u8>, PairError> {
        let mut r = record.clone();
        r.udid = Some(self.udid().to_owned());
        r.serialize().map_err(|e| err(ErrorCode::Internal, "serialize lockdown record", e))
    }

    /// Does the phone still accept usbmuxd's record for it?
    async fn existing_record(&self) -> Option<PairingFile> {
        let record = self.provider.get_pairing_file().await.ok()?;
        let mut l = LockdownClient::connect(&self.provider).await.ok()?;
        l.start_session(&record).await.ok()?;
        Some(record)
    }

    /// RP client over the CoreDeviceProxy software tunnel, kept alive while
    /// `f` runs. Used when `remotepairingdeviced.lockdown` is missing.
    async fn via_tunnel<T>(
        &self,
        host: &HostIdentity,
        f: impl AsyncFnOnce(
            &mut RemotePairingClient<RemoteXpcClient<Box<dyn idevice::ReadWrite>>>,
        ) -> Result<T, IdeviceError>,
    ) -> Result<T, IdeviceError> {
        let proxy = CoreDeviceProxy::connect(&self.paired()).await?;
        let rsd_port = proxy.tunnel_info().server_rsd_port;
        let adapter = proxy.create_software_tunnel()?;
        let mut adapter = adapter.to_async_handle();
        let rsd = adapter.connect(rsd_port).await?;
        let handshake = RsdHandshake::new(rsd).await?;
        let svc = handshake.services.get(UNTRUSTED_TUNNEL_SERVICE).ok_or(IdeviceError::ServiceNotFound)?;
        let stream = adapter.connect(svc.port).await?;
        let stream: Box<dyn idevice::ReadWrite> = Box::new(stream);
        let mut xpc = RemoteXpcClient::new(stream).await?;
        xpc.do_handshake().await?;
        let _ = xpc.recv_root().await;
        let mut client = RemotePairingClient::new(xpc, &host.host_name);
        f(&mut client).await
    }
}

/// Pair-setup, or reuse `cached` if the phone still verifies it. Returns the
/// record and whether it was the cached one.
async fn rp_pair<R: RpPairingSocketProvider>(
    client: &mut RemotePairingClient<R>,
    host: &HostIdentity,
    cached: Option<&[u8]>,
) -> Result<(Vec<u8>, bool), IdeviceError> {
    // Over the trusted USB transport there is no prompt, so no PIN is asked.
    let pin = async || "000000".to_string();
    if let Some(mut c) = cached.and_then(|b| RpPairingFile::from_bytes(b).ok()) {
        client.attempt_pair_verify().await?;
        if client.validate_pairing(&mut c).await.is_ok() {
            return Ok((c.to_bytes(), true));
        }
        let mut fresh = RpPairingFile::generate(&host.host_name);
        client.pair(&mut fresh, pin).await?;
        return Ok((fresh.to_bytes(), false));
    }
    let mut fresh = RpPairingFile::generate(&host.host_name);
    client.connect(&mut fresh, pin).await?;
    Ok((fresh.to_bytes(), false))
}

async fn rp_verify<R: RpPairingSocketProvider>(
    client: &mut RemotePairingClient<R>,
    rp: &[u8],
) -> Result<(), IdeviceError> {
    let mut file = RpPairingFile::from_bytes(rp)?;
    client.attempt_pair_verify().await?;
    client.validate_pairing(&mut file).await
}

impl DeviceConn for RealConn {
    fn rebind(&mut self, dev: &AttachedDevice) {
        self.provider.device_id = dev.mux_id;
        self.provider.tag = dev.mux_id;
    }

    async fn info(&mut self) -> Result<DeviceInfo, PairError> {
        let mut l = match self.session().await {
            Ok(l) => l,
            // Not trusted yet: the public subset of values.
            Err(_) => LockdownClient::connect(&self.provider)
                .await
                .map_err(|e| map(ErrorCode::Disconnected, "lockdown", e))?,
        };
        let mut get =
            async |k: &str| l.get_value(Some(k), None).await.ok().and_then(|v| v.as_string().map(str::to_owned));
        let ios =
            get("ProductVersion").await.ok_or_else(|| PairError::new(ErrorCode::Disconnected, "no ProductVersion"))?;
        let product_type = get("ProductType").await.unwrap_or_default();
        let name = get("DeviceName").await.unwrap_or_else(|| "iPhone".into());
        Ok(DeviceInfo {
            udid: self.udid().to_owned(),
            name,
            model: crate::models::marketing_name(&product_type).unwrap_or(&product_type).to_owned(),
            product_type,
            ios,
        })
    }

    async fn trust(&mut self, _host: &HostIdentity) -> Result<TrustResult, PairError> {
        if let Some(r) = self.existing_record().await {
            let bytes = self.serialize(&r)?;
            self.record = Some(r);
            return Ok(TrustResult { outcome: TrustOutcome::AlreadyTrusted, lockdown: Some(bytes) });
        }
        let mut mux = self.addr.connect(2).await.map_err(|e| err(ErrorCode::NoUsbmux, "usbmuxd", e))?;
        let buid = mux.get_buid().await.map_err(|e| err(ErrorCode::NoUsbmux, "usbmuxd BUID", e))?;
        let mut l =
            LockdownClient::connect(&self.provider).await.map_err(|e| map(ErrorCode::Disconnected, "lockdown", e))?;
        let host_id = uuid::Uuid::new_v4().to_string().to_uppercase();
        // `pair` resends while the dialog is pending (PairingDialogResponsePending).
        let record = match l.pair(host_id, buid, Some(PAIR_HOST_NAME)).await {
            Ok(r) => r,
            Err(IdeviceError::PasswordProtected) | Err(IdeviceError::DeviceLocked) => {
                return Ok(TrustResult { outcome: TrustOutcome::Locked, lockdown: None });
            }
            Err(e) => return Err(map(ErrorCode::Internal, "lockdown pair", e)),
        };
        // The record works before we keep it.
        let mut check =
            LockdownClient::connect(&self.provider).await.map_err(|e| map(ErrorCode::Disconnected, "lockdown", e))?;
        check.start_session(&record).await.map_err(|e| map(ErrorCode::Internal, "StartSession with new record", e))?;
        let bytes = self.serialize(&record)?;
        // usbmuxd keeps it too, so this computer is not asked again.
        if let Err(e) = save_pair_record(&mut mux, self.udid(), bytes.clone()).await {
            log::warn!("save_pair_record: {e}");
        }
        self.record = Some(record);
        Ok(TrustResult { outcome: TrustOutcome::Paired, lockdown: Some(bytes) })
    }

    fn set_lockdown(&mut self, lockdown: &[u8]) -> Result<(), PairError> {
        if self.record.is_none() {
            self.record = Some(
                PairingFile::from_bytes(lockdown).map_err(|e| err(ErrorCode::RecordFailed, "lockdown record", e))?,
            );
        }
        Ok(())
    }

    async fn dev_mode_status(&mut self) -> Result<bool, PairError> {
        let mut l = self.session().await?;
        match l.get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi")).await {
            Ok(v) => Ok(v.as_boolean().unwrap_or(false)),
            Err(_) => {
                let mut amfi =
                    AmfiClient::connect(&self.paired()).await.map_err(|e| map(ErrorCode::Internal, "amfi", e))?;
                amfi.get_developer_mode_status().await.map_err(|e| map(ErrorCode::Internal, "amfi status", e))
            }
        }
    }

    async fn reveal_dev_mode(&mut self) -> Result<(), PairError> {
        let mut amfi = AmfiClient::connect(&self.paired()).await.map_err(|e| map(ErrorCode::Internal, "amfi", e))?;
        amfi.reveal_developer_mode_option_in_ui().await.map_err(|e| map(ErrorCode::Internal, "amfi reveal", e))
    }

    async fn accept_dev_mode(&mut self) -> Result<(), PairError> {
        let mut amfi = AmfiClient::connect(&self.paired()).await.map_err(|e| map(ErrorCode::Internal, "amfi", e))?;
        amfi.accept_developer_mode().await.map_err(|e| map(ErrorCode::Internal, "amfi accept", e))
    }

    async fn enable_wifi_debugging(&mut self) -> Result<(), PairError> {
        let mut l = self.session().await?;
        l.set_value("EnableWifiDebugging", true.into(), Some("com.apple.mobile.wireless_lockdown"))
            .await
            .map_err(|e| map(ErrorCode::Internal, "EnableWifiDebugging", e))
    }

    async fn generate_rp(&mut self, host: &HostIdentity, cached: Option<&[u8]>) -> Result<(Vec<u8>, RpVia), PairError> {
        let primary = async {
            let svc = RemotePairingLockdownService::connect(&self.paired()).await?;
            let mut client = svc.into_client(&host.host_name)?;
            rp_pair(&mut client, host, cached).await
        }
        .await;
        let first = match primary {
            Ok((rp, reused)) => return Ok((rp, if reused { RpVia::Cached } else { RpVia::LockdownService })),
            Err(e) => e,
        };
        log::warn!("{}: remotepairingdeviced.lockdown failed ({first}); trying CoreDeviceProxy", self.udid());
        match self.via_tunnel(host, async |c| rp_pair(c, host, cached).await).await {
            Ok((rp, reused)) => Ok((rp, if reused { RpVia::Cached } else { RpVia::CoreDeviceProxy })),
            Err(second) => Err(PairError::new(
                ErrorCode::RecordFailed,
                format!("remotepairingdeviced.lockdown: {first}; CoreDeviceProxy: {second}"),
            )),
        }
    }

    async fn list_apps(&mut self) -> Result<AppList, PairError> {
        let mut ip = InstallationProxyClient::connect(&self.paired())
            .await
            .map_err(|e| map(ErrorCode::Internal, "installation_proxy", e))?;
        ip.get_apps(Some("User"), None).await.map_err(|e| map(ErrorCode::Internal, "installation_proxy lookup", e))
    }

    async fn write_dropbox(&mut self, bundle_id: &str, bytes: &[u8]) -> Result<WriteVia, PairError> {
        let mut errors = Vec::new();
        for via in [WriteVia::VendContainer, WriteVia::VendDocuments] {
            match self.write_with(via, bundle_id, bytes).await {
                Ok(()) => return Ok(via),
                Err(e) => {
                    log::warn!("{}: {via:?}: {e}", self.udid());
                    errors.push(format!("{via:?}: {e}"));
                }
            }
        }
        Err(PairError::new(ErrorCode::WriteFailed, errors.join("; ")))
    }

    async fn verify_rp(&mut self, host: &HostIdentity, rp: &[u8]) -> Result<(), PairError> {
        let primary = async {
            let svc = RemotePairingLockdownService::connect(&self.paired()).await?;
            let mut client = svc.into_client(&host.host_name)?;
            rp_verify(&mut client, rp).await
        }
        .await;
        match primary {
            Ok(()) => Ok(()),
            Err(first) => self
                .via_tunnel(host, async |c| rp_verify(c, rp).await)
                .await
                .map_err(|second| PairError::new(ErrorCode::VerifyFailed, format!("{first}; tunnel: {second}"))),
        }
    }

    async fn verify_lockdown(&mut self, lockdown: &[u8]) -> Result<(), PairError> {
        let record =
            PairingFile::from_bytes(lockdown).map_err(|e| err(ErrorCode::VerifyFailed, "lockdown record", e))?;
        let mut l =
            LockdownClient::connect(&self.provider).await.map_err(|e| map(ErrorCode::Disconnected, "lockdown", e))?;
        l.start_session(&record).await.map_err(|e| map(ErrorCode::VerifyFailed, "StartSession", e))?;
        Ok(())
    }
}

impl RealConn {
    async fn write_with(&self, via: WriteVia, bundle_id: &str, bytes: &[u8]) -> Result<(), IdeviceError> {
        let ha = HouseArrestClient::connect(&self.paired()).await?;
        let mut afc = match via {
            WriteVia::VendContainer => ha.vend_container(bundle_id).await?,
            WriteVia::VendDocuments => ha.vend_documents(bundle_id).await?,
        };
        let dir = format!("/{DROPBOX_DIR}");
        let tmp = format!("{dir}/{DROPBOX_TEMP_FILE}");
        let dst = format!("{dir}/{DROPBOX_FILE}");
        // Exists already on a second run; a real failure shows up at open.
        let _ = afc.mk_dir(&dir).await;
        {
            let mut f = afc.open(&tmp, AfcFopenMode::WrOnly).await?;
            f.write_entire(bytes).await?;
            f.close().await?;
        }
        let _ = afc.remove(&dst).await;
        afc.rename(&tmp, &dst).await?;
        let back = {
            let mut f = afc.open(&dst, AfcFopenMode::RdOnly).await?;
            let b = f.read_entire().await?;
            f.close().await?;
            b
        };
        if back != bytes {
            return Err(IdeviceError::UnexpectedResponse("read-back differs from what was written".into()));
        }
        Ok(())
    }
}

async fn save_pair_record(mux: &mut UsbmuxdConnection, udid: &str, bytes: Vec<u8>) -> Result<(), IdeviceError> {
    mux.save_pair_record(udid, bytes).await
}
