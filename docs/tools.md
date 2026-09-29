# Browser tools

Tiller exposes one set of browser tools two ways: as an MCP server for agents and as the `tiller` command-line tool for shells and scripts.

## MCP server

`build/Tiller.app/Contents/MacOS/tiller_mcp` is a stdio MCP server. It talks to the running app over a Unix socket at `control.sock` in the profile's folder (only your user can open it). Tiller gives its agents that path in `TILLER_SOCKET`. Started any other way, it picks the profile named by `TILLER_PROFILE` (an id or a name), or else the one used last. `TILLER_SOCKET` overrides both.

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

`read_page` marks each element it lists with a `data-tiller-ref` attribute, which pages can see. Refs are renumbered on every call.

How it's wired: tab operations (`tabs.*`) are answered by the Swift app (`ControlServer.swift`). Everything that touches page content is a DevTools protocol command (`Runtime.evaluate`, `Input.dispatchMouseEvent`, `Input.insertText`, `Page.captureScreenshot`) that the Rust core sends straight to the tab (`core/src/ipc.rs`, `core/src/browser.rs`).

To try it without an agent:

```sh
open build/Tiller.app
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_page","arguments":{}}}' \
  | build/Tiller.app/Contents/MacOS/tiller_mcp
```

## Command-line tool

`tiller` runs the same browser tools from a shell, so scripts and agents outside Tiller, such as Claude Code with its Bash tool, can drive the browser. It ships at `build/Tiller.app/Contents/Helpers/tiller`, not next to `Tiller` in `Contents/MacOS`, where the two names would be one file on a case-insensitive disk. Tiller > Install Command Line Tool… links it as `~/.local/bin/tiller` and says if that folder isn't on your PATH. Install again after moving the app.

```sh
tiller tabs                        # * marks the selected tab
tiller new example.com             # opens a tab and waits for the load
tiller read                        # text, then [ref] lines for links, buttons and fields
tiller click 3
tiller type 5 "hello" --submit
tiller type --selector '#q' hi     # CSS selector instead of a ref
tiller screenshot -o page.jpg      # prints the path; a temp file without -o
tiller eval 'document.title'
tiller close 2
tiller --profile work tabs         # another profile's Tiller
```

| Command | Tool |
|---|---|
| `tabs` | `list_tabs` |
| `new [url]` | `new_tab` |
| `select <tab>` | `select_tab` |
| `close <tab>` | `close_tab` |
| `go <url>` | `navigate` |
| `read [--max-chars N]` | `read_page` |
| `click <ref>` | `click` |
| `type [ref] <text> [--append] [--submit]` | `type`, into the focused element when no ref or selector is given |
| `screenshot [-o file]` | `screenshot` |
| `eval <expression>` | `eval_js` |

`--profile <name>` controls that profile's Tiller instead of the one used last, and takes an id too. `--tab <id>` acts on another tab than the selected one, and `--json` prints the raw result instead of text. Options can come before or after the command. Refs are stored in the page, so a `read` in one call and a `click` in the next agree. Errors go to stderr with exit code 1, or 2 for bad arguments. Like `tiller_mcp`, it needs Tiller running and honors `TILLER_SOCKET` and `TILLER_PROFILE`.

The tool code is in `mcp/src/browser.rs`. `mcp/src/main.rs` wraps it as MCP and `mcp/src/bin/tiller.rs` as the CLI.

## Debug launch arguments

Debug builds (`scripts/bundle.sh debug`) accept extra launch arguments.

Three arguments test the Chrome import: `-chromeDataDir <folder>` reads a Chrome data folder other than the real one, `-chromeSafeStoragePassword <password>` uses that password instead of the keychain's, and `-importChrome YES` imports everything from the last-used profile at launch and logs the result. `-importChrome extensions,history` imports only those kinds (`cookies`, `passwords`, `history`, `settings`, `extensions`).

`-addExtension <path>` adds an unpacked extension folder, or a CRX file when the path ends in `.crx`, and logs the result. It loads at the next launch.

Three arguments test the agent panel without typing: `-agentPrompt "..."` opens the panel and sends that message, `-agentStopAfter <seconds>` presses Stop after that many seconds, and `-agentPasteImage YES` pastes the clipboard into the field twice before sending the prompt three seconds later.
