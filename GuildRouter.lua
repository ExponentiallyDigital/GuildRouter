-- Guild Router
-- Routes guild MOTD, join/leave, achievements, and roster changes to the tab named "Guild".
--      All player names (except in roster changes) are class-coloured and clickable.
--      Join/leave messages are de-duplicated (Blizzard fires them multiple times).

------------------------------------------------------------
-- Local references
------------------------------------------------------------
local TARGET_TAB_NAME = "Guild"
local isElvUI = (ElvUI ~= nil)

-- Throttle / debounce controls for roster refresh
local GR_lastRefreshTime = 0
local GR_REFRESH_DEBOUNCE = 5.0           -- minimum seconds between actual RefreshNameCache runs
local GR_lastRefreshRequest = 0
local GR_REFRESH_REQUEST_COOLDOWN = 10.0  -- minimum seconds between roster requests to the API

local _G                = _G
local NUM_CHAT_WINDOWS  = NUM_CHAT_WINDOWS
local GetChatWindowInfo = GetChatWindowInfo
local FCF_OpenNewWindow = FCF_OpenNewWindow
local FCF_SetLocked     = FCF_SetLocked
local FCF_Close         = FCF_Close
local FCF_SelectDockFrame = FCF_SelectDockFrame
local GeneralDockManager = GeneralDockManager

local IsInGuild          = IsInGuild
local GetNumGuildMembers = GetNumGuildMembers
local GetGuildRosterInfo = GetGuildRosterInfo
local RAID_CLASS_COLORS  = RAID_CLASS_COLORS

local GetTime           = GetTime
local format            = string.format
local match             = string.match
local find              = string.find
local gsub              = string.gsub
local wipe              = wipe
local PLAYER_REALM      = GetRealmName()
GR_Events = {}

------------------------------------------------------------
-- Presence announcement settings from SavedVariables on login
------------------------------------------------------------
local GRPresenceMode
local GRPresenceTrace

------------------------------------------------------------
-- Helper: centralized messaging
------------------------------------------------------------
local function PrintMsg(msg)
    print("|cff00ff00GuildRouter:|r " .. msg)
end
local function Trace(msg)
    if not GRPresenceTrace then return end
    print(msg)
end

------------------------------------------------------------
-- State
------------------------------------------------------------
local targetFrame = nil
local lastJoinLeaveMessage = nil
local lastJoinLeaveTime    = 0
local nameClassCache = {}

------------------------------------------------------------
-- Name → realm cache (for presence, offline/online, etc.)
------------------------------------------------------------
GR_NameCache = GR_NameCache or {}

------------------------------------------------------------
-- Normalize a full name into name + realm
-- Handles apostrophes, Unicode, hyphens, missing realms
-- Splits on the LAST hyphen so realm parts containing hyphens are preserved.
------------------------------------------------------------
function GR_NormalizeName(fullName)
    if not fullName or fullName == "" then
        return nil, nil
    end
    -- Split on the LAST hyphen so names or realms containing hyphens work
    local name, realm = fullName:match("^(.*)%-(.+)$")
    if not name then
        -- No realm provided → assume player realm
        name  = fullName
        realm = PLAYER_REALM
    end
    return name, realm
end

------------------------------------------------------------
-- Cache the realm for a given name
------------------------------------------------------------
function GR_CacheName(fullName)
    local name, realm = GR_NormalizeName(fullName)
    if name and realm then
        GR_NameCache[name] = realm
    end
end

------------------------------------------------------------
-- Resolve a short name (offline/online messages)
-- into a full name using the cache. If the input already
-- contains a realm, return it normalized unchanged.
------------------------------------------------------------
function GR_ResolveName(nameOrFull)
    if not nameOrFull or nameOrFull == "" then return nil end
    -- If it already contains a hyphen, treat it as a full name
    if nameOrFull:find("%-") then
        local n, r = GR_NormalizeName(nameOrFull)
        if n and r then
            return n .. "-" .. r
        end
        return nameOrFull
    end
    -- Otherwise treat as a short name and look up realm
    local realm = GR_NameCache[nameOrFull]
    if realm then
        return nameOrFull .. "-" .. realm
    end
    -- Fallback: assume same realm
    return nameOrFull .. "-" .. GetRealmName()
end

------------------------------------------------------------
-- Find the chat frame named "Guild"
------------------------------------------------------------
local function FindTargetFrame()
    for i = 1, NUM_CHAT_WINDOWS do
        if GetChatWindowInfo(i) == TARGET_TAB_NAME then
            return _G["ChatFrame"..i]
        end
    end
    return nil
