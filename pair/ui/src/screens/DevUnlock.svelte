<script lang="ts">
  import { store } from "../lib/store.svelte";
  import { api } from "../lib/api";
  import Illus from "../lib/Illus.svelte";
  import MockRow from "../lib/MockRow.svelte";
  const t = $derived(store.t.unlock);
  const d = $derived(store.current!);
</script>

<h2 class="large-title">{t.title}</h2>
<p class="subtitle">{t.subtitle}</p>
<div class="small-title">{store.t.trust.onPhone}</div>
<div class="card"><div class="hero">
  <Illus kind="prompt" />
  <h2>{t.heading}</h2>
  <p>{t.body}</p>
  <span class="waiting"><span class="inf"></span>{t.waiting}</span>
</div></div>
<div class="btnrow left"><button class="btn text" onclick={() => api.command(d.udid, "recheck")}>{t.noPrompt}</button></div>
<MockRow>
  <button class="btn text" onclick={() => api.mockPhone(d.udid, "turnOn")}>{store.t.mock.turnOn}</button>
  <button class="btn text" onclick={() => api.mockPhone(d.udid, "cancel")}>{store.t.mock.cancel}</button>
</MockRow>
