// C interface of the Rust crate in core/. Keep in sync with core/src/lib.rs.
#pragma once
#include <stdbool.h>

// Static version string. Do not free.
const char *mini_core_version(void);

// Loads Chromium Embedded Framework from ../Frameworks. Main thread only.
bool mini_core_load_cef(void);
