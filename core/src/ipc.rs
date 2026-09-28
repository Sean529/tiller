//! Control socket the MCP server connects to. Each connection sends
//! newline-delimited JSON requests `{"id", "method", "params"}` and gets one
//! reply line per request, `{"id", "result"}` or `{"id", "error"}`.
//!
//! Connections are served on background threads. Every request is handed to
//! the CEF UI thread (the main thread): `cdp` goes straight to the browser's
//! DevTools agent, and everything else goes to the Swift handler, which
//! answers with `mini_ipc_reply`.

use crate::browser;
use cef::*;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    ffi::{CString, c_char, c_void},
    io::{BufRead, BufReader, Write},
    os::unix::{fs::PermissionsExt, net::{UnixListener, UnixStream}},
    path::Path,
    sync::{
        Mutex, OnceLock, mpsc,
        atomic::{AtomicU64, Ordering},
    },
    thread,
    time::Duration,
};

/// Called on the main thread with a request line. The handler must eventually
/// call `mini_ipc_reply` with the same token.
pub type Handler = unsafe extern "C" fn(ctx: *mut c_void, request: *const c_char, token: u64);

#[derive(Clone, Copy)]
struct SwiftHandler {
    ctx: usize,
    f: Handler,
}

static HANDLER: OnceLock<SwiftHandler> = OnceLock::new();
static PENDING: Mutex<Option<HashMap<u64, mpsc::Sender<Value>>>> = Mutex::new(None);
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);

/// Longer than any single tool waits, so a slow page gives an error instead of a hang.
const REPLY_TIMEOUT: Duration = Duration::from_secs(60);

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

    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            thread::spawn(move || serve(stream));
        }
    });
    Ok(())
}

fn serve(stream: UnixStream) {
    let Ok(mut writer) = stream.try_clone() else { return };
    for line in BufReader::new(stream).lines() {
        let Ok(line) = line else { return };
        if line.trim().is_empty() {
            continue;
        }
        let (id, reply) = match serde_json::from_str::<Value>(&line) {
            Ok(request) => (request.get("id").cloned().unwrap_or(Value::Null), dispatch(request)),
            Err(e) => (Value::Null, json!({ "error": format!("invalid JSON: {e}") })),
        };
        let mut reply = reply;
        reply["id"] = id;
        if writeln!(writer, "{reply}").and_then(|_| writer.flush()).is_err() {
            return;
        }
    }
}

/// Posts the request to the UI thread and waits for its reply.
fn dispatch(request: Value) -> Value {
    let token = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::channel();
    PENDING.lock().unwrap().get_or_insert_default().insert(token, tx);

    let mut task = RequestTask::new(request.to_string(), token);
    if post_task(ThreadId::UI, Some(&mut task)) == 0 {
        take(token);
        return json!({ "error": "browser is shutting down" });
    }
    match rx.recv_timeout(REPLY_TIMEOUT) {
        Ok(reply) => reply,
        Err(_) => {
            take(token);
            json!({ "error": "timed out waiting for the browser" })
        }
    }
}

fn take(token: u64) -> Option<mpsc::Sender<Value>> {
    PENDING.lock().unwrap().as_mut()?.remove(&token)
}

/// Sends `reply` (`{"result": ...}` or `{"error": ...}`) to whoever is waiting
/// on `token`. Late replies after a timeout are dropped.
pub fn reply(token: u64, reply: Value) {
    if let Some(tx) = take(token) {
        let _ = tx.send(reply);
    }
}

pub fn reply_error(token: u64, message: impl Into<String>) {
    reply(token, json!({ "error": message.into() }));
}

wrap_task! {
    struct RequestTask {
        request: String,
        token: u64,
    }

    impl Task {
        fn execute(&self) {
            let request: Value = serde_json::from_str(&self.request).unwrap_or_default();
            if request["method"] == "cdp" {
                let params = &request["params"];
                let Some(tab) = params["tab_id"].as_i64() else {
                    return reply_error(self.token, "cdp needs tab_id");
                };
                let Some(method) = params["method"].as_str() else {
                    return reply_error(self.token, "cdp needs method");
                };
                let args = params.get("params").cloned().unwrap_or_else(|| json!({}));
                return browser::devtools_call(tab as i32, method, args, self.token);
            }
            let Some(handler) = HANDLER.get() else {
                return reply_error(self.token, "no handler");
            };
            let request = CString::new(self.request.as_str()).unwrap_or_default();
            unsafe { (handler.f)(handler.ctx as *mut c_void, request.as_ptr(), self.token) };
        }
    }
}
