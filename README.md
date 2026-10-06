# Conch - Multi-Server IRC Client for FFXI (Ashita v4)

Conch is an in-game IRC client addon for Final Fantasy XI. It connects to one or more IRC
servers and channels and prints traffic into your FFXI chat log, so you can keep up with your
community without leaving the game.

## Features

- **Multi-server, multi-channel**: any number of servers, each with its own channels, nickname,
  password, and TLS setting.
- **In-game integration**: messages appear in the FFXI chat log with server/channel indicators and
  per-channel colors.
- **Automatic login/logout handling**: connects when your character is logged in, and disconnects a
  configurable delay after you log out.
- **Auto-join and auto-reconnect**: joins your configured channels on connect, and reconnects
  (throttled) after a dropped connection.
- **TLS**: optional IRC-over-TLS on a per-server basis.
- **Server and channel passwords**: supports both IRC server (`PASS`) and channel (`+k`) passwords.
- **Status feedback**: connect/disconnect results, join failures, kicks, and the reason a
  connection was lost are reported in the chat log instead of failing silently.
- **Outgoing tags**: embed live character data (target, job, HP/MP, position) in messages you send.

## Installation

1. Copy the `Conch` folder into your Ashita v4 `addons` directory.
2. The `irce` (IRC engine) and `outgoing` (message tag expansion) modules are bundled in the folder.
3. Load it in game with `/addon load Conch`. A settings file is created on first run.

TLS support uses LuaSec, which ships with Ashita as `socket.ssl`; no extra install is needed.

## Configuration

### Settings file

Settings are a **Lua** file, not JSON:

```
<AshitaPath>/config/addons/Conch/defaults/settings.lua
```

Conch loads this file at startup and **rewrites it** whenever settings change (on join with a new
channel password, `/conch color`, `/conch save`, `/conch connect`, and on addon unload). Because the
file is regenerated, **any comments you add are lost on the next save** — keep that in mind if you
annotate it.

The file assigns into a table and returns it:

```lua
require('common');

local settings = T{ };

settings["servers"] = T{ };
settings["servers"]["libera"] = T{ };
settings["servers"]["libera"]["channels"] = T{ };
settings["servers"]["libera"]["channel_passwords"] = T{ };
settings["servers"]["libera"]["channel_colors"] = T{ };

-- Server
settings["servers"]["libera"]["server"] = "irc.libera.chat";
settings["servers"]["libera"]["port"] = 6697;
settings["servers"]["libera"]["use_ssl"] = true;
settings["servers"]["libera"]["channels"][1] = "#horizonxi";
settings["servers"]["libera"]["channel_colors"]["#horizonxi"] = 109;

-- Global
settings["nick_suffix"] = "|";
settings["default_chat_color"] = 109;
settings["chat_channel"] = 212;

return settings;
```

### Server fields (`settings["servers"]["<name>"]`)

- **`server`** (string, required): hostname or IP. Example: `"irc.libera.chat"`.
- **`port`** (number, required): IRC port. `6667` is plaintext, `6697` is the usual TLS port.
- **`use_ssl`** (boolean, optional): connect using TLS. Default `false`.
  - Pair with the server's TLS port. Pointing `use_ssl` at a plaintext port (or vice versa) will
    fail the handshake.
  - Certificate verification is disabled (self-signed certificates are accepted), matching the other
    bundled addons.
- **`server_password`** (string, optional): password sent to the IRC server (`PASS`) before
  registration, for password-protected servers. Separate from channel passwords.
- **`channels`** (array of strings, optional): channels to auto-join on connect. Include the `#`.
  Example: `["#horizonxi", "#ffxi"]`.
- **`channel_passwords`** (table, optional): channel name → channel key, used when auto-joining and
  when joining with a key. The key must match the channel string in `channels`
  (e.g. `settings["servers"]["libera"]["channel_passwords"]["#horizonxi"] = "secret";`).
- **`channel_colors`** (table, optional): channel name → FFXI chat color index (0–512). Channels
  without an entry use `default_chat_color`.
- **`nickname`** (string, optional): base nickname for this server. If unset, your FFXI character
  name is used. `nick_suffix` is always appended.
- **`display_server_in_chat`** (boolean, optional): overrides the global `display_server_in_chat` for
  this server. When unset, the global value applies.

### Global fields

- **`join_alerts`** (boolean, default `false`): announce when other users join a channel.
- **`quit_alerts`** (boolean, default `false`): announce when other users leave or are kicked.
- **`nickname_change_alerts`** (boolean, default `false`): announce when a user changes nickname.
- **`nick_suffix`** (string, default `"|"`): appended to your nickname to flag FFXI clients
  (character `PlayerName` becomes `PlayerName|`).
- **`poll_interval`** (number, default `0.5`): seconds between polling each server for incoming
  messages.
- **`connection_cooldown`** (number, default `10`): minimum seconds between connection attempts to a
  server. Also throttles automatic reconnects after a drop.
- **`disconnect_delay`** (number, default `180`): seconds your character may be logged out before
  Conch disconnects from IRC.
- **`default_chat_color`** (number, default `109`): FFXI color index for messages in channels with no
  `channel_colors` override.
- **`chat_channel`** (number, default `212`): FFXI chat channel that Conch writes to (`212` = Unity).
- **`default_server`** (string, optional): server used by `/conch msg <channel> <message>` when more
  than one server is configured. If unset and only one server exists, that server is used.
- **`display_server_in_chat`** (boolean, default `false`): whether channel-scoped messages are
  prefixed with the server name. `false` shows `[#channel]`; `true` shows `[server#channel]`. A
  per-server `display_server_in_chat` (see below) overrides this for that server.

## Commands

