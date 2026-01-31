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
local GR_CACHE_VALIDITY = 3600             -- cache is valid for 1 hour by default (overridden by SavedVariables)
local GR_REFRESH_DEBOUNCE = 5.0            -- minimum seconds between actual RefreshNameCache runs
local GR_lastRefreshRequest = 0
local GR_REFRESH_REQUEST_COOLDOWN = 10.0   -- minimum seconds between roster requests to the API

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
GR_Events               = {}
GR_NameCache = GR_NameCache or {}           -- Name → realm cache (for presence, offline/online, etc.)
local GR_statusLines = {}
local FRIENDLY_SOURCES = {
    SYSTEM  = "System",
    GUILD   = "Guild Chat",
    OFFICER = "Officer Chat",
}

------------------------------------------------------------
-- Savedvariables init
------------------------------------------------------------
-- for the very first run after installing the addon or if saved variables file has been deleted
if type(GuildRouterDB) ~= "table" then GuildRouterDB = {} end
-- Initialize savedvariables with defaults if they don't exist
if GuildRouterDB.showLoginLogout == nil then GuildRouterDB.showLoginLogout = true end
if GuildRouterDB.presenceTrace == nil then GuildRouterDB.presenceTrace = false end
if GuildRouterDB.presenceMode == nil then GuildRouterDB.presenceMode = "guild-only" end
-- runtime defaults so Globals are usable before ADDON_LOADED
if GRShowLoginLogout == nil then GRShowLoginLogout = GuildRouterDB.showLoginLogout end
if GRPresenceTrace == nil then GRPresenceTrace = GuildRouterDB.presenceTrace end
if GRPresenceMode == nil then GRPresenceMode = GuildRouterDB.presenceMode end
-- set up
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, addon, ...)
    if event == "ADDON_LOADED" then
        if addon ~= "GuildRouter" then return end
        if not GuildRouterDB then GuildRouterDB = {} end
        if GuildRouterDB.showLoginLogout == nil then GuildRouterDB.showLoginLogout = true end
        GRShowLoginLogout = GuildRouterDB.showLoginLogout
        if GuildRouterDB.presenceTrace == nil then GuildRouterDB.presenceTrace = false end
        GRPresenceTrace = GuildRouterDB.presenceTrace
        if GuildRouterDB.presenceMode == nil then GuildRouterDB.presenceMode = "guild-only" end
        GRPresenceMode = GuildRouterDB.presenceMode
        -- Allow the user to configure cache validity from UI; saved default takes precedence
        GR_CACHE_VALIDITY = GuildRouterDB.cacheValidity or GR_CACHE_VALIDITY
        -- Defer UI-dependent setup until PLAYER_LOGIN
        self:RegisterEvent("PLAYER_LOGIN")
        self:UnregisterEvent("ADDON_LOADED")
        return
    end

    if event == "PLAYER_LOGIN" then
        -- safe to call UI helpers now
        if type(FindTargetFrame) == "function" then
            targetFrame = FindTargetFrame()
        elseif type(EnsureGuildTabExists) == "function" then
            targetFrame = EnsureGuildTabExists()
        end
        -- debugging
        PrintMsg(
        "DBG:init assigned GRPresenceMode=" .. tostring(GRPresenceMode)
        .. " GRPresenceTrace=" .. tostring(GRPresenceTrace)
        .. " GRShowLoginLogout=" .. tostring(GRShowLoginLogout)
        )
        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)


------------------------------------------------------------
-- State
------------------------------------------------------------
local targetFrame = nil
local lastJoinLeaveMessage = nil
local lastJoinLeaveTime    = 0
local nameClassCache = {}

------------------------------------------------------------
-- /grhelp contents
------------------------------------------------------------
GR_HELP_TEXT = {
    "/grstatus - Show addon status",
    "/grpresence <off | guild-only | all> - Set presence mode",
    "/grpresence trace - Toggle presence trace",
    "/grforceroster - Force roster refresh",
    "/grreset - Recreate Guild tab",
    "/grfix - Repair message groups",
    "/grdelete - Delete Guild tab",
    "/grnames - Dump name cache",
    "/grtest - Simulate events",
}

------------------------------------------------------------
-- Helper: centralized messaging (global so can be called at init)
------------------------------------------------------------
function PrintMsg(msg)
    print("|cff00ff00GuildRouter:|r " .. msg)
end

------------------------------------------------------------
-- Helper: toggle for presence tracing
------------------------------------------------------------
local function Trace(msg)
    if not GRPresenceTrace then return end
    print("|cff00ff00GuildRouter:|r " .. msg)
