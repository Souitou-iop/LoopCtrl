<script lang="ts">
  import { store } from "../lib/store.svelte";
  import { api } from "../lib/api";
  import Illus from "../lib/Illus.svelte";
  import MockRow from "../lib/MockRow.svelte";
  const t = $derived(store.t.trust);
  const d = $derived(store.current!);
</script>

<h2 class="large-title">{t.title}</h2>
<p class="subtitle">{t.subtitle}</p>
<div class="small-title">{t.onPhone}</div>
<div class="card"><div class="hero">
  <Illus kind="trust" />
  <h2>{t.heading}</h2>
  <p>{t.body}</p>
  {#if d.locked}<span class="warnline">{t.locked}</span>{/if}
  <span class="waiting"><span class="inf"></span>{t.waiting}</span>
</div></div>
<MockRow>
  {#if d.locked}<button class="btn text" onclick={() => api.mockPhone(d.udid, "unlock")}>{store.t.mock.unlock}</button>{/if}
  <button class="btn text" onclick={() => api.mockPhone(d.udid, "trust")}>{store.t.mock.trust}</button>
  <button class="btn text" onclick={() => api.mockPhone(d.udid, "dontTrust")}>{store.t.mock.dontTrust}</button>
</MockRow>
