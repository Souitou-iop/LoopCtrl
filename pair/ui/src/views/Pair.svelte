<script lang="ts">
  // The one pairing screen, for one phone or many. Connected phones are
  // listed as they are detected; 开始配对 starts all of them.
  import { flip } from "svelte/animate";
  import { store, needsUser } from "../lib/store.svelte";
  import { api, type Scenario } from "../lib/api";
  import DeviceCard from "../lib/DeviceCard.svelte";
  import Illus from "../lib/Illus.svelte";
  import MockRow from "../lib/MockRow.svelte";

  const t = $derived(store.t.home);
  const stage = $derived(store.stage);
  const list = $derived(store.shown);
  // Phones that need the user float up while pairing.
  const sorted = $derived(stage === "idle" ? list
    : list.slice().sort((a, b) => Number(needsUser(b)) - Number(needsUser(a)) || a.order - b.order));
  const solo = $derived(list.length === 1);
  const envErr = $derived(store.envCode ? store.t.errors[store.envCode] : null);

  const title = $derived(stage === "finished" ? t.titleDone : stage === "running" ? t.titleRunning
    : list.length ? t.titleFound(list.length) : t.titleEmpty);
  const subtitle = $derived(stage === "finished" ? t.subDone(store.doneCount)
    : stage === "running" ? t.subRunning(store.doneCount, list.length, store.needsYou)
    : list.length ? t.subFound : t.subEmpty);
  const avg = $derived(list.length ? list.reduce((a, d) => a + (d.phase === "done" ? 1 : d.progress), 0) / list.length : 0);

  let scenario = $state<Scenario>("ready");
  const scenarios = $derived(Object.entries(store.t.mock.scenarios) as [Scenario, string][]);
  async function resetDemo() {
    await store.stop();
    await api.mockReset();
    for (const d of store.devices) await api.forget(d.udid);
    store.devices = [];
  }
</script>

<div class="scroll">
  <header class="head">
    <h1 class="large-title">{title}</h1>
    <p class="subtitle">{subtitle}</p>
    {#if stage !== "idle" && list.length > 1}<div class="linear wide"><i style="width:{avg * 100}%"></i></div>{/if}
  </header>

  {#if envErr}
    <div class="banner">
      <span class="errc">!</span>
      <div class="t"><b>{envErr.title}</b><span>{envErr.body}</span></div>
      <button class="btn sm" onclick={() => (store.envDialog = true)}>{t.howToFix}</button>
    </div>
  {/if}

  {#if stage === "finished"}
    <div class="card donecard">
      <span class="big-ok"><svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></span>
      <div class="later">
        <div class="small-title flush">{t.later}</div>
        <div class="li"><b>{t.afterReboot}</b><span>{t.afterRebootSummary}</span></div>
        <div class="li"><b>{t.noMore}</b><span>{t.noMoreSummary}</span></div>
      </div>
    </div>
  {/if}

  {#if list.length}
    <div class="devlist">
      {#each sorted as d (d.udid)}
        <div animate:flip={{ duration: 300 }}><DeviceCard {d} solo={solo && stage !== "idle"} /></div>
      {/each}
    </div>
  {:else}
    <div class="card"><div class="hero">
      <Illus kind="cable" />
      <h2>{t.heroTitle}</h2>
      <p>{t.heroBody}</p>
      {#if !envErr}<span class="waiting"><span class="inf"></span>{t.detecting}</span>{/if}
    </div></div>
  {/if}

  {#if stage === "idle" && store.paired.length}
    <div class="small-title">{t.paired}</div>
    <div class="card">
      {#each store.paired as p (p.udid)}
        <div class="comp"><span class="okc sm"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></span>
          <div class="t"><span class="title">{p.name}</span><span class="summary">iOS {p.ios}</span></div><span class="end">{p.time}</span></div>
      {/each}
    </div>
  {/if}

  <MockRow>
    <select class="select" bind:value={scenario} aria-label="scenario">
      {#each scenarios as [k, label] (k)}<option value={k}>{label}</option>{/each}
    </select>
    <button class="btn text" onclick={() => api.mockPlug(scenario)}>{store.t.mock.plug}</button>
    <button class="btn text" onclick={() => api.mockBatch()}>{store.t.mock.batch}</button>
    <button class="btn text" onclick={resetDemo}>{store.t.mock.reset}</button>
  </MockRow>
</div>

<footer class="bar">
  <span class="barnote">
    {#if stage === "idle"}
      {#if !list.length}<span class="inf"></span>{t.waiting}
      {:else if store.ready.length}<span class="dotok"></span>{t.readyN(store.ready.length)} · {t.hub}
      {:else if list.some((d) => !d.info)}<span class="inf"></span>{t.detecting}
      {:else}{t.noneReady}{/if}
    {:else if stage === "running"}{t.runningNote}
    {:else}{t.doneNote(store.paired.length)}{/if}
  </span>
  {#if stage === "idle"}
    <button class="btn primary wide" disabled={!store.ready.length || !!store.envCode} onclick={() => store.start()}>{t.start(store.ready.length)}</button>
  {:else if stage === "running"}
    <button class="btn wide" onclick={() => store.stop()}>{t.stop}</button>
  {:else}
    <button class="btn primary wide" onclick={() => store.finish()}>{t.finish}</button>
  {/if}
</footer>
