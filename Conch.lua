addon.name = 'Conch'
addon.author = 'Melon'
addon.version = '1.0.2'
addon.description = 'Multi-server IRC client for FFXI Ashita v4'

-- TODO: Cleanup code so that channel names are lowercased everywhere
-- TODO: remove all the LLM comments . . . .
-- TODO: support for registered nicknames (both to identify the nickname and have the nickname persist rather than defaulting to player name)

require('common');
local chat = require('chat');
local IRCe = require("irce")
local socket = require("socket")
local settings = require('settings');
local outgoing = require('outgoing');

-- TLS parameters for servers configured with use_ssl. LuaSec (bundled with Ashita as
-- socket.ssl) is required lazily in connect() so plaintext users don't depend on it.
-- verify = 'none' matches the other addons here: IRC TLS is frequently self-signed and
-- shipping a CA bundle is more trouble than it's worth.
local SSL_PARAMS = {
    mode     = 'client',
    protocol = 'any',
    options  = { 'all', 'no_sslv2', 'no_sslv3' },
    verify   = 'none',
}
local SSL_HANDSHAKE_TIMEOUT = 5 -- Seconds to allow for the TLS handshake (blocking)

local default_settings = T{
    servers = {
    },
    join_alerts = false,
    quit_alerts = false,
    nickname_change_alerts = false,
    nick_suffix = '|', -- Indicates at a glance who is on an xi client
    poll_interval = 0.5, -- Seconds between polling each server for messagesw
    connection_cooldown = 10, -- Seconds between connection attempts per server d
    disconnect_delay = 180, -- Seconds player must be absent before disconnecting 
    default_chat_color = 109, -- FFXI color index for messages when channel has no override
    chat_channel = 212, -- chat channel used for output. 212 is unity.
    display_server_in_chat = false -- Prefix channel messages with the server name ([server#channel])
}

local conch = T{
    settings = settings.load(default_settings),
    servers = T{}, -- Will store server connection objects
}

if conch.settings.poll_interval == nil then conch.settings.poll_interval = 0.5 end
if conch.settings.connection_cooldown == nil then conch.settings.connection_cooldown = 10 end
if conch.settings.disconnect_delay == nil then conch.settings.disconnect_delay = 180 end
if conch.settings.default_chat_color == nil then conch.settings.default_chat_color = 109 end
if conch.settings.display_server_in_chat == nil then conch.settings.display_server_in_chat = false end
-- Time helpers: use socket.gettime() for fractional-second resolution (all times in seconds)
local function time_now()
    return socket.gettime()
end

local NICK = GetPlayerEntity() and GetPlayerEntity().Name or nil
local player_absent_since = nil -- First time GetPlayerEntity() was nil (logged out); nil when logged in

-- Server connection structure
local ServerConnection = {}
ServerConnection.__index = ServerConnection

function ServerConnection:new(server_name, server_config)
    local obj = setmetatable({}, ServerConnection)
    obj.server_name = server_name
    obj.server_config = server_config
    obj.connected = false
    obj.client = nil
    obj.irc = nil
    obj.nickname = nil
    obj.channels = T{} -- Track which channels we're in
    obj.awaiting_pong = false
    obj.server_error_reason = nil -- Last IRC-level error (ERROR / 464 / 465) seen before a drop
    obj.last_check_time = time_now() - (conch.settings.poll_interval or 0.5) - 1
    obj.last_connection_attempt = 0 -- Timestamp of last connection attempt
    obj.timeout = conch.settings.poll_interval or 0.5 -- Seconds between polls (fractional)
    
    -- Initialize IRC object
    obj.irc = IRCe.new()
    assert(obj.irc:load_module(require("irce.modules.base")))
    assert(obj.irc:load_module(require("irce.modules.message")))
    assert(obj.irc:load_module(require("irce.modules.channel")))
    
    -- Set up send function
    obj.client = socket.tcp()
    obj.client:settimeout(1)
    obj.irc:set_send_func(function(self, message)
        return obj.client:send(message)
    end)
    
    -- Set up callbacks
    obj:setup_callbacks()
    
    return obj
end


-- Utility functions
local function get_channel_color(server_name, channel)
    local server_config = conch.settings.servers and conch.settings.servers[server_name]
    if not server_config or not server_config.channel_colors then
        return conch.settings.default_chat_color
    end
    if channel and server_config.channel_colors[string.lower(channel)] ~= nil then
        return server_config.channel_colors[string.lower(channel)]
    end
    return conch.settings.default_chat_color
end

local function format_nickname(nick)
    local nick_suffix = conch.settings.nick_suffix
    if string.len(nick) >= string.len(nick_suffix)
        and string.sub(nick, -string.len(nick_suffix)) == nick_suffix then
        return string.sub(nick, 1, string.len(nick) - string.len(nick_suffix))
    else
        return nick
    end
end

-- Whether channel-scoped messages should name the server (`[server#channel]`) or not
-- (`[#channel]`). A server-level `display_server_in_chat` overrides the global setting.
local function should_display_server(server_name)
    if server_name then
        local server_config = conch.settings.servers and conch.settings.servers[server_name]
        if server_config and server_config.display_server_in_chat ~= nil then
            return server_config.display_server_in_chat and true or false
        end
    end
    return conch.settings.display_server_in_chat and true or false
end

-- Build the `[server#channel]` / `[#channel]` prefix for channel-scoped messages.
local function channel_prefix(server_name, channel)
    if should_display_server(server_name) then
        return ("[%s%s]"):format(server_name, channel)
    end
    return ("[%s]"):format(channel)
end

-- Single entry point for chat: message (required), color (optional), server_name, (optional) channel, (optional) sender_name (optional).
-- When server_name, channel, and sender_name are given, formats as [server#channel]<sender> message and uses channel color if color is nil.
local function print_message(message, server_name, channel, sender_name)
    if not message then return end
    local body
    local default_color = conch.settings.default_chat_color
    local c
    local line = ''
    if sender_name then
        body = ("%s<%s> %s"):format(channel_prefix(server_name, channel), format_nickname(sender_name), message)
        c = color or get_channel_color(server_name, channel)
    elseif server_name and channel then
        body = ("%s %s"):format(channel_prefix(server_name, channel), message)
        c = color or get_channel_color(server_name, channel)
        line = chat.header(addon.name)
    else
        body = message
        c = color or (conch.settings.default_chat_color)
        line = chat.header(addon.name)
    end
    local line = line .. chat.color1(c, body) -- color1 uses the non-erroneous 0x1E colors
    AshitaCore:GetChatManager():AddChatMessage(conch.settings.chat_channel, false, line)
end

local function list_users(server_name, channel, users)
    local onlines = '~~ONLINE~~ '
    for i, nick in ipairs(users) do
        if i > 1 then
            onlines = onlines .. ', '
        end
        onlines = onlines .. format_nickname(nick)
    end
    print_message(onlines, server_name, channel)
end

-- Remove a channel from a server connection's tracking, regardless of case.
local function remove_channel(server_conn, channel)
    if not channel then return end
    if server_conn.channels[channel] ~= nil then
        server_conn.channels[channel] = nil
    end
    local ch_lower = string.lower(channel)
    for ch, _ in pairs(server_conn.channels) do
        if string.lower(ch) == ch_lower then
            server_conn.channels[ch] = nil
        end
    end
end

-- Initialize server connections
local function initialize_servers()
    for server_name, server_config in pairs(conch.settings.servers) do
        conch.servers[server_name] = ServerConnection:new(server_name, server_config)
    end
end

function ServerConnection:setup_callbacks()
    local server_name = self.server_name
    local server_config = self.server_config
    local server_conn = self
    
    -- Raw callback (for debugging)
    self.irc:set_callback(IRCe.RAW, function(self, send, message)
        --Uncomment for debugging
        --print(("%s %s"):format(send and ">>>" or "<<<", message))
    end)
    
    -- CTCP VERSION reply
    self.irc:set_callback("CTCP", function(self, sender, origin, command, params, pm)
        if command == "VERSION" then
            assert(self:CTCP_REPLY(origin, "VERSION", "Conch IRC Client - FFXI Ashita v4"))
        end
    end)
    
    -- On successful connection (001), auto-join all channels from config
    self.irc:set_callback("001", function(self, ...)
        server_conn.server_error_reason = nil
        print_message(("[%s] Successfully connected to %s:%d"):format(server_name, server_config.server, server_config.port))
        local channel_passwords = server_config.channel_passwords or {}
        local channels = server_config.channels or {}
        for _, channel in ipairs(channels) do
            local channel_password = channel_passwords[channel]
            -- Membership is only recorded once the server confirms the JOIN (see JOIN callback).
            assert(self:JOIN(channel, channel_password))
        end
    end)
    
    -- Handle PRIVMSG (channel and private messages)
    self.irc:set_callback("PRIVMSG", function(self, sender, origin, message, pm)
        if pm then
            -- Private message
            print_message(message, server_name, "PM", sender[1])
        else
            -- Channel message
            print_message(message, server_name, origin, sender[1])
        end
    end)
    
    -- Handle NAMES (channel user list)
    self.irc:set_callback("NAMES", function(self, sender, channel, list, kind, message)
        if not list then
            print_message(("[%s] No channel called %s"):format(server_name, channel))
        else
            list_users(server_name, channel, list)
        end
    end)
    
    -- Handle NICK changes
    self.irc:set_callback("NICK", function(self, sender, new_nick)
        local old_nick = sender[1]
        if conch.settings.nickname_change_alerts then
            print_message(("[%s] %s is now %s."):format(server_name, format_nickname(old_nick), format_nickname(new_nick)))
        end
    end)
    
    -- Handle JOIN
    -- The IRC engine always passes sender as a table ({type=..., nick, ...}).
    -- Our own join is detected by matching the sender nick against our nickname.
    self.irc:set_callback("JOIN", function(self, sender, channel)
        local nick = (type(sender) == "table") and sender[1] or nil
        if nick and server_conn.nickname and string.lower(nick) == string.lower(server_conn.nickname) then
            -- The server confirmed our join
            server_conn.channels[channel] = true
            print_message("Successfully joined channel!", server_name, channel)
        elseif nick and conch.settings.join_alerts then
            -- Another user joined
            print_message(("%s has joined the channel!"):format(format_nickname(nick)), server_name, channel)
        end
    end)
    
    -- Handle PART
    self.irc:set_callback("PART", function(self, sender, channel, part_message)
        -- When we part, sender is a table with our nickname. When others part, sender is also a table.
        if type(sender) == "table" then
            local sender_nick = sender[1]
            if sender_nick == server_conn.nickname then
                -- We successfully left the channel
                print_message("Successfully left channel",server_name, channel)
                remove_channel(server_conn, channel)
            elseif conch.settings.quit_alerts then
                -- Another user left
                print_message(("%s has left the channel."):format(format_nickname(sender_nick)), server_name, channel)
            end
        end
    end)

    -- Handle KICK (a user was removed from a channel; notify when it's us)
    -- Channel module returns (sender, channel, user, kick_message).
    self.irc:set_callback("KICK", function(self, sender, channel, user, kick_message)
        if not user then return end
        local kicker = (type(sender) == "table") and sender[1] or "someone"
        if server_conn.nickname and string.lower(user) == string.lower(server_conn.nickname) then
            -- We were kicked: we are no longer in the channel
            remove_channel(server_conn, channel)
            local reason = (kick_message and kick_message ~= "") and (": " .. kick_message) or ""
            print_message(("Kicked from channel by %s%s"):format(format_nickname(kicker), reason), server_name, channel)
        elseif conch.settings.quit_alerts then
            -- Another user was kicked
            print_message(("%s was kicked from the channel."):format(format_nickname(user)), server_name, channel)
        end
    end)
    
    -- Handle QUIT
    self.irc:set_callback("QUIT", function(self, sender, params)
        if type(sender) == "table" and sender[1] ~= server_conn.nickname then
            if conch.settings.quit_alerts then
                print_message(("[%s] %s has left the server."):format(server_name, format_nickname(sender[1])))
            end
        end
    end)
    
    -- JOIN failure numerics: params are (our_nick, channel, trailing_message)
    local function join_error_msg(code, params)
        local channel = (type(params) == "table" and params[2]) or "?"
        local trailing = (type(params) == "table" and params[3]) or ""
        local reason = ({
            ["403"] = "No such channel",
            ["405"] = "You have joined too many channels",
            ["471"] = "Channel is full",
            ["473"] = "Invite only",
            ["474"] = "Banned from channel",
            ["475"] = "Incorrect channel password",
            ["476"] = "Invalid channel name",
            ["437"] = (trailing ~= "" and trailing) or "Unavailable (e.g. need uniq)",
        })[code] or ("Join failed: " .. (trailing ~= "" and trailing or code))
        print_message(("JOIN failed: %s"):format(reason), server_name, channel)
        if channel and channel ~= "?" then
            remove_channel(server_conn, channel)
        end
    end
    self.irc:set_callback("403", function(self, sender, params) join_error_msg("403", params) end)
    self.irc:set_callback("405", function(self, sender, params) join_error_msg("405", params) end)
    self.irc:set_callback("471", function(self, sender, params) join_error_msg("471", params) end)
    self.irc:set_callback("473", function(self, sender, params) join_error_msg("473", params) end)
    self.irc:set_callback("474", function(self, sender, params) join_error_msg("474", params) end)
    self.irc:set_callback("475", function(self, sender, params) join_error_msg("475", params) end)
    self.irc:set_callback("476", function(self, sender, params) join_error_msg("476", params) end)
    -- Other numeric errors that might be join-related (e.g. 437); show server message
    self.irc:set_callback("437", function(self, sender, params) join_error_msg("437", params) end)

    -- Server-initiated refusal / disconnect. These are recorded here and reported by
    -- handle_disconnect when the socket actually closes, so the user learns *why*.
    local function note_server_error(text)
        server_conn.server_error_reason = text
    end
    self.irc:set_callback("ERROR", function(self, sender, params)
        local msg = (type(params) == "table" and params[1]) or "server closed the connection"
        note_server_error(msg)
    end)
    -- 464 = password incorrect, 465 = banned; both usually precede a server-side close.
    self.irc:set_callback("464", function(self, sender, params) note_server_error("incorrect server password") end)
    self.irc:set_callback("465", function(self, sender, params) note_server_error("you are banned from this server") end)
end

function ServerConnection:update_nickname()
    local player_name = GetPlayerEntity() and GetPlayerEntity().Name or "Player"
    local nick = conch.settings.servers[self.server_name].nickname or player_name
    self.nickname = nick .. conch.settings.nick_suffix
    if self.irc then
        self.irc:NICK(self.nickname)
    end
end

function ServerConnection:connect()
    if self.connected then
        return
    end
    
    -- Check if we need to wait before attempting another connection
    local current_time = time_now()
    local time_since_last_attempt = current_time - self.last_connection_attempt
    local cooldown = conch.settings.connection_cooldown or 10
    if self.last_connection_attempt > 0 and time_since_last_attempt < cooldown then
        -- Still in cooldown period, don't attempt connection
        return false
    end
    
    -- Update last attempt time
    self.last_connection_attempt = current_time
    self.server_error_reason = nil

    self.client = socket.tcp()
    self.client:settimeout(1)
    local server_conn = self
    self.irc:set_send_func(function(_, message)
        -- Reference the current socket dynamically: with TLS enabled, self.client is
        -- replaced by the wrapped SSL object after the handshake.
        if server_conn.client then
            return server_conn.client:send(message)
        end
    end)

    local password_info = ""
    if self.server_config.server_password and self.server_config.server_password ~= "" then
        password_info = " (with server password)"
    end
    if self.server_config.use_ssl then
        password_info = password_info .. " (TLS)"
    end
    print_message(("[%s] Connecting to %s:%d%s..."):format(self.server_name, self.server_config.server, self.server_config.port, password_info))
    local line, err = self.client:connect(self.server_config.server, self.server_config.port, self.timeout)

    if line then
        self.connected = true
        -- Wrap the socket in TLS before anything is sent, if this server requests it.
        if self.server_config.use_ssl then
            local ssl_ok, ssl = pcall(require, 'socket.ssl')
            if not ssl_ok then
                self.connected = false
                self.client:close()
                print_message(("[%s] TLS unavailable: %s"):format(self.server_name, tostring(ssl)))
                return false
            end
            local ssock, werr = ssl.wrap(self.client, SSL_PARAMS)
            if not ssock then
                self.connected = false
                self.client:close()
                print_message(("[%s] TLS error: %s"):format(self.server_name, tostring(werr)))
                return false
            end
            self.client = ssock
            if type(ssock.sni) == 'function' then
                pcall(function() ssock:sni(self.server_config.server) end)
            end
            ssock:settimeout(SSL_HANDSHAKE_TIMEOUT)
            local hok, herr = ssock:dohandshake()
            if not hok then
                self.connected = false
                ssock:close()
                print_message(("[%s] TLS handshake failed: %s"):format(self.server_name, tostring(herr)))
                return false
            end
        end
        -- Send server password first if configured (must be before NICK and USER)
        if self.server_config.server_password and self.server_config.server_password ~= "" then
            self.irc:send_raw("PASS " .. self.server_config.server_password)
        end
        
        self:update_nickname()
        self.irc:USER(self.nickname, 'conch')
        -- Use non-blocking receive so we never block the game thread (poll interval controls how often we call receive)
        self.client:settimeout(0)
        -- Reset connection attempt time on successful connection
        self.last_connection_attempt = 0
        return true
    else
        self.connected = false
        self.client:close()
        local errmsg = err or "unknown error"
        print_message(("[%s] Connection failed: %s"):format(self.server_name, errmsg))
        return false
    end
end

function ServerConnection:disconnect()
    if self.connected and self.irc then
        self.irc:QUIT(("[%s] Disconnecting from %s:%d"):format(self.server_name, self.server_config.server, self.server_config.port))
    end
    if self.client then
        self.client:close()
    end
    self.connected = false
    -- Reset connection attempt time on disconnect so we can reconnect immediately if needed
    self.last_connection_attempt = 0
end

-- Called when the connection is lost unexpectedly (server closed the socket, network drop,
-- server-side refusal, etc.). Reports the reason and lets the main loop reconnect.
function ServerConnection:handle_disconnect(reason)
    if not self.connected then
        return
    end
    self.connected = false
    self.channels = T{} -- Stale membership is worse than none: we no longer know what we're in
    if self.client then
        self.client:close()
    end
    -- Throttle the automatic reconnect via the existing cooldown.
    self.last_connection_attempt = time_now()
    local why = self.server_error_reason or reason or "unknown"
    self.server_error_reason = nil
    print_message(("[%s] Connection lost: %s"):format(self.server_name, why))
end

function ServerConnection:process(skip_wait)
    if not self.connected then
        return
    end
    
    local current_time = time_now()
    local check_delta = current_time - self.last_check_time
    
    -- Update nickname if player name changed
    if GetPlayerEntity() then
        local player_name = GetPlayerEntity().Name
        local expected_nick = (conch.settings.servers[self.server_name].nickname or player_name) .. conch.settings.nick_suffix
        if self.nickname ~= expected_nick then
            self:update_nickname()
        end
    end
    
    -- Process incoming messages (poll every self.timeout seconds)
    if skip_wait or (check_delta >= self.timeout) then
        self.last_check_time = current_time
        local line, err = self.client:receive()
        if line then
            self.irc:process(line)
            return true
        elseif err and err ~= "timeout" and err ~= "wantread" and err ~= "wantwrite" then
            -- "timeout"/"wantread"/"wantwrite" just mean no data this poll (the latter two are
            -- how LuaSec reports a would-block on a non-blocking TLS socket). Any other error
            -- ("closed", reset, etc.) means the connection is gone.
            self:handle_disconnect(err)
        end
    end
    return false
end

local function is_in_channel(server_conn, channel)
    if server_conn.channels[channel] then return true end
    local ch_lower = string.lower(channel)
    for ch, _ in pairs(server_conn.channels) do
        if string.lower(ch) == ch_lower then return true end
    end
    return 
end

function ServerConnection:send_message(channel, message)
    if not channel or channel == "" then
        print_message(("[%s] No channel specified"):format(self.server_name))
        return false
    end
    if not self.connected then
        print_message(("[%s] Not connected to server"):format(self.server_name))
        return false
    end
    
    if not is_in_channel(self, channel) then
        print_message(("[%s] You must join %s before sending messages to it."):format(self.server_name, channel))
        return false
    end
    
    self.irc:send("PRIVMSG", channel, message)
    print_message(message, self.server_name, channel, self.nickname)
    return true
end

function ServerConnection:join_channel(channel, channel_password)
    if not self.connected then
        print_message(("[%s] Not connected to server"):format(self.server_name))
        return false
    end
    
    if self.irc:JOIN(channel, channel_password) then
        -- Membership is recorded by the JOIN callback once the server confirms it.
        local pwd_info = (channel_password and channel_password ~= "") and " (with channel password)" or ""
        print_message(("Joining channel %s..."):format(pwd_info), self.server_name, channel)
        return true
    end
    return false
end

function ServerConnection:part_channel(channel, part_message)
    if not self.connected then
        print_message(("[%s] Not connected to server"):format(self.server_name))
        return false
    end
    
    if not self.channels[channel] then
        print_message("Not in channel.", self.server_name, channel)
        return false
    end
    
    if self.irc:PART(channel, part_message) then
        print_message("Leaving channel %s...", self.server_name, channel)
        -- Note: The channel will be removed from self.channels when we receive the PART confirmation
        return true
    end
    return false
end

-- Main update loop: connect when character is logged in (GetPlayerEntity() non-nil),
-- disconnect 3 minutes after character is logged out (GetPlayerEntity() nil).
skip_wait = false
ashita.events.register('d3d_present', 'conch_update', function()
    if not GetPlayerEntity() then
        -- Character logged out
        if not player_absent_since then
            player_absent_since = time_now()
        end
        local disconnect_delay = conch.settings.disconnect_delay or 180
        if (time_now() - player_absent_since) >= disconnect_delay then
            for _, server_conn in pairs(conch.servers) do
                if server_conn.connected then
                    server_conn:disconnect()
                end
            end
            player_absent_since = nil
        end
        return
    end
    -- Character logged in
    player_absent_since = nil
    for server_name, server_conn in pairs(conch.servers) do
        if not server_conn.connected then
            server_conn:connect()
        else
            skip_wait = server_conn:process(skip_wait)
        end
    end
end)

-- Everything in the raw command line after its first `n` whitespace-separated
-- tokens, verbatim.
--
-- e.command holds the line as typed, but e.command:args() (sugar's string.args)
-- strips quote marks and merges quoted runs, so rebuilding a message from it
-- loses text the user typed:  /conch msg srv #chan hi "hello"  arrives as
-- `hi hello`.  Slicing the raw line instead keeps the quotes.  Counting tokens
-- rather than matching text keeps this working whatever case or spelling was
-- used for the server and channel names.
local function message_after_args(raw, n)
    local length, position = #raw, 1
    local function is_space(byte)
        return byte == 32 or byte == 9 or byte == 10 or byte == 13
    end
    for _ = 1, n do
        while position <= length and is_space(raw:byte(position)) do position = position + 1 end
        while position <= length and not is_space(raw:byte(position)) do position = position + 1 end
    end
    while position <= length and is_space(raw:byte(position)) do position = position + 1 end
    return raw:sub(position)
end

-- Command handler
ashita.events.register('command', 'conch_command', function(e)
    local args = e.command:args()
    
    if #args == 0 or args[1] ~= '/conch' then
        return
    end
    
    e.blocked = true
    
    if #args < 2 then
        print_message("Addon usage:")
        print_message("  /conch msg <channel> <message> - Send message to channel on default server")
        print_message("  /conch msg <server> <channel> <message> - Send message to channel on specific server")
        print_message("  /conch join <server> <channel> [channel_password] - Join a channel (optional channel password)")
        print_message("  /conch part <server> <channel> [message] - Leave a channel on a server")
        print_message("  /conch leave <server> <channel> [message] - Leave a channel on a server (alias for part)")
        print_message("  /conch list <server> <channel> - List users in a channel")
        print_message("  /conch connect <server> [server_password] - Connect to a server (with optional server password)")
        print_message("  /conch servers - List all configured servers")
        print_message("  /conch save - Update settings file with current server and channel connections")
        print_message("  /conch color <server> <channel> <color_number> - Set message color for a channel (0-512)")
        return
    end
    
    local command = args[2]:lower()
    
    if command == 'msg' then
        -- Two accepted forms:
        --   /conch msg <channel> <message>            (channel on the default server)
        --   /conch msg <server> <channel> <message>   (channel on a specific server)
        if #args < 4 then
            print_message("Usage: /conch msg <channel> <message>  or  /conch msg <server> <channel> <message>")
            return
        end

        local server_name, channel, message

        if conch.settings.servers[args[3]] ~= nil then
            -- Explicit server form.
            if #args < 5 then
                print_message("Usage: /conch msg <server> <channel> <message>")
                return
            end
            server_name = args[3]
            channel = args[4]
            -- Slice the message out of the raw line so quotes survive.
            message = message_after_args(e.command, 4)
        else
            -- Default-server form; args[3] is the channel.
            channel = args[3]
            message = message_after_args(e.command, 3)
            -- Resolve the default server: explicit setting, else the only configured server.
            if conch.settings.default_server and conch.settings.servers[conch.settings.default_server] then
                server_name = conch.settings.default_server
            else
                local count, only = 0, nil
                for name in pairs(conch.settings.servers) do
                    count = count + 1
                    only = name
                end
                server_name = (count == 1) and only or nil
            end
        end

        if not channel or channel == "" then
            print_message("Usage: /conch msg <channel> <message>  or  /conch msg <server> <channel> <message>")
            return
        end

        -- Ensure channel starts with #
        if string.sub(channel, 1, 1) ~= '#' then
            channel = '#' .. channel
        end

        if not server_name then
            print_message("No default server configured; use /conch msg <server> <channel> <message>")
            return
        end

        local server_conn = conch.servers[server_name]
        if not server_conn then
            print_message(("Server '%s' is not connected"):format(server_name))
            return
        end

        -- Expand tags and flatten the line before it goes out; the local echo
        -- shows the processed text so what was sent is what you see.
        server_conn:send_message(channel, outgoing.process(message))

    elseif command == 'join' then
        -- /conch join <server> <channel> [channel_password]
        if #args < 4 then
            print_message("Usage: /conch join <server> <channel> [channel_password]")
            return
        end
        
        local server_name = args[3]
        local channel = args[4]
        local channel_password = args[5] -- Optional channel password
        
        if string.sub(channel, 1, 1) ~= '#' then
            channel = '#' .. channel
        end
        
        local server_conn = conch.servers[server_name]
        if not server_conn then
            print_message(("Server '%s' not found"):format(server_name))
            return
        end
        
        -- Optionally save channel_password to config for this server
        if channel_password then
            local server_config = conch.settings.servers[server_name]
            if server_config then
                server_config.channel_passwords = server_config.channel_passwords or {}
                server_config.channel_passwords[channel] = channel_password
                settings.save()
            end
        end
        
        server_conn:join_channel(channel, channel_password)
        
    elseif command == 'part' or command == 'leave' then
        -- /conch part <server> <channel> [message] OR /conch leave <server> <channel> [message]
        if #args < 4 then
            print_message("Usage: /conch part <server> <channel> [message] OR /conch leave <server> <channel> [message]")
            return
        end
        
        local server_name = args[3]
        local channel = args[4]
        local part_message = nil
        
        if #args > 4 then
            part_message = table.concat(args, ' ', 5) -- Join remaining args as part message
        end
        
        if string.sub(channel, 1, 1) ~= '#' then
            channel = '#' .. channel
        end
        
        local server_conn = conch.servers[server_name]
        if not server_conn then
            print_message(("Server '%s' not found"):format(server_name))
            return
        end
        
        server_conn:part_channel(channel, part_message)
        
    elseif command == 'list' then
        -- /conch list <server> <channel>
        if #args < 4 then
            print_message("Usage: /conch list <server> <channel>")
            return
        end
        
        local server_name = args[3]
        local channel = args[4]
        
        if string.sub(channel, 1, 1) ~= '#' then
            channel = '#' .. channel
        end
        
        local server_conn = conch.servers[server_name]
        if not server_conn then
            print_message(("Server '%s' not found"):format(server_name))
            return
        end
        
        if server_conn.irc then
            print_message("Requesting user list...", server_name, channel)
            server_conn.irc:send_raw("NAMES " .. channel)
        end
        
    elseif command == 'connect' then
        -- /conch connect <server> [server_password]
        if #args < 3 then
            print_message("Usage: /conch connect <server> [server_password]")
            return
        end
        
        local server_name = args[3]
        local server_password = args[4] -- Optional server password
        
        local server_config = conch.settings.servers[server_name]
        if not server_config then
            print_message(("Server '%s' not found in configuration"):format(server_name))
            return
        end
        
        -- Update server_password if provided
        if server_password then
            server_config.server_password = server_password
            print_message(("Server password updated for '%s'"):format(server_name))
            settings.save()
        end
        
        local server_conn = conch.servers[server_name]
        if not server_conn then
            -- Server connection object doesn't exist, recreate it
            conch.servers[server_name] = ServerConnection:new(server_name, server_config)
            server_conn = conch.servers[server_name]
        else
            -- Update the server config in the connection object
            server_conn.server_config = server_config
        end
        
        -- Disconnect if already connected
        if server_conn.connected then
            server_conn:disconnect()
        end
        
        -- Reset connection attempt time to allow immediate connection
        server_conn.last_connection_attempt = 0
        
        -- Attempt to connect
        print_message(("Connecting to server '%s'..."):format(server_name))
        server_conn:connect()
        
    elseif command == 'save' then
        -- Update settings with current server/channel connections and write to file
        local updated = 0
        for server_name, server_conn in pairs(conch.servers) do
            local server_config = conch.settings.servers[server_name]
            if server_config and server_conn.connected then
                local channels = {}
                for ch, _ in pairs(server_conn.channels) do
                    table.insert(channels, ch)
                end
                table.sort(channels)
                server_config.channels = channels
                updated = updated + 1
            end
        end
        settings.save()
        print_message(("Settings saved with current connections (%d server(s) updated)."):format(updated))
        
    elseif command == 'color' then
        if #args < 5 then
            print_message("Usage: /conch color <server> <channel> <color_number>")
            return
        end
        local server_name = args[3]
        local channel = args[4]
        local color_num = tonumber(args[5])
        if color_num == nil or color_num < 0 or color_num > 512 then
            print_message("color_number must be 0-512 (FFXI chat color index)")
            return
        end
        if string.sub(channel, 1, 1) ~= '#' then
            channel = '#' .. channel
        end
        local server_config = conch.settings.servers[server_name]
        if not server_config then
            print_message(("Server '%s' not found in configuration."):format(server_name))
            return
        end
        server_config.channel_colors = server_config.channel_colors or {}
        server_config.channel_colors[channel] = color_num
        settings.save()
        print_message(("Color for %s on %s set to %d."):format(channel, server_name, color_num))
        
    elseif command == 'servers' then
        print_message("Configured servers:")
        for server_name, server_config in pairs(conch.settings.servers) do
            local status = conch.servers[server_name] and conch.servers[server_name].connected and "Connected" or "Disconnected"
            local server_pwd_info = server_config.server_password and server_config.server_password ~= "" and " (server_password set)" or ""
            local ssl_info = server_config.use_ssl and " (TLS)" or ""
            print_message(("  %s (%s:%d) - %s%s%s"):format(server_name, server_config.server, server_config.port, status, server_pwd_info, ssl_info))
            print_message(("    Channels: %s"):format(table.concat(server_config.channels, ", ")))
            local cp = server_config.channel_passwords
            -- if cp and next(cp) then
            --     local parts = {}
            --     for ch, _ in pairs(cp) do
            --         table.insert(parts, ch .. " (channel_password set)")
            --     end
            --     print_message(("    Channel passwords: %s"):format(table.concat(parts, ", ")))
            -- end
        end
        
    else
        print_message(("Unknown command: %s"):format(command))
        print_message("Use /conch for help")
    end
end)

-- Settings handling
settings.register('settings', 'settings_update', function(s)
    if s ~= nil then
        conch.settings = s
    end
    settings.save()
end)

-- Cleanup on unload
ashita.events.register('unload', 'conch_unload', function()
    for _, server_conn in pairs(conch.servers) do
        server_conn:disconnect()
    end
    settings.save()
end)

-- Initialize on load
initialize_servers()
