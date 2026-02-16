use std::io;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clap::Parser;
use quiche::h3::NameValue;
use ring::rand::*;

const MAX_DATAGRAM_SIZE: usize = 1350;

#[derive(Parser)]
#[command(about = "HTTP/3 benchmark client for QLOG overhead measurement")]
struct Args {
    /// Server URL (e.g., https://10.20.0.10/small)
    url: String,

    /// Number of measured requests
    #[arg(short = 'n', long, default_value_t = 10)]
    requests: u32,

    /// Warmup requests (not included in results)
    #[arg(short, long, default_value_t = 1)]
    warmup: u32,

    /// Idle timeout in milliseconds
    #[arg(long, default_value_t = 30_000)]
    idle_timeout: u64,

    /// Path to CA certificate for TLS verification
    #[arg(long)]
    ca_cert: Option<String>,

    /// Skip TLS certificate verification
    #[arg(long)]
    insecure: bool,
}

struct RequestResult {
    index: u32,
    status: u16,
    ttfb: Duration,
    total_time: Duration,
    bytes_received: u64,
}

struct InflightRequest {
    start: Instant,
    first_byte: Option<Instant>,
    status: u16,
    bytes_received: u64,
    stream_id: u64,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let url = url::Url::parse(&args.url).context("invalid URL")?;

    let peer_addr = url
        .socket_addrs(|| Some(443))
        .context("failed to resolve server address")?
        .into_iter()
        .next()
        .context("no addresses resolved")?;

    // Prepare request path.
    let mut path = String::from(url.path());
    if let Some(query) = url.query() {
        path.push('?');
        path.push_str(query);
    }

    let req_headers = vec![
        quiche::h3::Header::new(b":method", b"GET"),
        quiche::h3::Header::new(b":scheme", url.scheme().as_bytes()),
        quiche::h3::Header::new(
            b":authority",
            url.host_str().unwrap_or("localhost").as_bytes(),
        ),
        quiche::h3::Header::new(b":path", path.as_bytes()),
        quiche::h3::Header::new(b"user-agent", b"benchmark-client"),
    ];

    // Setup event loop.
    let mut poll = mio::Poll::new()?;
    let mut events = mio::Events::with_capacity(1024);

    let bind_addr = match peer_addr {
        std::net::SocketAddr::V4(_) => "0.0.0.0:0",
        std::net::SocketAddr::V6(_) => "[::]:0",
    };

    let mut socket = mio::net::UdpSocket::bind(bind_addr.parse().unwrap())?;
    poll.registry()
        .register(&mut socket, mio::Token(0), mio::Interest::READABLE)?;

    let local_addr = socket.local_addr()?;

