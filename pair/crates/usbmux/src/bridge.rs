//! A [`UsbPipe`] carried over a byte stream, for USB bridges.
//!
//! The muxer only needs one thing from a transport: whole bulk transfers in
//! both directions on the iPhone's usbmux interface ([`UsbPipe`]). A bridge is
//! something else that is the USB host for the iPhone (an ESP32-S3 with
//! USB-OTG, a Raspberry Pi in another room) and forwards those transfers over
//! TCP or a serial link. The usbmux protocol, TLS, lockdown and pairing all
//! stay on the computer running pair-core; the bridge only moves bytes.
//!
//! Wire format, version 1. Every frame is an 8 byte header and a payload:
//!
//! ```text
//! u8  kind      1 HELLO, 2 BULK_IN, 3 BULK_OUT, 4 DETACH
//! u8  reserved  0
//! u16 reserved  0
//! u32 length    payload bytes, little endian
//! ```
//!
//! * `HELLO` (bridge → host, first frame): `u8 version (1)`, `u16 vendor id`,
//!   `u16 product id`, `u16 max packet size of the bulk-out endpoint`,
//!   `u32 bus speed in Mbit/s`, then the USB serial number (UTF-8, the rest).
//!   The bridge has already selected the configuration and claimed the usbmux
//!   interface.
//! * `BULK_IN` (bridge → host): one completed bulk-in transfer, at most
//!   `USB_MRU` bytes.
//! * `BULK_OUT` (host → bridge): one mux packet; the bridge sends it as one
//!   bulk-out transfer and adds the zero length packet when its size is a
//!   multiple of the max packet size.
//! * `DETACH` (bridge → host): the iPhone is gone. Closing the stream means
//!   the same.
//!
//! One stream carries one iPhone. TCP and USB CDC-ACM serial are reliable, so
//! there is no checksum; a raw UART would need one (not part of version 1).
//! See docs/hardware-helpers.md.

use std::io::{self, Read, Write};
use std::sync::mpsc::{Receiver, RecvTimeoutError, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::hub::DeviceInfo;
use crate::packet::USB_MRU;
use crate::pipe::UsbPipe;

pub const VERSION: u8 = 1;
/// Default TCP port a host listens on for bridges.
pub const DEFAULT_PORT: u16 = 27_100;

pub const HELLO: u8 = 1;
pub const BULK_IN: u8 = 2;
pub const BULK_OUT: u8 = 3;
pub const DETACH: u8 = 4;

const HEADER: usize = 8;
/// Largest payload accepted in either direction.
const MAX_FRAME: usize = 1 << 20;

/// What a bridge says about the iPhone it serves.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hello {
    pub vendor_id: u16,
    pub product_id: u16,
    pub max_packet_out: u16,
    pub speed_mbps: u32,
    pub serial: String,
}

impl Hello {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = vec![VERSION];
        out.extend_from_slice(&self.vendor_id.to_le_bytes());
        out.extend_from_slice(&self.product_id.to_le_bytes());
        out.extend_from_slice(&self.max_packet_out.to_le_bytes());
        out.extend_from_slice(&self.speed_mbps.to_le_bytes());
        out.extend_from_slice(self.serial.as_bytes());
        out
    }

    pub fn decode(body: &[u8]) -> io::Result<Self> {
        if body.len() < 11 {
            return Err(invalid("short HELLO"));
        }
        if body[0] != VERSION {
            return Err(invalid(format!(
                "bridge protocol version {} (want {VERSION})",
                body[0]
            )));
        }
        let u16_at = |i: usize| u16::from_le_bytes([body[i], body[i + 1]]);
        Ok(Hello {
            vendor_id: u16_at(1),
            product_id: u16_at(3),
            max_packet_out: u16_at(5),
            speed_mbps: u32::from_le_bytes([body[7], body[8], body[9], body[10]]),
            serial: String::from_utf8_lossy(&body[11..]).into_owned(),
        })
    }

    /// The device as the hub lists it. `location` tells bridges apart.
    pub fn device_info(&self, location: u32) -> DeviceInfo {
        DeviceInfo {
            udid: crate::hub::udid_from_serial(&self.serial),
            product_id: self.product_id,
            location_id: location,
            speed: u64::from(self.speed_mbps) * 1_000_000,
        }
    }
}

fn invalid(msg: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.into())
}

pub fn write_frame(w: &mut impl Write, kind: u8, payload: &[u8]) -> io::Result<()> {
    if payload.len() > MAX_FRAME {
        return Err(invalid("frame too large"));
    }
    let mut header = [0u8; HEADER];
    header[0] = kind;
    header[4..].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    w.write_all(&header)?;
    w.write_all(payload)?;
    w.flush()
}

