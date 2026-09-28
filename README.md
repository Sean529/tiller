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

Mini passes two switches to Chromium:

- `--use-mock-keychain`, so it never asks for the login keychain password. The cost is that cookies are encrypted with a fixed key instead of one kept in the keychain.
- `--disable-backgrounding-occluded-windows`, so a window covered by other apps still counts as visible. Otherwise Chromium drops the agent's mouse and key input while you work elsewhere. The cost is that a covered Mini window keeps drawing.

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

## Browser tools (MCP)

`build/Mini.app/Contents/MacOS/mini_mcp` is a stdio MCP server. It talks to the running app over a Unix socket at `~/Library/Application Support/Mini/control.sock` (only your user can open it). Set `MINI_SOCKET` to use another path.

| Tool | What it does |
|---|---|
| `list_tabs` | Id, URL, title, loading state and selection of every tab |
| `new_tab` | Opens a URL or search in a new tab and waits for it to load |
| `select_tab` | Brings a tab to the front |
| `close_tab` | Closes a tab (the page may still ask to confirm) |
| `navigate` | Loads a URL or search and waits for the load |
| `read_page` | Page text plus numbered links, buttons and fields |
| `click` | Real mouse click on an element's center by `ref` or CSS `selector` |
| `type` | Types into a field, replacing its text unless `append` is set, optionally presses Enter |
| `screenshot` | JPEG of the visible part of the tab |
| `eval_js` | Runs an expression in the page and returns the value as JSON |

Tools act on the selected tab unless given `tab_id`. `click`, `type` and `screenshot` select their tab first, because background tabs don't draw and Chromium drops their input.

`read_page` marks each element it lists with a `data-mini-ref` attribute, which pages can see. Refs are renumbered on every call.

How it's wired: tab operations (`tabs.*`) are answered by the Swift app (`ControlServer.swift`). Everything that touches page content is a DevTools protocol command (`Runtime.evaluate`, `Input.dispatchMouseEvent`, `Input.insertText`, `Page.captureScreenshot`) that the Rust core sends straight to the tab (`core/src/ipc.rs`, `core/src/browser.rs`).

To try it without an agent:

```sh
open build/Mini.app
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_page","arguments":{}}}' \
  | build/Mini.app/Contents/MacOS/mini_mcp
```

## Agent panel

Click the sparkles button at the right of the toolbar, or press Cmd+Shift+A, to open the agent panel. Pick Qoder CLI (the default) or Claude Code from the menu at its top. Enter sends, Option+Enter adds a line, the button next to the field stops a running turn, and the pencil button starts a new chat. Switching agents also starts a new chat.

Mini runs the CLI in print mode with stream-json on stdin and stdout, and keeps the process alive between messages so the conversation carries over. Each message is prefixed with the selected tab's id, title and URL. The panel shows the agent's text, streamed for Claude Code, and one line per tool call that turns into ✓ or ✗ when it finishes.

The agent gets Mini's browser tools and nothing else:

| | Qoder CLI | Claude Code |
|---|---|---|
| Built-in tools off | `--tools ""` and `--disallowed-tools ListAgents,SendMessage` | `--tools ""` |
| Only Mini's MCP server | `--mcp-config <file> --strict-mcp-config` | same |
| Mini's tools allowed without asking | `--allowed-tools mcp__mini --permission-mode dont_ask` | `--allowedTools mcp__mini --permission-mode dontAsk` |

The MCP config is written to `~/Library/Application Support/Mini/agent-mcp.json` and points at the `mini_mcp` inside the running app. The agent runs in the empty directory `~/Library/Application Support/Mini/agent`, with `--no-session-persistence`. Your user settings still load, so your hooks, model choice and user-level instructions (such as `~/.claude/CLAUDE.md`) apply.

Mini looks for the CLI in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.volta/bin`, `~/.npm-global/bin`, then asks a login shell. Shell functions and aliases are skipped, so wrappers defined in `.zshrc` don't run. To use another binary:

```sh
defaults write dev.sorrycc.mini agentPath.qodercli /path/to/qodercli
defaults write dev.sorrycc.mini agentPath.claude /path/to/claude
```

Debug builds take two launch arguments for testing without typing: `-agentPrompt "..."` opens the panel and sends that message, and `-agentStopAfter <seconds>` presses Stop after that many seconds.
