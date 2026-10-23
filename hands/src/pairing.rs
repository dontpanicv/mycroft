//! Pairing with the phone (docs/pairing.md §1): `hands pair --with BASE --pin PIN` (and `hands install --pair`)
//! makes sure the listener runs, then POSTs this machine's identity to `BASE/pair` over HTTPS pinned to `PIN`, and
//! stores the phone's Ed25519 public key in `paired.json`, which the listener checks every `auth` against.

use crate::serve::{VERSION, now_ms};
use crate::{listener, mdns, state, tls};
use serde_json::{Value, json};
use std::io::{self, Read, Write};
use std::net::{IpAddr, TcpStream, ToSocketAddrs};
use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

const TIMEOUT: Duration = Duration::from_secs(15);
/// The largest response accepted from the phone.
const MAX_RESPONSE: usize = 1 << 20;

// ---- paired.json ----

/// The paired phones, `[{ name, publicKey, pairedAt }]`; empty if the file is missing or unreadable.
pub fn load() -> Vec<Value> {
    std::fs::read(state::paired_json())
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default()
}

fn save(phones: &[Value]) -> io::Result<()> {
    state::ensure()?;
    let mut text = serde_json::to_string_pretty(phones).map_err(io::Error::other)?;
    text.push('\n');
    tls::write_private(&state::paired_json(), text.as_bytes())
}

/// The name of the paired phone with this raw Ed25519 public key.
pub fn phone_with_key(public_key: &[u8]) -> Option<String> {
    load().into_iter().find_map(|phone| {
        let key = tls::unbase64(phone["publicKey"].as_str()?)?;
        (key == public_key).then(|| phone["name"].as_str().unwrap_or("phone").to_string())
    })
}

/// Add a phone; pairing the same key again replaces its entry.
pub fn add(name: &str, public_key: &[u8]) -> io::Result<()> {
    let mut phones = load();
    phones.retain(|phone| {
        phone["publicKey"]
            .as_str()
            .and_then(tls::unbase64)
            .is_none_or(|key| key != public_key)
    });
    phones.push(json!({
        "name": name,
        "publicKey": tls::base64(public_key),
        "pairedAt": now_ms(),
    }));
    save(&phones)
}

/// Remove the phones named `name` (or whose public key is `name`); how many were removed.
pub fn remove(name: &str) -> io::Result<usize> {
    let mut phones = load();
    let before = phones.len();
    phones.retain(|phone| phone["name"] != name && phone["publicKey"] != name);
    let removed = before - phones.len();
    if removed > 0 {
        save(&phones)?;
    }
    Ok(removed)
}

// ---- this machine ----

pub struct Machine {
    /// Short name, e.g. `mac-mini`.
    pub name: String,
    /// e.g. `mac-mini.local`.
    pub hostname: String,
}

fn gethostname() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is writable for its length; gethostname NUL-terminates within it on success.
    if unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len() - 1) } != 0 {
        return "localhost".into();
    }
    let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
    String::from_utf8_lossy(&buffer[..end]).into_owned()
}

pub fn machine() -> Machine {
    // On macOS, the Bonjour name (`LocalHostName`) is what `<name>.local` resolves to; gethostname may be a name
    // DHCP handed out.
    let local = cfg!(target_os = "macos")
        .then(|| Command::new("/usr/sbin/scutil").args(["--get", "LocalHostName"]).output().ok())
        .flatten()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|name| !name.is_empty());
    match local {
        Some(name) => Machine {
            hostname: format!("{name}.local"),
            name,
        },
        None => {
            let hostname = gethostname();
            let name = hostname.split('.').next().unwrap_or(&hostname).to_string();
            Machine { name, hostname }
        }
    }
}

/// This machine's IPv4 addresses the phone may reach the listener on: all non-loopback, non-link-local ones, or
/// just `bind` when the listener is bound to one address.
pub fn addresses(bind: Option<IpAddr>) -> Vec<String> {
    if let Some(bind) = bind.filter(|bind| !bind.is_unspecified()) {
        return vec![bind.to_string()];
    }
    let mut addresses = Vec::new();
    let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs fills `list`, which is walked read-only and freed once.
    unsafe {
        if libc::getifaddrs(&mut list) != 0 {
            return addresses;
        }
        let mut entry = list;
        while !entry.is_null() {
            let address = (*entry).ifa_addr;
            let up = (*entry).ifa_flags & libc::IFF_UP as libc::c_uint != 0;
            if up && !address.is_null() && (*address).sa_family as i32 == libc::AF_INET {
                let ip = (*(address as *const libc::sockaddr_in)).sin_addr.s_addr;
                let ip = std::net::Ipv4Addr::from(u32::from_be(ip));
                let text = ip.to_string();
                if !ip.is_loopback() && !ip.is_link_local() && !addresses.contains(&text) {
                    addresses.push(text);
                }
            }
            entry = (*entry).ifa_next;
        }
        libc::freeifaddrs(list);
    }
    addresses
}

