//! Core of LoopCtrl Pair: pairs an iPhone over USB, makes the pairing record
//! LoopCtrl needs, writes it into the app and verifies it.
//!
//! UI-independent so the desktop app, the CLI (crates/cli) and the Android (OTG)
//! version share it. See docs/architecture.md.

pub mod app_match;
pub mod backend;
pub mod cache;
pub mod env;
pub mod machine;
mod model;
pub mod models;
pub mod ops;
pub mod record;
pub mod session;
pub mod version;

pub use backend::mock::{MockBackend, PhoneAction, Scenario};
pub use backend::real::RealBackend;
/// usbmuxd address type, for [`RealBackend::at`].
pub use idevice::usbmuxd::UsbmuxdAddr;
pub use machine::{Phase, Step};
pub use model::*;
pub use session::{Config, DeviceView, Event, ManagerHandle};
pub use version::IosVersion;
