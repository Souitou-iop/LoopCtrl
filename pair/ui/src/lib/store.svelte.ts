// App state: device views from pair-core, plus what only the UI knows
// (whether a pairing run is on, the phones paired this session, preferences).
//
// There is one flow for any number of phones: connected iPhones are listed as
// they are detected, and nothing happens to them until 开始配对. Starting turns
// pair-core's auto-begin on, which begins every waiting phone and any phone
// plugged in while the run lasts.
import { api, envProblem, type AppInfo, type DeviceView, type EnvReport } from "./api";
import { dicts, type Lang } from "./i18n";

export type View = "pair" | "settings";
export type Theme = "auto" | "light" | "dark";
/** idle: listing phones, waiting for 开始配对. running: pairing. finished: every phone settled. */
export type Stage = "idle" | "running" | "finished";

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

/** Pairing can't go further for this phone without something new from the user (old iOS). */
export const isUnsupported = (d: DeviceView) => d.phase === "failed" && d.error?.code === "unsupported";
/** Nothing left to do for this phone in this run. */
export const isSettled = (d: DeviceView) => d.phase === "done" || isUnsupported(d);
/** Something to do on the phone, or an error to fix. The backend does not flag a Trust prompt as attention. */
export const needsUser = (d: DeviceView) => !isUnsupported(d) && (d.attention || d.phase === "trusting" || d.phase === "failed");
/** Waiting for 开始配对. */
export const isReady = (d: DeviceView) => d.connected && d.phase === "detected" && !!d.info;

export interface Paired { udid: string; name: string; ios: string; time: string }

class Store {
  devices = $state<DeviceView[]>([]);
  env = $state<EnvReport | null>(null);
  info = $state<AppInfo | null>(null);
  watchOk = $state(true);
  view = $state<View>("pair");
  running = $state(false);
  /** Phones put away by 完成; they stay listed under 本次已配对 only. */
  hidden = $state<string[]>([]);
  /** Phones whose step list the user opened. */
  open = $state<string[]>([]);
  paired = $state<Paired[]>([]);
  envDialog = $state(false);
  envSheet = $state(false);
  snack = $state<string | null>(null);
  lang = $state<Lang>(load("lang", "zh-CN", ["zh-CN", "en"]));
  theme = $state<Theme>(load("theme", "auto", ["auto", "light", "dark"]));
  /** Developer option: show the Windows environment card on any OS. */
  asWindows = $state(false);
  driverMissing = $state(false);
  lastUpdateCheck = $state<string | null>(readRaw("lastUpdateCheck"));

  t = $derived(dicts[this.lang]);
  mock = $derived(this.info?.mock ?? false);
  os = $derived(this.asWindows ? "windows" : (this.env?.os ?? "macos"));
  /** The environment problem to explain, if any. */
  envCode = $derived(envProblem(this.env, this.os));

  /** Phones on screen: not put away, and not a never-started phone that was unplugged. */
  shown = $derived(this.devices.filter((d) => !this.hidden.includes(d.udid) && (d.connected || d.phase !== "detected")));
  ready = $derived(this.shown.filter(isReady));
  doneCount = $derived(this.shown.filter((d) => d.phase === "done").length);
  needsYou = $derived(this.shown.filter(needsUser).length);
  stage = $derived.by((): Stage => {
    if (!this.running) return "idle";
    const s = this.shown;
    return s.length && s.every(isSettled) && s.some((d) => d.phase === "done") ? "finished" : "running";
  });

  private envPoll: ReturnType<typeof setInterval> | null = null;
  private snackT: ReturnType<typeof setTimeout> | undefined;

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
    // Phones wait for 开始配对.
    await api.setAutoBegin(false).catch(() => {});
    await api.onEvent((e) => {
      if (e.type === "device") this.upsert(e.device);
      else if (e.type === "removed") this.devices = this.devices.filter((d) => d.udid !== e.udid);
      else this.watchOk = e.ok;
    });
    this.devices = await api.devices().catch(() => []);
    await this.checkEnv();
    // Look again while something is wrong, so a fix shows up without a click.
    // On Linux also while no phone is listed: a phone plugged in later may be
    // unreadable (no udev rule) or held by the system usbmuxd.
    this.envPoll ??= setInterval(() => {
      if (this.envCode || (this.os === "linux" && !this.shown.length)) void this.checkEnv();
    }, 3000);
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
  }

  async start() {
    await this.checkEnv();
    if (this.envCode) { this.envDialog = true; return; }
    this.running = true;
    await api.setAutoBegin(true).catch(() => {});
  }

  /** Back to the list: phones not finished return to waiting; finished ones move to 本次已配对. */
  async stop() {
    this.running = false;
    await api.setAutoBegin(false).catch(() => {});
    for (const d of this.shown) {
      if (d.phase !== "detected" && !isSettled(d)) void api.command(d.udid, "cancel").catch(() => {});
    }
    this.hidden = [...this.hidden, ...this.shown.filter((d) => d.phase === "done").map((d) => d.udid)];
    this.open = [];
  }

  /** 完成: put the finished phones away and wait for the next ones. */
  async finish() {
    this.running = false;
    await api.setAutoBegin(false).catch(() => {});
    this.hidden = [...this.hidden, ...this.shown.filter(isSettled).map((d) => d.udid)];
    this.open = [];
  }

  toggle(udid: string) {
    this.open = this.open.includes(udid) ? this.open.filter((u) => u !== udid) : [...this.open, udid];
  }

  toast(msg: string) {
    this.snack = msg;
    clearTimeout(this.snackT);
    this.snackT = setTimeout(() => (this.snack = null), 2200);
  }

  markUpdateChecked() {
    const n = new Date();
    this.lastUpdateCheck = n.toLocaleString(this.lang, { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" });
    save("lastUpdateCheck", this.lastUpdateCheck);
  }
}

export const store = new Store();
