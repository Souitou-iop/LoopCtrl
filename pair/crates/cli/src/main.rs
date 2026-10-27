//! `loopctrl-pair`: LoopCtrl Pair without a window, for terminals, kiosks,
//! Raspberry Pi class boards and setups with external USB bridges.
//!
//! Same pair-core as the apps; `pair-host` picks the usbmuxd (system or
//! built-in). Run `loopctrl-pair --help`.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use pair_core::cache::Cache;
use pair_core::{
    Config, ErrorCode, Event, ManagerHandle, MockBackend, PairError, Phase, RealBackend, Scenario, UserCommand,
};
use pair_host::{MuxMode, Options, Transport};
use serde::Serialize;

mod text;
use text::Text;

const USAGE: &str = "\
loopctrl-pair — LoopCtrl Pair command line (LoopCtrl 配对助手命令行)

USAGE:
    loopctrl-pair <COMMAND> [OPTIONS]

COMMANDS:
    devices      List iPhones connected over USB
    pair         Full flow: Trust, Developer Mode, make the pairing file,
                 write it into LoopCtrl, verify
    write        Write a pairing file into LoopCtrl (default: the cached one)
    verify       Check that the iPhone accepts a pairing file (default: cached)
    env          Environment check (usbmuxd, built-in mode, udev rule)
    udev-rule    Print the udev rule for the built-in usbmuxd (Linux)

OPTIONS:
    --json                 Machine-readable output (pair: one event per line)
    --udid <UDID>          The iPhone to use (needed when several are connected)
    --all                  pair: every iPhone, now and plugged in later; runs until
                           --timeout or Ctrl-C (batch / kiosk)
    --file <PATH>          write, verify: the pairing file
    --out <PATH>           pair: also save the pairing file here
    --timeout <SECS>       pair: give up after this long (default 900; 0 = never)
    --mux <MODE>           auto (default), system or builtin
    --bridge-listen <ADDR> Accept USB bridges on ADDR (e.g. 0.0.0.0:27100); implies builtin
    --no-local-usb         builtin: do not open local USB devices (bridges only)
    --data-dir <PATH>      Records and cache (default: the desktop app's folder)
    --mock                 Simulated iPhones, no hardware needed
    --mock-scenario <S>    ready, devModeOff (default), legacy16, early17, noRpService, noApp
    -v, --verbose          Log to stderr
    -h, --help             This help
    -V, --version          Version

EXIT CODES:
    0 success, 1 failed, 2 usage, 3 no usbmuxd / USB access, 4 timed out

ENVIRONMENT:
    LOOPCTRL_PAIR_MUX        Same as --mux
    USBMUXD_SOCKET_ADDRESS   System usbmuxd address (path, or host:port)
";

#[derive(Debug, Default)]
struct Args {
    cmd: String,
    json: bool,
    udid: Option<String>,
    all: bool,
    file: Option<PathBuf>,
    out: Option<PathBuf>,
    timeout: Option<u64>,
    mux: Option<MuxMode>,
    bridge_listen: Option<std::net::SocketAddr>,
    no_local_usb: bool,
    data_dir: Option<PathBuf>,
    mock: bool,
    scenario: Option<Scenario>,
    verbose: bool,
}

fn parse_args(raw: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let mut a = Args::default();
    let mut it = raw.into_iter();
    let value =
        |it: &mut dyn Iterator<Item = String>, flag: &str| it.next().ok_or_else(|| format!("{flag} needs a value"));
    while let Some(arg) = it.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f.to_owned(), Some(v.to_owned())),
            _ => (arg.clone(), None),
        };
        let val = |it: &mut dyn Iterator<Item = String>| match &inline {
            Some(v) => Ok(v.clone()),
            None => value(it, &flag),
        };
        match flag.as_str() {
            "-h" | "--help" | "help" => a.cmd = "help".into(),
            "-V" | "--version" => a.cmd = "version".into(),
            "--json" => a.json = true,
            "--all" => a.all = true,
            "--mock" => a.mock = true,
            "--no-local-usb" => a.no_local_usb = true,
            "-v" | "--verbose" => a.verbose = true,
            "--udid" => a.udid = Some(val(&mut it)?),
            "--file" => a.file = Some(val(&mut it)?.into()),
            "--out" => a.out = Some(val(&mut it)?.into()),
            "--data-dir" => a.data_dir = Some(val(&mut it)?.into()),
            "--timeout" => a.timeout = Some(val(&mut it)?.parse().map_err(|_| "--timeout takes seconds")?),
            "--mux" => a.mux = Some(val(&mut it)?.parse()?),
            "--bridge-listen" => {
                a.bridge_listen = Some(val(&mut it)?.parse().map_err(|e| format!("--bridge-listen: {e}"))?)
            }
            "--mock-scenario" => {
                let s = val(&mut it)?;
                a.scenario = Some(
                    serde_json::from_value(serde_json::Value::String(s.clone()))
                        .map_err(|_| format!("unknown scenario {s:?}"))?,
                );
                a.mock = true;
            }
            f if f.starts_with('-') => return Err(format!("unknown option {f}")),
            c if a.cmd.is_empty() => a.cmd = c.to_owned(),
            c => return Err(format!("unexpected argument {c:?}")),
        }
    }
    Ok(a)
}

