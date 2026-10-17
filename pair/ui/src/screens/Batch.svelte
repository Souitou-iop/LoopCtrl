<script lang="ts">
  import { flip } from "svelte/animate";
  import { store } from "../lib/store.svelte";
  import { api } from "../lib/api";
  import { chipOf } from "../lib/chip";
  import Arrow from "../lib/Arrow.svelte";
  import Note from "../lib/Note.svelte";

  type Filter = "all" | "act" | "run" | "ok";
  let filter = $state<Filter>("all");
  let sortAct = $state(true);
  const t = $derived(store.t.batch);
  const devs = $derived(store.devices);
  const doneN = $derived(devs.filter((d) => d.phase === "done").length);
  const actN = $derived(devs.filter((d) => d.attention).length);
  const connected = $derived(devs.filter((d) => d.connected).length);
  const avg = $derived(devs.length ? devs.reduce((a, d) => a + d.progress, 0) / devs.length : 0);
  const list = $derived.by(() => {
    let l = devs.filter((d) => filter === "all" || (filter === "act" && d.attention) || (filter === "ok" && d.phase === "done")
      || (filter === "run" && !d.attention && d.phase !== "done"));
    if (sortAct) l = l.slice().sort((a, b) => Number(b.attention) - Number(a.attention) || a.order - b.order);
    return l;
  });

  async function resetDemo() { await api.mockReset(); for (const d of store.devices) await api.forget(d.udid); await api.mockBatch(); }
  async function clearDone() { for (const d of devs) if (d.phase === "done" || !d.connected) await api.forget(d.udid); }
</script>

<div class="titlerow"><h2 class="large-title">{t.title}</h2>
  <div class="tabrow" role="group" aria-label="mode"><button type="button" aria-pressed="false" onclick={() => store.go("single")}>{store.t.mode.single}</button><button type="button" aria-pressed="true">{store.t.mode.batch}</button></div></div>
<div class="card">
  <div class="sumrow"><span class="big">{doneN}<small>/{devs.length} {t.done}</small></span>
    <div class="meta"><span>{t.meta(connected, actN)}</span><div class="linear"><i style="width:{avg * 100}%"></i></div></div>
    {#if store.mock}<button class="btn sm" onclick={resetDemo}>{t.resetDemo}</button>
    {:else}<button class="btn sm" onclick={clearDone} disabled={!devs.some((d) => d.phase === "done" || !d.connected)}>{t.clearDone}</button>{/if}
  </div>
</div>
<div style="margin-top:12px"><Note icon="bolt">{t.hub}</Note></div>
<div class="filters">
  <div class="tabrow" role="group" aria-label="filter">
    {#each [["all", t.all], ["act", `${t.act} ${actN}`], ["run", t.run], ["ok", t.ok]] as [k, label] (k)}
      <button type="button" aria-pressed={filter === k} onclick={() => (filter = k as Filter)}>{label}</button>
    {/each}
  </div>
  <label for="sortAct">{t.sortAct}<input type="checkbox" class="switch" id="sortAct" bind:checked={sortAct}></label>
</div>
{#if list.length}
  <div class="card">
    {#each list as d (d.udid)}
      {@const chip = chipOf(d, store.t)}
      <div class="dev" role="button" tabindex="0" animate:flip={{ duration: 300 }}
        onclick={() => (store.sheet = d.udid)} onkeydown={(e) => e.key === "Enter" && (store.sheet = d.udid)}>
        <span class="ph"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="6.5" y="2.5" width="11" height="19" rx="3"/></svg></span>
        <span class="t"><b>{d.info?.name ?? "iPhone"}</b><span>{d.info?.model ?? "…"} · iOS {d.info?.ios ?? "…"} · {t.port(d.order)}</span></span>
        <span class="mini" class:bad={d.phase === "failed"}><i style="width:{d.progress * 100}%"></i></span>
        <span class="chip {chip[0]}">{#if chip[0] === "run"}<span class="inf" style="width:12px;height:12px"></span>{/if}{chip[1]}</span>
        <Arrow />
      </div>
    {/each}
  </div>
{:else}
  <div class="empty">{devs.length ? t.empty : t.none}</div>
{/if}
{#if store.mock && !devs.length}
  <div class="mockrow" style="justify-content:center"><span class="tag">{store.t.mock.tag}</span><button class="btn text" onclick={() => api.mockBatch()}>{store.t.mock.batch}</button></div>
{/if}
