<script lang="ts">
  // One dialog for every error: device errors (single mode) and the
  // environment check. Copy comes from i18n `errors`.
  import { store } from "./store.svelte";
  import { api, APPLE_DEVICES_STORE, APPLE_DEVICES_WEB, type DeviceView, type ErrorCode } from "./api";
  import MockRow from "./MockRow.svelte";

  let { device = null, envCode = null, onclose = () => {} }: { device?: DeviceView | null; envCode?: ErrorCode | null; onclose?: () => void } = $props();
  const code = $derived<ErrorCode>(envCode ?? device?.error?.code ?? "internal");
  const e = $derived(store.t.errors[code]);
  const b = $derived(store.t.dialog);
  let showDetail = $state(false);
  const detail = $derived(envCode ? store.env?.detail : device?.error?.detail);

  type Btn = { label: string; run: () => void };
  const cmd = (c: "retry" | "recheck" | "cancel") => () => device && api.command(device.udid, c);
  const cancelToWelcome = () => { if (device) void api.command(device.udid, "cancel"); store.finish(); };
  async function redetect() {
    const env = await store.checkEnv();
    if (env?.usbmuxOk) { onclose(); store.started = true; store.pickFocus(); }
  }
  async function openStore() {
    try { await api.openUrl(APPLE_DEVICES_STORE); } catch { await api.openUrl(APPLE_DEVICES_WEB); }
  }

  const buttons = $derived.by((): [Btn, Btn] => {
    switch (code) {
      case "noDriver": return [{ label: b.openStore, run: openStore }, { label: b.redetect, run: redetect }];
      case "noUsbmux": return [{ label: b.cancel, run: onclose }, { label: b.redetect, run: redetect }];
      case "devModeCancelled": return [{ label: b.later, run: cancelToWelcome }, { label: b.recheck, run: cmd("retry") }];
      case "rebootTimeout": return [{ label: b.recheck, run: cmd("recheck") }, { label: b.keepWaiting, run: cmd("retry") }];
      case "unsupported": return [{ label: b.back, run: () => { store.finish(); } }, { label: b.ok, run: () => device && store.skip(device.udid) }];
      default: return [{ label: b.cancel, run: cancelToWelcome }, { label: b.retry, run: cmd("retry") }];
    }
  });
</script>

<div class="scrim">
  <div class="dialog" role="dialog" aria-labelledby="dlg-title">
    <h3 id="dlg-title">{e.title}</h3>
    <p>{e.body}</p>
    <ol>{#each e.steps as s (s)}<li>{s}</li>{/each}</ol>
    {#if e.hint}<p class="hint">{e.hint}</p>{/if}
    {#if detail}
      {#if showDetail}<p class="detail">{detail}</p>
      {:else}<p class="detail"><button class="link" onclick={() => (showDetail = true)}>{b.detail}</button></p>{/if}
    {/if}
    <div class="btnrow">
      <button class="btn" onclick={buttons[0].run}>{buttons[0].label}</button>
      <button class="btn primary" onclick={buttons[1].run}>{buttons[1].label}</button>
    </div>
    {#if device && code === "appNotFound"}
      <MockRow><button class="btn text" onclick={() => api.mockPhone(device.udid, "installApp")}>{store.t.mock.install}</button></MockRow>
    {/if}
    {#if device && code === "disconnected"}
      <MockRow><button class="btn text" onclick={() => api.mockPhone(device.udid, "plug")}>{store.t.mock.plug}</button></MockRow>
    {/if}
    {#if device && code === "untrusted"}
      <MockRow><button class="btn text" onclick={async () => { await api.mockPhone(device.udid, "unplug"); setTimeout(() => api.mockPhone(device.udid, "plug"), 600); }}>{store.t.mock.unplug} → {store.t.mock.plug}</button></MockRow>
    {/if}
  </div>
</div>
