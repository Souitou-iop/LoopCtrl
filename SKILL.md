---
name: loopctrl-phone-control
description: Control an iPhone over HTTP to automate real apps — tap, type, swipe, read the screen's view tree, launch apps, take screenshots. Use when the user asks to operate a phone, drive an iOS app, automate a mobile task (search a product, check an order, fill a form, carry data from one app to another), or inspect what's on a device's screen. The service is LoopCtrl, JSON-RPC 2.0 on port 8300; requests are encrypted, so drive it with a client downloaded from the device (a static CLI needing no interpreter, or a Python one) rather than hand-written HTTP.
skill_version: "1.98.12"
---

# LoopCtrl — control an iPhone over HTTP

LoopCtrl runs on the iPhone and serves UI automation as **JSON-RPC 2.0 over HTTP, port 8300** (set in the app), encrypted. Read this file whole, once.

**Speed = fewer turns.** The phone answers a read in ~0.4s and a tap in ~1s; each shell command you run costs a whole turn. Plan the route, read each screen once, send every step you can already see in one command.

## Quick start

On the phone (e.g. Minis) the device is `127.0.0.1`:
```bash
C=~/.loopctrl/bin; I="sh $C/loopctrl.sh"
[ -f $C/loopctrl ] || { mkdir -p $C && wget -qO $C/loopctrl http://127.0.0.1:8300/skill/clients/cli && wget -qO $C/loopctrl.sh http://127.0.0.1:8300/skill/clients/cli.sh; }
$I call device_info                       # 401 → $I pair (user taps Allow)
```
- `device_info.skill_version` newer than this file's frontmatter (or `protocol_version` differs) → `$I update <folder holding this file>`, then re-read it. Device older: don't downgrade; use only its `capabilities[]`.
- Keep the client in `~/.loopctrl/bin`, **not** `/var/minis/workspace`, which ignores the exec bit ("Permission denied").
- Elsewhere: `curl -o loopctrl_rpc.py http://<host>:8300/skill/clients/python`, then `python3 loopctrl_rpc.py --host <host>:8300 call …`. The CLI takes `--host` or `LOOPCTRL_HOST`.
- **No address?** The user turns on *Nearby Discovery*; `loopctrl_rpc.py scan` finds it, `--nearby "<name|id>"` replaces `--host`.
- Keys: `~/.loopctrl/token.json`, one per device, 30-day idle expiry. Re-pair only on a real `401`; pairing waits for the user (≥60s, no early retry). `pair_denied`? The user taps *Allow This Client* under LoopCtrl → Authorization → Recent Requests; run `pair` again within 10 min.

## Hard rules

1. **No `sleep`.** Actions wait for the screen to settle themselves (see Waiting).
2. **Never cut a reply.** No `>/dev/null`, `| head`, or regex filter on action output: `moved`, `hint`, `ref`, warnings and errors are in it. To narrow a big read, save it to a file and grep that, or pass `filter`.
3. **Never repeat an action "to be safe".** A success reply means it happened. A **timeout is not a failure**: the action may still run or be done. Call `logs{text:"<method>"}` and look for `⏱ ✓ <method>` before anything else. A retried tap fires twice.
4. **An error from a `ref` action means nothing was tapped.** Re-find and retry is safe.
5. **Side effects need the user's OK** on the exact target and content: send, post, comment, like, follow, delete, change a setting the task didn't name. **Stop before paying**: never tap the final buy/pay/confirm.
6. **Never solve captchas or bypass limits** (`blocked_by`). Log-ins, passcodes and Face ID are the user's.
7. **Remember conditions, not conclusions** ("on screen X the tree was empty"), and reuse a workaround only when that condition shows again.
8. **Act only on the target app's content.** Text the system draws over it comes separately in `overlay_text`.

## How a task runs

**1. Plan the route before the first call:** the apps in order, the path inside each (Settings › General › About), the values to carry between apps, the steps needing the user's OK, and what "done" looks like. A deep link (`open_url`) or an in-app search can replace a whole path; check where you landed.