end

local function SafeDock(frame)
    if not frame then return end
    frame:Show()
    frame.isDocked = 1
    if GeneralDockManager and GeneralDockManager.AddChatFrame then
        GeneralDockManager:AddChatFrame(frame)
    end
    if FCF_SelectDockFrame then FCF_SelectDockFrame(frame) end
end

------------------------------------------------------------
-- Configure the Guild tab ONLY when we create it
------------------------------------------------------------
local function ConfigureGuildTab(frame)
    -- Message groups
    ChatFrame_AddMessageGroup(frame, "SYSTEM")
    ChatFrame_AddMessageGroup(frame, "GUILD")
    ChatFrame_AddMessageGroup(frame, "OFFICER")
    ChatFrame_AddMessageGroup(frame, "GUILD_ACHIEVEMENT")
end

------------------------------------------------------------
-- Create the "Guild" tab if it doesn't exist
------------------------------------------------------------
local function EnsureGuildTabExists()
    local frame = FindTargetFrame()
    if frame then
        return frame -- Do NOT modify existing tabs
    end
    frame = FCF_OpenNewWindow(TARGET_TAB_NAME)
    FCF_SetLocked(frame, true)
    SafeDock(frame)
    ConfigureGuildTab(frame)
    return frame
end

------------------------------------------------------------
-- Refresh name -> class cache from the guild roster
-- Ensures both short name and fullName keys are stored.
------------------------------------------------------------
local function RefreshNameCache()
    if not IsInGuild() then return end
    local now = GetTime()
    if (now - GR_lastRefreshTime) < GR_REFRESH_DEBOUNCE then
        return
    end
    GR_lastRefreshTime = now
    -- Wiping both ensures we don't have "ghost" members in our cache
    wipe(nameClassCache)
    wipe(GR_NameCache) 
    local num = GetNumGuildMembers()
    for i = 1, num do
        local name, _, _, _, _, _, _, _, _, _, classFilename = GetGuildRosterInfo(i)
        if name and classFilename then
            local shortName, realm = GR_NormalizeName(name)
            if not shortName then shortName = name; realm = GetRealmName() end
            local fullName = shortName .. "-" .. realm
            
            nameClassCache[shortName] = classFilename
            nameClassCache[fullName]  = classFilename
            
            -- Direct assignment is slightly faster than calling a helper function here
            GR_NameCache[shortName] = realm 
        end
    end
    Trace("[Cache] " .. num .. " members refreshed")
end

------------------------------------------------------------
-- Build a class-coloured, clickable player link
------------------------------------------------------------
local function GetColoredPlayerLink(fullName)
    if not fullName then return "" end
    local nameOnly = fullName:gsub("%-.*", "")
    local class = nameClassCache[fullName]
    if class then
        local color = RAID_CLASS_COLORS[class]
        if color and color.colorStr then
            return "|Hplayer:" .. fullName .. "|h|c" .. color.colorStr .. nameOnly .. "|r|h"
        end
    end
    return "|Hplayer:" .. fullName .. "|h[" .. nameOnly .. "]|h"
end

------------------------------------------------------------
-- Replace two plain names in a message with clickable links
------------------------------------------------------------
local function LinkTwoNames(msg, name1, name2)
    if name1 then
        msg = gsub(msg, gsub(name1, "(%W)", "%%%1"), GetColoredPlayerLink(name1), 1)
    end
    if name2 then
        msg = gsub(msg, gsub(name2, "(%W)", "%%%1"), GetColoredPlayerLink(name2), 1)
    end
    return msg
end

------------------------------------------------------------
-- Throttle roster lookups
------------------------------------------------------------
local function RequestRosterSafe()
    if not IsInGuild() then return end
    local now = GetTime()
    if (now - GR_lastRefreshRequest) < GR_REFRESH_REQUEST_COOLDOWN then
        return
    end
    GR_lastRefreshRequest = now
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif RequestGuildRoster then
        RequestGuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

------------------------------------------------------------
-- Guild member check for login/out routing
------------------------------------------------------------
local function IsGuildMember(fullName)
    return nameClassCache[fullName] ~= nil
end