pub fn read_frame(r: &mut impl Read) -> io::Result<(u8, Vec<u8>)> {
    let mut header = [0u8; HEADER];
    r.read_exact(&mut header)?;
    let len = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
    if len > MAX_FRAME {
        return Err(invalid(format!("frame of {len} bytes")));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)?;
    Ok((header[0], body))
}

/// Host side: the iPhone behind a bridge, as a [`UsbPipe`] for
/// [`Hub::add_device`](crate::Hub::add_device).
pub struct BridgePipe {
    rx: Mutex<Receiver<io::Result<Vec<u8>>>>,
    tx: Mutex<Box<dyn Write + Send>>,
}

impl BridgePipe {
    /// Reads the `HELLO` from `reader` and starts a thread that receives
    /// bulk-in transfers.
    pub fn start(
        mut reader: impl Read + Send + 'static,
        writer: impl Write + Send + 'static,
    ) -> io::Result<(Self, Hello)> {
        let (kind, body) = read_frame(&mut reader)?;
        if kind != HELLO {
            return Err(invalid(format!("expected HELLO, got frame kind {kind}")));
        }
        let hello = Hello::decode(&body)?;
        // A few transfers of slack; the mux session drains them quickly.
        let (tx, rx) = sync_channel(64);
        std::thread::Builder::new()
            .name("usbmux-bridge".into())
            .spawn(move || {
                loop {
                    let item = match read_frame(&mut reader) {
                        Ok((BULK_IN, body)) if body.len() <= USB_MRU => Ok(body),
                        Ok((BULK_IN, body)) => {
                            Err(invalid(format!("bulk-in of {} bytes", body.len())))
                        }
                        Ok((DETACH, _)) => Err(io::ErrorKind::NotConnected.into()),
                        Ok((kind, _)) => Err(invalid(format!("unexpected frame kind {kind}"))),
                        Err(e) => Err(e),
                    };
                    let stop = item.is_err();
                    if tx.send(item).is_err() || stop {
                        return;
                    }
                }
            })?;
        Ok((
            BridgePipe {
                rx: Mutex::new(rx),
                tx: Mutex::new(Box::new(writer)),
            },
            hello,
        ))
    }
}

impl UsbPipe for BridgePipe {
    fn read(&self, buf: &mut [u8], timeout: Duration) -> io::Result<usize> {
        match self.rx.lock().unwrap().recv_timeout(timeout) {
            Ok(Ok(data)) => {
                let n = data.len().min(buf.len());
                buf[..n].copy_from_slice(&data[..n]);
                Ok(n)
            }
            Ok(Err(e)) => Err(if e.kind() == io::ErrorKind::TimedOut {
                io::ErrorKind::BrokenPipe.into()
            } else {
                e
            }),
            Err(RecvTimeoutError::Timeout) => Err(io::ErrorKind::TimedOut.into()),
            Err(RecvTimeoutError::Disconnected) => Err(io::ErrorKind::BrokenPipe.into()),
        }
    }

    fn write(&self, data: &[u8]) -> io::Result<()> {
        write_frame(&mut *self.tx.lock().unwrap(), BULK_OUT, data)
    }
}

/// Bridge side, for a bridge that runs Rust (and as the reference for
/// firmware): forwards an iPhone that is reachable as a [`UsbPipe`] over a
/// stream. Returns when either side is gone.
pub fn serve(
    pipe: Arc<dyn UsbPipe>,
    hello: &Hello,
    mut reader: impl Read + Send + 'static,
    writer: impl Write + Send + 'static,
) -> io::Result<()> {
    let writer = Arc::new(Mutex::new(writer));
    write_frame(&mut *writer.lock().unwrap(), HELLO, &hello.encode())?;
    let up = {
        let pipe = pipe.clone();
        let writer = writer.clone();
        std::thread::Builder::new()
            .name("bridge-in".into())
            .spawn(move || {
                let mut buf = vec![0u8; USB_MRU];
                loop {
                    match pipe.read(&mut buf, Duration::from_millis(200)) {
                        Ok(n) => {
                            if write_frame(&mut *writer.lock().unwrap(), BULK_IN, &buf[..n])
                                .is_err()
                            {
                                return;
                            }
                        }
                        Err(e) if e.kind() == io::ErrorKind::TimedOut => {}
                        Err(_) => {
                            let _ = write_frame(&mut *writer.lock().unwrap(), DETACH, &[]);
                            return;
                        }
                    }
                }
            })?
    };
    let result = loop {
        match read_frame(&mut reader) {
            Ok((BULK_OUT, body)) => {
                if let Err(e) = pipe.write(&body) {
                    let _ = write_frame(&mut *writer.lock().unwrap(), DETACH, &[]);
                    break Err(e);
                }
            }
            Ok((kind, _)) => break Err(invalid(format!("unexpected frame kind {kind}"))),
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => break Ok(()),
            Err(e) => break Err(e),
        }
    };
    drop(up);
    result
}

