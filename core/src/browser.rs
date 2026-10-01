//! Browser registry and CEF handlers. Everything here runs on the CEF UI
//! thread, which on macOS is the main thread.

use crate::ipc;
use cef::*;
use serde::Deserialize;
use serde_json::{Value, json, value::RawValue};
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    ffi::{CString, c_char, c_void},
    sync::OnceLock,
};

/// Mirrors `TillerBrowserCallbacks` in tiller_core.h.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Callbacks {
    pub ctx: *mut c_void,
    pub address_changed: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub title_changed: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub loading_state_changed: Option<unsafe extern "C" fn(*mut c_void, bool, bool, bool)>,
    pub favicon_changed: Option<unsafe extern "C" fn(*mut c_void, *const u8, usize)>,
    pub open_tab: Option<unsafe extern "C" fn(*mut c_void, *const c_char, bool)>,
    pub close_ready: Option<unsafe extern "C" fn(*mut c_void)>,
    pub key_equivalent: Option<unsafe extern "C" fn(*mut c_void, *mut c_void) -> bool>,
    pub loading_progress: Option<unsafe extern "C" fn(*mut c_void, f64)>,
    pub find_result: Option<unsafe extern "C" fn(*mut c_void, i32, i32, bool)>,
    pub auto_resize: Option<unsafe extern "C" fn(*mut c_void, i32, i32)>,
    pub copy_text: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub status_changed: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub fullscreen_changed: Option<unsafe extern "C" fn(*mut c_void, bool)>,
}

struct Entry {
    browser: Browser,
    callbacks: Option<Callbacks>,
    /// Keeps the DevTools observer attached. Added on the first DevTools call.
    devtools: Option<Registration>,
}

/// A DevTools call waiting for its result.
struct PendingCall {
    browser_id: i32,
    token: u64,
}

/// Extension folders for `--load-extension`, comma-separated. Set once before
/// CEF initializes.
pub static EXTENSIONS: OnceLock<String> = OnceLock::new();

thread_local! {
    static BROWSERS: RefCell<HashMap<i32, Entry>> = RefCell::new(HashMap::new());
    static DEVTOOLS_CALLS: RefCell<HashMap<i32, PendingCall>> = RefCell::new(HashMap::new());
    static NEXT_MESSAGE_ID: Cell<i32> = const { Cell::new(1) };
}

pub fn get(id: i32) -> Option<Browser> {
    BROWSERS.with_borrow(|map| map.get(&id).map(|e| e.browser.clone()))
}

fn callbacks_for(browser: Option<&mut Browser>) -> Option<Callbacks> {
    callbacks_for_id(browser?.identifier())
}

fn callbacks_for_id(id: i32) -> Option<Callbacks> {
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
    let mut client = TillerClient::new();
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
    BROWSERS.with_borrow_mut(|map| map.insert(id, Entry { browser, callbacks: Some(callbacks), devtools: None }));
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

/// Starts closing one browser. The page's beforeunload runs first, then
/// `close_ready` fires and the Swift side removes the tab's view.
pub fn close(id: i32) {
    if let Some(host) = get(id).and_then(|b| b.host()) {
        host.close_browser(0);
    }
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

/// Sends one DevTools protocol command to a tab and replies to the control
/// socket request `token` with `{"result": ...}` or `{"error": ...}`.
pub fn devtools_call(id: i32, method: &str, params: Value, token: u64) {
    let Some(host) = get(id).and_then(|b| b.host()) else {
        return ipc::reply_error(token, format!("no tab with id {id}"));
    };
    let attached = BROWSERS.with_borrow_mut(|map| {
        let Some(entry) = map.get_mut(&id) else { return false };
        if entry.devtools.is_none() {
            let mut observer = TillerDevToolsObserver::new();
            entry.devtools = host.add_dev_tools_message_observer(Some(&mut observer));
        }
        entry.devtools.is_some()
    });
    if !attached {
        return ipc::reply_error(token, "could not attach to the tab's DevTools agent");
    }

    let message_id = NEXT_MESSAGE_ID.get();
    NEXT_MESSAGE_ID.set(message_id.wrapping_add(1).max(1));
    DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.insert(message_id, PendingCall { browser_id: id, token }));
    let message = json!({ "id": message_id, "method": method, "params": params }).to_string();
    if host.send_dev_tools_message(Some(message.as_bytes())) == 0 {
        DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.remove(&message_id));
        ipc::reply_error(token, "DevTools message was rejected");
    }
}

