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
