//! The phone's side of docs/pairing.md for the tests: a fake HTTPS server with a self-signed certificate (the
//! app's pairing server), and a WebSocket client that pins the listener's certificate and authenticates with an
//! Ed25519 key.

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ring::signature::{Ed25519KeyPair, KeyPair};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tungstenite::{Message, WebSocket};

pub fn base64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

pub fn unbase64(text: &str) -> Vec<u8> {
    STANDARD.decode(text).unwrap()
}

pub fn sha256(bytes: &[u8]) -> Vec<u8> {
    ring::digest::digest(&ring::digest::SHA256, bytes).as_ref().to_vec()
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// A phone's Ed25519 identity.
pub struct PhoneKey(Ed25519KeyPair);

impl PhoneKey {
    pub fn from_seed(seed: u8) -> PhoneKey {
        PhoneKey(Ed25519KeyPair::from_seed_unchecked(&[seed; 32]).unwrap())
    }

    pub fn public(&self) -> Vec<u8> {
        self.0.public_key().as_ref().to_vec()
    }

    pub fn sign(&self, message: &str) -> Vec<u8> {
        self.0.sign(message.as_bytes()).as_ref().to_vec()
    }
}

/// What the fake phone answers: status, content type, body.
pub type Reply = (u16, &'static str, Vec<u8>);

/// One request the fake phone received.
#[derive(Clone, Debug)]
pub struct Received {
    pub method: String,
    pub path: String,
    pub body: Vec<u8>,
}

/// The app's pairing server: HTTPS with a self-signed ECDSA P-256 certificate.
pub struct FakePhone {
    pub port: u16,
    /// `base64(sha256(SPKI))`, curl's `--pinnedpubkey sha256//` value.
    pub pin: String,
    pub requests: Arc<Mutex<Vec<Received>>>,
    /// TCP connections accepted, and application bytes read from them.
    pub connections: Arc<AtomicUsize>,
    pub bytes: Arc<AtomicUsize>,
}

impl FakePhone {
    pub fn start(handler: impl Fn(&Received) -> Reply + Send + Sync + 'static) -> FakePhone {
        let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256).unwrap();
        let cert = rcgen::CertificateParams::new(vec!["phone".into()]).unwrap().self_signed(&key).unwrap();
        let pin = base64(&sha256(&rcgen::PublicKeyData::subject_public_key_info(&key)));
        let config = rustls::ServerConfig::builder_with_provider(provider())
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![cert.der().clone()],
                PrivateKeyDer::try_from(key.serialize_der()).unwrap(),
            )
            .unwrap();
        let config = Arc::new(config);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let phone = FakePhone {
            port,
            pin,
            requests: Arc::default(),
            connections: Arc::default(),
            bytes: Arc::default(),
        };
        let (requests, connections, bytes) =
            (phone.requests.clone(), phone.connections.clone(), phone.bytes.clone());
        let handler = Arc::new(handler);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                connections.fetch_add(1, Ordering::SeqCst);
                let (config, requests, bytes, handler) =
                    (config.clone(), requests.clone(), bytes.clone(), handler.clone());
                std::thread::spawn(move || {
                    let _ = serve_one(config, stream, &requests, &bytes, &*handler);
                });
            }
        });
        phone
    }

    pub fn base(&self, setup: &str) -> String {
        format!("https://127.0.0.1:{}/{setup}", self.port)
    }

    pub fn received(&self) -> Vec<Received> {
        self.requests.lock().unwrap().clone()
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn serve_one(
    config: Arc<rustls::ServerConfig>,
    tcp: TcpStream,
    requests: &Mutex<Vec<Received>>,
    bytes: &AtomicUsize,
    handler: &dyn Fn(&Received) -> Reply,
) -> std::io::Result<()> {
    tcp.set_read_timeout(Some(Duration::from_secs(10)))?;
    let connection = rustls::ServerConnection::new(config).unwrap();
    let mut stream = rustls::StreamOwned::new(connection, tcp);
    let mut data = Vec::new();
    let mut buffer = [0u8; 8192];
    let request = loop {
        if let Some(end) = find(&data, b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&data[..end]).to_string();
            let length = head
                .lines()
                .find_map(|line| {
                    let (key, value) = line.split_once(':')?;
                    key.eq_ignore_ascii_case("content-length").then(|| value.trim().parse::<usize>().ok())?
                })
                .unwrap_or(0);
            if data.len() >= end + 4 + length {
                let mut words = head.split(' ');
                break Received {
                    method: words.next().unwrap_or_default().to_string(),
                    path: words.next().unwrap_or_default().to_string(),
                    body: data[end + 4..end + 4 + length].to_vec(),
                };
            }
        }
        let count = stream.read(&mut buffer)?;
        if count == 0 {
            return Ok(());
        }
        bytes.fetch_add(count, Ordering::SeqCst);
        data.extend_from_slice(&buffer[..count]);
    };
    requests.lock().unwrap().push(request.clone());
    let (status, content_type, body) = handler(&request);
    let head = format!(
        "HTTP/1.1 {status} X\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(&body)?;
    stream.flush()?;
    stream.conn.send_close_notify();
    stream.flush()
}

/// The JSON reply of a phone that accepts pairing.
pub fn paired_reply(name: &str, key: &PhoneKey) -> Reply {
    let body = json!({ "phoneName": name, "publicKey": base64(&key.public()) });
    (200, "application/json", body.to_string().into_bytes())
}

/// Accepts exactly the certificate with this SHA-256, as the app pins `certSha256`.
#[derive(Debug)]
struct CertPin(Vec<u8>);

impl ServerCertVerifier for CertPin {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if sha256(end_entity) == self.0 {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("certificate does not match".into()))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &provider().signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &provider().signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        provider().signature_verification_algorithms.supported_schemes()
    }
}