/// Fails every DevTools call still waiting on a browser that is going away.
fn fail_devtools_calls(browser_id: i32) {
    let tokens: Vec<u64> = DEVTOOLS_CALLS.with_borrow_mut(|calls| {
        let ids: Vec<i32> = calls.iter().filter(|(_, c)| c.browser_id == browser_id).map(|(id, _)| *id).collect();
        ids.iter().filter_map(|id| calls.remove(id)).map(|c| c.token).collect()
    });
    for token in tokens {
        ipc::reply_error(token, "the tab closed");
    }
}

/// The parts of a DevTools message that matter here. The result stays as the
/// text it arrived as: a screenshot's reply is megabytes of base64, and this
/// runs on the UI thread, so it is passed through rather than parsed into a
/// tree and written out again.
#[derive(Deserialize)]
struct DevToolsMessage<'a> {
    id: Option<i64>,
    #[serde(borrow)]
    result: Option<&'a RawValue>,
    error: Option<DevToolsError>,
}

#[derive(Deserialize)]
struct DevToolsError {
    message: Option<String>,
}

wrap_dev_tools_message_observer! {
    struct TillerDevToolsObserver;

    impl DevToolsMessageObserver {
        /// Answers the matching call. Events and replies to anyone else's calls
        /// are left for CEF's default handling.
        fn on_dev_tools_message(&self, _browser: Option<&mut Browser>, message: Option<&[u8]>) -> i32 {
            let Some(text) = message.and_then(|m| std::str::from_utf8(m).ok()) else { return 0 };
            // Events carry no id. Skipping them without a parse keeps a busy
            // page's stream of events off the UI thread's plate.
            if !text.contains("\"id\"") {
                return 0;
            }
            let Ok(message) = serde_json::from_str::<DevToolsMessage>(text) else { return 0 };
            let Some(id) = message.id else { return 0 };
            let Some(call) = DEVTOOLS_CALLS.with_borrow_mut(|calls| calls.remove(&(id as i32))) else { return 0 };
            match message.error {
                Some(error) => ipc::reply_error(call.token, error.message.unwrap_or_else(|| "DevTools error".into())),
                None => ipc::reply_raw(call.token, format!("{{\"result\":{}}}", message.result.map_or("{}", |r| r.get()))),
            }
            1
        }
    }
}

wrap_client! {
    struct TillerClient;

    impl Client {
        fn display_handler(&self) -> Option<DisplayHandler> {
            Some(TillerDisplayHandler::new())
        }

        fn life_span_handler(&self) -> Option<LifeSpanHandler> {
            Some(TillerLifeSpanHandler::new())
        }

        fn keyboard_handler(&self) -> Option<KeyboardHandler> {
            Some(TillerKeyboardHandler::new())
        }

        fn load_handler(&self) -> Option<LoadHandler> {
            Some(TillerLoadHandler::new())
        }

        fn find_handler(&self) -> Option<FindHandler> {
            Some(TillerFindHandler::new())
        }

        fn download_handler(&self) -> Option<DownloadHandler> {
            Some(crate::downloads::TillerDownloadHandler::new())
        }

        fn request_handler(&self) -> Option<RequestHandler> {
            Some(TillerRequestHandler::new())
        }

        fn context_menu_handler(&self) -> Option<ContextMenuHandler> {
            Some(TillerContextMenuHandler::new())
        }
    }
}

/// Asks the Swift side to open `url` in a new tab.
fn open_in_tab(browser: Option<&mut Browser>, url: Option<&CefString>, background: bool) {
    if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.open_tab {
        let url = to_cstring(url);
        unsafe { f(cb.ctx, url.as_ptr(), background) };
    }
}

