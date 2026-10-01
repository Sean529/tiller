//! File downloads. Each goes to ~/Downloads under a name no file there has
//! yet, and every change of state is reported to the app, which shows them.
//! Everything here runs on the CEF UI thread, the main thread.

use cef::*;
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    ffi::{CString, c_char, c_void},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// Mirrors `TillerDownloadCallback` in tiller_core.h: the tab's browser id,
/// the download's id, path, url, the url before redirects, bytes received,
/// bytes in all (-1 when unknown), and a state: 0 in progress, 1 complete,
/// 2 canceled, 3 failed.
pub type Callback =
    unsafe extern "C" fn(*mut c_void, i32, u32, *const c_char, *const c_char, *const c_char, i64, i64, i32);

thread_local! {
    static HANDLER: Cell<Option<(*mut c_void, Callback)>> = const { Cell::new(None) };
    /// The callback that can cancel each download still under way.
    static CALLBACKS: RefCell<HashMap<u32, DownloadItemCallback>> = RefCell::new(HashMap::new());
    /// Paths handed to downloads still under way, which don't exist on disk
    /// yet, so a second download of the same file gets another name.
    static RESERVED: RefCell<HashMap<u32, PathBuf>> = RefCell::new(HashMap::new());
    /// When each download's progress was last reported.
    static REPORTED: RefCell<HashMap<u32, Instant>> = RefCell::new(HashMap::new());
}

/// Chromium reports progress for every chunk received, far more often than
/// a progress ring can show. Progress is passed on at most this often; a
/// change of state always is.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(100);

pub fn set_handler(ctx: *mut c_void, handler: Option<Callback>) {
    HANDLER.set(handler.map(|h| (ctx, h)));
}

pub fn cancel(id: u32) {
    if let Some(callback) = CALLBACKS.with_borrow(|map| map.get(&id).cloned()) {
        callback.cancel();
    }
}

fn downloads_folder() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join("Downloads")
}

/// `name` in `folder`, or the first of `name-2`, `name-3`… that no file has
/// and no download under way is about to make.
fn unique_path(folder: &Path, name: &str) -> PathBuf {
    let name = if name.is_empty() { "download" } else { name };
    let taken = |path: &PathBuf| path.exists() || RESERVED.with_borrow(|map| map.values().any(|p| p == path));
    let first = folder.join(name);
    if !taken(&first) {
        return first;
    }
    let (stem, extension) = match name.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() => (stem, format!(".{extension}")),
        _ => (name, String::new()),
    };
    (2..)
        .map(|n| folder.join(format!("{stem}-{n}{extension}")))
        .find(|path| !taken(path))
        .expect("an unused name")
}

fn to_cstring(s: String) -> CString {
    CString::new(s).unwrap_or_else(|e| {
        let mut bytes = e.into_vec();
        bytes.retain(|&b| b != 0);
        CString::new(bytes).unwrap_or_default()
    })
}

fn report(browser: Option<&mut Browser>, item: &DownloadItem) {
    let Some((ctx, handler)) = HANDLER.get() else { return };
    let browser_id = browser.map_or(-1, |b| b.identifier());
    let state = if item.is_complete() != 0 {
        1
    } else if item.is_canceled() != 0 {
        2
    } else if item.is_interrupted() != 0 {
        3
    } else {
        0
    };
    let path = to_cstring(CefString::from(&item.full_path()).to_string());
    let url = to_cstring(CefString::from(&item.url()).to_string());
    let original = to_cstring(CefString::from(&item.original_url()).to_string());
    unsafe {
        handler(
            ctx,
            browser_id,
            item.id(),
            path.as_ptr(),
            url.as_ptr(),
            original.as_ptr(),
            item.received_bytes(),
            item.total_bytes(),
            state,
        )
    };
}

wrap_download_handler! {
    pub struct TillerDownloadHandler;

    impl DownloadHandler {
        fn can_download(&self, _browser: Option<&mut Browser>, _url: Option<&CefString>, _request_method: Option<&CefString>) -> i32 {
            1
        }

        /// Picks the file's path. Without this CEF drops the download.
        fn on_before_download(
            &self,
            browser: Option<&mut Browser>,
            download_item: Option<&mut DownloadItem>,
            suggested_name: Option<&CefString>,
            callback: Option<&mut BeforeDownloadCallback>,
        ) -> i32 {
            let (Some(item), Some(callback)) = (download_item, callback) else { return 0 };
            let folder = downloads_folder();
            let _ = std::fs::create_dir_all(&folder);
            let path = unique_path(&folder, &suggested_name.map(|s| s.to_string()).unwrap_or_default());
            RESERVED.with_borrow_mut(|map| map.insert(item.id(), path.clone()));
            callback.cont(Some(&CefString::from(path.to_string_lossy().as_ref())), 0);
            report(browser, item);
            1
        }

        fn on_download_updated(
            &self,
            browser: Option<&mut Browser>,
            download_item: Option<&mut DownloadItem>,
            callback: Option<&mut DownloadItemCallback>,
        ) {
            let Some(item) = download_item else { return };
            let id = item.id();
            if item.is_in_progress() != 0 {
                if let Some(callback) = callback {
                    CALLBACKS.with_borrow_mut(|map| map.insert(id, callback.clone()));
                }
                let now = Instant::now();
                let due = REPORTED.with_borrow_mut(|map| match map.get(&id) {
                    Some(last) if now.duration_since(*last) < PROGRESS_INTERVAL => false,
                    _ => {
                        map.insert(id, now);
                        true
                    }
                });
                if !due {
                    return;
                }
            } else {
                CALLBACKS.with_borrow_mut(|map| map.remove(&id));
                RESERVED.with_borrow_mut(|map| map.remove(&id));
                REPORTED.with_borrow_mut(|map| map.remove(&id));
            }
            report(browser, item);
        }
    }
}