// ---- the pairing request ----

/// `https://host:port/path` from `BASE`.
#[derive(Debug, PartialEq)]
pub struct Base {
    pub host: String,
    pub port: u16,
    pub path: String,
}

pub fn parse_base(base: &str) -> Result<Base, String> {
    let invalid = || format!("{base} is not an https:// URL");
    let rest = base.trim().strip_prefix("https://").ok_or_else(invalid)?;
    let (authority, path) = match rest.find('/') {
        Some(slash) => (&rest[..slash], rest[slash..].trim_end_matches('/')),
        None => (rest, ""),
    };
    let (host, port) = if let Some(v6) = authority.strip_prefix('[') {
        let (host, after) = v6.split_once(']').ok_or_else(invalid)?;
        (host, after.strip_prefix(':'))
    } else {
        match authority.rsplit_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (authority, None),
        }
    };
    let port = match port {
        Some(port) => port.parse().map_err(|_| invalid())?,
        None => 443,
    };
    if host.is_empty() || path.contains(['?', '#']) {
        return Err(invalid());
    }
    Ok(Base {
        host: host.to_string(),
        port,
        path: path.to_string(),
    })
}

/// The pin as 32 bytes. Accepts curl's `sha256//` prefix.
pub fn parse_pin(pin: &str) -> Result<[u8; 32], String> {
    let text = pin.trim();
    let text = text.strip_prefix("sha256//").unwrap_or(text);
    tls::unbase64(text)
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| format!("{pin} is not a pin (base64 of a SHA-256)"))
}

/// What the phone answered.
pub struct Phone {
    pub name: String,
    pub public_key: Vec<u8>,
}

/// POST the pairing request to `BASE/pair` and return the phone's identity. Nothing is sent unless the phone's
/// certificate matches `pin`.
pub fn request(base: &Base, pin: [u8; 32], body: &Value) -> Result<Phone, String> {
    let address = (base.host.as_str(), base.port)
        .to_socket_addrs()
        .map_err(|error| format!("cannot resolve {}: {error}", base.host))?
        .next()
        .ok_or_else(|| format!("cannot resolve {}", base.host))?;
    let mut tcp = TcpStream::connect_timeout(&address, TIMEOUT)
        .map_err(|error| format!("cannot reach the phone at {address}: {error}"))?;
    tcp.set_read_timeout(Some(TIMEOUT)).map_err(|error| error.to_string())?;
    tcp.set_write_timeout(Some(TIMEOUT)).map_err(|error| error.to_string())?;
    let config = rustls::ClientConfig::builder_with_provider(tls::provider())
        .with_safe_default_protocol_versions()
        .map_err(|error| error.to_string())?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(tls::PinVerifier::new(pin)))
        .with_no_client_auth();
    let name = rustls::pki_types::ServerName::try_from(base.host.clone())
        .map_err(|error| format!("{}: {error}", base.host))?;
    let mut connection =
        rustls::ClientConnection::new(Arc::new(config), name).map_err(|error| error.to_string())?;
    // Finish the handshake, and with it the pin check, before a byte of the request is written.
    while connection.is_handshaking() {
        if let Err(error) = connection.complete_io(&mut tcp) {
            let pinned = error
                .get_ref()
                .and_then(|inner| inner.downcast_ref::<rustls::Error>())
                .is_some_and(|error| matches!(error, rustls::Error::InvalidCertificate(_)));
            return Err(if pinned {
                "the phone's certificate does not match the pin; nothing was sent".into()
            } else {
                format!("TLS handshake with the phone failed: {error}")
            });
        }
    }
    let mut stream = rustls::StreamOwned::new(connection, tcp);
    let body = serde_json::to_vec(body).map_err(|error| error.to_string())?;
    let host = if base.host.contains(':') {
        format!("[{}]:{}", base.host, base.port)
    } else {
        format!("{}:{}", base.host, base.port)
    };
    let head = format!(
        "POST {}/pair HTTP/1.1\r\nHost: {host}\r\nUser-Agent: hands/{VERSION}\r\nContent-Type: application/json\r\n\
         Accept: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        base.path,
        body.len()
    );
    let mut request = head.into_bytes();
    request.extend_from_slice(&body);
    stream
        .write_all(&request)
        .and_then(|()| stream.flush())
        .map_err(|error| format!("sending the pairing request failed: {error}"))?;
    let (status, body) = read_response(&mut stream)?;
    let text = String::from_utf8_lossy(&body);
    match status {
        200 => {}
        410 => {
            return Err(
                "this pairing command was already used or has expired; tap Add machine on the phone again".into(),
            );
        }
        404 => return Err("the phone does not know this pairing link; tap Add machine on the phone again".into()),
        400 => return Err(format!("the phone rejected the pairing request: {}", text.trim())),
        _ => return Err(format!("the phone answered HTTP {status}: {}", text.trim())),
    }
    let reply: Value =
        serde_json::from_slice(&body).map_err(|error| format!("the phone's answer is not JSON: {error}"))?;
    let name = reply["phoneName"]
        .as_str()
        .filter(|name| !name.trim().is_empty())
        .ok_or("the phone's answer has no phoneName")?;
    let public_key = reply["publicKey"]
        .as_str()
        .and_then(tls::unbase64)
        .filter(|key| key.len() == 32)
        .ok_or("the phone's answer has no valid publicKey (base64 of 32 bytes)")?;
    Ok(Phone {
        name: name.trim().to_string(),
        public_key,
    })
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

