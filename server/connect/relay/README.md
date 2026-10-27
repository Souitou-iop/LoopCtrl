# Relay

LoopCtrl's relay: invite enrollment, and a reverse tunnel that gives every
enrolled phone a public address where a browser or an agent reaches it
exactly as on the phone's LAN address. One static Go binary. The full guide is
[docs/self-host-relay.md](../../docs/self-host-relay.md); the contracts are
LoopCtrl's [docs/relay-enrollment.md](https://github.com/Souitou-iop/LoopCtrl/blob/main/docs/relay-enrollment.md)
and [docs/remote-control.md](https://github.com/Souitou-iop/LoopCtrl/blob/main/docs/remote-control.md).

| File | What it is |
|---|---|
| `main.go`, `server.go`, `state.go`, `tunnel.go`, `frame.go` | The relay. |
| `relay_test.go` | Enrollment, sign-in, the tunnel, routing, flow control and rate limits, against a simulated phone. `go test -race ./...` |
| `relay_operator.py` | Operator client (`cli/loopctrl relay …`). |
| `Dockerfile`, `docker-compose.yml`, `relay.env.example` | Container deployment. |
| `systemd/` | Unit template and `render-unit.sh` for running the binary directly. |
| `nginx-site.conf`, `nginx-location.conf` | TLS front: own name (with a name per phone), or a path on an existing site. |
