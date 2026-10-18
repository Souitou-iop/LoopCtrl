# Pairing approval

Every new client has to be approved on the phone. This page covers what the
user can do when they missed the approval notification, and the rules that keep
approval something only the device owner can do.

## What the user sees

- **Pending card (home screen).** While a request waits, the home screen shows
  a card with the client name, where it came from (this device / USB, LAN,
  nearby, Tailscale, VPN, cellular, other), its address, the key fingerprint and
  a countdown. Allow and Deny settle the same request the notification would,
  and withdraw the notification. The card stays until the request is answered
  or times out, even if the notification was swiped away. Swiping the
  notification away does not deny the request; it keeps waiting.
- **Authorization page.** 「已授权 N 个客户端 >」 on the home screen (and
  Settings → Clients → Authorization) opens a page with:
  - the waiting request (same card);
  - recent requests from the last 10 minutes, each with its outcome (allowed,
    denied, timed out, allowed on retry). A denied or timed-out request with a
    key has **Allow This Client**;
  - every client holding a key: source, address, last active, when it was
    paired. Revoke one by swiping, or revoke all.

## Allowing a client after the fact

1. A request is denied or times out (60 s, `AuthManager.approvalTimeout`). The
   client gets `403 pair_denied`.
2. The user taps **Allow This Client** in the recent list within 10 minutes of
   the outcome. That arms a one-shot grant for 10 minutes from the tap.
3. The client runs `pair` again. If its public key matches, the request is
   approved at once: no prompt, no busy slot, no 15 s cooldown. The grant is
   then spent.

The grant is bound to `keyID`, the full SHA-256 of the client's X25519 public
key (`PairRequestLedger.keyID(forPublicKey:)`). The 8-hex fingerprint on screen
is only its prefix: it is short enough to grind a lookalike key, so it is never
what is matched. The client name plays no part, since a client can claim any
name. Holding the public key is not enough either: the device wraps the session
key against it, so only the holder of the private key can use what it is given.

For this to work the client must send the same key on its retry. The reference
clients keep the key of an unfinished pairing for 10 minutes and drop it once
pairing succeeds:

| Client | Where the pending key lives |
|---|---|
| `Scripts/loopctrl_rpc.py` | `~/.loopctrl/pending_pair.json` (0600), per device record and client name |
| `cli/loopctrl` | `~/.loopctrl/pending/<device record>` (0600) |
| LoopCtrl app, two-IPA build | in memory |

A third-party client that makes a fresh key per attempt still pairs normally;
its retry just won't match a grant.

### Plain loopback requests

`{"plain": true}` requests (loopback only, key returned in the clear) carry no
public key. There is nothing to bind an approval to, and the client name is
whatever the caller claims: any app on the phone, or any computer on USB, could
send the same one. So they are listed with their outcome but can **never** be
allowed after the fact. The page says so; the client has to ask again and be
answered while it waits.

## Who can answer

The app reads and answers requests through the runner's `config` RPC:

| Param | Meaning |
|---|---|
| `pair_respond: {"request_id": "...", "allow": true\|false}` | Answer the waiting request, as the notification would. |
| `pair_allow_recent: "<request_id>"` | Arm the after-the-fact grant for a recent request. |

The reply adds `pairing: {pending: [...], recent: [...], approval_timeout, recent_window}`
and, after one of the params above, `pairing_applied: bool`.

Both params, and the `pairing` field, are accepted only from **this device**: the
`_peer_source` that the server sets after authentication (it overwrites any
value the caller sent) must be `local`.

- **All-in-one build.** The app calls `config` in-process through
  `InProcessRunnerControl.rpc`. That is a `NotificationCenter.default`
  notification, which another app can't post, and the observer sets the source
  to `local` itself.
- **Two-IPA build.** The app is a paired client of the runner and calls over
  loopback (`127.0.0.1`), so its source is `local`.

A client asking to pair has no key yet, so it can't reach `config` at all and
can't approve itself. A client already paired over the network (LAN, nearby,
Tailscale) gets an error from these params and no `pairing` field. What is left
is a client that is already paired and connects over loopback, such as a
computer on USB. It can answer requests, but it could already tap the
notification's Allow button through UI automation, so this gives it no new power.

## Sources

`source` is the `PeerSource` of the connection. One addition: a VPN tunnel
address in Tailscale's ranges (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`, which
the project's Headscale also hands out) shows as **Tailscale** (`tailnet`).
Traffic relayed through DERP arrives on the same tailnet address, so the phone
can't tell it from a direct tailnet connection, and it shows as Tailscale too.

A client that comes through a remote service relay has source **Relay**
(`relay`, 「中继」). The relay transport sets this source itself; the server never
works it out from the network interface. Operators named in a confirmed invite
are pre-approved for that source only. See [relay-enrollment.md](relay-enrollment.md#pre-approval-on-the-phone).

## Code

- `LoopCtrlKit/PairRequestLedger.swift` holds the pending and recent requests
  and the grants. It is a value type with an injected clock, tested in
  `Tests/LoopCtrlKitTests` (`xcodebuild test -scheme LoopCtrlKitTests -destination platform=macOS`).
- `LoopCtrlKit/AuthManager.swift`: `requestAuth`, `respondToPendingRequest`,
  `allowRecentRequest`, `pairingRequests`.
- `LoopCtrlUITests/LoopCtrlUITests.swift`: the `config` params and the
  `didWithdrawAuthRequest` delegate method that removes the notification.
- `LoopCtrlApp/Views/AuthorizationViews.swift`: the card, the entry row, the
  page and the polling.
