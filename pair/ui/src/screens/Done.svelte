<script lang="ts">
  import { store } from "../lib/store.svelte";
  import SessionList from "../lib/SessionList.svelte";
  const t = $derived(store.t.done);
  const d = $derived(store.current!);
</script>

<h2 class="large-title">{t.title}</h2>
<p class="subtitle">{d.info?.name ?? "iPhone"} · iOS {d.info?.ios ?? ""}</p>
<div class="cols">
  <div>
    <div class="small-title">{t.result}</div>
    <div class="card"><div class="hero">
      <span class="big-ok"><svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></span>
      <h2>{t.heading}</h2>
      <p>{t.body}</p>
    </div></div>
  </div>
  <div>
    <div class="small-title">{t.later}</div>
    <div class="card">
      <div class="comp"><div class="t"><span class="title">{t.afterReboot}</span><span class="summary">{t.afterRebootSummary}</span></div></div>
      <div class="comp"><div class="t"><span class="title">{t.noMore}</span><span class="summary">{t.noMoreSummary}</span></div></div>
    </div>
    <div class="small-title">{t.sessionCount(store.paired.length)}</div>
    <SessionList />
  </div>
</div>
<div class="btnrow" style="padding-top:22px"><button class="btn" onclick={() => store.finish()}>{t.finish}</button><button class="btn primary" onclick={() => store.nextDevice()}>{t.next}</button></div>
