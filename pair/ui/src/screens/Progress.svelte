<script lang="ts">
  import { store } from "../lib/store.svelte";
  import type { Step } from "../lib/api";
  import StepRow from "../lib/StepRow.svelte";
  const t = $derived(store.t.progress);
  const s = $derived(store.t.state);
  const d = $derived(store.current!);
  const ORDER: Step[] = ["generate", "findApp", "write", "verify"];
  const AT: Record<string, number> = { generating: 0, findingApp: 1, writing: 2, verifying: 3, done: 4 };
  const at = $derived(d.phase === "failed" ? ORDER.indexOf(d.failedAt as Step) : (AT[d.phase] ?? 0));
  const titles = $derived([t.gen, t.find, t.write, t.verify]);
  const doneText = $derived([
    d.recordKind === "lockdown" ? t.lockdownOnly : s.done,
    d.app ? `${d.app.name}${d.app.version ? " " + d.app.version : ""}` : s.done,
    t.written,
    t.passed,
  ]);
  const rowState = (i: number) => (i < at ? "ok" : i === at ? (d.phase === "failed" ? "bad" : "run") : "wait");
</script>

<h2 class="large-title">{t.title}</h2>
<p class="subtitle">{t.subtitle}</p>
<div class="small-title">{t.heading}</div>
<div class="card">
  {#each titles as title, i (i)}
    {@const st = rowState(i)}
    <StepRow state={st} {title} end={st === "ok" ? doneText[i] : st === "run" ? s.run : st === "bad" ? store.t.chip.failed : s.wait} />
  {/each}
</div>
<div class="linear"><i style="width:{(Math.max(at, 0) / 4) * 100}%"></i></div>