/// The desktop app's data folder (Tauri `app_data_dir` for app.loopctrl.pair),
/// so the CLI and the app share one host identity and cache.
fn default_data_dir() -> PathBuf {
    const ID: &str = "app.loopctrl.pair";
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if cfg!(target_os = "macos") {
        if let Some(h) = home {
            return h.join("Library/Application Support").join(ID);
        }
    } else if cfg!(windows) {
        if let Some(d) = std::env::var_os("APPDATA") {
            return PathBuf::from(d).join(ID);
        }
    } else if let Some(d) = std::env::var_os("XDG_DATA_HOME").filter(|d| !d.is_empty()) {
        return PathBuf::from(d).join(ID);
    } else if let Some(h) = home {
        return h.join(".local/share").join(ID);
    }
    std::env::temp_dir().join(ID)
}

struct StderrLog;

impl log::Log for StderrLog {
    fn enabled(&self, _: &log::Metadata) -> bool {
        true
    }
    fn log(&self, r: &log::Record) {
        eprintln!("[{} {}] {}", r.level(), r.target(), r.args());
    }
    fn flush(&self) {}
}

/// Exit codes.
const FAILED: u8 = 1;
const USAGE_ERR: u8 = 2;
const NO_ACCESS: u8 = 3;
const TIMED_OUT: u8 = 4;

fn exit_for(e: &PairError) -> u8 {
    match e.code {
        ErrorCode::NoUsbmux | ErrorCode::NoDriver => NO_ACCESS,
        _ => FAILED,
    }
}

struct Ctx {
    args: Args,
    t: &'static Text,
    data_dir: PathBuf,
}

impl Ctx {
    fn emit<T: Serialize>(&self, v: &T) {
        println!("{}", serde_json::to_string(v).unwrap_or_default());
    }

    fn fail(&self, e: &PairError) -> ExitCode {
        if self.args.json {
            self.emit(&serde_json::json!({ "error": e }));
        } else {
            eprintln!("{}: {}", self.t.error_title(e.code), e.detail);
            if let Some(h) = self.t.error_hint(e.code) {
                eprintln!("  {h}");
            }
        }
        ExitCode::from(exit_for(e))
    }

    fn cache(&self) -> Cache {
        Cache::new(if self.args.mock { self.data_dir.join("mock") } else { self.data_dir.clone() })
    }

    fn config(&self) -> Config {
        let mut cfg = Config::new(self.cache().root().to_path_buf());
        cfg.tool_version = env!("CARGO_PKG_VERSION").into();
        cfg
    }

    fn transport(&self) -> Result<Transport, PairError> {
        let mut o = Options::new(&self.data_dir);
        if let Some(m) = self.args.mux {
            o.mode = m;
        }
        o.bridge_listen = self.args.bridge_listen;
        o.local_usb = !self.args.no_local_usb;
        Transport::start(&o).map_err(|e| PairError::new(ErrorCode::NoUsbmux, e))
    }

    /// How long to wait for usbmuxd to list devices. The built-in one opens
    /// USB devices after it starts, so give it a moment.
    fn settle(&self, t: Option<&Transport>) -> Duration {
        match t.map(Transport::kind) {
            Some(pair_host::Kind::BuiltIn) => Duration::from_millis(3500),
            _ => Duration::from_millis(800),
        }
    }

