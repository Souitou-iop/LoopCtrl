<script lang="ts">
  import { store } from "../lib/store.svelte";
  import { api } from "../lib/api";
  import StepRow from "../lib/StepRow.svelte";
  import Note from "../lib/Note.svelte";
  import MockRow from "../lib/MockRow.svelte";
  const t = $derived(store.t.devcheck);
  const s = $derived(store.t.state);
  const d = $derived(store.current!);
  const reading = $derived(d.phase === "checkingDevMode" || (d.phase === "failed" && d.failedAt === "devModeCheck"));
  const off = $derived(d.devModeWasOff && !reading);
  const guide = $derived(d.phase === "devModeGuide");
</script>

<h2 class="large-title">{t.title}</h2>
<p class="subtitle">{reading ? t.checking : off ? t.off : t.on}</p>
<div class="cols">
  <div>
    <div class="small-title">{t.auto}</div>
    <div class="card">
      <StepRow state={reading ? "run" : off ? "bad" : "ok"} title={t.read} end={reading ? s.reading : off ? s.off : s.on} />
      {#if off}
        <StepRow state={d.phase === "revealingDevMode" ? "run" : "ok"} title={t.reveal} summary={t.revealSummary}
          end={d.phase === "revealingDevMode" ? s.run : s.done} />
      {/if}
    </div>
    {#if guide}
      <div class="small-title">{t.whyTitle}</div>
      <Note>{t.why}</Note>
    {/if}
  </div>
  {#if guide}
    <div>
      <div class="small-title">{t.onPhone}</div>
      <div class="card steps">
        <div class="comp"><span class="num">1</span><div class="t"><span class="title">{t.step1}</span><span class="summary">{t.step1Summary}</span></div></div>
        <div class="comp"><span class="num">2</span><div class="t"><span class="title">{t.step2}</span></div></div>
        <div class="comp"><span class="num">3</span><div class="t"><span class="title">{t.step3}</span><span class="summary">{t.step3Summary}</span></div></div>
      </div>
      <div class="waiting" style="padding:14px 4px 0"><span class="inf"></span>{t.waitReboot}</div>
    </div>
  {/if}
</div>
{#if guide}
  <MockRow><button class="btn text" onclick={() => api.mockPhone(d.udid, "restart")}>{store.t.mock.restart}</button></MockRow>
{/if}
