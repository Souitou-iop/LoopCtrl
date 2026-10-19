# Architecture

```
ui/ (Svelte 5 + Vite)  ──invoke / "pair-event"──▶  src-tauri/ (Tauri 2 shell)
                                                        │
                                                        ▼
                                            crates/pair-core (no UI)
                              ┌──────────────┬──────────┴──────┬──────────────┐
                           machine.rs     session.rs        record.rs      backend/
                        (state machine)  (manager, workers) (file format)  real.rs  (idevice)
                                                                           mock.rs  (fake phones)
```

**pair-core** is the reusable part, shared by the desktop app and the Android app. It has no Tauri dependency.

- `machine.rs`: one pure state machine per phone. Inputs are operation results, usbmuxd attach/detach and user commands; outputs are the next action. Phases: `detected → trusting → checkingDevMode → [revealingDevMode → devModeGuide → rebooting → confirmingDevMode] → generating → findingApp → writing → verifying → done`, or `failed` with the step it failed at, which is where Retry resumes. Replugging a failed phone retries it.
- `session.rs`: the manager. One thread with a single-threaded tokio runtime; a usbmuxd watcher (reconnects every 2 s) and one worker task per phone, so batch mode is just several workers. A worker runs the action the machine asks for, cancels it when the phone is unplugged or a command arrives, and emits a `DeviceView` after every step.
- `backend/real.rs`: idevice v0.1.68 (the version LoopCtrl's xcframework uses). Trust = `LockdownClient::pair` (it re-sends while `PairingDialogResponsePending`), checked with `start_session`, then `save_pair_record` to usbmuxd. Developer Mode = lockdown `DeveloperModeStatus` in `com.apple.security.mac.amfi`, AMFI (`com.apple.amfi.lockdown`) action 0 to reveal the toggle and action 2 after the reboot. RP record = `RemotePairingLockdownService` (`com.apple.dt.remotepairingdeviced.lockdown`), falling back to CoreDeviceProxy → software tunnel → RSD → untrusted tunnel service. A cached RP record is pair-verified first and reused when the phone still accepts it. Apps = installation_proxy `Lookup` (User). Write = house_arrest `VendContainer`, then `VendDocuments`, AFC write + rename + read-back. Verify = RP pair-verify (17.4+) or a lockdown session (16 / 17.0–17.3).
- `backend/mock.rs`: scripted iPhones (`Scenario`) that need the same "phone side" actions a person would do (`PhoneAction`), or act on their own (batch preset). Used by the tests and by mock mode.
- `record.rs`: the handoff file (docs/handoff.md). `cache.rs`: host name and per-UDID records in the app-data folder (0700/0600 on Unix). `app_match.rs`: finding LoopCtrl.

**src-tauri** holds the manager, forwards events, and exposes commands (`device_command`, `set_auto_begin`, mock controls, `check_update`). Mock mode: `LOOPCTRL_PAIR_MOCK=1`, or Settings › 开发者选项 (shown in debug builds, or with `LOOPCTRL_PAIR_DEV=1`).

**ui** keeps only what pair-core does not know: the page, which phone single mode is following, the phones paired this session, theme and language. Screens map 1:1 to the approved miuix demo.

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

## Licenses

`cargo deny check licenses bans sources` (deny.toml) allows permissive licenses only, plus MPL-2.0 for five unmodified crates Tauri pulls in (cssparser, cssparser-macros, selectors, dtoa-short, option-ext). `bun run licenses:check` does the same for the JS packages that ship. `bun run licenses` regenerates THIRD_PARTY_NOTICES.md and the list in Settings.