    fn mock(&self) -> MockBackend {
        let m = MockBackend::new();
        m.plug_auto(self.args.scenario.unwrap_or(Scenario::DevModeOff));
        m
    }
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread().enable_all().build().expect("tokio runtime")
}

fn main() -> ExitCode {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("loopctrl-pair: {e}\n\n{USAGE}");
            return ExitCode::from(USAGE_ERR);
        }
    };
    if args.verbose {
        let _ = log::set_logger(&StderrLog);
        log::set_max_level(log::LevelFilter::Info);
    }
    let data_dir = args.data_dir.clone().unwrap_or_else(default_data_dir);
    let ctx = Ctx { t: text::pick(), data_dir, args };
    match ctx.args.cmd.as_str() {
        "" | "help" => {
            print!("{USAGE}");
            ExitCode::SUCCESS
        }
        "version" => {
            println!("loopctrl-pair {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        "devices" => devices(&ctx),
        "pair" => pair(&ctx),
        "write" | "verify" => write_or_verify(&ctx),
        "env" => env(&ctx),
        "udev-rule" => {
            print!("{}", pair_host::UDEV_RULE);
            ExitCode::SUCCESS
        }
        other => {
            eprintln!("loopctrl-pair: unknown command {other:?}\n\n{USAGE}");
            ExitCode::from(USAGE_ERR)
        }
    }
}

fn devices(ctx: &Ctx) -> ExitCode {
    let rt = runtime();
    let (list, transport) = if ctx.args.mock {
        let m = ctx.mock();
        (rt.block_on(pair_core::ops::list(&m, Duration::from_millis(300))), None)
    } else {
        let t = match ctx.transport() {
            Ok(t) => t,
            Err(e) => return ctx.fail(&e),
        };
        let b = RealBackend::at(t.addr());
        (rt.block_on(pair_core::ops::list(&b, ctx.settle(Some(&t)))), Some(t))
    };
    let list = match list {
        Ok(l) => l,
        Err(e) => return ctx.fail(&e),
    };
    if ctx.args.json {
        ctx.emit(&list);
        return ExitCode::SUCCESS;
    }
    if list.is_empty() {
        println!("{}", ctx.t.no_devices);
        if let Some(t) = &transport {
            for d in t.usb_status() {
                println!("  {} {}: {:?}", d.dev_path, d.udid, d.state);
            }
        }
    }
    for d in &list {
        match &d.info {
            Some(i) => println!(
                "{}  {} · {} · iOS {}  [{}]",
                d.udid,
                i.name,
                i.model,
                i.ios,
                match (d.supported, d.record_kind) {
                    (Some(false), _) => ctx.t.unsupported,
                    (_, Some(pair_core::RecordKind::RemotePairing)) => "RemotePairing + lockdown",
                    _ => "lockdown",
                }
            ),
            None => println!("{}  ({})", d.udid, d.error.as_ref().map(|e| e.detail.as_str()).unwrap_or("?")),
        }
    }
    ExitCode::SUCCESS
}

fn env(ctx: &Ctx) -> ExitCode {
    let rt = runtime();
    let report = if ctx.args.mock {
        rt.block_on(pair_core::backend::Backend::env_check(&MockBackend::new()))
    } else {
        let t = match ctx.transport() {
            Ok(t) => t,
            Err(e) => return ctx.fail(&e),
        };
        // Let the built-in host look at USB once.
        if t.kind() == pair_host::Kind::BuiltIn {
            std::thread::sleep(Duration::from_millis(1500));
        }
        let mut r = rt.block_on(pair_core::env::check_usbmux_at(t.addr()));
        t.decorate(&mut r);
        r
    };
    if ctx.args.json {
        ctx.emit(&report);
    } else {
        text::print_env(ctx.t, &report, &ctx.data_dir);
    }
    let access_ok = report.linux.as_ref().is_none_or(|l| l.usb_access != Some(false) && l.conflict.is_none());
    if report.usbmux_ok && access_ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(NO_ACCESS)
    }
}

