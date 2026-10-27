// Dev-only screen gallery: `vite` in a browser with `?preview=<name>[&theme=dark][&lang=en]`
// renders one state from fixed device views, without Tauri. Not used in the app.
import type { DeviceView, EnvReport, ErrorCode, Phase, Step } from "./api";
import type { store as Store } from "./store.svelte";

const info = (i: number, name: string, model: string, ios: string) => ({ udid: `U${i}`, name, model, productType: "", ios });
const base: DeviceView = {
  udid: "U1", order: 1, connected: true, info: info(1, "林晓的 iPhone", "iPhone 15 Pro", "18.6.2"),
  phase: "detected", error: null, failedAt: null, progress: 0, attention: false, devModeWasOff: false,
  recordKind: "remotePairing", rpVia: null, app: null, writeVia: null, locked: false, phaseSince: Date.now() - 42_000, doneAt: null,
};
const app = { bundleId: "com.customer.loopctrl", name: "LoopCtrl", version: "1.4", matchedBy: "bundleSuffix", fileSharing: false };

function dev(phase: Phase, more: Partial<DeviceView> = {}): DeviceView {
  return { ...base, phase, ...more };
}
function failed(code: ErrorCode, at: Step, more: Partial<DeviceView> = {}): DeviceView {
  return dev("failed", { error: { code, detail: `${code}: example detail from idevice` }, failedAt: at, attention: true, progress: 0.5, ...more });
}

const ERRORS: [ErrorCode, Step][] = [
  ["untrusted", "trust"], ["devModeCancelled", "devModeConfirm"], ["rebootTimeout", "reboot"],
  ["recordFailed", "generate"], ["appNotFound", "findApp"], ["writeFailed", "write"], ["verifyFailed", "verify"],
  ["disconnected", "write"], ["internal", "generate"],
];

/** One phone while pairing. */
const SOLO: Record<string, DeviceView> = {
  trust: dev("trusting", { progress: 0.08, attention: true }),
  "trust-locked": dev("trusting", { locked: true, progress: 0.08, attention: true }),
  devcheck: dev("checkingDevMode", { progress: 0.15 }),
  "devcheck-guide": dev("devModeGuide", { devModeWasOff: true, attention: true, progress: 0.2 }),
  reboot: dev("rebooting", { connected: false, devModeWasOff: true, progress: 0.3 }),
  devunlock: dev("confirmingDevMode", { devModeWasOff: true, attention: true, progress: 0.35 }),
  progress: dev("writing", { app, rpVia: "lockdownService", progress: 0.7 }),
  ...Object.fromEntries(ERRORS.map(([c, at]) => [`err-${c}`, failed(c, at)])),
};

function many(): DeviceView[] {
  const mk = (i: number, name: string, model: string, ios: string, v: Partial<DeviceView>): DeviceView =>
    ({ ...base, udid: `U${i}`, order: i, info: info(i, name, model, ios), ...v } as DeviceView);
  return [
    mk(1, "林晓的 iPhone", "iPhone 15 Pro", "18.6.2", { phase: "done", progress: 1, app, doneAt: Date.now() }),
    mk(2, "王磊的 iPhone", "iPhone 12", "17.5.1", { phase: "trusting", progress: 0.08, attention: true }),
    mk(3, "测试机 03", "iPhone XR", "16.7.10", { phase: "devModeGuide", progress: 0.15, attention: true, devModeWasOff: true, recordKind: "lockdown" }),
    mk(4, "张敏的 iPhone", "iPhone 16", "26.0.1", { phase: "generating", progress: 0.5 }),
    mk(5, "前台备用机", "iPhone 11", "18.5", { phase: "failed", progress: 0.6, attention: true, failedAt: "findApp", error: { code: "appNotFound", detail: "no LoopCtrl among user apps" } }),
  ];
}
function idle(): DeviceView[] {
  return many().map((d, i) => i === 4
    ? { ...d, phase: "failed", failedAt: "info", attention: true, progress: 0, error: { code: "unsupported", detail: "iOS 15.8" }, info: { ...d.info!, ios: "15.8" } }
    : i === 3 ? { ...d, phase: "detected", progress: 0, info: null } : { ...d, phase: "detected", progress: 0, attention: false });
}

export function applyPreview(store: typeof Store, name: string) {
  const env: EnvReport = { os: "macos", osVersion: "15.5", usbmuxOk: true, usbmuxAddr: "/var/run/usbmuxd", detail: null };
  store.env = env;
  store.info = { version: "0.2.0", mock: true, devOptions: true, cacheDir: "~/Library/Application Support/app.loopctrl.pair", updaterConfigured: false };
  switch (name) {
    case "empty": return;
    case "idle-one": store.devices = [dev("detected")]; return;
    case "idle-many": store.devices = idle(); store.paired = [{ udid: "P1", name: "前台 1 号机", ios: "17.5.1", time: "9:41" }]; return;
    case "running-many": store.running = true; store.devices = many(); store.open = ["U4"]; return;
    case "finished": store.running = true; store.devices = many().slice(0, 3).map((d) => ({ ...d, phase: "done", progress: 1, attention: false }));
      store.paired = store.devices.map((d) => ({ udid: d.udid, name: d.info!.name, ios: d.info!.ios, time: "9:41" })); return;
    case "finished-one": store.running = true; store.devices = [dev("done", { progress: 1, app })]; return;
    case "settings": store.view = "settings"; return;
    case "env": store.envSheet = true; return;
    case "err-noDriver":
      store.asWindows = true;
      store.env = { ...env, os: "windows", usbmuxOk: false, detail: "connection refused (os error 10061)" };
      store.devices = [];
      return;
    case "err-linux-denied": {
      const linux = { usbmuxdInstalled: false, usbmuxdRunning: false, builtIn: true, udevRule: false, usbAccess: false, usbDevices: 1, conflict: null } as const;
      store.env = { ...env, os: "linux", osVersion: "24.04", usbmuxAddr: "/run/user/1000/loopctrl-pair/usbmuxd.sock", transport: "builtIn",
        detail: "permission denied: /dev/bus/usb/003/012", linux };
      store.envDialog = true;
      return;
    }
  }
  const d = SOLO[name];
  if (d) { store.running = true; store.devices = [d]; }
}

export const PREVIEWS = ["empty", "idle-one", "idle-many", ...Object.keys(SOLO), "running-many", "finished", "finished-one", "settings", "env", "err-noDriver", "err-linux-denied"];
