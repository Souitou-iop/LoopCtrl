<script lang="ts">
  // One phone in the list. Collapsed it is a row; while pairing it can open
  // to show the five steps, and what the phone needs from the user is always
  // shown under it.
  import { store, isUnsupported } from "./store.svelte";
  import type { DeviceView } from "./api";
  import { chipOf, stepOf } from "./chip";
  import Guide from "./Guide.svelte";

  let { d, solo = false }: { d: DeviceView; solo?: boolean } = $props();
  const t = $derived(store.t);
  const running = $derived(store.running);
  const chip = $derived(chipOf(d, t, running));
  const at = $derived(stepOf(d));
  const started = $derived(d.phase !== "detected" && !isUnsupported(d));
  const tap = $derived(started && !solo);
  const expanded = $derived(started && (solo || store.open.includes(d.udid)));
  const stepState = (i: number) =>
    i < at || d.phase === "done" ? "ok" : i === at ? (d.phase === "failed" ? "bad" : d.attention ? "act" : "run") : "wait";
</script>

<div class="dcard" class:solo>
  {#snippet rowBody()}
    <span class="ph" class:ok={d.phase === "done"}>
      {#if d.phase === "done"}<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>
      {:else}<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="6.5" y="2.5" width="11" height="19" rx="3"/><path d="M10.5 18.5h3" stroke-linecap="round"/></svg>{/if}
    </span>
    <span class="t"><b>{d.info?.name ?? "iPhone"}</b>
      <span>{d.info ? `${d.info.model} · iOS ${d.info.ios}` : "…"} · {t.row.port(d.order)}</span></span>
    {#if tap}<span class="mini" class:bad={d.phase === "failed"} class:gone={d.phase === "done"}><i style="width:{d.progress * 100}%"></i></span>{/if}
    <span class="chip {chip[0]}">{#if chip[0] === "run" || (chip[0] === "wait" && !d.info)}<span class="inf sm"></span>{/if}{chip[1]}</span>
    {#if tap}<svg class="chev" class:up={expanded} viewBox="0 0 16 10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M2 2l6 6 6-6"/></svg>{/if}
  {/snippet}
  {#if tap}
    <div class="drow press" role="button" tabindex="0" aria-expanded={expanded}
      onclick={() => store.toggle(d.udid)} onkeydown={(e) => e.key === "Enter" && store.toggle(d.udid)}>{@render rowBody()}</div>
  {:else}
    <div class="drow">{@render rowBody()}</div>
  {/if}
  {#if expanded}
    <ol class="stepper" aria-label="steps">
      {#each t.steps as name, i (i)}
        {@const st = stepState(i)}
        <li class={st}><span class="sd">{#if st === "ok"}<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>{:else if st === "bad"}!{:else if st === "run"}<span class="inf sm on"></span>{:else}{i + 1}{/if}</span><span class="sl">{name}</span></li>
      {/each}
    </ol>
    {#if solo && d.phase !== "failed"}<div class="linear"><i style="width:{d.progress * 100}%"></i></div>{/if}
  {/if}
  {#if started || d.phase === "failed"}<Guide {d} hero={solo} />{/if}
</div>
