# External hardware helpers (ESP32 and friends) — design

Status: **design only**. No firmware exists. What *is* built and tested is the
host side: the bridge wire protocol, `usbmux::bridge::BridgePipe`, the TCP
listener (`loopctrl-pair --bridge-listen`) and a Rust reference of the bridge
side (`usbmux::bridge::serve`), exercised end to end with a simulated iPhone
over TCP in `cargo test -p usbmux bridge`. Everything marked ⚠️ has not been
tried on hardware.

## Why a helper at all

Pairing needs one USB connection between the iPhone and something that runs
pair-core. Today that is a Mac, a Windows PC, a Linux box (including a
Raspberry Pi) or an Android phone. A helper is for setups where none of those
can be next to the phone: a kiosk with only Wi-Fi, a counter where a small
board sits under the desk, a test rack.

The simplest helper already works: **a Raspberry Pi running the CLI**
(`loopctrl-pair pair --all`, built-in usbmuxd, see README). The rest of this
document is about a cheaper, dumber helper: a microcontroller that is only the
USB host and forwards bytes.

## Layers, and where a bridge plugs in

```
pair-core (state machine, records)            unchanged
   │  Backend trait → RealBackend (idevice)
   ▼
usbmuxd protocol on a socket                  unchanged
   │  usbmux::server  (private unix socket / 127.0.0.1)
   ▼
usbmux::Hub → Link → Session (mux protocol, TCP-like streams)   unchanged
   │  trait UsbPipe { read(bulk-in, timeout), write(bulk-out) }
   ▼
transport ─┬─ UsbfsPipe     Linux / Android, local USB (usbfs ioctls)
           └─ BridgePipe    any byte stream: TCP, USB-CDC serial, …
                 │
                 ▼  bridge protocol v1 (crates/usbmux/src/bridge.rs)
              helper (ESP32-S3, Pi, …) = USB host for the iPhone
```

`UsbPipe` is the transport seam: whole bulk transfers on the iPhone's usbmux
interface, nothing more. Everything above it (mux protocol, the usbmuxd
socket, lockdown, TLS, RemotePairing, AFC) is the same for every transport, so
adding a helper never touches the pairing logic. On the host:

```bash
loopctrl-pair pair --all --bridge-listen 0.0.0.0:27100 --no-local-usb
```

starts the built-in usbmuxd, accepts helpers on TCP 27100
(`usbmux::bridge::DEFAULT_PORT`) and adds each helper's iPhone to the hub like
a local USB device. The desktop app can do the same through
`pair_host::Options::bridge_listen` (no UI for it yet).

A serial helper needs no new trait: `BridgePipe::start(reader, writer)` takes
any `Read` + `Write`, so a serial port handle plugs in as is. Only the listener
(open the port instead of accepting TCP) would be new.

## Bridge protocol v1

8-byte header (`kind`, three zero bytes, `u32` little-endian length), then the
payload. One stream = one iPhone.

| kind | direction | payload |
|---|---|---|
| 1 `HELLO` | helper → host, first | `u8 version=1`, `u16 vid`, `u16 pid`, `u16 bulk-out max packet size`, `u32 bus speed Mbit/s`, USB serial (UTF-8) |
| 2 `BULK_IN` | helper → host | one completed bulk-in transfer (≤ 16384 bytes) |
| 3 `BULK_OUT` | host → helper | one mux packet = one bulk-out transfer; the helper adds a zero-length packet when the size is a multiple of the max packet size |
| 4 `DETACH` | helper → host | the iPhone is gone (closing the stream means the same) |

Before `HELLO` the helper has enumerated the iPhone, chosen the configuration
that contains the usbmux interface (class 255, subclass 254, protocol 2),
selected it and claimed the interface: the same steps as
`crates/usbmux/src/linux.rs`. The UDID is the USB serial number (24-digit
serials get their dash back on the host).

There is no checksum: TCP and USB CDC-ACM are reliable. A raw UART link would
need framing with a CRC and resynchronisation; that would be protocol v2. ⚠️

## ESP32-S2 / S3 as the USB host

