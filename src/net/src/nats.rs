// src/net/src/nats.rs
// NATS publisher for muninn-net.
// Publishes NetSnapshot messages to "muninn.net" subject in addition
// to writing JSON lines to stdout.

use anyhow::Result;
use std::time::Duration;

/// Minimal NATS client — publishes a single message via raw TCP.
/// Avoids the full async_nats crate to keep the binary small.
pub struct NatsPub {
    stream: std::net::TcpStream,
}

impl NatsPub {
    pub fn connect(url: &str) -> Result<Self> {
        // url: "nats://host:port"
        let addr = url
            .trim_start_matches("nats://")
            .to_string();
        let stream = std::net::TcpStream::connect(&addr)?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;

        let mut pub_ = NatsPub { stream };
        pub_.read_info()?;
        pub_.send_connect()?;
        Ok(pub_)
    }

    fn read_info(&mut self) -> Result<()> {
        use std::io::BufRead;
        let mut r = std::io::BufReader::new(&self.stream);
        let mut line = String::new();
        r.read_line(&mut line)?;
        // INFO {...}\r\n  — we just consume it
        Ok(())
    }

    fn send_connect(&mut self) -> Result<()> {
        use std::io::Write;
        let msg = b"CONNECT {\"verbose\":false,\"pedantic\":false,\"name\":\"muninn-net\"}\r\n";
        self.stream.write_all(msg)?;
        Ok(())
    }

    /// Publish payload to subject.
    pub fn publish(&mut self, subject: &str, payload: &[u8]) -> Result<()> {
        use std::io::Write;
        let header = format!("PUB {} {}\r\n", subject, payload.len());
        self.stream.write_all(header.as_bytes())?;
        self.stream.write_all(payload)?;
        self.stream.write_all(b"\r\n")?;
        Ok(())
    }
}
