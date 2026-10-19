# Remote service: invites and relay enrollment

LoopCtrl can be controlled from another network through a **relay**. The app
has no server built in. A customer connects to a hosted service or to a relay
they run themselves. Both go through the same invite and the same checks.

This page describes:

- the invite a relay hands out;
- what the app checks before it connects;
- the HTTPS API a relay must provide so the app can enroll with it.

Anyone self-hosting a relay can implement the API from this page.

> Status: implemented on both sides. The app's client is
> `RelayRemoteServiceClient`. The reference relay lives in
> [LoopCtrl-Server](https://github.com/Souitou-iop/LoopCtrl-Server): `connect/relay/loopctrl_relay_server.py`
> (Python standard library only) serves exactly this API, with
> `connect/relay/selftest.py` as its test and `connect/relay/relay_operator.py`
> as an operator client. **This page is the canonical contract**; LoopCtrl-Server
> links here rather than keeping a copy. The channel is a repeated HTTPS poll, not a WebSocket. Relayed
> requests reach the runner in-process, so only the all-in-one build can take
> them for now.

## Trust model

- **The relay is untrusted.** It forwards bytes. Pairing (`POST /pair`, X25519)
  and the v1 envelope stay end to end between the operator's client and the
  runner on the phone, exactly as on the LAN. The relay never holds a pairing
  key.
- **The invite is the trust anchor, not the server.** The invite names the
  operators, by key. The app refuses to connect if the server reports different
  operators, so a malicious relay can't substitute its own key.
- **Pre-approval is narrow.** Confirming an invite pre-approves exactly the
  invite's operator keys. It applies only to pairing requests that arrive
  **through the relay**. The same key on the LAN, or any other key through the
  relay, still needs the user's tap on the phone.
- **No long-lived secret in the invite.** The invite carries a one-time code.
  The phone's long-lived credential is an Ed25519 key it generates itself and
  keeps in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).

## The invite

### Link (and QR code)

```
loopctrl://connect?v=1&server=<host[:port][/path]>&code=<code>&op=<keyID>[,<keyID>…]&pin=<spki>&exp=<unix>
```

| Param | Required | Meaning |
|---|---|---|
| `v` | no (default 1) | Invite version. The app refuses any other value with "needs a newer version". |
| `server` | yes | The relay's host, optionally with a port and a path prefix: `relay.example.com`, `relay.example.com:8443`, `example.com/loopctrl-relay` (a relay behind a reverse-proxy location). `https://` is accepted and implied. Path segments are letters, digits and `-._~` only, never `.` or `..`. No query, fragment or user info. |
| `code` | yes | One-time connection code (see below). Hyphens and spaces are ignored. |
| `op` | no | Comma-separated operator key IDs: the full SHA-256 of each operator's X25519 public key, 64 lower-case hex characters. This is the key their client sends in `POST /pair`, hashed. The 8-hex fingerprint shown in prompts is only its prefix. It is too short to bind anything to and is rejected here. |
| `pin` | no | SHA-256 of the relay certificate's SubjectPublicKeyInfo (DER), as 64 hex characters or base64/base64url (padding optional). When present, the app refuses a server that presents any other key. |
| `exp` | no | When the code stops working, in Unix seconds. An expired invite is refused before anything is sent. |

`loopctrl-app://connect?…` is accepted too. That is the scheme of the
two-IPA build, where `loopctrl://` belongs to the runner.

A QR code holds the link as plain text.

### Text form

A person can also paste the invite as a sentence. The app recognises it
anywhere in the pasted text:

```
LoopCtrl 连接邀请 · 服务器 relay.example.com · 连接码 7K3M-9QX2 · 10 分钟内有效
LoopCtrl 連線邀請 · 伺服器 relay.example.com · 連線碼 7K3M-9QX2 · 10 分鐘內有效
LoopCtrl connection invite · Server relay.example.com · Code 7K3M-9QX2 · valid for 10 minutes
```

The labels it looks for are 服务器/伺服器/Server and 连接码/連線碼/Code. A colon
after a label is optional. An optional 操作员/操作員/Operator label followed by
64-hex key IDs adds `op`. If a `loopctrl://connect?…` link appears in the
text, the link wins.

Text without `op`, and a server and code typed in by hand, carry no operators.
The app then shows the server's operators with 「请核对操作员指纹」 and
**pre-approves nobody**. Each operator is asked about on the phone the first
time they pair. Hand out links or QR codes when you want operators to connect
without a prompt.

### Connection code

- 8 characters of Crockford base32: `0-9 A-H J K M N P-T V-Z`. No I, L, O or U.
- The app upper-cases what the user typed and maps `O→0` and `I/L→1`. It
  ignores hyphens, so display codes as `7K3M-9QX2`.
