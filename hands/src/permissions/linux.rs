//! `hands permissions` on Linux: nothing to approve, so it reports what keeps hands running, the service and
//! lingering.

use super::output;
use crate::listener;
use serde_json::json;

/// `loginctl`'s Linger for this user: `yes`, `no`, or `None` without loginctl.
pub fn linger() -> Option<String> {
    let user = std::env::var("USER").unwrap_or_default();
    output("loginctl", &["show-user", &user, "-p", "Linger", "--value"]).map(|text| text.trim().to_string())
}

/// `hands permissions [--json]` on Linux.
pub fn report(json_output: bool) -> i32 {
    let service = listener::running().is_some();
    let linger = linger();
    let lingers = linger.as_deref().is_none_or(|linger| linger == "yes");
    if json_output {
        println!("{}", json!({ "service": service, "linger": linger }));
    } else {
        println!("Nothing to approve on Linux: hands runs as you, with your user's access.");
        println!(
            "{:<10} {}",
            "service",
            if service { "running" } else { "not running (`hands install` sets it up)" }
        );
        println!(
            "{:<10} {}",
            "linger",
            match linger.as_deref() {
                Some("yes") => "yes: hands keeps running after you log out".to_string(),
                Some(other) => format!("{other}: hands stops at logout (run `sudo loginctl enable-linger $USER`)"),
                None => "unknown (no loginctl)".to_string(),
            }
        );
    }
    if service && lingers { 0 } else { 1 }
}
