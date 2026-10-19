<script lang="ts">
  import { onMount } from "svelte";
  import { store, type Screen } from "./lib/store.svelte";
  import { api } from "./lib/api";
  import ErrorDialog from "./lib/ErrorDialog.svelte";
  import DeviceSheet from "./lib/DeviceSheet.svelte";
  import Welcome from "./screens/Welcome.svelte";
  import Wait from "./screens/Wait.svelte";
  import Device from "./screens/Device.svelte";
  import Trust from "./screens/Trust.svelte";
  import DevCheck from "./screens/DevCheck.svelte";
  import Reboot from "./screens/Reboot.svelte";
  import DevUnlock from "./screens/DevUnlock.svelte";
  import Progress from "./screens/Progress.svelte";
  import Done from "./screens/Done.svelte";
  import Batch from "./screens/Batch.svelte";
  import Settings from "./screens/Settings.svelte";

  const SCREENS: Record<Screen, typeof Welcome> = {
    welcome: Welcome, wait: Wait, device: Device, trust: Trust, devcheck: DevCheck,
    reboot: Reboot, devunlock: DevUnlock, progress: Progress, done: Done,
  };
  const pageKey = $derived(store.page === "single" ? `single-${store.screen}` : store.page);
  const Single = $derived(SCREENS[store.screen]);
  const failed = $derived(store.page === "single" && store.current?.phase === "failed" ? store.current : null);
  const envCode = $derived(store.envCode ?? (store.os === "windows" ? "noDriver" : "noUsbmux"));

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
  <nav class="rail" aria-label="nav">
    <img src="/icon.png" alt="LoopCtrl" width="40" height="40">
    <button type="button" aria-current={store.page === "single"} onclick={() => store.go("single")}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="6.5" y="2.5" width="11" height="19" rx="3"/><path d="M10.5 18.5h3"/></svg>{store.t.rail.single}</button>
    <button type="button" aria-current={store.page === "batch"} onclick={() => store.go("batch")}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="3" y="5" width="8" height="15" rx="2.2"/><rect x="13" y="3" width="8" height="15" rx="2.2"/></svg>{store.t.rail.batch}</button>
    <button type="button" aria-current={store.page === "settings"} onclick={() => store.go("settings")}><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><circle cx="12" cy="12" r="3"/><path d="M12 2.8l2 2.2 3-.4.6 3 2.6 1.6-1.2 2.8 1.2 2.8-2.6 1.6-.6 3-3-.4-2 2.2-2-2.2-3 .4-.6-3L3.6 15l1.2-2.8L3.6 9.4l2.6-1.6.6-3 3 .4z" stroke-linejoin="round"/></svg>{store.t.rail.settings}</button>
  </nav>
  <div class="pages">
    {#key pageKey}
      <section class="page enter">
        {#if store.page === "single"}<Single />
        {:else if store.page === "batch"}<Batch />
        {:else}<Settings />{/if}
      </section>
    {/key}
  </div>

  {#if failed}
    {#key failed.udid + failed.error?.code}<ErrorDialog device={failed} />{/key}
  {:else if store.envDialog}
    <ErrorDialog envCode={envCode} onclose={() => (store.envDialog = false)} />
  {/if}
  {#if store.page === "batch"}<DeviceSheet />{/if}
  {#if store.snack}<div class="snack">{store.snack}</div>{/if}
</div>
