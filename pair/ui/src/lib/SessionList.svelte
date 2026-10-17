<script lang="ts">
  import { store } from "./store.svelte";
  import StepState from "./StepState.svelte";
</script>

<div class="card">
  {#each store.paired as p (p.udid)}
    <div class="comp"><StepState state="ok" /><div class="t"><span class="title">{p.name}</span><span class="summary">iOS {p.ios}</span></div><span class="end">{p.time}</span></div>
  {/each}
</div>
