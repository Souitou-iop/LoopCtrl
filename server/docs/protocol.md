# Protocol overview

Three layers, each defined in one place.

```
operator ──(1) LoopCtrl v1: pairing + sealed JSON-RPC, end to end──▶ runner on the phone
   │                                                                     ▲
   └──(2) transport: relay tunnel  ─or─  tailnet (WireGuard) ──────────┘
          (3) enrollment: invite → preview → redeem   (relay only)
```

## 1. LoopCtrl protocol v1 (end to end)

What actually controls the phone. The runner serves JSON-RPC on port 8300.
An operator pairs once (X25519 key agreement; the phone's user approves, or a
relay invite pre-approves) and then seals every request and response with an
HMAC-SHA256 based envelope keyed by the pairing secret. Neither transport can
read or forge it.

- Reference client: [`cli/loopctrl_rpc.py`](../cli/loopctrl_rpc.py), a copy of
  LoopCtrl's `Scripts/loopctrl_rpc.py`. **LoopCtrl's copy is canonical**: it
  changes together with the app.
- Method list: LoopCtrl's `SKILL.md`.

## 2. Transports

- **Relay** (`connect/relay/`): the phone keeps one WebSocket open to the
  relay. Each HTTP request to the phone's public address
  (`https://<slug>.<relay domain>/…`, or `…/d/<slug>/…`) travels down it as a
  stream and reaches the runner unchanged; the response comes back the same
  way, with per-stream flow control. So a browser gets the control page, the
  screen stream and `/rpc` exactly as on the LAN. The tunnel protocol is in
  LoopCtrl's
  [docs/remote-control.md](../../docs/remote-control.md#tunnel-protocol-v1).
- **Tailnet** (`connect/headscale/`): plain TCP to `100.64.x.y:8300` over
  WireGuard. Headscale only coordinates keys and the DERP relay; the ACL limits
  operators to port 8300 on customer phones.

The runner records which way a request came in (`relay`, `tailnet`, `lan`, …)
and shows it in the pairing prompt. Relay pre-approval applies only to
requests that came through the relay.

## 3. Relay enrollment (API v1)

The invite (`loopctrl://connect?v=1&server=…&code=…&op=…`), what the app
checks, and every relay endpoint with its request, response, signature and
error format are specified in LoopCtrl's
**[docs/relay-enrollment.md](../../docs/relay-enrollment.md)**.
That page is the client contract and the **source of truth**; the relay
deliberately keeps no copy, so the two can't drift. The reference relay here
implements exactly that API, and `connect/relay/relay_test.go` exercises it.

In short:

1. An operator mints a one-time code naming the operator keys (full SHA-256 of
   each operator's X25519 pairing public key) the phone should trust.
2. The phone previews it, the user confirms, and the phone redeems it with an
   Ed25519 key it generated, signing over the relay's public name.
3. The phone authenticates with that key (challenge, signature, short-lived
   token) whenever it opens the tunnel.
4. The app refuses to connect if the relay reports operators other than the
   ones in the invite, so a malicious relay can't substitute its own key.

Optional `pin=` in the invite pins the relay's certificate SPKI:

```sh
openssl x509 -in fullchain.pem -pubkey -noout | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary | base64
```

## Versioning

The relay's `GET /healthz` reports `"api": 1` and `"tunnel": 1`. A breaking
change to the enrollment API bumps `api` and the `/v1/` prefix together, and
lands in LoopCtrl's `docs/relay-enrollment.md` first; one to the tunnel bumps
`tunnel` and its WebSocket subprotocol (`loopctrl-tunnel-v1`), and lands in
LoopCtrl's `docs/remote-control.md` first.
