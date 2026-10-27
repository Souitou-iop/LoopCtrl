<script lang="ts">
  import { onMount } from "svelte";
  import { store } from "./lib/store.svelte";
  import { api } from "./lib/api";
  import ErrorDialog from "./lib/ErrorDialog.svelte";
  import EnvSheet from "./lib/EnvSheet.svelte";
  import Pair from "./views/Pair.svelte";
  import Settings from "./views/Settings.svelte";

  const envState = $derived(!store.env ? "checking" : store.envCode ? "bad" : "ok");

  onMount(async () => {
    const q = new URLSearchParams(location.search);
    const preview = q.get("preview");
    // Screen gallery for development in a plain browser (see lib/preview.ts).
    if (import.meta.env.DEV && preview && !api.inTauri) {
      const { applyPreview } = await import("./lib/preview");
      if (q.get("theme")) store.theme = q.get("theme") as "dark";
      if (q.get("lang")) store.lang = q.get("lang") as "en";
      applyPreview(store, preview);
      return;
    }
    void store.init();
  });
</script>

<div class="app">
  <header class="topbar">
    {#if store.view === "settings"}
      <button class="iconbtn" aria-label={store.t.nav.back} onclick={() => (store.view = "pair")}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 5l-7 7 7 7"/></svg></button>
      <span class="brand">{store.t.settings.title}</span>
    {:else}
      <img src="/icon.png" alt="" width="28" height="28">
      <span class="brand">{store.t.appName}</span>
      <span class="sp"></span>
      <button class="pill {envState}" onclick={() => (store.envSheet = true)}>
        {#if envState === "checking"}<span class="inf sm"></span>{:else}<span class="pdot"></span>{/if}
        {store.t.env[envState]}</button>
      <button class="iconbtn" aria-label={store.t.nav.settings} onclick={() => (store.view = "settings")}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="3"/><path d="M12 2.8l2 2.2 3-.4.6 3 2.6 1.6-1.2 2.8 1.2 2.8-2.6 1.6-.6 3-3-.4-2 2.2-2-2.2-3 .4-.6-3L3.6 15l1.2-2.8L3.6 9.4l2.6-1.6.6-3 3 .4z" stroke-linejoin="round"/></svg></button>
    {/if}
  </header>
  {#key store.view}
    <main class="page enter" class:back={store.view === "pair"}>
      {#if store.view === "pair"}<Pair />{:else}<Settings />{/if}
    </main>
  {/key}

  {#if store.envDialog && store.envCode}
    <ErrorDialog code={store.envCode} onclose={() => (store.envDialog = false)} />
  {/if}
  {#if store.envSheet}<EnvSheet />{/if}
  {#if store.snack}<div class="snack">{store.snack}</div>{/if}
</div>
