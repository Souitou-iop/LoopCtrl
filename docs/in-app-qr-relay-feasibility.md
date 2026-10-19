# In-app QR pairing and self-hosted relay: feasibility

Status: design note, no implementation yet.

## Question

Can LoopCtrl let a customer scan one QR code, connect to our service, and
control the phone remotely without configuring Shadowrocket or Tailscale?

## Short answer

Not while also reusing Shadowrocket's active VPN tunnel. iOS allows only one
active Network Extension tunnel at a time. A QR code can simplify enrollment,
but it cannot give LoopCtrl a second VPN path or share Shadowrocket's path.

There are two viable product shapes:

1. **Relay client inside LoopCtrl.** The service opens a long-lived outbound
   connection to our relay. This can be zero-configuration for the customer,
   but it is a new transport and does not use Tailscale.
2. **Managed Tailscale enrollment.** The customer keeps Shadowrocket and uses
   its built-in Tailscale client. Our backend supplies a short-lived enrollment
   token, and the app/operator walk the customer through the few UI fields.
   This is lower risk, but it is not a single-scan, fully integrated setup.

## What the QR code can and cannot do

It can carry:

- A short-lived, single-use enrollment token
- The relay/control base URL for our environment
- An operator/tenant identifier
- A protocol version and required client capability

It cannot:

- Create or replace an iOS VPN configuration
- Grant a Network Extension entitlement
- Make Shadowrocket's tunnel available to LoopCtrl
- Bypass the user's approval of a new pairing

Never put a long-lived pre-auth key, Tailscale auth key, device private key, or
customer credential directly in a QR code. A screenshot or photo would leak it.

## Recommended target architecture

```text
operator / browser
        |
        | TLS + mutually authenticated session
        v
our relay and control plane
        ^
        | outbound TLS session, reconnects through NAT
        |
LoopCtrl on iPhone
```

The relay should forward encrypted LoopCtrl envelopes only. It must not receive
the LoopCtrl pairing key in plaintext, and it must not be able to call RPC
methods directly as a trusted client. The physical network endpoint can be a
Network Extension or an authenticated outbound session from the automation
runtime; that choice is a distribution/entitlement decision, not a QR-code
decision.

A QR scanner in the foreground app is enough to enroll and configure. It is
not a background transport. A scanner-only build must not be described as
always-on remote access.

Suggested enrollment flow:

1. Operator creates a short-lived device enrollment token in our portal.
2. The QR code carries that token and the environment endpoint.
3. LoopCtrl scans it out of process, redeems the token over TLS, and receives a
   device-scoped relay credential.
4. The relay binds the credential to a device public key. The token is consumed.
5. LoopCtrl opens an outbound relay session and exposes only `/pair` and `/rpc`
   through that authenticated session.
6. The operator pairs normally; the existing on-device Allow/Deny prompt stays.
7. The owner can revoke the device in LoopCtrl and the operator can revoke it
   server-side. Both revocations must take effect immediately.

## Data path and what "via our server" means

If the transport is an application relay, every control packet goes through our
relay because LoopCtrl is the client and the relay is the only reachable peer.
That is different from the current Tailscale design:

- Control plane: our Headscale server.
- DERP fallback: our server.
- Successful Tailscale direct path: encrypted peer-to-peer traffic does not
  pass through our server.

Therefore a product promise of "all traffic must pass through us" requires
either an application relay or a forced relay policy; it cannot be inferred
from a custom Tailscale control URL alone.

## iOS constraints and risks

### One active VPN tunnel

Shadowrocket's global tunnel and a LoopCtrl Network Extension compete for the
single active tunnel. Integrating Tailscale into LoopCtrl therefore replaces
Shadowrocket while active; it does not compose with it.

### Background execution

The current all-in-one runner relies on XCTest's `continuous` background mode.
That is suitable for a development/sideload build, not a normal App Store
product. A production relay client must be tested under:

- screen lock
- app backgrounding
- Wi-Fi/cellular changes
- low-power mode
- process termination and relaunch

### Live Activity is not a background transport

An ActivityKit Live Activity is a presentation surface. It can show a
connection state on the Lock Screen and Dynamic Island; it does not grant
continuous execution, keep a TCP/TLS socket open, or create a network tunnel.
It also cannot coexist with the assumption that the app process is always
suspended or terminated.

Useful roles for a Live Activity:

- show relay connection health
- display a one-tap disconnect or approval state
- deep-link back into the app or pairing flow
- preserve a short-lived enrollment/approval context while the user moves
  between apps

Non-solutions for transport:

- a Live Activity timer or animation to keep the app alive
- a push-to-start Live Activity as a substitute for an inbound socket
- an ActivityKit state update as a wake-up signal for arbitrary network work

The transport must be independently justified by a Network Extension,
background-capable runtime, or a server-push design that is explicitly tested
under lock, background, and termination.

### Distribution

LoopCtrl already depends on developer tooling and test-runner behavior.
Commercial distribution, signing, and App Review are product risks separate
from relay feasibility. Do not assume the sideload path can be shipped to
customers unchanged.

### Security

The relay must not become a universal bypass of LoopCtrl pairing. Keep the
existing encrypted-envelope protocol end to end and treat the relay as an
untrusted byte pipe with authenticated routing. Rate-limit enrollment, expire
tokens quickly, and log only hashed token identifiers.

## Delivery plan

### Phase 0: prove the transport

- Build a disposable relay prototype.
- Open an outbound TLS session from a test iOS build or a disposable
  Network Extension prototype.
- Send one existing encrypted LoopCtrl request through it.
- Measure latency and reconnect behavior across backgrounding and network
  changes.

Exit criterion: a real `/rpc` call succeeds after 30 minutes in the background
and after a Wi-Fi/cellular switch, with the chosen runtime and entitlement.
Add a lock-screen Live Activity as an observability layer, but keep it out of
the success criterion for socket survival.

### Phase 1: enrollment

- Add QR scanning and a versioned enrollment payload.
- Add short-lived, single-use token redemption.
- Bind relay credentials to a device public key.
- Add operator-side device and session revocation.

Exit criterion: a fresh install can enroll by scanning one code, then complete
the normal on-device pairing prompt. This does not yet prove background
reachability.

### Phase 2: productization

- Decide distribution model and entitlement strategy.
- Add telemetry for relay reachability and reconnect rate, without collecting
  content.
- Test regional network behavior and relay capacity.
- Add a kill switch and clear local-only fallback.

## Decision

For the current Shadowrocket-first customer base, the lowest-risk commercial
path is measurable, managed enrollment rather than replacing the customer's
VPN. For a genuinely zero-configuration product, the application relay is the
only architecture that can meet the promise, but it must pass the iOS
background and distribution gates before it is treated as viable.

The v1 scope for this branch is a design and transport spike, not an App Store
release. Until the background and distribution gates pass, market it as a
managed setup or test build, not as a production always-on service.
