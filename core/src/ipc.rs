//! Control socket the MCP server connects to. Each connection sends
//! newline-delimited JSON requests `{"id", "method", "params"}` and gets one
//! reply line per request, `{"id", "result"}` or `{"id", "error"}`.
//!
//! Connections are served on background threads, which parse each request
//! once and frame DevTools commands there. Every request is then handed to
//! the CEF UI thread (the main thread): `cdp` goes straight to the browser's
//! DevTools agent, and everything else goes to the Swift handler, which
//! answers with `tiller_ipc_reply`. A DevTools reply comes back as the bytes
//! Chromium sent, and the connection's thread splits it into result or
//! error, so a screenshot's megabytes never get scanned on the UI thread.

use crate::browser;
use cef::*;
use serde::Deserialize;
use serde_json::{Value, json, value::RawValue};
use std::{
    collections::HashMap,
    ffi::{CString, c_char, c_void},
    io::{BufRead, BufReader, Read, Write},
    os::unix::{fs::PermissionsExt, net::{UnixListener, UnixStream}},
    path::{Path, PathBuf},
    sync::{
        Mutex, OnceLock, mpsc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread,
    time::Duration,
};

/// Called on the main thread with a request line. The handler must eventually
/// call `tiller_ipc_reply` with the same token.
pub type Handler = unsafe extern "C" fn(ctx: *mut c_void, request: *const c_char, token: u64);

#[derive(Clone, Copy)]
struct SwiftHandler {
    ctx: usize,
    f: Handler,
}

/// What a waiting connection gets back.
enum Reply {
    /// The JSON text of `{"result": ...}` or `{"error": ...}`, ready to send.
    Text(String),
    /// The app's reply as the bytes it sent, turned into text on the
    /// connection's thread.
    Bytes(Vec<u8>),
    /// A DevTools message as Chromium sent it, split into result or error on
    /// the connection's thread.
    DevTools(Vec<u8>),
}

static HANDLER: OnceLock<SwiftHandler> = OnceLock::new();
static SOCKET_PATH: OnceLock<PathBuf> = OnceLock::new();
static PENDING: Mutex<Option<HashMap<u64, mpsc::Sender<Reply>>>> = Mutex::new(None);
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);
/// Set once the message loop has ended, after which nothing may be posted to
/// the UI thread: CEF is being torn down.
static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);

/// Longer than any single tool waits, so a slow page gives an error instead of a hang.
const REPLY_TIMEOUT: Duration = Duration::from_secs(60);
/// A request line longer than this closes the connection. Skills are the
/// largest thing sent, and they are far smaller.
const MAX_LINE: u64 = 32 * 1024 * 1024;

pub fn start(path: &Path, ctx: *mut c_void, handler: Handler) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // A socket left behind by a crashed run would make bind fail.
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    // Anyone who can connect can run script in every tab, so only this user may.
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    let _ = HANDLER.set(SwiftHandler { ctx: ctx as usize, f: handler });
    let _ = SOCKET_PATH.set(path.to_path_buf());

    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            thread::spawn(move || serve(stream));
        }
    });
    Ok(())
}

/// Stops requests reaching the UI thread and removes the socket. Called once
/// the message loop has ended, before CEF shuts down.
pub fn stop() {
    SHUTTING_DOWN.store(true, Ordering::SeqCst);
    if let Some(path) = SOCKET_PATH.get() {
        let _ = std::fs::remove_file(path);
    }
}

fn serve(stream: UnixStream) {
    let Ok(mut writer) = stream.try_clone() else { return };
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    loop {
        line.clear();
        match (&mut reader).take(MAX_LINE).read_line(&mut line) {
            Ok(0) | Err(_) => return,
            // The cap was hit before a newline came.
            Ok(_) if !line.ends_with('\n') && line.len() as u64 >= MAX_LINE => return,
            Ok(_) => {}
        }
        if line.trim().is_empty() {
            continue;
        }
        let (id, reply) = match parse(&line) {
            Ok((id, request)) => (id, dispatch(request)),
            Err(message) => (Value::Null, error_json(message)),
        };
        let mut out = with_id(&id, &reply);
        out.push('\n');
        if writer.write_all(out.as_bytes()).and_then(|_| writer.flush()).is_err() {
            return;
        }
    }
}

fn error_json(message: impl Into<String>) -> String {
    json!({ "error": message.into() }).to_string()
}

/// `reply`, an object, with `"id": id` as its first member.
fn with_id(id: &Value, reply: &str) -> String {
    let body = reply.trim();
    let inner = body.strip_prefix('{').and_then(|b| b.strip_suffix('}')).unwrap_or("").trim();
    if inner.is_empty() {
        format!("{{\"id\":{id}}}")
    } else {
        format!("{{\"id\":{id},{inner}}}")
    }
}

/// The parts of a request read here. `params` stays as text: for `cdp` it is
/// copied into the DevTools message, and the Swift handler gets the whole line.
#[derive(Deserialize)]
struct Incoming<'a> {
    #[serde(default)]
    id: Value,
    method: &'a str,
    #[serde(borrow, default)]
    params: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct CdpParams<'a> {
    tab_id: Option<i64>,
    method: Option<&'a str>,
    #[serde(borrow, default)]
    params: Option<&'a RawValue>,
}

/// A request ready for the UI thread.
#[derive(Clone)]
pub enum Request {
    /// A DevTools command, framed with its message id.
    Cdp { tab: i32, message_id: i32, message: String },
    /// Anything else, for the Swift handler, as the request line it arrived as.
    Swift(CString),
}

