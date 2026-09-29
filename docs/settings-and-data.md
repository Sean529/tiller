# Settings and data

Tiller's settings, the switches it passes to Chromium, and where it stores data.

## Settings

Tiller > Settings… (Cmd+,) has five panes: General, Passwords, Extensions (see [Extensions](browser.md#extensions)), Agent and Profiles (see [Profiles](browser.md#profiles)). Changes are saved as you make them, and apply to the current profile only.

| Pane | Setting | Default | Takes effect |
|---|---|---|---|
| General | Homepage | `https://www.google.com/` | next launch if chosen below or there are no tabs to restore, and new tabs if chosen below |
| General | At launch, open: Tabs from Last Time or Homepage | Tabs from Last Time | next launch |
| General | New tabs open with: Blank Page or Homepage | Blank Page | next new tab |
| General | Show tabs: Along the Top or In a Sidebar | Along the Top | right away |
| General | Search engine: Google, Bing, DuckDuckGo or Custom | Google | next search |
| General | Custom search URL, with `%s` for the query | empty | next search; Google is used while it isn't a valid http(s) URL with `%s` |
| Agent | New chats use: Qoder CLI, Claude Code or Codex | Qoder CLI | next new chat; same as the picker in the panel |
| Agent | Chat tabs: how many chats the panel keeps open at once, 1 to 9 | 3 | right away; tabs already open stay |
| Agent | Show and hide shortcut: click, then press a combination with Cmd or Ctrl. Delete clears it; one already in a menu is refused | Cmd+Shift+S | right away |
| Agent | Path for each CLI | empty, meaning look it up | next new chat |
| Agent | Extra instructions, added after Tiller's system prompt | empty | next new chat |

Settings live in the profile's own user defaults, `dev.sorrycc.tiller.profile.<id>`. Window position and size stay in `dev.sorrycc.tiller`, shared by every profile. Agents opening tabs with `new_tab` always get a blank page when they pass no URL, whatever the new tab setting says.

## Chromium switches

Tiller passes these switches to Chromium:

- `--use-mock-keychain`, so it never asks for the login keychain password. The cost is that cookies are encrypted with a fixed key instead of one kept in the keychain.
- `--disable-backgrounding-occluded-windows`, so a window covered by other apps still counts as visible. Otherwise Chromium drops the agent's mouse and key input while you work elsewhere. The cost is that a covered Tiller window keeps drawing.
- With extensions on, `--load-extension=<folders>` for the profile's enabled [extensions](browser.md#extensions), and `--noerrdialogs`. Without it, an extension Chromium can't load asks for an error dialog, which hangs Tiller at launch. Chromium writes the error to `chrome_debug.log` in the profile's folder instead, and Settings > Extensions reads it from there. A folder whose path has a comma can't be passed, since Chromium splits the list on commas.

## Data folder

Tiller keeps its data in `~/Library/Application Support/Tiller`. Set `TILLER_DATA_DIR` to use another folder. Profiles opened from a Tiller started that way use the same folder.

| Path | What it is |
|---|---|
| `profiles.json` | Every profile's id, name and creation date, and the id of the one used last |
| `Profiles/<id>/` | One profile: Chromium's data, `history.sqlite`, `passwords.json`, `session.json`, `extensions.json`, `Extensions/`, `agent-chats/`, the agent's working folder and the control socket |
| `Profiles/<id>/extensions.json` | The profile's extensions: each one's folder, where it came from (a folder, a CRX file or Chrome), and whether it's on and pinned |
| `Profiles/<id>/Extensions/` | Extensions Tiller unpacked or copied, one folder each, named by id plus a random suffix so an update never overwrites files Chromium has loaded. Folders nothing uses any more are deleted at launch |

Unix socket paths are limited to 104 bytes, so for a long folder path set `TILLER_SOCKET` to a shorter socket path. The app and `tiller_mcp` both read it. It applies to one Tiller only: profiles opened from that Tiller don't get it, since two processes can't share a socket.

## Migrations

### From a single data folder to profiles

Before profiles, Tiller kept everything straight in the data folder. At its first launch with profiles, it moves all of it into `Profiles/default/` and moves the settings into that profile's user defaults (`ProfileMigration.swift`). If an older Tiller is running, it asks you to quit it and exits. As with the rename from Mini, saved chats are pointed at the new folder, but Claude Code and Qoder CLI keep sessions by folder path, so chats from before can't be continued.

### From Mini to Tiller

Tiller was previously named Mini. At its first launch it brings over Mini's data (`RenameMigration.swift`):

- It moves `~/Library/Application Support/Mini` to `Tiller`, unless `TILLER_DATA_DIR` is set or the `Tiller` folder already exists. If Mini is running, Tiller asks you to quit it and exits. Saved chats that ran in the old folder are pointed at the new one, but Claude Code and Qoder CLI keep sessions by folder path, so those chats can't be continued.
- It copies the `dev.sorrycc.mini` user defaults while `dev.sorrycc.tiller` has none.
- It removes the `~/.local/bin/mini` link to a `Mini.app`. Install `tiller` again from the Tiller menu.
- The first time it needs the password key, it copies "Mini Saved Passwords" in the keychain to "Tiller Saved Passwords", and macOS asks first.

Mini's defaults and keychain item are left in place. Full Disk Access and permission to control Finder belong to the bundle id, so grant them to Tiller again.