All commands start with `/conch`. Channel names without a leading `#` are prefixed automatically.
`<...>` is required, `[...]` is optional.

| Command | Description |
|---|---|
| `/conch` | Show usage help. |
| `/conch msg <channel> <message>` | Send to a channel on the default server. |
| `/conch msg <server> <channel> <message>` | Send to a channel on a specific server. Quotes in the message are preserved. |
| `/conch join <server> <channel> [channel_password]` | Join a channel. If a password is given it is saved to the config. |
| `/conch part <server> <channel> [message]` | Leave a channel (alias: `/conch leave`). |
| `/conch list <server> <channel>` | List users in a channel. |
| `/conch connect <server> [server_password]` | (Re)connect a server, optionally setting its server password (saved to config). |
| `/conch servers` | List configured servers, their status, channels, and whether a password/TLS is set. |
| `/conch save` | Write the currently joined channels back to the config file. |
| `/conch color <server> <channel> <color_number>` | Set a channel's FFXI color (0–512), saved to config. |

**Examples**

```
/conch msg #horizonxi Hello everyone!            (default server)
/conch msg libera #horizonxi Hello from FFXI!    (explicit server)
/conch join libera #secret sekrit          (join a +k channel with key "sekrit")
/conch part libera #horizonxi brb                (leave with a part message)
/conch color libera #horizonxi 71                (set channel color)
```

### Server selection for `/conch msg`

The first argument is treated as a server name if it matches a configured server; otherwise the
command uses the default-server form. Use the explicit `<server> <channel>` form when you have more
than one server configured and no `default_server` set.

## Outgoing tags

Messages you send are rewritten before they go out: certain `<tag>` placeholders are replaced with
values read live from the game at the moment of sending. The local echo shows the processed text, so
what you see is what was sent.

| Tag | Value |
|---|---|
| `<t>` | Current target |
| `<bt>` | Battle target |
| `<lastst>` | Last selected target |
| `<me>` | Your character name |
| `<job>` | Main job and level, plus sub job when set (e.g. `THF75/NIN37`) |
| `<hp>` / `<mp>` | Current/max HP or MP (e.g. `512/600`) |
| `<hpp>` / `<mpp>` | Percentage of HP or MP remaining (e.g. `85%`) |
| `<posxyz>` | Position and height as `(x, z, height)` |

Tags are case-insensitive. A tag whose value cannot be read right now (no target, character not
loaded, etc.) is passed through unchanged, so you can see what actually went out. Any newline is
flattened to a space so it cannot break the IRC line.

Example:

```
/conch msg #horizonxi <job> at <posxyz>, hp <hpp>
```

## Message format

Channel and private messages are prefixed with the channel, and optionally the server (controlled by
`display_server_in_chat`):

```
[#channel]<nickname> message              (channel, default)
[server#channel]<nickname> message        (channel, when display_server_in_chat = true)
[serverPM]<nickname> message              (private message)
```

For example, with the default setting: `[#horizonxi]<PlayerName> Hello everyone!`

Status and informational lines (connect results, join/part notices, errors, user lists) carry a
`Conch:` header and use the same channel prefix:

```
Conch: [#horizonxi] Successfully joined channel!
Conch: [#horizonxi] ~~ONLINE~~ PlayerName, SomeUser
```

A few diagnostic lines that are inherently about a single server (e.g. `[libera] Not connected to
server`) always name that server regardless of this setting.

## Connection behavior

- **On login**: Conch connects to every configured server and auto-joins the configured channels
  once the server confirms registration.
- **Channel membership**: a channel is only marked as joined after the server confirms the JOIN, so
  messaging a channel you are not actually in reports a notice rather than sending into the void.
- **On drop**: if the connection is lost, Conch reports the reason (server error text, incorrect
  server password, TLS handshake failure, socket error, …), clears its channel state, and reconnects
  after the cooldown.
- **On logout**: `disconnect_delay` seconds after your character logs out, Conch disconnects.
- **Failures are reported**: connection refusals, join errors (no such channel, invite only, banned,
  wrong channel key, channel full, too many channels, …), and kicks are all printed with the reason.

## Quality of Life

- Add the following to your default.txt for a channel you frequent to make it resemble a third linkshell, and to make typing in that channel less annoying:
```
/alias /l3 /conch msg libera #horizonxi
/alias /l3list /conch list libera #horizonxi
```

## Troubleshooting

### The addon does not connect

- Verify `server` and `port`, and that the port matches the mode: `6667` plaintext, `6697` TLS.
- If using `use_ssl`, make sure the server actually speaks TLS on that port — otherwise you will see
  `TLS handshake failed`.
- A firewall may be blocking the port.
- A refusal reason appears in chat; check it (e.g. `incorrect server password`, `banned`).

### Messages do not send

- Check connection status with `/conch servers`.
- Confirm you are actually joined: sending to a channel you are not in prints a notice.
- Channel names are auto-prefixed with `#`, but names must otherwise be correct.

### A password-protected channel will not join

- Set the key in `channel_passwords`, or join once with
  `/conch join <server> <channel> <key>` (which saves it).
- A wrong key reports `JOIN failed: Incorrect channel password`.

### Settings

- The settings file is **Lua**, at `config/addons/Conch/defaults/settings.lua`.
- Conch rewrites it on save, so hand-written comments are not preserved.
- After editing by hand, reload with `/addon reload Conch`.

### Nicknames

- If your nickname is taken, the server may assign a different one.
- Your nickname follows your character name unless a `nickname` is set for the server.
- `nick_suffix` is always appended.

## License

Provided as-is. Modify and distribute as needed.

## Credits

- Based on the `linkshell3` example addon by Melon.
- Uses the Lua IRC Engine (IRCe).
- Built for Final Fantasy XI on Ashita v4.