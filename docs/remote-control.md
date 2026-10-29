# Remote control: one page, direct or through a relay

Turn the service on, open an address in a browser, tap **Allow** on the phone,
and drive it: a live screen, touch, keyboard, hardware buttons and the view
tree. The same page and the same code path serve all three ways in:

| Way in | Address | Transport |
|---|---|---|
| Same Wi-Fi | `http://<phone>:8300/remote` | the phone's own HTTP server |
| Tailnet | `http://100.x.y.z:8300/remote` | the same, over WireGuard |
| Relay | `https://<slug>.<relay domain>/remote` (or `https://<relay>/d/<slug>/remote`) | the relay forwards whole HTTP exchanges to the phone over one WebSocket the phone keeps open |

The relay is a reverse tunnel, not a second implementation: every request a
browser or an agent sends to the public address reaches the phone's server
unchanged, so `/remote`, `/pair`, `/rpc`, `/stream`, `/skill` and the rest
behave exactly as on the LAN.

## Trust

- **Pairing and the v1 envelope stay end to end.** The relay sees `/pair`
  requests (whose key grant is wrapped with X25519) and sealed `/rpc` bodies.
- **The video is encrypted when the page runs in a secure context** (any
  `https://` address, so always through a relay): AES-256-GCM under a key
  derived from the pairing key (see [Stream](#stream)). A passive relay sees
  neither the screen nor the commands.
- **The relay serves the page.** Whoever runs the relay could change the page
  it forwards and so read the key the page holds. Use a relay you run, or one
  run by someone you would trust with the phone anyway. This is the same
  trust a reverse proxy in front of any web app gets.
- **Requests through the relay are remote, never local.** They reach the
  runner on a separate loopback port (`port + 2`) whose connections are always
  classified `relay`, so a plaintext key grant (loopback only) and the
  owner-only `config` settings are refused to them, as for any other remote
  caller. Only the relay's own invite operators are pre-approved, and only
  through that relay connection (docs/relay-enrollment.md).
- **Each phone gets its own origin** in subdomain mode, so a page one phone
  serves can't read what another phone's page stored. Path mode (`/d/<slug>/`)
  puts every phone of that relay on one origin; use it only when all of them
  belong to the same person.

## Tunnel protocol (v1)

The phone signs in exactly as before (`/v1/device/challenge`,
`/v1/device/session`), then opens

```
GET /v1/device/tunnel
Authorization: Bearer <device_token>
Sec-WebSocket-Protocol: loopctrl-tunnel-v1
```

The relay answers with a text message, then carries binary messages both ways.

```json
{"type": "hello", "public_url": "https://k3x9….relay.example.com/", "max_frame": 32768, "window": 262144}
```

Binary message: `type u8 | stream u32 (big-endian) | payload`.

| Type | Name | Direction | Payload |
|---|---|---|---|
| 1 | `OPEN` | relay → phone | JSON `{"method", "path", "headers": [[name, value], …], "peer"}`. `path` includes the query and has the `/d/<slug>` prefix removed. |
| 2 | `DATA` | both | bytes, at most `max_frame` |
| 3 | `END` | both | none: the sender sends no more `DATA` on this stream |
| 4 | `RESET` | both | optional UTF-8 reason: the stream is abandoned |
| 5 | `WINDOW` | both | `u32` credit: the receiver has passed on that many more bytes |

- The relay opens streams, numbered from 1. One stream carries one HTTP
  exchange: request head in `OPEN`, the request body as `DATA`, `END`; the
  response comes back as raw HTTP/1.1 bytes (status line, headers, body) in
  `DATA`, then `END` when the phone's server closes the connection.
- Each side may have at most `window` unacknowledged bytes in flight per
  stream and direction. It sends `WINDOW` as it hands data on, so a slow
  browser slows the phone's server, which then drops video frames rather than
  queueing them.
- A new tunnel from the same device replaces the old one; its streams are
  reset.
- The relay pings every 20 s; the phone reconnects with backoff (1, 2, 4, 8,
  16 s) after a drop.

The phone turns `OPEN` into an HTTP/1.1 request to `127.0.0.1:<port + 2>`. It
drops hop-by-hop headers and any `X-LoopCtrl-Relay-*` the relay sent, then
adds its own:

| Header | Value |
|---|---|
| `X-LoopCtrl-Relay-Connection` | the app's id for this relay connection |
| `X-LoopCtrl-Relay-Server` | the relay's name (`host[:port][/path]`) |
| `X-LoopCtrl-Relay-Peer` | the browser's address as the relay reports it |

The runner reads those headers only on the relay port.

## Stream

`GET /stream?ticket=<t>[&quality=low|medium|high][&codec=h264|hevc][&enc=1][&ack=1][&workers=1-3]`.
The ticket comes from the `stream_ticket` RPC, is single use and lasts 60 s.
The response is a sequence of messages:

```
len u32 (big-endian, covers type + payload) | type u8 | payload
```

| Type | Name | Payload |
|---|---|---|
| 0 | `HELLO` | JSON, always in the clear: `{"v": 1, "enc": "none" \| "aes-256-gcm", "salt": "<hex>", "viewer": "<id>"}` |
| 1 | `CONFIG` | JSON: `{"codec": "avc1.64002a" \| "hvc1.1.6.L120.B0", "width", "height", "point_width", "point_height", "description": "<base64 avcC or hvcC>"}` |
| 2 | `FRAME` | `flags u8` (bit 0: keyframe) `| ts u64` (microseconds) `| access unit` (length-prefixed NAL units) |
| 3 | `STATE` | JSON: `{"paused", "people": [{"tok", "name", "kind", "watching", "operating", "since", "actions"}], "hidden", "lan": ["<ip:port>"]}`, first after `HELLO` and again whenever it changes (see [Control](#control)); `lan` lists where the phone answers on the LAN, when it does (see [Direct on the LAN](#direct-on-the-lan)) |

With `enc=1` the runner derives `key = HMAC-SHA256(K, "loopctrl-stream-v1" || salt)`
from the pairing key `K` the ticket was minted for, and every message after
`HELLO` carries `AES-256-GCM(key, iv = 0x00000000 || be64(counter), aad = type)`
of its payload instead of the payload, the counter starting at 0. The page asks
for it whenever it has WebCrypto.

Up to 60 fps at `medium` (720p, 3 Mbit/s) and `high` (1080p, 8 Mbit/s), 30 at
`low` (480p, 1 Mbit/s). One screen capture takes about 30 ms on a phone, so
captures overlap: `workers` (default 3) threads capture in turn, paced to the
frame rate, and hand each frame to the encoder without waiting for it; a frame
whose capture finishes after a later one's is dropped. Measured on an iPhone
17: one capture takes 29 ms alone and 34 ms when two overlap, so two workers
reach about 45–50 fps and three about 60. If captures keep failing with several
workers, the runner drops to one. While the screen has not changed for a
second, it is looked at 10 times a second instead, and at the full rate again
as soon as it changes or an action lands: each capture is a full screenshot,
and sixty a second of a still screen only warm the phone, which then captures
slower (seen: 200 ms a capture instead of 50).

`CONFIG` comes first and again whenever the encoder restarts (rotation,
quality or codec change, or a restart after a failure). A new client starts at
a keyframe. An unchanged screen sends nothing. When a client can't keep up,
the runner skips frames for it and resumes at the next keyframe.

**One encoder per viewer.** Each viewer gets an encoder of its own (its codec,
its size, its bitrate), up to three; viewers beyond that share one that makes
the same quality, HEVC only if all of them asked for it. So a viewer joining
doesn't change what the others get, and one on a slow relay doesn't slow one
on the LAN: its encoder simply takes no new frame while its frames queue.
Each frame is captured once and drawn once per size, however many encoders
take it.

**Encoders that stop.** iOS invalidates a hardware encoder made while LoopCtrl
was in front once LoopCtrl goes to the background (pressing Home from the
page is enough); frames then go in and nothing comes out, with no error the
stream would otherwise notice, while actions still work. So the runner starts
every encoder afresh when LoopCtrl moves between foreground and background,
and also starts a new one for any encoder that reports an error or has taken
frames for a second without returning one.

**Codec.** The page asks for HEVC when its choice is Auto and the browser can
decode it, or when the user picks H.265; the runner makes H.264 when the phone
can't make HEVC. HEVC needs roughly a third less
bitrate for the same picture, which on a slow link means more frames and less
delay.

**Acknowledgements.** With `ack=1` the client calls the `stream_ack` RPC
`{"viewer": "<id from HELLO>", "ts": <newest frame's ts>, "queue_ms": <n>}` a
few times a second, without waiting for the previous answer (it comes back up
the same congested link as the video). The runner then:

- captures no new frame while the viewer's last reported queue, less the time
  since it was reported, is over 200 ms, so frames never pile up in socket
  buffers along the way. The client reports it as `queue_ms`: how much later
  than the quickest frame of the last 10 s its newest frame arrived (arrival
  time minus `ts`, minus the smallest such difference). That is one-way, so
  the slow trip of the acknowledgement itself doesn't count. A client that
  doesn't report it is judged by how long its acknowledgements take, more
  generously;
- starts at no more than 2 Mbit/s, then sets the encoder's bitrate once a
  second: 85% of what got through when a viewer fell behind (at most halving
  it), a quarter more each second after two calm ones, up to the quality's
  rate.

**Keeping the picture current.** A still screen sends no frames, so two
things could otherwise leave the page showing an old picture for good:

- A viewer that missed frames, or whose decoder dropped or failed on some,
  shows nothing new until a keyframe. The page says so (`stream_ack` with
  `key: true`, sent at once, not only with the next frame), and the runner
  makes a keyframe even on a still screen, at most once a second, until the
  viewer has one. The page also replaces a decoder that failed, or that has
  taken frames for 2 s without showing any and without an error (some
  browsers' hardware H.265 decoders hang this way). If H.265 hangs twice
  within a minute and the codec is on Auto, that browser uses H.264 for a day.
- A link that died without the browser noticing (a relay or network drop)
  leaves requests waiting forever. The runner repeats `STATE` every 3 s, the
  page starts a new stream when it has heard nothing for 10 s, and every
  request gives up after a while (4 s for acknowledgements, 8 s for a stream
  ticket, 20 s otherwise), so a retry gets a fresh connection.
- Anything else that stops the picture while the stream goes on. The page
  checks the whole path itself: frames that arrive for 3 s with none shown
  get a new player (a third time within 30 s, a new stream); and an action
  that brings no new frame within 1.5 s asks for a keyframe, which also has
  the runner restart an encoder that died, and if nothing comes 4 s later
  either, the page starts a new stream.

Without acknowledgements, a link slower than the stream's bitrate builds
seconds of delay (measured: 4 s at 720p over a 1.5 Mbit/s uplink); with them
it stays at a few hundred milliseconds, and the quality drops instead.

The page decodes with WebCodecs where it can (secure contexts) and otherwise
wraps each frame in fragmented MP4 (`avc1`/`hvc1`) for Media Source
Extensions.

## System broadcast

Settings › System broadcast (all-in-one app only) adds a second way to get the
screen: iOS's own screen broadcast (ReplayKit), started with one tap on the
home screen's 系统录屏推流 row, which presses the system's broadcast button
limited to LoopCtrl's extension. iOS starts a broadcast only that way, never
on its own, and shows the red recording indicator while it runs. Until one is
started, and the moment it ends, the stream takes screenshots as before.

The extension (`LoopCtrlBroadcast`, a broadcast upload extension) gets each
picture as iOS draws it, with no screenshot taken and no JPEG made: it turns
it upright, scales it in hardware to each lane's size and encodes it there.
The runner keeps everything else: viewers, acknowledgements, bitrate,
keyframes and holding back for a viewer that falls behind. It tells the
extension 20 times a second what each lane needs, and passes the frames it
gets back to that lane's viewers. The format between them is in
`LoopCtrlKit/BroadcastWire.swift`; the extension may use 50 MB, so it keeps
only the newest picture (for a keyframe on a still screen, or a viewer who
joins one) and drops frames the runner hasn't taken yet.

They meet on loopback port 48300. No App Group is needed, so re-signing stays
as it is. The runner takes one connection at a time, and only while the
screen is being captured (`UIScreen.isCaptured`): another app could reach a
loopback port, but not make the screen be recorded. Turning the switch off
ends a running broadcast.

## Direct on the LAN

A page opened through the relay is served over HTTPS, which the browser needs
for WebCodecs (the lowest-latency player). When the phone is on a LAN, its
`STATE` lists where it answers there (`lan`, from the Wi-Fi or hotspot
interface, only with remote access on). The page then tries each address
with an ordinary `device_info` RPC, answered under the page's own pairing key,
so a reply proves it is this phone. If one answers within 3 s, the page sends
its RPC and its stream there instead of through the relay, and the subtitle
says Direct.

Chrome and Edge allow an HTTPS page to reach a private address over plain
HTTP once the user allows local network access (the browser asks the first
time); the page passes `targetAddressSpace: "local"`, and the runner answers
the preflight with `Access-Control-Allow-Private-Network: true` and serves
`/stream` with `Access-Control-Allow-Origin: *` (`/rpc` already had it; both
are locked by the pairing key and the single-use ticket). Safari and Firefox
refuse such requests, and those pages stay on the relay.

A failed request, a stream that ends or falls silent, or an address that
leaves `lan` sends the page back to the relay at once, and it tries the LAN
again a minute later (20 s after a try that found nothing). Viewers on the LAN and on the relay each have their own
encoder, so both get what their link carries.

## Control

Several people and agents may drive the phone at once
(`LoopCtrlKit/RemoteSession.swift`); the phone keeps track of who is there
and what each of them did.

- **Who is there.** A paired client counts as *operating* for 60 s after its
  last action if it is a person (the page sends `manual:true`), 30 s if it is
  an agent, and as *watching* while it has the screen stream open. The
  stream's `STATE` message lists them (`people: [{tok, name, kind, watching,
  operating, since, actions}]`), and the page shows how many operate and
  watch in a pill next to the phone's name (on a narrow screen, as a hand and
  an eye with a count each).
- **Each one's log.** Every touch, key and button is recorded under the
  client that sent it, with where it touched (never what was typed: typing
  is logged by length) and its [outcome](#action-outcomes): the newest 500
  per client, in memory while the runner runs, and as a line in the runner's
  log (`👤 <name>: tap (120, 300) → applied`). `control {action:"log"}`
  returns them, one list per client; the page's pill opens them.
- **The owner's pause.** While anyone watches or drives remotely, the phone
  shows a notification with **Pause remote control**. Pausing ends everyone's
  operating spell and stops everything remote: no frames are captured or
  sent, and every method except `control`, `device_info`, `logs`, `config`,
  `stream_ack`, `stream_ticket`, `is_locked` and `wait` returns
  `paused_by_owner` (-32003), for agents on the phone itself too. Resuming
  from the notification needs the phone unlocked.

On iOS 16.2 and later, a **Live Activity** shows this on the Lock Screen and
in the Dynamic Island: who is operating, how many watch, for how long, and
(iOS 17) Pause and Resume buttons; Resume asks for the phone to be unlocked.
iOS starts Live Activities only for an app in front, so it starts with the
service (or the next time LoopCtrl is opened) and waits idle; iOS ends it
after 8 hours. It lights up once when remote use starts.

Where the Live Activity isn't up (turned off in Settings, older iOS, past its
8 hours), a notification says the same, with the same buttons. It alerts
once, when remote use starts. After that it is replaced silently as people
come and go (`2 operating · 3 watching`), and it stays for 30 s after the
last one leaves, so reloading the page or switching quality doesn't alert
again.

The stream's `STATE` message carries both, so the page updates without
polling. `hidden` is the third field: see [View tree](#view-tree).

### Action outcomes

Every reply to a touch says what happened to it, in `outcome` (in `result`
on success, in the error's `data` otherwise), with `retry_safe`:

| `outcome` | Meaning | `retry_safe` |
|---|---|---|
| `applied` | The phone performed it. | — |
| `failed` | It was rejected before anything happened (a point off the screen, a bad argument). | yes |
| `not_sent` | Refused before it reached the screen: `paused_by_owner`. | yes |
| `queued` | Accepted but timed out waiting for its turn on the main thread; it may still run. | no |
| `unknown` | Sent, but no answer came back. | no |

The page stops its queue and says so on `queued` or `unknown`, and never
sends that touch again on its own.

### Gestures

The page sends one finger that stays put as `tap` or `long_press`, and
anything else as one `gesture`: every finger's real path (`[{x, y, t}, …]`
in points, `t` in seconds), up to five fingers, synthesized as one event so
a curved drag, a pinch or a two-finger hold arrives as drawn. With a mouse,
holding Alt/Option while dragging adds a mirrored second finger: a pinch.

The toolbar also has **App switcher** (`app_switcher`: up from the bottom
edge and a short hold, as a person does), **Notification Center**
(`notification_center`: down from the top edge), **Control Center**
(`control_center`: down from the top-right corner, or up from the bottom on a
phone with a Home button) and **Rotate** (`rotate`: between portrait and
landscape, or to a given `orientation`). Whether the interface turns is
up to the app in front; the reply gives the screen size afterwards.

## View tree

The page reads `page_source{visible_only:true}` and parses its lines
(`Type, label: '…', value: '…', id: '…', {{x, y}, {w, h}}`, two spaces of
indent per level). It lists the elements, outlines the one under the pointer
on the screen, taps an element's centre when you choose it, and can draw every
frame as a wireframe for screens that black out capture.

The runner notices those screens itself: when a captured frame is almost
entirely black (16 × 16 samples, every channel at most 24), `STATE` carries
`hidden: true`, and the page turns the outlines on until the screen comes
back.

## Recording

**Record** on the page captures the touches, typing and buttons a person
sends, with the pause before each. When it stops, the recording can be
replayed on the spot or downloaded as JSON:

```json
{"loopctrl_flow": 1, "device": "iPhone", "recorded": "2026-10-27T05:12:00Z",
 "steps": [{"method": "tap", "params": {"x": 203.5, "y": 276.6, "settle": false, "manual": true}, "wait": 0.8}]}
```

Each step is the RPC call the page made, so any client can replay a file by
making the same calls. A file can be edited to add `wait` steps
(`{"method": "wait", "params": {"text": "Done", "timeout": 20}}`), so a
replay waits for a screen instead of relying on the recorded pauses. Screen settings › **Replay a recording** runs a
saved file; pauses longer than 10 s are shortened to 10 s, and the first
failed step stops the replay.

## Page

`LoopCtrlKit/RemoteHTML.swift` is one self-contained page with no external
requests. It follows miuix's look (HyperOS: colours, corner radii, cards,
segmented controls, dialogs and bottom sheets), in plain CSS: miuix itself is
Compose Multiplatform, whose web build would be several megabytes of Wasm for
the phone to serve. Light and dark follow the system, or the choice under
Screen settings › Appearance. At phone width the toolbar moves to the bottom
and the view tree opens as a sheet.

**Layout.** The phones on the left, the screen in the middle, the tools on
the right (with the view tree beside them). Below 1100 px wide the phone list
and the view tree become drawers (the phone's name at the top left opens the
list); a phone held upright has the tools under the screen and the view tree
as a bottom sheet; held sideways, the tools stay on the right so the screen
keeps the full height.

**Several phones.** The page lists every phone opened in this browser on this
site, with whether it is online (`GET whoami` on its page's address), and
switches by opening that phone's page. Behind one relay every phone shares
the site, so each one's page lists them all; a phone at another address (a
LAN or tailnet IP) can be added by its URL. Each phone's pairing key is kept
under its own device id, so pairing one doesn't replace another's.

**Offline phone.** A service worker (`GET /remote-sw.js`, secure contexts
only) keeps a copy of the page. When the phone can't be reached — the relay
answers 503 for it — the copy opens instead of an error: the screen says the
phone isn't connected, everything around it still works, and the page reloads
by itself when the phone is back. Pairing likewise takes the screen's place,
not the whole page.

**Page updates.** The page ships inside the app, but a newer one can be
pushed to a phone without reinstalling (`LoopCtrlKit/PageUpdate.swift`):

```bash
make page-push HOST=https://relay.example.com/d/<slug>/
```

signs the page in `RemoteHTML.swift` (`Scripts/page-update.swift`, Ed25519
with the key in `~/.loopctrl-keys/page-update.key`, which never goes into the
repository) and calls `page_update` with it, as a paired client
(`Scripts/loopctrl_rpc.py pair` once). The phone takes only a page signed
with that key whose version (the push time, `yyyyMMddHHmm`) is newer than
what it serves, stores it, and serves it from then on; `page_update
{reset:true}` goes back to the app's own page, and a page pushed before the
app was last built gives way to the app's. Open pages learn of it from the
stream's `STATE` (`page`) and offer a reload. Only the page updates this way:
anything in the app or the runner still needs a new build.

The first time a browser opens the page, a short guide points at each part
of it in turn (Screen settings › **Show the guide again** repeats it). The
buttons show icons, text, or both (Screen settings › **Buttons**; both by
default on a wide screen with a mouse). The status line under the phone's
name gives the connection, the codec, the frame rate and the round trip.