| Question | Answer |
|---|---|
| Can it be the USB host for an iPhone? | The S2 and S3 have a USB 2.0 OTG controller with host mode, and ESP-IDF ships a USB Host library (Apache-2.0); TinyUSB's host stack (MIT) is an alternative. Both are permissive. ⚠️ Not tried with an iPhone. |
| Speed | **Full speed only (12 Mbit/s)** with the internal PHY. An iPhone is a high-speed device but must fall back to full speed on a full-speed host; bulk max packet size becomes 64 bytes (the HELLO carries it, the host handles it). ⚠️ Whether iOS offers the usbmux configuration at full speed is unverified; usbmuxd itself does not require high speed. |
| Is full speed enough? | Yes for pairing. Full-speed bulk tops out near 1.2 MB/s (≈0.5–0.9 MB/s in practice). The whole flow moves tens of kilobytes: lockdown plists, a TLS handshake, the RemotePairing exchange, a pairing file of a few KB written over AFC. Expect seconds, not minutes. ⚠️ Not measured. Anything bulky (app installs, DDI mounts) would be slow; that is not this tool's job. |
| High speed | The ESP32-P4 has a high-speed (480 Mbit/s) OTG port, as do boards with an external ULPI PHY. ⚠️ Not evaluated. |
| Power for the iPhone | The helper must supply VBUS: 5 V, at least 500 mA (USB 2.0 host), more if the battery is flat. Most dev boards do **not** switch or current-limit VBUS on the OTG port. Use a board with a VBUS load switch and a 5 V/2 A supply, or put a **powered USB hub** between the helper and the iPhone (a hub at full speed is fine). ⚠️ |
| TLS / SRP / RSA on the chip | **None in this design.** The helper forwards raw usbmux bulk transfers; lockdown TLS, RSA-2048 pair records, the RemotePairing X25519/Ed25519/ChaCha20 exchange and SRP all run on the host in pair-core / idevice. The ESP32 needs about 16 KB of buffer per direction and no crypto. |
| …and if it did everything itself? | Not recommended. It would need an RSA-2048 key pair per host record (seconds even with the S3's RSA accelerator ⚠️), a TLS 1.2 client with client certificates (mbedTLS, feasible), SRP-3072 for the CoreDeviceProxy fallback (3072-bit modular exponentiation, feasible with the accelerator ⚠️), plists, house_arrest/AFC — i.e. porting pair-core to C. The bridge keeps all of that in one tested Rust implementation. |
| Link to the host | **Wi-Fi TCP** (the S3's 2.4 GHz Wi-Fi gives several Mbit/s, more than full-speed USB delivers). Serial is awkward on the S3: the USB-OTG controller and the USB-Serial-JTAG console share the internal PHY, so a serial link to the host needs a UART + USB-UART adapter and the protocol-v2 CRC above. ⚠️ |

### Firmware outline (not written)

1. ESP-IDF `usb_host` install, register a client, wait for a new device with
   VID `05ac` and a PID in `0x1290–0x12af` or `0x1901–0x1905`.
2. Read the configuration descriptors, pick the one with the usbmux interface
   (prefer the one with the fewest interfaces), `SET_CONFIGURATION`, claim
   interface + endpoints.
3. Connect to the host (`host:27100`), send `HELLO` with the iPhone's serial,
   PID, the bulk-out max packet size (64 at full speed) and speed 12.
4. Keep one bulk-in transfer of 16384 bytes in flight; each completion → one
   `BULK_IN` frame.
5. Each `BULK_OUT` frame → one bulk-out transfer, with
   `USB_TRANSFER_FLAG_ZERO_PACK` when the length is a multiple of 64.
6. On disconnect → `DETACH`, close, wait for the next iPhone.

`usbmux::bridge::serve` is the same loop in Rust and is the reference when
behaviour is unclear.

## Security

The usbmux stream is not encrypted end to end. Lockdown switches to TLS
after `StartSession`, but the Trust exchange (the pair record request and the
escrow bag that comes back) and, depending on the service, the AFC write of
`pairingFile.plist` — which contains private keys that control the phone —
can cross the bridge in the clear. Therefore:

- Run bridges only on a trusted, isolated network segment, or tunnel them
  (WireGuard, SSH port forward). ⚠️ Protocol v1 has no authentication or
  encryption of its own; adding a pre-shared-key TLS layer is the obvious v2.
- `--bridge-listen` accepts any peer that speaks the protocol. Bind it to the
  interface the helpers are on (e.g. `192.168.50.1:27100`), not `0.0.0.0`, on
  any machine with other network exposure.
- The host keeps records in its private data folder (0700/0600), the same as
  without a bridge.

## Verified / not verified

- ✅ Protocol encode/decode, size limits, `HELLO` parsing (unit tests).
- ✅ Simulated iPhone → `serve` → TCP → `BridgePipe` → hub: usbmux handshake,
  a stream to a device port, unplug propagates as detach (unit test).
- ✅ `loopctrl-pair --bridge-listen` starts the listener next to the built-in
  usbmuxd (unit test in pair-host).
- ⚠️ Everything with real hardware: ESP32 firmware, an iPhone at full speed,
  VBUS power, Wi-Fi latency, throughput.
