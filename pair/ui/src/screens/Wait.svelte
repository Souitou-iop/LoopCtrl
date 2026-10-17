<script lang="ts">
  import { store } from "../lib/store.svelte";
  import { api, type Scenario } from "../lib/api";
  import Illus from "../lib/Illus.svelte";
  import MockRow from "../lib/MockRow.svelte";
  import SessionList from "../lib/SessionList.svelte";
  const t = $derived(store.t.wait);
  let scenario = $state<Scenario>("ready");
  const scenarios = $derived(Object.entries(store.t.mock.scenarios) as [Scenario, string][]);
</script>

<h2 class="large-title">{t.title}</h2>
<p class="subtitle">{t.subtitle}</p>
<div class="small-title">{t.status}</div>
<div class="card"><div class="hero">
  <Illus kind="cable" />
  <h2>{t.heading}</h2>
  <p>{t.body}</p>
  <span class="waiting"><span class="inf"></span>{t.waiting}</span>
</div></div>
{#if store.paired.length}
  <div class="small-title">{t.sessionDone}</div>
  <SessionList />
{/if}
<div class="btnrow left"><button class="btn text" onclick={() => store.finish()}>{t.back}</button></div>
<MockRow>
  <select class="select" bind:value={scenario} aria-label="scenario">
    {#each scenarios as [k, label] (k)}<option value={k}>{label}</option>{/each}
  </select>
  <button class="btn text" onclick={() => api.mockPlug(scenario)}>{store.t.mock.plug}</button>
</MockRow>
