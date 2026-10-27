//! Runs the whole flow from a terminal, for testing with a real iPhone:
//!
//! ```text
//! cargo run -p pair-core --example pair            # real usbmuxd
//! cargo run -p pair-core --example pair -- --mock  # simulated phone
//! cargo run -p pair-core --example pair -- --network  # also Wi-Fi devices already trusted (testing)
//! ```
//!
//! Every phone that is plugged in starts by itself (batch behaviour). Records
//! are cached under ./target/pair-cache. Ctrl-C to quit.

use std::time::Duration;

use pair_core::{Config, Event, ManagerHandle, MockBackend, PhoneAction, RealBackend, Scenario};

fn main() {
    let mock = std::env::args().any(|a| a == "--mock");
    let mut cfg = Config::new("target/pair-cache");
    cfg.auto_begin = true;
    let print = |e: Event| match e {
        Event::Device { device: d } => {
            let name = d.info.as_ref().map(|i| format!("{} ({}, iOS {})", i.name, i.model, i.ios)).unwrap_or_default();
            let err = d.error.as_ref().map(|e| format!("  ERROR {:?}: {}", e.code, e.detail)).unwrap_or_default();
            println!("[{}] {:?} {}{}", d.udid, d.phase, name, err);
            if d.phase == pair_core::Phase::Done {
                println!(
                    "    record {:?} via {:?}, app {:?}, write {:?}",
                    d.record_kind,
                    d.rp_via,
                    d.app.map(|a| a.bundle_id),
                    d.write_via
                );
            }
        }
        Event::Removed { udid } => println!("[{udid}] removed"),
        Event::Watch { ok, detail } => println!(
            "usbmuxd: {}{}",
            if ok { "connected" } else { "unavailable" },
            detail.map(|d| format!(" ({d})")).unwrap_or_default()
        ),
    };
    if mock {
        let m = MockBackend::new();
        let _h = ManagerHandle::start(m.clone(), cfg, print);
        let udid = m.plug(Scenario::DevModeOff);
        // Play the person holding the phone.
        for (wait, action) in [(2, PhoneAction::Trust), (6, PhoneAction::Restart), (6, PhoneAction::TurnOn)] {
            std::thread::sleep(Duration::from_secs(wait));
            m.phone(&udid, action);
        }
        std::thread::sleep(Duration::from_secs(10));
    } else {
        let network = std::env::args().any(|a| a == "--network");
        let _h = ManagerHandle::start(RealBackend::new().allow_network(network), cfg, print);
        loop {
            std::thread::sleep(Duration::from_secs(3600));
        }
    }
}