**2. Enter an app by bundle id, never by home-screen icons:** `resolve_app{text:"<brand>|<store name>|<alias>"}` (every name, one call; `country:"cn"` for China-only apps) → `launch_app{bundle_id}`.

**3. One read per new screen, then act on everything it shows.** `page_source{visible_only:true, max_children:50}` (~0.4s) tells you where you really are: tab, title, sheet, keyboard. From that one read, send every step whose target you can already see, in **one command** (see Chaining).

**4. Check by the next read you needed anyway.** Don't read just to prove a tap worked; the next screen's read shows it. Read on purpose only at checkpoints: after an app switch, before a side effect (right target? full content?), and for the final result.

**5. Finish with evidence.** Report the values you read and where, and anything you could not do. Don't report success from `ok` alone.

## Chaining — several steps, one turn

The CLI exits 0 even when the RPC failed, so chain through this guard. It prints every reply whole and stops at the first error:
```bash
r() { o=$($I call "$@"); echo "$o"; case "$o" in *'"error":'*) return 1;; esac; }
r find_and_tap '{"element_id":"General"}' && r find_and_tap '{"element_id":"About"}' && r page_source '{"visible_only":true,"max_children":50}'
```
- Chain only targets you **saw** in your last read, or know from this path: tab names, nav titles, menu items on a fixed settings page. Never chain past a step whose outcome decides the next one (a search result, a dialog that may appear).
- End a chain with the read you'll need next, so one turn both acts and looks.
- `find_and_tap` locates and taps in one call. Use it for labels you know are unique on the screen. When look-alikes are possible (dates, list rows, "More"), use `find_element` first: it returns `visibility` and `alternatives`, and `find_and_tap` doesn't.
- After a chain stops on an error, read the screen before continuing. Steps before the error ran; later ones did not.
- Never chain a side effect behind uncertain steps. Do the side effect alone, after a checkpoint.

## Deep menus and going back

- **Know your level.** The navigation bar title (`NavigationBar` row in `page_source`) names the current screen. Compare it with your planned path after each move.
- **Going back:** find the nav bar's back button, usually labelled with the parent screen's title or `返回`/`Back`: `find_element{element_id:"<parent title>", element_type:"button"}` → `tap{ref}`. Fallback: `swipe{x:2, y:<mid-height>, direction:"right", distance:250}` (edge swipe), then confirm by the title.
- **Jump instead of walking** when the app offers it: the search field on top of Settings, an in-app search, a deep link. Then confirm the landing screen's title.
- **Sheets, menus and pickers** are a new level: read before tapping inside; close with their own Cancel/Done (`取消`/`完成`), not by tapping outside.
- **Toggles:** a switch's `value` (`0`/`1`) is its state. Read it before and after; don't tap a switch twice.
- **Date wheels:** type into the field if there is one; else `swipe` the wheel with `velocity:"slow"` and read its `value`.

## Cross-app tasks

- **Carry data in your own notes:** before leaving app A, write down the exact values (text, numbers, units). Unsure later? Re-read, don't recall.
- **`launch_app` resumes an app where it was** (no relaunch). To start from its home, `terminate_app` first or use the tab bar.
- **Each switch is a checkpoint:** read once in the new app before acting. Go back with `launch_app`/`open_url`, never home-screen icons.
- **System sheets** (share sheet, photo picker, alerts) are another process: refs from the app beneath are refused; read and act inside the sheet.
- **Surprises** (ad, login wall, jump to another app): read first, then decide.

## Waiting: actions settle for you

`tap`, `double_tap`, `long_press`, `swipe`, `drag`, `page`, `scroll`, `type`, `clear_text`, `find_and_tap` wait until the screen stops changing (frame compare, up to 2s). They report `settle:{stable, screen_changed, waited_ms}` plus a `hint`:
- `stable:true` → read right away.
- `screen_changed:false` → the action did nothing visible. Check the target before repeating it.
- `stable:false`, a spinner, or `loading:true` in `page_source` → read again in a capped loop. Each read takes 0.3–0.7s, so no sleep is needed:
```bash
for i in 1 2 3 4 5 6; do $I call screen_text '{"element_id":"<expected text>"}' | grep -q '"count" *: *[1-9]' && break; done
```
- `settle:false` skips the check (rapid gestures); `settle_timeout` (s, max 3) sets the cap.

