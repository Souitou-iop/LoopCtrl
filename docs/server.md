# Server-side code

The server side lives in this repository, under [`server/`](../server/)
(Apache-2.0); it was the separate LoopCtrl-Server repository until its
history was merged in here.

- `server/connect/relay/`: the relay (Go), with its Docker image
  (`ghcr.io/souitou-iop/loopctrl-relay`, tagged `server-vX.Y.Z`) and a
  systemd unit;
- `server/connect/headscale/`: the Headscale + embedded DERP templates;
- `server/cli/`: an operator CLI that works directly or through the relay;
- guides for self-hosting either method in `server/docs/`.

The relay's client contract is [relay-enrollment.md](relay-enrollment.md)
and [remote-control.md](remote-control.md), and the relay implements it.
`Scripts/loopctrl_rpc.py` is the protocol v1 client; `server/cli/` links to
it rather than keeping a copy.