/// Decode a complete chunked body; `None` while it is incomplete.
fn dechunk(mut data: &[u8]) -> Option<Vec<u8>> {
    let mut body = Vec::new();
    loop {
        let line_end = find(data, b"\r\n")?;
        let size = std::str::from_utf8(&data[..line_end]).ok()?;
        let size = usize::from_str_radix(size.split(';').next()?.trim(), 16).ok()?;
        data = &data[line_end + 2..];
        if size == 0 {
            return Some(body);
        }
        if data.len() < size + 2 {
            return None;
        }
        body.extend_from_slice(&data[..size]);
        data = &data[size + 2..];
    }
}

/// Read an HTTP/1.1 response: `(status, body)`. Stops at the end of the body or of the connection.
fn read_response(stream: &mut impl Read) -> Result<(u16, Vec<u8>), String> {
    let mut data = Vec::new();
    let mut buffer = [0u8; 8192];
    let mut ended = false;
    loop {
        if let Some(head_end) = find(&data, b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&data[..head_end]).to_string();
            let mut lines = head.split("\r\n");
            let status: u16 = lines
                .next()
                .and_then(|line| line.split(' ').nth(1))
                .and_then(|code| code.parse().ok())
                .ok_or("the phone's answer is not HTTP")?;
            let header = |name: &str| {
                head.split("\r\n").skip(1).find_map(|line| {
                    let (key, value) = line.split_once(':')?;
                    key.trim().eq_ignore_ascii_case(name).then(|| value.trim().to_string())
                })
            };
            let rest = &data[head_end + 4..];
            if header("transfer-encoding").is_some_and(|value| value.eq_ignore_ascii_case("chunked")) {
                match dechunk(rest) {
                    Some(body) => return Ok((status, body)),
                    None if ended => return Err("the phone's answer ended early".into()),
                    None => {}
                }
            } else if let Some(length) = header("content-length").and_then(|value| value.parse::<usize>().ok()) {
                if rest.len() >= length {
                    return Ok((status, rest[..length].to_vec()));
                }
                if ended {
                    return Err("the phone's answer ended early".into());
                }
            } else if ended {
                return Ok((status, rest.to_vec()));
            }
        } else if ended {
            return Err("the phone closed the connection without answering".into());
        }
        if data.len() > MAX_RESPONSE {
            return Err("the phone's answer is too large".into());
        }
        match stream.read(&mut buffer) {
            Ok(0) => ended = true,
            Ok(count) => data.extend_from_slice(&buffer[..count]),
            // A peer that closes without close_notify.
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => ended = true,
            Err(error) => return Err(format!("reading the phone's answer failed: {error}")),
        }
    }
}

/// The name the phone should try first for this machine. On Linux a bare `gethostname` usually resolves nowhere the
/// phone looks, so while the listener advertises itself it is `<name>.local`, which the listener's mDNS responder
/// answers for (mdns.rs); the addresses only last until DHCP hands out others.
fn reported_hostname(machine: &Machine, bind: Option<IpAddr>) -> String {
    let bind = bind.unwrap_or(IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED));
    if cfg!(target_os = "linux") && mdns::enabled(bind) {
        format!("{}.local", machine.name)
    } else {
        machine.hostname.clone()
    }
}

/// The request body of docs/pairing.md.
pub fn request_body(port: u16, cert_sha256: &str, bind: Option<IpAddr>) -> Value {
    let machine = machine();
    json!({
        "name": machine.name,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "version": VERSION,
        "port": port,
        "certSha256": cert_sha256,
        "addresses": addresses(bind),
        "hostname": reported_hostname(&machine, bind),
    })
}

