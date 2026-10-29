import Foundation

/// GET /remote: the control page a person drives the phone from, on the LAN,
/// a tailnet or the relay's public address (docs/remote-control.md).
///
/// One self-contained file with no external requests. Every URL it uses is
/// relative, so it works at `/remote` and under a relay's `/d/<slug>/` alike.
/// It pairs from the browser (X25519, approved on the phone), keeps the
/// 32-byte key in this origin's storage, and seals every /rpc call itself:
/// the key never leaves the browser. The crypto falls back to plain
/// JavaScript where WebCrypto is missing (an http:// LAN address is not a
/// secure context).
///
/// The look is miuix's (compose-miuix-ui/miuix, Apache-2.0): its colours,
/// type sizes and component shapes recreated in CSS, light and dark,
/// following the system unless the viewer picks one.
enum RemoteHTML {
    /// GET /remote/manifest.webmanifest. Added to a Home Screen, the page opens
    /// full screen. Relative URLs resolve against the manifest's own address.
    static let manifest: String = #"""
{
  "name": "LoopCtrl",
  "short_name": "LoopCtrl",
  "start_url": "../remote",
  "scope": "../",
  "display": "fullscreen",
  "background_color": "#0b0b0d",
  "theme_color": "#0b0b0d",
  "icons": [{ "src": "icon.png", "sizes": "180x180", "type": "image/png" }]
}
"""#

    /// GET /remote-sw.js. Network first, always: a copy is used only when the
    /// phone can't be reached (no connection, or the relay's 503 for an
    /// offline phone), and only for the page, its icon and its manifest.
    static let serviceWorker: String = #"""
const CACHE = "loopctrl-page-v1";
const PAGE = /\/remote(\/(icon\.png|manifest\.webmanifest))?$/;
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET" || !PAGE.test(new URL(req.url).pathname)) return;
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    try {
      const res = await fetch(req, { cache: "no-store" });
      if (res.ok) { cache.put(req, res.clone()); return res; }
      return (await cache.match(req)) || res;
    } catch (err) {
      const kept = await cache.match(req);
      if (kept) return kept;
      throw err;
    }
  })());
});
"""#

    static let page: String = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="theme-color" content="#f7f7f7" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
<meta name="referrer" content="no-referrer">
<link rel="manifest" href="remote/manifest.webmanifest">
<link rel="apple-touch-icon" href="remote/icon.png">
<link rel="icon" type="image/png" href="remote/icon.png">
<title>LoopCtrl</title>
<script>
// The theme before first paint, so a dark page never flashes white.
try { const th = localStorage.getItem("loopctrl.theme"); if (th === "light" || th === "dark") document.documentElement.dataset.theme = th; } catch (_) {}
</script>
<style>
/* miuix / HyperOS look: values from compose-miuix-ui/miuix (Apache-2.0) —
   theme/Colors.kt, TextStyles, basic/*Defaults, dialogs (32px), bottom sheets
   (28px) — recreated in CSS as LoopCtrl Pair does. No Xiaomi fonts or assets. */
:root {
  --primary: #3482ff; --on-primary: #ffffff; --disabled-primary: #c2d9ff;
  --error: #e94634; --error-container: #fdf6f4;
  --secondary-variant: #f0f0f0; --on-secondary-variant: #303030;
  --secondary-container: #f0f0f0; --on-secondary-container: #8a8a8a;
  --tertiary-container: #eaf2ff; --on-tertiary-container: #3482ff;
  --background: #ffffff; --surface: #f7f7f7; --card: #ffffff;
  --on-surface: #000000; --on-surface-secondary: rgba(0,0,0,.8); --summary: rgba(0,0,0,.6); --actions: rgba(0,0,0,.4);
  --small-title: #8c93b0; --divider: #e0e0e0; --dim: rgba(0,0,0,.3);
  --slider-bg: rgba(0,0,0,.06); --press: rgba(0,0,0,.05); --switch-off: #e6e6e6; --thumb: #ffffff; --handle: rgba(0,0,0,.15);
  --snack: #2b2b2b; --snack-ink: #ffffff; --screen-edge: rgba(0,0,0,.08);
  --font: -apple-system, BlinkMacSystemFont, "PingFang SC", "HarmonyOS Sans SC", "Microsoft YaHei UI", "Microsoft YaHei", "Segoe UI", sans-serif;
  --r-card: 16px; --r-btn: 16px; --r-dialog: 32px;
  --spring: cubic-bezier(.22,1.2,.36,1); --ease: cubic-bezier(.2,.9,.1,1);
  color-scheme: light;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --primary: #277af7; --disabled-primary: #253e64; --error: #f12522; --error-container: #2e0603;
  --secondary-variant: #434343; --on-secondary-variant: #d9d9d9; --secondary-container: #434343; --on-secondary-container: #a0a0a0;
  --tertiary-container: #2b3b54; --on-tertiary-container: #4788ff;
  --background: #000000; --surface: #000000; --card: #242424;
  --on-surface: #f2f2f2; --on-surface-secondary: rgba(255,255,255,.8); --summary: rgba(255,255,255,.5); --actions: rgba(255,255,255,.4);
  --small-title: #787e96; --divider: #393939; --dim: rgba(0,0,0,.6);
  --slider-bg: rgba(255,255,255,.15); --press: rgba(255,255,255,.06); --switch-off: #505050; --thumb: #ffffff; --handle: rgba(255,255,255,.2);
  --snack: #e9e9e9; --snack-ink: #000000; --screen-edge: rgba(255,255,255,.1); color-scheme: dark; } }
:root[data-theme="dark"] {
  --primary: #277af7; --disabled-primary: #253e64; --error: #f12522; --error-container: #2e0603;
  --secondary-variant: #434343; --on-secondary-variant: #d9d9d9; --secondary-container: #434343; --on-secondary-container: #a0a0a0;
  --tertiary-container: #2b3b54; --on-tertiary-container: #4788ff;
  --background: #000000; --surface: #000000; --card: #242424;
  --on-surface: #f2f2f2; --on-surface-secondary: rgba(255,255,255,.8); --summary: rgba(255,255,255,.5); --actions: rgba(255,255,255,.4);
  --small-title: #787e96; --divider: #393939; --dim: rgba(0,0,0,.6);
  --slider-bg: rgba(255,255,255,.15); --press: rgba(255,255,255,.06); --switch-off: #505050; --thumb: #ffffff; --handle: rgba(255,255,255,.2);
  --snack: #e9e9e9; --snack-ink: #000000; --screen-edge: rgba(255,255,255,.1); color-scheme: dark; }

* { box-sizing: border-box; }
[hidden] { display: none !important; }
html, body { margin: 0; height: 100%; background: var(--surface); color: var(--on-surface); font-family: var(--font);
  -webkit-font-smoothing: antialiased; overscroll-behavior: none; }
button { font: inherit; color: inherit; }
input { font: inherit; color: inherit; }
svg { width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; flex: none; }
:focus-visible { outline: 2px solid var(--primary); outline-offset: 2px; }

.app { display: flex; flex-direction: column; height: 100dvh;
  padding: env(safe-area-inset-top) env(safe-area-inset-right) 0 env(safe-area-inset-left); }

/* TopAppBar (small) */
.topbar { flex: none; height: 56px; display: flex; align-items: center; gap: 8px; padding: 0 12px 0 16px; }
.topbar img { width: 28px; height: 28px; border-radius: 7px; flex: none; }
.titles { min-width: 0; flex: 0 1 auto; display: flex; flex-direction: column; align-items: flex-start; border: 0; background: transparent;
  padding: 4px 8px; margin-left: -6px; border-radius: 12px; text-align: left; cursor: pointer; transition: background .15s; }
.titles:hover { background: var(--press); }
.titles .brand { display: flex; align-items: center; gap: 2px; max-width: 100%; }
.titles .brand span { overflow: hidden; text-overflow: ellipsis; }
.titles .chev { width: 16px; height: 16px; opacity: .55; flex: none; }
.brand { font-size: 16px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.sub { font-size: 12px; color: var(--summary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-variant-numeric: tabular-nums; }
.sp { flex: 1; }
.iconbtn { width: 40px; height: 40px; border: 0; border-radius: 50%; background: transparent; display: grid; place-items: center;
  cursor: pointer; color: var(--on-surface); transition: background .15s, transform .25s var(--spring), color .2s; position: relative; }
.iconbtn:hover { background: var(--press); } .iconbtn:active { transform: scale(.9); }
.iconbtn.on { color: var(--primary); background: var(--tertiary-container); }
.iconbtn.rec { color: var(--error); background: var(--error-container); }
.iconbtn .badge { position: absolute; top: 4px; right: 2px; min-width: 16px; height: 16px; padding: 0 4px; border-radius: 8px;
  background: var(--error); color: #fff; font-size: 10px; font-weight: 600; line-height: 16px; }
.pill { display: inline-flex; align-items: center; gap: 8px; height: 32px; max-width: 40vw; padding: 0 14px; border: 0; border-radius: 16px;
  background: var(--card); font-size: 13px; font-weight: 500; color: var(--summary); cursor: default; white-space: nowrap;
  transition: transform .25s var(--spring), background .2s, color .2s; }
.pill span { overflow: hidden; text-overflow: ellipsis; }
.pill .pdot { width: 8px; height: 8px; border-radius: 50%; background: var(--actions); flex: none; }
.pill.mine { background: var(--tertiary-container); color: var(--on-tertiary-container); } .pill.mine .pdot { background: var(--primary); }
.pill.other { background: var(--error-container); color: var(--error); } .pill.other .pdot { background: var(--error); }
.pill { cursor: pointer; flex: none; } .pill:active { transform: scale(.95); }
.pill .short { display: none; align-items: center; gap: 4px; } .pill .short svg { width: 16px; height: 16px; }

/* button labels: icons, text or both (Screen settings › Buttons) */
.lbl { display: none; font-size: 14px; font-weight: 500; white-space: nowrap; }
.labels-text .labeled svg { display: none; }
.labels-text .labeled .lbl, .labels-both .labeled .lbl { display: inline; }
.labels-text .labeled, .labels-both .labeled { width: auto; display: flex; align-items: center; gap: 8px; padding: 0 12px; border-radius: 12px; }

/* body: devices | screen | tools | view tree. Narrower windows fold the
   device list and the view tree into drawers; a portrait phone puts the
   tools under the screen. */
.body { flex: 1; min-height: 0; display: grid; gap: 12px; padding: 0 12px 12px;
  grid-template-columns: auto minmax(0, 1fr) auto auto; grid-template-areas: "devices stage tools tree"; }
#devices { grid-area: devices; } .stage { grid-area: stage; } #tools { grid-area: tools; } #tree-panel { grid-area: tree; }
.card { background: var(--card); border-radius: var(--r-card); }
.rail { display: flex; flex-direction: column; gap: 4px; padding: 6px; align-self: center; max-height: 100%; overflow-y: auto; scrollbar-width: none; }
.stage { position: relative; display: grid; place-items: center; min-width: 0; min-height: 0; }
.screen { position: relative; height: 100%; max-width: 100%; aspect-ratio: var(--ar, 0.46); border-radius: 22px; overflow: hidden;
  background: #000; box-shadow: 0 0 0 1px var(--screen-edge), 0 12px 40px rgba(0,0,0,.18); touch-action: none; user-select: none; -webkit-user-select: none; }
.screen > canvas, .screen > video { position: absolute; inset: 0; width: 100%; height: 100%; }
#video, #mse { object-fit: fill; }
#overlay { cursor: pointer; }
.msg { position: absolute; inset: 0; display: grid; place-items: center; text-align: center; padding: 24px; color: rgba(255,255,255,.75);
  font-size: 15px; line-height: 1.5; pointer-events: none; }
.msg .box { display: flex; flex-direction: column; align-items: center; gap: 12px; max-width: 18em; }
.msg.paused { background: rgba(0,0,0,.72); pointer-events: auto; }
.msg.paused svg { width: 40px; height: 40px; color: #fff; }
.tag { position: absolute; left: 50%; bottom: 14px; transform: translateX(-50%); padding: 6px 12px; border-radius: 14px; font-size: 12px; font-weight: 500;
  background: rgba(0,0,0,.6); color: #fff; white-space: nowrap; pointer-events: none; }
/* InfiniteProgressIndicator */
.spin { width: 22px; height: 22px; border-radius: 50%; position: relative; box-shadow: inset 0 0 0 2px rgba(255,255,255,.25);
  animation: spin 1s linear infinite; flex: none; }
.spin::after { content: ""; position: absolute; top: 3px; left: 50%; width: 4px; height: 4px; margin-left: -2px; border-radius: 50%; background: #fff; }
.card .spin, .dialog .spin { box-shadow: inset 0 0 0 2px var(--slider-bg); } .card .spin::after, .dialog .spin::after { background: var(--on-surface); }
@keyframes spin { to { transform: rotate(360deg); } }

/* side panel: view tree */
.side { width: 340px; display: flex; flex-direction: column; min-height: 0; overflow: hidden; }
.side .head { display: flex; align-items: center; gap: 4px; padding: 12px 8px 8px 16px; }
.side .head b { font-size: 17px; font-weight: 500; flex: 1; }
.search { display: flex; align-items: center; gap: 8px; margin: 0 12px 8px; padding: 0 14px; height: 44px; border-radius: 14px; background: var(--secondary-container); color: var(--actions); }
.search input { flex: 1; min-width: 0; border: 0; outline: 0; background: transparent; font-size: 15px; color: var(--on-surface); }
.search svg { width: 18px; height: 18px; }
#tree { flex: 1; min-height: 0; overflow: auto; padding: 0 0 12px; }
.node { display: flex; align-items: center; gap: 10px; min-height: 40px; padding: 4px 16px 4px 0; cursor: pointer; transition: background .15s; }
.node:hover, .node.hot { background: var(--press); }
.node .t { flex: 1; min-width: 0; display: flex; flex-direction: column; }
.node b { font-size: 15px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.node span { font-size: 12px; color: var(--summary); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.node.empty b { font-weight: 400; color: var(--summary); }
.foot { padding: 10px 16px; font-size: 13px; color: var(--small-title); border-top: 1px solid var(--divider); }

/* devices: every phone opened here, to switch between */
.devices { width: 252px; display: flex; flex-direction: column; min-height: 0; overflow: hidden; }
.devices .head { display: flex; align-items: center; padding: 14px 8px 6px 18px; }
.devices .head b { flex: 1; font-size: 14px; font-weight: 500; color: var(--small-title); }
.devlist { flex: 1; min-height: 0; overflow: auto; padding: 2px 8px 8px; display: flex; flex-direction: column; gap: 4px; }
.dev { display: flex; align-items: center; gap: 12px; padding: 10px; border-radius: 14px; cursor: pointer; color: inherit; text-decoration: none;
  transition: background .15s; }
.dev:hover { background: var(--press); }
.dev.current { background: var(--tertiary-container); cursor: default; }
.dev .ic { width: 38px; height: 38px; border-radius: 11px; display: grid; place-items: center; flex: none;
  background: var(--secondary-container); color: var(--on-secondary-container); }
.dev.current .ic { background: var(--primary); color: var(--on-primary); }
.dev .ic svg { width: 20px; height: 20px; }
.dev .t { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.dev .title { font-size: 15px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.dev.current .title { color: var(--on-tertiary-container); }
.dev .summary { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--summary); white-space: nowrap; }
.dev .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--actions); flex: none; }
.dev .dot.on { background: #34c759; } .dev .dot.off { background: var(--error); }
.dev .rm { width: 30px; height: 30px; opacity: 0; } .dev:hover .rm, .dev .rm:focus-visible { opacity: 1; }
@media (hover: none) { .dev .rm { opacity: .7; } }
.devices .add { margin: 0 8px 8px; min-height: 48px; display: flex; align-items: center; justify-content: center; gap: 8px; }
.drawer-scrim { position: fixed; inset: 0; z-index: 14; background: var(--dim); animation: fade .25s both; }
@keyframes from-left { from { transform: translateX(-100%); } }
@keyframes from-right { from { transform: translateX(100%); } }

/* people: who is watching and operating, and each one's actions */
.people { display: flex; flex-direction: column; gap: 8px; padding-bottom: 6px; }
.person { border-radius: var(--r-card); background: var(--surface); overflow: hidden; }
.person .top { display: flex; align-items: center; gap: 12px; padding: 12px 16px; cursor: pointer; }
.avatar { width: 36px; height: 36px; border-radius: 50%; display: grid; place-items: center; flex: none; font-size: 14px; font-weight: 600;
  background: var(--tertiary-container); color: var(--on-tertiary-container); }
.avatar.agent { background: var(--secondary-container); color: var(--on-secondary-container); }
.person .t { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.person .title { font-size: 16px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.person .summary { font-size: 13px; color: var(--summary); }
.chip { font-style: normal; font-size: 11px; font-weight: 500; padding: 2px 8px; margin-left: 6px; border-radius: 8px; vertical-align: 2px;
  background: var(--secondary-container); color: var(--on-secondary-container); }
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--actions); flex: none; }
.status-dot.on { background: var(--primary); }
.log { max-height: 280px; overflow: auto; padding: 0 16px 10px; }
.log div { display: flex; align-items: baseline; gap: 10px; padding: 7px 0; border-top: 1px solid var(--divider); font-size: 13px; }
.log time { flex: none; color: var(--small-title); font-variant-numeric: tabular-nums; }
.log span { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.log b { flex: none; font-weight: 500; color: var(--summary); } .log b.bad { color: var(--error); }
.log .empty { color: var(--summary); }

/* guide: a spotlight on one control at a time */
.coach-block { position: fixed; inset: 0; z-index: 38; }
.coach { position: fixed; z-index: 39; border-radius: 18px; box-shadow: 0 0 0 200vmax var(--dim); pointer-events: none;
  transition: left .4s var(--ease), top .4s var(--ease), width .4s var(--ease), height .4s var(--ease); }
.coach-card { position: fixed; z-index: 40; width: min(340px, calc(100vw - 32px)); padding: 20px; border-radius: 24px; background: var(--card);
  display: flex; flex-direction: column; gap: 10px; box-shadow: 0 12px 40px rgba(0,0,0,.25);
  transition: left .4s var(--ease), top .4s var(--ease); animation: dlg .45s var(--spring) both; }
.coach-card .step { font-size: 12px; font-weight: 500; color: var(--small-title); }
.coach-card h3 { margin: 0; font-size: 19px; font-weight: 500; }
.coach-card p { margin: 0; font-size: 14px; line-height: 1.55; color: var(--on-surface-secondary); }
.coach-card .legend { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 12px; padding: 4px 0; }
.coach-card .legend div { display: flex; align-items: center; gap: 8px; font-size: 13px; }
.coach-card .legend svg { width: 20px; height: 20px; color: var(--primary); }
.coach-card .go { display: flex; align-items: center; justify-content: space-between; padding-top: 4px; }
.coach-card .go .btn.primary { min-height: 40px; padding: 8px 20px; font-size: 15px; margin-left: auto; }

/* buttons, segmented, sheet, dialog, snackbar */
.btn { border: 0; min-width: 58px; min-height: 48px; padding: 13px 16px; border-radius: var(--r-btn); font-size: 17px; font-weight: 500; cursor: pointer;
  background: var(--secondary-variant); color: var(--on-secondary-variant); transition: transform .3s var(--spring), filter .15s, opacity .2s; }
.btn.primary { background: var(--primary); color: var(--on-primary); }
.btn:active:not(:disabled) { transform: scale(.96); filter: brightness(.94); }
.btn:disabled { cursor: default; } .btn.primary:disabled { background: var(--disabled-primary); }
.btn.text { background: transparent; color: var(--primary); font-size: 15px; min-height: 36px; padding: 8px 12px; }
.btnrow { display: flex; gap: 12px; padding-top: 8px; } .btnrow .btn { flex: 1; }
.seg { display: flex; gap: 4px; padding: 4px; border-radius: 14px; background: var(--surface); }
.seg button { flex: 1; border: 0; background: transparent; padding: 8px 10px; border-radius: 10px; font-size: 14px; cursor: pointer; color: var(--summary);
  transition: background .25s var(--ease), color .25s; white-space: nowrap; }
.seg button[aria-pressed="true"] { background: var(--card); color: var(--on-tertiary-container); font-weight: 500; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
.row { display: flex; flex-direction: column; gap: 8px; padding: 6px 0; }
.row > b { font-size: 14px; font-weight: 500; color: var(--small-title); padding: 0 4px; }
.comp { display: flex; align-items: center; gap: 12px; min-height: 56px; padding: 14px 16px; border-radius: var(--r-card); background: var(--surface);
  cursor: pointer; transition: background .15s; }
.comp:hover { background: var(--press); }
.comp .t { flex: 1; display: flex; flex-direction: column; gap: 2px; }
.comp .title { font-size: 16px; font-weight: 500; } .comp .summary { font-size: 13px; color: var(--summary); }
.scrim { position: fixed; inset: 0; z-index: 20; background: var(--dim); display: flex; align-items: center; justify-content: center; padding: 12px; animation: fade .25s both; }
.scrim.bottom { align-items: flex-end; padding: 0; }
@keyframes fade { from { opacity: 0; } }
.dialog { width: 420px; max-width: 100%; max-height: 100%; overflow: auto; background: var(--card); border-radius: var(--r-dialog); padding: 24px;
  display: flex; flex-direction: column; gap: 12px; animation: dlg .45s var(--spring) both; }
@keyframes dlg { from { transform: scale(.9); opacity: 0; } to { transform: none; opacity: 1; } }
.dialog h3 { margin: 4px 0 0; text-align: center; font-size: 20px; font-weight: 500; }
.dialog p { margin: 0; text-align: center; font-size: 15px; color: var(--on-surface-secondary); line-height: 1.5; }
.sheet { width: 100%; max-width: 640px; max-height: 88dvh; overflow: auto; background: var(--card); border-radius: 28px 28px 0 0;
  padding: 0 24px calc(24px + env(safe-area-inset-bottom)); animation: up .45s var(--ease) both; display: flex; flex-direction: column; gap: 6px; }
@keyframes up { from { transform: translateY(100%); } }
.sheet .handle { width: 36px; height: 4px; border-radius: 2px; background: var(--handle); margin: 12px auto 6px; flex: none; }
.sheet h3 { margin: 0 0 6px; text-align: center; font-size: 20px; font-weight: 500; }
.snack { position: fixed; left: 50%; bottom: calc(28px + env(safe-area-inset-bottom)); z-index: 30; transform: translateX(-50%);
  display: flex; align-items: center; gap: 4px; max-width: calc(100vw - 32px); background: var(--snack); color: var(--snack-ink);
  padding: 8px 8px 8px 18px; min-height: 48px; border-radius: 16px; font-size: 14px; animation: snack .4s var(--spring) both; }
.snack span { padding: 6px 8px 6px 0; }
.snack .btn.text { color: var(--primary); }
@keyframes snack { from { transform: translate(-50%, 20px); opacity: 0; } }

/* pairing */
/* Pairing takes the screen's place only: the device list, the tools and the
   settings stay usable around it. */
.pairpage { position: absolute; inset: 0; z-index: 5; display: grid; place-items: center; background: var(--surface); padding: 8px; overflow: auto; }
.paircard { width: min(420px, 100%); padding: 32px 24px 24px; display: flex; flex-direction: column; align-items: center; gap: 10px; text-align: center; }
.paircard .icon { width: 72px; height: 72px; border-radius: 18px; }
.paircard h1 { margin: 6px 0 0; font-size: 24px; font-weight: 500; }
.paircard p { margin: 0; font-size: 15px; color: var(--summary); line-height: 1.55; }
#pair-start, #pair-wait { align-self: stretch; display: flex; flex-direction: column; align-items: center; gap: 12px; }
#pair-start .btn { align-self: stretch; margin-top: 8px; }
.fp { font: 600 28px/1.2 ui-monospace, "SF Mono", Menlo, monospace; letter-spacing: .12em; padding: 14px 20px; border-radius: 16px;
  background: var(--tertiary-container); color: var(--on-tertiary-container); }
.waiting { display: inline-flex; align-items: center; gap: 10px; font-size: 14px; color: var(--summary); }
.err { color: var(--error); font-size: 14px; min-height: 1.4em; }
.link { color: var(--primary); cursor: pointer; background: none; border: 0; padding: 0; font-size: 13px; }
.keyfield { align-self: stretch; height: 48px; padding: 0 14px; border-radius: 14px; border: 0; background: var(--secondary-container);
  font-family: ui-monospace, Menlo, monospace; font-size: 14px; outline: 0; }
#kbd { position: fixed; left: -1000px; top: 0; width: 10px; height: 10px; opacity: 0; }

/* Wide: the list folds away by its width, so the screen glides over rather
   than jumping, and unfolds the same way. Its content keeps its width while
   the box narrows, so nothing rewraps on the way. */
@media (min-width: 1100px) {
  .devices { transition: width .45s var(--ease), margin-right .45s var(--ease), opacity .3s var(--ease), transform .45s var(--ease); }
  .devices > .head, .devices > .devlist { min-width: 252px; }
  .devices > .add { min-width: 236px; }   /* 252 less its 8px margins */
  .devices.collapsed { width: 0; margin-right: -12px; opacity: 0; transform: translateX(-16px); pointer-events: none; visibility: hidden;
    transition: width .45s var(--ease), margin-right .45s var(--ease), opacity .25s var(--ease), transform .45s var(--ease), visibility 0s .45s; }
}
@media (max-width: 1099px) {
  .devices { position: fixed; left: 0; top: 0; bottom: 0; z-index: 16; width: min(300px, 86vw); border-radius: 0 24px 24px 0;
    padding-top: env(safe-area-inset-top); box-shadow: 10px 0 40px rgba(0,0,0,.25); animation: from-left .35s var(--ease) both; }
  .devices:not(.open) { display: none; }
  .side { position: fixed; right: 0; top: 0; bottom: 0; z-index: 15; width: min(360px, 90vw); border-radius: 24px 0 0 24px;
    padding-top: env(safe-area-inset-top); box-shadow: -10px 0 40px rgba(0,0,0,.25); animation: from-right .35s var(--ease) both; }
}
/* phone-sized either way up: compact top bar, people as icons */
@media (max-width: 760px), (max-height: 520px) {
  .topbar { padding: 0 6px 0 12px; gap: 2px; }
  .pill { max-width: 34vw; padding: 0 10px; gap: 6px; }
  .pill .long { display: none; } .pill .short { display: inline-flex; }
  #btn-full { display: none; }
  /* No room in the top bar for words: icons there whatever the setting. */
  .topbar .labeled { width: 40px !important; padding: 0 !important; justify-content: center; }
  .topbar .labeled svg { display: block !important; } .topbar .labeled .lbl { display: none !important; }
}
/* landscape phone: every point of height for the screen; tools stay right */
@media (max-height: 520px) and (orientation: landscape) {
  .topbar { height: 44px; }
  .body { gap: 8px; padding: 0 calc(8px + env(safe-area-inset-right)) 8px calc(8px + env(safe-area-inset-left)); }
  .rail { align-self: stretch; justify-content: flex-start; }
}
/* portrait phone: tools under the screen, view tree as a bottom sheet */
@media (max-width: 760px) and (orientation: portrait) {
  .body { grid-template-columns: minmax(0, 1fr); grid-template-rows: minmax(0, 1fr) auto; grid-template-areas: "stage" "tools";
    gap: 8px; padding: 0 8px calc(8px + env(safe-area-inset-bottom)); }
  .rail { flex-direction: row; justify-content: space-around; align-self: stretch; overflow-x: auto; overflow-y: hidden; }
  .side { left: 0; right: 0; top: auto; bottom: 0; width: auto; height: 60dvh; z-index: 15; border-radius: 28px 28px 0 0; padding-top: 0;
    box-shadow: 0 -10px 40px rgba(0,0,0,.25); animation: up .45s var(--ease) both; }
  .side .head::before { content: ""; position: absolute; left: 50%; top: 8px; width: 36px; height: 4px; margin-left: -18px; border-radius: 2px; background: var(--handle); }
  .side .head { position: relative; padding-top: 22px; }
  .labels-text .rail .labeled, .labels-both .rail .labeled { flex: 1 0 auto; justify-content: center; }
  .labels-both .rail .labeled { flex-direction: column; gap: 2px; height: 52px; padding: 4px 6px; }
  .labels-both .rail .lbl { font-size: 11px; }
}
/* ── motion: every control answers a press, every panel arrives and leaves ──
   A press shrinks a control at once and lets it spring back; a ripple
   spreads from where it was pressed. Panels slide or scale out as they came
   in instead of vanishing. Values follow miuix's spring feel. */
:root { --out: cubic-bezier(.4, 0, .9, .6); }
.iconbtn, .btn, .pill, .comp, .dev, .person .top, .node, .seg button, .titles, .link {
  -webkit-tap-highlight-color: transparent; touch-action: manipulation; }
.iconbtn, .btn, .pill, .comp, .dev, .titles, .seg button {
  transition: transform .45s var(--spring), background-color .2s, color .2s, box-shadow .2s, opacity .2s; }
.iconbtn:active, .btn:active:not(:disabled), .pill:active, .comp:active, .dev:active, .titles:active, .person .top:active, .node:active {
  transform: scale(.93); transition-duration: .08s, .1s, .1s, .1s, .1s; }
.btn:active:not(:disabled) { transform: scale(.96); }
.rippling { position: relative; overflow: hidden; isolation: isolate; }
.ripple { position: absolute; border-radius: 50%; background: currentColor; opacity: .16; pointer-events: none; z-index: -1;
  transform: scale(0); animation: ripple .6s var(--ease) forwards; }
.btn.primary .ripple { background: #fff; opacity: .25; }
@keyframes ripple { 60% { opacity: .12; } to { transform: scale(1); opacity: 0; } }
/* the tool's own gesture when it runs */
.iconbtn.pop svg { animation: pop .5s var(--spring); }
.iconbtn.pop[data-act="rotate"] svg { animation: turn .55s var(--ease); }
.iconbtn.pop[data-act="notifications"] svg { animation: swing .7s var(--ease); transform-origin: 50% 15%; }
.iconbtn.pop[data-act="switcher"] svg, .iconbtn.pop[data-act="home"] svg { animation: hop .5s var(--spring); }
@keyframes pop { 40% { transform: scale(1.22); } }
@keyframes turn { from { transform: rotate(-90deg); } }
@keyframes swing { 20% { transform: rotate(14deg); } 40% { transform: rotate(-10deg); } 60% { transform: rotate(6deg); } 80% { transform: rotate(-3deg); } }
@keyframes hop { 40% { transform: translateY(-4px) scale(1.08); } }
.iconbtn svg, .btn svg { transition: transform .3s var(--spring); }
/* recording: a ring keeps breathing out of the button */
.iconbtn.rec::after { content: ""; position: absolute; inset: 4px; border-radius: 50%; border: 2px solid var(--error); pointer-events: none;
  animation: breathe 1.6s var(--ease) infinite; }
@keyframes breathe { from { transform: scale(.7); opacity: .7; } to { transform: scale(1.25); opacity: 0; } }
.badge.bump, .pill.bump .pdot { animation: pop .45s var(--spring); }
.pill .pdot { transition: background-color .3s; }
.titles .chev { transition: transform .35s var(--spring); }
.titles[aria-expanded="true"] .chev { transform: rotate(180deg); }
/* segmented: the highlight slides to the choice */
.seg { position: relative; }
.seg::before { content: ""; position: absolute; top: 4px; bottom: 4px; border-radius: 10px; background: var(--card);
  box-shadow: 0 1px 3px rgba(0,0,0,.08); --w: calc((100% - 8px - (var(--n, 1) - 1) * 4px) / var(--n, 1));
  width: var(--w); left: calc(4px + var(--i, 0) * (var(--w) + 4px)); transition: left .45s var(--spring); }
.seg button { position: relative; z-index: 1; }
.seg button[aria-pressed="true"] { background: transparent; box-shadow: none; }
/* arrivals */
.msg:not([hidden]), .tag:not([hidden]) { animation: fade .3s var(--ease) both; }
.msg .box { animation: rise .45s var(--spring) both; }
.paircard { animation: dlg .5s var(--spring) both; }
.fp { animation: pop .5s var(--spring) both; }
/* "backwards": only until they finish. Held afterwards ("both"), they would
   pin opacity and transform, and the device list's fold couldn't fade. */
.topbar, #tools, #devices:not(.open) { animation: rise .5s var(--ease) backwards; }
#tools { animation-delay: .06s; }
@keyframes rise { from { transform: translateY(8px); opacity: 0; } }
.devlist.entering .dev { animation: rise .4s var(--ease) both; animation-delay: calc(var(--k, 0) * 35ms); }
.people .person { animation: rise .35s var(--ease) both; }
.log div { animation: fade .25s both; }
.node { transition: background-color .15s; }
/* departures */
.scrim.closing, .drawer-scrim.closing { animation: fadeout .24s var(--out) forwards; pointer-events: none; }
.scrim.closing .dialog { animation: dlgout .22s var(--out) forwards; }
.scrim.closing .sheet { animation: down .28s var(--out) forwards; }
.snack.leaving { animation: snackout .25s var(--out) forwards; }
.devices.closing { animation: to-left .28s var(--out) forwards !important; }
.side.closing { animation: to-right .28s var(--out) forwards !important; }
@keyframes fadeout { to { opacity: 0; } }
@keyframes dlgout { to { transform: scale(.94); opacity: 0; } }
@keyframes down { to { transform: translateY(100%); } }
@keyframes snackout { to { transform: translate(-50%, 16px); opacity: 0; } }
@keyframes to-left { to { transform: translateX(-100%); } }
@keyframes to-right { to { transform: translateX(100%); } }
@media (max-width: 760px) and (orientation: portrait) { .side.closing { animation: down .28s var(--out) forwards !important; } }
/* the theme changes as a cross-fade, not a flash */
.theming, .theming * { transition: background-color .35s var(--ease), color .35s var(--ease), border-color .35s, fill .35s !important; }
@media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation-duration: 1ms !important; transition-duration: 1ms !important; } }
</style>
</head>
<body>
<div class="app" id="app">
  <header class="topbar">
    <img src="remote/icon.png" alt="">
    <button class="titles" id="title-btn" data-tip="devices"><span class="brand"><span id="name">LoopCtrl</span><svg class="chev" viewBox="0 0 24 24"><path d="M8 10l4 4 4-4"/></svg></span><span class="sub" id="sub"></span></button>
    <span class="sp"></span>
    <button class="pill" id="people" hidden><i class="pdot"></i><span class="long"></span><span class="short"></span></button>
    <button class="iconbtn" id="btn-rec" data-tip="record"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="7"/><circle cx="12" cy="12" r="3" fill="currentColor"/></svg><i class="badge" hidden></i></button>
    <button class="iconbtn" id="btn-tree" data-tip="tree"><svg viewBox="0 0 24 24"><path d="M4 5h6M4 12h4M10 12h10M4 19h4M10 19h10M14 5h6"/><path d="M7 5v14"/></svg></button>
    <button class="iconbtn" id="btn-settings" data-tip="settings"><svg viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg></button>
    <button class="iconbtn" id="btn-full" data-tip="full"><svg viewBox="0 0 24 24"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg></button>
  </header>
  <main class="body">
    <aside class="devices card" id="devices">
      <div class="head"><b data-t="devicesTitle"></b>
        <button class="iconbtn" id="devices-close" data-tip="close"><svg viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></svg></button></div>
      <div class="devlist" id="devlist"></div>
      <button class="btn add" id="dev-add"><svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg><span data-t="addDevice"></span></button>
    </aside>
    <section class="stage">
      <div class="screen" id="screen">
        <canvas id="video"></canvas>
        <video id="mse" muted playsinline autoplay disablepictureinpicture hidden></video>
        <canvas id="overlay"></canvas>
        <div class="tag" id="hidden-tag" hidden></div>
        <div class="msg" id="screen-msg"><div class="box"><div class="spin"></div><span></span></div></div>
        <div class="msg paused" id="paused-msg" hidden><div class="box">
          <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M10 9v6M14 9v6"/></svg><span></span></div></div>
      </div>
      <div class="pairpage" id="pair" hidden>
        <div class="paircard card">
          <img class="icon" src="remote/icon.png" alt="">
          <h1 id="pair-name">LoopCtrl</h1>
          <div id="pair-start" class="paircard-body">
            <p data-t="pairHint"></p>
            <button class="btn primary" id="pair-btn" data-t="pair"></button>
          </div>
          <div id="pair-wait" hidden>
            <p data-t="approve"></p>
            <div class="fp" id="pair-fp"></div>
            <div class="waiting"><div class="spin"></div><span data-t="waiting"></span></div>
          </div>
          <div class="err" id="pair-err"></div>
          <button class="link" id="key-toggle" data-t="haveKey"></button>
          <input class="keyfield" id="key-input" type="password" autocomplete="off" spellcheck="false" placeholder="64 hex" hidden>
        </div>
      </div>
    </section>
    <nav class="rail card" id="tools">
      <button class="iconbtn" data-act="home" data-tip="home"><svg viewBox="0 0 24 24"><path d="M4 11l8-7 8 7v9h-5v-6H9v6H4z"/></svg></button>
      <button class="iconbtn" data-act="switcher" data-tip="switcher"><svg viewBox="0 0 24 24"><rect x="8" y="3" width="12" height="14" rx="2.5"/><path d="M4 7v11a3 3 0 0 0 3 3h9"/></svg></button>
      <button class="iconbtn" data-act="notifications" data-tip="notifications"><svg viewBox="0 0 24 24"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2 2 0 0 0 4 0"/></svg></button>
      <button class="iconbtn" data-act="controls" data-tip="controls"><svg viewBox="0 0 24 24"><rect x="3" y="4" width="8" height="8" rx="4"/><rect x="13" y="4" width="8" height="8" rx="2.5"/><rect x="3" y="14" width="8" height="6" rx="2.5"/><rect x="13" y="14" width="8" height="6" rx="3"/></svg></button>
      <button class="iconbtn" data-act="rotate" data-tip="rotate"><svg viewBox="0 0 24 24"><rect x="3" y="10" width="14" height="10" rx="2.5"/><path d="M11 3.5a8 8 0 0 1 9 7.5"/><path d="M21 7.5l-1 3.5-3.4-1.3"/></svg></button>
      <button class="iconbtn" data-act="app" data-tip="app"><svg viewBox="0 0 24 24"><rect x="4" y="4" width="6" height="6" rx="1.8"/><rect x="14" y="4" width="6" height="6" rx="1.8"/><rect x="4" y="14" width="6" height="6" rx="1.8"/><path d="M17 14v6M14 17h6"/></svg></button>
      <button class="iconbtn" data-act="keyboard" data-tip="keyboard"><svg viewBox="0 0 24 24"><rect x="3" y="6" width="18" height="12" rx="3"/><path d="M7 10h.01M11 10h.01M15 10h.01M7 14h10"/></svg></button>
      <button class="iconbtn" data-act="wire" data-tip="wire"><svg viewBox="0 0 24 24"><rect x="4" y="3" width="16" height="18" rx="3"/><path d="M4 9h16M10 9v12"/></svg></button>
    </nav>
    <aside class="side card" id="tree-panel" hidden>
      <div class="head"><b data-t="tree"></b>
        <button class="iconbtn" id="tree-refresh" data-tip="refresh"><svg viewBox="0 0 24 24"><path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7"/></svg></button>
        <button class="iconbtn" id="tree-close" data-tip="close"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
      </div>
      <label class="search"><svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6"/><path d="M20 20l-4.5-4.5"/></svg>
        <input id="tree-filter" type="search" autocomplete="off" spellcheck="false"></label>
      <div id="tree"></div>
      <div class="foot" id="tree-foot"></div>
    </aside>
  </main>
</div>

<textarea id="kbd" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"></textarea>
<input type="file" id="flow-file" accept="application/json,.json" hidden>
<script>
"use strict";
(() => {
// ───────────────────────────── text ─────────────────────────────
const zh = /^zh/i.test(navigator.language || "");
const T = {
  pair: ["Pair this browser", "配对此浏览器"],
  pairHint: ["The phone will ask its owner to allow this browser.", "手机上会请机主确认是否允许此浏览器。"],
  approve: ["Tap Allow on the phone if it shows this code", "手机上显示同样的代码时，请点“允许”"],
  waiting: ["Waiting for the phone…", "正在等待手机确认…"],
  haveKey: ["Use an existing key", "使用已有密钥"],
  denied: ["Declined on the phone.", "手机上拒绝了配对。"],
  busy: ["The phone is answering another request. Try again in %s s.", "手机正在处理另一个配对请求，%s 秒后再试。"],
  failed: ["Could not pair: %s", "配对失败：%s"],
  connecting: ["Connecting…", "正在连接…"],
  noVideo: ["The screen is unavailable: %s", "画面不可用：%s"],
  waitingFrame: ["Waiting for the screen…", "正在等待画面…"],
  relay: ["Relay", "中继"], direct: ["Direct", "直连"], offline: ["Offline", "未连接"],
  srcCapture: ["Screenshots", "截图"], srcBroadcast: ["Screen recording", "系统录屏"],
  home: ["Home", "主屏幕"], app: ["Open app", "打开 App"], keyboard: ["Type", "键盘输入"], wire: ["Outlines", "元素轮廓"],
  tree: ["View tree", "视图树"], full: ["Full screen", "全屏"],
  settings: ["Screen settings", "画面设置"], record: ["Record", "录制操作"], refresh: ["Refresh", "刷新"], close: ["Close", "关闭"],
  appPrompt: ["App name", "App 名称"], notFound: ["No app matches “%s”.", "没有找到“%s”。"],
  filter: ["Filter", "筛选元素"], nodes: ["%s elements", "%s 个元素"], treeErr: ["Could not read the view tree: %s", "无法读取视图树：%s"],
  quality: ["Quality", "画质"], codec: ["Codec", "编码"], theme: ["Appearance", "外观"],
  auto: ["Auto", "自动"], system: ["System", "跟随系统"], light: ["Light", "浅色"], dark: ["Dark", "深色"],
  replay: ["Replay a recording…", "回放录制…"], replayHint: ["Run the steps of a saved recording on this phone", "在这台手机上依次执行保存的录制步骤"],
  done: ["Done", "完成"],
  paused: ["The phone's owner paused remote control.\nNothing is visible or sent until they resume it on the phone.",
           "机主已在手机上暂停远程控制。\n在机主继续之前，看不到画面，也无法操作。"],
  hiddenTag: ["This screen blocks capture · showing outlines", "此画面禁止截屏 · 显示元素轮廓"],
  pausedPill: ["Paused by owner", "机主已暂停"],
  switcher: ["App switcher", "多任务"], rotate: ["Rotate", "旋转屏幕"],
  notifications: ["Notification Center", "通知中心"], controls: ["Control Center", "控制中心"],
  operatingN: ["%s operating", "%s 人在操控"], watchingN: ["%s watching", "%s 人在查看"],
  people: ["Watching and operating", "查看与操控"], you: ["You", "你"], agent: ["Agent", "智能体"],
  operatingNow: ["Operating · %s actions", "正在操控 · %s 次操作"], watchingNow: ["Watching · %s actions", "在查看 · %s 次操作"],
  gone: ["Left · %s actions", "已离开 · %s 次操作"], noActions: ["No actions yet", "还没有操作"],
  o_failed: ["failed", "失败"], o_unknown: ["unknown", "结果未知"], o_queued: ["timed out", "排队超时"], o_sent: ["sending", "发送中"],
  labels: ["Buttons", "按钮样式"], icons: ["Icons", "图标"], words: ["Text", "文字"], both: ["Icons and text", "图标+文字"],
  guideAgain: ["Show the guide again", "重新查看引导"], guideHint: ["A short tour of the controls", "快速了解各个按钮的作用"],
  next: ["Next", "下一步"], skip: ["Skip", "跳过"], gotIt: ["Start", "开始使用"],
  g1t: ["Drive the phone here", "在这里操作手机"],
  g1d: ["Click to tap, drag to swipe, hold to long-press. Scroll with the wheel; hold Option (Alt) while dragging to pinch. Typing goes straight to the phone.",
        "单击是点按，拖动是滑动，按住不放是长按。滚轮可以滚动；按住 Option（Alt）拖动是双指缩放。直接打字就会输入到手机上。"],
  g1m: ["Tap, swipe and hold as on the phone itself; pinch with two fingers.", "像在手机上一样点按、滑动和长按，双指捏合可以缩放。"],
  g2t: ["Buttons", "常用按键"], g2: ["The phone's buttons and a few tools:", "手机的按键和几个常用工具："],
  g3t: ["Connection", "连接状态"],
  g3: ["How you're connected, the codec, frame rate and delay. On the right: how many are watching and operating — open it for everyone's actions.",
       "这里是连接方式、编码、帧率和延迟。右侧显示有几人在查看和操控，点开可以看每个人的操作记录。"],
  g4t: ["Record and replay", "录制与回放"], g4: ["Record what you do, then replay it or download it as a file.", "录下你的操作，之后可以回放，或者下载成文件。"],
  g5t: ["View tree", "视图树"], g5: ["Lists the elements on screen. Point at one to find it on the screen; choose it to tap it.", "列出屏幕上的元素。指向一个元素会在画面上标出它，点一下就会点按它。"],
  g6t: ["Settings", "画面设置"], g6: ["Quality, codec, appearance and button style. The guide is here too.", "画质、编码、外观和按钮样式都在这里，也可以在这里重新查看引导。"],
  unknownOutcome: ["%s may or may not have happened. It wasn't sent again.", "%s 的结果未知，已停止，未重复发送。"],
  failedAction: ["%s failed: %s", "%s 失败：%s"],
  recSaved: ["Recorded %s steps", "已录制 %s 步"], recEmpty: ["Nothing was recorded.", "没有录到任何操作。"],
  download: ["Download", "下载"], discard: ["Discard", "丢弃"], play: ["Replay", "回放"],
  replaying: ["Replaying %s/%s", "正在回放 %s/%s"], replayDone: ["Replay finished", "回放完成"], stop: ["Stop", "停止"],
  badFlow: ["That file isn't a LoopCtrl recording.", "这不是 LoopCtrl 的录制文件。"],
  devices: ["Devices", "切换设备"], devicesTitle: ["Devices", "设备"], addDevice: ["Add a device", "添加设备"],
  addHint: ["Paste the address of another phone's control page.", "粘贴另一台手机控制页的地址。"],
  badUrl: ["That isn't a web address.", "这不是一个网址。"], devOn: ["Online", "在线"], devOff: ["Offline", "离线"],
  devOpen: ["Open to check", "打开后可查看"], devThis: ["This phone", "当前"], remove: ["Remove", "移除"], add: ["Add", "添加"],
  g7t: ["Your phones", "多台手机"],
  g7: ["Every phone you've opened here is listed, with whether it's online: choose one to switch to it. In a narrow window, tap the phone's name.",
       "在这里打开过的手机都会列出来，并显示是否在线，点一下就能切换。窗口较窄时，点左上角的手机名称打开列表。"],
  phoneOffline: ["The phone isn't connected. Waiting for it…", "手机未连接，正在等待它上线…"],
  pageUpdated: ["A newer control page is ready.", "控制页已更新。"], reload: ["Reload", "刷新"],
  hevcGeometry: ["H.265 is drawn wrong in this browser: switched to H.264.", "此浏览器的 H.265 画面显示不正确，已改用 H.264。"],
  copyDiag: ["Copy diagnostics", "复制诊断信息"], copyDiagHint: ["What this page saw of the stream, to send to the developer", "本页的画面与连接情况，可发给开发者排查问题"],
  copied: ["Copied", "已复制"],
  hevcFallback: ["H.265 keeps stalling in this browser: switched to H.264.", "此浏览器的 H.265 解码多次卡住，已改用 H.264。"],
};
const t = (k, ...a) => { let s = (T[k] || [k])[zh ? 1 : 0] || (T[k] || [k])[0]; for (const v of a) s = s.replace("%s", v); return s; };
document.documentElement.lang = zh ? "zh" : "en";
for (const el of document.querySelectorAll("[data-t]")) el.textContent = t(el.dataset.t);
for (const el of document.querySelectorAll("[data-tip]")) { el.title = t(el.dataset.tip); el.setAttribute("aria-label", el.title); }
const $ = (id) => document.getElementById(id);
$("tree-filter").placeholder = t("filter");

// ───────────────────────────── settings ─────────────────────────────
const prefs = {
  get(k) { try { return localStorage.getItem("loopctrl." + k); } catch (_) { return null; } },
  set(k, v) { try { localStorage.setItem("loopctrl." + k, v); } catch (_) {} },
};
const settings = {
  quality: prefs.get("quality") || "",   // filled in at start, once we know relay or direct
  codec: prefs.get("codec") || "auto",
  theme: prefs.get("theme") || "system",
  // Words beside the icons where there is room for them.
  labels: prefs.get("labels") || (matchMedia("(pointer: fine) and (min-width: 900px)").matches ? "both" : "icon"),
};
function applyTheme() {
  const root = document.documentElement;
  if (document.body) {
    root.classList.add("theming");
    clearTimeout(applyTheme.timer);
    applyTheme.timer = setTimeout(() => root.classList.remove("theming"), 450);
  }
  if (settings.theme === "light" || settings.theme === "dark") root.dataset.theme = settings.theme;
  else delete root.dataset.theme;
}
applyTheme();

// ───────────────────────────── bytes ─────────────────────────────
const enc = new TextEncoder(), dec = new TextDecoder();
const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const unhex = (s) => { const o = new Uint8Array(s.length >> 1); for (let i = 0; i < o.length; i++) o[i] = parseInt(s.substr(i * 2, 2), 16); return o; };
const cat = (...parts) => { let n = 0; for (const p of parts) n += p.length; const o = new Uint8Array(n); let i = 0; for (const p of parts) { o.set(p, i); i += p.length; } return o; };
const b64 = (b) => { let s = ""; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s) => { const r = atob(s), o = new Uint8Array(r.length); for (let i = 0; i < r.length; i++) o[i] = r.charCodeAt(i); return o; };
const random = (n) => crypto.getRandomValues(new Uint8Array(n));
const be64 = (v) => { const o = new Uint8Array(8), d = new DataView(o.buffer); d.setUint32(0, Math.floor(v / 4294967296)); d.setUint32(4, v >>> 0); return o; };
const be32 = (v) => { const o = new Uint8Array(4); new DataView(o.buffer).setUint32(0, v); return o; };
const SUBTLE = (window.isSecureContext && crypto.subtle) ? crypto.subtle : null;

// ───────────────────────────── SHA-256 / HMAC ─────────────────────────────
// Plain JavaScript on purpose: it works on http:// pages, and the request
// cipher is one HMAC per 32 bytes, far cheaper here than an async WebCrypto
// call each time.
const K256 = new Int32Array([
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,
  0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,
  0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,
  0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);
const W = new Int32Array(64);
function compress(h, b, o) {
  for (let i = 0; i < 16; i++) W[i] = (b[o + i * 4] << 24) | (b[o + i * 4 + 1] << 16) | (b[o + i * 4 + 2] << 8) | b[o + i * 4 + 3];
  for (let i = 16; i < 64; i++) {
    const x = W[i - 15], y = W[i - 2];
    W[i] = (((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3)) + W[i - 7] +
           (((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10)) + W[i - 16] | 0;
  }
  let a = h[0], c1 = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
  for (let i = 0; i < 64; i++) {
    const t1 = k + (((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))) + ((e & f) ^ (~e & g)) + K256[i] + W[i] | 0;
    const t2 = (((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))) + ((a & c1) ^ (a & c) ^ (c1 & c)) | 0;
    k = g; g = f; f = e; e = d + t1 | 0; d = c; c = c1; c1 = a; a = t1 + t2 | 0;
  }
  h[0] = h[0] + a | 0; h[1] = h[1] + c1 | 0; h[2] = h[2] + c | 0; h[3] = h[3] + d | 0;
  h[4] = h[4] + e | 0; h[5] = h[5] + f | 0; h[6] = h[6] + g | 0; h[7] = h[7] + k | 0;
}
const IV = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
// state after `prefix` (whole 64-byte blocks), then the rest of `msg`
function shaFrom(state, done, msg) {
  const h = Int32Array.from(state);
  const total = done + msg.length, full = msg.length & ~63;
  for (let o = 0; o < full; o += 64) compress(h, msg, o);
  const tail = new Uint8Array(((msg.length - full + 9 + 63) >> 6) << 6);
  tail.set(msg.subarray(full)); tail[msg.length - full] = 0x80;
  const dv = new DataView(tail.buffer), bits = total * 8;
  dv.setUint32(tail.length - 8, Math.floor(bits / 4294967296)); dv.setUint32(tail.length - 4, bits >>> 0);
  for (let o = 0; o < tail.length; o += 64) compress(h, tail, o);
  const out = new Uint8Array(32), ov = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) ov.setInt32(i * 4, h[i]);
  return out;
}
const sha256 = (m) => shaFrom(IV, 0, m);
// HMAC with the key's pads absorbed once, for the many blocks of a keystream
function hmacKey(key) {
  if (key.length > 64) key = sha256(key);
  const ip = new Uint8Array(64).fill(0x36), op = new Uint8Array(64).fill(0x5c);
  for (let i = 0; i < key.length; i++) { ip[i] ^= key[i]; op[i] ^= key[i]; }
  const hi = Int32Array.from(IV), ho = Int32Array.from(IV);
  compress(hi, ip, 0); compress(ho, op, 0);
  return (msg) => shaFrom(ho, 64, shaFrom(hi, 64, msg));
}
const hmac = (key, msg) => hmacKey(key)(msg);
function keystreamXor(key, nonce, data) {
  const mac = hmacKey(key), out = new Uint8Array(data.length);
  for (let i = 0, n = 0; i < data.length; i += 32, n++) {
    const block = mac(cat(nonce, be32(n)));
    for (let j = 0; j < 32 && i + j < data.length; j++) out[i + j] = data[i + j] ^ block[j];
  }
  return out;
}

// ───────────────────────────── X25519 ─────────────────────────────
// RFC 7748, with BigInt, for browsers without WebCrypto X25519. Only used
// once, while pairing.
const P = 2n ** 255n - 19n;
const mod = (a) => { a %= P; return a < 0n ? a + P : a; };
const pow = (b, e) => { let r = 1n; b = mod(b); while (e > 0n) { if (e & 1n) r = mod(r * b); b = mod(b * b); e >>= 1n; } return r; };
const leToInt = (b) => { let r = 0n; for (let i = b.length - 1; i >= 0; i--) r = (r << 8n) | BigInt(b[i]); return r; };
const intToLe = (n) => { const o = new Uint8Array(32); for (let i = 0; i < 32; i++) { o[i] = Number(n & 255n); n >>= 8n; } return o; };
function x25519(k, u) {
  const s = k.slice(); s[0] &= 248; s[31] &= 127; s[31] |= 64;
  const kn = leToInt(s), x1 = leToInt(u) & ((1n << 255n) - 1n);
  let x2 = 1n, z2 = 0n, x3 = x1, z3 = 1n, swap = 0n;
  for (let i = 254n; i >= 0n; i--) {
    const bit = (kn >> i) & 1n;
    if (swap ^ bit) { [x2, x3] = [x3, x2]; [z2, z3] = [z3, z2]; }
    swap = bit;
    const A = mod(x2 + z2), AA = mod(A * A), B = mod(x2 - z2), BB = mod(B * B), E = mod(AA - BB);
    const C = mod(x3 + z3), D = mod(x3 - z3), DA = mod(D * A), CB = mod(C * B);
    x3 = mod((DA + CB) ** 2n); z3 = mod(x1 * mod((DA - CB) ** 2n));
    x2 = mod(AA * BB); z2 = mod(E * (AA + 121665n * E));
  }
  if (swap) { [x2, x3] = [x3, x2]; [z2, z3] = [z3, z2]; }
  return intToLe(mod(x2 * pow(z2, P - 2n)));
}
async function ephemeralKey() {
  if (SUBTLE) {
    try {
      const kp = await SUBTLE.generateKey({ name: "X25519" }, true, ["deriveBits"]);
      return {
        pub: new Uint8Array(await SUBTLE.exportKey("raw", kp.publicKey)),
        shared: async (peer) => new Uint8Array(await SUBTLE.deriveBits(
          { name: "X25519", public: await SUBTLE.importKey("raw", peer, { name: "X25519" }, false, []) }, kp.privateKey, 256)),
      };
    } catch (_) { /* no X25519 in this browser */ }
  }
  const priv = random(32), base = new Uint8Array(32); base[0] = 9;
  return { pub: x25519(priv, base), shared: async (peer) => x25519(priv, peer) };
}

// ───────────────────────────── device and key ─────────────────────────────
let device = { id: "", name: "" };
let key = null, tok = "";        // the 32-byte pairing key and its id
let clockSkew = 0;               // server minus local, seconds
const storeName = () => "loopctrl.key." + (device.id || location.host);
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (_) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (_) {} },
  del(k) { try { localStorage.removeItem(k); } catch (_) {} },
};
function useKey(hexKey) {
  key = unhex(hexKey);
  tok = hex(sha256(key).subarray(0, 4));
}

class AuthError extends Error {}

// One sealed JSON-RPC call (protocol v1, see /skill).
let lastRTT = 0;
// A request on a connection that died quietly would wait forever, and with
// it everything queued behind it (acknowledgements, the next stream ticket).
// Give up after a while: the retry gets a fresh connection.
const RPC_TIMEOUT = { stream_ack: 4000, stream_ticket: 8000 };
// The direct path: a page that came through the relay talks to the phone on
// the LAN when both are on one (Chrome and Edge ask once to allow the local
// network; other browsers refuse an http address from an https page, and the
// relay carries on). apiBase is "" for this page's own origin.
let apiBase = "";
const LAN_FETCH = { targetAddressSpace: "local" };
const via = (base) => base ? LAN_FETCH : {};
async function rpc(method, params = {}, retry = true, base = apiBase) {
  if (!key) throw new AuthError("not paired");
  const nonce = random(16), ts = Math.floor(Date.now() / 1000 + clockSkew);
  const body = enc.encode(JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method, params }));
  const ct = keystreamXor(hmac(key, cat(enc.encode("loopctrl-v1|enc-req"), nonce)), nonce, body);
  const kMac = hmac(key, cat(enc.encode("loopctrl-v1|mac"), nonce));
  const tag = hmac(kMac, cat(enc.encode("v1"), unhex(tok), be64(ts), nonce, ct));
  const started = performance.now();
  const limit = RPC_TIMEOUT[method] || (method === "wait" ? 1000 * Number(params.timeout || params.duration || 10) + 20000 : 20000);
  const abort = new AbortController(), timer = setTimeout(() => abort.abort(), limit);
  let r, j;
  try {
    r = await fetch(base + "rpc", { method: "POST", headers: { "Content-Type": "application/json" }, signal: abort.signal,
      body: JSON.stringify({ v: 1, tok, ts, nonce: hex(nonce), ct: b64(ct), tag: hex(tag) }), ...via(base) });
    j = await r.json().catch(() => ({}));
  } catch (e) {
    // The LAN went away under us: the relay from now on.
    if (base && base === apiBase) dropDirect("rpc: " + (e.message || e));
    throw new Error(abort.signal.aborted ? "no answer from the phone" : (e.message || String(e)));
  } finally { clearTimeout(timer); }
  lastRTT = performance.now() - started;
  if (r.status === 401) {
    const e = j.error || {};
    if (e.code === "ts_skew" && e.server_ts && retry) {
      clockSkew = e.server_ts - Date.now() / 1000;
      return rpc(method, params, false, base);
    }
    throw new AuthError(e.message || "key rejected");
  }
  if (!j.ct || !j.tag) throw new Error((j.error && j.error.message) || ("HTTP " + r.status));
  const rct = unb64(j.ct);
  const want = hex(hmac(kMac, cat(enc.encode("resp"), nonce, rct)));
  if (want !== j.tag) throw new Error("reply failed verification");
  const out = JSON.parse(dec.decode(keystreamXor(hmac(key, cat(enc.encode("loopctrl-v1|enc-resp"), nonce)), nonce, rct)));
  if (out.error) {
    const e = new Error(out.error.message || "error " + out.error.code);
    e.code = out.error.code; e.data = out.error.data || {};
    throw e;
  }
  return out.result || {};
}

async function pair() {
  const eph = await ephemeralKey();
  $("pair-fp").textContent = hex(sha256(eph.pub)).slice(0, 8).toUpperCase().replace(/(.{4})/, "$1 ");
  show("pair-wait");
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome" : /Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : "Browser";
  const os = /iPhone|iPad/.test(ua) ? "iOS" : /Android/.test(ua) ? "Android" : /Mac/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
  const r = await fetch("pair", { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ client_name: browser + (os ? " · " + os : ""), pub: b64(eph.pub) }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = j.error || {};
    if (e.code === "pair_denied") throw new Error(t("denied"));
    if (r.status === 429) throw new Error(t("busy", e.retry_after || 30));
    throw new Error(t("failed", e.message || e.code || r.status));
  }
  const devPub = unb64(j.pub);
  const kWrap = hmac(await eph.shared(devPub), cat(enc.encode("loopctrl-pair"), eph.pub, devPub));
  const pad = hmac(kWrap, enc.encode("loopctrl-wrap"));
  const k = unhex(j.token_ct).map((b, i) => b ^ pad[i]);
  store.set(storeName(), hex(k));
  useKey(hex(k));
}

// ───────────────────────────── screen ─────────────────────────────
const screenEl = $("screen"), videoCanvas = $("video"), mse = $("mse"), overlay = $("overlay");
const octx = overlay.getContext("2d");
let points = { w: 0, h: 0 };               // tap space of the current frame
let decoded = 0, shownAt = 0;

function setMessage(text, spinning = true) {
  const m = $("screen-msg");
  m.hidden = !text;
  if (text) { m.querySelector("span").textContent = text; m.querySelector(".spin").hidden = !spinning; }
}

// WebCodecs: lowest latency; only in secure contexts.
class CodecPlayer {
  static ok() { return typeof VideoDecoder === "function" && window.isSecureContext; }
  constructor() { this.ctx = videoCanvas.getContext("2d"); this.decoder = null; this.needKey = true; this.conf = null; this.waiting = 0; this.shown = 0; }
  presented() { return this.shown; }
  async configure(cfg) {
    this.close();
    const conf = { codec: cfg.codec, description: unb64(cfg.description), optimizeForLatency: true };
    const support = await VideoDecoder.isConfigSupported(conf).catch(() => ({ supported: false }));
    if (!support.supported) throw new Error("unsupported codec " + cfg.codec);
    videoCanvas.width = cfg.width; videoCanvas.height = cfg.height;
    videoCanvas.hidden = false; mse.hidden = true;
    this.conf = conf;
    this.size = { w: cfg.width, h: cfg.height };
    this.start();
  }
  // A decoder that fails is closed for good: start a new one, from a keyframe.
  start() {
    this.waiting = 0;
    this.decoder = new VideoDecoder({
      output: (f) => {
        this.waiting = 0;
        checkGeometry(f, this.size, this.conf.codec);
        this.ctx.drawImage(f, 0, 0, videoCanvas.width, videoCanvas.height);
        f.close();
        this.shown++;
        frameShown();
      },
      error: (e) => { note("decoder error", (e && e.message) || ""); this.decoder = null; this.needKey = true; askKeyframe(); },
    });
    this.decoder.configure(this.conf);
    this.needKey = true;
  }
  // Fed for 2 s with nothing out and no error either: a decoder that hung
  // (seen with hardware H.265). Start over from a keyframe.
  check() {
    if (!this.decoder || !this.waiting || performance.now() - this.waiting < 2000) return;
    try { this.decoder.close(); } catch (_) {}
    this.decoder = null; this.needKey = true; this.waiting = 0;
    askKeyframe();
    decoderStalled(this.conf && this.conf.codec);
  }
  frame(keyframe, ts, data) {
    this.check();
    if (!this.decoder && this.conf) this.start();
    const d = this.decoder;
    if (!d || d.state !== "configured") return;
    if (!keyframe && (this.needKey || d.decodeQueueSize > 3)) {
      if (!this.needKey) askKeyframe();
      this.needKey = true;
      return;
    }
    this.needKey = false;
    if (!this.waiting) this.waiting = performance.now();
    try { d.decode(new EncodedVideoChunk({ type: keyframe ? "key" : "delta", timestamp: ts, data })); }
    catch (_) { this.decoder = null; this.needKey = true; askKeyframe(); }
  }
  close() { if (this.decoder && this.decoder.state !== "closed") this.decoder.close(); this.decoder = null; }
}

// Media Source Extensions, for http:// pages: each frame wrapped in
// fragmented MP4, played at a fixed pace and kept at the live edge.
class MsePlayer {
  static ok() { return !!(window.ManagedMediaSource || window.MediaSource); }
  constructor() { this.queue = []; this.sb = null; this.seq = 1; this.time = 0; this.needKey = true; }
  // What the video element painted, not what was handed to it: a media
  // element that errs or stalls keeps taking data and shows none of it.
  presented() {
    const q = mse.getVideoPlaybackQuality ? mse.getVideoPlaybackQuality() : null;
    return q ? q.totalVideoFrames : decoded;
  }
  configure(cfg) {
    this.close();
    const MS = window.ManagedMediaSource || window.MediaSource;
    const type = 'video/mp4; codecs="' + cfg.codec + '"';
    if (!MS.isTypeSupported(type)) throw new Error("unsupported codec " + cfg.codec);
    this.ms = new MS();
    mse.disableRemotePlayback = true;
    mse.src = URL.createObjectURL(this.ms);
    this.queue = [mp4Init(cfg)]; this.seq = 1; this.time = 0; this.needKey = true;
    this.ms.addEventListener("sourceopen", () => {
      this.sb = this.ms.addSourceBuffer(type);
      this.sb.mode = "segments";
      this.sb.addEventListener("updateend", () => this.pump());
      this.pump();
    }, { once: true });
    mse.hidden = false; videoCanvas.hidden = true;
    mse.play().catch(() => {});
  }
  frame(keyframe, ts, data) {
    if (!keyframe && (this.needKey || this.queue.length > 4)) {
      if (!this.needKey) askKeyframe();
      this.needKey = true;
      return;
    }
    this.needKey = false;
    this.queue.push(mp4Fragment(this.seq++, this.time, keyframe, data));
    this.time += 1500;   // 1/60 s at 90 kHz
    this.pump();
    frameShown();
  }
  pump() {
    const sb = this.sb;
    if (!sb || sb.updating || !this.queue.length) return;
    try { sb.appendBuffer(this.queue.shift()); } catch (_) { this.needKey = true; askKeyframe(); return; }
    const b = mse.buffered;
    if (b.length) {
      const end = b.end(b.length - 1);
      if (end - mse.currentTime > 0.2) mse.currentTime = Math.max(b.start(b.length - 1), end - 0.04);
      if (mse.currentTime - b.start(0) > 20 && !sb.updating) { try { sb.remove(0, mse.currentTime - 10); } catch (_) {} }
    }
    if (mse.paused) mse.play().catch(() => {});
  }
  close() {
    this.sb = null; this.queue = [];
    if (this.ms) { try { URL.revokeObjectURL(mse.src); } catch (_) {} this.ms = null; }
  }
}

function box(type, ...parts) {
  const body = cat(...parts), o = new Uint8Array(8 + body.length), d = new DataView(o.buffer);
  d.setUint32(0, o.length); o.set(enc.encode(type), 4); o.set(body, 8); return o;
}
const u8 = (...v) => new Uint8Array(v);
const u16 = (v) => u8(v >> 8 & 255, v & 255);
const u32 = (v) => be32(v >>> 0);
const zeros = (n) => new Uint8Array(n);
const MATRIX = cat(u32(0x10000), u32(0), u32(0), u32(0), u32(0x10000), u32(0), u32(0), u32(0), u32(0x40000000));
function mp4Init(cfg) {
  const desc = unb64(cfg.description), w = cfg.width, h = cfg.height, hevc = /^(hvc1|hev1)/.test(cfg.codec);
  const avc1 = box(hevc ? "hvc1" : "avc1", zeros(6), u16(1), zeros(16), u16(w), u16(h), u32(0x480000), u32(0x480000), u32(0), u16(1),
    zeros(32), u16(0x18), u16(0xffff), box(hevc ? "hvcC" : "avcC", desc));
  const stbl = box("stbl", box("stsd", u32(0), u32(1), avc1), box("stts", u32(0), u32(0)), box("stsc", u32(0), u32(0)),
    box("stsz", u32(0), u32(0), u32(0)), box("stco", u32(0), u32(0)));
  const minf = box("minf", box("vmhd", u32(1), zeros(8)), box("dinf", box("dref", u32(0), u32(1), box("url ", u32(1)))), stbl);
  const mdia = box("mdia", box("mdhd", u32(0), u32(0), u32(0), u32(90000), u32(0), u16(0x55c4), u16(0)),
    box("hdlr", u32(0), u32(0), enc.encode("vide"), zeros(12), enc.encode("LoopCtrl\0")), minf);
  const trak = box("trak", box("tkhd", u32(3), u32(0), u32(0), u32(1), u32(0), u32(0), zeros(8), u16(0), u16(0), u16(0), u16(0),
    MATRIX, u32(w << 16), u32(h << 16)), mdia);
  const moov = box("moov", box("mvhd", u32(0), u32(0), u32(0), u32(1000), u32(0), u32(0x10000), u16(0x100), zeros(10), MATRIX, zeros(24), u32(2)),
    trak, box("mvex", box("trex", u32(0), u32(1), u32(1), u32(0), u32(0), u32(0))));
  return cat(box("ftyp", enc.encode("isom"), u32(0x200), enc.encode("isomiso6avc1mp41")), moov);
}
function mp4Fragment(seq, time, keyframe, data) {
  const trun = (offset) => box("trun", u32(0x000701), u32(1), u32(offset), u32(1500), u32(data.length), u32(keyframe ? 0x02000000 : 0x01010000));
  const traf = (offset) => box("traf", box("tfhd", u32(0x020000), u32(1)), box("tfdt", u32(0x01000000), be64(time)), trun(offset));
  const size = box("moof", box("mfhd", u32(0), u32(seq)), traf(0)).length;
  return cat(box("moof", box("mfhd", u32(0), u32(seq)), traf(size + 8)), box("mdat", data));
}

function frameShown() {
  decoded++;
  if (!shownAt) { shownAt = performance.now(); setMessage(""); }
}

// The stream: framed messages, sealed when the page has WebCrypto.
let streamAbort = null, player = null, streamGen = 0;
// H.265 when this browser decodes it (and the user left the choice on Auto).
const HEVC_PROBE = "hvc1.1.6.L123.B0";
let hevcOK = null;
async function canHevc() {
  if (hevcOK !== null) return hevcOK;
  hevcOK = false;
  // Edge on Windows decoded the stream's H.265 into a wrong picture (see
  // checkGeometry). Auto stays on H.264 there; H.265 can still be chosen.
  if (/Windows/.test(navigator.userAgent)) return false;
  if (Date.now() - Number(prefs.get("hevcStalled") || 0) < 86400000) return false;
  try {
    if (CodecPlayer.ok()) hevcOK = (await VideoDecoder.isConfigSupported({ codec: HEVC_PROBE })).supported === true;
    if (!hevcOK && MsePlayer.ok()) hevcOK = (window.ManagedMediaSource || window.MediaSource).isTypeSupported('video/mp4; codecs="' + HEVC_PROBE + '"');
  } catch (_) {}
  return hevcOK;
}
async function wantedCodec() {
  const c = settings.codec;
  if (c === "h264") return "h264";
  if (c === "hevc") return "hevc";
  return (await canHevc()) ? "hevc" : "h264";
}
// What the page saw of the stream, for "Copy diagnostics" in the settings.
const diag = { events: [] };
function note(what, detail) {
  diag.events.push([new Date().toISOString().slice(11, 19), what, detail]);
  if (diag.events.length > 80) diag.events.shift();
}
// A decoder that hangs again and again on H.265 (some browsers' hardware
// decoders do): with the codec on Auto, use H.264 in this browser for a day.
let stalls = [];
function decoderStalled(codec) {
  const now = performance.now();
  note("decoder stalled", codec);
  stalls = stalls.filter((at) => now - at < 60000).concat(now);
  if (stalls.length < 2) return;
  stalls = [];
  dropHevc(codec, "hevcFallback");
}
function dropHevc(codec, message) {
  if (!/^(hvc1|hev1)/.test(codec || "") || settings.codec !== "auto") return;
  hevcOK = false;
  prefs.set("hevcStalled", String(Date.now()));
  note("switched to H.264", message);
  snack(t(message));
  if (player) player.close();
  player = null;
  runStream();
}
// A decoded frame whose size isn't what the phone sent: the decoder read the
// stream wrong (seen with H.265 in Edge on Windows: the top half of the
// screen stretched over all of it). Three in a row on H.265: use H.264.
let geometryOff = 0;
function checkGeometry(f, size, codec) {
  const vr = f.visibleRect || { x: 0, y: 0, width: f.displayWidth, height: f.displayHeight };
  const near = (a, b) => Math.abs(a - b) <= 16;
  const ok = near(vr.width, size.w) && near(vr.height, size.h) && near(f.displayWidth, size.w) && near(f.displayHeight, size.h);
  diag.frame = { codec, sent: [size.w, size.h], coded: [f.codedWidth, f.codedHeight],
                 visible: [vr.x, vr.y, vr.width, vr.height], display: [f.displayWidth, f.displayHeight] };
  if (ok) { geometryOff = 0; return; }
  if (geometryOff++ === 0) note("frame size differs", JSON.stringify(diag.frame));
  if (geometryOff === 3) dropHevc(codec, "hevcGeometry");
}
// Acknowledgements: the newest frame received, a few times a second, with
// how much later than the quickest frame lately it arrived. That difference
// is the queue on the way here, whatever the clocks say and however slow the
// acknowledgement's own trip, so the phone can keep it short.
let viewerId = "", newestTs = 0, ackedTs = 0, acksInFlight = 0, queueMs = 0, keyWanted = false;
let arrivals = [];   // [local ms, arrival minus frame ts]
function noteArrival(ts) {
  const now = performance.timeOrigin + performance.now(), lag = now - ts / 1000;
  arrivals.push([now, lag]);
  while (arrivals.length && now - arrivals[0][0] > 10000) arrivals.shift();
  let base = lag;
  for (const a of arrivals) if (a[1] < base) base = a[1];
  queueMs = lag - base;
  newestTs = ts;
}
// Not waiting for the answer: it comes back up the same link as the video,
// so on a congested link it would arrive late exactly when it matters most.
async function sendAck() {
  if (!viewerId || acksInFlight >= 4 || (newestTs <= ackedTs && !keyWanted) || !key) return;
  const ts = newestTs, params = { viewer: viewerId, ts, queue_ms: Math.round(queueMs) };
  if (keyWanted) params.key = true;
  ackedTs = ts; keyWanted = false;
  acksInFlight++;
  try { await rpc("stream_ack", params); } catch (_) { if (params.key) keyWanted = true; }
  acksInFlight--;
}
setInterval(sendAck, 150);
// The decoder dropped frames or failed and shows nothing new until a
// keyframe: say so now. The phone makes keyframes only when asked or when the
// screen changes, so on a still screen nobody else would.
function askKeyframe() { keyWanted = true; sendAck(); }
// The phone sends at least its state every few seconds, even on a still
// screen: a stream silent for longer (or one that never got going) died
// quietly, in a relay or network drop the browser didn't notice. Start anew.
let lastMessageAt = 0;
setInterval(() => {
  if (streamAbort && lastMessageAt && performance.now() - lastMessageAt > 10000 && !document.hidden) {
    lastMessageAt = 0;
    note("watchdog", "nothing for 10 s: reconnecting");
    if (apiBase) dropDirect("silent for 10 s"); else runStream();
  }
}, 2000);
// The picture, end to end. Frames that arrive and never reach the screen (a
// decoder or media element that stopped without an error) get a new player;
// an action that brings no new frame asks the phone for one, which also has
// it restart an encoder that died; and if even that brings nothing, a new
// stream. Whatever broke, the picture comes back without a reload.
let framesIn = 0, lastFrameAt = 0, lastConfig = null;
let seenIn = 0, seenShown = 0, stuckSince = 0, resets = [];
setInterval(() => {
  if (!player || !player.presented || !streamAbort || document.hidden) { stuckSince = 0; return; }
  const shown = player.presented(), now = performance.now();
  if (framesIn !== seenIn && shown === seenShown) stuckSince = stuckSince || now;
  else stuckSince = 0;
  seenIn = framesIn; seenShown = shown;
  if (!stuckSince || now - stuckSince < 3000) return;
  stuckSince = 0;
  resets = resets.filter((at) => now - at < 30000).concat(now);
  if (resets.length > 2) { note("picture stuck", "again: new stream"); resets = []; runStream(); return; }
  note("picture stuck", "frames arrive, none shown: new player");
  if (player) player.close();
  player = null;
  if (lastConfig) onConfig(lastConfig).catch((e) => note("player", e.message || String(e)));
  askKeyframe();
}, 1000);
let frameProbe = 0;
function expectFrame() {
  const since = framesIn;
  clearTimeout(frameProbe);
  frameProbe = setTimeout(() => {
    if (framesIn !== since || !streamAbort || state.paused) return;
    note("no frame after an action", "asking for one");
    askKeyframe();
    frameProbe = setTimeout(() => {
      if (framesIn !== since || !streamAbort || state.paused) return;
      note("still no frame", "new stream");
      runStream();
    }, 4000);
  }, 1500);
}
// Try the phone's LAN addresses (from its state) when this page came through
// the relay; every 20 s at most, and not again while one works.
let lanEndpoints = [], lanTryAt = 0, lanTrying = false;
async function tryDirect() {
  if (!relayed || apiBase || lanTrying || !key || !lanEndpoints.length || performance.now() < lanTryAt) return;
  lanTrying = true;
  // Soon again: the first try may have been waiting on the browser's prompt.
  lanTryAt = performance.now() + 20000;
  try {
    for (const ep of lanEndpoints) {
      const base = "http://" + ep + "/";
      try {
        const t0 = performance.now();
        // Answered under this page's key: it is this phone, not some other
        // device at the same address.
        await Promise.race([rpc("device_info", {}, true, base),
          new Promise((_, no) => setTimeout(() => no(new Error("timeout")), 3000))]);
        apiBase = base;
        note("direct", ep + " (" + Math.round(performance.now() - t0) + " ms)");
        renderSub();
        runStream();
        return;
      } catch (e) { note("direct unavailable", ep + ": " + (e.message || e)); }
    }
  } finally { lanTrying = false; }
}
function dropDirect(why) {
  if (!apiBase) return;
  note("back to the relay", why);
  apiBase = "";
  lanTryAt = performance.now() + 60000;
  renderSub();
  runStream();
}

async function runStream() {
  const gen = ++streamGen;
  if (streamAbort) streamAbort.abort();
  const abort = new AbortController();
  streamAbort = abort;
  let backoff = 1000;
  while (gen === streamGen) {
    try {
      lastMessageAt = performance.now();   // the watchdog covers getting started, too
      note("stream connecting", settings.quality);
      const ticket = (await rpc("stream_ticket")).ticket;
      if (gen !== streamGen) return;   // a newer attempt started while this one waited
      const quality = settings.quality;
      const encrypted = !!SUBTLE;
      const codec = await wantedCodec();
      const base = apiBase;
      const r = await fetch(base + "stream?ticket=" + encodeURIComponent(ticket) + "&quality=" + quality + "&codec=" + codec + "&ack=1" +
        (encrypted ? "&enc=1" : ""), { signal: abort.signal, cache: "no-store", ...via(base) });
      if (!r.ok || !r.body) throw new Error("HTTP " + r.status);
      lastMessageAt = performance.now();
      setLink(true);
      note("stream open", codec + (encrypted ? ", encrypted" : ""));
      await readStream(r.body.getReader(), gen);
      note("stream ended", "");
      backoff = 1000;
    } catch (e) {
      if (gen !== streamGen) return;
      if (e instanceof AuthError) return needPair();
      note("stream error", (e && e.message) || String(e));
      if (apiBase) { dropDirect("stream: " + ((e && e.message) || e)); continue; }
      setLink(false);
      setMessage(t("noVideo", e.message || e), false);
    }
    if (gen !== streamGen) return;
    await new Promise((res) => setTimeout(res, backoff));
    backoff = Math.min(backoff * 2, 8000);
  }
}

async function readStream(reader, gen) {
  let buf = new Uint8Array(0), aes = null, counter = 0;
  shownAt = 0;
  setMessage(t("waitingFrame"));
  for (;;) {
    const { value, done } = await reader.read();
    if (done || gen !== streamGen) return;
    lastMessageAt = performance.now();
    buf = buf.length ? cat(buf, value) : value;
    let off = 0;
    while (buf.length - off >= 5) {
      const len = new DataView(buf.buffer, buf.byteOffset + off, 4).getUint32(0);
      if (buf.length - off < 4 + len) break;
      const type = buf[off + 4];
      let payload = buf.slice(off + 5, off + 4 + len);
      off += 4 + len;
      if (type === 0) {
        const hello = JSON.parse(dec.decode(payload));
        viewerId = hello.viewer || ""; newestTs = 0; ackedTs = 0; arrivals = []; queueMs = 0;
        if (hello.enc === "aes-256-gcm") {
          const k = hmac(key, cat(enc.encode("loopctrl-stream-v1"), unhex(hello.salt)));
          aes = await SUBTLE.importKey("raw", k, "AES-GCM", false, ["decrypt"]);
        }
        continue;
      }
      if (aes) {
        const iv = cat(zeros(4), be64(counter++));
        payload = new Uint8Array(await SUBTLE.decrypt({ name: "AES-GCM", iv, additionalData: u8(type) }, aes, payload));
      }
      if (type === 1) await onConfig(JSON.parse(dec.decode(payload)));
      else if (type === 3) onState(JSON.parse(dec.decode(payload)));
      else if (type === 2 && player) {
        const view = new DataView(payload.buffer, payload.byteOffset);
        const ts = view.getUint32(1) * 4294967296 + view.getUint32(5);
        noteArrival(ts);
        framesIn++; lastFrameAt = performance.now();
        player.frame((payload[0] & 1) === 1, ts, payload.subarray(9));
      }
    }
    buf = off ? buf.slice(off) : buf;
  }
}

async function onConfig(cfg) {
  note("config", cfg.codec + " " + cfg.width + "x" + cfg.height);
  lastConfig = cfg;
  if (cfg.point_width) points = { w: cfg.point_width, h: cfg.point_height };
  codecName = /^(hvc1|hev1)/.test(cfg.codec || "") ? "H.265" : "H.264";
  screenEl.style.setProperty("--ar", cfg.width / cfg.height);
  if (!player) player = CodecPlayer.ok() ? new CodecPlayer() : MsePlayer.ok() ? new MsePlayer() : null;
  if (!player) throw new Error("this browser can't play the stream");
  try { await player.configure(cfg); }
  catch (e) {
    if (player instanceof CodecPlayer && MsePlayer.ok()) { player = new MsePlayer(); await player.configure(cfg); }
    else throw e;
  }
  sizeOverlay();
}

function stopStream() {
  streamGen++;
  if (streamAbort) streamAbort.abort();
  streamAbort = null;
}


// ───────────────────────────── ui helpers ─────────────────────────────
function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") e.className = v; else if (k === "text") e.textContent = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v); else e.setAttribute(k, v);
  }
  for (const k of kids) if (k) e.append(k);
  return e;
}
let snackTimer = 0;
// One snackbar at a time; an action button when there is something to do.
function snack(text, action, sticky = false) {
  document.querySelector(".snack:not(.leaving)")?.remove();
  clearTimeout(snackTimer);
  const s = el("div", { class: "snack", role: "status" }, el("span", { text }));
  if (action) s.append(el("button", { class: "btn text", text: action[0], onclick: () => { leave(s, "leaving"); action[1](); } }));
  document.body.append(s);
  if (!sticky) snackTimer = setTimeout(() => leave(s, "leaving"), 4000);
  return s;
}
// Play an element's way out (a class with an animation), then remove it —
// or just hide it, for panels that stay in the page.
function leave(node, cls, hideOnly = false) {
  if (!node || !node.isConnected || node.classList.contains(cls)) return;
  node.classList.add(cls);
  let done = false;
  const finish = () => {
    if (done) return;
    done = true;
    node.classList.remove(cls);
    if (hideOnly) hideOnly(); else node.remove();
  };
  node.addEventListener("animationend", (e) => { if (e.target === node) finish(); });
  setTimeout(finish, 400);   // no animation (reduced motion, hidden): still go
}
// A miuix dialog (centred) or bottom sheet; resolves with the button's value.
function modal({ title, body = [], buttons = [], sheet = false }) {
  return new Promise((resolve) => {
    const box = el("div", { class: sheet ? "sheet" : "dialog" });
    const scrim = el("div", { class: "scrim" + (sheet ? " bottom" : "") }, box);
    let closed = false;
    const close = (v) => {
      if (closed) return;
      closed = true;
      resolve(v);
      leave(scrim, "closing");
    };
    scrim.addEventListener("click", (e) => { if (e.target === scrim) close(null); });
    if (sheet) box.append(el("div", { class: "handle" }));
    if (title) box.append(el("h3", { text: title }));
    for (const b of body) box.append(typeof b === "function" ? b(close) : b);
    if (buttons.length) box.append(el("div", { class: "btnrow" }, ...buttons.map(([label, value, primary]) =>
      el("button", { class: "btn" + (primary ? " primary" : ""), text: label, onclick: () => close(value) }))));
    document.body.append(scrim);
    box.querySelector("input")?.focus();
  });
}
function segmented(options, current, onPick) {
  const seg = el("div", { class: "seg" });
  seg.style.setProperty("--n", options.length);
  seg.style.setProperty("--i", Math.max(0, options.findIndex(([v]) => v === current)));
  options.forEach(([value, label], i) => {
    const b = el("button", { text: label, "aria-pressed": String(value === current) });
    b.addEventListener("click", () => {
      for (const o of seg.children) o.setAttribute("aria-pressed", String(o === b));
      seg.style.setProperty("--i", i);   // the highlight slides over
      onPick(value);
    });
    seg.append(b);
  });
  return seg;
}

// ───────────────────────────── motion ─────────────────────────────
// A ripple from the press point on every control, and the tool's own
// gesture on its icon when it runs.
const RIPPLED = ".iconbtn, .btn, .pill, .comp, .dev, .person .top, .node, .seg button, .titles";
document.addEventListener("pointerdown", (ev) => {
  const target = ev.target.closest && ev.target.closest(RIPPLED);
  if (!target || target.disabled || (ev.pointerType === "mouse" && ev.button !== 0)) return;
  const r = target.getBoundingClientRect(), size = Math.hypot(r.width, r.height) * 2;
  target.classList.add("rippling");
  const dot = el("span", { class: "ripple" });
  Object.assign(dot.style, { width: size + "px", height: size + "px",
    left: (ev.clientX - r.left - size / 2) + "px", top: (ev.clientY - r.top - size / 2) + "px" });
  dot.addEventListener("animationend", () => dot.remove());
  target.append(dot);
}, true);
document.addEventListener("click", (ev) => {
  const b = ev.target.closest && ev.target.closest(".iconbtn");
  if (!b) return;
  b.classList.remove("pop");
  void b.offsetWidth;   // restart the animation on a quick second press
  b.classList.add("pop");
}, true);
document.addEventListener("animationend", (ev) => {
  const b = ev.target.closest && ev.target.closest(".iconbtn.pop");
  if (b && ev.target.tagName.toLowerCase() === "svg") b.classList.remove("pop");
});
function bump(node) {
  if (!node) return;
  node.classList.remove("bump");
  void node.offsetWidth;
  node.classList.add("bump");
}

// ───────────────────────────── overlay ─────────────────────────────
let trails = [], ripple = null, hot = null, wireManual = false, hiddenScreen = false, nodes = [], trailFade = 0;
const easeOut = (x) => 1 - Math.pow(1 - Math.min(Math.max(x, 0), 1), 3);
const wireOn = () => wireManual || hiddenScreen;
function sizeOverlay() {
  const r = overlay.getBoundingClientRect(), dpr = devicePixelRatio || 1;
  overlay.width = Math.round(r.width * dpr); overlay.height = Math.round(r.height * dpr);
  draw();
}
// One frame at a time. A frame asked for while the tab was hidden may never
// come; after half a second without it, ask again rather than stay stuck.
let drawQueued = 0;
function draw() {
  if (drawQueued && performance.now() - drawQueued < 500) return;
  drawQueued = performance.now();
  requestAnimationFrame(() => {
    drawQueued = 0;
    const W2 = overlay.width, H2 = overlay.height;
    octx.clearRect(0, 0, W2, H2);
    if (!points.w) return;
    const sx = W2 / points.w, sy = H2 / points.h, dpr = devicePixelRatio || 1;
    if (wireOn()) {
      octx.lineWidth = dpr; octx.font = (10 * dpr) + "px -apple-system, system-ui, sans-serif";
      for (const n of nodes) {
        if (n.w <= 0 || n.h <= 0) continue;
        octx.strokeStyle = n.label ? "rgba(52,130,255,.9)" : "rgba(255,255,255,.22)";
        octx.strokeRect(n.x * sx, n.y * sy, n.w * sx, n.h * sy);
        if (n.label && n.h * sy > 12 * dpr) {
          octx.fillStyle = "rgba(255,255,255,.92)";
          octx.fillText(n.label.slice(0, 40), n.x * sx + 3 * dpr, n.y * sy + 11 * dpr, Math.max(0, n.w * sx - 6 * dpr));
        }
      }
    }
    if (hot) {
      octx.fillStyle = "rgba(52,130,255,.18)"; octx.strokeStyle = "#3482ff"; octx.lineWidth = 2 * dpr;
      octx.fillRect(hot.x * sx, hot.y * sy, hot.w * sx, hot.h * sy);
      octx.strokeRect(hot.x * sx, hot.y * sy, hot.w * sx, hot.h * sy);
    }
    const now = performance.now();
    let again = false;
    octx.lineCap = "round"; octx.lineJoin = "round";
    // Drag paths, fading out once the fingers lift.
    const trailAlpha = trailFade ? 1 - (now - trailFade) / 300 : 1;
    if (trailFade && trailAlpha <= 0) { trails = []; trailFade = 0; }
    for (const trail of trails) {
      if (trail.length < 2) continue;
      octx.strokeStyle = "rgba(255,255,255," + (0.7 * trailAlpha) + ")"; octx.lineWidth = 6 * dpr;
      octx.beginPath(); octx.moveTo(trail[0].x * sx, trail[0].y * sy);
      for (const p of trail) octx.lineTo(p.x * sx, p.y * sy);
      octx.stroke();
      const end = trail[trail.length - 1];
      octx.fillStyle = "rgba(255,255,255," + (0.85 * trailAlpha) + ")";
      octx.beginPath(); octx.arc(end.x * sx, end.y * sy, 5 * dpr, 0, Math.PI * 2); octx.fill();
    }
    if (trailFade) again = true;
    // A finger on the screen: a soft spot at once, and for one that stays
    // put a ring that fills toward the long press (full at 0.5 s).
    for (const f of fingers.values()) {
      if (f.up) continue;
      const p = f.path[f.path.length - 1], held = (now - f.down) / 1000;
      const grow = easeOut(held / 0.12);
      octx.fillStyle = "rgba(255,255,255," + (0.28 * grow) + ")";
      octx.beginPath(); octx.arc(p.x * sx, p.y * sy, (8 + 8 * grow) * dpr, 0, Math.PI * 2); octx.fill();
      if (!f.moved && fingers.size === 1 && held > 0.15) {
        const k = Math.min((held - 0.15) / 0.35, 1);
        octx.strokeStyle = k >= 1 ? "rgba(52,130,255,.95)" : "rgba(255,255,255,.85)";
        octx.lineWidth = 3 * dpr;
        octx.beginPath();
        octx.arc(p.x * sx, p.y * sy, 22 * dpr, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * easeOut(k));
        octx.stroke();
      }
      again = true;
    }
    // The tap itself: a filled circle and a ring spreading out, fading.
    if (ripple) {
      const age = (now - ripple.at) / 450;
      if (age < 1) {
        const e = easeOut(age);
        octx.fillStyle = "rgba(255,255,255," + (0.3 * (1 - age)) + ")";
        octx.beginPath(); octx.arc(ripple.x * sx, ripple.y * sy, (12 + 14 * e) * dpr, 0, Math.PI * 2); octx.fill();
        octx.strokeStyle = "rgba(255,255,255," + (0.85 * (1 - age)) + ")"; octx.lineWidth = 2.5 * dpr;
        octx.beginPath(); octx.arc(ripple.x * sx, ripple.y * sy, (12 + 30 * e) * dpr, 0, Math.PI * 2); octx.stroke();
        again = true;
      } else ripple = null;
    }
    if (again) draw();
  });
}

// ───────────────────────────── actions ─────────────────────────────
// Actions run one after another; a backlog is dropped rather than replayed
// late. A touch whose outcome is unknown is never sent again.
const actions = [];
let acting = false;
const LABELS = { tap: ["Tap", "点按"], long_press: ["Long press", "长按"], gesture: ["Gesture", "手势"], drag: ["Swipe", "滑动"],
  type: ["Typing", "输入"], home: ["Home", "主屏幕"], lock: ["Lock", "锁屏"], unlock: ["Wake", "唤醒"], launch_app: ["Opening the app", "打开 App"],
  rotate: ["Rotate", "旋转屏幕"], app_switcher: ["App switcher", "多任务"],
  notification_center: ["Notification Center", "通知中心"], control_center: ["Control Center", "控制中心"], double_tap: ["Double tap", "双击"], swipe: ["Swipe", "滑动"],
  scroll: ["Scroll", "滚动"], clear_text: ["Clear text", "清空文本"], activate_app: ["Switching app", "切换 App"],
  terminate_app: ["Closing the app", "关闭 App"], open_url: ["Opening a link", "打开链接"], tap_element: ["Tap", "点按"], find_and_tap: ["Tap", "点按"] };
const label = (m) => (LABELS[m] || [m, m])[zh ? 1 : 0];
function act(method, params = {}) {
  if (actions.length > 6) actions.length = 0;
  actions.push([method, params]);
  record(method, params);
  pumpActions();
}
async function pumpActions() {
  if (acting) return;
  acting = true;
  while (actions.length) {
    const [method, params] = actions.shift();
    try { await rpc(method, params); expectFrame(); }
    catch (e) { if (!actionFailed(method, e)) break; }
    if (treeOpen() || wireOn()) scheduleTree(500);
  }
  acting = false;
}
// What to tell the person, and whether the queue may go on.
function actionFailed(method, e) {
  if (e instanceof AuthError) { actions.length = 0; needPair(); return false; }
  const d = (e && e.data) || {};
  if (d.code === "paused_by_owner") { actions.length = 0; onState({ ...state, paused: true }); return false; }
  if (d.outcome === "unknown" || d.outcome === "queued" || !e.code) {
    // A dropped connection or a late reply: it may have landed. Stop, don't resend.
    actions.length = 0;
    snack(t("unknownOutcome", label(method)));
    return false;
  }
  snack(t("failedAction", label(method), (e.message || "").slice(0, 120)));
  return true;
}

// ───────────────────────────── control ─────────────────────────────
// Anyone paired may operate; the pill says how many watch and operate, and
// opens everyone's own log of actions.
let state = { paused: false, people: [], hidden: false, source: "" };
let pageVersion = 0;
function onState(s) {
  const was = state;
  // A newer page was pushed to the phone (page_update): offer it.
  if (s.page) {
    if (!pageVersion) pageVersion = s.page;
    else if (s.page !== pageVersion) { pageVersion = s.page; snack(t("pageUpdated"), [t("reload"), () => location.reload()], true); }
  }
  state = { paused: !!s.paused, people: Array.isArray(s.people) ? s.people : [], hidden: !!s.hidden, source: s.source || "" };
  if (state.source !== was.source) { if (was.source) note("source", state.source); renderSub(); }
  lanEndpoints = Array.isArray(s.lan) ? s.lan.filter((e) => typeof e === "string") : [];
  if (apiBase && !lanEndpoints.some((e) => apiBase === "http://" + e + "/")) dropDirect("the phone left the LAN");
  else tryDirect();
  hiddenScreen = state.hidden && !state.paused;
  $("paused-msg").hidden = !state.paused;
  $("paused-msg").querySelector("span").textContent = t("paused");
  $("paused-msg").querySelector("span").style.whiteSpace = "pre-line";
  $("hidden-tag").hidden = !hiddenScreen;
  $("hidden-tag").textContent = t("hiddenTag");
  renderPeople();
  if (peopleView) peopleView();
  // The phone repeats its state every few seconds: read the tree again only
  // when the outlines just came on or the pause just ended.
  if (wireOn() && !state.paused && (was.paused || was.hidden !== state.hidden)) loadTree();
  draw();
}
function renderPeople() {
  const pill = $("people"), long = pill.querySelector(".long"), short = pill.querySelector(".short");
  pill.className = "pill";
  if (state.paused) {
    pill.hidden = false; pill.classList.add("other");
    long.textContent = t("pausedPill"); short.replaceChildren(PAUSE_ICON.cloneNode(true));
    return;
  }
  const ops = state.people.filter((p) => p.operating), watching = state.people.filter((p) => p.watching).length;
  pill.hidden = !state.people.length;
  const text = [ops.length && t("operatingN", ops.length), watching && t("watchingN", watching)].filter(Boolean).join(" · ");
  if (text !== long.textContent && long.textContent) bump(pill);
  pill.title = long.textContent = text;
  // Narrow screens: an icon and a count each.
  short.replaceChildren(...(ops.length ? [HAND_ICON.cloneNode(true), String(ops.length)] : []),
                        ...(watching ? [EYE_ICON.cloneNode(true), String(watching)] : []));
  if (ops.some((p) => p.tok !== tok)) pill.classList.add("other");
  else if (ops.length) pill.classList.add("mine");
}
const icon = (d) => { const e = document.createElementNS("http://www.w3.org/2000/svg", "svg"); e.setAttribute("viewBox", "0 0 24 24"); e.innerHTML = d; return e; };
const EYE_ICON = icon('<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>');
const HAND_ICON = icon('<path d="M9 11V5.5a1.5 1.5 0 0 1 3 0V11M12 10V4.5a1.5 1.5 0 0 1 3 0V11M15 10.5V6.5a1.5 1.5 0 0 1 3 0V15a6 6 0 0 1-6 6h-.5a6 6 0 0 1-4.8-2.4L4 14.5a1.5 1.5 0 0 1 2.3-1.9L9 15V8.5a1.5 1.5 0 0 0-3 0"/>');
const PAUSE_ICON = icon('<circle cx="12" cy="12" r="9"/><path d="M10 9v6M14 9v6"/>');
let peopleView = null;
$("people").addEventListener("click", async () => {
  const list = el("div", { class: "people" }), open = new Set();
  let logs = [];
  const clock = (at) => new Date(at * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  const render = () => {
    const byTok = new Map(logs.map((l) => [l.tok, l.actions || []]));
    const rows = state.people.map((p) => ({ ...p }));
    for (const l of logs) if (!rows.some((p) => p.tok === l.tok)) rows.push({ tok: l.tok, name: l.name, kind: l.kind, gone: true });
    list.replaceChildren(...rows.map((p) => {
      const entries = byTok.get(p.tok) || [], name = p.tok === tok ? t("you") : p.name || p.tok;
      const box = el("div", { class: "person" }, el("div", { class: "top", onclick: () => {
        if (!open.delete(p.tok)) open.add(p.tok);
        render();
      } },
        el("div", { class: "avatar" + (p.kind === "agent" ? " agent" : ""), text: p.kind === "agent" ? "AI" : [...name][0].toUpperCase() }),
        el("div", { class: "t" },
          el("div", { class: "title" }, name, p.kind === "agent" && el("i", { class: "chip", text: t("agent") })),
          el("div", { class: "summary", text: t(p.gone ? "gone" : p.operating ? "operatingNow" : "watchingNow", Math.max(p.actions || 0, entries.length)) })),
        el("i", { class: "status-dot" + (p.operating ? " on" : "") })));
      if (open.has(p.tok)) box.append(el("div", { class: "log" }, ...(entries.length ? entries.slice().reverse().map((a) =>
        el("div", {}, el("time", { text: clock(a.at) }), el("span", { text: label(a.method) + (a.detail ? " " + a.detail : "") }),
           a.outcome !== "applied" && el("b", { class: a.outcome === "sent" ? "" : "bad", text: t("o_" + a.outcome) })))
        : [el("div", { class: "empty", text: t("noActions") })])));
      return box;
    }));
  };
  const load = async () => {
    try { logs = (await rpc("control", { action: "log", limit: 200 })).logs || []; render(); }
    catch (e) { if (e instanceof AuthError) needPair(); }
  };
  peopleView = render;
  render(); load();
  const timer = setInterval(load, 3000);
  await modal({ title: t("people"), sheet: true, body: [list], buttons: [[t("done"), null, true]] });
  clearInterval(timer);
  peopleView = null;
});

// ───────────────────────────── input ─────────────────────────────
function toPoint(ev) {
  const r = overlay.getBoundingClientRect();
  const x = Math.min(Math.max((ev.clientX - r.left) / r.width, 0), 1) * points.w;
  const y = Math.min(Math.max((ev.clientY - r.top) / r.height, 0), 1) * points.h;
  return { x: Math.round(x * 10) / 10, y: Math.round(y * 10) / 10 };
}
// Every finger on the screen, with its path. When the last one lifts: a tap
// or long press for one finger that stayed put, otherwise one gesture with
// each finger's real path (a curved drag, a pinch, a two-finger hold).
// Alt/Option while dragging with a mouse mirrors a second finger: a pinch.
const fingers = new Map();
let gestureStart = 0, pinch = false;
const since = () => Math.round((performance.now() - gestureStart)) / 1000;
overlay.addEventListener("pointerdown", (ev) => {
  if (!points.w || state.paused || (ev.button !== 0 && ev.pointerType === "mouse")) return;
  try { overlay.setPointerCapture(ev.pointerId); } catch (_) { /* a pointer the browser no longer tracks */ }
  if (!fingers.size) { gestureStart = performance.now(); pinch = ev.altKey && ev.pointerType === "mouse"; }
  const p = toPoint(ev);
  fingers.set(ev.pointerId, { path: [{ x: p.x, y: p.y, t: since() }], moved: false, px: ev.clientX, py: ev.clientY, down: performance.now(), up: false });
  trails = [...fingers.values()].map((f) => f.path);
  trailFade = 0;
  draw();
});
overlay.addEventListener("pointermove", (ev) => {
  const f = fingers.get(ev.pointerId);
  if (!f) { if (treeOpen() || wireOn()) hover(toPoint(ev)); return; }
  if (!f.moved && Math.hypot(ev.clientX - f.px, ev.clientY - f.py) > 6) f.moved = true;
  if (!f.moved) return;
  const p = toPoint(ev), tt = since(), last = f.path[f.path.length - 1];
  if (tt - last.t >= 0.012) f.path.push({ x: p.x, y: p.y, t: tt });
  if (pinch) trails = [f.path, mirror(f.path)];
  draw();
});
function lift(ev, cancelled) {
  const f = fingers.get(ev.pointerId);
  if (!f) return;
  if (cancelled) { fingers.clear(); trails = []; draw(); return; }
  const p = toPoint(ev);
  f.path.push({ x: p.x, y: p.y, t: Math.max(since(), f.path[f.path.length - 1].t + 0.01) });
  f.up = true;
  if ([...fingers.values()].every((g) => g.up)) finishGesture();
  if (ev.pointerType === "mouse") focusKeyboard();
}
overlay.addEventListener("pointerup", (ev) => lift(ev, false));
overlay.addEventListener("pointercancel", (ev) => lift(ev, true));
function mirror(path) {
  const o = path[0];
  return path.map((q) => ({ x: Math.min(Math.max(2 * o.x - q.x, 1), points.w - 1),
                           y: Math.min(Math.max(2 * o.y - q.y, 1), points.h - 1), t: q.t }));
}
function thin(path) {
  if (path.length <= 120) return path;
  const step = path.length / 119, out = [];
  for (let i = 0; i < 119; i++) out.push(path[Math.floor(i * step)]);
  out.push(path[path.length - 1]);
  return out;
}
function finishGesture() {
  const list = [...fingers.values()];
  fingers.clear();
  const single = list.length === 1 && !list[0].moved && !pinch;
  if (single) {
    const p = list[0].path[0], held = (performance.now() - list[0].down) / 1000;
    trails = [];
    ripple = { x: p.x, y: p.y, at: performance.now() };
    if (held >= 0.5) act("long_press", { x: p.x, y: p.y, duration: Math.min(held, 5), settle: false, manual: true });
    else act("tap", { x: p.x, y: p.y, settle: false, manual: true });
    draw();
    return;
  }
  let paths = list.map((f) => f.path);
  if (pinch && paths.length === 1) paths.push(mirror(paths[0]));
  act("gesture", { fingers: paths.map(thin), manual: true });
  trailFade = performance.now();
  draw();
}
overlay.addEventListener("contextmenu", (ev) => {
  ev.preventDefault();
  if (state.paused) return;
  const p = toPoint(ev);
  act("long_press", { x: p.x, y: p.y, duration: 1, settle: false, manual: true });
});
// Wheel and trackpad: gathered briefly, then one drag of that distance.
let wheel = null;
overlay.addEventListener("wheel", (ev) => {
  ev.preventDefault();
  if (!points.w || state.paused) return;
  const r = overlay.getBoundingClientRect(), scale = points.h / r.height;
  if (!wheel) {
    wheel = { at: toPoint(ev), dx: 0, dy: 0 };
    setTimeout(() => {
      const w = wheel; wheel = null;
      const dy = Math.max(-points.h * 0.6, Math.min(points.h * 0.6, -w.dy * scale));
      const dx = Math.max(-points.w * 0.6, Math.min(points.w * 0.6, -w.dx * scale));
      if (Math.abs(dx) < 4 && Math.abs(dy) < 4) return;
      const fx = Math.min(Math.max(w.at.x, 10), points.w - 10), fy = Math.min(Math.max(w.at.y - dy / 2, 10), points.h - 10);
      act("drag", { from_x: fx, from_y: fy, to_x: Math.min(Math.max(fx + dx, 1), points.w - 1),
                    to_y: Math.min(Math.max(fy + dy, 1), points.h - 1), duration: 0.25, settle: false, manual: true });
    }, 120);
  }
  wheel.dx += ev.deltaX; wheel.dy += ev.deltaY * (ev.deltaMode === 1 ? 16 : 1);
}, { passive: false });

// Typing: a hidden field takes the keys (and the input method's composed
// text), and they go to the phone in short batches.
const kbd = $("kbd");
let composing = false, typed = "", typeTimer = 0, keyboardOn = false;
const desktop = matchMedia("(pointer: fine)").matches;
function focusKeyboard() { if (desktop || keyboardOn) kbd.focus({ preventScroll: true }); }
function flushTyping() {
  clearTimeout(typeTimer);
  if (!typed) return;
  const text = typed; typed = "";
  act("type", { text, fast: true, settle: false, manual: true });
}
function typeText(s) { typed += s; clearTimeout(typeTimer); typeTimer = setTimeout(flushTyping, 90); }
kbd.addEventListener("compositionstart", () => { composing = true; });
kbd.addEventListener("compositionend", (ev) => { composing = false; if (ev.data) typeText(ev.data); kbd.value = ""; });
kbd.addEventListener("input", (ev) => {
  if (composing || ev.isComposing) return;
  if (ev.inputType === "insertText" && ev.data) typeText(ev.data);
  else if (ev.inputType === "insertLineBreak") typeText("\n");
  kbd.value = "";
});
kbd.addEventListener("keydown", (ev) => {
  if (composing || ev.isComposing || ev.keyCode === 229) return;
  if (ev.key === "Backspace") { ev.preventDefault(); typeText("\b"); }
  else if (ev.key === "Enter") { ev.preventDefault(); typeText("\n"); }
  else if (ev.key === "Tab") { ev.preventDefault(); typeText("\t"); }
});
kbd.addEventListener("paste", (ev) => {
  const s = ev.clipboardData && ev.clipboardData.getData("text");
  if (s) { ev.preventDefault(); typeText(s); }
});

async function openApp() {
  const input = el("input", { class: "keyfield", type: "text", placeholder: t("appPrompt"), autocomplete: "off", spellcheck: "false" });
  input.style.fontFamily = "var(--font)";
  const name = await modal({ title: t("app"), body: [(close) => {
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") close(input.value); });
    return input;
  }], buttons: [[t("close"), null], [t("app"), "go", true]] }).then((v) => v === "go" ? input.value : v);
  if (!name || !name.trim()) return;
  try {
    const found = await rpc("resolve_app", { text: name.trim(), distance: 3 });
    const app = (found.apps || []).find((a) => a.installed_here !== false) || (found.apps || [])[0];
    if (!app) return snack(t("notFound", name));
    act("launch_app", { bundle_id: app.bundle_id });
  } catch (e) { if (e instanceof AuthError) needPair(); else snack(e.message); }
}
for (const b of document.querySelectorAll("[data-act]")) {
  b.addEventListener("click", () => {
    switch (b.dataset.act) {
      case "home": act("home", { manual: true }); break;
      case "switcher": act("app_switcher", { manual: true }); break;
      case "rotate": act("rotate", { manual: true }); break;
      case "notifications": act("notification_center", { manual: true }); break;
      case "controls": act("control_center", { manual: true }); break;
      // No lock / wake buttons: locking the phone suspends the app that holds
      // the relay tunnel (the page simply loses the phone), and waking it is a
      // Home press that cannot get past a passcode. Both stay available to
      // agents over RPC, where screen_locked says what actually happened.
      case "app": openApp(); break;
      case "keyboard":
        keyboardOn = !keyboardOn; b.classList.toggle("on", keyboardOn);
        if (keyboardOn) kbd.focus({ preventScroll: true }); else kbd.blur();
        break;
      case "wire":
        wireManual = !wireManual; b.classList.toggle("on", wireManual);
        if (wireOn()) loadTree(); else draw();
        break;
    }
  });
}

// ───────────────────────────── view tree ─────────────────────────────
const LINE = /^( *)([A-Za-z0-9]+)(?:, label: '(.*?)')?(?:, value: '(.*?)')?(?:, id: '(.*?)')?, \{\{(-?\d+), (-?\d+)\}, \{(-?\d+), (-?\d+)\}\}/;
function parseTree(src) {
  const out = [];
  for (const line of src.split("\n")) {
    const m = LINE.exec(line);
    if (!m) continue;
    out.push({ depth: m[1].length / 2, type: m[2], label: m[3] || "", value: m[4] || "", id: m[5] || "",
               x: +m[6], y: +m[7], w: +m[8], h: +m[9] });
  }
  return out;
}
const treeOpen = () => !$("tree-panel").hidden;
let treeTimer = 0, treeBusy = false;
function scheduleTree(ms) { clearTimeout(treeTimer); treeTimer = setTimeout(loadTree, ms); }
async function loadTree() {
  if (state.paused) return;
  if (treeBusy) return scheduleTree(400);
  treeBusy = true;
  try {
    const r = await rpc("page_source", { visible_only: true });
    nodes = parseTree(r.source || "");
    renderTree();
    $("tree-foot").textContent = t("nodes", nodes.length);
  } catch (e) {
    if (e instanceof AuthError) { treeBusy = false; return needPair(); }
    $("tree-foot").textContent = t("treeErr", e.message);
  }
  treeBusy = false;
  draw();
  if (wireOn()) scheduleTree(hiddenScreen ? 1500 : 2500);
}
function renderTree() {
  const list = $("tree"), q = $("tree-filter").value.trim().toLowerCase();
  list.textContent = "";
  const frag = document.createDocumentFragment();
  nodes.forEach((n, i) => {
    const text = n.label || n.value || n.id;
    if (q && !(text + " " + n.type).toLowerCase().includes(q)) return;
    const row = el("div", { class: "node" + (text ? "" : " empty") },
      el("div", { class: "t" }, el("b", { text: text || n.type }), el("span", { text: text ? n.type : n.w + "×" + n.h })));
    row.style.paddingLeft = (16 + Math.min(n.depth, 24) * 10) + "px";
    row.dataset.i = i;
    frag.append(row);
  });
  list.append(frag);
}
$("tree").addEventListener("mouseover", (ev) => {
  const row = ev.target.closest(".node");
  hot = row ? nodes[+row.dataset.i] : null; draw();
});
$("tree").addEventListener("mouseleave", () => { hot = null; draw(); });
$("tree").addEventListener("click", (ev) => {
  const row = ev.target.closest(".node");
  if (!row) return;
  const n = nodes[+row.dataset.i];
  if (n.w <= 0 || n.h <= 0) return;
  const x = n.x + n.w / 2, y = n.y + n.h / 2;
  ripple = { x, y, at: performance.now() }; draw();
  act("tap", { x, y, settle: false, manual: true });
});
$("tree-filter").addEventListener("input", renderTree);
$("tree-refresh").addEventListener("click", loadTree);
// Under the pointer: the smallest element containing it.
function hover(p) {
  let best = null;
  for (const n of nodes) {
    if (n.w <= 0 || n.h <= 0 || p.x < n.x || p.y < n.y || p.x > n.x + n.w || p.y > n.y + n.h) continue;
    if (!best || n.w * n.h <= best.w * best.h) best = n;
  }
  if (best === hot) return;
  hot = best; draw();
  for (const e of document.querySelectorAll(".node.hot")) e.classList.remove("hot");
  if (best) {
    const row = document.querySelector('.node[data-i="' + nodes.indexOf(best) + '"]');
    if (row) { row.classList.add("hot"); row.scrollIntoView({ block: "nearest" }); }
  }
}
overlay.addEventListener("pointerleave", () => { if (!fingers.size) { hot = null; draw(); } });
function setTree(open) {
  const panel = $("tree-panel");
  // In a drawer or sheet it slides away; beside the screen it just goes.
  if (!open && !panel.hidden && getComputedStyle(panel).position === "fixed") {
    leave(panel, "closing", () => { panel.hidden = true; setTimeout(sizeOverlay, 0); });
    $("btn-tree").classList.remove("on");
    hot = null; draw();
    return;
  }
  panel.hidden = !open;
  $("btn-tree").classList.toggle("on", open);
  if (open) loadTree(); else { hot = null; draw(); }
  setTimeout(sizeOverlay, 0);
}
$("btn-tree").addEventListener("click", () => setTree(!treeOpen()));
$("tree-close").addEventListener("click", () => setTree(false));

// ───────────────────────────── settings ─────────────────────────────
for (const b of document.querySelectorAll(".rail [data-tip], .topbar .iconbtn[data-tip]")) {
  b.classList.add("labeled");
  b.append(el("span", { class: "lbl", text: b.title }));
}
function applyLabels() {
  document.body.classList.remove("labels-icon", "labels-text", "labels-both");
  document.body.classList.add("labels-" + settings.labels);
  setTimeout(sizeOverlay, 0);
}
applyLabels();
$("btn-settings").addEventListener("click", () => {
  const row = (title, seg) => el("div", { class: "row" }, el("b", { text: title }), seg);
  modal({ title: t("settings"), sheet: true, body: [
    row(t("quality"), segmented([["low", "480p"], ["medium", "720p"], ["high", "1080p"]], settings.quality, (v) => {
      settings.quality = v; prefs.set("quality", v); runStream();
    })),
    row(t("codec"), segmented([["auto", t("auto")], ["h264", "H.264"], ["hevc", "H.265"]], settings.codec, (v) => {
      settings.codec = v; prefs.set("codec", v);
      if (player) player.close();
      player = null;
      runStream();
    })),
    row(t("theme"), segmented([["system", t("system")], ["light", t("light")], ["dark", t("dark")]], settings.theme, (v) => {
      settings.theme = v; prefs.set("theme", v); applyTheme();
    })),
    row(t("labels"), segmented([["icon", t("icons")], ["text", t("words")], ["both", t("both")]], settings.labels, (v) => {
      settings.labels = v; prefs.set("labels", v); applyLabels();
    })),
    (close) => el("div", { class: "comp", onclick: () => { close(null); $("flow-file").click(); } },
      el("div", { class: "t" }, el("div", { class: "title", text: t("replay") }), el("div", { class: "summary", text: t("replayHint") }))),
    (close) => el("div", { class: "comp", onclick: () => { close(null); guide(); } },
      el("div", { class: "t" }, el("div", { class: "title", text: t("guideAgain") }), el("div", { class: "summary", text: t("guideHint") }))),
    (close) => el("div", { class: "comp", onclick: () => { close(null); copyDiagnostics(); } },
      el("div", { class: "t" }, el("div", { class: "title", text: t("copyDiag") }), el("div", { class: "summary", text: t("copyDiagHint") }))),
  ], buttons: [[t("done"), null, true]] });
});
async function copyDiagnostics() {
  const text = JSON.stringify({
    page: pageVersion, browser: navigator.userAgent, secure: window.isSecureContext,
    player: player ? player.constructor.name : null, codec_setting: settings.codec, quality: settings.quality,
    decoded_frames: decoded, shown_at: shownAt ? Math.round(shownAt) : 0, now: Math.round(performance.now()),
    hevc_ok: hevcOK, link: $("sub").textContent, direct: apiBase || null, lan: lanEndpoints, source: state.source,
    frames_in: framesIn, presented: player && player.presented ? player.presented() : null,
    frame: diag.frame || null, events: diag.events,
  }, null, 1);
  try { await navigator.clipboard.writeText(text); }
  catch (_) {
    const area = el("textarea", { style: "position:fixed;opacity:0" });
    area.value = text; document.body.append(area); area.select(); document.execCommand("copy"); area.remove();
  }
  snack(t("copied"));
}
$("btn-full").addEventListener("click", () => {
  if (document.fullscreenElement) document.exitFullscreen();
  else ($("app").requestFullscreen || $("app").webkitRequestFullscreen || (() => {})).call($("app"));
});
new ResizeObserver(sizeOverlay).observe(overlay);

// ───────────────────────────── guide ─────────────────────────────
// Shown once per browser: a spotlight on each part of the page in turn.
function guide() {
  const legend = () => el("div", { class: "legend" }, ...[...document.querySelectorAll("#tools [data-tip]")].map((b) =>
    el("div", {}, b.querySelector("svg").cloneNode(true), el("span", { text: b.title }))));
  const steps = [
    ["screen", "g1t", desktop ? "g1d" : "g1m"], ["tools", "g2t", "g2", legend],
    [wide.matches ? "devices" : ".titles", "g7t", "g7"], [".titles, #people", "g3t", "g3"],
    ["btn-rec", "g4t", "g4"], ["btn-tree", "g5t", "g5"], ["btn-settings", "g6t", "g6"],
  ];
  const block = el("div", { class: "coach-block" }), hole = el("div", { class: "coach" }), card = el("div", { class: "coach-card" });
  document.body.append(block, hole, card);
  let i = 0;
  const end = () => { block.remove(); hole.remove(); card.remove(); removeEventListener("resize", place); prefs.set("guided", "1"); };
  function place() {
    // Every visible element the step names, as one box.
    const boxes = [...document.querySelectorAll(steps[i][0].split(", ").map((q) => /^[.#]/.test(q) ? q : "#" + q).join(", "))]
      .map((e) => e.getBoundingClientRect()).filter((b) => b.width && b.height);
    if (!boxes.length) { if (++i < steps.length) render(); else end(); return; }   // not on screen at this size
    const r = { left: Math.min(...boxes.map((b) => b.left)), top: Math.min(...boxes.map((b) => b.top)),
                right: Math.max(...boxes.map((b) => b.right)), bottom: Math.max(...boxes.map((b) => b.bottom)) };
    r.width = r.right - r.left; r.height = r.bottom - r.top;
    const pad = 6, gap = 14, m = 16, vw = innerWidth, vh = innerHeight;
    Object.assign(hole.style, { left: r.left - pad + "px", top: r.top - pad + "px", width: r.width + 2 * pad + "px", height: r.height + 2 * pad + "px" });
    const cw = card.offsetWidth, ch = card.offsetHeight;
    let x = r.left + r.width / 2 - cw / 2, y;
    if (r.bottom + pad + gap + ch <= vh - m) y = r.bottom + pad + gap;
    else if (r.top - pad - gap - ch >= m) y = r.top - pad - gap - ch;
    else if (r.right + pad + gap + cw <= vw - m) { x = r.right + pad + gap; y = r.top + r.height / 2 - ch / 2; }
    else if (r.left - pad - gap - cw >= m) { x = r.left - pad - gap - cw; y = r.top + r.height / 2 - ch / 2; }
    else y = vh - ch - m;
    card.style.left = Math.min(Math.max(x, m), vw - cw - m) + "px";
    card.style.top = Math.min(Math.max(y, m), vh - ch - m) + "px";
  }
  function render() {
    const [, title, text, extra] = steps[i], last = i === steps.length - 1;
    card.replaceChildren(...[el("div", { class: "step", text: (i + 1) + " / " + steps.length }),
      el("h3", { text: t(title) }), el("p", { text: t(text) }), extra && extra(),
      el("div", { class: "go" }, !last && el("button", { class: "btn text", text: t("skip"), onclick: end }),
        el("button", { class: "btn primary", text: t(last ? "gotIt" : "next"), onclick: () => { if (++i < steps.length) render(); else end(); } }))]
      .filter(Boolean));
    place();
  }
  addEventListener("resize", place);
  render();
}

// ───────────────────────────── recording ─────────────────────────────
// What a person does here, as steps another session can replay: each the
// call it made and the pause before it.
let recording = null, replaying = null;
// "wait" is never recorded, but a recording may be edited to wait for a text
// ({method:"wait", params:{text, timeout}}) before its next step.
const RECORDED = new Set(["tap", "long_press", "gesture", "drag", "type", "home", "lock", "unlock", "launch_app", "rotate", "app_switcher", "notification_center", "control_center", "wait"]);
function record(method, params) {
  if (!recording || replaying || !RECORDED.has(method)) return;
  const now = performance.now();
  recording.steps.push({ method, params, wait: Math.round(now - recording.last) / 1000 });
  recording.last = now;
  const badge = $("btn-rec").querySelector(".badge");
  badge.hidden = false; badge.textContent = recording.steps.length;
  bump(badge);
}
$("btn-rec").addEventListener("click", async () => {
  const btn = $("btn-rec"), badge = btn.querySelector(".badge");
  if (replaying) { replaying.stop = true; return; }
  if (!recording) { recording = { steps: [], last: performance.now() }; btn.classList.add("rec"); return; }
  const steps = recording.steps;
  recording = null; btn.classList.remove("rec"); badge.hidden = true;
  if (!steps.length) return snack(t("recEmpty"));
  const choice = await modal({ title: t("recSaved", steps.length), buttons: [[t("discard"), null], [t("download"), "save"], [t("play"), "play", true]] });
  if (choice === "save") saveFlow(steps);
  if (choice === "play") replayFlow(steps);
});
function saveFlow(steps) {
  const flow = { loopctrl_flow: 1, device: device.name || "", recorded: new Date().toISOString(), steps };
  const a = el("a", { href: URL.createObjectURL(new Blob([JSON.stringify(flow, null, 1)], { type: "application/json" })),
                      download: "loopctrl-" + new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-") + ".json" });
  document.body.append(a); a.click(); a.remove();
}
async function replayFlow(steps) {
  replaying = { stop: false };
  $("btn-rec").classList.add("rec");
  const stop = () => { if (replaying) replaying.stop = true; };
  let i = 0;
  for (; i < steps.length && !replaying.stop; i++) {
    snack(t("replaying", i + 1, steps.length), [t("stop"), stop], true);
    await new Promise((r) => setTimeout(r, Math.min(Math.max(steps[i].wait || 0, 0), 10) * 1000));
    if (replaying.stop) break;
    try { await rpc(steps[i].method, { ...steps[i].params, manual: true }); }
    catch (e) { actionFailed(steps[i].method, e); break; }
  }
  if (i >= steps.length) snack(t("replayDone"));
  else document.querySelector(".snack")?.remove();
  replaying = null;
  $("btn-rec").classList.remove("rec");
}
$("flow-file").addEventListener("change", async () => {
  const file = $("flow-file").files[0];
  $("flow-file").value = "";
  if (!file) return;
  try {
    const flow = JSON.parse(await file.text());
    if (flow.loopctrl_flow !== 1 || !Array.isArray(flow.steps)) throw new Error("format");
    replayFlow(flow.steps.filter((s) => s && RECORDED.has(s.method)));
  } catch (_) { snack(t("badFlow")); }
});

// ───────────────────────────── status ─────────────────────────────
let relayed = location.protocol === "https:", linkUp = false;
function setLink(up) { linkUp = up; renderSub(); renderDevices(); }
let lastDecoded = 0, fps = 0, codecName = "";
function renderSub() {
  const parts = [linkUp ? t(relayed && !apiBase ? "relay" : "direct") : t("offline")];
  // How the phone takes its screen: screenshots, or the system's screen
  // recording while one runs (docs/remote-control.md, "System broadcast").
  if (linkUp && state.source) parts.push(t(state.source === "broadcast" ? "srcBroadcast" : "srcCapture"));
  if (linkUp && shownAt) parts.push(codecName, fps + " fps", Math.round(lastRTT) + " ms");
  $("sub").textContent = parts.join(" · ");
}
setInterval(() => {
  fps = decoded - lastDecoded; lastDecoded = decoded; renderSub();
  if (player && player.check) player.check();   // also when frames stop coming
}, 1000);
// A quick look at another tab or window keeps the stream: a new one would
// cost a keyframe and start its bitrate low again, every time. Only a page
// hidden for a while lets it go.
let hideTimer = 0;
document.addEventListener("visibilitychange", () => {
  note("page " + document.visibilityState, "");
  if (!key) return;
  clearTimeout(hideTimer);
  if (document.hidden) hideTimer = setTimeout(stopStream, 15000);
  else if (streamAbort) askKeyframe();   // frames may have been skipped meanwhile
  else runStream();
});

// ───────────────────────────── devices ─────────────────────────────
// Every phone opened in this browser on this site, to switch between. Under
// a relay all phones share the site, so each one's page lists the others; a
// phone at another address (a LAN or tailnet IP) can be added by its URL.
// Switching is opening that phone's page: each keeps its own pairing key.
const pageURL = () => location.href.split("#")[0].split("?")[0];
const wide = matchMedia("(min-width: 1100px)");
function deviceList() {
  try { const l = JSON.parse(prefs.get("devices") || "[]"); return Array.isArray(l) ? l : []; } catch (_) { return []; }
}
function saveDevices(list) { prefs.set("devices", JSON.stringify(list.slice(0, 30))); }
function rememberThisDevice() {
  const list = deviceList(), url = pageURL();
  const at = list.findIndex((d) => (device.id && d.id === device.id) || d.url === url);
  const entry = { id: device.id || url, name: device.name || location.host, url, via: relayed ? "relay" : "direct" };
  if (at >= 0) list[at] = entry; else list.push(entry);
  saveDevices(list);
}
const devState = {};   // id → "on" | "off" | "unknown"
async function probe(d) {
  if (new URL(d.url).origin !== location.origin) return "unknown";   // whoami is same-origin only
  const abort = new AbortController(), timer = setTimeout(() => abort.abort(), 6000);
  try {
    const r = await fetch(new URL("whoami", d.url), { cache: "no-store", signal: abort.signal });
    const who = r.ok ? await r.json() : null;
    if (!who || (d.id && !d.id.startsWith("http") && who.device_id !== d.id)) return "off";
    if (who.name && who.name !== d.name) {
      const list = deviceList(), e = list.find((x) => x.url === d.url);
      if (e) { e.name = who.name; e.id = who.device_id; saveDevices(list); }
    }
    return "on";
  } catch (_) { return "off"; } finally { clearTimeout(timer); }
}
const PHONE_ICON = icon('<rect x="7" y="2.5" width="10" height="19" rx="2.5"/><path d="M11 18.5h2"/>');
function renderDevices() {
  const here = pageURL();
  $("devlist").replaceChildren(...deviceList().map((d, k) => {
    const current = d.url === here || (device.id && d.id === device.id);
    const st = current ? (linkUp ? "on" : "off") : devState[d.id] || "unknown";
    const row = el(current ? "div" : "a", { class: "dev" + (current ? " current" : ""), style: "--k:" + k, ...(current ? {} : { href: d.url }) },
      el("div", { class: "ic" }, PHONE_ICON.cloneNode(true)),
      el("div", { class: "t" }, el("div", { class: "title", text: d.name || d.url }),
        el("div", { class: "summary" }, el("i", { class: "dot" + (st === "on" ? " on" : st === "off" ? " off" : "") }),
          el("span", { text: [t(d.via === "relay" ? "relay" : "direct"),
                              current ? t("devThis") : t(st === "on" ? "devOn" : st === "off" ? "devOff" : "devOpen")].join(" · ") }))),
      !current && el("button", { class: "iconbtn rm", title: t("remove"), "aria-label": t("remove"), onclick: (ev) => {
        ev.preventDefault(); ev.stopPropagation();
        saveDevices(deviceList().filter((x) => x.url !== d.url));
        renderDevices();
      } }, icon('<path d="M6 6l12 12M18 6L6 18"/>')));
    return row;
  }));
}
async function refreshDevices() {
  const here = pageURL();
  await Promise.all(deviceList().filter((d) => d.url !== here && d.id !== device.id).map(async (d) => { devState[d.id] = await probe(d); }));
  renderDevices();
}
setInterval(() => { if (!document.hidden && devicesShown()) refreshDevices(); }, 20000);
const devicesShown = () => getComputedStyle($("devices")).display !== "none" && !$("devices").classList.contains("collapsed");
let drawerScrim = null;
function setDevices(show) {
  const panel = $("devices");
  $("title-btn").setAttribute("aria-expanded", String(show));
  if (wide.matches) {
    panel.classList.toggle("collapsed", !show);
    prefs.set("devicesCollapsed", show ? "" : "1");
    setTimeout(sizeOverlay, 0);
  } else if (show) {
    panel.classList.add("open");
    if (!drawerScrim) {
      drawerScrim = el("div", { class: "drawer-scrim", onclick: () => setDevices(false) });
      document.body.append(drawerScrim);
    }
  } else {
    leave(panel, "closing", () => panel.classList.remove("open"));
    if (drawerScrim) { leave(drawerScrim, "closing"); drawerScrim = null; }
  }
  if (show) {
    const list = $("devlist");
    list.classList.add("entering");
    setTimeout(() => list.classList.remove("entering"), 700);
    refreshDevices();
  }
}
$("title-btn").addEventListener("click", () => setDevices(!devicesShown()));
$("devices-close").addEventListener("click", () => setDevices(false));
wide.addEventListener("change", () => {
  $("devices").classList.remove("open");
  if (drawerScrim) { drawerScrim.remove(); drawerScrim = null; }
  $("devices").classList.toggle("collapsed", !!prefs.get("devicesCollapsed"));
  setTimeout(sizeOverlay, 0);
});
$("devices").classList.toggle("collapsed", !!prefs.get("devicesCollapsed"));
$("dev-add").addEventListener("click", async () => {
  const input = el("input", { class: "keyfield", type: "url", placeholder: "https://…/remote", autocomplete: "off", spellcheck: "false" });
  const err = el("div", { class: "err" });
  const value = await modal({ title: t("addDevice"), body: [el("p", { text: t("addHint") }), (close) => {
    input.addEventListener("keydown", (e) => { if (e.key === "Enter") close("go"); });
    return input;
  }, err], buttons: [[t("close"), null], [t("add"), "go", true]] });
  if (value !== "go" || !input.value.trim()) return;
  let u;
  try { u = new URL(input.value.trim()); if (!/^https?:$/.test(u.protocol)) throw 0; } catch (_) { return snack(t("badUrl")); }
  u.hash = ""; u.search = "";
  if (!/\/remote\/?$/.test(u.pathname)) u.pathname = u.pathname.replace(/\/?$/, "/remote");
  const list = deviceList();
  if (!list.some((d) => d.url === u.href)) {
    list.push({ id: u.href, name: u.pathname.match(/\/d\/([^/]+)\//)?.[1] || u.host, url: u.href,
                via: u.protocol === "https:" ? "relay" : "direct" });
    saveDevices(list);
  }
  setDevices(true);
});
// Followed in other tabs too: a phone added or renamed there shows up here.
addEventListener("storage", (e) => { if (e.key === "loopctrl.devices") renderDevices(); });

// ───────────────────────────── start ─────────────────────────────
function show(id) {
  for (const e of ["pair-start", "pair-wait"]) $(e).hidden = e !== id;
}
function needPair() {
  stopStream();
  key = null;
  store.del(storeName());
  $("pair").hidden = false;
  show("pair-start");
}
$("pair-btn").addEventListener("click", async () => {
  $("pair-err").textContent = "";
  $("pair-btn").disabled = true;
  try { await pair(); begin(); }
  catch (e) { $("pair-err").textContent = e.message || String(e); show("pair-start"); }
  $("pair-btn").disabled = false;
});
$("key-toggle").addEventListener("click", () => { $("key-input").hidden = !$("key-input").hidden; $("key-input").focus(); });
$("key-input").addEventListener("change", () => {
  const v = $("key-input").value.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(v)) return;
  store.set(storeName(), v); useKey(v); begin();
});

async function begin(adopt = "") {
  $("pair").hidden = true;
  setMessage(t("connecting"));
  try {
    const info = await rpc("device_info");
    if (adopt) store.set(storeName(), adopt);
    if (info.point_width) points = { w: info.point_width, h: info.point_height };
    if (info.device_name || info.name) $("name").textContent = info.device_name || info.name;
    const c = await rpc("control");
    onState({ ...state, paused: c.paused, people: c.people });
    if (!prefs.get("guided")) setTimeout(guide, 400);
  } catch (e) {
    if (e instanceof AuthError) return needPair();
  }
  runStream();
}

// Kept by the browser, so that with the phone offline (the relay answers
// for it) the page still opens: the device list, the tools and the settings
// work, and only the screen says the phone is away.
if ("serviceWorker" in navigator && window.isSecureContext) navigator.serviceWorker.register("remote-sw.js").catch(() => {});

function waitForPhone() {
  setLink(false);
  setMessage(t("phoneOffline"), true);
  const timer = setInterval(async () => {
    try {
      const r = await fetch("whoami", { cache: "no-store" });
      if (r.ok) { clearInterval(timer); location.reload(); }
    } catch (_) {}
  }, 5000);
}

(async () => {
  let reachable = false;
  try {
    const r = await fetch("whoami", { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    device = await r.json();
    device.id = device.device_id || "";
    relayed = device.via === "relay";
    reachable = true;
  } catch (_) {
    // Offline: what this browser remembers of the phone.
    const known = deviceList().find((d) => d.url === pageURL());
    if (known) {
      device = { id: known.id.startsWith("http") ? "" : known.id, name: known.name };
      relayed = known.via === "relay";
    }
  }
  if (!settings.quality) settings.quality = relayed ? "medium" : "high";
  $("name").textContent = $("pair-name").textContent = device.name || "LoopCtrl";
  document.title = (device.name || "LoopCtrl");
  if (reachable) rememberThisDevice();
  renderDevices();
  if (devicesShown()) refreshDevices();
  renderSub();
  if (!reachable) return waitForPhone();
  // Pages before this one kept the key under the site's name, which every
  // phone on one relay shares. Try such a key once; keep it under this
  // phone's id if the phone takes it.
  const own = store.get(storeName()), legacy = store.get("loopctrl.key." + location.host);
  const saved = own || legacy;
  if (saved && /^[0-9a-f]{64}$/.test(saved)) { useKey(saved); begin(!own && device.id ? saved : ""); }
  else needPair();
})();
})();
</script>
</body>
</html>
"""#
}
