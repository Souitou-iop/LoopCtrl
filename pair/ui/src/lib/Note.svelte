<script lang="ts">
  import type { Snippet } from "svelte";
  let { icon = "info", children }: { icon?: "info" | "bolt"; children: Snippet } = $props();
</script>

<div class="note">
  {#if icon === "bolt"}
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M13 2L4 14h7l-1 8 9-12h-7z" stroke-linejoin="round"/></svg>
  {:else}
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.01"/></svg>
  {/if}
  <span>{@render children()}</span>
</div>
