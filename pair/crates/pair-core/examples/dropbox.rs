//! Reads LoopCtrl's drop file back from the first USB iPhone, to check what
//! the app will import: `cargo run -p pair-core --example dropbox -- <bundle id> [out.plist]`

use idevice::afc::opcode::AfcFopenMode;
use idevice::house_arrest::HouseArrestClient;
use idevice::usbmuxd::{Connection, UsbmuxdAddr};
use idevice::IdeviceService;
use pair_core::record::{DROPBOX_DIR, DROPBOX_FILE};

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let mut args = std::env::args().skip(1);
    let bundle = args.next().expect("bundle id");
    let out = args.next().unwrap_or_else(|| "target/dropbox-readback.plist".into());
    let addr = UsbmuxdAddr::from_env_var().unwrap_or_default();
    let mut mux = addr.connect(0).await.expect("usbmuxd");
    let dev = mux
        .get_devices()
        .await
        .expect("devices")
        .into_iter()
        .find(|d| d.connection_type == Connection::Usb)
        .expect("no USB iPhone");
    let p = dev.to_provider(addr, "LoopCtrl-Pair");
    let mut afc = HouseArrestClient::connect(&p)
        .await
        .expect("house_arrest")
        .vend_container(&bundle)
        .await
        .expect("vend_container");
    println!("{:?}", afc.list_dir(format!("/{DROPBOX_DIR}")).await);
    let mut f = afc.open(format!("/{DROPBOX_DIR}/{DROPBOX_FILE}"), AfcFopenMode::RdOnly).await.expect("open");
    let bytes = f.read_entire().await.expect("read");
    f.close().await.ok();
    std::fs::write(&out, &bytes).unwrap();
    println!("{} bytes → {out}", bytes.len());
}
