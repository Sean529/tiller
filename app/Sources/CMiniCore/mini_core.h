// C interface of the Rust crate in core/. Keep in sync with core/src/lib.rs.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Called on the main thread. `ctx` is passed back unchanged.
typedef struct MiniBrowserCallbacks {
    void *ctx;
    void (*address_changed)(void *ctx, const char *url);
    void (*title_changed)(void *ctx, const char *title);
    void (*loading_state_changed)(void *ctx, bool is_loading, bool can_go_back, bool can_go_forward);
    // PNG bytes of the page's favicon, or len 0 when it has none.
    void (*favicon_changed)(void *ctx, const uint8_t *png, size_t len);
    // A popup or new-window link. The URL should open in a new tab.
    void (*open_tab)(void *ctx, const char *url, bool background);
    // beforeunload passed. Remove the browser's view to finish closing it.
    void (*close_ready)(void *ctx);
    // A Command or Control key press (an NSEvent *) before the page sees it.
    // Return true if the app handled it.
    bool (*key_equivalent)(void *ctx, void *ns_event);
} MiniBrowserCallbacks;

// Static version string. Do not free.
const char *mini_core_version(void);

// Loads CEF, installs the CEF-compatible NSApplication subclass and initializes
// CEF. Call first in main, before touching NSApp. Returns 0 or an exit code.
int mini_core_start(void);

// Runs the message loop until the last browser closes, then shuts CEF down.
void mini_core_run(void);

// Creates a browser filling `parent_view` (an NSView *). Returns its id or -1.
int mini_browser_create(void *parent_view, int width, int height, const char *url,
                        MiniBrowserCallbacks callbacks);
void mini_browser_load_url(int id, const char *url);
void mini_browser_go_back(int id);
void mini_browser_go_forward(int id);
void mini_browser_reload(int id);
void mini_browser_stop(int id);
void mini_browser_set_focus(int id, bool focus);

// Runs JavaScript in the tab's main frame. Nothing comes back.
void mini_browser_execute_js(int id, const char *code);

// Sets cookies, replacing any with the same name, domain and path.
// `cookies_json` is an array of objects:
//   url        where the cookie is set from, e.g. "https://example.com/"
//   name, value, path
//   domain     ".example.com" for a domain cookie, "" for a host-only one
//   secure, httponly, has_expires   booleans
//   creation, last_access, expires  microseconds since 1601-01-01 UTC
//   same_site  "unspecified", "none", "lax" or "strict"
//   priority   "low", "medium" or "high"
// `done` runs on the main thread once every cookie is set and the store is
// written to disk, with how many were set and how many were rejected.
void mini_cookies_import(const char *cookies_json, void *ctx,
                         void (*done)(void *ctx, int imported, int failed));

// Closes a tab. beforeunload runs first and may cancel. If it doesn't,
// close_ready fires.
void mini_browser_close(int id);

// Stops callbacks for this browser. Call before freeing the callback context.
void mini_browser_detach(int id);

// Starts the control socket mini_mcp connects to. `handler` runs on the main
// thread for every request except DevTools calls, which the core answers
// itself. Each request must be answered with mini_ipc_reply using its token.
// Returns false if the socket can't be created.
bool mini_ipc_start(const char *socket_path, void *ctx,
                    void (*handler)(void *ctx, const char *request_json, uint64_t token));

// Answers a request. `reply_json` is {"result": ...} or {"error": "..."}.
void mini_ipc_reply(uint64_t token, const char *reply_json);
