//! Bonjour (docs/pairing.md §3): the listener advertises `_mycroft-hands._tcp` with TXT `name`, `version` and `cert`
//! (the first 16 hex digits of `certSha256`), so the phone can find a paired machine whose address changed. Best
//! effort: a failure is logged and nothing else depends on it.
//!
//! macOS registers with the system's mDNSResponder through `dns_sd`; Linux runs the pure-Rust `mdns-sd` responder,
//! which also answers for `<name>.local`, the hostname pairing reports there (pairing.rs).
//! Skipped when the listener is bound to a loopback address; `HANDS_MDNS=0` turns it off, `HANDS_MDNS=1` forces it.

use crate::serve::VERSION;
use std::net::IpAddr;

pub const SERVICE: &str = "_mycroft-hands._tcp";

/// Keeps the advertisement alive; dropping it withdraws it.
pub struct Advertisement(#[allow(dead_code)] platform::Handle);

/// Whether a listener bound to `bind` advertises itself (and, on Linux, answers for `<name>.local`).
pub fn enabled(bind: IpAddr) -> bool {
    match std::env::var("HANDS_MDNS").as_deref() {
        Ok("0") => false,
        Ok("1") => true,
        _ => !bind.is_loopback(),
    }
}

pub fn advertise(name: &str, port: u16, cert_sha256: &str, bind: IpAddr) -> Option<Advertisement> {
    if !enabled(bind) {
        return None;
    }
    let cert = &cert_sha256[..cert_sha256.len().min(16)];
    let txt = [("name", name), ("version", VERSION), ("cert", cert)];
    match platform::register(name, port, &txt) {
        Ok(handle) => Some(Advertisement(handle)),
        Err(error) => {
            eprintln!("hands: Bonjour advertisement failed: {error}");
            None
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::ffi::{CString, c_char, c_void};

    type ServiceRef = *mut c_void;

    // dns_sd.h, in libSystem.
    unsafe extern "C" {
        fn DNSServiceRegister(
            service: *mut ServiceRef,
            flags: u32,
            interface_index: u32,
            name: *const c_char,
            regtype: *const c_char,
            domain: *const c_char,
            host: *const c_char,
            port: u16,
            txt_length: u16,
            txt_record: *const c_void,
            callback: *const c_void,
            context: *mut c_void,
        ) -> i32;
        fn DNSServiceRefDeallocate(service: ServiceRef);
    }

    pub struct Handle(ServiceRef);

    // SAFETY: the reference is only deallocated, once, by its owner.
    unsafe impl Send for Handle {}

    impl Drop for Handle {
        fn drop(&mut self) {
            // SAFETY: a reference DNSServiceRegister returned, deallocated once.
            unsafe { DNSServiceRefDeallocate(self.0) };
        }
    }

    pub fn register(name: &str, port: u16, txt: &[(&str, &str)]) -> Result<Handle, String> {
        let mut record = Vec::new();
        for (key, value) in txt {
            let entry = format!("{key}={value}");
            let entry = &entry.as_bytes()[..entry.len().min(255)];
            record.push(entry.len() as u8);
            record.extend_from_slice(entry);
        }
        let name = CString::new(name).map_err(|error| error.to_string())?;
        let regtype = CString::new(super::SERVICE).expect("no NUL");
        let mut service: ServiceRef = std::ptr::null_mut();
        // SAFETY: valid NUL-terminated strings and a TXT buffer that outlive the call; no callback, so no results
        // need processing (mDNSResponder renames on a conflict by itself).
        let status = unsafe {
            DNSServiceRegister(
                &mut service,
                0,
                0,
                name.as_ptr(),
                regtype.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                port.to_be(),
                record.len() as u16,
                record.as_ptr().cast(),
                std::ptr::null(),
                std::ptr::null_mut(),
            )
        };
        if status != 0 || service.is_null() {
            return Err(format!("DNSServiceRegister failed with {status}"));
        }
        Ok(Handle(service))
    }
}

#[cfg(target_os = "linux")]
mod platform {
    pub struct Handle(mdns_sd::ServiceDaemon);

    impl Drop for Handle {
        fn drop(&mut self) {
            let _ = self.0.shutdown();
        }
    }

    pub fn register(name: &str, port: u16, txt: &[(&str, &str)]) -> Result<Handle, String> {
        let daemon = mdns_sd::ServiceDaemon::new().map_err(|error| error.to_string())?;
        let host = format!("{}.local.", crate::pairing::machine().name);
        let info = mdns_sd::ServiceInfo::new(&format!("{}.local.", super::SERVICE), name, &host, (), port, txt)
            .map_err(|error| error.to_string())?
            .enable_addr_auto();
        daemon.register(info).map_err(|error| error.to_string())?;
        Ok(Handle(daemon))
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod platform {
    pub struct Handle;

    pub fn register(_name: &str, _port: u16, _txt: &[(&str, &str)]) -> Result<Handle, String> {
        Err("not supported on this system".into())
    }
}
