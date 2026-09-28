// C interface of the Rust crate in core/. Keep in sync with core/src/lib.rs.
#pragma once
#include <stdbool.h>

// Called on the main thread. `ctx` is passed back unchanged.
typedef struct MiniBrowserCallbacks {
    void *ctx;
    void (*address_changed)(void *ctx, const char *url);
    void (*title_changed)(void *ctx, const char *title);
    void (*loading_state_changed)(void *ctx, bool is_loading, bool can_go_back, bool can_go_forward);
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

// For windowShouldClose:. True means close now. False means beforeunload is
// running and CEF will ask the window to close again.
bool mini_browser_try_close(int id);

// Stops callbacks for this browser. Call before freeing the callback context.
void mini_browser_detach(int id);
