// App state: device views from pair-core, plus what only the UI knows
// (page, single-mode focus, the phones paired this session, preferences).
import { api, envProblem, type AppInfo, type DeviceView, type EnvReport, type Phase, type Step } from "./api";
import { dicts, type Lang } from "./i18n";

export type Page = "single" | "batch" | "settings";
export type Theme = "auto" | "light" | "dark";
export type Screen = "welcome" | "wait" | "device" | "trust" | "devcheck" | "reboot" | "devunlock" | "progress" | "done";

function load<T extends string>(key: string, fallback: T, allowed: readonly T[]): T {
  try {
    const v = localStorage.getItem(key) as T | null;
    if (v && allowed.includes(v)) return v;
  } catch {}
  return fallback;
}
function readRaw(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}
function save(key: string, v: string) {
  try { localStorage.setItem(key, v); } catch {}
}

const SCREEN_OF_PHASE: Record<Phase, Screen> = {
  detected: "device", trusting: "trust", checkingDevMode: "devcheck", revealingDevMode: "devcheck",
  devModeGuide: "devcheck", rebooting: "reboot", confirmingDevMode: "devunlock", generating: "progress",
  findingApp: "progress", writing: "progress", verifying: "progress", done: "done", failed: "progress",
};
const SCREEN_OF_STEP: Record<Step, Screen> = {
  info: "device", trust: "trust", devModeCheck: "devcheck", reboot: "reboot", devModeConfirm: "devunlock",
  generate: "progress", findApp: "progress", write: "progress", verify: "progress",
};

export function screenOf(d: DeviceView): Screen {
  if (d.phase === "failed") return SCREEN_OF_STEP[d.failedAt ?? "info"];
  return SCREEN_OF_PHASE[d.phase];
}

export interface Paired { udid: string; name: string; ios: string; time: string }

class Store {
  devices = $state<DeviceView[]>([]);
  env = $state<EnvReport | null>(null);
  info = $state<AppInfo | null>(null);
  watchOk = $state(true);
  page = $state<Page>("single");
  /** Single mode left the welcome screen. */
  started = $state(false);
  focus = $state<string | null>(null);
  paired = $state<Paired[]>([]);
  /** Environment problem shown as a dialog (from 开始配对). */
  envDialog = $state(false);
  sheet = $state<string | null>(null);
  snack = $state<string | null>(null);
  lang = $state<Lang>(load("lang", "zh-CN", ["zh-CN", "en"]));
  theme = $state<Theme>(load("theme", "auto", ["auto", "light", "dark"]));
  /** Developer option: show the Windows environment card on any OS. */
  asWindows = $state(false);
  driverMissing = $state(false);
  lastUpdateCheck = $state<string | null>(readRaw("lastUpdateCheck"));
  /** Phones single mode should not come back to (unsupported). */
  skipped = $state<string[]>([]);

  t = $derived(dicts[this.lang]);
  mock = $derived(this.info?.mock ?? false);
  os = $derived(this.asWindows ? "windows" : (this.env?.os ?? "macos"));
  /** The environment problem to explain (dialog code), if any. */
  envCode = $derived(envProblem(this.env, this.os));
  private envPoll: ReturnType<typeof setInterval> | null = null;

  /** The phone single mode is showing. */
  current = $derived(this.devices.find((d) => d.udid === this.focus) ?? null);

  screen = $derived.by((): Screen => {
    if (!this.started) return "welcome";
    const d = this.current;
    return d ? screenOf(d) : "wait";
  });

  constructor() {
    $effect.root(() => {
      $effect(() => {
        const root = document.documentElement;
        if (this.theme === "auto") root.removeAttribute("data-theme");
        else root.setAttribute("data-theme", this.theme);
        root.lang = this.lang;
        document.title = this.t.appName;
      });
    });
  }

  setTheme(t: Theme) { this.theme = t; save("theme", t); }
  setLang(l: Lang) { this.lang = l; save("lang", l); }

  async init() {
    this.info = await api.appInfo().catch(() => null);
    await api.onEvent((e) => {
      if (e.type === "device") this.upsert(e.device);
      else if (e.type === "removed") this.devices = this.devices.filter((d) => d.udid !== e.udid);
      else this.watchOk = e.ok;
    });
    this.devices = await api.devices().catch(() => []);
    this.pickFocus();
    await this.checkEnv();
  }

  async checkEnv() {
    this.env = await api.envCheck().catch(() => null);
    return this.env;
  }

  upsert(d: DeviceView) {
    const i = this.devices.findIndex((x) => x.udid === d.udid);
    if (i < 0) this.devices = [...this.devices, d].sort((a, b) => a.order - b.order);
    else this.devices[i] = d;
    if (d.phase === "done" && !this.paired.some((p) => p.udid === d.udid)) {
      const at = new Date(d.doneAt ?? Date.now());
      this.paired = [...this.paired, {
        udid: d.udid, name: d.info?.name ?? "iPhone", ios: d.info?.ios ?? "",
        time: `${at.getHours()}:${String(at.getMinutes()).padStart(2, "0")}`,
      }];
    }
    this.pickFocus();
  }

  /** Single mode follows one phone: keep it while it is there, else take the
   *  next connected one not paired this session. */
  pickFocus() {
    const cur = this.current;
    // Keep a phone that is mid-flow even while unplugged (reboot, or the
    // "unplugged" dialog that resumes on replug); drop one that never started.
    if (cur && !this.skipped.includes(cur.udid) && (cur.connected || cur.phase !== "detected")) return;
    const next = this.devices.find((d) => d.connected && d.phase !== "done"
      && !this.paired.some((p) => p.udid === d.udid) && !this.skipped.includes(d.udid));
    this.focus = next?.udid ?? null;
  }

  async start() {
    await this.checkEnv();
    if (this.envCode) { this.envDialog = true; return; }
    this.started = true;
    this.pickFocus();
    // Linux built-in mode: a phone plugged in later may turn out to be
    // unreadable (no udev rule) or held by the system usbmuxd. Look again
    // while waiting so that is explained instead of waiting forever.
    if (this.os === "linux" && !this.envPoll) {
      this.envPoll = setInterval(async () => {
        if (!this.started || this.current || this.envDialog) return;
        await this.checkEnv();
        if (this.envCode) this.envDialog = true;
      }, 3000);
    }
  }

  /** Single mode will not come back to this phone. */
  skip(udid: string) {
    this.skipped = [...this.skipped, udid];
    this.focus = null;
    this.pickFocus();
  }

  /** 继续配对下一台: leave the finished phone behind; the next attach takes focus. */
  nextDevice() {
    if (this.current) this.skip(this.current.udid);
    else this.pickFocus();
  }

  /** Back to the welcome screen. A finished phone is not shown again. */
  finish() {
    const cur = this.current;
    if (cur && cur.phase === "done") this.skipped = [...this.skipped, cur.udid];
    this.started = false;
    this.focus = null;
    this.pickFocus();
  }

  go(p: Page) {
    this.page = p;
    this.sheet = null;
    // Batch starts every phone by itself; single waits for 继续.
    void api.setAutoBegin(p === "batch").catch(() => {});
    if (p === "single") this.pickFocus();
  }

  toast(msg: string) {
    this.snack = msg;
    clearTimeout((this as any)._snackT);
    (this as any)._snackT = setTimeout(() => (this.snack = null), 2200);
  }

  markUpdateChecked() {
    const n = new Date();
    this.lastUpdateCheck = n.toLocaleString(this.lang, { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
    save("lastUpdateCheck", this.lastUpdateCheck);
  }
}

export const store = new Store();