fn write_or_verify(ctx: &Ctx) -> ExitCode {
    let verify = ctx.args.cmd == "verify";
    let rt = runtime();
    let cache = ctx.cache();
    let host = match cache.host_identity() {
        Ok(h) => h,
        Err(e) => return ctx.fail(&e),
    };
    macro_rules! go {
        ($backend:expr, $settle:expr) => {{
            let backend = $backend;
            rt.block_on(async {
                let dev = pair_core::ops::pick(&backend, ctx.args.udid.as_deref(), $settle).await?;
                let file = match &ctx.args.file {
                    Some(p) => std::fs::read(p).map_err(|e| PairError::internal(format!("{}: {e}", p.display())))?,
                    None => cache.load_pairing_file(&dev.udid).ok_or_else(|| {
                        PairError::new(
                            ErrorCode::RecordFailed,
                            format!("no cached pairing file for {}; run `loopctrl-pair pair` or pass --file", dev.udid),
                        )
                    })?,
                };
                if verify {
                    pair_core::ops::verify(&backend, &dev, &host, &file)
                        .await
                        .map(|r| serde_json::to_value(r).unwrap_or_default())
                } else {
                    pair_core::ops::write(&backend, &dev, &file)
                        .await
                        .map(|r| serde_json::to_value(r).unwrap_or_default())
                }
            })
        }};
    }

    let result = if ctx.args.mock {
        go!(ctx.mock(), Duration::from_millis(300))
    } else {
        let t = match ctx.transport() {
            Ok(t) => t,
            Err(e) => return ctx.fail(&e),
        };
        go!(RealBackend::at(t.addr()), ctx.settle(Some(&t)))
    };
    match result {
        Ok(v) => {
            if ctx.args.json {
                ctx.emit(&v);
            } else if verify {
                println!("{} {}", ctx.t.verified, v["udid"].as_str().unwrap_or(""));
            } else {
                println!(
                    "{} {} ({}, {})",
                    ctx.t.written,
                    v["udid"].as_str().unwrap_or(""),
                    v["app"]["bundleId"].as_str().unwrap_or(""),
                    v["writeVia"].as_str().unwrap_or("")
                );
            }
            ExitCode::SUCCESS
        }
        Err(e) => ctx.fail(&e),
    }
}

/// Runs the manager like the apps do and follows one iPhone (or all with
/// `--all`) to the end.
fn pair(ctx: &Ctx) -> ExitCode {
    let (tx, rx) = mpsc::channel::<Event>();
    let on_event = move |e: Event| {
        let _ = tx.send(e);
    };
    let mut cfg = ctx.config();
    cfg.auto_begin = ctx.args.all;
    let transport;
    let mut _mock = None;
    let manager = if ctx.args.mock {
        // Short waits, like the apps' mock mode.
        cfg.reboot_timeout = Duration::from_secs(20);
        cfg.confirm_timeout = Duration::from_secs(15);
        let m = MockBackend::new();
        let h = ManagerHandle::start(m.clone(), cfg, on_event);
        m.plug_auto(ctx.args.scenario.unwrap_or(Scenario::DevModeOff));
        _mock = Some(m);
        h
    } else {
        transport = match ctx.transport() {
            Ok(t) => t,
            Err(e) => return ctx.fail(&e),
        };
        if !ctx.args.json {
            eprintln!("{} {} ({})", ctx.t.using, transport.kind().as_str(), describe(&transport));
        }
        ManagerHandle::start(RealBackend::at(transport.addr()), cfg, on_event)
    };
    let cache = ctx.cache();

    let timeout = match ctx.args.timeout {
        Some(0) => None,
        Some(s) => Some(Duration::from_secs(s)),
        None if ctx.args.all => None,
        None => Some(Duration::from_secs(900)),
    };
    let started = Instant::now();
    let mut target: Option<String> = ctx.args.udid.clone();
    let mut begun = false;
    let mut last: std::collections::HashMap<String, (Phase, bool, bool)> = Default::default();
    let mut done = 0u32;
    let mut failed = 0u32;
    let mut waiting_said = false;

    loop {
        let left = timeout.map(|t| t.saturating_sub(started.elapsed()));
        if left == Some(Duration::ZERO) {
            if ctx.args.json {
                ctx.emit(&serde_json::json!({ "type": "result", "ok": false, "timedOut": true, "done": done, "failed": failed }));
            } else {
                eprintln!("{}", ctx.t.timed_out);
            }
            return ExitCode::from(if ctx.args.all && failed == 0 && done > 0 { 0 } else { TIMED_OUT });
        }
        let ev = match rx.recv_timeout(left.unwrap_or(Duration::from_secs(3600)).min(Duration::from_secs(1))) {
            Ok(ev) => ev,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if !waiting_said && !ctx.args.json && started.elapsed() > Duration::from_secs(4) && last.is_empty() {
                    eprintln!("{}", ctx.t.waiting);
                    waiting_said = true;
                }
                continue;
            }
            Err(_) => return ExitCode::from(FAILED),
        };
        if ctx.args.json {
            ctx.emit(&ev);
        }
        let Event::Device { device: d } = ev else {
            if let Event::Watch { ok: false, detail } = ev {
                if !ctx.args.json {
                    eprintln!("{} {}", ctx.t.usbmux_down, detail.unwrap_or_default());
                }
            }
            continue;
        };
        if !ctx.args.all {
            if target.is_none() {
                target = Some(d.udid.clone());
            }
            if target.as_deref().is_some_and(|t| !t.eq_ignore_ascii_case(&d.udid)) {
                continue;
            }
            // Begin is ignored until the phone's info has been read.
            if !begun && d.phase == Phase::Detected && d.info.is_some() {
                manager.command(&d.udid, UserCommand::Begin);
                begun = true;
            }
        }
        let key = (d.phase, d.locked, d.connected);
        if last.get(&d.udid) != Some(&key) {
            last.insert(d.udid.clone(), key);
            if !ctx.args.json {
                text::print_view(ctx.t, &d);
            }
        }
        match d.phase {
            Phase::Done => {
                if let Some(out) = &ctx.args.out {
                    if let Some(bytes) = cache.load_pairing_file(&d.udid) {
                        let path = if ctx.args.all { out.join(format!("{}.plist", d.udid)) } else { out.clone() };
                        if let Err(e) = save(&path, &bytes) {
                            eprintln!("{}: {e}", path.display());
                        } else if !ctx.args.json {
                            println!("  → {}", path.display());
                        }
                    }
                }
                if !ctx.args.all {
                    if ctx.args.json {
                        ctx.emit(&serde_json::json!({ "type": "result", "ok": true, "device": d }));
                    }
                    return ExitCode::SUCCESS;
                }
                done += 1;
            }
            Phase::Failed => {
                if !ctx.args.all {
                    let e = d.error.clone().unwrap_or_else(|| PairError::internal("failed"));
                    if ctx.args.json {
                        ctx.emit(&serde_json::json!({ "type": "result", "ok": false, "device": d }));
                    }
                    // The failure and its hint were printed with the view.
                    return ExitCode::from(exit_for(&e));
                }
                failed += 1;
            }
            _ => {}
        }
    }
}

