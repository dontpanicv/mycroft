//! `hands __serve`: one connection's daemon (docs/protocol.md) on stdin/stdout. The listener (listener.rs) starts one
//! per authenticated phone connection and proxies its frames, so a crash takes down only that connection. Requests
//! run in this process, except the `job.*` operations, which go to the supervisor (supervisor.rs) so jobs outlive the
//! connection, and on macOS `cua.*`, which go to Cua Driver in the supervisor (cua.rs).

use crate::errors::Failure;
use crate::exec::{self, Control};
use crate::frame::{self, CANCEL, ERROR, Frame, PING, REQUEST, RESULT};
use crate::output::Output;
use crate::{cua, fs, list, supervisor, sys};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::env;
use std::fs::File;
use std::io::{self, BufReader, BufWriter, Read};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const PROTOCOL: u64 = 1;
/// The hands release, reported by `hello`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
const PING_INTERVAL: Duration = Duration::from_secs(5);
const SILENCE_LIMIT_MS: u64 = 30_000;
/// Threads for file operations; commands run on their own threads.
const WORKERS: usize = 16;
/// Open handles per connection, beyond which opening fails with `EMFILE`.
const MAX_HANDLES: usize = 4096;
/// Replies with larger payloads queue behind command output instead of going first.
const CONTROL_PAYLOAD: usize = 64 * 1024;

/// The operations a client may send. `job.*` go on to the supervisor (supervisor.rs has its own, separate set).
#[derive(Clone, Copy, PartialEq)]
enum Op {
    Hello,
    Write,
    Open,
    Pread,
    Close,
    ListFiles,
    Exec,
    JobStart,
    JobStatus,
    JobOutput,
    JobWait,
    JobCancel,
    JobList,
    CuaTools,
    CuaCall,
}

/// Where a request runs.
enum Lane {
    /// The shared worker pool: quick file operations and supervisor calls.
    Pool,
    /// A thread of its own: commands last, and waits and desktop calls block until something else happens.
    Thread,
}

impl Op {
    /// In `hello.features` order.
    const ALL: [Op; 15] = [
        Op::Hello,
        Op::Write,
        Op::Open,
        Op::Pread,
        Op::Close,
        Op::ListFiles,
        Op::Exec,
        Op::JobStart,
        Op::JobStatus,
        Op::JobOutput,
        Op::JobWait,
        Op::JobCancel,
        Op::JobList,
        Op::CuaTools,
        Op::CuaCall,
    ];

    fn name(self) -> &'static str {
        match self {
            Op::Hello => "hello",
            Op::Write => "write",
            Op::Open => "open",
            Op::Pread => "pread",
            Op::Close => "close",
            Op::ListFiles => "listFiles",
            Op::Exec => "exec",
            Op::JobStart => "job.start",
            Op::JobStatus => "job.status",
            Op::JobOutput => "job.output",
            Op::JobWait => "job.wait",
            Op::JobCancel => "job.cancel",
            Op::JobList => "job.list",
            Op::CuaTools => "cua.tools",
            Op::CuaCall => "cua.call",
        }
    }

    fn parse(name: &str) -> Option<Op> {
        Op::ALL.into_iter().find(|op| op.name() == name)
    }

    fn lane(self) -> Lane {
        match self {
            Op::Exec | Op::JobWait | Op::CuaCall => Lane::Thread,
            _ => Lane::Pool,
        }
    }

    /// Whether `hello.features` lists it: the operations added after protocol 1's first release, which clients
    /// check for before using. `cua.*` only where desktop control exists (macOS); elsewhere they answer
    /// `not_supported`.
    fn is_feature(self) -> bool {
        match self {
            Op::Hello | Op::Write | Op::Open | Op::Pread | Op::Close | Op::Exec => false,
            Op::CuaTools | Op::CuaCall => cfg!(target_os = "macos"),
            _ => true,
        }
    }
}

fn features() -> Vec<&'static str> {
    Op::ALL.into_iter().filter(|op| op.is_feature()).map(Op::name).collect()
}

struct FileHandle {
    file: File,
    path: String,
}

type Job = Box<dyn FnOnce() + Send>;

struct Server {
    output: Arc<Output>,
    tmpdir: String,
    handles: Mutex<HashMap<u64, Arc<FileHandle>>>,
    next_handle: AtomicU64,
    controls: Mutex<HashMap<u32, Arc<Control>>>,
    groups: exec::Groups,
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

fn field<'a>(json: &'a Value, key: &str) -> Result<&'a str, Failure> {
    json[key]
        .as_str()
        .ok_or_else(|| Failure::new("EINVAL", format!("missing field {key}")))
}

fn number(json: &Value, key: &str) -> Result<u64, Failure> {
    json[key]
        .as_u64()
        .ok_or_else(|| Failure::new("EINVAL", format!("missing or invalid field {key}")))
}

fn flag(json: &Value, key: &str) -> bool {
    json[key].as_bool().unwrap_or(false)
}

