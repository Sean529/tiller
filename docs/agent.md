# Agent panel

The side panel runs Qoder CLI, Claude Code or Codex against the browser. Each profile has its own chats, working folder and agent configuration.

Click the sparkles button at the right of the toolbar, or press Cmd+Shift+S, to open the agent panel. The same keys hide it, and Settings can change them. While the panel is hidden, a dot on the button shows that a chat is still working. Pick Qoder CLI (the default), Claude Code or Codex from the menu at its top, or in Settings. A new chat offers a few prompts to start from. Enter sends, Option+Enter or Shift+Enter adds a line, Escape or the button in the field stops a running turn.

## Chats

Chats open in tabs, three by default (Settings > Agent > Chat tabs). A row above the message field has a numbered button per tab on the left: click one to switch; the selected tab's number becomes a cross under the mouse, which closes it, and right-click closes any tab. Each tab has its own agent process, so one can keep working while you use another; a dot on the number shows it is busy. All tabs drive the same browser. The tools work in background tabs, and agents are told to open tabs of their own in the background, so agents running at once stay out of each other's way and yours unless two act on the same tab. On the right of the row, the plus button opens a new tab while there is room, the pencil button starts a new chat in the selected tab, and the clock button lists past chats, newest first. Picking a chat that is open switches to its tab; picking another one opens it in the selected tab. Right-click a chat in the list to delete it. While the agent has nothing to show yet, a Thinking row sits where its answer will start, and once the newest message has scrolled far out of view a round button over the transcript brings it back. Switching agents with a chat in the tab also starts a new chat.