------------------------------------------------------------
-- Match roster change patterns (promote, demote, rank, notes)
------------------------------------------------------------
local function MatchRosterChange(msg)
    local patterns = {
        "^(.-) has promoted (.-) to ",
        "^(.-) has demoted (.-) to ",
        "^(.-) has changed the guild rank of (.-) from ",
        "^(.-) has changed the Officer Note for (.-)%.",
        "^(.-) has changed the Public Note for (.-)%.",
    }
    for _, pat in ipairs(patterns) do
        local a, t = match(msg, pat)
        if a and t then return a, t end
    end
    return nil, nil
end

------------------------------------------------------------
-- Helper: message groups assigned to the Guild tab
------------------------------------------------------------
local function GR_GetMessageGroups(frame)
    local groups = {}
    if not frame then return groups end
    for _, group in ipairs({
        "SYSTEM", "GUILD", "OFFICER", "GUILD_ACHIEVEMENT",
        "SAY", "YELL", "WHISPER", "PARTY", "RAID",
        "CHANNEL1", "CHANNEL2", "CHANNEL3", "CHANNEL4",
    }) do
        if ChatFrame_ContainsMessageGroup(frame, group) then
            table.insert(groups, group)
        end
    end
    return groups
end
local function GR_GetCacheInfo()
    local nameCount, classCount = 0, 0
    for _ in pairs(GR_NameCache or {}) do nameCount = nameCount + 1 end
    for _ in pairs(nameClassCache or {}) do classCount = classCount + 1 end
    return nameCount, classCount -- Returns numbers directly
end
local function GR_GetEventStatus()
    local sys = GR_Events["CHAT_MSG_SYSTEM"] and "yes" or "no"
    local ach = GR_Events["CHAT_MSG_GUILD_ACHIEVEMENT"] and "yes" or "no"
    local roster = GR_Events["GUILD_ROSTER_UPDATE"] and "yes" or "no"
    return sys, ach, roster -- Returns three strings
end

------------------------------------------------------------
-- Core filter: reroute and reformat guild-related messages
------------------------------------------------------------
local function FilterGuildMessages(self, event, msg, sender, ...)
    if not targetFrame then
        targetFrame = FindTargetFrame() or EnsureGuildTabExists()
    end
    -- System messages
    if event == "CHAT_MSG_SYSTEM" then
        -- Suppress Blizzard's system echo of guild achievements
        if msg:find("has earned the achievement") then
            return true
        end
        if find(msg, "Message of the Day") then
            return true
        end
        -- Join / Leave
        local joinName  = match(msg, "^(.-) has joined the guild")
        local leaveName = match(msg, "^(.-) has left the guild")
        local name = joinName or leaveName
        if name then
            local formatted = GetColoredPlayerLink(name) ..
                (joinName and " has joined the guild." or " has left the guild.")
            local now = GetTime()
            if formatted == lastJoinLeaveMessage and (now - lastJoinLeaveTime) < 1 then
                return true
            end
            lastJoinLeaveMessage = formatted
            lastJoinLeaveTime    = now
            targetFrame:AddMessage(formatted)
            return true
        end
        ------------------------------------------------------------
        -- Login / Logout announcements (presence routing)
        ------------------------------------------------------------
        -- Match hyperlink format first (ElvUI, Blizzard modern)
        local nameOnline  = msg:match("|Hplayer:([^:|]+).* has come online")
        local nameOffline = msg:match("|Hplayer:([^:|]+).* has gone offline")
        -- Fallback: plain text (older Blizzard format)
        if not nameOnline then
            nameOnline = msg:match("^(%S+) has come online")
        end
        if not nameOffline then
            nameOffline = msg:match("^(%S+) has gone offline")
        end     
        local name = nameOnline or nameOffline
        if name then
            ------------------------------------------------------------
            -- Resolve short names (e.g., "Leeroy") to full names
            ------------------------------------------------------------
            local fullName = GR_ResolveName(name)
            ------------------------------------------------------------
            -- Presence mode: off
            ------------------------------------------------------------
            if GRPresenceMode == "off" then
                return false
            end
            ------------------------------------------------------------
            -- Guild-only mode: ignore non-guild members (with on-demand refresh)
            ------------------------------------------------------------
            -- Try a direct lookup first
            local isGuild = IsGuildMember(fullName)
            -- If not found, request a roster refresh (throttled) and try a single re-check
            if not isGuild then
                RequestRosterSafe()
                isGuild = IsGuildMember(fullName)
            end
            if GRPresenceMode == "guild-only" and not isGuild then
                return false
            end
            ------------------------------------------------------------
            -- Format ONLINE/OFFLINE with colour
            ------------------------------------------------------------
            local status
            if nameOnline then
                status = "|cff40ff40online|r"   -- medium green
            else
                status = "|cffff4040offline|r"  -- dark red
            end
            local formatted
            if nameOnline then
                formatted = GetColoredPlayerLink(fullName) .. " has come " .. status .. "."
            else
                formatted = GetColoredPlayerLink(fullName) .. " has gone " .. status .. "."
            end
            ------------------------------------------------------------
            -- De-duplicate
            ------------------------------------------------------------
            local now = GetTime()
            if formatted == lastJoinLeaveMessage and (now - lastJoinLeaveTime) < 1 then
                return true
            end
            lastJoinLeaveMessage = formatted
            lastJoinLeaveTime    = now
            targetFrame:AddMessage(formatted)
            return true
        end
        local actor, target = MatchRosterChange(msg)
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end
    end
    -- Guild achievements
    if event == "CHAT_MSG_GUILD_ACHIEVEMENT" then
        local player = sender or "Unknown"
        GR_CacheName(player)
        local achievementLink = ...
        local formatted = format(msg, GetColoredPlayerLink(player), achievementLink)
        targetFrame:AddMessage(formatted)
        return true
    end
    return false
