//! Lists what usbmuxd reports, USB and network, with the lockdown basics.
//! `cargo run -p pair-core --example devices`
//! `cargo run -p pair-core --example devices -- --forget <UDID>` backs up this
//! computer's usbmuxd pair record to target/pair-record-backup and deletes it,
//! so the phone asks "Trust" again (for testing the Trust step).
//! `--unpair <UDID> [HOSTID…]` does the same and also sends lockdown `Unpair`
//! for that record's HostID (and any extra HostIDs given), so the phone itself
//! forgets this computer. Less invasive than Reset Location & Privacy.

use idevice::lockdown::LockdownClient;
use idevice::usbmuxd::{UsbmuxdAddr, UsbmuxdConnection};
use idevice::IdeviceService;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let addr = UsbmuxdAddr::from_env_var().unwrap_or_default();
    let mut mux: UsbmuxdConnection = addr.connect(0).await.expect("usbmuxd");
    let args: Vec<String> = std::env::args().collect();
    if let Some(i) = args.iter().position(|a| a == "--forget" || a == "--unpair") {
        let unpair = args[i] == "--unpair";
        let udid = args.get(i + 1).expect("UDID");
        let record = mux.get_pair_record(udid).await.expect("no pair record to forget");
        std::fs::create_dir_all("target/pair-record-backup").unwrap();
        let path = format!("target/pair-record-backup/{udid}.plist");
        std::fs::write(&path, record.clone().serialize().expect("serialize")).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        if unpair {
            let dev = mux.get_device(udid).await.expect("device not attached");
            let p = dev.to_provider(addr.clone(), "LoopCtrl-Pair");
            let mut hosts = vec![record.host_id.clone()];
            hosts.extend(args[i + 2..].iter().cloned());
            for h in hosts {
                let mut l = LockdownClient::connect(&p).await.expect("lockdown");
                match l.unpair(h.clone()).await {
                    Ok(()) => println!("Unpair {h}: ok"),
                    Err(e) => println!("Unpair {h}: {e}"),
                }
            }
        }
        mux.delete_pair_record(udid).await.expect("delete");
        println!("backed up to {path} and deleted the usbmuxd record");
        return;
    }
    let devs = mux.get_devices().await.expect("ListDevices");
    println!("{} device(s)", devs.len());
    for d in devs {
        let has_record = mux.get_pair_record(&d.udid).await.is_ok();
        print!("{} mux={} {:?} pair-record={has_record}", d.udid, d.device_id, d.connection_type);
        let p = d.to_provider(addr.clone(), "LoopCtrl-Pair");
        match LockdownClient::connect(&p).await {
            Ok(mut l) => {
                for k in ["DeviceName", "ProductType", "ProductVersion"] {
                    let v = l.get_value(Some(k), None).await.ok().and_then(|v| v.as_string().map(str::to_owned));
                    print!(" {k}={}", v.unwrap_or_else(|| "?".into()));
                }
                println!();
            }
            Err(e) => println!(" lockdown: {e}"),
        }
    }
}
