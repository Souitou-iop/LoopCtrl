# Phase 0 relay transport prototype

Status: prototype, not a product. It proves one path and nothing else.

Companion to `docs/in-app-qr-relay-feasibility.md`, which is the design note.
This file describes what is actually implemented on this branch, how to run it,
and what is deliberately missing.

## What this proves

```text
operator (relay/relay_operator.py)
        |
        | HTTPS/HTTP + operator bearer token
        v
LoopCtrl relay (relay/loopctrl_relay_server.py)
        ^
        | outbound repeated poll, device bearer token
        |
LoopCtrl on iPhone (LoopCtrlKit/RelayRPCClient.swift)
        |
        | http://127.0.0.1:<port>/rpc, unchanged v1 envelope
        v
existing JSONRPCServer / AuthManager / SecureEnvelope path
```

The only new thing in the data path is a store-and-forward hop. The relay does
not know the LoopCtrl pairing key, cannot open an envelope, and cannot call an
RPC method. It moves `POST /rpc` request bytes to the device and moves the
response bytes back.

That is the whole Phase 0 claim: *the existing encrypted request/response
survives an untrusted intermediate hop.*

## Relay wire protocol (v0, prototype)

All bodies are JSON. All authenticated calls use `Authorization: Bearer <token>`.

| Method | Path | Who | Purpose |
| --- | --- | --- | --- |
| `GET` | `/healthz` | anyone | liveness; no secrets |
| `POST` | `/v1/admin/enrollments` | operator | mint a single-use enrollment token |
| `POST` | `/v1/device/register` | device, enrollment token | exchange it for a short-lived device token |
| `POST` | `/v1/device/poll` | device, device token | server-held poll; `200` with work, `204` when idle |
| `POST` | `/v1/device/response` | device, device token | return the opaque response |
| `POST` | `/v1/operator/devices/<id>/rpc` | operator | send an opaque request, wait for its response |
| `GET` | `/v1/admin/devices` | operator | list live sessions (ids, names, pending counts) |

`POST /v1/device/poll` returns:

```json
{"request_id": "<32 hex chars>", "body_b64": "<opaque request>", "expires_in": 3600}
```

`POST /v1/device/response` sends back:

```json
{"request_id": "...", "status": 200, "body_b64": "<opaque response>", "content_type": "application/json"}
```

The device token is the only credential the relay gives a device. It is random,
short-lived (`--device-ttl`, default 3600 s), extended on every authenticated
use, and stored by the relay as a SHA-256 digest — never in the clear. The
default deliberately exceeds Phase 0's 30-minute background criterion: a phone
that is suspended for >3 minutes must not need to redeem a new enrollment token.
Enrollment tokens are single-use: `register` removes the digest as it consumes
it. Unknown, expired, and already-consumed tokens all answer a plain `401` with
no distinction, so the relay does not confirm which tokens exist.

The relay stores nothing on disk and logs no tokens or bodies. Access logging is
off unless `LOOPCTRL_RELAY_ACCESS_LOG=1` is set for a debugging session.

## Running it locally

Requirements: Python 3.11+ (stdlib only; nothing to install).

### 1. Self-test (no iPhone, no Swift)

```sh
cd <repo>
python3 relay/selftest.py
```

Runs the relay in-process on a random loopback port and exercises enrollment,
registration, single-use enforcement, a server-held HTTP poll, opaque byte
forwarding, response return, rejection of unknown operator/device tokens, and
a simulated 31-minute no-poll gap.

### Poll transport and timeout contract

`POST /v1/device/poll` is not a WebSocket and not a persistent connection. Each
poll is one ordinary HTTP request. The server may hold that request for up to
its `poll_timeout` (default 25 s) while waiting for operator work, then answers
`204 No Content`; the exchange closes. Repeat requests after each `204`.

This prototype does **not** prove that a TCP/TLS socket survives iOS
backgrounding. It only proves the request/response cycle and envelope forwarding.
A background test must show that the app can *re-establish each poll request*
after suspension; a held-open socket is neither required nor claimed.

Registration returns `poll_timeout` so the client and server agree. The Swift
client sets its poll `URLRequest.timeoutInterval` to the advertised
`poll_timeout` plus a 15-second response grace (minimum 12 seconds). This is
longer than the server hold by construction, avoiding a client timeout while
the server is still legitimately waiting. Registration and response-upload
requests use the independent 90-second `requestTimeout`.

If the client's poll request times out before work is handed out, that cycle
ends without a server response; the operator's request may still be pending for
the server-side operator timeout. The next poll is a new HTTP request. The
client never reuses a request ID, and the relay rejects a second response to
the same ID. This is why the server-advertised wait plus grace is explicit and
tested rather than implicit in a hardcoded timeout.

### 2. Relay + operator client by hand

```sh
export LOOPCTRL_RELAY_OPERATOR_TOKEN="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
python3 relay/loopctrl_relay_server.py --bind 127.0.0.1 --port 8787
```

In a second shell (same environment variable):

```sh
python3 relay/relay_operator.py --enroll      # prints a single-use enrollment token
python3 relay/relay_operator.py --list        # live device sessions
python3 relay/relay_operator.py --device-id <id> --body-file envelope.json
```

`--body-file` is an already-sealed v1 envelope (the output of a real paired
client). The operator helper prints the opaque response to stdout; whoever owns
the pairing key decrypts it. The relay never sees the plaintext.

For a non-loopback test, front the relay with TLS. The prototype can also serve
TLS directly:

