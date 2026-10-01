//! CEF subprocess entry point. `scripts/bundle.sh` copies this binary into the
//! five `Tiller Helper*.app` bundles (GPU, Renderer, Plugin, Alerts, plain).

use cef::{args::Args, *};

fn main() {
    let args = Args::new();

    let _sandbox = {
        let mut sandbox = cef::sandbox::Sandbox::new();
        sandbox.initialize(args.as_main_args());
        sandbox
    };

    let _loader = {
        let Ok(exe) = std::env::current_exe() else {
            eprintln!("tiller helper: can't find its own executable");
            std::process::exit(1);
        };
        let loader = library_loader::LibraryLoader::new(&exe, true);
        if !loader.load() {
            eprintln!("tiller helper: Chromium Embedded Framework not found next to {}", exe.display());
            std::process::exit(1);
        }
        loader
    };

    let _ = api_hash(sys::CEF_API_VERSION_LAST, 0);

    let code = execute_process(Some(args.as_main_args()), None::<&mut App>, std::ptr::null_mut());
    std::process::exit(code);
}
