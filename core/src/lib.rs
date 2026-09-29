//! Browser core for Mini. Built as a static library and linked into the Swift app.
//! Every exported function is declared in `app/Sources/CMiniCore/mini_core.h`.

mod app_mac;
mod browser;
mod cookies;
mod ipc;

use cef::*;
use std::ffi::{CStr, c_char, c_int, c_void};

static VERSION: &CStr = c"mini-core 0.1.0 (cef 154.2.0+154.0.28)";

/// Returns a static, NUL-terminated version string. The caller must not free it.
#[unsafe(no_mangle)]
pub extern "C" fn mini_core_version() -> *const c_char {
    VERSION.as_ptr()
}

/// Loads CEF, installs the CEF-compatible NSApplication and initializes CEF.
/// Must be the first thing `main` does, before anything touches `NSApp`.
/// Returns 0 on success, or a nonzero exit code.
#[unsafe(no_mangle)]
pub extern "C" fn mini_core_start() -> c_int {
    let Ok(exe) = std::env::current_exe() else {
        return 1;
    };
    let loader = library_loader::LibraryLoader::new(&exe, false);
    if !loader.load() {
        eprintln!("mini: Chromium Embedded Framework not found. Run Mini from Mini.app.");
        return 1;
    }
    // The framework has to stay loaded for the life of the process.
    std::mem::forget(loader);
    let _ = api_hash(sys::CEF_API_VERSION_LAST, 0);

    if !app_mac::install() {
        eprintln!("mini: NSApp was created before mini_core_start");
        return 1;
    }

    let args = args::Args::new();
    // The main executable is never a subprocess (helpers are separate apps),
    // but CEF still expects this call first.
    let code = execute_process(Some(args.as_main_args()), None, std::ptr::null_mut());
    if code >= 0 {
        return code;
    }

    // Same folder as DataDirectory.swift.
    let root = match std::env::var("MINI_DATA_DIR") {
        Ok(dir) if !dir.is_empty() => dir,
        _ => std::env::var("HOME").map(|h| format!("{h}/Library/Application Support/Mini")).unwrap_or_default(),
    };
    let settings = Settings {
        root_cache_path: CefString::from(root.as_str()),
        cache_path: CefString::from(format!("{root}/Default").as_str()),
        persist_session_cookies: 1,
        log_severity: LogSeverity::WARNING,
        ..Default::default()
    };
    let mut app = browser::MiniApp::new();
    if initialize(Some(args.as_main_args()), Some(&settings), Some(&mut app), std::ptr::null_mut()) != 1 {
        eprintln!("mini: CEF failed to initialize");
        return 1;
    }
    0
}

/// Runs the AppKit/CEF message loop until the last browser closes, then shuts
/// CEF down.
#[unsafe(no_mangle)]
pub extern "C" fn mini_core_run() {
    run_message_loop();
    shutdown();
}

/// Sets a function run on the main thread when the app is asked to quit (Cmd+Q,
/// the Dock, logging out), before any tab starts closing. Null clears it.
#[unsafe(no_mangle)]
pub extern "C" fn mini_core_set_quit_handler(handler: Option<unsafe extern "C" fn()>) {
    app_mac::set_quit_handler(handler);
}

/// Creates a browser filling `parent_view` (an `NSView *`). Returns the browser
/// id, or -1 on failure. Callbacks run on the main thread.
///
/// # Safety
/// `parent_view` must be a live NSView and `url` a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mini_browser_create(
    parent_view: *mut c_void,
    width: c_int,
    height: c_int,
    url: *const c_char,
    callbacks: browser::Callbacks,
) -> c_int {
    let url = unsafe { cstr(url) };
    browser::create(parent_view, width, height, &url, callbacks)
}

