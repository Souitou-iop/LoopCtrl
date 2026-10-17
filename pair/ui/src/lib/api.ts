// Types mirror pair-core's serde output (camelCase).
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export type Phase =
  | "detected" | "trusting" | "checkingDevMode" | "revealingDevMode" | "devModeGuide" | "rebooting"
  | "confirmingDevMode" | "generating" | "findingApp" | "writing" | "verifying" | "done" | "failed";
export type Step = "info" | "trust" | "devModeCheck" | "reboot" | "devModeConfirm" | "generate" | "findApp" | "write" | "verify";
export type ErrorCode =
  | "noDriver" | "noUsbmux" | "untrusted" | "devModeCancelled" | "rebootTimeout" | "unsupported" | "recordFailed"
  | "appNotFound" | "writeFailed" | "verifyFailed" | "disconnected" | "internal";
export type UserCommand = "begin" | "retry" | "recheck" | "cancel";
export type PhoneAction = "trust" | "dontTrust" | "unlock" | "restart" | "turnOn" | "cancel" | "installApp" | "unplug" | "plug";
export type Scenario = "ready" | "devModeOff" | "noRpService" | "legacy16" | "early17" | "noApp" | "rebootHangs" | "unsupported" | "locked";

export interface DeviceInfo { udid: string; name: string; model: string; productType: string; ios: string }
export interface PairError { code: ErrorCode; detail: string }
export interface AppMatch { bundleId: string; name: string; version: string | null; matchedBy: string; fileSharing: boolean }
export interface DeviceView {
  udid: string; order: number; connected: boolean; info: DeviceInfo | null; phase: Phase;
  error: PairError | null; failedAt: Step | null; progress: number; attention: boolean; devModeWasOff: boolean;
  recordKind: "remotePairing" | "lockdown" | null; rpVia: "lockdownService" | "coreDeviceProxy" | "cached" | null;
  app: AppMatch | null; writeVia: "vendContainer" | "vendDocuments" | null; locked: boolean;
  phaseSince: number; doneAt: number | null;
}
export interface EnvReport { os: "windows" | "macos" | "linux"; osVersion: string; usbmuxOk: boolean; usbmuxAddr: string; detail: string | null }
export interface AppInfo { version: string; mock: boolean; devOptions: boolean; cacheDir: string; updaterConfigured: boolean }
export type UpdateStatus =
  | { status: "notConfigured" } | { status: "upToDate" }
  | { status: "available"; version: string; notes: string | null } | { status: "error"; message: string };

export type CoreEvent =
  | { type: "device"; device: DeviceView }
  | { type: "removed"; udid: string }
  | { type: "watch"; ok: boolean; detail: string | null };

const inTauri = "__TAURI_INTERNALS__" in window;

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!inTauri) throw new Error(`not running inside Tauri (${cmd})`);
  return invoke<T>(cmd, args);
}

export const api = {
  inTauri,
  appInfo: () => call<AppInfo>("app_info"),
  envCheck: () => call<EnvReport>("env_check"),
  devices: () => call<DeviceView[]>("devices"),
  command: (udid: string, cmd: UserCommand) => call<void>("device_command", { udid, cmd }),
  setAutoBegin: (on: boolean) => call<void>("set_auto_begin", { on }),
  forget: (udid: string) => call<void>("forget_device", { udid }),
  setMock: (on: boolean) => call<void>("set_mock", { on }),
  mockPlug: (scenario: Scenario) => call<void>("mock_plug", { scenario }),
  mockBatch: () => call<void>("mock_batch"),
  mockPhone: (udid: string, action: PhoneAction) => call<void>("mock_phone", { udid, action }),
  mockReset: () => call<void>("mock_reset"),
  mockDriverMissing: (missing: boolean) => call<void>("mock_driver_missing", { missing }),
  checkUpdate: () => call<UpdateStatus>("check_update"),
  onEvent: (f: (e: CoreEvent) => void) => (inTauri ? listen<CoreEvent>("pair-event", (e) => f(e.payload)) : Promise.resolve(() => {})),
  openUrl: async (url: string) => {
    if (!inTauri) return void window.open(url, "_blank");
    const { openUrl } = await import("@tauri-apps/plugin-opener");
    await openUrl(url);
  },
};

export const APPLE_DEVICES_STORE = "ms-windows-store://pdp/?ProductId=9NP83LWLPZ9K";
export const APPLE_DEVICES_WEB = "https://apps.microsoft.com/detail/9NP83LWLPZ9K";
export const SOURCE_URL = "https://github.com/Souitou-iop/LoopCtrl-Pair";
