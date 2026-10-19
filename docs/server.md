# Server-side code

The server-side code no longer lives in this repo.

- **[LoopCtrl-Server](https://github.com/Souitou-iop/LoopCtrl-Server)**
  (Apache-2.0) holds the connection layer, so you can self-host it:
  - `connect/relay/`: the in-app relay (formerly `relay/` here), with its Docker
    image (`ghcr.io/souitou-iop/loopctrl-relay`) and a systemd unit;
  - `connect/headscale/`: the Headscale + embedded DERP templates (formerly
    `deploy/headscale/`);
  - `cli/`: an operator CLI that works directly or through the relay;
  - guides for self-hosting either method.

  The history of both directories moved with them.
- The relay's client contract stays here:
  [relay-enrollment.md](relay-enrollment.md) is canonical, and the server
  implements it. `Scripts/loopctrl_rpc.py` also stays here as the canonical
  protocol v1 client; LoopCtrl-Server carries a copy in `cli/`.