/// Make sure the listener runs (started from `binary`, waiting up to `grace` for a service to start it first),
/// pair with the phone at `base`, and store it. Returns the line to print.
pub fn pair(base: &Base, pin: [u8; 32], binary: &Path, bind: Option<IpAddr>, grace: Duration) -> Result<String, String> {
    let identity = listener::identity().map_err(|error| format!("listener identity: {error}"))?;
    listener::ensure_running(binary, bind, grace)?;
    let body = request_body(identity.port, &identity.cert.sha256, bind);
    let phone = request(base, pin, &body)?;
    add(&phone.name, &phone.public_key).map_err(|error| format!("saving paired.json: {error}"))?;
    let kind = if cfg!(target_os = "macos") { "Mac" } else { "machine" };
    Ok(format!("Paired with {}. Mycroft can use this {kind} now.", phone.name))
}

/// Parse `--with BASE --pin PIN [--bind ADDR]`-style options shared by `pair` and `install`.
pub fn parse_bind(text: &str) -> Result<IpAddr, String> {
    text.parse().map_err(|_| format!("{text} is not an IP address"))
}

/// `hands pair --with BASE --pin PIN [--bind ADDR]`.
pub fn main(args: &[String]) -> i32 {
    const USAGE: &str = "usage: hands pair --with <BASE> --pin <PIN> [--bind <ADDR>]";
    let (mut base, mut pin, mut bind) = (None, None, None);
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        let value = args.as_slice().first().cloned();
        match (arg.as_str(), value) {
            ("--with", Some(value)) => base = Some(value),
            ("--pin", Some(value)) => pin = Some(value),
            ("--bind", Some(value)) => bind = Some(value),
            _ => {
                eprintln!("{USAGE}");
                return 2;
            }
        }
        args.next();
    }
    let (Some(base), Some(pin)) = (base, pin) else {
        eprintln!("{USAGE}");
        return 2;
    };
    let parsed = (|| {
        let bind = bind.as_deref().map(parse_bind).transpose()?;
        Ok::<_, String>((parse_base(&base)?, parse_pin(&pin)?, bind))
    })();
    let (base, pin, bind) = match parsed {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!("hands pair: {error}");
            return 2;
        }
    };
    let binary = match std::env::current_exe() {
        Ok(binary) => binary,
        Err(error) => {
            eprintln!("hands pair: {error}");
            return 1;
        }
    };
    match pair(&base, pin, &binary, bind, Duration::ZERO) {
        Ok(line) => {
            println!("{line}");
            0
        }
        Err(error) => {
            eprintln!("hands pair: {error}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_base_urls() {
        let base = parse_base("https://192.168.1.20:50111/abcd2345").unwrap();
        assert_eq!(
            base,
            Base { host: "192.168.1.20".into(), port: 50111, path: "/abcd2345".into() }
        );
        let base = parse_base("https://[fe80::1]:8443/S/").unwrap();
        assert_eq!((base.host.as_str(), base.port, base.path.as_str()), ("fe80::1", 8443, "/S"));
        assert_eq!(parse_base("https://phone.local").unwrap().port, 443);
        assert!(parse_base("http://1.2.3.4:5/S").is_err());
        assert!(parse_base("https://1.2.3.4:x/S").is_err());
    }

    #[test]
    fn reports_a_local_name_on_linux_while_advertising() {
        let machine = Machine { name: "box".into(), hostname: "box".into() };
        let lan = "192.168.1.5".parse().ok();
        let expected = if cfg!(target_os = "linux") { "box.local" } else { "box" };
        if std::env::var_os("HANDS_MDNS").is_none() {
            assert_eq!(reported_hostname(&machine, lan), expected);
            assert_eq!(reported_hostname(&machine, None), expected);
            // Bound to loopback, nothing is advertised.
            assert_eq!(reported_hostname(&machine, "127.0.0.1".parse().ok()), "box");
        }
    }

    #[test]
    fn parses_pins() {
        let pin = tls::base64(&[7u8; 32]);
        assert_eq!(parse_pin(&pin).unwrap(), [7u8; 32]);
        assert_eq!(parse_pin(&format!("sha256//{pin}")).unwrap(), [7u8; 32]);
        assert!(parse_pin("abc").is_err());
    }

    #[test]
    fn reads_responses() {
        let mut plain: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}extra";
        assert_eq!(read_response(&mut plain).unwrap(), (200, b"{}".to_vec()));
        let mut chunked: &[u8] = b"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n2\r\n{\"\r\n1\r\n}\r\n0\r\n\r\n";
        assert_eq!(read_response(&mut chunked).unwrap(), (200, b"{\"}".to_vec()));
        let mut until_close: &[u8] = b"HTTP/1.0 410 Gone\r\n\r\ngone";
        assert_eq!(read_response(&mut until_close).unwrap(), (410, b"gone".to_vec()));
        let mut short: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n{}";
        assert!(read_response(&mut short).is_err());
    }
}