end

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
local function RefreshNameCache(reason)
    if not IsInGuild() then return end
    local now = GetTime()
    if (now - GR_lastRefreshTime) < GR_REFRESH_DEBOUNCE then
        Trace("[Cache] Throttled (reason: " .. (reason or "unknown") .. ")")
        return
    end
    GR_lastRefreshTime = now  -- Reset the validity timer
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
    -- Update the last refresh time so cache validity is measured from here
    GR_lastRefreshTime = GetTime()
    Trace("[Cache] " .. num .. " members refreshed (reason: " .. (reason or "unknown") .. ")")
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
-- Helper: find all message groups assigned to the Guild tab
------------------------------------------------------------
local function GR_GetMessageGroups(frame)
    local groups = {}
    if not frame then return groups end
    for groupName, groupTable in pairs(ChatTypeGroup) do
        if ChatFrame_ContainsMessageGroup(frame, groupName) then
            table.insert(groups, groupName)
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
-- Check if cache needs refreshing (on-demand, not automatic)
------------------------------------------------------------
local function IsCacheStale()
    local now = GetTime()
    return (now - GR_lastRefreshTime) > GR_CACHE_VALIDITY
end

local function RefreshCacheIfNeeded(reason)
    if not IsInGuild() then return false end
    if not IsCacheStale() then 
        Trace("[Cache] Skipped (cache still fresh, reason requested: " .. (reason or "unknown") .. ")")
        return false 
    end
    Trace("[Cache] Cache is stale, requesting roster refresh (reason: " .. (reason or "unknown") .. ")")
    -- Cache is stale, request a roster refresh (throttled)
    RequestRosterSafe()
    return true
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
-- Generate status information, used in command line output and addon UI
------------------------------------------------------------
function GR_BuildStatusLines()
    wipe(GR_statusLines)
    local lines = GR_statusLines
    -- Version
    local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or (GetAddOnMetadata and GetAddOnMetadata)
    local version = meta and meta("GuildRouter", "Version") or "unknown"
    lines[#lines+1] = "Version: " .. version
    -- UI
    lines[#lines+1] = "UI: " .. (isElvUI and "ElvUI" or "Blizzard")
    -- Guild Tab
    local index, frame, docked = GR_GetGuildTabInfo()
    if index then
        lines[#lines+1] = "Guild tab: ChatFrame " .. index .. (docked and " (docked)" or "")

        local groups = GR_GetMessageGroups(frame) or {}
        local friendlyList = {}
        for i = 1, #groups do
            friendlyList[#friendlyList + 1] = groups[i]
        end
        if #friendlyList > 0 then
            lines[#lines+1] = "ChatFrame active sources: " .. table.concat(friendlyList, ", ")
        else
            lines[#lines+1] = "ChatFrame active sources: none!"
        end
    else
        lines[#lines+1] = "Tab: NOT FOUND"
    end
    -- Cache info
    local nCache, cCache = GR_GetCacheInfo()
    lines[#lines+1] = "Caches: names=" .. nCache .. ", class=" .. cCache
    -- Event status
    local evSys, evAch, evRos = GR_GetEventStatus()
    lines[#lines+1] = "Events: sys=" .. evSys .. ", ach=" .. evAch .. ", roster=" .. evRos
    lines[#lines+1] = "In memory config"
    lines[#lines+1] = "  show login/out = " .. tostring(GuildRouterDB and GuildRouterDB.showLoginLogout)
    lines[#lines+1] = "  presenceMode = " .. tostring(GuildRouterDB and GuildRouterDB.presenceMode)
    lines[#lines+1] = "  presencetrace = " .. tostring(GuildRouterDB and GuildRouterDB.presenceTrace)
    lines[#lines+1] = "  cache refresh = " .. tostring(GuildRouterDB and GuildRouterDB.cacheValidity)
    lines[#lines+1] = "SavedVariables:"
    lines[#lines+1] = "  show login/out = " .. tostring(GRShowLoginLogout)
    lines[#lines+1] = "  presenceMode = " .. tostring(GRPresenceMode)
    lines[#lines+1] = "  presencetrace = " .. tostring(GRPresenceTrace)
    lines[#lines+1] = "  cache refresh = " .. tostring(GR_CACHE_VALIDITY)
    -- Memory usage
    collectgarbage("collect")
    UpdateAddOnMemoryUsage()
    local mem = GetAddOnMemoryUsage("GuildRouter")
    lines[#lines+1] = string.format("Memory: %.1f KB", mem)
    return lines
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
            -- Display/hide login/logout messages
            ------------------------------------------------------------
            if not GRShowLoginLogout then
                return false
            end
            ------------------------------------------------------------
            -- Resolve short names (e.g., "Leeroy") to name + realm
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
            -- Guild-only mode: check guild membership using cache
            -- If not found and cache is stale, request a roster refresh (throttled)
            -- but don't block - we'll use stale data rather than delaying the message
            local isGuild = IsGuildMember(fullName)
            if not isGuild and IsCacheStale() then
                RefreshCacheIfNeeded("presence check (" .. fullName .. " not in cache)")
                -- Re-check after potential refresh (might not complete immediately)
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
-- Check if cache needs refreshing (on-demand, not automatic)
------------------------------------------------------------
local function IsCacheStale()
    local now = GetTime()
    return (now - GR_lastRefreshTime) > GR_CACHE_VALIDITY
end

local function RefreshCacheIfNeeded(reason)
    if not IsInGuild() then return false end
    if not IsCacheStale() then 
        Trace("[Cache] Skipped (cache still fresh, reason requested: " .. (reason or "unknown") .. ")")
        return false 
    end
    Trace("[Cache] Cache is stale, requesting roster refresh (reason: " .. (reason or "unknown") .. ")")
    -- Cache is stale, request a roster refresh (throttled)
    RequestRosterSafe()
    return true
end

------------------------------------------------------------
-- Show the guild MOTD in the Guild tab
------------------------------------------------------------
local motdFrame = CreateFrame("Frame")
motdFrame:RegisterEvent("GUILD_MOTD")
motdFrame:SetScript("OnEvent", function(_, _, msg)
    FilterGuildMessages(nil, "GUILD_MOTD", msg)
end)

------------------------------------------------------------
-- On login: initialize Guild tab and request roster
------------------------------------------------------------
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
    targetFrame = FindTargetFrame() or EnsureGuildTabExists()
    -- Don't try to refresh cache immediately; the roster data isn't loaded yet
    -- Instead, request the roster; GUILD_ROSTER_UPDATE will fire and populate the cache
    if IsInGuild() then
        RequestRosterSafe()
    end
end)

-- Debounced roster update listener
-- WoW fires GUILD_ROSTER_UPDATE many times per minute for various reasons,
-- so we only refresh if: (1) cache is empty (first load) or (2) cache is stale (5+ minutes old)
local rosterFrame = CreateFrame("Frame")
rosterFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
rosterFrame:SetScript("OnEvent", function()
    if not IsInGuild() then return end
    -- Always refresh if cache is empty (first login), otherwise only if stale
    local cacheEmpty = next(nameClassCache) == nil
    if cacheEmpty or IsCacheStale() then
        RefreshNameCache(cacheEmpty and "GUILD_ROSTER_UPDATE (first load)" or "GUILD_ROSTER_UPDATE (cache expired)")
    else
        Trace("[Cache] Ignoring GUILD_ROSTER_UPDATE (cache still fresh)")
    end
end)
GR_Events["GUILD_ROSTER_UPDATE"] = true

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
-- /grfix — repair Guild tab message groups
------------------------------------------------------------
SLASH_GRFIX1 = "/grfix"
SlashCmdList["GRFIX"] = function()
    local frame = FindTargetFrame() or EnsureGuildTabExists()
    ConfigureGuildTab(frame)
    SafeDock(frame)
    -- Return focus to the General tab (ChatFrame1)
    if _G["ChatFrame1"] then
        FCF_SelectDockFrame(_G["ChatFrame1"])
    end
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
        PrintMsg("Test: " .. arg .." (see Guild tab)")
    elseif arg == "ach" then
        local achID = 62110
        local achLink = GetAchievementLink(achID)
        FilterGuildMessages(nil, "CHAT_MSG_GUILD_ACHIEVEMENT",
            "%s has earned the achievement %s!", "Turalyon-Ner'zhul", achLink)
        PrintMsg("Test: achievement (see Guild tab)")
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
    PrintMsg("/gpresence: guild-only (default), all, off, trace")
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
-- /grstatus — show diagnostic info
------------------------------------------------------------
SLASH_GRSTATUS1 = "/grstatus"
SlashCmdList["GRSTATUS"] = function(msg)
    PrintMsg("Status")
    local lines = GR_BuildStatusLines()
    for i = 1, #lines do
        print(lines[i])
    end
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
-- /grlogin — show/hide login messages
------------------------------------------------------------
SLASH_GRLOGIN1 = "/grlogin"
SlashCmdList["GRLOGIN"] = function()
    GRShowLoginLogout = not GRShowLoginLogout
    GuildRouterDB.showLoginLogout = GRShowLoginLogout
    PrintMsg("Login/Logout messages: " .. (GRShowLoginLogout and "ON" or "OFF"))
    PrintMsg("DBG:slash /grlogin set GRShowLoginLogout=" .. tostring(GRShowLoginLogout))
end

------------------------------------------------------------
-- /grhelp — show commands
------------------------------------------------------------
SLASH_GRHELP1 = "/grhelp"
SlashCmdList["GRHELP"] = function()
    PrintMsg("Help")
    print("|cff00ff00GuildRouter by ArcNineOhNine, commands:|r")
    for _, line in ipairs(GR_HELP_TEXT) do
        print(line)
    end
end