```sh
python3 relay/loopctrl_relay_server.py --bind 0.0.0.0 --port 8787 \
  --certfile /path/fullchain.pem --keyfile /path/privkey.pem
```

Use a throwaway certificate for that. Do not point this at any deployed
service, and do not reuse the production Headscale host or its nginx config.

## Swift side (device)

`LoopCtrlKit/RelayRPCClient.swift` is the outbound client.

- `RelayEnrollment(baseURL:token:expectedDeviceID:)` validates the enrollment
  values. The expected id is optional; with it, the client pins the id returned
  by registration.
  Non-loopback endpoints must be `https`; a `http` origin is accepted only for
  `127.0.0.1`/`localhost`/`::1`. There is no path, query, or userinfo.
- `start()` runs one register → poll → forward → respond loop, where each poll
  is a separate HTTP request, with a capped reconnect backoff. `stop()` cancels
  the current request and the loop.
- It forwards to `http://127.0.0.1:<rpcPort>/rpc` and returns the response
  verbatim. It does not parse, re-sign, or re-encrypt anything.
- A failure to reach the local server still answers the relay with a generic
  `502 {"error":"loopctrl_unavailable"}` so an operator request never hangs
  until timeout.

It is gated three ways, so existing direct/LAN/Tailnet behaviour is unchanged:

1. Nothing constructs it unless the host calls `AppState.startRelayIfConfigured()`.
2. That method requires a base URL and token (and optionally a pinned device id)
   and only runs when the in-process runner is the server (`LOOPCTRL_ALL_IN_ONE`).
3. The enrollment token is compiled into the app only in `DEBUG`
   (`@AppStorage("relayEnrollmentToken")`); Release builds never read one.

To drive it from a debug build without any UI, set the relevant `@AppStorage`
values in the app's own `UserDefaults` for the build you are running — for a
simulator that is `defaults write <bundle id> relayBaseURL "http://127.0.0.1:8787"`
plus `relayEnrollmentToken` (and optionally `relayExpectedDeviceID`), and on a
device the same keys via the Xcode scheme or a temporary debug-only field.
`relayBaseURL` and `relayExpectedDeviceID` are non-secret; only set
`relayEnrollmentToken` in a Debug build. Then start the service and watch
`Relay state:` lines in the app log.

### Honest limits

- **No QR scanner and no enrollment UI.** `RelayEnrollment` is the seam a
  scanner would write into.
- **No device public key binding.** Phase 1 in the design note. Today the
  device token proves "this device registered", not "this keypair enrolled".
- **No production auth.** One shared operator token from the environment. No
  tenant model, no operator accounts, no rate limiting beyond the pending cap.
- **No APNs / background wake.** The client is a foreground repeated-poll loop;
  each cycle is a separate HTTP request, not a live socket. See below.
- **No Tailscale integration and no Network Extension.** This is an application
  relay, not a VPN, and it does not compose with Shadowrocket's tunnel.
- **No live activity and no reconnect telemetry.**

## Test plan

| Layer | Command | Status on this branch |
| --- | --- | --- |
| Relay, automated | `python3 relay/selftest.py` | run, passes |
| Relay, syntax | `python3 -m py_compile relay/*.py` | run, passes |
| Poll timing arithmetic | `relay/check_swift_timeout.sh` | run, passes |
| Relay over TLS | see above, throwaway cert | not run here |
| Swift, compile | `xcodebuild … -destination generic/platform=iOS build` | see below |
| Swift, typecheck | `swiftc -typecheck` on the three files it needs | run, passes |
| Device end-to-end | real `/rpc` through the relay, then lock/background | not run here |

### Verified on this machine

- `python3 relay/selftest.py` — PASS (registration, single-use enrollment,
  server-held poll forwarding, opaque request/response bytes, a simulated
  31-minute no-poll gap, unknown-token rejection).
- `relay/check_swift_timeout.sh` — PASS (`server poll_timeout + 15 s grace`,
  with a 12-second floor).
- `swiftc -typecheck RelayRPCClient.swift SecureEnvelope.swift ServerPort.swift
  -target arm64-apple-ios16.0 -sdk <iphoneos sdk>` — no diagnostics.

### Not verified, and why

- **Any real device run, background survival, or Wi-Fi/cellular switch.** Phase
  0's stated exit criterion — a real `/rpc` call after 30 minutes in the
  background and after a network switch — is *not* met by this commit. The
  repeated-poll client is foreground-only and must not be described as
  always-on. The 60-minute device TTL is a prerequisite, not a substitute, for
  that device test.

### Full-build note

A full `xcodebuild` was run after symlinking the main checkout's gitignored
`Frameworks/IDevice.xcframework` as a local build aid. Debug (both schemes) and
Release (all-in-one) succeeded. The symlink is not committed.

## Deliberately not implemented

- Real QR scanning, camera permission, and a versioned QR payload.
- Production enrollment: device-key binding, revocation, tenants, quotas.
- APNs or any push-based wake-up; background execution of any kind.
- Tailscale/Headscale integration; the deployed server and its config are
  untouched by this branch.
- Network Extension / packet tunnel provider.
- Live Activity, metrics, and latency measurement.

## What to do next, before Phase 1

1. Run the full device test and record whether new poll requests can be issued
   after backgrounding and a Wi-Fi/cellular switch. Check both the app and relay
   logs for a request gap, since no persistent socket survival is assumed.
   Until that passes, this is a lab prototype.
2. Decide the enrollment credential's shape (device public key + short-lived
   token) so Phase 1 can bind it at registration.
3. Add per-device and per-operator rate limits before any shared deployment.
