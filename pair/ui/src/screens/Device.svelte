<script lang="ts">
  import { store } from "../lib/store.svelte";
  import { api } from "../lib/api";
  import MockRow from "../lib/MockRow.svelte";
  const t = $derived(store.t.device);
  const d = $derived(store.current!);
</script>

<h2 class="large-title">{d.info?.name ?? "iPhone"}</h2>
<p class="subtitle">{t.subtitle}</p>
<div class="cols">
  <div>
    <div class="small-title">{t.info}</div>
    <div class="card">
      <div class="comp"><div class="t"><span class="title">{t.model}</span></div><span class="end">{d.info?.model ?? "…"}</span></div>
      <div class="comp"><div class="t"><span class="title">{t.ios}</span></div><span class="end">{d.info?.ios ?? "…"}</span></div>
      <div class="comp"><div class="t"><span class="title">{t.devMode}</span><span class="summary">{t.devModeSummary}</span></div><span class="end">{t.pending}</span></div>
    </div>
  </div>
  <div>
    <div class="small-title">{t.next}</div>
    <div class="card"><div class="comp"><div class="t"><span class="title">{t.nextTitle}</span><span class="summary">{t.nextSummary}</span></div></div></div>
  </div>
</div>
<div class="btnrow" style="padding-top:22px">
  <button class="btn primary" disabled={!d.info} onclick={() => api.command(d.udid, "begin")}>{d.info ? t.continue : t.reading}</button>
</div>
<MockRow><button class="btn text" onclick={() => api.mockPhone(d.udid, "unplug")}>{store.t.mock.unplug}</button></MockRow>
