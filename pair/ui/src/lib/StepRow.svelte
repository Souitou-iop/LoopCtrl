<script lang="ts">
  import StepState from "./StepState.svelte";
  let { state, title, summary = "", end = "" }: { state: "wait" | "run" | "ok" | "bad"; title: string; summary?: string; end?: string } = $props();
</script>

<div class="comp">
  <StepState {state} />
  <div class="t"><span class="title">{title}</span>{#if summary}<span class="summary">{summary}</span>{/if}</div>
  <span class="end" class:ok={state === "run"} class:bad={state === "bad"}>{end}</span>
</div>
