<script lang="ts">
  import { store } from "../lib/store.svelte";
  import { api, SOURCE_URL } from "../lib/api";
  import licenses from "../lib/licenses.json";
  import Arrow from "../lib/Arrow.svelte";

  const t = $derived(store.t.settings);
  type Lic = { name: string; version: string; license: string; repo: string; kind: string };
  const all = licenses as Lic[];
  // The ones worth naming first; the full list is one tap away.
  const featured = ["idevice", "tauri", "tokio", "serde", "plist", "svelte"]
    .map((n) => all.find((l) => l.name === n)).filter((l): l is Lic => !!l);
  let showAll = $state(false);
  // Every component's license text (THIRD_PARTY_NOTICES.md), loaded only when
  // asked for: a few hundred KB, kept out of the main bundle.
  let texts = $state<string[] | null>(null);
  async function openTexts() {
    showAll = false;
    const md = (await import("../../../THIRD_PARTY_NOTICES.md?raw")).default as string;
    texts = md.split(/\n{2,}/).filter((p) => p.trim());
  }
  let checking = $state(false);
  let autoUpd = $state(readAuto());

  function readAuto() { try { return localStorage.getItem("autoUpdate") !== "0"; } catch { return true; } }
  $effect(() => { try { localStorage.setItem("autoUpdate", autoUpd ? "1" : "0"); } catch {} });

  async function checkUpdate() {
    if (checking) return;
    checking = true;
    try {
      const r = await api.checkUpdate();
      store.markUpdateChecked();
      store.toast(r.status === "upToDate" ? t.upToDate : r.status === "notConfigured" ? t.notConfigured
        : r.status === "available" ? t.available(r.version) : t.updateError);
    } catch {
      store.toast(t.updateError);
    } finally {
      checking = false;
    }
  }

  async function setMock(on: boolean) {
    await store.stop();
    await api.setMock(on);
    store.devices = [];
    store.hidden = [];
    store.info = await api.appInfo();
    await store.checkEnv();
  }
  async function setDriverMissing(on: boolean) {
    store.driverMissing = on;
    await api.mockDriverMissing(on);
    await store.checkEnv();
  }
</script>

