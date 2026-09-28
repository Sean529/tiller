//! Browser registry and CEF handlers. Everything here runs on the CEF UI
//! thread, which on macOS is the main thread.

use cef::*;
use std::{
    cell::RefCell,
    collections::HashMap,
    ffi::{CString, c_char, c_void},
};

/// Mirrors `MiniBrowserCallbacks` in mini_core.h.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Callbacks {
    pub ctx: *mut c_void,
    pub address_changed: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub title_changed: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub loading_state_changed: Option<unsafe extern "C" fn(*mut c_void, bool, bool, bool)>,
}

struct Entry {
    browser: Browser,
    callbacks: Option<Callbacks>,
}

thread_local! {
    static BROWSERS: RefCell<HashMap<i32, Entry>> = RefCell::new(HashMap::new());
}

pub fn get(id: i32) -> Option<Browser> {
    BROWSERS.with_borrow(|map| map.get(&id).map(|e| e.browser.clone()))
}

fn callbacks_for(browser: Option<&mut Browser>) -> Option<Callbacks> {
    let id = browser?.identifier();
    BROWSERS.with_borrow(|map| map.get(&id).and_then(|e| e.callbacks))
}

fn to_cstring(s: Option<&CefString>) -> CString {
    let s = s.map(|s| s.to_string()).unwrap_or_default();
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

pub fn create(parent_view: *mut c_void, width: i32, height: i32, url: &str, callbacks: Callbacks) -> i32 {
    let window_info = WindowInfo {
        parent_view,
        bounds: Rect { x: 0, y: 0, width, height },
        runtime_style: RuntimeStyle::ALLOY,
        ..Default::default()
    };
    let mut client = MiniClient::new();
    let Some(browser) = browser_host_create_browser_sync(
        Some(&window_info),
        Some(&mut client),
        Some(&CefString::from(url)),
        Some(&BrowserSettings::default()),
        None,
        None,
    ) else {
        return -1;
    };
    let id = browser.identifier();
    BROWSERS.with_borrow_mut(|map| map.insert(id, Entry { browser, callbacks: Some(callbacks) }));
    id
}

/// Stops callbacks into the Swift side, whose context may be freed soon.
pub fn detach(id: i32) {
    BROWSERS.with_borrow_mut(|map| {
        if let Some(entry) = map.get_mut(&id) {
            entry.callbacks = None;
        }
    });
}

/// Starts closing every browser. Each one runs its beforeunload handlers, then
/// asks its window to close. Quits right away when no browser exists.
pub fn close_all() {
    // Collect first: closing can call back into handlers that borrow the map.
    let browsers: Vec<Browser> = BROWSERS.with_borrow(|map| map.values().map(|e| e.browser.clone()).collect());
    if browsers.is_empty() {
        quit_message_loop();
        return;
    }
    for browser in browsers {
        if let Some(host) = browser.host() {
            host.close_browser(0);
        }
    }
}

wrap_client! {
    struct MiniClient;

    impl Client {
        fn display_handler(&self) -> Option<DisplayHandler> {
            Some(MiniDisplayHandler::new())
        }

        fn life_span_handler(&self) -> Option<LifeSpanHandler> {
            Some(MiniLifeSpanHandler::new())
        }

        fn load_handler(&self) -> Option<LoadHandler> {
            Some(MiniLoadHandler::new())
        }
    }
}

wrap_display_handler! {
    struct MiniDisplayHandler;

    impl DisplayHandler {
        fn on_address_change(&self, browser: Option<&mut Browser>, frame: Option<&mut Frame>, url: Option<&CefString>) {
            if frame.is_none_or(|f| f.is_main() == 0) {
                return;
            }
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.address_changed {
                let url = to_cstring(url);
                unsafe { f(cb.ctx, url.as_ptr()) };
            }
        }

        fn on_title_change(&self, browser: Option<&mut Browser>, title: Option<&CefString>) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.title_changed {
                let title = to_cstring(title);
                unsafe { f(cb.ctx, title.as_ptr()) };
            }
        }
    }
}

wrap_load_handler! {
    struct MiniLoadHandler;

    impl LoadHandler {
        fn on_loading_state_change(&self, browser: Option<&mut Browser>, is_loading: i32, can_go_back: i32, can_go_forward: i32) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.loading_state_changed {
                unsafe { f(cb.ctx, is_loading != 0, can_go_back != 0, can_go_forward != 0) };
            }
        }
    }
}

wrap_life_span_handler! {
    struct MiniLifeSpanHandler;

    impl LifeSpanHandler {
        /// Tabs arrive in step 5. Until then a popup loads in the same browser.
        fn on_before_popup(
            &self,
            browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            _popup_id: i32,
            target_url: Option<&CefString>,
            _target_frame_name: Option<&CefString>,
            _target_disposition: WindowOpenDisposition,
            _user_gesture: i32,
            _popup_features: Option<&PopupFeatures>,
            _window_info: Option<&mut WindowInfo>,
            _client: Option<&mut Option<Client>>,
            _settings: Option<&mut BrowserSettings>,
            _extra_info: Option<&mut Option<DictionaryValue>>,
            _no_javascript_access: Option<&mut i32>,
        ) -> i32 {
            if let (Some(browser), Some(url)) = (browser, target_url)
                && let Some(frame) = browser.main_frame()
            {
                frame.load_url(Some(url));
            }
            1
        }

        /// Returning false lets CEF send the close event to the window, whose
        /// `windowShouldClose:` then calls `mini_browser_try_close` again.
        fn do_close(&self, _browser: Option<&mut Browser>) -> i32 {
            0
        }

        fn on_before_close(&self, browser: Option<&mut Browser>) {
            let Some(browser) = browser else { return };
            let id = browser.identifier();
            let empty = BROWSERS.with_borrow_mut(|map| {
                map.remove(&id);
                map.is_empty()
            });
            // One window for now, so the last browser closing quits the app.
            if empty {
                quit_message_loop();
            }
        }
    }
}

wrap_app! {
    pub struct MiniApp;

    impl App {
        fn on_before_command_line_processing(&self, process_type: Option<&CefString>, command_line: Option<&mut CommandLine>) {
            let is_browser = process_type.is_none_or(|t| t.to_string().is_empty());
            if let (true, Some(cmd)) = (is_browser, command_line) {
                // Keeps Chromium from asking for the login keychain password to
                // encrypt cookies. Cookies are stored with a fixed key instead.
                cmd.append_switch(Some(&CefString::from("use-mock-keychain")));
            }
        }
    }
}