- Single use, short-lived (10 minutes is a good default), and rate-limited per
  source address. 40 bits is enough only because of the rate limit and the
  short lifetime.

### What the app rejects

| Invite problem | Message |
|---|---|
| Not an invite | 这不是 LoopCtrl 连接邀请。 |
| `v` other than 1 | 这份邀请需要更新版本的 LoopCtrl。 |
| No / malformed `server` (bad host, `..` or odd characters in the path) | 邀请中缺少服务器地址。 / 服务器地址无效。 |
| `http://` (or any non-https scheme) | 只允许 HTTPS 服务器。 HTTP is allowed only for `localhost`, `127.0.0.0/8` and `[::1]`, and only in DEBUG builds. |
| No / malformed code | 邀请中缺少连接码。 / 连接码由 8 位字母和数字组成… |
| `op` entry not 64 hex | 邀请中的操作员指纹格式不正确。 |
| Malformed `pin` | 邀请中的证书固定值格式不正确。 |
| `exp` in the past | 这份邀请已过期，请索取新的邀请。 |

The parser is `LoopCtrlKit/RemoteInvite.swift`. It is tested in
`Tests/LoopCtrlKitTests/RemoteInviteTests.swift`.

## Enrollment, step by step

1. **Preview.** The app calls `POST /v1/enroll/preview` with the code. It
   shows the confirmation screen:
   - the server **from the invite** (never from the response), large, with a
     lock for HTTPS or a shield when the certificate is pinned;
   - the organisation, labelled 「由服务器提供」 because it is only the server's
     word;
   - each operator with name and fingerprint, marked 「✓ 与邀请一致」;
   - what the operator will be able to do;
   - 「服务器只负责转发，看不到你的操作内容；只有上面这位操作员能控制这台手机」.

   The operators are compared with the invite's `op` by full key ID; names play
   no part. If the server adds, drops or swaps a key, the app shows 「已拒绝连接」
   and offers only Cancel (`OperatorCheck.verify`).