impl Server {
    fn file(&self, json: &Value) -> Result<Arc<FileHandle>, Failure> {
        self.handles
            .lock()
            .unwrap()
            .get(&number(json, "handle")?)
            .cloned()
            .ok_or_else(|| Failure::new("EBADF", "unknown handle"))
    }

    fn insert_file(&self, file: File, path: &str) -> Result<u64, Failure> {
        let mut handles = self.handles.lock().unwrap();
        if handles.len() >= MAX_HANDLES {
            return Err(Failure::new("EMFILE", "EMFILE: too many open files"));
        }
        let id = self.next_handle.fetch_add(1, Ordering::Relaxed);
        let path = path.to_string();
        handles.insert(id, Arc::new(FileHandle { file, path }));
        Ok(id)
    }

    fn dispatch(
        &self,
        id: u32,
        op: Op,
        json: &Value,
        payload: Vec<u8>,
        control: &Control,
    ) -> Result<(Value, Vec<u8>), Failure> {
        let plain = |value: Result<Value, Failure>| value.map(|value| (value, Vec::new()));
        match op {
            Op::Hello => plain(Ok(json!({
                "protocol": PROTOCOL,
                "version": VERSION,
                "os": env::consts::OS,
                "arch": env::consts::ARCH,
                "home": sys::home(),
                "tmpdir": self.tmpdir,
                "cwd": sys::cwd(),
                "pid": std::process::id(),
                "features": features(),
                "cua": cua::version().map(|version| json!({ "version": version })),
            }))),
            Op::Write => {
                fs::write(field(json, "path")?, flag(json, "append"), &payload)?;
                plain(Ok(json!({})))
            }
            Op::Open => {
                // Node's `open(path, "r")`: any kind of file, blocking; the reply reports what the file is.
                let path = field(json, "path")?;
                let file = sys::open(path, sys::OpenMode::Read)
                    .map_err(|error| Failure::io(&error, "open", path))?;
                let mut result = match file.metadata() {
                    Ok(metadata) => json!({ "stat": fs::info(path, &metadata) }),
                    Err(error) => json!({ "statError": Failure::io(&error, "fstat", path).to_json() }),
                };
                result["handle"] = json!(self.insert_file(file, path)?);
                plain(Ok(result))
            }
            Op::Pread => {
                let handle = self.file(json)?;
                let length = (number(json, "length")? as usize).min(frame::MAX_PAYLOAD);
                let offset = number(json, "offset")?;
                Ok((json!({}), fs::pread(&handle.file, &handle.path, offset, length)?))
            }
            Op::Close => {
                self.handles
                    .lock()
                    .unwrap()
                    .remove(&number(json, "handle")?);
                plain(Ok(json!({})))
            }
            Op::ListFiles => list::run(json, &|| control.aborted.load(Ordering::SeqCst)),
            Op::Exec => plain(exec::run(
                id,
                exec::ExecRequest::from_json(json)?,
                &self.tmpdir,
                &self.output,
                control,
                &self.groups,
            )),
            Op::JobStart => plain(supervisor::call(&job_start_request(json)).map(|(value, _)| value)),
            Op::JobWait => plain(job_wait(json, control)),
            Op::JobStatus | Op::JobOutput | Op::JobCancel | Op::JobList => supervisor::call(json),
            Op::CuaTools | Op::CuaCall => cua::dispatch(op.name(), json, control),
        }
    }
}

/// A job gets the environment `exec` would give a command: this daemon's (the service's, which `hands install` gave
/// the user's `PATH`), then `env`, unless `inheritEnv` is false. The supervisor's own environment is not used.
fn job_start_request(json: &Value) -> Value {
    let mut request = json.clone();
    let mut env: serde_json::Map<String, Value> = if json["inheritEnv"].as_bool().unwrap_or(true) {
        env::vars().map(|(key, value)| (key, json!(value))).collect()
    } else {
        Default::default()
    };
    if let Some(extra) = json["env"].as_object() {
        env.extend(extra.iter().map(|(key, value)| (key.clone(), value.clone())));
    }
    request["env"] = Value::Object(env);
    request["inheritEnv"] = json!(false);
    request
}

/// `job.wait` in short slices, so cancelling the request (or this connection ending) stops waiting at once. The
/// job itself is never touched.
fn job_wait(json: &Value, control: &Control) -> Result<Value, Failure> {
    let timeout = json["timeoutMs"].as_u64().unwrap_or(30_000);
    let deadline = now_ms().saturating_add(timeout);
    loop {
        if control.aborted.load(Ordering::SeqCst) || control.killed.load(Ordering::SeqCst) {
            return Err(Failure::new("aborted", "aborted"));
        }
        let slice = deadline.saturating_sub(now_ms()).min(500);
        let mut request = json.clone();
        request["timeoutMs"] = json!(slice);
        let (status, _) = supervisor::call(&request)?;
        if status["state"] != "running" || slice == 0 {
            return Ok(status);
        }
    }
}

