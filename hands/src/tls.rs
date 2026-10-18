//! TLS and the small amount of cryptography around it (docs/pairing.md): the listener's long-lived self-signed
//! certificate, the SPKI pin `hands pair` checks the phone's certificate against, and the encodings both use.
//!
//! ring is the only crypto provider: TLS (through rustls), SHA-256, random bytes and Ed25519 verification.

use crate::state;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use ring::rand::SecureRandom;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, WebPkiSupportedAlgorithms};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::{CertificateError, DigitallySignedStruct, SignatureScheme};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::sync::Arc;

pub fn base64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

pub fn unbase64(text: &str) -> Option<Vec<u8>> {
    STANDARD.decode(text.trim()).ok()
}

pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    let digest = ring::digest::digest(&ring::digest::SHA256, bytes);
    digest.as_ref().try_into().expect("SHA-256 is 32 bytes")
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `N` bytes from the system's secure random source.
pub fn random<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    ring::rand::SystemRandom::new()
        .fill(&mut bytes)
        .expect("the system random source failed");
    bytes
}

pub fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

/// The string the phone signs to authenticate: `mycroft-auth:<certSha256 hex>:<nonce base64>`.
pub fn auth_message(cert_sha256: &str, nonce: &str) -> String {
    format!("mycroft-auth:{cert_sha256}:{nonce}")
}

/// Whether `signature` is a valid Ed25519 signature by the raw 32-byte `public_key` over `message`.
pub fn ed25519_verify(public_key: &[u8], message: &[u8], signature: &[u8]) -> bool {
    public_key.len() == 32
        && signature.len() == 64
        && ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, public_key)
            .verify(message, signature)
            .is_ok()
}

/// Write `contents` to `path` with mode 0600, replacing it atomically.
pub fn write_private(path: &Path, contents: &[u8]) -> io::Result<()> {
    let temporary = path.with_extension(format!("tmp{}", std::process::id()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(contents)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&temporary, path)
}

/// The listener's certificate and key (`listener-cert.pem`, `listener-key.pem`).
pub struct Certificate {
    pub der: CertificateDer<'static>,
    pub key: PrivateKeyDer<'static>,
    /// Lowercase hex SHA-256 of the certificate DER: what the phone pins.
    pub sha256: String,
}

/// Load the listener's certificate, or generate and keep a self-signed ECDSA P-256 one. The caller serialises
/// concurrent first starts (`listener::identity`).
pub fn certificate(name: &str) -> io::Result<Certificate> {
    let dir = state::dir();
    let (cert_path, key_path) = (dir.join("listener-cert.pem"), dir.join("listener-key.pem"));
    if cert_path.exists() && key_path.exists() {
        let invalid = |error: rustls::pki_types::pem::Error| {
            io::Error::new(io::ErrorKind::InvalidData, format!("{error}"))
        };
        let der = CertificateDer::from_pem_file(&cert_path).map_err(invalid)?;
        let key = PrivateKeyDer::from_pem_file(&key_path).map_err(invalid)?;
        let sha256 = hex(&sha256(&der));
        return Ok(Certificate { der, key, sha256 });
    }
    let failed = |error: rcgen::Error| io::Error::other(format!("generating the certificate: {error}"));
    let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256).map_err(failed)?;
    let mut params = rcgen::CertificateParams::new(vec!["hands".to_string()]).map_err(failed)?;
    params.distinguished_name = rcgen::DistinguishedName::new();
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, format!("Mycroft hands on {name}"));
    let cert = params.self_signed(&key).map_err(failed)?;
    // The key first: a certificate without its key would be reloaded and fail.
    write_private(&key_path, key.serialize_pem().as_bytes())?;
    write_private(&cert_path, cert.pem().as_bytes())?;
    let der = cert.der().clone();
    let sha256 = hex(&sha256(&der));
    let key = PrivateKeyDer::try_from(key.serialize_der())
        .map_err(|error| io::Error::other(error.to_string()))?;
    Ok(Certificate { der, key, sha256 })
}

/// The DER of the SubjectPublicKeyInfo of an X.509 certificate, with its tag and length.
pub fn spki(certificate: &[u8]) -> Option<&[u8]> {
    // Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version OPTIONAL, serialNumber, signature, issuer,
    // validity, subject, subjectPublicKeyInfo, ... }, ... }
    let (certificate, _) = der_element(certificate, 0x30)?;
    let (tbs, _) = der_element(der_contents(certificate)?, 0x30)?;
    let mut rest = der_contents(tbs)?;
    if rest.first() == Some(&0xa0) {
        rest = der_element(rest, 0xa0)?.1;
    }
    for tag in [0x02, 0x30, 0x30, 0x30, 0x30] {
        rest = der_element(rest, tag)?.1;
    }
    Some(der_element(rest, 0x30)?.0)
}

