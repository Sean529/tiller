//! Cookie import. Cookies go through the profile's cookie manager, so Chromium
//! stores them the same way it stores cookies the pages set. Everything here
//! runs on the CEF UI thread, which on macOS is the main thread.

use cef::*;
use serde_json::Value;
use std::{
    cell::{Cell, RefCell},
    collections::{HashMap, HashSet},
    ffi::c_void,
};

/// Called once with the number of cookies set and the number that failed.
pub type Done = unsafe extern "C" fn(ctx: *mut c_void, imported: i32, failed: i32);

struct Import {
    /// The cookie manager of the profile they go to.
    manager: CookieManager,
    ctx: *mut c_void,
    done: Done,
    /// Indexes of cookies still waiting for their callback. A cookie is counted
    /// once, even if CEF both rejects it and calls back.
    pending: HashSet<usize>,
    imported: i32,
    failed: i32,
}

thread_local! {
    static IMPORTS: RefCell<HashMap<u64, Import>> = RefCell::new(HashMap::new());
    static NEXT_ID: Cell<u64> = const { Cell::new(1) };
}

/// Sets every cookie in `json`, a JSON array of objects as described in
/// tiller_core.h, in request context `context`. A cookie with the same name,
/// domain and path is replaced. `done` runs after the last cookie is set and
/// the store is flushed.
pub fn import(context: i32, json: &str, ctx: *mut c_void, done: Done) {
    let cookies = match serde_json::from_str::<Value>(json) {
        Ok(Value::Array(cookies)) => cookies,
        _ => return unsafe { done(ctx, 0, 0) },
    };
    let Some(manager) = crate::browser::context(context).and_then(|c| c.cookie_manager(None)) else {
        return unsafe { done(ctx, 0, cookies.len() as i32) };
    };

    let id = NEXT_ID.get();
    NEXT_ID.set(id + 1);
    let pending = (0..cookies.len()).collect();
    IMPORTS.with_borrow_mut(|imports| {
        imports.insert(id, Import { manager: manager.clone(), ctx, done, pending, imported: 0, failed: 0 })
    });
    if cookies.is_empty() {
        return flush(id);
    }
    for (index, value) in cookies.iter().enumerate() {
        let Some((url, cookie)) = parse(value) else {
            finish_one(id, index, false);
            continue;
        };
        let mut callback = TillerSetCookieCallback::new(id, index);
        if manager.set_cookie(Some(&CefString::from(url.as_str())), Some(&cookie), Some(&mut callback)) == 0 {
            finish_one(id, index, false);
        }
    }
}

fn parse(value: &Value) -> Option<(String, Cookie)> {
    let text = |key: &str| value[key].as_str().unwrap_or_default();
    let flag = |key: &str| value[key].as_bool().unwrap_or(false) as i32;
    let time = |key: &str| Basetime { val: value[key].as_i64().unwrap_or(0) };
    let url = value["url"].as_str()?;
    let name = value["name"].as_str()?;
    let cookie = Cookie {
        name: CefString::from(name),
        value: CefString::from(text("value")),
        domain: CefString::from(text("domain")),
        path: CefString::from(text("path")),
        secure: flag("secure"),
        httponly: flag("httponly"),
        creation: time("creation"),
        last_access: time("last_access"),
        has_expires: flag("has_expires"),
        expires: time("expires"),
        same_site: match text("same_site") {
            "none" => CookieSameSite::NO_RESTRICTION,
            "lax" => CookieSameSite::LAX_MODE,
            "strict" => CookieSameSite::STRICT_MODE,
            _ => CookieSameSite::UNSPECIFIED,
        },
        priority: match text("priority") {
            "low" => CookiePriority::LOW,
            "high" => CookiePriority::HIGH,
            _ => CookiePriority::MEDIUM,
        },
        ..Default::default()
    };
    Some((url.to_owned(), cookie))
}

fn finish_one(id: u64, index: usize, success: bool) {
    let all_done = IMPORTS.with_borrow_mut(|imports| {
        let Some(import) = imports.get_mut(&id) else { return false };
        if !import.pending.remove(&index) {
            return false;
        }
        if success {
            import.imported += 1;
        } else {
            import.failed += 1;
        }
        import.pending.is_empty()
    });
    if all_done {
        flush(id);
    }
}

/// Writes the new cookies to disk, then reports.
fn flush(id: u64) {
    let manager = IMPORTS.with_borrow(|imports| imports.get(&id).map(|i| i.manager.clone()));
    let flushing = manager.is_some_and(|manager| manager.flush_store(Some(&mut TillerFlushCallback::new(id))) != 0);
    if !flushing {
        report(id);
    }
}

fn report(id: u64) {
    if let Some(import) = IMPORTS.with_borrow_mut(|imports| imports.remove(&id)) {
        unsafe { (import.done)(import.ctx, import.imported, import.failed) };
    }
}

wrap_set_cookie_callback! {
    struct TillerSetCookieCallback {
        import_id: u64,
        index: usize,
    }

    impl SetCookieCallback {
        fn on_complete(&self, success: i32) {
            finish_one(self.import_id, self.index, success != 0);
        }
    }
}

wrap_completion_callback! {
    struct TillerFlushCallback {
        import_id: u64,
    }

    impl CompletionCallback {
        fn on_complete(&self) {
            report(self.import_id);
        }
    }
}