fn kill_all(groups: &exec::Groups) {
    for pid in groups.lock().unwrap().iter() {
        exec::kill_group(*pid);
    }
}

/// Stdin that records when bytes last arrived, so a large frame arriving slowly counts as a live client.
struct Seen<R> {
    inner: R,
    last_seen: Arc<AtomicU64>,
}

impl<R: Read> Read for Seen<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let read = self.inner.read(buffer)?;
        if read > 0 {
            self.last_seen.store(now_ms(), Ordering::Relaxed);
        }
        Ok(read)
    }
}

fn start_workers() -> Sender<Job> {
    let (jobs, queue) = mpsc::channel::<Job>();
    let queue = Arc::new(Mutex::new(queue));
    for _ in 0..WORKERS {
        let queue: Arc<Mutex<Receiver<Job>>> = queue.clone();
        thread::spawn(move || {
            loop {
                let job = queue.lock().unwrap().recv();
                match job {
                    Ok(job) => job(),
                    Err(_) => return,
                }
            }
        });
    }
    jobs
}

fn respond(server: &Server, id: u32, op: Op, request: Frame, control: Arc<Control>) {
    let reply = match server.dispatch(id, op, &request.json, request.payload, &control) {
        Ok((json, payload)) => Frame::with_payload(RESULT, id, json, payload),
        Err(failure) => Frame::new(ERROR, id, failure.to_json()),
    };
    server.controls.lock().unwrap().remove(&id);
    // A command's result follows its output; large payloads do not hold up pings and small replies.
    if op == Op::Exec || reply.payload.len() > CONTROL_PAYLOAD {
        server.output.bulk(reply, None);
    } else {
        server.output.control(reply);
    }
}

fn serve_frames(server: &Arc<Server>, input: &mut impl Read) -> io::Result<()> {
    let jobs = start_workers();
    while let Some(request) = frame::read_frame(input)? {
        match request.kind {
            REQUEST => {
                let id = request.id;
                let name = request.json["op"].as_str().unwrap_or_default();
                let op = match Op::parse(name) {
                    Some(op) => op,
                    None => {
                        let failure = if request.json.is_null() {
                            Failure::new("EINVAL", "invalid JSON")
                        } else {
                            Failure::new("EINVAL", format!("unknown operation {name}"))
                        };
                        server.output.control(Frame::new(ERROR, id, failure.to_json()));
                        continue;
                    }
                };
                // Registered before the request runs, so a cancel right behind it is not lost.
                let control = Arc::new(Control::default());
                server.controls.lock().unwrap().insert(id, control.clone());
                let worker = server.clone();
                match op.lane() {
                    Lane::Thread => {
                        let spawned = thread::Builder::new()
                            .stack_size(16 * 1024 * 1024)
                            .spawn(move || respond(&worker, id, op, request, control));
                        if let Err(error) = spawned {
                            server.controls.lock().unwrap().remove(&id);
                            let failure = Failure::new("spawn_error", error.to_string());
                            server
                                .output
                                .bulk(Frame::new(ERROR, id, failure.to_json()), None);
                        }
                    }
                    Lane::Pool => {
                        let _ = jobs.send(Box::new(move || respond(&worker, id, op, request, control)));
                    }
                }
            }
            CANCEL => {
                let control = server.controls.lock().unwrap().get(&request.id).cloned();
                if let Some(control) = control {
                    control.cancel(request.json["mode"].as_str() == Some("kill"));
                }
            }
            _ => {}
        }
    }
    Ok(())
}

pub fn serve() -> io::Result<()> {
    let output = Arc::new(Output::default());
    let writer = {
        let output = output.clone();
        thread::spawn(move || {
            output.run(&mut BufWriter::with_capacity(1 << 20, io::stdout().lock()))
        })
    };
    let server = Arc::new(Server {
        output: output.clone(),
        tmpdir: sys::tmpdir(),
        handles: Mutex::new(HashMap::new()),
        next_handle: AtomicU64::new(1),
        controls: Mutex::new(HashMap::new()),
        groups: Arc::new(Mutex::new(Default::default())),
    });
    let last_seen = Arc::new(AtomicU64::new(now_ms()));
    {
        let output = output.clone();
        let last_seen = last_seen.clone();
        let groups = server.groups.clone();
        thread::spawn(move || {
            loop {
                thread::sleep(PING_INTERVAL);
                output.control(Frame::new(PING, 0, json!({})));
                // A client that went silent (a phone that lost its network) leaves nothing running.
                if now_ms().saturating_sub(last_seen.load(Ordering::Relaxed)) > SILENCE_LIMIT_MS {
                    kill_all(&groups);
                    std::process::exit(0);
                }
            }
        });
    }
    let mut input = BufReader::with_capacity(
        1 << 20,
        Seen {
            inner: io::stdin().lock(),
            last_seen,
        },
    );
    let result = serve_frames(&server, &mut input);
    // However input ended, the client is gone: stop everything it started.
    kill_all(&server.groups);
    output.close();
    let _ = writer.join();
    result
}