/// Accepts bridges on `listener` and adds each one's iPhone to `hub`.
pub async fn serve_tcp(listener: tokio::net::TcpListener, hub: crate::Hub) {
    let mut location = 0xB000_0000u32;
    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!("bridge accept: {e}");
                tokio::time::sleep(Duration::from_millis(500)).await;
                continue;
            }
        };
        location = location.wrapping_add(1);
        let hub = hub.clone();
        tokio::spawn(async move {
            let started = tokio::task::spawn_blocking(move || {
                let stream = stream.into_std()?;
                stream.set_nonblocking(false)?;
                let _ = stream.set_nodelay(true);
                let writer = stream.try_clone()?;
                BridgePipe::start(stream, writer)
            })
            .await;
            match started {
                Ok(Ok((pipe, hello))) => {
                    tracing::info!("bridge {peer}: iPhone {}", hello.serial);
                    if let Err(e) = hub
                        .add_device(Arc::new(pipe), hello.device_info(location))
                        .await
                    {
                        tracing::warn!("bridge {peer}: {e}");
                    }
                }
                Ok(Err(e)) => tracing::warn!("bridge {peer}: {e}"),
                Err(e) => tracing::warn!("bridge {peer}: {e}"),
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;
    use crate::Hub;
    use crate::pair_store::MemoryPairStore;
    use crate::testutil::FakeDevice;

    fn hello() -> Hello {
        Hello {
            vendor_id: 0x05ac,
            product_id: 0x12a8,
            max_packet_out: 512,
            speed_mbps: 480,
            serial: "00008030001C1D2E0A68802E".into(),
        }
    }

    #[test]
    fn hello_roundtrips() {
        let h = hello();
        assert_eq!(Hello::decode(&h.encode()).unwrap(), h);
        assert_eq!(h.device_info(7).udid, "00008030-001C1D2E0A68802E");
        assert_eq!(h.device_info(7).speed, 480_000_000);
        let mut bad = h.encode();
        bad[0] = 9;
        assert!(Hello::decode(&bad).is_err());
        assert!(Hello::decode(&[1, 2, 3]).is_err());
    }

    #[test]
    fn frames_roundtrip_and_reject_oversize() {
        let mut buf = Vec::new();
        write_frame(&mut buf, BULK_OUT, b"abc").unwrap();
        assert_eq!(&buf[..8], &[3, 0, 0, 0, 3, 0, 0, 0]);
        assert_eq!(
            read_frame(&mut &buf[..]).unwrap(),
            (BULK_OUT, b"abc".to_vec())
        );
        let mut huge = vec![2, 0, 0, 0];
        huge.extend_from_slice(&(MAX_FRAME as u32 + 1).to_le_bytes());
        assert!(read_frame(&mut &huge[..]).is_err());
    }

    /// A fake iPhone behind a bridge on the other end of a TCP connection
    /// works like one on local USB: handshake, then a stream to a port.
    #[tokio::test(flavor = "multi_thread")]
    async fn iphone_behind_a_tcp_bridge() {
        let hub = Hub::new(Box::new(MemoryPairStore::new()));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(serve_tcp(listener, hub.clone()));
        let mut events = hub.subscribe();

        let device = Arc::new(FakeDevice::with_services());
        let bridge_device = device.clone();
        std::thread::spawn(move || {
            let stream = std::net::TcpStream::connect(addr).unwrap();
            let writer = stream.try_clone().unwrap();
            let _ = serve(bridge_device, &hello(), stream, writer);
        });

        let attached = tokio::time::timeout(Duration::from_secs(5), events.recv())
            .await
            .unwrap()
            .unwrap();
        let crate::hub::HubEvent::Attached(dev) = attached else {
            panic!("{attached:?}")
        };
        assert_eq!(dev.info.udid, "00008030-001C1D2E0A68802E");

        let mut stream = hub.connect(dev.id, 7).await.unwrap();
        stream.write_all(b"over the bridge").await.unwrap();
        let mut back = [0u8; 15];
        stream.read_exact(&mut back).await.unwrap();
        assert_eq!(&back, b"over the bridge");

        // Unplugging at the bridge detaches the device on the host.
        device.unplug();
        let gone = tokio::time::timeout(Duration::from_secs(5), events.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(gone, crate::hub::HubEvent::Detached(dev.id));
    }
}
