//! Browser core for Mini. Built as a static library and linked into the Swift app.
//! Every exported function is declared in `app/Sources/CMiniCore/include/mini_core.h`.

use std::ffi::{c_char, CStr};

static VERSION: &CStr = c"mini-core 0.1.0 (cef 154.2.0+154.0.28)";

/// Returns a static, NUL-terminated version string. The caller must not free it.
#[unsafe(no_mangle)]
pub extern "C" fn mini_core_version() -> *const c_char {
    VERSION.as_ptr()
}

/// Loads the Chromium Embedded Framework from `../Frameworks` relative to the
/// running executable. Must be called on the main thread before any other CEF call.
/// Returns false if the framework is missing, e.g. when run outside `Mini.app`.
#[unsafe(no_mangle)]
pub extern "C" fn mini_core_load_cef() -> bool {
    let Ok(exe) = std::env::current_exe() else {
        return false;
    };
    let loader = cef::library_loader::LibraryLoader::new(&exe, false);
    if !loader.load() {
        return false;
    }
    // The framework has to stay loaded for the life of the process.
    std::mem::forget(loader);
    let _ = cef::api_hash(cef::sys::CEF_API_VERSION_LAST, 0);
    true
}