/// # Safety
/// `url` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mini_browser_load_url(id: c_int, url: *const c_char) {
    let url = unsafe { cstr(url) };
    if let Some(frame) = browser::get(id).and_then(|b| b.main_frame()) {
        frame.load_url(Some(&CefString::from(url.as_str())));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_go_back(id: c_int) {
    if let Some(b) = browser::get(id) {
        b.go_back();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_go_forward(id: c_int) {
    if let Some(b) = browser::get(id) {
        b.go_forward();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_reload(id: c_int) {
    if let Some(b) = browser::get(id) {
        b.reload();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_stop(id: c_int) {
    if let Some(b) = browser::get(id) {
        b.stop_load();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_set_focus(id: c_int, focus: bool) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.set_focus(focus.into());
    }
}

/// Zooms the page out (`command` < 0), back to 100% (0) or in (> 0), in
/// Chromium's zoom steps.
#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_zoom(id: c_int, command: c_int) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.zoom(match command {
            ..0 => ZoomCommand::OUT,
            0 => ZoomCommand::RESET,
            _ => ZoomCommand::IN,
        });
    }
}

/// The page's zoom as a factor, 1 for 100%.
#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_zoom_factor(id: c_int) -> f64 {
    browser::get(id).and_then(|b| b.host()).map_or(1.0, |host| 1.2f64.powf(host.zoom_level()))
}

/// Finds `text` in the page and highlights the matches. `find_next` moves to
/// the next or previous match of the same text. Results arrive through
/// `find_result`.
///
/// # Safety
/// `text` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mini_browser_find(id: c_int, text: *const c_char, forward: bool, find_next: bool) {
    let text = unsafe { cstr(text) };
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.find(Some(&CefString::from(text.as_str())), forward.into(), 0, find_next.into());
    }
}

/// Ends a search and removes its highlights.
#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_stop_finding(id: c_int) {
    if let Some(host) = browser::get(id).and_then(|b| b.host()) {
        host.stop_finding(1);
    }
}

/// Runs `code` in the tab's main frame. Nothing comes back.
///
/// # Safety
/// `code` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mini_browser_execute_js(id: c_int, code: *const c_char) {
    let code = unsafe { cstr(code) };
    if let Some(frame) = browser::get(id).and_then(|b| b.main_frame()) {
        frame.execute_java_script(Some(&CefString::from(code.as_str())), None, 0);
    }
}

/// Sets the cookies in `cookies_json` (see mini_core.h), replacing any with
/// the same name, domain and path. `done` runs on the main thread once all
/// are set and written to disk.
///
/// # Safety
/// `cookies_json` must be a NUL-terminated UTF-8 string. `ctx` must stay valid
/// until `done` runs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mini_cookies_import(cookies_json: *const c_char, ctx: *mut c_void, done: cookies::Done) {
    let json = unsafe { cstr(cookies_json) };
    cookies::import(&json, ctx, done);
}

/// Closes a tab. The page's beforeunload runs first and may cancel. When the
/// close goes ahead, the `close_ready` callback fires.
#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_close(id: c_int) {
    browser::close(id);
}

/// Stops all callbacks for this browser. Call before freeing the callback context.
#[unsafe(no_mangle)]
pub extern "C" fn mini_browser_detach(id: c_int) {
    browser::detach(id);
}

/// Starts the control socket at `socket_path` that `mini_mcp` connects to.
/// `handler` gets every request except `cdp`, on the main thread, and must
/// answer each one with `mini_ipc_reply`. Returns false if the socket can't be
/// created.
///
/// # Safety
/// `socket_path` must be a NUL-terminated UTF-8 string. `ctx` must stay valid
/// for the life of the process.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mini_ipc_start(socket_path: *const c_char, ctx: *mut c_void, handler: ipc::Handler) -> bool {
    let path = unsafe { cstr(socket_path) };
    match ipc::start(std::path::Path::new(&path), ctx, handler) {
        Ok(()) => true,
        Err(e) => {
            eprintln!("mini: control socket {path}: {e}");
            false
        }
    }
}

/// Answers the request `token`. `reply_json` is `{"result": ...}` or
/// `{"error": "..."}`.
///
/// # Safety
/// `reply_json` must be a NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mini_ipc_reply(token: u64, reply_json: *const c_char) {
    let reply = unsafe { cstr(reply_json) };
    match serde_json::from_str(&reply) {
        Ok(value) => ipc::reply(token, value),
        Err(e) => ipc::reply_error(token, format!("bad reply from app: {e}")),
    }
}

unsafe fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

// The cef crate's sandbox bindings sit in the same object file as everything
// else, so linking any of cef pulls in references to these two symbols. Only
// the helper uses the sandbox, and it loads libcef_sandbox.dylib at runtime.
// These stubs satisfy the linker for the main executable and are never called.
#[unsafe(no_mangle)]
pub extern "C" fn cef_sandbox_initialize(_argc: c_int, _argv: *mut *mut c_char) -> *mut c_void {
    std::ptr::null_mut()
}

#[unsafe(no_mangle)]
pub extern "C" fn cef_sandbox_destroy(_context: *mut c_void) {}
