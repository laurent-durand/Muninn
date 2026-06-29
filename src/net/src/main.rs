// src/net/src/main.rs
// muninn-net — reads /proc/net/dev in a tight loop, computes per-interface
// bandwidth (bytes/sec, packets/sec) and emits JSON lines to stdout.
// Consumed by the Go broker (src/api).

use anyhow::{Context, Result};
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::time::{Duration, Instant};
use tokio::time;
use tracing::{info, warn};

const INTERVAL: Duration = Duration::from_secs(1);
const PROC_NET_DEV: &str = "/proc/net/dev";

#[derive(Debug, Clone, Default)]
struct RawStats {
    rx_bytes:   u64,
    tx_bytes:   u64,
    rx_packets: u64,
    tx_packets: u64,
    rx_errors:  u64,
    tx_errors:  u64,
    rx_dropped: u64,
    tx_dropped: u64,
}

#[derive(Debug, Serialize)]
struct NetSnapshot {
    timestamp_ms: u128,
    ifaces:       Vec<IfaceStats>,
}

#[derive(Debug, Serialize)]
struct IfaceStats {
    iface:      String,
    rx_bps:     f64,
    tx_bps:     f64,
    rx_pps:     f64,
    tx_pps:     f64,
    rx_errors:  u64,
    tx_errors:  u64,
    rx_dropped: u64,
    tx_dropped: u64,
    rx_bytes:   u64,
    tx_bytes:   u64,
}

fn parse_proc_net_dev() -> Result<HashMap<String, RawStats>> {
    let content = fs::read_to_string(PROC_NET_DEV)
        .with_context(|| format!("cannot read {PROC_NET_DEV}"))?;

    let mut map = HashMap::new();
    for line in content.lines().skip(2) {
        let line = line.trim();
        let colon = match line.find(':') {
            Some(i) => i,
            None    => continue,
        };
        let name   = line[..colon].trim().to_owned();
        let fields: Vec<u64> = line[colon + 1..]
            .split_whitespace()
            .filter_map(|s| s.parse().ok())
            .collect();

        if fields.len() < 16 {
            warn!("unexpected field count for {name}: {}", fields.len());
            continue;
        }

        map.insert(name, RawStats {
            rx_bytes:   fields[0],
            rx_packets: fields[1],
            rx_errors:  fields[2],
            rx_dropped: fields[3],
            tx_bytes:   fields[8],
            tx_packets: fields[9],
            tx_errors:  fields[10],
            tx_dropped: fields[11],
        });
    }
    Ok(map)
}

fn delta(curr: u64, prev: u64, dt: f64) -> f64 {
    if dt == 0.0 { return 0.0; }
    curr.saturating_sub(prev) as f64 / dt
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter("muninn_net=info")
        .with_writer(std::io::stderr)
        .init();

    info!("muninn-net starting, interval={}ms", INTERVAL.as_millis());

    let mut prev     = parse_proc_net_dev()?;
    let mut prev_ts  = Instant::now();
    let mut interval = time::interval(INTERVAL);

    loop {
        interval.tick().await;

        let curr   = parse_proc_net_dev()?;
        let now    = Instant::now();
        let dt     = now.duration_since(prev_ts).as_secs_f64();
        prev_ts    = now;

        let mut ifaces = Vec::new();
        for (name, c) in &curr {
            let p = prev.get(name).cloned().unwrap_or_default();
            ifaces.push(IfaceStats {
                iface:      name.clone(),
                rx_bps:     delta(c.rx_bytes,   p.rx_bytes,   dt) * 8.0,
                tx_bps:     delta(c.tx_bytes,   p.tx_bytes,   dt) * 8.0,
                rx_pps:     delta(c.rx_packets, p.rx_packets, dt),
                tx_pps:     delta(c.tx_packets, p.tx_packets, dt),
                rx_errors:  c.rx_errors,
                tx_errors:  c.tx_errors,
                rx_dropped: c.rx_dropped,
                tx_dropped: c.tx_dropped,
                rx_bytes:   c.rx_bytes,
                tx_bytes:   c.tx_bytes,
            });
        }

        ifaces.sort_by(|a, b| b.rx_bps.partial_cmp(&a.rx_bps).unwrap());

        let snap = NetSnapshot {
            timestamp_ms: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_millis(),
            ifaces,
        };

        println!("{}", serde_json::to_string(&snap)?);
        prev = curr;
    }
}
