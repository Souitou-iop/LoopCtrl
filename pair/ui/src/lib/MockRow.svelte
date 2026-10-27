<script lang="ts">
  // Phone-side buttons for the mock backend, like the demo's "演示：…" links.
  import type { Snippet } from "svelte";
  import { store } from "./store.svelte";
  let { children }: { children: Snippet } = $props();
</script>

{#if store.mock}
  <div class="mockrow"><span class="tag">{store.t.mock.tag}</span>{@render children()}</div>
{/if}