    // Configure QUIC.
    let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION)?;

    config.verify_peer(!args.insecure);

    if let Some(ref ca_path) = args.ca_cert {
        config.load_verify_locations_from_file(ca_path)?;
    }

    config
        .set_application_protos(quiche::h3::APPLICATION_PROTOCOL)
        .context("failed to set ALPN")?;

    config.set_max_idle_timeout(args.idle_timeout);
    config.set_max_recv_udp_payload_size(MAX_DATAGRAM_SIZE);
    config.set_max_send_udp_payload_size(MAX_DATAGRAM_SIZE);
    config.set_initial_max_data(1_073_741_824);
    config.set_initial_max_stream_data_bidi_local(1_073_741_824);
    config.set_initial_max_stream_data_bidi_remote(1_000_000);
    config.set_initial_max_stream_data_uni(1_000_000);
    config.set_initial_max_streams_bidi(1_000);
    config.set_initial_max_streams_uni(100);
    config.set_disable_active_migration(true);

    // Create QUIC connection.
    let mut scid = [0; quiche::MAX_CONN_ID_LEN];
    SystemRandom::new()
        .fill(&mut scid[..])
        .map_err(|_| anyhow::anyhow!("failed to generate connection ID"))?;
    let scid = quiche::ConnectionId::from_ref(&scid);

    let mut conn =
        quiche::connect(url.domain(), &scid, local_addr, peer_addr, &mut config)
            .context("QUIC connect failed")?;

    // Send initial handshake packet.
    let mut out = [0; MAX_DATAGRAM_SIZE];
    let (write, send_info) = conn.send(&mut out).context("initial send failed")?;
    send_to(&socket, &out[..write], send_info.to)?;

    let h3_config = quiche::h3::Config::new()?;
    let mut h3_conn: Option<quiche::h3::Connection> = None;

    let mut buf = [0; 65535];
    let total_requests = args.warmup + args.requests;
    let mut requests_sent: u32 = 0;
    let mut requests_done: u32 = 0;
    let mut results: Vec<RequestResult> = Vec::with_capacity(args.requests as usize);
    let mut inflight: Option<InflightRequest> = None;

    loop {
        poll.poll(&mut events, conn.timeout())?;

        // Read incoming UDP packets.
        'read: loop {
            if events.is_empty() {
                conn.on_timeout();
                break 'read;
            }

            let (len, from) = match socket.recv_from(&mut buf) {
                Ok(v) => v,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break 'read,
                Err(e) => bail!("recv() failed: {e}"),
            };

            let recv_info = quiche::RecvInfo {
                to: local_addr,
                from,
            };

            if let Err(e) = conn.recv(&mut buf[..len], recv_info) {
                eprintln!("recv processing failed: {e}");
            }
        }

        if conn.is_closed() {
            break;
        }

        // Create HTTP/3 connection once QUIC handshake completes.
        if conn.is_established() && h3_conn.is_none() {
            h3_conn = Some(
                quiche::h3::Connection::with_transport(&mut conn, &h3_config)
                    .context("failed to create HTTP/3 connection")?,
            );
        }

        // Send next request if nothing in-flight and requests remaining.
        if let Some(h3) = &mut h3_conn {
            if inflight.is_none() && requests_sent < total_requests {
                let stream_id = h3
                    .send_request(&mut conn, &req_headers, true)
                    .context("send_request failed")?;

                inflight = Some(InflightRequest {
                    start: Instant::now(),
                    first_byte: None,
                    status: 0,
                    bytes_received: 0,
                    stream_id,
                });
                requests_sent += 1;
            }
        }

        // Process HTTP/3 events.
        if let Some(h3) = &mut h3_conn {
            loop {
                match h3.poll(&mut conn) {
                    Ok((stream_id, quiche::h3::Event::Headers { list, .. })) => {
                        if let Some(ref mut req) = inflight {
                            if stream_id == req.stream_id {
                                req.first_byte = Some(Instant::now());
                                for hdr in &list {
                                    if hdr.name() == b":status" {
                                        req.status = std::str::from_utf8(hdr.value())
                                            .unwrap_or("0")
                                            .parse()
                                            .unwrap_or(0);
                                    }
                                }
                            }
                        }
                    }

                    Ok((stream_id, quiche::h3::Event::Data)) => {
                        if let Some(ref mut req) = inflight {
                            if stream_id == req.stream_id {
                                while let Ok(read) =
                                    h3.recv_body(&mut conn, stream_id, &mut buf)
                                {
                                    req.bytes_received += read as u64;
                                }
                            }
                        }
                    }

                    Ok((stream_id, quiche::h3::Event::Finished)) => {
                        if let Some(req) = inflight.take() {
                            if stream_id == req.stream_id {
                                let now = Instant::now();

                                // Only record results after warmup.
                                if requests_done >= args.warmup {
                                    results.push(RequestResult {
                                        index: requests_done - args.warmup,
                                        status: req.status,
                                        ttfb: req
                                            .first_byte
                                            .unwrap_or(now)
                                            .duration_since(req.start),
                                        total_time: now.duration_since(req.start),
                                        bytes_received: req.bytes_received,
                                    });
                                }
                                requests_done += 1;
                            }
                        }

                        // All requests done — close connection.
                        if requests_done >= total_requests {
                            conn.close(true, 0x100, b"done").ok();
                        }
                    }

                    Ok((_stream_id, quiche::h3::Event::Reset(e))) => {
                        eprintln!("stream reset by peer: {e}");
                        inflight = None;
                        requests_done += 1;

                        if requests_done >= total_requests {
                            conn.close(true, 0x100, b"done").ok();
                        }
                    }

                    Ok((_, quiche::h3::Event::GoAway)) => {
                        eprintln!("received GOAWAY");
                        conn.close(true, 0x100, b"goaway").ok();
                    }

                    Ok((_, quiche::h3::Event::PriorityUpdate)) => (),

                    Err(quiche::h3::Error::Done) => break,

                    Err(e) => {
                        eprintln!("HTTP/3 error: {e}");
                        break;
                    }
                }
            }
        }

        // Send outgoing QUIC packets.
        loop {
            let (write, send_info) = match conn.send(&mut out) {
                Ok(v) => v,
                Err(quiche::Error::Done) => break,
                Err(e) => {
                    conn.close(false, 0x1, b"fail").ok();
                    bail!("send failed: {e}");
                }
            };

            send_to(&socket, &out[..write], send_info.to)?;
        }

        if conn.is_closed() {
            break;
        }
    }

    // Print CSV results to stdout.
    println!("index,status,ttfb_ms,total_time_ms,bytes");
    for r in &results {
        println!(
            "{},{},{:.3},{:.3},{}",
            r.index,
            r.status,
            r.ttfb.as_secs_f64() * 1000.0,
            r.total_time.as_secs_f64() * 1000.0,
            r.bytes_received,
        );
    }

    // Print summary to stderr.
    let stats = conn.stats();
    let path_stats = conn.path_stats().next();
    eprintln!("---");
    eprintln!("endpoint: {}", args.url);
    eprintln!(
        "requests: {} (+ {} warmup)",
        args.requests, args.warmup
    );
    if let Some(ps) = path_stats {
        eprintln!(
            "rtt: {:.3}ms (min: {:.3}ms)",
            ps.rtt.as_secs_f64() * 1000.0,
            ps.min_rtt.unwrap_or(ps.rtt).as_secs_f64() * 1000.0,
        );
    }
    eprintln!(
        "packets: sent={} recv={} lost={}",
        stats.sent, stats.recv, stats.lost,
    );
    eprintln!(
        "bytes: sent={} recv={}",
        stats.sent_bytes, stats.recv_bytes,
    );

    Ok(())
}

fn send_to(
    socket: &mio::net::UdpSocket,
    buf: &[u8],
    to: std::net::SocketAddr,
) -> Result<()> {
    loop {
        match socket.send_to(buf, to) {
            Ok(_) => return Ok(()),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
            Err(e) => bail!("send_to failed: {e}"),
        }
    }
}
