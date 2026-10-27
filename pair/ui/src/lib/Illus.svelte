<script lang="ts">
  // Line illustrations from the approved demo.
  let { kind }: { kind: "cable" | "trust" | "reboot" | "prompt" } = $props();
</script>

<svg class="illus" viewBox="0 0 140 110" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" aria-hidden="true">
  {#if kind === "cable"}
    <rect x="52" y="6" width="36" height="66" rx="8"/><path d="M64 13h12"/><path d="M70 72v14c0 8-6 14-14 14H20" opacity=".55"/><rect x="65" y="70" width="10" height="7" rx="2" fill="currentColor" stroke="none"/>
  {:else if kind === "trust"}
    <rect x="45" y="3" width="50" height="104" rx="10"/><rect x="53" y="36" width="34" height="34" rx="7" stroke-width="2.5"/><path d="M59 47h22" stroke-width="2.5"/><path d="M53 60h34" stroke-width="1.5" opacity=".5"/><path d="M73 62h10" stroke-width="4"/>
  {:else if kind === "reboot"}
    <rect x="45" y="3" width="50" height="104" rx="10"/><path d="M58 52a12 12 0 1 0 6-10.4"/><path d="M64 36v6h-6"/>
  {:else}
    <rect x="45" y="3" width="50" height="104" rx="10"/><rect x="53" y="34" width="34" height="38" rx="7" stroke-width="2.5"/><path d="M59 44h22" stroke-width="2.5"/><path d="M60 63h20" stroke-width="4"/>
  {/if}
</svg>
