--[[
    Conch outgoing text.

    Rewrites a message on its way out to IRC: expands the FFXI-style tags
    below into values read live from client memory, then flattens anything
    that would break the IRC line.  Auto-translate phrases are spelled out
    into text first, because the client stores them as marker bytes rather
    than words and those bytes are not valid UTF-8.

    Tags are case insensitive; anything else is left as typed:
        <t>          current target
        <bt>         battle target
        <lastst>     last selected target
        <me>         your character's name
        <job>        main job and level, plus sub job when one is set (THF75/NIN37)
        <hp> <mp>    current/max HP or MP
        <hpp> <mpp>  percentage of HP or MP remaining
        <posxyz>     current position and height, as (x, z, height)

    Nothing here tracks state between calls: every value is read fresh at
    the moment the message is sent.  A tag that cannot be read right now
    (no target, character not loaded, battle-target scan unavailable) is
    passed through unchanged, so the sender can see what actually went out.
--]]

local M = {};

-- Job ids as the client numbers them.
local JOBS = {
    [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM',
    [5]  = 'RDM', [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK',
    [9]  = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM',
    [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU',
    [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
};

-- Entity slots run 0..2302; anything outside that is not an entity index.
local MAX_ENTITY_INDEX = 2302;

-- SeekBattleActor, the same signature the shared ffxi/targets library scans
-- for.  There is no memory-manager accessor for the battle target.
local BATTLE_TARGET_PATTERN = '66A1????????83EC186685C053565774??0FBFC08B0C85';

local ffi_ok, ffi = pcall(require, 'ffi');

-- ---------------------------------------------------------------------
-- Memory reads
-- ---------------------------------------------------------------------

local function mem()
    return AshitaCore:GetMemoryManager();
end

-- Entity index of the local player.
local function my_index()
    local party = mem():GetParty();
    return party and party:GetMemberTargetIndex(0);
end

-- Name of the entity in `index`, or nil when that slot holds nothing.
-- A leading 0xAB is stripped off, as the fancychat targets library does.
local function entity_name(index)
    if type(index) ~= 'number' or index < 0 or index > MAX_ENTITY_INDEX then
        return nil;
    end
    local entity = mem():GetEntity():GetRawEntity(index);
    local name = entity and entity.Name;
    if type(name) ~= 'string' then return nil; end
    name = name:gsub('^\171', ''):gsub('%s+$', '');
    if name == '' then return nil; end
    return name;
end

-- ---------------------------------------------------------------------
-- Battle target
-- ---------------------------------------------------------------------

local battle_target_addr = nil;
local battle_target_scanned = false;

local function battle_target_index()
    if not battle_target_scanned then
        battle_target_scanned = true;
        if ffi_ok then
            local declared = pcall(ffi.cdef, [[
                typedef struct { uint32_t GuideNo; uint32_t UniqueNo; } conch_char_id;
                typedef struct { uint8_t padding00[116]; conch_char_id id; } conch_atel_buff;
                typedef conch_atel_buff* (__stdcall* conch_seek_battle_actor)(void);
            ]]);
            if declared then
                local addr = ashita.memory.find(0, 0, BATTLE_TARGET_PATTERN, 0, 0);
                if addr ~= nil and addr ~= 0 then
                    battle_target_addr = addr;
                end
            end
        end
    end
    if not battle_target_addr then return nil; end

    local ok, actor = pcall(function()
        return ffi.cast('conch_seek_battle_actor', battle_target_addr)();
    end);
    if not ok or actor == nil then return nil; end
    return actor.id.GuideNo;
end

-- ---------------------------------------------------------------------
-- Tag values
-- ---------------------------------------------------------------------

local function percent(current, maximum)
    if type(current) ~= 'number' or type(maximum) ~= 'number' or maximum <= 0 then
        return nil;
    end
    return ('%d%%'):format(math.floor((current / maximum) * 100 + 0.5));
end

-- Exposed so callers can add or override tags.
M.tags = {};

M.tags['me'] = function()
    local party = mem():GetParty();
    local name = party and party:GetMemberName(0);
    if type(name) == 'string' and name ~= '' then return name; end
    return entity_name(my_index());
end;

M.tags['job'] = function()
    local player = mem():GetPlayer();
    local main, main_level = JOBS[player:GetMainJob()], player:GetMainJobLevel();
    if main == nil or type(main_level) ~= 'number' or main_level <= 0 then return nil; end

    local job = ('%s%d'):format(main, main_level);
    local sub, sub_level = JOBS[player:GetSubJob()], player:GetSubJobLevel();
    if sub ~= nil and type(sub_level) == 'number' and sub_level > 0 then
        job = ('%s/%s%d'):format(job, sub, sub_level);
    end
    return job;
end;

M.tags['hp'] = function()
    local hp, max = mem():GetParty():GetMemberHP(0), mem():GetPlayer():GetHPMax();
    if type(hp) ~= 'number' or type(max) ~= 'number' then return nil; end
    return ('%d/%d'):format(hp, max);
end;

M.tags['mp'] = function()
    local mp, max = mem():GetParty():GetMemberMP(0), mem():GetPlayer():GetMPMax();
    if type(mp) ~= 'number' or type(max) ~= 'number' then return nil; end
    return ('%d/%d'):format(mp, max);
end;

M.tags['hpp'] = function()
    return percent(mem():GetParty():GetMemberHP(0), mem():GetPlayer():GetHPMax());
end;

M.tags['mpp'] = function()
    return percent(mem():GetParty():GetMemberMP(0), mem():GetPlayer():GetMPMax());
end;

-- Ground-plane position plus height, as (x, z, height).
--
-- The client's field names are not the order you would guess: the two
-- horizontal axes are X and Z, and the field named Y is altitude.  The shared
-- targets library depends on exactly that -- libs/ffxi/targets.lua picks the
-- nearest claimable mob with sqrt(x*x + z*z), dropping Y -- so this reads them
-- the same way.  (mining.lua and mobdb print the pair as X/Y and Z as height,
-- which is the wrong way round.)
M.tags['posxyz'] = function()
    local entity = mem():GetEntity();
    local index  = my_index();
    local x, z = entity:GetLocalPositionX(index), entity:GetLocalPositionZ(index);
    local height = entity:GetLocalPositionY(index);
    if type(x) ~= 'number' or type(z) ~= 'number' or type(height) ~= 'number' then
        return nil;
    end
    return ('(%.1f, %.1f, %.1f)'):format(x, z, height);
end;

M.tags['t'] = function()
    local target = mem():GetTarget();
    -- The sub-target lives in slot 1 and the game reports it ahead of the
    -- normal target, matching the fancychat targets library.  The empty slot
    -- is checked so a stale index can never resolve to some other entity.
    local slot = target:GetIsSubTargetActive() ~= 0 and 1 or 0;
    local active = target:GetIsActive(slot);
    if active == nil or active == 0 then return nil; end
    return entity_name(target:GetTargetIndex(slot));
end;

M.tags['lastst'] = function()
    local target = mem():GetTarget();
    -- Prefer the name the client recorded with the target; fall back to
    -- resolving the recorded index.
    local name = target:GetLastTargetName();
    if type(name) == 'string' then
        name = name:gsub('^\171', ''):gsub('%s+$', '');
        if name ~= '' then return name; end
    end
    return entity_name(target:GetLastTargetIndex());
end;

M.tags['bt'] = function()
    return entity_name(battle_target_index());
end;

-- ---------------------------------------------------------------------
-- Text rewriting
-- ---------------------------------------------------------------------

-- An auto-translate phrase does not arrive as text.  The client puts a run of
-- marker bytes and a phrase id in the string and only expands it when drawing:
-- sugar's strip_translate (libs/sugar/string.lua) has to know about the marker
-- bytes, and ParseAutoTranslate exists to turn them into words.  Sent as-is
-- they are not valid UTF-8, which is why a message containing one disappears
-- for everyone on the other end while still showing up in the local echo.
--
-- The chat manager owns the phrase table, so hand the message to it first.
-- The flag is `useBrackets`: false writes the phrase out as plain text, true
-- would wrap it in square brackets.
local function parse_autotranslate(text)
    local chat = AshitaCore:GetChatManager();
    if chat == nil then return text; end
    local ok, parsed = pcall(function()
        return chat:ParseAutoTranslate(text, false);
    end);
    if ok and type(parsed) == 'string' then return parsed; end
    return text;
end

-- Replace every <tag> with its value; unknown or unreadable tags are
-- passed through exactly as typed.
local function expand(text)
    return (text:gsub('<(%w+)%>', function(tag)
        local resolve = M.tags[tag:lower()];
        if resolve ~= nil then
            local ok, value = pcall(resolve);
            if ok then
                if type(value) == 'number' then value = tostring(value); end
                if type(value) == 'string' and value ~= '' then return value; end
            end
        end
        return ('<%s>'):format(tag);
    end));
end

-- IRC lines are CRLF delimited, so a newline coming out of the client would
-- end the message early and anything after it would be read as a command.
-- Flatten them; spacing inside the message is otherwise left alone.
local function sanitize(text)
    return (text:gsub('[\r\n]+', ' '):gsub('^%s+', ''):gsub('%s+$', ''));
end

--[[
    Rewrite a message on its way out to IRC.

    @param {string} message - The message as typed.
    @return {string} The message with tags expanded and the line flattened.
--]]
M.process = function(message)
    if type(message) ~= 'string' then return message; end
    return sanitize(expand(parse_autotranslate(message)));
end;

return M;