<div class="scroll">
  <div class="cols">
    <div>
      <div class="small-title">{t.about}</div>
      <div class="card">
        <div class="comp"><img class="lead-icon" src="/icon.png" alt="" width="44" height="44"><div class="t"><span class="title">{store.t.appName}</span><span class="summary">{t.version(store.info?.version ?? "–")}</span></div></div>
        <div class="comp press" role="button" tabindex="0" onclick={checkUpdate} onkeydown={(e) => e.key === "Enter" && checkUpdate()}>
          <div class="t"><span class="title">{t.checkUpdate}</span><span class="summary">{store.lastUpdateCheck ? t.lastCheck(store.lastUpdateCheck) : t.never}</span></div>
          {#if checking}<span class="inf"></span>{:else}<Arrow />{/if}
        </div>
        <div class="comp"><div class="t"><span class="title">{t.autoUpdate}</span></div><input type="checkbox" class="switch" bind:checked={autoUpd} aria-label={t.autoUpdate}></div>
        <div class="comp press" role="button" tabindex="0" onclick={() => api.openUrl(SOURCE_URL)} onkeydown={(e) => e.key === "Enter" && api.openUrl(SOURCE_URL)}>
          <div class="t"><span class="title">{t.source}</span><span class="summary">{t.sourceSummary}</span></div><Arrow />
        </div>
      </div>
      <div class="small-title">{t.appearance}</div>
      <div class="card">
        <div class="comp"><div class="t"><span class="title">{t.theme}</span></div>
          <div class="seg" role="group" aria-label={t.theme}>
            {#each [["auto", t.themeAuto], ["light", t.themeLight], ["dark", t.themeDark]] as [k, label] (k)}
              <button type="button" aria-pressed={store.theme === k} onclick={() => store.setTheme(k as "auto")}>{label}</button>
            {/each}
          </div></div>
        <div class="comp"><div class="t"><span class="title">{t.language}</span></div>
          <div class="seg" role="group" aria-label={t.language}>
            <button type="button" aria-pressed={store.lang === "zh-CN"} onclick={() => store.setLang("zh-CN")}>简体中文</button>
            <button type="button" aria-pressed={store.lang === "en"} onclick={() => store.setLang("en")}>English</button>
          </div></div>
      </div>
      {#if store.info?.devOptions}
        <div class="small-title">{t.developer}</div>
        <div class="card">
          <div class="comp"><div class="t"><span class="title">{t.mock}</span><span class="summary">{t.mockSummary}</span></div>
            <input type="checkbox" class="switch" checked={store.mock} onchange={(e) => setMock(e.currentTarget.checked)} aria-label={t.mock}></div>
          {#if store.mock}
            <div class="comp"><div class="t"><span class="title">{t.driverMissing}</span></div>
              <input type="checkbox" class="switch" checked={store.driverMissing} onchange={(e) => setDriverMissing(e.currentTarget.checked)} aria-label={t.driverMissing}></div>
          {/if}
          <div class="comp"><div class="t"><span class="title">{t.asWindows}</span></div>
            <input type="checkbox" class="switch" bind:checked={store.asWindows} aria-label={t.asWindows}></div>
          <div class="comp"><div class="t"><span class="title">{t.cacheDir}</span><span class="summary selectable">{store.info.cacheDir}</span></div></div>
        </div>
      {/if}
    </div>
    <div>
      <div class="small-title">{t.licenses}</div>
      <div class="card">
        {#each featured as l (l.name)}
          <div class="comp press" role="button" tabindex="0" onclick={() => api.openUrl(l.repo)} onkeydown={(e) => e.key === "Enter" && api.openUrl(l.repo)}>
            <div class="t"><span class="title">{l.name === "tauri" ? "Tauri" : l.name}</span></div><span class="end">{l.license}</span><Arrow /></div>
        {/each}
        <div class="comp press" role="button" tabindex="0" onclick={() => api.openUrl("https://github.com/nab138/iloader")} onkeydown={(e) => e.key === "Enter" && api.openUrl("https://github.com/nab138/iloader")}>
          <div class="t"><span class="title">iLoader{t.inspiration}</span></div><span class="end">MIT</span><Arrow /></div>
        <div class="comp press" role="button" tabindex="0" onclick={() => (showAll = true)} onkeydown={(e) => e.key === "Enter" && (showAll = true)}>
          <div class="t"><span class="title">{t.allLicenses(all.length)}</span></div><Arrow /></div>
        <div class="comp press" role="button" tabindex="0" onclick={openTexts} onkeydown={(e) => e.key === "Enter" && openTexts()}>
          <div class="t"><span class="title">{t.licenseTexts}</span></div><Arrow /></div>
      </div>
    </div>
  </div>
</div>

{#if showAll}
  <div class="scrim bottom" role="presentation" onclick={(e) => e.target === e.currentTarget && (showAll = false)}>
    <div class="sheet" role="dialog" aria-label={t.licenses}><div class="handle"></div>
      <h3>{t.licenses}</h3><p class="sub">{t.allLicenses(all.length)}</p>
      <div class="card lic-list">
        {#each all as l (l.name + l.version)}
          <div class="comp press" role="button" tabindex="0" onclick={() => api.openUrl(l.repo)} onkeydown={(e) => e.key === "Enter" && api.openUrl(l.repo)}>
            <div class="t"><span class="title">{l.name}</span><span class="summary">{l.version}</span></div><span class="end sm">{l.license}</span></div>
        {/each}
      </div>
      <div class="btnrow"><button class="btn" onclick={() => (showAll = false)}>{store.t.env.close}</button></div>
    </div>
  </div>
{/if}

{#if texts}
  <div class="scrim bottom" role="presentation" onclick={(e) => e.target === e.currentTarget && (texts = null)}>
    <div class="sheet" role="dialog" aria-label={t.licenseTexts}><div class="handle"></div>
      <h3>{t.licenseTexts}</h3>
      <div class="lic-texts">
        {#each texts as p, i (i)}<pre>{p}</pre>{/each}
      </div>
      <div class="btnrow"><button class="btn" onclick={() => (texts = null)}>{store.t.env.close}</button></div>
    </div>
  </div>
{/if}
