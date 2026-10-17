<script lang="ts">
  import { store } from "./store.svelte";
  import { api } from "./api";
  import { chipOf, sheetStep } from "./chip";
  import StepRow from "./StepRow.svelte";
  import Note from "./Note.svelte";
  import MockRow from "./MockRow.svelte";

  const d = $derived(store.devices.find((x) => x.udid === store.sheet) ?? null);
  const t = $derived(store.t.batch);
  const close = () => (store.sheet = null);
  const hint = $derived.by((): [string, string] | null => {
    if (!d) return null;
    switch (d.phase) {
      case "trusting": return d.locked ? t.hintLocked : t.hintTrust;
      case "devModeGuide": return t.hintDevOff;
      case "rebooting": return t.hintReboot;
      case "confirmingDevMode": return t.hintUnlock;
      case "failed": {
        const e = store.t.errors[d.error?.code ?? "internal"];
        return [e.title, `${e.body} ${e.steps.join("；")}`];
      }
      default: return null;
    }
  });
</script>

<svelte:window onkeydown={(e) => e.key === "Escape" && close()} />
{#if d}
  {@const at = sheetStep(d)}
  {@const chip = chipOf(d, store.t)}
  <div class="scrim bottom" role="presentation" onclick={(e) => e.target === e.currentTarget && close()}>
    <div class="sheet" role="dialog" aria-labelledby="ds-title"><div class="handle"></div>
      <h3 id="ds-title">{d.info?.name ?? "iPhone"}</h3>
      <p class="sub">{d.info?.model ?? ""} · iOS {d.info?.ios ?? ""} · {t.port(d.order)}</p>
      <div class="card">
        {#each t.steps as name, i (i)}
          {@const st = i < at ? "ok" : i === at ? (d.phase === "done" ? "ok" : d.attention ? "bad" : "run") : "wait"}
          <StepRow state={st} title={name}
            end={st === "ok" ? (i === 1 ? store.t.state.on : store.t.state.done) : st === "wait" ? store.t.state.wait : chip[1]} />
        {/each}
      </div>
      {#if hint}
        <div class="small-title" style="padding-left:2px">{t.needYou}</div>
        <Note><b>{hint[0]}</b><br>{hint[1]}</Note>
        {#if d.phase === "failed" && d.error?.code !== "unsupported"}
          <div class="btnrow left"><button class="btn text" onclick={() => api.command(d.udid, "retry")}>{t.retry}</button></div>
        {/if}
        <MockRow>
          {#if d.phase === "trusting"}<button class="btn text" onclick={() => api.mockPhone(d.udid, d.locked ? "unlock" : "trust")}>{d.locked ? store.t.mock.unlock : store.t.mock.trust}</button>{/if}
          {#if d.phase === "devModeGuide"}<button class="btn text" onclick={() => api.mockPhone(d.udid, "restart")}>{store.t.mock.restart}</button>{/if}
          {#if d.phase === "confirmingDevMode"}<button class="btn text" onclick={() => api.mockPhone(d.udid, "turnOn")}>{store.t.mock.turnOn}</button>{/if}
          {#if d.error?.code === "appNotFound"}<button class="btn text" onclick={() => api.mockPhone(d.udid, "installApp")}>{store.t.mock.install}</button>{/if}
        </MockRow>
      {/if}
      <div class="btnrow"><button class="btn" onclick={close}>{t.close}</button></div>
    </div>
  </div>
{/if}