fn describe(t: &Transport) -> String {
    let mut s = match t.addr() {
        #[cfg(unix)]
        pair_core::UsbmuxdAddr::UnixSocket(p) => p,
        pair_core::UsbmuxdAddr::TcpSocket(a) => a.to_string(),
    };
    if let Some(b) = t.bridge_addr() {
        s.push_str(&format!(", bridges on {b}"));
    }
    s
}

/// Saves a pairing file privately (0600): it gives full control of the phone.
fn save(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    let mut o = std::fs::OpenOptions::new();
    o.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    o.open(path)?.write_all(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Result<Args, String> {
        parse_args(s.split_whitespace().map(str::to_owned))
    }

    #[test]
    fn parses_commands_and_options() {
        let a = p("pair --udid ABC --json --timeout=30 --mux builtin --out x.plist").unwrap();
        assert_eq!(a.cmd, "pair");
        assert_eq!(a.udid.as_deref(), Some("ABC"));
        assert!(a.json);
        assert_eq!(a.timeout, Some(30));
        assert_eq!(a.mux, Some(MuxMode::BuiltIn));
        assert_eq!(a.out, Some(PathBuf::from("x.plist")));
        let a = p("devices --mock-scenario legacy16").unwrap();
        assert!(a.mock);
        assert_eq!(a.scenario, Some(Scenario::Legacy16));
        let a = p("pair --bridge-listen 0.0.0.0:27100 --no-local-usb").unwrap();
        assert_eq!(a.bridge_listen, Some("0.0.0.0:27100".parse().unwrap()));
        assert!(a.no_local_usb);
    }

    #[test]
    fn rejects_bad_input() {
        assert!(p("pair --udid").is_err());
        assert!(p("pair --frobnicate").is_err());
        assert!(p("pair extra").is_err());
        assert!(p("pair --mux libusb").is_err());
        assert!(p("pair --timeout soon").is_err());
        assert!(p("pair --mock-scenario nope").is_err());
    }
}