/// Accepts any certificate (with a valid handshake signature), for tests that do not care which.
#[derive(Debug)]
pub struct AnyCert;

impl AnyCert {
    pub fn new() -> Arc<AnyCert> {
        Arc::new(AnyCert)
    }
}

impl ServerCertVerifier for AnyCert {
    fn verify_server_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        CertPin(Vec::new()).verify_tls12_signature(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        CertPin(Vec::new()).verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        provider().signature_verification_algorithms.supported_schemes()
    }
}

pub type Socket = WebSocket<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>;

/// Connect to the listener on 127.0.0.1:`port` at `path`, pinning the certificate with SHA-256 `cert_sha256` (hex).
pub fn connect(port: u16, cert_sha256: &str, path: &str) -> Result<Socket, tungstenite::Error> {
    let pin: Vec<u8> = (0..cert_sha256.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&cert_sha256[index..index + 2], 16).unwrap())
        .collect();
    let config = rustls::ClientConfig::builder_with_provider(provider())
        .with_safe_default_protocol_versions()
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(CertPin(pin)))
        .with_no_client_auth();
    let tcp = TcpStream::connect(("127.0.0.1", port)).unwrap();
    tcp.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let connection =
        rustls::ClientConnection::new(Arc::new(config), ServerName::try_from("hands").unwrap()).unwrap();
    let stream = rustls::StreamOwned::new(connection, tcp);
    tungstenite::client(format!("wss://127.0.0.1:{port}{path}"), stream)
        .map(|(socket, _)| socket)
        .map_err(|error| match error {
            tungstenite::HandshakeError::Failure(error) => error,
            tungstenite::HandshakeError::Interrupted(_) => tungstenite::Error::ConnectionClosed,
        })
}

/// The next text message as JSON.
pub fn read_json(socket: &mut Socket) -> Value {
    loop {
        match socket.read().unwrap() {
            Message::Text(text) => return serde_json::from_str(text.as_str()).unwrap(),
            Message::Ping(_) | Message::Pong(_) => {}
            other => panic!("expected a text message, got {other:?}"),
        }
    }
}

/// Whether the server ends the connection (a close frame or the end of the stream) within a few seconds.
pub fn closes(socket: &mut Socket) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match socket.read() {
            Ok(Message::Close(_)) | Err(_) => return true,
            Ok(_) => {}
        }
    }
    false
}

/// The listener's port and certificate hash from its state dir.
pub fn listener_identity(state: &Path) -> (u16, String) {
    let listener: Value = serde_json::from_slice(&std::fs::read(state.join("listener.json")).unwrap()).unwrap();
    let pem = std::fs::read_to_string(state.join("listener-cert.pem")).unwrap();
    let body: String = pem.lines().filter(|line| !line.starts_with("-----")).collect();
    (listener["port"].as_u64().unwrap() as u16, hex(&sha256(&unbase64(&body))))
}

/// `hello`, then `auth` signed by `key` over `signed(cert_sha256, nonce)`; the server's answer.
pub fn authenticate(socket: &mut Socket, key: &PhoneKey, sign: impl Fn(&str) -> String) -> Value {
    let hello = read_json(socket);
    assert_eq!(hello["type"], "hello");
    let nonce = hello["nonce"].as_str().unwrap();
    assert_eq!(unbase64(nonce).len(), 32);
    let auth = json!({
        "type": "auth",
        "publicKey": base64(&key.public()),
        "signature": base64(&key.sign(&sign(nonce))),
    });
    socket.send(Message::text(auth.to_string())).unwrap();
    read_json(socket)
}