wrap_request_handler! {
    struct TillerRequestHandler;

    impl RequestHandler {
        /// Cmd+click, Shift+click and middle click on a link. Chromium turns
        /// the modifiers into a disposition before it gets here: Cmd or middle
        /// click is a background tab, Cmd+Shift a foreground one, Shift a new
        /// window, which becomes a selected tab since Tiller has one window.
        fn on_open_urlfrom_tab(
            &self,
            browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            target_url: Option<&CefString>,
            target_disposition: WindowOpenDisposition,
            _user_gesture: i32,
        ) -> i32 {
            let background = match target_disposition {
                WindowOpenDisposition::NEW_BACKGROUND_TAB => true,
                WindowOpenDisposition::NEW_FOREGROUND_TAB
                | WindowOpenDisposition::NEW_WINDOW
                | WindowOpenDisposition::NEW_POPUP => false,
                _ => return 0,
            };
            open_in_tab(browser, target_url, background);
            1
        }
    }
}

const MENU_OPEN_LINK: i32 = sys::cef_menu_id_t::MENU_ID_USER_FIRST as i32;
const MENU_OPEN_LINK_BACKGROUND: i32 = MENU_OPEN_LINK + 1;
const MENU_COPY_LINK: i32 = MENU_OPEN_LINK + 2;

wrap_context_menu_handler! {
    struct TillerContextMenuHandler;

    impl ContextMenuHandler {
        /// Puts the link items above CEF's own when the menu is for a link.
        fn on_before_context_menu(
            &self,
            _browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            params: Option<&mut ContextMenuParams>,
            model: Option<&mut MenuModel>,
        ) {
            let (Some(params), Some(model)) = (params, model) else { return };
            let link = sys::cef_context_menu_type_flags_t::CM_TYPEFLAG_LINK.0;
            if params.type_flags().as_ref().0 & link == 0 {
                return;
            }
            let items = [
                (MENU_OPEN_LINK, "Open Link in New Tab"),
                (MENU_OPEN_LINK_BACKGROUND, "Open Link in Background"),
                (MENU_COPY_LINK, "Copy Link"),
            ];
            for (index, (id, label)) in items.iter().enumerate() {
                model.insert_item_at(index, *id, Some(&CefString::from(*label)));
            }
            if model.count() > items.len() {
                model.insert_separator_at(items.len());
            }
        }

        fn on_context_menu_command(
            &self,
            browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            params: Option<&mut ContextMenuParams>,
            command_id: i32,
            _event_flags: EventFlags,
        ) -> i32 {
            let Some(params) = params else { return 0 };
            let url = CefString::from(&params.link_url());
            match command_id {
                MENU_OPEN_LINK => open_in_tab(browser, Some(&url), false),
                MENU_OPEN_LINK_BACKGROUND => open_in_tab(browser, Some(&url), true),
                MENU_COPY_LINK => {
                    if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.copy_text {
                        let url = to_cstring(Some(&url));
                        unsafe { f(cb.ctx, url.as_ptr()) };
                    }
                }
                _ => return 0,
            }
            1
        }
    }
}

wrap_find_handler! {
    struct TillerFindHandler;

    impl FindHandler {
        fn on_find_result(
            &self,
            browser: Option<&mut Browser>,
            _identifier: i32,
            count: i32,
            _selection_rect: Option<&Rect>,
            active_match_ordinal: i32,
            final_update: i32,
        ) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.find_result {
                unsafe { f(cb.ctx, count, active_match_ordinal, final_update != 0) };
            }
        }
    }
}

wrap_display_handler! {
    struct TillerDisplayHandler;

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

        fn on_favicon_urlchange(&self, browser: Option<&mut Browser>, icon_urls: Option<&mut CefStringList>) {
            let Some(browser) = browser else { return };
            let first = icon_urls.and_then(first_string);
            let Some(url) = first else {
                send_favicon(browser.identifier(), &[]);
                return;
            };
            if let Some(host) = browser.host() {
                let mut callback = TillerFaviconCallback::new(browser.identifier(), page_origin(browser));
                host.download_image(Some(&CefString::from(url.as_str())), 1, 64, 0, Some(&mut callback));
            }
        }

        fn on_title_change(&self, browser: Option<&mut Browser>, title: Option<&CefString>) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.title_changed {
                let title = to_cstring(title);
                unsafe { f(cb.ctx, title.as_ptr()) };
            }
        }

        /// The link under the mouse, or nothing when it leaves one.
        fn on_status_message(&self, browser: Option<&mut Browser>, value: Option<&CefString>) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.status_changed {
                let text = to_cstring(value);
                unsafe { f(cb.ctx, text.as_ptr()) };
            }
        }

        /// The page asked for the whole screen, as a video player does, or
        /// gave it back. The app takes the window there and back.
        fn on_fullscreen_mode_change(&self, browser: Option<&mut Browser>, fullscreen: i32) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.fullscreen_changed {
                unsafe { f(cb.ctx, fullscreen != 0) };
            }
        }

        fn on_loading_progress_change(&self, browser: Option<&mut Browser>, progress: f64) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.loading_progress {
                unsafe { f(cb.ctx, progress) };
            }
        }

        /// The page's size in points, for browsers with auto-resize on.
        fn on_auto_resize(&self, browser: Option<&mut Browser>, new_size: Option<&Size>) -> i32 {
            let Some(size) = new_size else { return 0 };
            match callbacks_for(browser) {
                Some(Callbacks { ctx, auto_resize: Some(f), .. }) => {
                    unsafe { f(ctx, size.width, size.height) };
                    1
                }
                _ => 0,
            }
        }
    }
}

