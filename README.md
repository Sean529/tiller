# Mini

A small macOS browser: Chromium (via the Rust `cef` crate) inside a native Swift/AppKit shell, with an agent side panel that drives the browser through an MCP server.

## Layout

| Path | What it is |
|---|---|
| `core/` | Rust static library linked into the app. Loads CEF, will own browsers and tabs. C header in `app/Sources/CMiniCore/mini_core.h`. |
| `helper/` | Rust binary for CEF subprocesses, copied into the five `Mini Helper*.app` bundles. |
| `mcp/` | Rust stdio MCP server that the agent CLI launches. |
| `app/` | SwiftPM package with the AppKit app. Menu is built in code, so no Xcode or `ibtool` needed. |
| `scripts/bundle.sh` | Builds everything and assembles an ad-hoc signed `build/Mini.app`. |

## One-time setup

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
brew install ninja
git clone https://github.com/tauri-apps/cef-rs && cd cef-rs
git checkout cef-v154.2.0+154.0.28
cargo run -p export-cef-dir -- --force $HOME/.local/share/cef
```

`bundle.sh` reads CEF from `$CEF_PATH`, defaulting to `~/.local/share/cef`. Keep that download in step with the `cef` version pinned in `Cargo.toml`.

## Build and run

```sh
scripts/bundle.sh            # release; pass `debug` for a debug build
open build/Mini.app
```