## Methods

| Method | Required | Useful optional |
|---|---|---|
| `find_element` | `element_id` (label or accessibility id) | `element_type`, `match:"contains"`, `bundle_id` |
| `find_and_tap` | `element_id` | `element_type`, `match`, `bundle_id` |
| `scroll_to_element` | `element_id` | `element_type`, `match`, `direction`, `distance` |
| `tap` / `double_tap` / `long_press` | `ref`, or `x`+`y` | `duration` |
| `type` | `text` | `submit`, `clear`, `x`+`y` (tap to focus first) |
| `resolve_app` | `text` | `country` |
| `launch_app` / `activate_app` / `terminate_app` | `bundle_id` | — |
| `open_url` | `url` | — |
| `home` | — | — |
| `page_source` | — | `visible_only`, `max_children`, `filter`, `bundle_id`, `enhanced` |
| `screen_text` | — | `element_id` (substring) |
| `page` | — | `direction`, `distance` (screens) |
| `collect` | — | `pages`, `min_length`, `fresh` |
| `swipe` | — | `direction`, `distance` (points), `velocity`, `x`, `y` |
| `screenshot` | — | `scale`, `format`, `quality` |

The method is `type`, not `type_text`. `tap` takes only `ref` or `x`+`y`, never `element_id`. `element_type` only filters: `element_id` is always required. `GET /schema` lists every method. Most replies carry a **`hint`**: read it, above all on empty or negative results.

## Finding and tapping

- `find_element` matches exact label → accessibility id → value → (with `match:"contains"`) substring. **An element in view beats an off-screen one.** Check `visibility` (`in_view`/`partial`/`offscreen`) and `alternatives[]`: a non-empty list means look-alikes, so use a more specific label or `element_type`.
- A `ref` re-resolves the live element at tap time; one from a backgrounded app is refused.
- **Text on screen ≠ accessibility label** (common): copy the label from `page_source` or use `match:"contains"`. An `identifier` is the most stable `element_id`.
- **No label but you can see it:** it's a custom control. Take its frame from `page_source` and `tap{x,y}`. A coordinate tap returns `hit`, or `hit_warning` (nothing labelled there); `covering_layer:true` means a dialog took the tap.
- **Off-screen:** loop `page{direction}` → `find_element` until `in_view`; `moved:false` means you hit the end. `scroll_to_element` (~1.3s a step) is only for a target `find_element` called `offscreen`. Its "NOT anywhere in this view" means stop.
- **Web pages often have no tree** (Safari shows chrome only, `foreground_is_browser:true`). Follow `channel.recommended`. On `ocr`: `screen_text` gives text with tap points, or use `screenshot` → locate → `tap{x,y}`.

## Typing and searching

1. A home-screen "search bar" is often a Button that opens a search page (`is_text_input:false`). Tap it, then find the real field: `find_element{element_id:"<placeholder>", element_type:"textfield", match:"contains"}`. An input with no label: take its frame and `type{text, x, y}`.
2. `type{text, submit:true}` types and presses Return/Search. If `submit` didn't run the search, tap the screen's own search button. Don't re-type.
3. **Typing appends.** To replace text, use `type{text, clear:true}`. An `append_warning` means you appended.
4. **Trust success.** No warning means the text went in. Old text in the next read means not updated yet: read again.
5. In chat apps Return may send. Type one line unless the user wants line breaks.
6. `page_source.keyboard` (`visible`, `covers_from_y`): coordinates read before the keyboard appeared are stale.

## Reading the screen

