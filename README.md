# Mini

A small macOS browser: Chromium (via the Rust `cef` crate) inside a native Swift/AppKit shell, with an agent side panel that drives the browser through an MCP server.

## Layout

| Path | What it is |
|---|---|
| `core/` | Rust static library linked into the app. Loads CEF, owns the browsers and sets imported cookies. C header in `app/Sources/CMiniCore/mini_core.h`. |
| `helper/` | Rust binary for CEF subprocesses, copied into the five `Mini Helper*.app` bundles. |
| `mcp/` | Rust crate with the browser tools: the stdio MCP server `mini_mcp` that the agent CLI launches, and the `mini` command-line tool. |
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
open build/Mini.app --args -url https://example.com   # also open this page, selected, after any restored tabs
```

## Settings

Mini > Settings… (Cmd+,) has two panes. Changes are saved as you make them.

| Pane | Setting | Default | Takes effect |
|---|---|---|---|
| General | Homepage | `https://www.google.com/` | next launch if chosen below or there are no tabs to restore, and new tabs if chosen below |
| General | At launch, open: Tabs from Last Time or Homepage | Tabs from Last Time | next launch |
| General | New tabs open with: Blank Page or Homepage | Blank Page | next new tab |
| General | Search engine: Google, Bing, DuckDuckGo or Custom | Google | next search |
| General | Custom search URL, with `%s` for the query | empty | next search; Google is used while it isn't a valid http(s) URL with `%s` |
| Agent | New chats use: Qoder CLI, Claude Code or Codex | Qoder CLI | next new chat; same as the picker in the panel |
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
| Cmd+Shift+T | Reopen the last closed tab where it was |
| Cmd+Shift+] / Cmd+Shift+[, Ctrl+Tab / Ctrl+Shift+Tab | Next / previous tab |
| Cmd+1 to Cmd+8, Cmd+9 | That tab, last tab |
| Middle click on a tab | Close it |
| Drag a tab | Move it along the row |

Menu shortcuts take priority over the page, except Edit menu keys (Cmd+Z, Cmd+A, Cmd+C and so on), which the page gets first so editors in it keep their own handling.

Tabs share the row equally. When there are too many for their titles, they show only their icons, and past that the row scrolls to keep the selected tab in view.

Mini saves its open tabs as they change and opens them again at the next launch, however it quit: Cmd+Q, closing the window, closing the last tab, or a crash. Each tab reloads its last URL; back/forward history, scroll position and form contents aren't kept. A session of only blank tabs opens the homepage instead. Tabs are still saved when Settings says to open the homepage, so switching back restores the last run's tabs.

The last 25 closed tabs are kept for Cmd+Shift+T, across restarts too. Tabs that close because the window closed or Mini quit aren't among them, since they come back at launch. Clear History… forgets them.

Both are stored in `session.json` in the data folder, readable only by you.

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

## Find and zoom

| Shortcut | Action |
|---|---|
| Cmd+F | Find in page. The bar at the top right shows the match count; Return and Shift+Return step through matches, Escape closes it |
| Cmd+G / Cmd+Shift+G | Next / previous match |
| Cmd+= (or Cmd+Plus) / Cmd+- | Zoom in / out |
| Cmd+0 | Actual size |

Find shortcuts go to the menu before the page, like the other non-Edit shortcuts. Zoom follows Chromium's steps and is kept per site, and the address bar shows it when it isn't 100%. Click the percentage to go back to actual size. Switching tabs closes the find bar.

## Address bar and start page

The address bar shows just the site, such as `en.wikipedia.org`. Clicking it or pressing Cmd+L shows the full URL, selected, and Escape puts it back after you've typed over it. While a page loads, the bar fills with a faint tint from the left.

A blank tab shows your most visited sites as tiles, one per site, each opening that site's most visited page. Favicons for the tiles are kept in `history.sqlite` alongside history. With no history yet, it shows a hint to use the address bar.

## History

Mini keeps its own history in `history.sqlite` in its data folder. Chromium's History file can't be used: CEF has no API for it and holds it locked. A page is saved once it finishes loading, and again when its URL or title changes after that.

- Typing in the address bar lists matching pages. Up and Down move through the list, Return opens the highlighted page, Escape closes the list. When the best match's address starts with what you typed, it is highlighted from the start, so Return goes there instead of searching.
- The History menu lists the 15 most recent pages. History > Clear History… empties it, along with the start page's saved favicons and the recently closed tabs.

## Saved passwords

Passwords come from the Chrome import; Mini doesn't offer to save new ones. On a page with a saved login, a key button appears at the left of the address bar. Click it, or choose Edit > Fill Saved Password, to fill the username and password. With several logins for the site, a menu asks which. Logins match the page's exact origin (scheme, host and port).

Mini never fills on its own. The agent's tools can read anything on the page, so a password you fill can be read by the agent until the page navigates away.

Settings > Passwords lists the saved logins, with buttons to copy a password or remove logins.

Storage: `passwords.json` in the data folder, readable only by you. Sites and usernames are stored in the clear, as Chrome stores them, so Mini knows which pages have a login without unlocking anything. Each password is sealed with AES-GCM under a key kept in the login keychain as "Mini Saved Passwords". Mini is ad-hoc signed, so after a rebuild macOS may ask before the new binary can read that key.

## Data folder

Mini keeps its profile, history, passwords, open tabs and control socket in `~/Library/Application Support/Mini`. Set `MINI_DATA_DIR` to use another folder, for example to run a second Mini alongside the first. Unix socket paths are limited to 104 bytes, so for a long folder path also set `MINI_SOCKET` to a shorter socket path; the app and `mini_mcp` both read it.

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

## Command-line tool

`mini` runs the same browser tools from a shell, so scripts and agents outside Mini, such as Claude Code with its Bash tool, can drive the browser. It ships at `build/Mini.app/Contents/Helpers/mini`, not next to `Mini` in `Contents/MacOS`, where the two names would be one file on a case-insensitive disk. Mini > Install Command Line Tool… links it as `~/.local/bin/mini` and says if that folder isn't on your PATH. Install again after moving the app.

```sh
mini tabs                        # * marks the selected tab
mini new example.com             # opens a tab and waits for the load
mini read                        # text, then [ref] lines for links, buttons and fields
mini click 3
mini type 5 "hello" --submit
mini type --selector '#q' hi     # CSS selector instead of a ref
mini screenshot -o page.jpg      # prints the path; a temp file without -o
mini eval 'document.title'
mini close 2
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

`--tab <id>` acts on another tab than the selected one, and `--json` prints the raw result instead of text. Refs are stored in the page, so a `read` in one call and a `click` in the next agree. Errors go to stderr with exit code 1, or 2 for bad arguments. Like `mini_mcp`, it needs Mini running and honors `MINI_SOCKET`.

The tool code is in `mcp/src/browser.rs`. `mcp/src/main.rs` wraps it as MCP and `mcp/src/bin/mini.rs` as the CLI.

## Agent panel

Click the sparkles button at the right of the toolbar, or press Cmd+Shift+A, to open the agent panel. Pick Qoder CLI (the default), Claude Code or Codex from the menu at its top, or in Settings. A new chat offers a few prompts to start from. Enter sends, Option+Enter or Shift+Enter adds a line, Escape or the button in the field stops a running turn, and the pencil button starts a new chat. Switching agents also starts a new chat.

Mini runs Qoder CLI and Claude Code in print mode with stream-json on stdin and stdout, and Codex as `codex app-server`, which speaks JSON-RPC on stdin and stdout. The process stays alive between messages so the conversation carries over. Each message is prefixed with the selected tab's id, title and URL. The panel shows the agent's text, streamed for Claude Code and Codex, with its markdown headings, lists, quotes, code and links rendered. Each tool call gets a row with a spinner that turns into a check, or a cross with the error. The transcript follows new output unless you've scrolled up to read.

The agent gets Mini's browser tools and, apart from Codex's shell, nothing else:

| | Qoder CLI | Claude Code | Codex (in `thread/start`) |
|---|---|---|---|
| Built-in tools off | `--tools ""` and `--disallowed-tools ListAgents,SendMessage` | `--tools ""` | web search, apps, goals, sub-agents, image generation and memories off; the shell can't be removed, so it runs in a `read-only` sandbox |
| Only Mini's MCP server | `--mcp-config <file> --strict-mcp-config` | same | `mcp_servers.mini` in `config`, with Mini's own `CODEX_HOME` so your `config.toml` servers don't load |
| Mini's tools allowed without asking | `--allowed-tools mcp__mini --permission-mode dont_ask` | `--allowedTools mcp__mini --permission-mode dontAsk` | `default_tools_approval_mode = "approve"` on the server, `approvalPolicy: "never"` for everything else |

The MCP config is written to `~/Library/Application Support/Mini/agent-mcp.json` and points at the `mini_mcp` inside the running app. The agent runs in the empty directory `~/Library/Application Support/Mini/agent`, with `--no-session-persistence`. Your user settings still load, so your hooks, model choice and user-level instructions (such as `~/.claude/CLAUDE.md`) apply.

Codex is set apart more. It runs with `CODEX_HOME` set to `~/Library/Application Support/Mini/codex`, so your `~/.codex/config.toml`, its MCP servers, plugins, hooks and `AGENTS.md` don't load, and Codex uses its default model. That folder's `auth.json` is a link to `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`), so Codex uses your login and a token refresh updates the file you already have. If you aren't logged in, the panel asks you to run `codex login`. Skills in `~/.agents/skills` and system hooks in `/etc/codex` still load. Threads are ephemeral, and Mini declines any approval or question Codex sends, since the panel can't ask you. Current Codex models call tools from a script they write, and the panel still shows each of Mini's tools as its own row. The sandboxed shell can read files on your disk, and its commands show as `shell` rows.

Mini looks for the CLI in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.volta/bin`, `~/.npm-global/bin`, then asks a login shell. Shell functions and aliases are skipped, so wrappers defined in `.zshrc` don't run. To use another binary, set its path in Settings > Agent, which shows the one found automatically when the field is empty.

Debug builds take two launch arguments for testing without typing: `-agentPrompt "..."` opens the panel and sends that message, and `-agentStopAfter <seconds>` presses Stop after that many seconds.
