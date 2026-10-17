<script lang="ts">
  let { state }: { state: "wait" | "run" | "ok" | "bad" } = $props();
</script>

<span class="state">
  {#if state === "run"}<span class="inf"></span>
  {:else if state === "ok"}<span class="okc"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></span>
  {:else if state === "bad"}<span class="errc">!</span>
  {:else}<span class="dot"></span>{/if}
</span>