/// First entry of a list CEF lends to a callback. The crate's `Clone` and
/// `IntoIterator` for a borrowed list lose its contents, so read it directly.
fn first_string(list: &mut CefStringList) -> Option<String> {
    let raw: *mut sys::_cef_string_list_t = list.into();
    if raw.is_null() || unsafe { sys::cef_string_list_size(raw) } == 0 {
        return None;
    }
    let mut value: sys::cef_string_t = unsafe { std::mem::zeroed() };
    if unsafe { sys::cef_string_list_value(raw, 0, &mut value) } == 0 {
        return None;
    }
    let s = CefString::from(std::ptr::from_ref(&value)).to_string();
    unsafe { sys::cef_string_utf16_clear(&mut value) };
    Some(s)
}

/// Scheme, host and port of the page the browser shows, such as
/// "https://example.com".
fn page_origin(browser: &Browser) -> String {
    let url = browser.main_frame().map(|f| CefString::from(&f.url()).to_string()).unwrap_or_default();
    let start = url.find("://").map_or(0, |i| i + 3);
    let end = url[start..].find('/').map_or(url.len(), |i| start + i);
    url[..end].to_string()
}

fn send_favicon(id: i32, png: &[u8]) {
    if let Some(cb) = callbacks_for_id(id) && let Some(f) = cb.favicon_changed {
        unsafe { f(cb.ctx, png.as_ptr(), png.len()) };
    }
}

wrap_download_image_callback! {
    struct TillerFaviconCallback {
        browser_id: i32,
        // The site the icon belongs to. An icon that arrives after the tab
        // went to another site is dropped, so it can't be shown or saved
        // as that site's.
        origin: String,
    }

    impl DownloadImageCallback {
        fn on_download_image_finished(&self, _image_url: Option<&CefString>, _http_status_code: i32, image: Option<&mut Image>) {
            if get(self.browser_id).is_none_or(|b| page_origin(&b) != self.origin) {
                return;
            }
            // CEF returns nothing unless both size out-parameters are given.
            let (mut width, mut height) = (0, 0);
            let png = image.and_then(|image| image.as_png(2.0, 1, Some(&mut width), Some(&mut height)));
            match png {
                Some(png) if png.size() > 0 => {
                    let bytes = unsafe { std::slice::from_raw_parts(png.raw_data().cast::<u8>(), png.size()) };
                    send_favicon(self.browser_id, bytes);
                }
                _ => send_favicon(self.browser_id, &[]),
            }
        }
    }
}

wrap_keyboard_handler! {
    struct TillerKeyboardHandler;

    impl KeyboardHandler {
        /// Gives the menu bar first pick of Command and Control shortcuts, so
        /// Cmd+W, Cmd+R, Cmd+[ and the rest work while a page has focus. The
        /// Swift side leaves Edit menu keys alone so pages still get Cmd+Z etc.
        fn on_pre_key_event(
            &self,
            browser: Option<&mut Browser>,
            event: Option<&KeyEvent>,
            os_event: *mut u8,
            _is_keyboard_shortcut: Option<&mut i32>,
        ) -> i32 {
            let Some(event) = event else { return 0 };
            let modifiers = (sys::cef_event_flags_t::EVENTFLAG_COMMAND_DOWN.0 | sys::cef_event_flags_t::EVENTFLAG_CONTROL_DOWN.0) as u32;
            if event.type_ != KeyEventType::RAWKEYDOWN || event.modifiers & modifiers == 0 || os_event.is_null() {
                return 0;
            }
            match callbacks_for(browser) {
                Some(Callbacks { ctx, key_equivalent: Some(f), .. }) => unsafe { f(ctx, os_event.cast()) }.into(),
                _ => 0,
            }
        }
    }
}

