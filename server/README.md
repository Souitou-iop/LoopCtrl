<p align="right"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

# LoopCtrl server

The connection layer for [LoopCtrl](../README.md):
the server-side pieces that let an operator reach a phone's LoopCtrl from
another network. Everything here can be self-hosted.

LoopCtrl runs an XCUITest runner on the iPhone that serves an encrypted
JSON-RPC API (protocol v1, port 8300). On the same Wi-Fi an operator talks to
it directly. From anywhere else it needs a path to the phone, and this folder
provides two interchangeable ones:

| | In-app relay (`connect/relay/`) | Headscale tailnet (`connect/headscale/`) |
|---|---|---|
| Phone setup | Scan an invite QR code in LoopCtrl. Nothing else. | Join a tailnet through Shadowrocket (or another Tailscale client) with a pre-auth key. |
| Server | One small Go binary behind HTTPS. | Headscale + embedded DERP relay behind HTTPS, UDP 3478 for STUN. |
| Transport | The phone holds one WebSocket to the relay; the relay forwards whole HTTP exchanges down it. | WireGuard, direct when NAT allows, otherwise via your DERP. |
| Operator reaches | The phone's own public address, `https://<slug>.<relay domain>/`: the control page in a browser, or `/rpc` for agents. | `100.64.x.y:8300` from any `tag:operator` node. |
| Use it when | Default. Zero configuration on the customer's phone. | Fallback, or when you already run a tailnet. |

Either way the operator pairs with the phone (X25519) and every call is
sealed end to end with the LoopCtrl v1 envelope. **Neither the relay nor
Headscale can read or forge requests.** The invite names the operator keys the
phone pre-approves. The relay does serve the control page a browser opens, so
use a relay you run or trust ([why](../docs/remote-control.md#trust)).

## Layout

```
connect/relay/        the relay (Go), its tests, the operator tool,
                      Dockerfile, compose file, nginx and systemd templates
connect/headscale/    Headscale + embedded DERP: compose file, config, ACL policy, nginx
cli/                  `loopctrl` operator CLI (direct or through the relay)
docs/                 self-hosting guides and the protocol overview
```

## Quick start

Relay, with Docker, behind your own HTTPS reverse proxy:

```sh
cd connect/relay
cp relay.env.example relay.env && $EDITOR relay.env
install -d -m 0700 -o 65532 -g 65532 state
docker compose up -d
curl -s http://127.0.0.1:8787/healthz
```

Then mint an invite and drive the phone:

```sh
export LOOPCTRL_RELAY_URL=https://relay.example.com
export LOOPCTRL_RELAY_OPERATOR_TOKEN=...      # from relay.env
cli/loopctrl relay enroll --name "Alex"       # prints the loopctrl://connect link; show it as a QR code
cli/loopctrl relay devices                    # each phone's public address
cli/loopctrl relay pair --device-id dev_...   # approved automatically: the invite named your key
cli/loopctrl relay call --device-id dev_... device_info
```

Or open the phone's public address in a browser and pair from there (the
phone asks its user): a live screen, touch, keyboard and the view tree.

Full guides:

- [docs/self-host-relay.md](docs/self-host-relay.md): the relay (Docker or systemd).
- [docs/self-host-headscale.md](docs/self-host-headscale.md): Headscale + DERP, and joining phones through Shadowrocket.
- [docs/protocol.md](docs/protocol.md): how the pieces fit, and where each contract is defined.

## Images

Tagged releases publish `ghcr.io/souitou-iop/loopctrl-relay:<version>` (and
`:latest`). Headscale uses the upstream `headscale/headscale` image.

## Development

```sh
cd connect/relay && go test -race ./...   # the relay against a simulated phone; no iPhone needed
ruff check .                              # the Python CLI
```

The relay needs Go 1.23+ and one dependency (`github.com/coder/websocket`).
The CLI is Python 3.10+, standard library only (it uses `cryptography` for
X25519 pairing if it is installed, and falls back to pure Python).

## License

Apache-2.0, like LoopCtrl.
