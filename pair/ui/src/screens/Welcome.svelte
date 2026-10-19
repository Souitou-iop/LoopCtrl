<script lang="ts">
  import { store } from "../lib/store.svelte";
  import Arrow from "../lib/Arrow.svelte";
  import { api } from "../lib/api";
  const t = $derived(store.t.welcome);
  const env = $derived(store.env);
  const ok = $derived(env?.usbmuxOk ?? false);
  const lx = $derived(env?.linux ?? null);
  let installing = $state(false);
  async function installRule() {
    installing = true;
    try { await api.installUdevRule(); store.snack = store.t.dialog.ruleInstalled; await store.checkEnv(); }
    catch (e) { store.snack = `${store.t.dialog.ruleFailed}: ${e}`; }
    finally { installing = false; }
  }
</script>

<div class="titlerow"><h2 class="large-title">{t.title}</h2>
  <div class="tabrow" role="group" aria-label="mode"><button type="button" aria-pressed="true">{store.t.mode.single}</button><button type="button" aria-pressed="false" onclick={() => store.go("batch")}>{store.t.mode.batch}</button></div></div>
<p class="subtitle">{t.subtitle}</p>
<div class="cols">
  <div>
    <div class="small-title">LoopCtrl</div>
    <div class="card"><div class="comp"><img class="lead-icon" src="/icon.png" alt="" width="44" height="44"><div class="t"><span class="title">{t.cardTitle}</span><span class="summary">{t.cardSummary}</span></div></div></div>
    <div class="small-title">{t.manyTitle}</div>
    <div class="card"><div class="comp press" role="button" tabindex="0" onclick={() => store.go("batch")} onkeydown={(e) => e.key === "Enter" && store.go("batch")}><div class="t"><span class="title">{t.batch}</span><span class="summary">{t.batchSummary}</span></div><Arrow /></div></div>
  </div>
  <div>
    <div class="small-title">{t.env}</div>
    {#if store.os === "windows"}
      <div class="card">
        <div class="comp"><div class="t"><span class="title">{t.appleDevices}</span><span class="summary">{t.appleDevicesSummary}</span></div>
          <span class="end" class:ok class:bad={env && !ok}>{!env ? t.checking : ok ? t.installed : t.notInstalled}</span></div>
        <div class="comp"><div class="t"><span class="title">{t.driver}</span><span class="summary">{t.driverSummary}</span></div>
          <span class="end" class:ok class:bad={env && !ok}>{!env ? t.checking : ok ? t.normal : t.unavailable}</span></div>
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
        <div class="comp"><div class="t"><span class="title">{env?.os === "linux" ? "Linux" : "macOS"} {env?.osVersion ?? ""}</span><span class="summary">{env?.os === "linux" ? "usbmuxd" : t.macBuiltIn}</span></div>
          <span class="end" class:ok class:bad={env && !ok}>{!env ? t.checking : ok ? t.noInstall : t.unavailable}</span></div>
      </div>
    {/if}
  </div>
</div>
<div class="btnrow" style="padding-top:22px"><button class="btn primary" onclick={() => store.start()}>{t.start}</button></div>
