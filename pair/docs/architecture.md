# Architecture

```
ui/ (Svelte 5 + Vite)  ──invoke / "pair-event"──▶  src-tauri/ (Tauri 2 shell)      crates/cli (loopctrl-pair)
                                                        │                               │
                                                        ├──── crates/pair-host ─────────┤  which usbmuxd
                                                        ▼                               ▼
                                            crates/pair-core (no UI)
                              ┌──────────────┬──────────┴──────┬──────────────┐
                           machine.rs     session.rs        record.rs      backend/
                        (state machine)  (manager, workers) (file format)  real.rs  (idevice)
                                                                           mock.rs  (fake phones)
```

**pair-core** is the reusable part, shared by the desktop app, the CLI and the Android app. It has no Tauri or other GUI dependency.

- `machine.rs`: one pure state machine per phone. Inputs are operation results, usbmuxd attach/detach and user commands; outputs are the next action. Phases: `detected → trusting → checkingDevMode → [revealingDevMode → devModeGuide → rebooting → confirmingDevMode] → generating → findingApp → writing → verifying → done`, or `failed` with the step it failed at, which is where Retry resumes. Replugging a failed phone retries it.
- `session.rs`: the manager. One thread with a single-threaded tokio runtime; a usbmuxd watcher (reconnects every 2 s) and one worker task per phone, so batch mode is just several workers. A worker runs the action the machine asks for, cancels it when the phone is unplugged or a command arrives, and emits a `DeviceView` after every step.
- `backend/real.rs`: idevice v0.1.68 (the version LoopCtrl's xcframework uses). Trust = `LockdownClient::pair` (it re-sends while `PairingDialogResponsePending`), checked with `start_session`, then `save_pair_record` to usbmuxd. Developer Mode = lockdown `DeveloperModeStatus` in `com.apple.security.mac.amfi`, AMFI (`com.apple.amfi.lockdown`) action 0 to reveal the toggle and action 2 after the reboot. RP record = `RemotePairingLockdownService` (`com.apple.dt.remotepairingdeviced.lockdown`), falling back to CoreDeviceProxy → software tunnel → RSD → untrusted tunnel service. A cached RP record is pair-verified first and reused when the phone still accepts it. Apps = installation_proxy `Lookup` (User). Write = house_arrest `VendContainer`, then `VendDocuments`, AFC write + rename + read-back. Verify = RP pair-verify (17.4+) or a lockdown session (16 / 17.0–17.3).
- `backend/mock.rs`: scripted iPhones (`Scenario`) that need the same "phone side" actions a person would do (`PhoneAction`), or act on their own (batch preset). Used by the tests and by mock mode.
- `ops.rs`: single operations outside the state machine (list, write, verify) for the CLI, generic over `Backend`.
- `record.rs`: the handoff file (docs/handoff.md). `cache.rs`: host name and per-UDID records in the app-data folder (0700/0600 on Unix). `app_match.rs`: finding LoopCtrl.

**pair-host** decides which usbmuxd pair-core talks to (`Transport`): the system one, or the built-in one (`crates/usbmux`) on a private socket. Auto mode: system when `USBMUXD_SOCKET_ADDRESS` is set, on macOS/Windows, or on Linux when the system socket answers or usbmuxd is installed (udev starts it on plug); built-in otherwise, or whenever USB bridges are accepted. It also fills in `EnvReport.linux` (usbmuxd installed/running, built-in, udev rule, USB access, conflict) and holds the udev rule.

**src-tauri** holds the manager and the transport, forwards events, and exposes commands (`device_command`, `set_auto_begin`, mock controls, `check_update`). Mock mode: `LOOPCTRL_PAIR_MOCK=1`, or Settings › 开发者选项 (shown in debug builds, or with `LOOPCTRL_PAIR_DEV=1`).

**ui** keeps only what pair-core does not know: the page, which phone single mode is following, the phones paired this session, theme and language. Screens map 1:1 to the approved miuix demo.

## Linux

```
                    system usbmuxd (user-installed)  ─┐
pair-core RealBackend ──usbmuxd protocol──▶ either     ├─ /var/run/usbmuxd
                                                      │
                    built-in usbmuxd (pair-host)     ─┘  $XDG_RUNTIME_DIR/loopctrl-pair/usbmuxd.sock (0600)
                       usbmux::linux::LinuxUsbHost: sysfs scan (1 s) → descriptors →
                       config → claim → UsbfsPipe → Hub
                       usbmux::bridge::serve_tcp (optional): helpers over TCP → BridgePipe → Hub
```

- `usbmux::linux` polls `/sys/bus/usb/devices` for Apple usbmux devices, reads every configuration from the world-readable sysfs `descriptors` file, keeps the active configuration when it has the usbmux interface (otherwise picks the one with the fewest interfaces and unbinds kernel drivers before `SETCONFIGURATION`), opens `/dev/bus/usb/BBB/DDD`, claims the interface and hands a `UsbfsPipe` (the Android code) to the hub. No libusb.
- Permissions: `packaging/linux/70-loopctrl-pair.rules` (uaccess + plugdev). EACCES → `UsbState::PermissionDenied` → `usbAccess: false` → the UI's "no permission" dialog, which can install the rule through pkexec.
- Conflict: an interface already bound to `usbfs` (another program, normally usbmuxd) is never taken; it is reported as `Busy` → `conflict: "systemTookDevice"` when the system socket answers. In auto mode the app switches to the system usbmuxd on the next environment check.
- Pair records of the built-in usbmuxd live in `<data dir>/lockdown/`; the system usbmuxd keeps its own in `/var/lib/lockdown`.
- Bundles: `.deb` (installs the udev rule, postinst reloads udev) and AppImage, x86_64 and aarch64, built by CI. The CLI is a separate tarball.

## Transports and external helpers

`usbmux::pipe::UsbPipe` (bulk-in with timeout, bulk-out) is the only thing a transport implements. `UsbfsPipe` (Linux, Android) and `BridgePipe` (framed byte stream from an external USB host, `usbmux::bridge`) exist; everything above (mux, usbmuxd socket, idevice, pair-core) is shared. Design for ESP32-class helpers: docs/hardware-helpers.md.

## CLI

`crates/cli` builds `loopctrl-pair`: `devices`, `pair [--all]`, `write`, `verify`, `env`, `udev-rule`, `--json`, `--mock`. `pair` runs a `ManagerHandle` exactly as the apps do (auto-begin with `--all`, otherwise Begin for one phone); `write`/`verify` use `pair_core::ops` with the record cached by `pair` (or `--file`). It shares the desktop app's data folder, so both use one RemotePairing host identity. (The Tauri cargo binary is named `loopctrl-pair-app` to keep the names apart; bundles use `mainBinaryName`.)

## Android

```
android/app (Compose + miuix) ──UniFFI──▶ android/bridge (PairBridge)
   UsbHost.kt: UsbManager, permission,          ├─ crates/usbmux: built-in usbmuxd (usbfs bulk
   configuration, claim, fd ───────────────────▶│   transfers, mux protocol, private unix socket)
                                                 └─ pair-core ManagerHandle + RealBackend::at(socket)
```

Android has no usbmuxd, so the bridge runs one in-process (`crates/usbmux`, from iloader's Android port, MIT) and points `RealBackend` at its socket; pair-core works unchanged. The muxer keeps lockdown records and its SystemBUID in `files/lockdown/`, pair-core its cache in `files/pair/`. Views and events cross the bridge as pair-core's JSON. The muxer's own auto-pairing (`usbmux::pairing`) is not used: pair-core does Trust itself. Details: android/README.md.

## Updates

`tauri-plugin-updater` is wired, but `plugins.updater` in `tauri.conf.json` holds placeholders (`REPLACE_WITH_MINISIGN_PUBLIC_KEY`, an `.invalid` endpoint). While the pubkey is a placeholder, "检查更新" reports that no server is configured. To enable: `bun tauri signer generate`, put the public key and the CDN URL in the config, set `bundle.createUpdaterArtifacts` to true, sign builds with `TAURI_SIGNING_PRIVATE_KEY`.

## CI and releases

`.github/workflows/ci.yml`: on pushes and PRs, a Linux check job (fmt, clippy `-D warnings`, tests, the CLI against the mock backend and the built-in usbmuxd, cargo-deny, the JS license check, notices up to date), then bundles for Linux x86_64 and aarch64 (native arm runner), macOS universal, Windows x64 (NSIS) and Android (debug APK). A `v*` tag adds a release job that attaches everything with SHA256SUMS (pre-release when the tag has a `-`; notes from `docs/release-notes/<tag>.md` if present). AppImages bundle GTK/WebKitGTK (LGPL), so they are attached only when the repository variable `RELEASE_APPIMAGE` is `true`.

## Licenses

`cargo deny check licenses bans sources` (deny.toml) allows permissive licenses only, plus MPL-2.0 for five unmodified crates Tauri pulls in (cssparser, cssparser-macros, selectors, dtoa-short, option-ext). `bun run licenses:check` does the same for the JS packages that ship. `bun run licenses` regenerates THIRD_PARTY_NOTICES.md and the list in Settings.
