# Mini

A small macOS browser: Chromium (via the Rust `cef` crate) inside a native Swift/AppKit shell, with an agent side panel that drives the browser through an MCP server.

## Layout

| Path | What it is |
|---|---|
| `core/` | Rust static library linked into the app. Loads CEF, owns the browsers and sets imported cookies. C header in `app/Sources/CMiniCore/mini_core.h`. |
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
open build/Mini.app --args -url https://example.com   # start on another page, ignoring the homepage
```

## Settings

Mini > Settings… (Cmd+,) has two panes. Changes are saved as you make them.

| Pane | Setting | Default | Takes effect |
|---|---|---|---|
| General | Homepage | `https://www.google.com/` | next launch, and new tabs if chosen below |
| General | New tabs open with: Blank Page or Homepage | Blank Page | next new tab |
| General | Search engine: Google, Bing, DuckDuckGo or Custom | Google | next search |
| General | Custom search URL, with `%s` for the query | empty | next search; Google is used while it isn't a valid http(s) URL with `%s` |
| Agent | New chats use: Qoder CLI or Claude Code | Qoder CLI | next new chat; same as the picker in the panel |
| Agent | Path for each CLI | empty, meaning look it up | next new chat |
| Agent | Extra instructions, added after Mini's system prompt | empty | next new chat |

Settings live in the `dev.sorrycc.mini` user defaults. Agents opening tabs with `new_tab` always get a blank page when they pass no URL, whatever the new tab setting says.

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

## Import from Chrome

File > Import from Chrome… brings over data from one Chrome profile. Pick the profile and any of:

| Data | What happens |
|---|---|
| Cookies | Set through Chromium's cookie manager, replacing Mini's cookie with the same name, domain and path. Partitioned cookies (third-party embeds) are skipped because CEF can't set them, as are expired ones. |
| Saved passwords | Stored in Mini's password store (below). A saved login with the same site and username is replaced. Sites marked "never save" and non-web logins are skipped. |
| History | Merged into Mini's history. A page Mini already has keeps its title and takes the higher visit count and later visit. |
| Search engine and homepage | Google, Bing and DuckDuckGo map to Mini's engines; any other engine becomes a custom search URL. Chrome's startup page becomes Mini's homepage, or failing that its Home button page. |

Re-running the import is safe: nothing is duplicated.

Chrome encrypts cookies and passwords with a key in its "Chrome Safe Storage" keychain item, so macOS asks for your login password before Mini can read it. The import reads copies of Chrome's databases, which works while Chrome is running, but cookies Chrome changed in the last 30 seconds or so may not be on disk yet.

macOS may block Mini from reading Chrome's folder at all. The sheet then says so and has a button that opens Privacy & Security > Full Disk Access, where you can allow Mini.

Some sites tie a session to the browser it started in, so they may still ask you to sign in again.

## History

Mini keeps its own history in `history.sqlite` in its data folder. Chromium's History file can't be used: CEF has no API for it and holds it locked. A page is saved once it finishes loading, and again when its URL or title changes after that.

- Typing in the address bar lists matching pages. Up and Down move through the list, Return opens the highlighted page, Escape closes the list. When the best match's address starts with what you typed, it is highlighted from the start, so Return goes there instead of searching.
- The History menu lists the 15 most recent pages. History > Clear History… empties it.

## Saved passwords

Passwords come from the Chrome import; Mini doesn't offer to save new ones. On a page with a saved login, a key button appears at the left of the address bar. Click it, or choose Edit > Fill Saved Password, to fill the username and password. With several logins for the site, a menu asks which. Logins match the page's exact origin (scheme, host and port).

Mini never fills on its own. The agent's tools can read anything on the page, so a password you fill can be read by the agent until the page navigates away.

Settings > Passwords lists the saved logins, with buttons to copy a password or remove logins.

Storage: `passwords.json` in the data folder, readable only by you. Sites and usernames are stored in the clear, as Chrome stores them, so Mini knows which pages have a login without unlocking anything. Each password is sealed with AES-GCM under a key kept in the login keychain as "Mini Saved Passwords". Mini is ad-hoc signed, so after a rebuild macOS may ask before the new binary can read that key.

## Data folder

Mini keeps its profile, history, passwords and control socket in `~/Library/Application Support/Mini`. Set `MINI_DATA_DIR` to use another folder, for example to run a second Mini alongside the first. Unix socket paths are limited to 104 bytes, so for a long folder path also set `MINI_SOCKET` to a shorter socket path; the app and `mini_mcp` both read it.

Debug builds take three more launch arguments for testing the import: `-chromeDataDir <folder>` reads a Chrome data folder other than the real one, `-chromeSafeStoragePassword <password>` uses that password instead of the keychain's, and `-importChrome YES` imports everything from the last-used profile at launch and logs the result.

## Browser tools (MCP)

`build/Mini.app/Contents/MacOS/mini_mcp` is a stdio MCP server. It talks to the running app over a Unix socket at `control.sock` in the data folder (only your user can open it). Set `MINI_SOCKET` to use another path.

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

Click the sparkles button at the right of the toolbar, or press Cmd+Shift+A, to open the agent panel. Pick Qoder CLI (the default) or Claude Code from the menu at its top, or in Settings. Enter sends, Option+Enter adds a line, the button next to the field stops a running turn, and the pencil button starts a new chat. Switching agents also starts a new chat.

Mini runs the CLI in print mode with stream-json on stdin and stdout, and keeps the process alive between messages so the conversation carries over. Each message is prefixed with the selected tab's id, title and URL. The panel shows the agent's text, streamed for Claude Code, and one line per tool call that turns into ✓ or ✗ when it finishes.

The agent gets Mini's browser tools and nothing else:

| | Qoder CLI | Claude Code |
|---|---|---|
| Built-in tools off | `--tools ""` and `--disallowed-tools ListAgents,SendMessage` | `--tools ""` |
| Only Mini's MCP server | `--mcp-config <file> --strict-mcp-config` | same |
| Mini's tools allowed without asking | `--allowed-tools mcp__mini --permission-mode dont_ask` | `--allowedTools mcp__mini --permission-mode dontAsk` |

The MCP config is written to `~/Library/Application Support/Mini/agent-mcp.json` and points at the `mini_mcp` inside the running app. The agent runs in the empty directory `~/Library/Application Support/Mini/agent`, with `--no-session-persistence`. Your user settings still load, so your hooks, model choice and user-level instructions (such as `~/.claude/CLAUDE.md`) apply.

Mini looks for the CLI in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.volta/bin`, `~/.npm-global/bin`, then asks a login shell. Shell functions and aliases are skipped, so wrappers defined in `.zshrc` don't run. To use another binary, set its path in Settings > Agent, which shows the one found automatically when the field is empty.

Debug builds take two launch arguments for testing without typing: `-agentPrompt "..."` opens the panel and sends that message, and `-agentStopAfter <seconds>` presses Stop after that many seconds.