A chat is saved with its first message. Its title is the first line of that message until the agent names it: Codex sends a name, and Claude Code and Qoder CLI may write one to their session file, which Tiller reads after each turn. The open tabs come back at the next launch, and a chat from the list or from last time continues where it left off: the next message restarts the agent on its saved session (`--resume <id>`, or Codex's `thread/resume`) in the folder it first ran in. Instructions come from the current Settings, and tools from the chat's own choice. Since the CLIs save these sessions, they also appear in each CLI's own resume list. If the session can't be resumed, the panel says so and the next message starts a new conversation without the earlier context. Chats are kept in `agent-chats` in the [profile's folder](settings-and-data.md#data-folder): `index.json` lists them and the open tabs, and each chat has a folder with its transcript and images.

## Image attachments

A message can carry up to five images. Paste one with Cmd+V (a screenshot, an image copied from a page, or image files copied in Finder), drop images on the field, or pick them with the paperclip button. They show as thumbnails above the text, each with a button to remove it, and clicking a thumbnail, there or in the transcript, opens it in Quick Look. Tiller scales each image down to 2000 pixels on its long edge and saves it as PNG, or as JPEG if the PNG is over 3.5 MB, in the chat's folder. Claude Code and Qoder CLI get the image in the message, and Codex gets the file's path. The images stay with the chat and are deleted with it; images attached but never sent are deleted when the tab closes.

## Skills

A skill is a folder with a `SKILL.md`: front matter with its `name` and `description`, then instructions the agent follows when it is called. Type `/` at the start of a message to pick one: a list above the field shows the skills whose names match what follows the `/`, with what each does and, for Tiller's own, a Tiller label. Up and Down move through it, Tab, Return or a click puts `/name ` in the field, and Escape closes it. Anything after the name goes to the skill as its arguments.

Before the agent starts, the list has Tiller's skill library and the skills the CLI finds itself in your folders: `~/.claude/skills` for Claude Code, `~/.agents/skills` and `~/.qoder/skills` for Qoder CLI, `~/.agents/skills` for Codex. Once the agent is running, the list is the skills it reported loading, plugins' included, described from their files where Tiller finds them.

A skill call has to come first in the message, so for Claude Code and Qoder CLI a message starting with `/` goes before the selected tab's details instead of after them. Codex gets the skill as its own input item, and the text calls it as `$name`, as Codex writes it.

### Tiller's skill library

Settings > Skills lists the profile's own skills, which every agent loads besides its own. Add Folder… copies a skill's folder, or every skill in the folders inside it. Add Archive… unpacks a `.zip` or `.skill` file, and Add from Git… clones a repository URL, `owner/repo` on GitHub, or a link to a folder on GitHub (`…/tree/<branch>/<path>`). Both take the skill at the top, or else every skill one level down, looking inside a `skills` folder or a single wrapping folder when there are none. A skill with the name of one already in the library replaces it and stays on or off. The checkbox turns a skill off without removing it; Show in Finder reveals its `SKILL.md`, and Remove deletes it. Agents read the library when they start, so changes apply from a chat's next start: a new chat, or the next message after the agent stopped.

The library is in `agent-skills` in the [profile's folder](settings-and-data.md#data-folder): `skills.json` lists the skills, `library/<name>` holds each one, and `exposed/skills` links the ones that are on. Claude Code and Qoder CLI get `exposed` with `--add-dir` and find the skills in its `.claude/skills` and `.qoder/skills`, both links to `exposed/skills`. Codex gets `exposed/skills` from `skills/extraRoots/set`.

### Creating skills from a chat

Ask the agent to create a skill, or to change or improve one, and it uses three of Tiller's tools: `list_skills`, `read_skill` and `save_skill`. They work with built-in tools off. `save_skill` writes `SKILL.md` and any other files to the library, and when it updates a skill, files it doesn't mention stay. Only library skills can be changed: the agent can read skills in your own folders, but saving one by that name is refused until you add its folder in Settings > Skills.

## How agents run

Tiller runs Qoder CLI and Claude Code in print mode with stream-json on stdin and stdout, and Codex as `codex app-server`, which speaks JSON-RPC on stdin and stdout. The process stays alive between messages so the conversation carries over, and the CLI also saves the conversation so it can be resumed later. Each message is prefixed with the selected tab's id, title and URL. The panel shows the agent's text, streamed for Claude Code and Codex, with its markdown headings, lists, quotes, links and tables rendered, and fenced code on a plate with its language and a copy button. Each tool call gets a row with a spinner that turns into a check, or a cross with the error. The transcript follows new output unless you've scrolled up to read. Web links in the agent's text open in a new Tiller tab, selected, or behind the current one with Cmd+click. Other links, such as `mailto:`, go to their apps.

## Tools the agent gets

By default the agent gets Tiller's [browser and skill tools](tools.md) and, apart from Codex's shell, nothing else:

| | Qoder CLI | Claude Code | Codex (in `thread/start`) |
|---|---|---|---|
| Built-in tools off | `--tools ""` and `--disallowed-tools ListAgents,SendMessage` | `--tools ""` | web search, apps, goals, sub-agents, image generation and memories off; the shell can't be removed, so it runs in a `read-only` sandbox |
| Only Tiller's MCP server | `--mcp-config <file> --strict-mcp-config` | same | `mcp_servers.tiller` in `config`, with Tiller's own `CODEX_HOME` so your `config.toml` servers don't load |
| Tiller's tools allowed without asking | `--allowed-tools mcp__tiller --permission-mode dont_ask` | `--allowedTools mcp__tiller --permission-mode dontAsk` | `default_tools_approval_mode = "approve"` on the server, `approvalPolicy: "never"` for everything else |

The MCP config is written to `agent-mcp.json` in the profile's folder and points at the `tiller_mcp` inside the running app. Claude Code and Qoder CLI also get `--add-dir` with the [skill library](#tillers-skill-library). The agent runs in the empty `agent` directory in the profile's folder, or in the folder set in Settings > Agent > Working folder. A real project folder loads that project's instructions and settings too.

### Optional built-in tools

Settings > Agent > Allowed tools turns on built-in tools, all off by default. They run without asking, and pages the agent reads can try to steer it, so turn on only what you need. Settings sets the tools a new chat starts with.

Each chat can change its own with the wrench button in the row above the message field, which turns blue when any is on. Its menu has the same three choices and applies only to that chat. The choice is saved with the chat, so it comes back with the open tabs and when the chat is opened from the list. The CLIs take their tools when they start, so a change stops the chat's agent and the next message resumes its session with the new tools. The menu is locked while a turn runs. For Codex, reading and running commands show as always on. Chats saved before this use the tools in Settings.

| | Qoder CLI and Claude Code | Codex |
|---|---|---|
| Read files | `Read`, `Grep`, `Glob` | nothing changes; its shell can always read |
| Write and edit files | `Write`, `Edit` | `workspace-write` sandbox: the shell and patches can write in the folder (and temp folders), not elsewhere |
| Run commands | `Bash`, not sandboxed: it can do anything your user can | nothing changes; the shell is always there |

The names go in `--tools` and the allow list. Qoder CLI's `dont_ask` refuses built-in tools even when allowed, so with any on Tiller uses `--permission-mode bypass_permissions`; `--tools` still limits which tools exist. The system prompt tells the agent which tools it has and not to act on instructions from pages with them. Your user settings still load, so your hooks, model choice and user-level instructions (such as `~/.claude/CLAUDE.md`) apply.

## Codex isolation

Codex is set apart more. It runs with `CODEX_HOME` set to `codex` in the profile's folder, so your `~/.codex/config.toml`, its MCP servers, plugins, hooks and `AGENTS.md` don't load, and Codex uses its default model. That folder's `auth.json` is a link to `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`), so Codex uses your login and a token refresh updates the file you already have. If you aren't logged in, the panel asks you to run `codex login`. Skills in `~/.agents/skills` and system hooks in `/etc/codex` still load. Threads are saved in Tiller's `CODEX_HOME`, and Tiller declines any approval or question Codex sends, since the panel can't ask you. Current Codex models call tools from a script they write, and the panel still shows each of Tiller's tools as its own row. The sandboxed shell can read files on your disk, and its commands show as `shell` rows and its patches as `edit` rows.

## Finding the CLI

Tiller looks for the CLI in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin`, `~/.volta/bin`, `~/.npm-global/bin`, then asks a login shell. Shell functions and aliases are skipped, so wrappers defined in `.zshrc` don't run. To use another binary, pick the CLI under Settings > Agent > Run and set its path there; the field shows the one found automatically while it is empty.
