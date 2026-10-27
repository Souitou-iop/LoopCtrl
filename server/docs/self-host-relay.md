# Self-hosting the relay

The relay (`connect/relay/`) lets a phone running LoopCtrl be controlled from
anywhere with no VPN on the phone. The customer scans one invite. LoopCtrl
then keeps one WebSocket open to the relay, and the relay gives the phone a
public address: open `https://<slug>.<your domain>/remote` in a browser to
drive the phone, or point an agent at the same address.

Pairing and every call stay end to end between the operator and the phone,
and the screen stream is encrypted for any `https://` page. The relay stores
only enrolled devices' public keys (`state.json`). Enrollment codes, tokens
and tunnels live in memory.

The relay does serve the control page, so whoever runs it could change that
page. Run it yourself, or use one run by someone you would trust with the
phone anyway ([details](../../docs/remote-control.md#trust)).

## What you need

- A public HTTPS name for the relay, either a name of its own
  (`relay.example.com`) or a path on an existing site
  (`example.com/loopctrl-relay`).
- For one address per phone (recommended): a wildcard DNS record
  (`*.relay.example.com`) and a wildcard certificate for it. Without one,
  phones are served at `https://<relay>/d/<slug>/`, all on one origin, which
  is fine only when every phone on the relay belongs to one person.
- A reverse proxy for TLS (nginx templates are in `connect/relay/`).
- Docker, or Go 1.23+ to build the binary for systemd.

A self-signed certificate works for the phone's side when the invite pins it
(`pin=`, see [protocol.md](protocol.md)); browsers will still warn about it.

## 1. Configure

```sh
cd connect/relay
cp relay.env.example relay.env
chmod 600 relay.env
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'   # paste as LOOPCTRL_RELAY_OPERATOR_TOKEN
$EDITOR relay.env
```

- `LOOPCTRL_RELAY_PUBLIC_SERVER` must be the public name exactly as phones see
  it, `host[:port][/path]` with no scheme and no trailing slash. Every
  signature the phone makes is bound to it; a mismatch makes enrollment fail
  with `bad_signature`.
- `LOOPCTRL_RELAY_DEVICE_DOMAIN` is the domain phones get names under
  (`relay.example.com` gives `<slug>.relay.example.com`). Leave it empty for
  path addresses (`/d/<slug>/`).

## 2a. Run with Docker

```sh
install -d -m 0700 -o 65532 -g 65532 state     # the image runs as uid 65532
docker compose up -d                           # ghcr.io/souitou-iop/loopctrl-relay:latest
docker compose logs -f
```

Pin a version with `RELAY_VERSION=0.2.0 docker compose up -d`, or build
locally with `docker compose build`. The container listens on
`127.0.0.1:8787` on the host.

## 2b. Run with systemd

```sh
cd connect/relay && CGO_ENABLED=0 go build -trimpath -o loopctrl-relay .
install -m 0755 loopctrl-relay /usr/local/bin/loopctrl-relay
install -d -m 0700 /etc/loopctrl-relay /var/lib/loopctrl-relay
install -m 0600 relay.env /etc/loopctrl-relay/relay.env

BINARY=/usr/local/bin/loopctrl-relay \
ENV_FILE=/etc/loopctrl-relay/relay.env \
STATE_DIR=/var/lib/loopctrl-relay \
  systemd/render-unit.sh > /etc/systemd/system/loopctrl-relay.service
systemctl daemon-reload
systemctl enable --now loopctrl-relay
```

Cross-compile for the server with `GOOS=linux GOARCH=amd64` (or `arm64`).
`render-unit.sh` also takes `LISTEN` and `USER_NAME`. The unit is sandboxed
(`ProtectSystem=strict`); only `STATE_DIR` is writable.

## 3. Put it behind HTTPS

- Own name: `connect/relay/nginx-site.conf` (replace `RELAY_DOMAIN` and
  `PHONES_DOMAIN`).
- Under a path: include `connect/relay/nginx-location.conf` in your existing
  `server { listen 443 ssl; … }` block, and add the `map` it names at http
  level.

Keep the WebSocket upgrade headers (the phones' tunnels), `Host $host` (the
relay routes on the name), `proxy_buffering off` and the long timeouts (the
screen is one long streamed response).

The relay rate-limits enrollment and pairing per client address, which it
takes from `X-Real-IP` when the request comes from a trusted proxy (loopback by
default, plus the Docker bridge in the compose file;
`LOOPCTRL_RELAY_TRUSTED_PROXIES` to change). The same address is what the
phone shows for a browser asking to pair.

Check it:

```sh
curl -s https://relay.example.com/healthz
# {"api":1,"ok":true,"server":"relay.example.com","tunnel":1}
```

`server` must equal what you put in `LOOPCTRL_RELAY_PUBLIC_SERVER`.

## 4. Enroll a phone

```sh
export LOOPCTRL_RELAY_URL=https://relay.example.com
export LOOPCTRL_RELAY_OPERATOR_TOKEN=...      # never on the command line
cli/loopctrl relay key                        # your operator name and key ID
cli/loopctrl relay enroll --name "Alex" --org "Example Ops"
```

`enroll` prints a `loopctrl://connect?…` link. Show it as a QR code (or send
the link); the phone shows the organization and your name, and connects after
the customer confirms. LoopCtrl then shows the phone's control page address
on its 远程服务 screen, and `cli/loopctrl relay devices` lists it too.

## 5. Drive it

In a browser: open the address, tap **Pair**, and the phone asks its user to
allow it. The page shows the live screen, takes clicks, drags, the scroll
wheel and typing (input methods included), has Home, Lock and an app launcher,
and lists the view tree.

From the command line, with the operator key the invite named (no prompt):

```sh
cli/loopctrl relay pair --device-id dev_0123456789abcdef
cli/loopctrl relay call --device-id dev_0123456789abcdef device_info
```

Or any client, as on the LAN (the phone asks its user):

```sh
cli/loopctrl direct --host https://k3x9….relay.example.com pair --name ops-laptop
cli/loopctrl direct --host https://k3x9….relay.example.com call tap '{"x":100,"y":200}'
```

The operator key lives in `~/.loopctrl/relay_operator.json`; keep it, because
invites name it.

## Operating it

- **Backups:** `state.json` only. Losing it unbinds every phone (each must
  scan a new invite); nothing else is lost. Records from the earlier Python
  relay load as they are and get a public address on first start.
- **Restarts** are safe: phones reconnect within seconds and keep their
  addresses. Open control pages pick the stream up again by themselves.
- **Bandwidth:** each person watching a phone costs 1 to 6 Mbit/s through the
  relay, depending on the quality they pick.
- **Logs:** with `LOOPCTRL_RELAY_EVENT_LOG=1`, one line per enrollment,
  sign-in and tunnel event (ids only). Tokens and request contents are never
  logged.
- **Token rotation:** change `LOOPCTRL_RELAY_OPERATOR_TOKEN` and restart.
  Phones are unaffected; operators need the new token for `enroll` and
  `devices`.
- **Certificate pinning:** invites may carry `pin=` (the SPKI hash, see
  [protocol.md](protocol.md)). A pin breaks when the certificate key changes,
  so renew with the same key (`certbot --reuse-key`) if you pin.

## Testing

```sh
cd connect/relay && go test -race ./...
```

Runs the relay in-process against a simulated phone: enrollment, sign-in,
the tunnel, both kinds of address, flow control, resets, rate limits, unbind
and loading old state files. No iPhone needed.
