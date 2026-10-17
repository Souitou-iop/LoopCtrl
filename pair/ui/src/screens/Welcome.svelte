<script lang="ts">
  import { store } from "../lib/store.svelte";
  import Arrow from "../lib/Arrow.svelte";
  const t = $derived(store.t.welcome);
  const env = $derived(store.env);
  const ok = $derived(env?.usbmuxOk ?? false);
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
    {:else}
      <div class="card">
        <div class="comp"><div class="t"><span class="title">{env?.os === "linux" ? "Linux" : "macOS"} {env?.osVersion ?? ""}</span><span class="summary">{env?.os === "linux" ? "usbmuxd" : t.macBuiltIn}</span></div>
          <span class="end" class:ok class:bad={env && !ok}>{!env ? t.checking : ok ? t.noInstall : t.unavailable}</span></div>
      </div>
    {/if}
  </div>
</div>
<div class="btnrow" style="padding-top:22px"><button class="btn primary" onclick={() => store.start()}>{t.start}</button></div>