2. **连接.** The app:
   1. creates the device key (Ed25519) and stores it in the Keychain;
   2. redeems the code (`POST /v1/enroll/redeem`) with the public key. It
      checks the operators in the reply **again**: a server that previews one
      set and enrolls another is refused;
   3. opens the relay channel;
   4. pre-approves exactly the invite's operator key IDs on the runner (see
      [Pre-approval on the phone](#pre-approval-on-the-phone)).
3. From then on the phone authenticates with its device key. It does not need
   an invite again unless the user taps 解除绑定.

## Relay API (v1)

All endpoints are HTTPS under the invite's `server`, path prefix included:
with `server=example.com/loopctrl-relay`, preview is
`https://example.com/loopctrl-relay/v1/enroll/preview`. Bodies are JSON in
UTF-8. Times are Unix seconds. Binary values are base64url without padding
unless noted.

**The server name.** Every signature the phone makes ends with the relay's
name exactly as the invite gives it, normalised: `host[:port][/path]`, no
scheme, lower-case host, no trailing slash (`RemoteInvite.serverName`). A
relay checks signatures against its own public name (`--public-server` in the
reference relay), so a signature made for one relay is useless at another.

### `POST /v1/enroll/preview`

Look at a code without spending it.

```json
{ "code": "7K3M9QX2" }
```

The relay normalises the code the way the app does (upper case, no `-`,
`O→0`, `I/L→1`). `200`:

```json
{
  "organization": "Example Ops",
  "operators": [
    { "name": "Alex Chen", "key_id": "3f9a6c0d…a65" }
  ],
  "capabilities": ["view_screen", "control", "launch_apps", "read_text"],
  "code_expires_at": 1800000600
}
```

- `operators[].key_id` is required. It is the same 64-hex SHA-256 the invite's
  `op` carries.
- `capabilities` are shown as a list. Known values are `view_screen`,
  `control`, `launch_apps` and `read_text`. Unknown values are ignored.
- The response must not depend on who asks. Preview is unauthenticated, so
  rate-limit it like redeem.

### `POST /v1/enroll/redeem`

Spend the code and register the phone.

```json
{
  "code": "7K3M9QX2",
  "device_public_key": "<32-byte Ed25519 public key>",
  "device_name": "iPhone",
  "proof": "<Ed25519 signature>"
}
```

`proof` signs the UTF-8 string `loopctrl-enroll-v1\n<code>\n<server name>`
with the device key, the code in its 8-character form. It shows the redeemer
holds the key it registers, and binds the redemption to this relay. The relay
checks the proof **before** spending the code, so a bad proof can't burn it.

`200`:

```json
{
  "device_id": "dev_8f3a1c22e1b04d7a",
  "organization": "Example Ops",
  "operators": [ { "name": "Alex Chen", "key_id": "3f9a6c0d…a65" } ],
  "poll_timeout": 25
}
```

The code is now spent, whether or not the phone ever connects. A second
redeem answers `410 expired_code`.

### Channel

The phone keeps no socket open. It signs in with its key, then asks for work
one held request at a time.

1. **`POST /v1/device/challenge`** `{"device_id": "…"}` → `200
   {"nonce": "<32 bytes>", "expires_in": 60}`. `404 unknown_device` means the
   relay no longer knows this phone: the app shows 「服务器断开了连接」 and stops.
2. **`POST /v1/device/session`**
   `{"device_id": "…", "nonce": "…", "sig": "<Ed25519>"}`, where `sig` signs
   `loopctrl-channel-v1\n<nonce as sent>\n<server name>`. → `200
   {"device_token": "…", "expires_in": 3600, "poll_timeout": 25}`. The nonce
   is single use. Signing in again replaces the token and keeps any work
   already queued.
3. **`POST /v1/device/poll`** with `Authorization: Bearer <device_token>`. The
   relay holds the request until an operator sends something, at most
   `poll_timeout` seconds, then answers either `204` (nothing; poll again) or
   `200`:

   ```json
   {"request_id": "<32 hex>", "path": "/pair", "body_b64": "<standard base64>"}
   ```

   `path` is `/pair` or `/rpc`. The body is the operator's request, byte for
   byte. The phone hands it to its runner as a request with source
   `PeerSource.relay` (never through loopback, which would make it `local`).
   Over it the operator runs the ordinary protocol: `/pair` with its X25519
   key, then v1 envelopes, which the relay can't read. `401` means the token
   lapsed: sign in again.
4. **`POST /v1/device/response`** with the same bearer:
   `{"request_id": "…", "status": 200, "body_b64": "…", "content_type": "application/json"}`.
   Each request ID is answered once; a second answer is `404`.

The phone answers in the background and polls again at once, so a pairing
prompt waiting for the user doesn't hold up other requests. The token is
extended by every use. If a poll fails for any other reason, the app signs in
again and retries, up to 5 times with backoff (1, 2, 4, 8, 16 s), before it
shows 「无法连接服务器」. Each successful retry counts toward 「24 小时内重连」.

The latency the home card shows is the round trip of the sign-in, then of a
`GET /healthz` every 30 s. 「XX 正在操作」 comes from the relayed traffic
itself, not from the relay's word: a `/pair` that succeeds with one of the
connection's operator keys names the operator, and later envelopes carry the
session id it was given. After 2 minutes without a request the operator is
shown as gone. This is display only. What an operator can do is decided by
pairing and the envelope.

### `DELETE /v1/devices/{device_id}`

Unbind. Send the header
`Authorization: LoopCtrl-Device sig=<Ed25519>, ts=<unix time>`, where `sig`
signs `loopctrl-unbind-v1\n<device_id>\n<ts>\n<server name>` and `ts` is
within 5 minutes of the relay's clock. The relay drops the device record,
wakes any operator request waiting for it with `410`, and forgets its token.
The app removes its own state whether or not this call succeeds.

### Operator side

How operators reach a phone is up to the relay; the phone never sees it. The
reference relay uses one shared operator token
(`Authorization: Bearer <LOOPCTRL_RELAY_OPERATOR_TOKEN>`):

| Call | Purpose |
|---|---|
| `POST /v1/admin/enrollments` `{"operators": [{"name", "key_id"}], "organization"?, "capabilities"?, "expires_in"?}` | Mint a code. `201 {"code", "display_code", "expires_at", "server", "invite"}`; `invite` is the ready `loopctrl://connect?…` link. Default lifetime 10 minutes, at most a day. |
| `GET /v1/admin/devices` | Enrolled phones: id, name, organization, operators, whether one is polling. |
| `POST /v1/operator/devices/{id}/pair`, `…/rpc` | Send one `/pair` or `/rpc` body to the phone and wait (90 s at most) for its answer, returned as the phone sent it. `503 device_offline` when the phone has no live channel, `504 device_timeout` when it didn't answer. |
| `GET /healthz` | `{"ok": true, "api": 1, "server": "<its name>"}` |

LoopCtrl-Server's `connect/relay/relay_operator.py` (`cli/loopctrl relay …`) drives these: `enroll --name …` prints the invite
with the operator's key ID in `op`, `pair` and `call` talk to the phone.

### Errors

Errors use `{"error": "<code>", "message": "…"}`:

| HTTP | `error` | App shows |
|---|---|---|
| 404 | `invalid_code` | 连接码无效。请检查，或索取新的邀请。 |
| 410 | `expired_code` (also: already used) | 这份邀请已过期或已被使用，请索取新的邀请。 |
| 400 | `bad_proof`, `bad_request` | 服务器返回了无法识别的内容。 |
| 404 | `unknown_device` (challenge/session) | 服务器断开了连接。 |
| 401 | `bad_challenge`, `bad_signature`, `ts_skew` | Retried, then 无法连接服务器。 |
| 429 | `rate_limited` | 无法连接服务器，请检查地址和网络。 |
| — | TLS failure | 无法验证服务器证书（TLS 错误）。 |
| — | pin mismatch | 服务器证书与邀请中固定的证书不一致。 |
| — | connect/timeout | 无法连接服务器，请检查地址和网络。 |
| — | operators differ from `op` | 服务器返回的操作员与邀请不一致，已拒绝连接。 |

The reference relay allows 20 preview/redeem calls and 60 challenge/session
calls per source address per minute (behind nginx, the address in
`X-Real-IP`).

## Pre-approval on the phone

The runner keeps a standing list of `(connection, operator name, key ID)`. The
list is `PairRequestLedger.preApprovals`, persisted in the runner process's
defaults under `relayPreApprovals`.

- `requestAuth` lets a request in **without a prompt** only when all of these
  hold:
  - its source is `relay`;
  - it came through the connection whose entry it matches (the relay
    transport names the connection; one relay's channel can't use another's
    pre-approval);
  - its key ID is on the list and matches in full.

  The session it creates remembers the connection (`relay_connection`).
- A request from any other source with the same key is prompted as usual. So
  is any other key through the relay.
- 解除绑定 removes the connection's entries and revokes every session they let in.

The app changes the list through the runner's `config`. The runner accepts
these parameters only from this device (`_peer_source == local`), like
`pair_respond`:

| Param | Meaning |
|---|---|
| `relay_preapprove: {"connection_id": "…", "operators": [{"name": "…", "key_id": "<64 hex>"}]}` | Replace that connection's pre-approved operators. Entries that are not 64 hex characters are dropped. |
| `relay_revoke: "<connection_id>"` or `["<id>", …]` | Unbind: drop those connections' entries and revoke their sessions. The app sends a batch 解除绑定 as one call. |

From this device, the reply also carries
`relay_preapprovals: [{connection_id, name, key_id}]`. Each session row carries
`relay_connection`.

If the service isn't running when the user confirms an invite, the app keeps
the pre-approval pending. It sends the pre-approval the next time the service
is up. Until then those operators are asked about like anyone else.

The Authorization page lists the pre-approved operators with source 「中继」.
Clients that paired through the relay show the same source.

## Self-hosting checklist

- Serve the API over HTTPS with a certificate the phone trusts. Pin its SPKI in
  your invites (`pin=`) if you can: `openssl x509 -in cert.pem -pubkey -noout |
  openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`.
  Remember a pin breaks when the key changes (certbot renews with a new key
  unless told to reuse it).
- Tell the relay its public name, path prefix included. Every signature is
  bound to it.
- Generate codes from the Crockford alphabet. Make them single-use, expire them
  within minutes, and rate-limit preview and redeem.
- Put the full key ID of every operator in `op`, and return exactly those
  operators from preview and redeem.
- Never log or inspect relayed payloads. You can't read them after pairing
  anyway, and the phone says so to the user.

## Code

- `LoopCtrlKit/RemoteInvite.swift`: invite parsing and validation.
- `LoopCtrlKit/RemoteService.swift`:
  - `OperatorCheck` (the operator comparison);
  - `RemoteConnectionMachine` (connection states);
  - `RemoteServiceError`.
- `LoopCtrlKit/PairRequestLedger.swift` and `AuthManager.swift`: pre-approvals.
- `LoopCtrlApp/Models/RemoteServiceClient.swift`:
  - the protocol;
  - `RemoteConnection`;
  - the Keychain device key.
- `LoopCtrlApp/Models/RelayRemoteServiceClient.swift`: the client for this
  API (HTTPS with SPKI capture and pinning, the channel, the hand-off to the
  runner).
- `LoopCtrlKit/JSONRPCServer.swift` `handleRelayed`, reached through
  `InProcessRunnerControl.relayed`: where relayed requests enter the runner.
- `LoopCtrlApp/Models/MockRemoteServiceClient.swift`: the mock relay, for
  clicking through every screen and failure without a server. Off by default:
  long-press the footer of Settings › 远程服务 for 2 s to turn it on, then
  relaunch. In DEBUG the demo launch arguments turn it on too.
- [LoopCtrl-Server](https://github.com/Souitou-iop/LoopCtrl-Server) `connect/relay/`: the reference relay, its
  self-test and an operator client.
- `LoopCtrlApp/Models/RemoteServiceStore.swift`: enrollment, the channel and
  the log.
- `LoopCtrlApp/Views/RemoteServiceViews.swift`:
  - the home card;
  - the add sheet;
  - the confirmation screen;
  - Settings › 远程服务.
