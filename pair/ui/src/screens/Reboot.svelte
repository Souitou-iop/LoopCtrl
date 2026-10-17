<script lang="ts">
  import { onDestroy } from "svelte";
  import { store } from "../lib/store.svelte";
  import Illus from "../lib/Illus.svelte";
  const t = $derived(store.t.reboot);
  const d = $derived(store.current!);
  let now = $state(Date.now());
  const iv = setInterval(() => (now = Date.now()), 1000);
  onDestroy(() => clearInterval(iv));
  const secs = $derived(Math.max(0, Math.floor((now - d.phaseSince) / 1000)));
  const clock = $derived(`${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, "0")}`);
</script>

<h2 class="large-title">{t.title}</h2>
<p class="subtitle">{t.subtitle}</p>
<div class="small-title">{store.t.wait.status}</div>
<div class="card"><div class="hero">
  <Illus kind="reboot" />
  <h2>{t.heading}</h2>
  <p>{t.body}</p>
  <span class="warnline">{t.noUnplug}</span>
  <span class="waiting"><span class="inf"></span>{t.waiting} {d.phase === "rebooting" ? clock : ""}</span>
</div></div>
