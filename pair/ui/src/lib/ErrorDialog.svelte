<script lang="ts">
  // How to fix an environment problem (Apple Devices missing, usbmuxd, Linux
  // USB access). Phone errors are shown in the phone's own card instead.
  import { store } from "./store.svelte";
  import { api, APPLE_DEVICES_STORE, APPLE_DEVICES_WEB, type ErrorCode } from "./api";

  let { code, onclose }: { code: ErrorCode; onclose: () => void } = $props();
  const e = $derived(store.t.errors[code]);
  const b = $derived(store.t.dialog);
  let showDetail = $state(false);
  const detail = $derived(store.env?.detail);

  type Btn = { label: string; run: () => void };
  async function redetect() {
    await store.checkEnv();
    if (!store.envCode) onclose();
  }
  let installing = $state(false);
  async function installRule() {
    installing = true;
    try { await api.installUdevRule(); store.toast(b.ruleInstalled); await redetect(); }
    catch (err) { store.toast(`${b.ruleFailed}: ${err}`); }
    finally { installing = false; }
  }
  async function openStore() {
    try { await api.openUrl(APPLE_DEVICES_STORE); } catch { await api.openUrl(APPLE_DEVICES_WEB); }
  }

  const buttons = $derived.by((): [Btn, Btn] => {
    switch (code) {
      case "noDriver": return [{ label: b.openStore, run: openStore }, { label: b.redetect, run: redetect }];
      case "usbDenied": return [{ label: b.redetect, run: redetect }, { label: installing ? b.installing : b.installRule, run: installRule }];
      default: return [{ label: b.cancel, run: onclose }, { label: b.redetect, run: redetect }];
    }
  });
</script>

<svelte:window onkeydown={(ev) => ev.key === "Escape" && onclose()} />
<div class="scrim" role="presentation" onclick={(ev) => ev.target === ev.currentTarget && onclose()}>
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
  </div>
</div>
