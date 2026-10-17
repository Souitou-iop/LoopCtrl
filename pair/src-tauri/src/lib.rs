//! Tauri shell around pair-core: commands for the UI, and `pair-event`
//! events carrying pair-core's [`Event`]s.

use std::sync::Mutex;
use std::time::Duration;

use pair_core::{
    Config, DeviceView, EnvReport, Event, ManagerHandle, MockBackend, PhoneAction, RealBackend, Scenario, UserCommand,
};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

/// The running manager and, in mock mode, the fake phones behind it.
struct Core {
    manager: Option<ManagerHandle>,
    mock: Option<MockBackend>,
    auto_begin: bool,
}

struct AppState(Mutex<Core>);

/// Mock mode: `LOOPCTRL_PAIR_MOCK=1`, or the developer switch in Settings.
fn env_mock() -> bool {
    matches!(std::env::var("LOOPCTRL_PAIR_MOCK").as_deref(), Ok("1" | "true"))
}

/// Developer options are visible in debug builds or with `LOOPCTRL_PAIR_DEV=1`.
fn dev_options() -> bool {
    cfg!(debug_assertions) || env_mock() || matches!(std::env::var("LOOPCTRL_PAIR_DEV").as_deref(), Ok("1" | "true"))
}

fn start(app: &AppHandle, core: &mut Core, mock: bool) {
    // Stop the old manager first: two usbmuxd listeners would both act.
    core.manager = None;
    let dir = app.path().app_data_dir().unwrap_or_else(|_| std::env::temp_dir().join("LoopCtrl Pair"));
    let mut cfg = Config::new(dir);
    cfg.auto_begin = core.auto_begin;
    cfg.tool_version = app.package_info().version.to_string();
    let emitter = app.clone();
    let on_event = move |e: Event| {
        let _ = emitter.emit("pair-event", e);
    };
    if mock {
        // Short waits so the timeout screens are reachable in a demo.
        cfg.reboot_timeout = Duration::from_secs(20);
        cfg.confirm_timeout = Duration::from_secs(15);
        let m = core.mock.get_or_insert_with(MockBackend::new).clone();
        core.manager = Some(ManagerHandle::start(m, cfg, on_event));
    } else {
        core.mock = None;
        core.manager = Some(ManagerHandle::start(RealBackend::new(), cfg, on_event));
    }
    log::info!("pair-core started ({})", if mock { "mock" } else { "usbmuxd" });
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AppInfo {
    version: String,
    mock: bool,
    dev_options: bool,
    cache_dir: String,
    updater_configured: bool,
}

fn updater_configured(app: &AppHandle) -> bool {
    app.config()
        .plugins
        .0
        .get("updater")
        .and_then(|u| u.get("pubkey"))
        .and_then(|k| k.as_str())
        .is_some_and(|k| !k.starts_with("REPLACE_"))
}

/// Runs `f` on the manager under the lock; futures it returns are awaited after.
fn handle<T>(state: &State<AppState>, f: impl FnOnce(&ManagerHandle) -> T) -> Option<T> {
    state.0.lock().unwrap().manager.as_ref().map(f)
}

#[tauri::command]
fn app_info(app: AppHandle, state: State<AppState>) -> AppInfo {
    let core = state.0.lock().unwrap();
    AppInfo {
        version: app.package_info().version.to_string(),
        mock: core.mock.is_some(),
        dev_options: dev_options(),
        cache_dir: app.path().app_data_dir().map(|p| p.display().to_string()).unwrap_or_default(),
        updater_configured: updater_configured(&app),
    }
}

#[tauri::command]
async fn env_check(state: State<'_, AppState>) -> Result<EnvReport, String> {
    let fut = handle(&state, |m| m.env_check()).ok_or("not running")?;
    fut.await.ok_or_else(|| "manager stopped".into())
}

#[tauri::command]
async fn devices(state: State<'_, AppState>) -> Result<Vec<DeviceView>, String> {
    match handle(&state, |m| m.snapshot()) {
        Some(f) => Ok(f.await),
        None => Ok(Vec::new()),
    }
}

#[tauri::command]
fn device_command(state: State<AppState>, udid: String, cmd: UserCommand) {
    handle(&state, |m| m.command(&udid, cmd));
}

#[tauri::command]
fn set_auto_begin(state: State<AppState>, on: bool) {
    let mut core = state.0.lock().unwrap();
    core.auto_begin = on;
    if let Some(m) = &core.manager {
        m.set_auto_begin(on);
    }
}

#[tauri::command]
fn forget_device(state: State<AppState>, udid: String) {
    handle(&state, |m| m.forget(&udid));
}

#[tauri::command]
fn set_mock(app: AppHandle, state: State<AppState>, on: bool) -> Result<(), String> {
    if !dev_options() {
        return Err("developer options are off".into());
    }
    let mut core = state.0.lock().unwrap();
    start(&app, &mut core, on);
    Ok(())
}

fn with_mock(state: &State<AppState>, f: impl FnOnce(&MockBackend)) -> Result<(), String> {
    let core = state.0.lock().unwrap();
    let m = core.mock.as_ref().ok_or("not in mock mode")?;
    f(m);
    Ok(())
}

#[tauri::command]
fn mock_plug(state: State<AppState>, scenario: Scenario) -> Result<(), String> {
    with_mock(&state, |m| {
        m.plug(scenario);
    })
}

#[tauri::command]
fn mock_batch(state: State<AppState>) -> Result<(), String> {
    with_mock(&state, |m| {
        m.plug_batch();
    })
}

#[tauri::command]
fn mock_phone(state: State<AppState>, udid: String, action: PhoneAction) -> Result<(), String> {
    with_mock(&state, |m| m.phone(&udid, action))
}

#[tauri::command]
fn mock_reset(state: State<AppState>) -> Result<(), String> {
    with_mock(&state, |m| m.reset())
}

#[tauri::command]
fn mock_driver_missing(state: State<AppState>, missing: bool) -> Result<(), String> {
    with_mock(&state, |m| m.set_driver_missing(missing))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase", tag = "status")]
enum UpdateStatus {
    /// No update server yet (pubkey placeholder in tauri.conf.json).
    NotConfigured,
    UpToDate,
    Available {
        version: String,
        notes: Option<String>,
    },
    Error {
        message: String,
    },
}

#[tauri::command]
async fn check_update(app: AppHandle) -> UpdateStatus {
    use tauri_plugin_updater::UpdaterExt;
    if !updater_configured(&app) {
        return UpdateStatus::NotConfigured;
    }
    let updater = match app.updater() {
        Ok(u) => u,
        Err(e) => return UpdateStatus::Error { message: e.to_string() },
    };
    match updater.check().await {
        Ok(Some(u)) => UpdateStatus::Available { version: u.version, notes: u.body },
        Ok(None) => UpdateStatus::UpToDate,
        Err(e) => UpdateStatus::Error { message: e.to_string() },
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_log::Builder::new().level(log::LevelFilter::Info).build())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(AppState(Mutex::new(Core { manager: None, mock: None, auto_begin: false })))
        .setup(|app| {
            let state = app.state::<AppState>();
            let mut core = state.0.lock().unwrap();
            start(app.handle(), &mut core, env_mock());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            app_info,
            env_check,
            devices,
            device_command,
            set_auto_begin,
            forget_device,
            set_mock,
            mock_plug,
            mock_batch,
            mock_phone,
            mock_reset,
            mock_driver_missing,
            check_update,
        ])
        .run(tauri::generate_context!())
        .expect("error while running LoopCtrl Pair");
}
