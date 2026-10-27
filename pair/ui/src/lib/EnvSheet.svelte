<script lang="ts">
  // What the environment check found, per OS. Opened from the status pill.
  import { store } from "./store.svelte";
  import { api } from "./api";

  const t = $derived(store.t.env);
  const env = $derived(store.env);
  const ok = $derived(env?.usbmuxOk ?? false);
  const lx = $derived(env?.linux ?? null);
  const close = () => (store.envSheet = false);
  let installing = $state(false);
  let checking = $state(false);
  async function installRule() {
    installing = true;
    try { await api.installUdevRule(); store.toast(store.t.dialog.ruleInstalled); await store.checkEnv(); }
    catch (e) { store.toast(`${store.t.dialog.ruleFailed}: ${e}`); }
    finally { installing = false; }
  }
  async function recheck() {
    checking = true;
    try { await store.checkEnv(); } finally { checking = false; }
  }
</script>

<svelte:window onkeydown={(e) => e.key === "Escape" && close()} />
<div class="scrim bottom" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
  <div class="sheet" role="dialog" aria-labelledby="env-title"><div class="handle"></div>
    <h3 id="env-title">{t.title}</h3>
    <p class="sub">{env ? `${env.os === "windows" ? "Windows" : env.os === "linux" ? "Linux" : "macOS"} ${env.osVersion}` : t.checkingShort}</p>
    {#if store.os === "windows"}
      <div class="card">
        <div class="comp"><div class="t"><span class="title">{t.appleDevices}</span><span class="summary">{t.appleDevicesSummary}</span></div>
          <span class="end" class:ok class:bad={env && !ok}>{!env ? t.checkingShort : ok ? t.installed : t.notInstalled}</span></div>
        <div class="comp"><div class="t"><span class="title">{t.driver}</span><span class="summary">{t.driverSummary}</span></div>
          <span class="end" class:ok class:bad={env && !ok}>{!env ? t.checkingShort : ok ? t.normal : t.unavailable}</span></div>
      </div>
    {:else if store.os === "linux" && lx}
      <div class="card">
        <div class="comp"><div class="t"><span class="title">{t.lxSystem}</span><span class="summary">{t.lxSystemSummary}</span></div>
          <span class="end" class:ok={lx.usbmuxdRunning}>{lx.usbmuxdRunning ? t.running : lx.usbmuxdInstalled ? t.installed : t.notInstalled}</span></div>
        <div class="comp"><div class="t"><span class="title">{t.lxBuiltIn}</span><span class="summary">{t.lxBuiltInSummary}</span></div>
          <span class="end" class:ok={lx.builtIn && ok} class:bad={lx.builtIn && !ok}>{lx.builtIn ? (ok ? t.inUse : t.unavailable) : t.notInUse}</span></div>
        {#if lx.builtIn}
          <div class="comp"><div class="t"><span class="title">{t.lxRule}</span><span class="summary">{t.lxRuleSummary}</span></div>
            {#if lx.udevRule}<span class="end ok">{t.installed}</span>
            {:else}<span class="end"><button class="btn text" disabled={installing} onclick={installRule}>{installing ? store.t.dialog.installing : t.install}</button></span>{/if}</div>
          <div class="comp"><div class="t"><span class="title">{t.lxAccess}</span><span class="summary">/dev/bus/usb</span></div>
            <span class="end" class:ok={lx.usbAccess === true} class:bad={lx.usbAccess === false}>{lx.usbAccess === null ? t.noPhone : lx.usbAccess ? t.normal : t.denied}</span></div>
        {/if}
        {#if lx.conflict}
          <div class="comp"><div class="t"><span class="title">{t.lxConflict}</span><span class="summary">{lx.conflict === "systemTookDevice" ? t.lxConflictSystem : t.lxConflictOther}</span></div>
            <span class="end bad">!</span></div>
        {/if}
      </div>
    {:else}
      <div class="card">
        <div class="comp"><div class="t"><span class="title">usbmuxd</span><span class="summary">{env?.os === "linux" ? env.usbmuxAddr : t.macBuiltIn}</span></div>
          <span class="end" class:ok class:bad={env && !ok}>{!env ? t.checkingShort : ok ? t.noInstall : t.unavailable}</span></div>
      </div>
    {/if}
    <div class="btnrow">
      <button class="btn" onclick={close}>{t.close}</button>
      <button class="btn primary" disabled={checking} onclick={recheck}>{store.t.dialog.redetect}</button>
    </div>
  </div>
</div>
