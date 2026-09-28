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
open build/Mini.app --args -url https://example.com   # start on another page
```

Mini passes `--use-mock-keychain` to Chromium, so it never asks for the login keychain password. The cost is that cookies are encrypted with a fixed key instead of one kept in the keychain.

## Tabs

| Shortcut | Action |
|---|---|
| Cmd+T | New tab |
| Cmd+W | Close tab (the window closes with its last tab, and the app quits) |
| Cmd+Shift+W | Close window |
| Cmd+Shift+] / Cmd+Shift+[, Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Cmd+1 to Cmd+8, Cmd+9 | That tab, last tab |
| Middle click on a tab | Close it |

Menu shortcuts take priority over the page, except Edit menu keys (Cmd+Z, Cmd+A, Cmd+C and so on), which the page gets first so editors in it keep their own handling.

Popups and `target=_blank` links open as new tabs. Each is a separate browser, so the new page has no `window.opener`. Sign-in flows that post a result back to the opener won't work.
