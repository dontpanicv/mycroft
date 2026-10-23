//! hands: the executing half of Mycroft. The brain on the phone connects to the paired TLS listener of `hands
//! supervise --listen` (docs/pairing.md) and speaks protocol 1 (docs/protocol.md) plus supervised jobs (docs/jobs.md)
//! to a `hands __serve` the listener starts for each connection. Jobs belong to `hands supervise`, a long-lived
//! process per user, so they outlive the connection.
//!
//! Based on the pi-env daemon of earendil-works/pi (MIT); see NOTICE.

mod cli;
mod cua;
mod decode;
mod errors;
mod exec;
mod frame;
mod fs;
mod install;
mod jobs;
mod list;
mod listener;
mod mdns;
mod output;
mod pairing;
mod permissions;
mod serve;
mod state;
mod supervisor;
mod sys;
mod tls;
mod window;

use serve::VERSION;
use std::env;

const USAGE: &str = "usage: hands <command>

  install [--pair <BASE> --pin <PIN>] [--no-service] [--bind <ADDR>] [--dry-run] [--uninstall]
                                    install the binary and the service (systemd user unit / LaunchAgent) that runs
                                    `supervise --listen`; with --pair, pair with the phone too; on macOS, then ask
                                    for the permissions Mycroft needs
  pair --with <BASE> --pin <PIN> [--bind <ADDR>]
                                    pair with the phone (what the phone's install command runs, via install)
  paired [--json]                   list the paired phones
  unpair <name>                     remove a paired phone
  supervise [--listen] [--bind <ADDR>] [--detached]
                                    the long-lived supervisor that owns jobs and, on macOS, desktop control; with
                                    --listen, also the phone's TLS WebSocket listener
  jobs [--json]                     list supervised jobs
  permissions [--check] [--json]    on macOS, walk through what Mycroft needs approved for hands, one at a time:
                                    Accessibility, Screen Recording, the Desktop, Documents and Downloads folders,
                                    Local Network and, optionally, Full Disk Access; --check only reports. On
                                    Linux, report the service and lingering
  doctor                            report the binary, supervisor, listener, paired phones, state dir and jobs
  version                           print the version";

/// `hands __serve`: what the listener runs for each connection, not a command for people.
fn serve_main(args: &[String]) -> i32 {
    if !args.is_empty() {
        eprintln!("usage: hands __serve");
        return 2;
    }
    if let Err(error) = serve::serve() {
        eprintln!("hands: {error}");
        return 1;
    }
    0
}

fn supervise_main(args: &[String]) -> i32 {
    const USAGE: &str = "usage: hands supervise [--listen] [--bind <ADDR>] [--detached]";
    let (mut detached, mut listen, mut bind) = (false, false, None);
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match (arg.as_str(), args.as_slice().first()) {
            ("--detached", _) => detached = true,
            ("--listen", _) => listen = true,
            ("--bind", Some(value)) => {
                match pairing::parse_bind(value) {
                    Ok(address) => bind = Some(address),
                    Err(error) => {
                        eprintln!("hands supervise: {error}");
                        return 2;
                    }
                }
                args.next();
            }
            _ => {
                eprintln!("{USAGE}");
                return 2;
            }
        }
    }
    if bind.is_some() && !listen {
        eprintln!("{USAGE}");
        return 2;
    }
    let result = if listen {
        listener::run(bind, detached)
    } else {
        supervisor::run(detached)
    };
    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("hands supervise: {error}");
            1
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let rest = args.get(2..).unwrap_or_default();
    let code = match args.get(1).map(String::as_str) {
        Some("supervise") => supervise_main(rest),
        Some("install") => install::main(rest),
        Some("pair") => pairing::main(rest),
        Some("paired") => cli::paired(rest),
        Some("unpair") => cli::unpair(rest),
        Some("jobs") => cli::jobs(rest),
        Some("permissions") => permissions::main(rest),
        Some("doctor") => cli::doctor(),
        Some("version" | "--version" | "-V") => {
            println!("hands {VERSION}");
            0
        }
        Some("__serve") => serve_main(rest),
        Some("__job-runner") => jobs::runner(rest),
        Some("help" | "--help" | "-h") => {
            println!("{USAGE}");
            0
        }
        _ => {
            eprintln!("{USAGE}");
            2
        }
    };
    // Request threads may still be blocked (a FIFO open); nothing is left to answer them.
    std::process::exit(code);
}
