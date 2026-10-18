//! hands: the executing half of Mycroft. The brain on the phone connects over SSH and runs `hands serve --stdio`,
//! which speaks pi-env's protocol 1 (docs/protocol.md) plus supervised jobs (docs/jobs.md). Jobs belong to
//! `hands supervise`, a long-lived process per user, so they outlive the connection.
//!
//! Based on the pi-env daemon of earendil-works/pi (MIT); see NOTICE.

mod cli;
mod decode;
mod errors;
mod exec;
mod frame;
mod fs;
mod install;
mod jobs;
mod list;
mod output;
mod pty;
mod scan;
mod serve;
mod state;
mod supervisor;
mod sys;
mod ui;
mod watch;
mod window;

use serve::VERSION;
use std::env;

const USAGE: &str = "usage: hands <command>

  serve [--stdio] [--token <hex>]   the pi-env protocol on stdin/stdout (what the phone runs over ssh)
  supervise [--detached]            the long-lived supervisor that owns jobs
  install [--dry-run] [--uninstall] install the binary and the supervisor service (systemd user unit / LaunchAgent)
  jobs [--json]                     list supervised jobs
  doctor                            report the binary, supervisor, state dir and jobs
  version                           print the version

With no command and stdin not a terminal, hands serves on stdin/stdout.";

fn serve_main(args: &[String]) -> i32 {
    // pi-env clients run `serve --token <hex>`; the token is echoed in the sync line (`PI-ENV <token>`).
    let mut token = "hands".to_string();
    let mut args = args.iter();
    while let Some(arg) = args.next() {
        match (arg.as_str(), args.as_slice().first()) {
            ("--stdio", _) => {}
            ("--token", Some(value)) => {
                token = value.clone();
                args.next();
            }
            _ => {
                eprintln!("usage: hands serve [--stdio] [--token <hex>]");
                return 2;
            }
        }
    }
    if let Err(error) = serve::serve(&token) {
        eprintln!("hands: {error}");
        return 1;
    }
    0
}

fn supervise_main(args: &[String]) -> i32 {
    let detached = match args {
        [] => false,
        [flag] if flag == "--detached" => true,
        _ => {
            eprintln!("usage: hands supervise [--detached]");
            return 2;
        }
    };
    match supervisor::run(detached) {
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
    // SAFETY: isatty only inspects the descriptor.
    let interactive = unsafe { libc::isatty(0) } == 1;
    let code = match args.get(1).map(String::as_str) {
        None if !interactive => serve_main(&[]),
        Some("serve") => serve_main(rest),
        Some("supervise") => supervise_main(rest),
        Some("install") => install::main(rest),
        Some("jobs") => cli::jobs(rest),
        Some("doctor") => cli::doctor(),
        Some("version" | "--version" | "-V") => {
            println!("hands {VERSION}");
            0
        }
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
