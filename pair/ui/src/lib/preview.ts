// Dev-only screen gallery: `vite` in a browser with `?preview=<name>[&theme=dark][&lang=en]`
// renders one screen from fixed device states, without Tauri. Not used in the app.
import type { DeviceView, EnvReport, ErrorCode, Phase, Step } from "./api";
import type { store as Store } from "./store.svelte";

const base: DeviceView = {
  udid: "00008110-000A1B2C3D4E5F60", order: 1, connected: true,
  info: { udid: "00008110-000A1B2C3D4E5F60", name: "林晓的 iPhone", model: "iPhone 15 Pro", productType: "iPhone16,1", ios: "18.6.2" },
  phase: "detected", error: null, failedAt: null, progress: 0, attention: false, devModeWasOff: false,
  recordKind: "remotePairing", rpVia: null, app: null, writeVia: null, locked: false, phaseSince: Date.now() - 42_000, doneAt: null,
};
const app = { bundleId: "com.customer.loopctrl", name: "LoopCtrl", version: "1.4", matchedBy: "bundleSuffix", fileSharing: false };

function dev(phase: Phase, more: Partial<DeviceView> = {}): DeviceView {
  return { ...base, phase, ...more };
}
function failed(code: ErrorCode, at: Step, more: Partial<DeviceView> = {}): DeviceView {
  return dev("failed", { error: { code, detail: `${code}: example detail from idevice` }, failedAt: at, attention: true, ...more });
}

const ERRORS: [ErrorCode, Step][] = [
  ["untrusted", "trust"], ["devModeCancelled", "devModeConfirm"], ["rebootTimeout", "reboot"], ["unsupported", "info"],
  ["recordFailed", "generate"], ["appNotFound", "findApp"], ["writeFailed", "write"], ["verifyFailed", "verify"],
  ["disconnected", "write"], ["internal", "generate"],
];

const SINGLE: Record<string, DeviceView | null> = {
  wait: null,
  device: dev("detected"),
  trust: dev("trusting"),
  "trust-locked": dev("trusting", { locked: true }),
  devcheck: dev("checkingDevMode"),
  "devcheck-reveal": dev("revealingDevMode", { devModeWasOff: true }),
  "devcheck-guide": dev("devModeGuide", { devModeWasOff: true, attention: true }),
  reboot: dev("rebooting", { connected: false, devModeWasOff: true }),
  devunlock: dev("confirmingDevMode", { devModeWasOff: true, attention: true }),
  progress: dev("writing", { app, rpVia: "lockdownService" }),
  done: dev("done", { app, rpVia: "lockdownService", progress: 1, doneAt: Date.now() }),
  ...Object.fromEntries(ERRORS.map(([c, at]) => [`err-${c}`, failed(c, at, c === "unsupported" ? { info: { ...base.info!, ios: "15.8" } } : {})])),
};

function batch(): DeviceView[] {
  const mk = (i: number, name: string, model: string, ios: string, v: Partial<DeviceView>): DeviceView =>
    ({ ...base, udid: `U${i}`, order: i, info: { udid: `U${i}`, name, model, productType: "", ios }, ...v } as DeviceView);
  return [
    mk(1, "林晓的 iPhone", "iPhone 15 Pro", "18.6.2", { phase: "done", progress: 1, app, doneAt: Date.now() }),
    mk(2, "王磊的 iPhone", "iPhone 12", "17.5.1", { phase: "trusting", progress: 0.08 }),
    mk(3, "测试机 03", "iPhone XR", "16.7.10", { phase: "devModeGuide", progress: 0.15, attention: true, devModeWasOff: true, recordKind: "lockdown" }),
    mk(4, "张敏的 iPhone", "iPhone 16", "26.0.1", { phase: "generating", progress: 0.5 }),
    mk(5, "前台备用机", "iPhone 11", "18.5", { phase: "failed", progress: 0.6, attention: true, failedAt: "findApp", error: { code: "appNotFound", detail: "no LoopCtrl among user apps" } }),
  ];
}

export function applyPreview(store: typeof Store, name: string) {
  const env: EnvReport = { os: "macos", osVersion: "15.5", usbmuxOk: true, usbmuxAddr: "/var/run/usbmuxd", detail: null };
  store.env = env;
  store.info = { version: "0.1.0", mock: true, devOptions: true, cacheDir: "~/Library/Application Support/app.loopctrl.pair", updaterConfigured: false };
  if (name === "welcome") return;
  if (name === "welcome-win") { store.asWindows = true; return; }
  if (name === "err-noDriver") { store.asWindows = true; store.env = { ...env, os: "windows", usbmuxOk: false, detail: "connection refused (os error 10061)" }; store.envDialog = true; return; }
  if (name.startsWith("welcome-linux") || name.startsWith("err-linux")) {
    const linux = { usbmuxdInstalled: false, usbmuxdRunning: false, builtIn: true, udevRule: false, usbAccess: false, usbDevices: 1, conflict: null } as const;
    store.env = { ...env, os: "linux", osVersion: "24.04", usbmuxAddr: "/run/user/1000/loopctrl-pair/usbmuxd.sock", transport: "builtIn",
      detail: "permission denied: /dev/bus/usb/003/012", linux: { ...linux } };
    if (name === "welcome-linux-ok") store.env = { ...store.env, detail: null, linux: { ...linux, udevRule: true, usbAccess: true } };
    if (name === "welcome-linux-system") store.env = { ...store.env, detail: null, transport: "system", usbmuxAddr: "/var/run/usbmuxd", linux: { ...linux, usbmuxdInstalled: true, usbmuxdRunning: true, builtIn: false, usbAccess: null } };
    if (name === "err-linux-conflict") store.env = { ...store.env, detail: null, linux: { ...linux, udevRule: true, usbAccess: true, usbmuxdInstalled: true, usbmuxdRunning: true, conflict: "systemTookDevice" } };
    if (name.startsWith("err-linux")) store.envDialog = true;
    return;
  }
  if (name === "batch" || name === "batch-sheet") {
    store.page = "batch";
    store.devices = batch();
    if (name === "batch-sheet") store.sheet = "U3";
    return;
  }
  if (name === "batch-empty") { store.page = "batch"; return; }
  if (name === "settings") { store.page = "settings"; return; }
  store.started = true;
  if (name === "wait" || name === "done") {
    store.paired = [{ udid: "P1", name: "王磊的 iPhone", ios: "17.5.1", time: "9:41" }];
  }
  const d = SINGLE[name];
  if (d) {
    store.devices = [d];
    store.focus = d.udid;
  }
}

export const PREVIEWS = ["welcome", "welcome-win", "err-noDriver", "welcome-linux", "welcome-linux-ok", "welcome-linux-system", "err-linux-denied", "err-linux-conflict", ...Object.keys(SINGLE), "batch", "batch-sheet", "batch-empty", "settings"];