/// Split the DER element at the start of `input`, which must have `tag`, from what follows it.
fn der_element(input: &[u8], tag: u8) -> Option<(&[u8], &[u8])> {
    if *input.first()? != tag {
        return None;
    }
    let first = *input.get(1)? as usize;
    let (length, header) = if first < 0x80 {
        (first, 2)
    } else {
        let count = first & 0x7f;
        if count == 0 || count > 4 {
            return None;
        }
        let bytes = input.get(2..2 + count)?;
        (bytes.iter().fold(0usize, |length, byte| length << 8 | *byte as usize), 2 + count)
    };
    let end = header.checked_add(length)?;
    (end <= input.len()).then(|| input.split_at(end))
}

/// The contents of a DER element, without its tag and length.
fn der_contents(element: &[u8]) -> Option<&[u8]> {
    let first = *element.get(1)? as usize;
    let header = if first < 0x80 { 2 } else { 2 + (first & 0x7f) };
    element.get(header..)
}

/// `base64(sha256(SubjectPublicKeyInfo DER))` of a certificate: curl's `--pinnedpubkey sha256//` value.
#[cfg(test)]
pub fn spki_pin(certificate: &[u8]) -> Option<String> {
    spki(certificate).map(|spki| base64(&sha256(spki)))
}

/// Accepts exactly the server certificate whose SPKI SHA-256 is the pin, as `curl -k --pinnedpubkey` does: no CA,
/// no name and no validity checks. The handshake signature is still verified against that certificate's key, so
/// only the holder of the pinned key can complete the handshake.
#[derive(Debug)]
pub struct PinVerifier {
    pin: [u8; 32],
    algorithms: WebPkiSupportedAlgorithms,
}

impl PinVerifier {
    pub fn new(pin: [u8; 32]) -> PinVerifier {
        PinVerifier {
            pin,
            algorithms: provider().signature_verification_algorithms,
        }
    }
}

impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let spki = spki(end_entity).ok_or(rustls::Error::InvalidCertificate(CertificateError::BadEncoding))?;
        if sha256(spki) == self.pin {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spki_matches_the_generated_key() {
        let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256).unwrap();
        let cert = rcgen::CertificateParams::new(vec!["x".into()])
            .unwrap()
            .self_signed(&key)
            .unwrap();
        assert_eq!(spki(cert.der()).unwrap(), rcgen::PublicKeyData::subject_public_key_info(&key).as_slice());
        assert_eq!(spki_pin(cert.der()).unwrap(), base64(&sha256(&rcgen::PublicKeyData::subject_public_key_info(&key))));
        assert_eq!(spki(&cert.der()[..40]), None);
        assert_eq!(spki(b"\x30\x84\xff\xff\xff\xff"), None);
    }

    /// The vector in docs/pairing.md ("Test vectors"); the iOS app tests against the same values.
    #[test]
    fn auth_test_vector() {
        let seed = hex_bytes("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
        let cert_sha256 = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
        let nonce: Vec<u8> = (0x20..0x40).collect();
        let nonce = base64(&nonce);
        assert_eq!(nonce, "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=");
        let message = auth_message(cert_sha256, &nonce);
        assert_eq!(
            message,
            "mycroft-auth:000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f:\
             ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8="
        );
        let pair = ring::signature::Ed25519KeyPair::from_seed_unchecked(&seed).unwrap();
        use ring::signature::KeyPair;
        let public_key = pair.public_key().as_ref().to_vec();
        assert_eq!(base64(&public_key), "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=");
        let signature = pair.sign(message.as_bytes());
        assert_eq!(base64(signature.as_ref()), EXPECTED_SIGNATURE);
        assert!(ed25519_verify(&public_key, message.as_bytes(), signature.as_ref()));
        assert!(!ed25519_verify(&public_key, b"mycroft-auth:other", signature.as_ref()));
    }

    /// The PIN vector in docs/pairing.md: the P-256 public key of private scalar 1 (the generator).
    #[test]
    fn pin_test_vector() {
        let spki = hex_bytes(
            "3059301306072a8648ce3d020106082a8648ce3d030107034200046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a\
             13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
        );
        assert_eq!(base64(&sha256(&spki)), "XNJS+wzokyQ2+vjM0QQJgbie5K1rn+niorfnGqyyfNM=");
        let verifier = PinVerifier::new(sha256(&spki));
        assert_eq!(verifier.pin, sha256(&spki));
    }

    const EXPECTED_SIGNATURE: &str =
        "qKa3C0FH/CS/urmfJt5xfB2h0Tsk4YQrtxDZg6nxzkTrv5ZBl2ILTqyAMZZr3eSg/o1LivawmAeBjzDQsUxPDg==";

    fn hex_bytes(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|index| u8::from_str_radix(&text[index..index + 2], 16).unwrap())
            .collect()
    }
}