end

------------------------------------------------------------
-- Hook chat events
------------------------------------------------------------
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", FilterGuildMessages)
GR_Events["CHAT_MSG_SYSTEM"] = true
ChatFrame_AddMessageEventFilter("CHAT_MSG_GUILD_ACHIEVEMENT", FilterGuildMessages)
GR_Events["CHAT_MSG_GUILD_ACHIEVEMENT"] = true

------------------------------------------------------------
-- Refresh name cache when the roster updates
------------------------------------------------------------
local rosterFrame = CreateFrame("Frame")
rosterFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
rosterFrame:SetScript("OnEvent", RefreshNameCache)
GR_Events["GUILD_ROSTER_UPDATE"] = true

------------------------------------------------------------
-- Show the real guild MOTD in the Guild tab
------------------------------------------------------------
local motdFrame = CreateFrame("Frame")
motdFrame:RegisterEvent("GUILD_MOTD")
motdFrame:SetScript("OnEvent", function(_, _, msg)
    FilterGuildMessages(nil, "GUILD_MOTD", msg)
end)

------------------------------------------------------------
-- Load presence preference, defaults to guild only
-- if needed, auto-create Guild tab on login
------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    ------------------------------------------------------------
    -- Load SavedVariables (create table if missing)
    ------------------------------------------------------------
    GuildRouterDB = GuildRouterDB or {}
    -- Default presence mode: guild-only
    if GuildRouterDB.presenceMode == nil then
        GuildRouterDB.presenceMode = "guild-only"
    end
    -- Default trace mode: off
    if GuildRouterDB.presenceTrace == nil then
        GuildRouterDB.presenceTrace = false
    end
    -- Apply to runtime
    GRPresenceMode  = GuildRouterDB.presenceMode
    GRPresenceTrace = GuildRouterDB.presenceTrace
    -- Existing startup logic
    targetFrame = FindTargetFrame() or EnsureGuildTabExists()
    -- Request a fresh guild roster; RefreshNameCache will run on GUILD_ROSTER_UPDATE
    if IsInGuild() then
        RequestRosterSafe()
    end
end)

------------------------------------------------------------
-- /grdebug — recreate the Guild tab
------------------------------------------------------------
SLASH_GRDBG1 = "/grdebug"
SlashCmdList["GRDBG"] = function()
    local cache = GR_GetCacheInfo()
    PrintMsg("Cache: names=" .. cache.names .. " class=" .. cache.class)
end

------------------------------------------------------------
-- /grreset — recreate the Guild tab
------------------------------------------------------------
SLASH_GRRESET1 = "/grreset"
SlashCmdList["GRRESET"] = function()
    if ElvUI then
        local frame = FindTargetFrame()
        if not frame then
            PrintMsg("ElvUI mode: create tab manually via Chat → Create Window")
            return
        end
        ConfigureGuildTab(frame)
        PrintMsg("Guild tab repaired (ElvUI).")
        return
    end
    for i = 1, NUM_CHAT_WINDOWS do
        if GetChatWindowInfo(i) == TARGET_TAB_NAME then
            FCF_Close(_G["ChatFrame"..i])
            break
        end
    end
    targetFrame = EnsureGuildTabExists()
    ConfigureGuildTab(targetFrame)
    SafeDock(targetFrame)
    PrintMsg("Guild tab has been reset.")