wrap_load_handler! {
    struct TillerLoadHandler;

    impl LoadHandler {
        fn on_loading_state_change(&self, browser: Option<&mut Browser>, is_loading: i32, can_go_back: i32, can_go_forward: i32) {
            if let Some(cb) = callbacks_for(browser) && let Some(f) = cb.loading_state_changed {
                unsafe { f(cb.ctx, is_loading != 0, can_go_back != 0, can_go_forward != 0) };
            }
        }
    }
}

wrap_life_span_handler! {
    struct TillerLifeSpanHandler;

    impl LifeSpanHandler {
        /// Opens popups and new-window links as tabs. The new tab is a separate
        /// browser, so the page loses `window.opener` to it.
        fn on_before_popup(
            &self,
            browser: Option<&mut Browser>,
            _frame: Option<&mut Frame>,
            _popup_id: i32,
            target_url: Option<&CefString>,
            _target_frame_name: Option<&CefString>,
            target_disposition: WindowOpenDisposition,
            _user_gesture: i32,
            _popup_features: Option<&PopupFeatures>,
            _window_info: Option<&mut WindowInfo>,
            _client: Option<&mut Option<Client>>,
            _settings: Option<&mut BrowserSettings>,
            _extra_info: Option<&mut Option<DictionaryValue>>,
            _no_javascript_access: Option<&mut i32>,
        ) -> i32 {
            open_in_tab(browser, target_url, target_disposition == WindowOpenDisposition::NEW_BACKGROUND_TAB);
            1
        }

        /// A tab closing must not close the window, so instead of letting CEF
        /// send performClose: to it, tell Swift to remove the tab's view. Tearing
        /// down that view finishes the close and leads to `on_before_close`.
        fn do_close(&self, browser: Option<&mut Browser>) -> i32 {
            // A browser of its own, such as the developer tools window,
            // closes the usual way.
            let Some(cb) = callbacks_for(browser) else { return 0 };
            if let Some(f) = cb.close_ready {
                unsafe { f(cb.ctx) };
            }
            1
        }

        fn on_before_close(&self, browser: Option<&mut Browser>) {
            let Some(browser) = browser else { return };
            let id = browser.identifier();
            fail_devtools_calls(id);
            let empty = BROWSERS.with_borrow_mut(|map| {
                map.remove(&id);
                map.is_empty()
            });
            // One window for now, so the last tab closing quits the app.
            if empty {
                quit_message_loop();
            }
        }
    }
}

wrap_app! {
    pub struct TillerApp;

    impl App {
        fn on_before_command_line_processing(&self, process_type: Option<&CefString>, command_line: Option<&mut CommandLine>) {
            let is_browser = process_type.is_none_or(|t| t.to_string().is_empty());
            if let (true, Some(cmd)) = (is_browser, command_line) {
                // Keeps Chromium from asking for the login keychain password to
                // encrypt cookies. Cookies are stored with a fixed key instead.
                cmd.append_switch(Some(&CefString::from("use-mock-keychain")));
                // A window covered by other windows would otherwise count as
                // hidden, and Chromium drops input to hidden pages, so the
                // agent's clicks and keys would vanish while the user works
                // in another app. The cost is that covered windows keep drawing.
                cmd.append_switch(Some(&CefString::from("disable-backgrounding-occluded-windows")));
                // The profile's enabled extensions, loaded unpacked like
                // Chrome's Load unpacked. Chromium only reads this at startup.
                // An extension that fails to load would otherwise get an error
                // dialog, which hangs startup without Chrome's UI; the error
                // goes to chrome_debug.log instead.
                if let Some(paths) = EXTENSIONS.get().filter(|p| !p.is_empty()) {
                    cmd.append_switch_with_value(
                        Some(&CefString::from("load-extension")),
                        Some(&CefString::from(paths.as_str())),
                    );
                    cmd.append_switch(Some(&CefString::from("noerrdialogs")));
                }
            }
        }
    }
}
