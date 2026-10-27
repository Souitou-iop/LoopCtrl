<script lang="ts">
  // What this phone needs from the user right now, inside its card: the
  // prompt to answer on the iPhone, or an error with its fix. `hero`: the only
  // phone on screen, so the block gets an illustration and more room.
  import { onDestroy } from "svelte";
  import { store, isUnsupported } from "./store.svelte";
  import { api, type DeviceView } from "./api";
  import Illus from "./Illus.svelte";
  import MockRow from "./MockRow.svelte";

  let { d, hero = false }: { d: DeviceView; hero?: boolean } = $props();
  const g = $derived(store.t.guide);
  const b = $derived(store.t.dialog);
  const m = $derived(store.t.mock);

  let now = $state(Date.now());
  const iv = setInterval(() => (now = Date.now()), 1000);
  onDestroy(() => clearInterval(iv));
  const clock = $derived.by(() => {
    const s = Math.max(0, Math.floor((now - d.phaseSince) / 1000));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  });

  type Kind = "trust" | "devOff" | "reboot" | "unlock" | "unplugged" | "error";
  const kind = $derived.by((): Kind | null => {
    if (d.phase === "failed") return "error";
    if (!d.connected && d.phase !== "rebooting" && d.phase !== "detected" && d.phase !== "done") return "unplugged";
    switch (d.phase) {
      case "trusting": return "trust";
      case "devModeGuide": return "devOff";
      case "rebooting": return "reboot";
      case "confirmingDevMode": return "unlock";
      default: return null;
    }
  });
  const err = $derived(d.phase === "failed" ? store.t.errors[d.error?.code ?? "internal"] : null);
  const text = $derived.by((): [string, string] | null => {
    switch (kind) {
      case "trust": return d.locked ? g.locked : g.trust;
      case "devOff": return g.devOff;
      case "reboot": return g.reboot;
      case "unlock": return g.unlock;
      case "unplugged": return g.unplugged;
      case "error": return err ? [err.title, err.body] : null;
      default: return null;
    }
  });
  const illus = $derived(kind === "trust" ? "trust" : kind === "reboot" ? "reboot" : kind === "unlock" ? "prompt" : kind === "unplugged" ? "cable" : null);
  let showDetail = $state(false);

  type Btn = { label: string; run: () => void; primary?: boolean };
  const cmd = (c: "retry" | "recheck") => () => void api.command(d.udid, c);
  const buttons = $derived.by((): Btn[] => {
    if (kind === "unlock") return [{ label: g.noPrompt, run: cmd("recheck") }];
    if (kind !== "error") return [];
    switch (d.error?.code) {
      case "unsupported": return [];
      case "devModeCancelled": return [{ label: b.recheck, run: cmd("retry"), primary: true }];
      case "rebootTimeout": return [{ label: b.recheck, run: cmd("recheck") }, { label: b.keepWaiting, run: cmd("retry"), primary: true }];
      default: return [{ label: b.retry, run: cmd("retry"), primary: true }];
    }
  });
</script>

{#if kind && text}
  <div class="guide" class:bad={kind === "error"} class:calm={kind === "reboot"} class:big={hero}>
    {#if hero && illus}<Illus kind={illus} />{/if}
    <div class="gt">
      <b>{text[0]}</b>
      <p>{text[1]}</p>
      {#if kind === "devOff"}
        <ol class="nums">{#each g.devSteps as s, i (i)}<li><span class="num">{i + 1}</span>{s}</li>{/each}</ol>
      {:else if kind === "error" && err}
        <ol>{#each err.steps as s (s)}<li>{s}</li>{/each}</ol>
        {#if err.hint}<p class="hint">{err.hint}</p>{/if}
        {#if d.error?.detail}
          {#if showDetail}<p class="detail">{d.error.detail}</p>
          {:else}<button class="link sm" onclick={() => (showDetail = true)}>{b.detail}</button>{/if}
        {/if}
      {/if}
      {#if kind === "reboot"}<span class="warnline">{g.noUnplug}</span>{/if}
      <div class="gfoot">
        {#if kind === "trust" || kind === "unlock" || kind === "devOff"}<span class="waiting"><span class="inf"></span>{g.waiting}</span>
        {:else if kind === "reboot"}<span class="waiting"><span class="inf"></span>{g.elapsed(clock)}</span>
        {:else if isUnsupported(d)}<span class="waiting">{g.skipped}</span>{/if}
        <span class="sp"></span>
        {#each buttons as btn (btn.label)}
          <button class="btn sm" class:primary={btn.primary} class:text={!btn.primary && kind === "unlock"} onclick={btn.run}>{btn.label}</button>
        {/each}
      </div>
      {#if !hero && store.shown.length > 1 && kind !== "reboot" && !isUnsupported(d)}<p class="hint">{g.other}</p>{/if}
      {#if kind !== "reboot" && !isUnsupported(d)}<MockRow>
        {#if kind === "trust"}
          {#if d.locked}<button class="btn text" onclick={() => api.mockPhone(d.udid, "unlock")}>{m.unlock}</button>{/if}
          <button class="btn text" onclick={() => api.mockPhone(d.udid, "trust")}>{m.trust}</button>
          <button class="btn text" onclick={() => api.mockPhone(d.udid, "dontTrust")}>{m.dontTrust}</button>
        {:else if kind === "devOff"}<button class="btn text" onclick={() => api.mockPhone(d.udid, "restart")}>{m.restart}</button>
        {:else if kind === "unlock"}
          <button class="btn text" onclick={() => api.mockPhone(d.udid, "turnOn")}>{m.turnOn}</button>
          <button class="btn text" onclick={() => api.mockPhone(d.udid, "cancel")}>{m.cancel}</button>
        {:else if kind === "unplugged" || d.error?.code === "disconnected"}<button class="btn text" onclick={() => api.mockPhone(d.udid, "plug")}>{m.plug}</button>
        {:else if d.error?.code === "appNotFound"}<button class="btn text" onclick={() => api.mockPhone(d.udid, "installApp")}>{m.install}</button>
        {:else if d.error?.code === "untrusted"}
          <button class="btn text" onclick={async () => { await api.mockPhone(d.udid, "unplug"); setTimeout(() => api.mockPhone(d.udid, "plug"), 600); }}>{m.unplug} → {m.plug}</button>
        {/if}
      </MockRow>{/if}
    </div>
  </div>
{/if}