/// Reads the request's id and turns the rest into what the UI thread sends on.
fn parse(line: &str) -> Result<(Value, Request), String> {
    let incoming: Incoming = serde_json::from_str(line).map_err(|e| format!("invalid JSON: {e}"))?;
    if incoming.method != "cdp" {
        let request = CString::new(line.trim()).map_err(|_| "request contains a NUL byte".to_string())?;
        return Ok((incoming.id, Request::Swift(request)));
    }
    let params: CdpParams = incoming
        .params
        .map(|p| serde_json::from_str(p.get()))
        .transpose()
        .map_err(|e| format!("bad cdp params: {e}"))?
        .unwrap_or(CdpParams { tab_id: None, method: None, params: None });
    let Some(tab) = params.tab_id else {
        return Err("cdp needs tab_id".into());
    };
    let Some(method) = params.method else {
        return Err("cdp needs method".into());
    };
    let message_id = browser::next_message_id();
    let args = params.params.map_or("{}", |p| p.get());
    let message = format!("{{\"id\":{message_id},\"method\":{},\"params\":{args}}}", json!(method));
    Ok((incoming.id, Request::Cdp { tab: tab as i32, message_id, message }))
}

/// Posts the request to the UI thread and waits for its reply.
fn dispatch(request: Request) -> String {
    if SHUTTING_DOWN.load(Ordering::SeqCst) {
        return error_json("browser is shutting down");
    }
    let token = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::channel();
    PENDING.lock().unwrap().get_or_insert_default().insert(token, tx);

    let mut task = RequestTask::new(request, token);
    if post_task(ThreadId::UI, Some(&mut task)) == 0 {
        take(token);
        return error_json("browser is shutting down");
    }
    match rx.recv_timeout(REPLY_TIMEOUT) {
        Ok(Reply::Text(reply)) => reply,
        Ok(Reply::Bytes(reply)) => String::from_utf8(reply).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned()),
        Ok(Reply::DevTools(message)) => devtools_reply(&message),
        Err(_) => {
            take(token);
            // The tab may still answer later; nothing should be waiting for it.
            if !SHUTTING_DOWN.load(Ordering::SeqCst) {
                let mut forget = ForgetTask::new(token);
                post_task(ThreadId::UI, Some(&mut forget));
            }
            error_json("timed out waiting for the browser")
        }
    }
}

/// The parts of a DevTools reply that matter here. The result stays as the
/// text it arrived as: a screenshot's reply is megabytes of base64, which is
/// passed through rather than parsed into a tree and written out again.
#[derive(Deserialize)]
struct DevToolsMessage<'a> {
    #[serde(borrow)]
    result: Option<&'a RawValue>,
    error: Option<DevToolsError>,
}

#[derive(Deserialize)]
struct DevToolsError {
    message: Option<String>,
}

/// `{"result": ...}` or `{"error": "..."}` for a DevTools reply.
fn devtools_reply(message: &[u8]) -> String {
    let Ok(text) = std::str::from_utf8(message) else {
        return error_json("DevTools reply was not UTF-8");
    };
    match serde_json::from_str::<DevToolsMessage>(text) {
        Ok(DevToolsMessage { error: Some(error), .. }) => error_json(error.message.unwrap_or_else(|| "DevTools error".into())),
        Ok(DevToolsMessage { result, .. }) => format!("{{\"result\":{}}}", result.map_or("{}", |r| r.get())),
        Err(e) => error_json(format!("bad DevTools reply: {e}")),
    }
}

fn take(token: u64) -> Option<mpsc::Sender<Reply>> {
    PENDING.lock().unwrap().as_mut()?.remove(&token)
}

fn send(token: u64, reply: Reply) {
    // Late replies after a timeout are dropped.
    if let Some(tx) = take(token) {
        let _ = tx.send(reply);
    }
}

/// Sends `reply` (`{"result": ...}` or `{"error": ...}`) to whoever is waiting
/// on `token`.
pub fn reply(token: u64, reply: Value) {
    reply_raw(token, reply.to_string());
}

/// Like `reply`, with the reply already as JSON text.
pub fn reply_raw(token: u64, reply: String) {
    send(token, Reply::Text(reply));
}

/// Like `reply_raw`, with the reply as JSON bytes, which are checked for
/// UTF-8 on the waiting thread rather than here.
pub fn reply_bytes(token: u64, reply: Vec<u8>) {
    send(token, Reply::Bytes(reply));
}

/// Answers `token` with a DevTools message, which is read on the waiting
/// thread rather than here.
pub fn reply_devtools(token: u64, message: Vec<u8>) {
    send(token, Reply::DevTools(message));
}

pub fn reply_error(token: u64, message: impl Into<String>) {
    reply(token, json!({ "error": message.into() }));
}

wrap_task! {
    struct RequestTask {
        request: Request,
        token: u64,
    }

    impl Task {
        fn execute(&self) {
            match &self.request {
                Request::Cdp { tab, message_id, message } => {
                    browser::devtools_send(*tab, *message_id, message, self.token);
                }
                Request::Swift(request) => {
                    let Some(handler) = HANDLER.get() else {
                        return reply_error(self.token, "no handler");
                    };
                    unsafe { (handler.f)(handler.ctx as *mut c_void, request.as_ptr(), self.token) };
                }
            }
        }
    }
}

wrap_task! {
    struct ForgetTask {
        token: u64,
    }

    impl Task {
        fn execute(&self) {
            browser::forget_devtools_call(self.token);
        }
    }
}