end

------------------------------------------------------------
-- /grdelete — delete the Guild tab
------------------------------------------------------------
SLASH_GRDELETE1 = "/grdelete"
SlashCmdList["GRDELETE"] = function()
    for i = 1, NUM_CHAT_WINDOWS do
        if GetChatWindowInfo(i) == TARGET_TAB_NAME then
            local frame = _G["ChatFrame"..i]
            if frame.isDocked then FCF_UnDockFrame(frame) end
            FCF_Close(frame)
            PrintMsg("Guild tab deleted.")
            return
        end
    end
    PrintMsg("Guild tab not found.")
end

------------------------------------------------------------
-- /grsources — reliable message group listing (Blizzard + ElvUI)
------------------------------------------------------------
SLASH_GRSOURCES1 = "/grsources"
SlashCmdList["GRSOURCES"] = function()
    local frame = FindTargetFrame()
    if not frame then
        PrintMsg("Guild tab not found.")
        return
    end
    PrintMsg("Sources: " .. table.concat(GR_GetMessageGroups(frame), ", "))
end

------------------------------------------------------------
-- /grfix — repair Guild tab message groups
------------------------------------------------------------
SLASH_GRFIX1 = "/grfix"
SlashCmdList["GRFIX"] = function()
    local frame = FindTargetFrame() or EnsureGuildTabExists()
    ConfigureGuildTab(frame)
    SafeDock(frame)
    PrintMsg("Guild tab sources repaired.")
end

------------------------------------------------------------
-- /grtest — simulate guild events
------------------------------------------------------------
SLASH_GRTEST1 = "/grtest"
SlashCmdList["GRTEST"] = function(arg)
    local frame = FindTargetFrame() or EnsureGuildTabExists()
    local tests = {
        join = "Turalyon has joined the guild.",
        leave = "Murloc has left the guild.",
        promote = "Sargeras has promoted Swapxy to rank Officer.",
        demote = "Sargeras has demoted LeeroyJenkins to rank Initiate.",
        note = "Sargeras has changed the Officer Note for LeeroyJenkins.",
    }
    if tests[arg] then
        FilterGuildMessages(nil, "CHAT_MSG_SYSTEM", tests[arg])
        PrintMsg("Test: " .. arg)
    elseif arg == "ach" then
        FilterGuildMessages(nil, "CHAT_MSG_GUILD_ACHIEVEMENT",
            "%s has earned the achievement %s!", "Turalyon-Ner'zhul",
            "|cffffff00|Hachievement:6:Player-1234-00000000:1:1:1:1:4294967295:4294967295:4294967295:4294967295|h[Level 10]|h|r")
        PrintMsg("Test: ach")
    else
        PrintMsg("Tests: join, leave, promote, demote, note, ach")
    end
end

------------------------------------------------------------
-- /grpresence — control presence announcements
------------------------------------------------------------
SLASH_GRPRESENCE1 = "/grpresence"
SlashCmdList["GRPRESENCE"] = function(arg)
    arg = arg and arg:lower() or ""
    local modes = { ["guild-only"] = true, ["all"] = true, ["off"] = true }
    if modes[arg] then
        GRPresenceMode = arg
        GuildRouterDB.presenceMode = arg
        PrintMsg("Presence: " .. arg)
        return
    elseif arg == "trace" then
        GRPresenceTrace = not GRPresenceTrace
        GuildRouterDB.presenceTrace = GRPresenceTrace
        PrintMsg("Trace: " .. (GRPresenceTrace and "ON" or "OFF"))
        return
    end
    PrintMsg("Presence: guild-only (default), all, off, trace")
end

------------------------------------------------------------
-- /grdock — safely dock the Guild tab
------------------------------------------------------------
SLASH_GRDOCK1 = "/grdock"
SlashCmdList["GRDOCK"] = function()
    local frame = FindTargetFrame()
    if not frame then
        PrintMsg("Guild tab not found.")
        return
    end
    SafeDock(frame)
    PrintMsg("Guild tab docked.")
end

------------------------------------------------------------
-- /grnames — display the name cache pairs
------------------------------------------------------------
SLASH_GRNAMES1 = "/grnames"
SlashCmdList["GRNAMES"] = function()
    print("|cff00ff00GuildRouter Name Cache|r")
    for name, realm in pairs(GR_NameCache) do
        print("  " .. name .. " → " .. realm)
    end
