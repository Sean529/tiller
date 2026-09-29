# Tiller

A small macOS browser built on Chromium, with a native Swift/AppKit interface and a built-in agent panel that can drive the browser.

## Features

- **Chromium engine, native shell.** Pages render with Chromium through CEF; the window, tabs and menus are AppKit.
- **Tabs and session restore.** Open tabs and recently closed tabs survive restarts and crashes.
- **Import from Chrome.** Cookies, saved passwords, history, search engine and homepage.
- **Profiles.** Each profile has its own site data, history, passwords, settings and chats, and runs as its own app instance.
- **Agent panel.** Chat with Qoder CLI, Claude Code or Codex in a side panel that controls the browser.
- **Browser tools.** A stdio MCP server and the `tiller` command-line tool expose the same tools to external agents and scripts.

## Requirements

- macOS with the Swift toolchain (Xcode Command Line Tools)
- Rust, installed through [rustup](https://rustup.rs)
- [Ninja](https://ninja-build.org)
- CEF 154, matching the `cef` version pinned in `Cargo.toml`

## Setup

Install the toolchain and download CEF once:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
brew install ninja
git clone https://github.com/tauri-apps/cef-rs && cd cef-rs
git checkout cef-v154.2.0+154.0.28
cargo run -p export-cef-dir -- --force $HOME/.local/share/cef
```

The build reads CEF from `$CEF_PATH`, which defaults to `~/.local/share/cef`. Update the download whenever the pinned `cef` version changes.

## Build and run

```sh
scripts/bundle.sh                                       # release build; pass `debug` for a debug build
open build/Tiller.app
open build/Tiller.app --args -url https://example.com   # open a page at launch
```

The script builds the Rust crates and the Swift app, then assembles an ad-hoc signed `build/Tiller.app`. To keep the bundle small, it includes only the English and Chinese Chromium locales and omits SwiftShader, so there is no software rendering fallback when the GPU is unavailable.

## Driving the browser

Agents in the panel use Tiller's browser tools automatically. External agents and scripts can use the MCP server at `build/Tiller.app/Contents/MacOS/tiller_mcp`, or the `tiller` command-line tool, installed from Tiller > Install Command Line Tool…:

```sh
tiller new example.com      # open a tab and wait for the load
tiller read                 # page text with numbered links, buttons and fields
tiller click 3
tiller type 5 "hello" --submit
```

See [Browser tools](docs/tools.md) for every tool, command and option.

## Project layout

| Path | Description |
|---|---|
| `core/` | Rust static library linked into the app. Loads CEF and owns the browsers. |
| `helper/` | Rust binary for the CEF subprocesses. |
| `mcp/` | Rust crate with the browser tools, the `tiller_mcp` MCP server and the `tiller` command-line tool. |
| `app/` | SwiftPM package with the AppKit app. No Xcode project is required. |
| `scripts/bundle.sh` | Builds everything and assembles `build/Tiller.app`. |

## Documentation

| Guide | Covers |
|---|---|
| [Using the browser](docs/browser.md) | Tabs, find and zoom, address bar, history, saved passwords, Chrome import, profiles |
| [Agent panel](docs/agent.md) | Chats, image attachments, agent permissions, Codex isolation |
| [Browser tools](docs/tools.md) | MCP server, command-line tool, debug launch arguments |
| [Settings and data](docs/settings-and-data.md) | Settings, Chromium switches, data folder, environment variables, migrations |

## License

[MIT](LICENSE)