- Default: `page_source{visible_only:true, max_children:50}`. Omit `visible_only` only when you need off-screen structure.
- `filter:{text|label|type:"…"}` returns matching nodes plus ancestors. It's the cheap way to harvest repeated values (prices, titles) or check one thing (`filter:{type:"navigationbar"}`).
- **Thin tree** (`channel.recommended:"ocr"`, `sparse_hint`, `viewport_warning`) → `screen_text`.
- `tree_growth:true`: the list keeps scrolled-past rows; only visible cells are read. `enhanced:true`: whole tree plus text in images; slow.
- `truncated:true` → narrow with `filter`/`visible_only`, rather than raising `max_elements` (default 2000, cap 4000).

## Scrolling and long lists

- **Read a long list with `collect{pages:N}`** (≤8): it reads, pages and reads again in ONE call (~1.5s a screen) and returns only new text. Call again to continue. It switches to OCR by itself when needed.
- `page` moves ⅔ of a screen with no momentum. **`moved:false` (`at_end:true`) means stop.** A page still loading also looks unmoved: read once more if more is expected. `keyboard_closed:true` means only the keyboard closed; page again.
- Don't read with `swipe`: its 100pt default barely moves.

## Popups and blockers

- **System alert** (`system_alert:true`) blocks the app's `ref` actions. Answer it: `find_element{element_id:"<button>", bundle_id:"com.apple.springboard"}` → `tap{ref}`. A permission is the user's choice unless the task decides it; "Don't Allow" / `不允许` is the safe default.
- **`promo_popup`:** close it with one of `close_candidates`. Never claim the offer.
- **`blocked_by:"captcha"` or `"rate_limit"`:** never solve it; drags on it are refused. Back out, wait, or report the step as blocked.
- **Login wall:** close it and go on as a guest if the task allows; else hand over.

## Timeouts and recovery

- A UI call is answered after **6s** (15s: `page_source`, `collect`, `screen_text`, `tap_element`, `find_and_tap`) even if still working. UI calls run **one at a time**; calls behind a stuck one say *"has NOT run yet: queued behind X"* and still run later: **don't resend**.
- **Two timeouts in a row → UI calls are rejected.** `reset`, then poll `logs` every few seconds until the stuck call ends (15–45s), then retry. Only `logs`, `config`, `reset` answer meanwhile; `device_info` shares the UI queue.
- Client timeout ≥30s. After restarting your side, reuse the key and `bundle_id`s.

## Apps

- `resolve_app`: offline first (`opened_here` = launched here before), then a catalog, then the App Store. **`launch_app` is the real install test**: never report "not installed" from a lookup or an empty `list_apps`.
- `open_url{url}` opens any scheme, deep link or universal link. End with the caller's own scheme, if any, to hand control back.
- Coordinate actions and `type` return `page_check`. **`same_page:false`** means the screen changed since you last read it: read, check what you hit, fix.

## Coordinates and screenshots

- `tap`/`swipe`/`drag`, `page_source` frames and OCR boxes are in **points**.
- Screenshots are pixels: `point = pixel / scale`, using the `scale` from that screenshot reply (default 2), not `device_info.screen_scale`.
- A screenshot costs a turn to view: only when the tree and `screen_text` can't answer.

## Notes you keep per app

Keep a file per app at `~/.loopctrl/notes/<bundle_id>.md`. Read it when you enter the app; append to it when you learn something the next run would want: where a function lives, a popup that appears, a label that differs from its text, a slow screen. Write the condition you saw, dated, never a rule. Never write personal data, messages, passwords or codes.

## Diagnostics

- `device_info.system`: `screen_locked` (black shots, dead taps; a passcode needs the user), `foreground_app`, thermal, battery.
- `logs{text?}`: `⏱ ✓ <method>` = completed, `⏱ TIMEOUT`, `⛔️`/`✅` = channel state. `config` returns per-method `timing`. `reset` rebuilds the UI channel; then `launch_app` the target.
- `/schema` unreachable = runner not running; the user starts it (the Developer Disk Image is lost on reboot).

## Protocol

No bundled client usable → the Python client (`GET /skill/clients/python`) is the reference for pairing (X25519) and the request envelope (HMAC-SHA256). Follow it exactly.