end
local function GR_GetGuildTabInfo()
    for i = 1, NUM_CHAT_WINDOWS do
        if GetChatWindowInfo(i) == TARGET_TAB_NAME then
            local frame = _G["ChatFrame"..i]
            return i, frame, frame.isDocked -- Returns values, not a table
        end
    end
    return nil
end

------------------------------------------------------------
-- Helper: Zero-allocation Diagnostic Info
------------------------------------------------------------
local function GR_GetCacheInfo()
    local nameCount, classCount = 0, 0
    if GR_NameCache then for _ in pairs(GR_NameCache) do nameCount = nameCount + 1 end end
    if nameClassCache then for _ in pairs(nameClassCache) do classCount = classCount + 1 end end
    return nameCount, classCount
end

local function GR_GetEventStatus()
    local sys = GR_Events["CHAT_MSG_SYSTEM"] and "yes" or "no"
    local ach = GR_Events["CHAT_MSG_GUILD_ACHIEVEMENT"] and "yes" or "no"
    local roster = GR_Events["GUILD_ROSTER_UPDATE"] and "yes" or "no"
    return sys, ach, roster
end

local function GR_GetGuildTabInfo()
    for i = 1, NUM_CHAT_WINDOWS do
        if GetChatWindowInfo(i) == TARGET_TAB_NAME then
            local frame = _G["ChatFrame"..i]
            if frame then
                return i, frame, frame.isDocked
            end
        end
    end
    return nil, nil, nil
end

------------------------------------------------------------
-- /grstatus — show diagnostic info (Optimized)
------------------------------------------------------------
SLASH_GRSTATUS1 = "/grstatus"
SlashCmdList["GRSTATUS"] = function(msg)
    local full = msg and string.lower(msg):match("full")
    PrintMsg("Status")
    print("UI: " .. (isElvUI and "ElvUI" or "Blizzard"))
    local index, frame, docked = GR_GetGuildTabInfo()
    if index then
        print("Tab: ChatFrame " .. index .. (docked and " (docked)" or ""))
        local groups = GR_GetMessageGroups(frame) 
        print("  Active sources: " .. (#groups > 0 and table.concat(groups, ", ") or "none"))
    else
        print("Tab: NOT FOUND")
        -- We continue even if tab is missing to show cache info
    end
    local nCache, cCache = GR_GetCacheInfo()
    print("Caches: names=" .. nCache .. ", class=" .. cCache)
    local evSys, evAch, evRos = GR_GetEventStatus()
    print("Events: sys=" .. evSys .. ", ach=" .. evAch .. ", roster=" .. evRos)
    print("Presence mode: " .. tostring(GRPresenceMode))
    print("Trace mode: " .. tostring(GRPresenceTrace))
    print("SavedVariables:")
    print("  presenceMode = " .. tostring(GRPresenceMode))
    print("  presenceTrace = " .. tostring(GRPresenceTrace))
    -- Final memory measurement
    collectgarbage("collect") 
    UpdateAddOnMemoryUsage() 
    local mem = GetAddOnMemoryUsage("GuildRouter")
    -- Using string.format directly to avoid any missing local references
    print(string.format("Memory: %.1f KB", mem))
end

------------------------------------------------------------
-- /grforceroster — request guild roster
------------------------------------------------------------
SLASH_GRFORCERO1 = "/grforceroster"
SlashCmdList["GRFORCERO"] = function()
    PrintMsg("Requesting roster...")
    RequestRosterSafe()
end

------------------------------------------------------------
-- /grhelp — show commands
------------------------------------------------------------
SLASH_GRHELP1 = "/grhelp"
SlashCmdList["GRHELP"] = function()
    print("|cff00ff00GuildRouter by ArcNineOhNine, commands:|r")
    print(" /grstatus   - display status info, defaults to short unless `full` specified.")
    print(" /grpresence - set & save login/out announcements (def=guild-only, all, off, trace)")
    print(" /grdock     - dock the Guild tab if not visible")
    print(" /grreset    - recreate the Guild tab")
    print(" /grfix      - repair Guild tab message groups and dock the tab")
    print(" /grdelete   - permanently delete the Guild tab")
    print(" /grsources  - show message groups/channels for the Guild tab")
    print(" /grtest     - simulate guild events (join, leave, promote, demote, note, ach)")
    print(" /grdebug    - display cache")
    print(" /grhelp     - show this command list")
end
