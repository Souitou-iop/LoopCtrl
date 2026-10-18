# Remote service: invites and relay enrollment

LoopCtrl can be controlled from another network through a **relay**. The app
has no server built in. A customer connects to a hosted service or to a relay
they run themselves. Both go through the same invite and the same checks.

This page describes:

- the invite a relay hands out;
- what the app checks before it connects;
- the HTTPS API a relay must provide so the app can enroll with it.

Anyone self-hosting a relay can implement the API from this page.

> Status: the app side (invite parsing, the 远程服务 screens, pre-approval on
> the runner) is in place, behind `RemoteServiceClient`. The only client so far
> is `MockRemoteServiceClient`. The relay transport (prototype on
> `codex/qr-relay-feasibility`, then a WebSocket tunnel) will implement the
> same protocol against the API below.

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
loopctrl://connect?v=1&server=<host[:port]>&code=<code>&op=<keyID>[,<keyID>…]&pin=<spki>&exp=<unix>
```

| Param | Required | Meaning |
|---|---|---|
| `v` | no (default 1) | Invite version. The app refuses any other value with "needs a newer version". |
| `server` | yes | The relay's host, optionally with a port: `relay.example.com`, `relay.example.com:8443`. `https://` is accepted and implied. No path, query or user info. |
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
| No / malformed `server` | 邀请中缺少服务器地址。 / 服务器地址无效。 |
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

All endpoints are HTTPS on the invite's `server`, with JSON bodies in UTF-8.
Times are Unix seconds. Binary values are base64url without padding unless
noted.

### `POST /v1/enroll/preview`

Look at a code without spending it.

```json
{ "code": "7K3M9QX2" }
```

`200`:

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
  "device_name": "Ebato's iPhone",
  "proof": "<Ed25519 signature>"
}
```

`proof` signs the UTF-8 string `loopctrl-enroll-v1\n<code>\n<server host[:port]>`
with the device key. It shows the redeemer holds the key it registers, and
binds the redemption to this server name.

`200`:

```json
{
  "device_id": "dev_8f3a1c22e1",
  "organization": "Example Ops",
  "operators": [ { "name": "Alex Chen", "key_id": "3f9a6c0d…a65" } ],
  "channel": "wss://relay.example.com/v1/channel"
}
```

The code is now spent, whether or not the phone ever connects.

### Channel: `GET /v1/channel` (WebSocket)

1. The server sends `{"type":"challenge","nonce":"<32 bytes>"}`.
2. The phone answers with
   `{"type":"auth","device_id":"…","sig":"<Ed25519 over 'loopctrl-channel-v1\n' + nonce + '\n' + host>"}`.
3. After `{"type":"ready"}`, the relay multiplexes operator streams to the
   phone. Each stream is a byte pipe that the phone hands to its local server
   as if it were a TCP connection, with `PeerSource.relay` as the source. Over
   that pipe the operator runs the ordinary protocol: `/pair` with its X25519
   key, then v1 envelopes. The relay sees only that traffic, which is end-to-end
   encrypted after pairing.
4. Control messages the app understands, all optional:

   | Message | Meaning |
   |---|---|
   | `{"type":"operator","state":"start","key_id":"…","name":"…"}` | Operator began a session. The home card shows 「XX 正在操作」. |
   | `{"type":"operator","state":"end","key_id":"…"}` | Operator session ended. |
   | `{"type":"activity","text":"…"}` | One line for the phone's operation log. |
   | `{"type":"close","reason":"…"}` | Server is ending the channel. The app shows 「服务器断开了连接」 and stops reconnecting. |

   The relay is not trusted for any of these. They only affect what the phone
   displays. Control is still gated by pairing and the envelope.
5. Ping/pong at least every 30 s. The app shows the round trip as latency.

If the socket drops for any other reason, the app retries up to 5 times with
backoff before it reports 「无法连接服务器」. Each successful retry counts toward
「24 小时内重连」.

### `DELETE /v1/devices/{device_id}`

Unbind. Send the header `Authorization: LoopCtrl-Device sig=<Ed25519 over 'loopctrl-unbind-v1\n' + device_id + '\n' + <unix time>>, ts=<unix time>`.
The relay drops the device record and closes its channel. The app removes its
own state whether or not this call succeeds.

### Errors

Errors use `{"error": "<code>", "message": "…"}`:

| HTTP | `error` | App shows |
|---|---|---|
| 404 | `invalid_code` | 连接码无效。请检查，或索取新的邀请。 |
| 410 | `expired_code` (also: already used) | 这份邀请已过期或已被使用，请索取新的邀请。 |
| 429 | `rate_limited` | 无法连接服务器，请检查地址和网络。 |
| — | TLS failure | 无法验证服务器证书（TLS 错误）。 |
| — | pin mismatch | 服务器证书与邀请中固定的证书不一致。 |
| — | connect/timeout | 无法连接服务器，请检查地址和网络。 |
| — | operators differ from `op` | 服务器返回的操作员与邀请不一致，已拒绝连接。 |

## Pre-approval on the phone

The runner keeps a standing list of `(connection, operator name, key ID)`. The
list is `PairRequestLedger.preApprovals`, persisted in the runner process's
defaults under `relayPreApprovals`.

- `requestAuth` lets a request in **without a prompt** only when all of these
  hold:
  - its source is `relay`;
  - its key ID is on the list;
  - the key ID matches in full.

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
| `relay_revoke: "<connection_id>"` | Unbind: drop that connection's entries and revoke their sessions. |

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
  your invites (`pin=`) if you can.
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
- `LoopCtrlApp/Models/MockRemoteServiceClient.swift`: the mock relay. It is on
  in DEBUG builds. In Release builds, long-press the footer of Settings › 远程服务
  for 2 s to turn it on, then relaunch.
- `LoopCtrlApp/Models/RemoteServiceStore.swift`: enrollment, the channel and
  the log.
- `LoopCtrlApp/Views/RemoteServiceViews.swift`:
  - the home card;
  - the add sheet;
  - the confirmation screen;
  - Settings › 远程服务.
