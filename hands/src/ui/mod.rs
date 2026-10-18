//! Desktop control: `ui.observe` and `ui.act`. Reserved for milestone M6; both report `not_supported` today and are
//! not listed in `hello.features`, so clients can probe for them the way they probe for `listFiles`.
//!
//! # Planned design (macOS)
//!
//! An SSH session cannot hold the Accessibility (TCC) permission: macOS grants it to an app or binary running in the
//! logged-in user's GUI session, and processes started by `sshd` are outside that session. So desktop control will
//! run in a second process:
//!
//! - `hands install` also writes a LaunchAgent (`dev.mycroft.hands.ui`) that runs `hands ui-agent` in the user's
//!   Aqua session. The user grants it Accessibility (and, for screenshots, Screen Recording) once, in System
//!   Settings; `hands doctor` reports whether it has been granted.
//! - The UI agent listens on its own user-only Unix socket in the state dir, next to the supervisor's, speaking the
//!   same frames. `serve` proxies `ui.*` requests to it; no listening ports, nothing reachable from the network.
//! - `ui.observe { app?, window?, maxElements? }` walks the AX tree of the frontmost (or named) application through
//!   `AXUIElement` (via `objc2`) and returns a compact element list: role, title or label, value, frame, enabled
//!   and focused flags, and a short `ref` per element that stays valid until the next observe. An optional
//!   screenshot of the window travels as payload.
//! - `ui.act { ref, action, text?, keys?, dx?, dy? }` performs one operation on a referenced element: press, type,
//!   set value, focus, scroll, or a key chord. A stale `ref` fails with a distinct code so the brain re-observes.
//! - The brain runs the loop on the phone: observe, let Jev pick the operation and target, act, observe again to
//!   verify. Model credentials never reach `hands`.
//!
//! Linux desktop control (AT-SPI) is not planned yet.

use crate::errors::Failure;
use serde_json::Value;

pub fn dispatch(op: &str, _json: &Value) -> Result<Value, Failure> {
    Err(Failure::new(
        "not_supported",
        format!("{op} is reserved for desktop control and is not implemented yet"),
    ))
}
