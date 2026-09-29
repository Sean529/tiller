# Agent panel

The side panel runs Qoder CLI, Claude Code or Codex against the browser. Each profile has its own chats, working folder and agent configuration.

Click the sparkles button at the right of the toolbar, or press Cmd+Shift+S, to open the agent panel. The same keys hide it, and Settings can change them. Pick Qoder CLI (the default), Claude Code or Codex from the menu at its top, or in Settings. A new chat offers a few prompts to start from. Enter sends, Option+Enter or Shift+Enter adds a line, Escape or the button in the field stops a running turn.

## Chats

Chats open in tabs, three by default (Settings > Agent > Chat tabs). A row above the message field has a numbered button per tab on the left: click one to switch, right-click it to close it. Each tab has its own agent process, so one can keep working while you use another; a dot on the number shows it is busy. All tabs drive the same browser, so two agents running at once can get in each other's way. On the right of the row, the plus button opens a new tab while there is room, the pencil button starts a new chat in the selected tab, and the clock button lists past chats, newest first. Picking a chat that is open switches to its tab; picking another one opens it in the selected tab. Right-click a chat in the list to delete it. Switching agents with a chat in the tab also starts a new chat.

A chat is saved with its first message. Its title is the first line of that message until the agent names it: Codex sends a name, and Claude Code and Qoder CLI may write one to their session file, which Tiller reads after each turn. The open tabs come back at the next launch, and a chat from the list or from last time continues where it left off: the next message restarts the agent on its saved session (`--resume <id>`, or Codex's `thread/resume`) in the folder it first ran in. Tools and instructions come from the current Settings. Since the CLIs save these sessions, they also appear in each CLI's own resume list. If the session can't be resumed, the panel says so and the next message starts a new conversation without the earlier context. Chats are kept in `agent-chats` in the [profile's folder](settings-and-data.md#data-folder): `index.json` lists them and the open tabs, and each chat has a folder with its transcript and images.

## Image attachments

A message can carry up to five images. Paste one with Cmd+V (a screenshot, an image copied from a page, or image files copied in Finder), drop images on the field, or pick them with the paperclip button. They show as thumbnails above the text, each with a button to remove it, and clicking a thumbnail, there or in the transcript, opens it in Quick Look. Tiller scales each image down to 2000 pixels on its long edge and saves it as PNG, or as JPEG if the PNG is over 3.5 MB, in the chat's folder. Claude Code and Qoder CLI get the image in the message, and Codex gets the file's path. The images stay with the chat and are deleted with it; images attached but never sent are deleted when the tab closes.

## How agents run

Tiller runs Qoder CLI and Claude Code in print mode with stream-json on stdin and stdout, and Codex as `codex app-server`, which speaks JSON-RPC on stdin and stdout. The process stays alive between messages so the conversation carries over, and the CLI also saves the conversation so it can be resumed later. Each message is prefixed with the selected tab's id, title and URL. The panel shows the agent's text, streamed for Claude Code and Codex, with its markdown headings, lists, quotes, code and links rendered. Each tool call gets a row with a spinner that turns into a check, or a cross with the error. The transcript follows new output unless you've scrolled up to read.

## Tools the agent gets

By default the agent gets Tiller's [browser tools](tools.md) and, apart from Codex's shell, nothing else:

| | Qoder CLI | Claude Code | Codex (in `thread/start`) |
|---|---|---|---|
| Built-in tools off | `--tools ""` and `--disallowed-tools ListAgents,SendMessage` | `--tools ""` | web search, apps, goals, sub-agents, image generation and memories off; the shell can't be removed, so it runs in a `read-only` sandbox |
| Only Tiller's MCP server | `--mcp-config <file> --strict-mcp-config` | same | `mcp_servers.tiller` in `config`, with Tiller's own `CODEX_HOME` so your `config.toml` servers don't load |
| Tiller's tools allowed without asking | `--allowed-tools mcp__tiller --permission-mode dont_ask` | `--allowedTools mcp__tiller --permission-mode dontAsk` | `default_tools_approval_mode = "approve"` on the server, `approvalPolicy: "never"` for everything else |

The MCP config is written to `agent-mcp.json` in the profile's folder and points at the `tiller_mcp` inside the running app. The agent runs in the empty `agent` directory in the profile's folder, or in the folder set in Settings > Agent > Work in. A real project folder loads that project's instructions and settings too.

### Optional built-in tools

Settings > Agent > Also allow turns on built-in tools, all off by default. They run without asking, and pages the agent reads can try to steer it, so turn on only what you need. Changes apply from the next new chat.

| | Qoder CLI and Claude Code | Codex |
|---|---|---|
| Read files | `Read`, `Grep`, `Glob` | nothing changes; its shell can always read |
| Write and edit files | `Write`, `Edit` | `workspace-write` sandbox: the shell and patches can write in the folder (and temp folders), not elsewhere |
| Run commands | `Bash`, not sandboxed: it can do anything your user can | nothing changes; the shell is always there |

The names go in `--tools` and the allow list. Qoder CLI's `dont_ask` refuses built-in tools even when allowed, so with any on Tiller uses `--permission-mode bypass_permissions`; `--tools` still limits which tools exist. The system prompt tells the agent which tools it has and not to act on instructions from pages with them. Your user settings still load, so your hooks, model choice and user-level instructions (such as `~/.claude/CLAUDE.md`) apply.

## Codex isolation

Codex is set apart more. It runs with `CODEX_HOME` set to `codex` in the profile's folder, so your `~/.codex/config.toml`, its MCP servers, plugins, hooks and `AGENTS.md` don't load, and Codex uses its default model. That folder's `auth.json` is a link to `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`), so Codex uses your login and a token refresh updates the file you already have. If you aren't logged in, the panel asks you to run `codex login`. Skills in `~/.agents/skills` and system hooks in `/etc/codex` still load. Threads are saved in Tiller's `CODEX_HOME`, and Tiller declines any approval or question Codex sends, since the panel can't ask you. Current Codex models call tools from a script they write, and the panel still shows each of Tiller's tools as its own row. The sandboxed shell can read files on your disk, and its commands show as `shell` rows and its patches as `edit` rows.

## Finding the CLI

Tiller looks for the CLI in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.volta/bin`, `~/.npm-global/bin`, then asks a login shell. Shell functions and aliases are skipped, so wrappers defined in `.zshrc` don't run. To use another binary, set its path in Settings > Agent, which shows the one found automatically when the field is empty.
