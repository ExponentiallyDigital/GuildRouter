-- Guild Router
-- Routes guild MOTD, join/leave, achievements, and roster changes to the tab named "Guild".
--      All player names (except in roster changes) are class-coloured and clickable.
--      Join/leave messages are de-duplicated (Blizzard fires them multiple times).

------------------------------------------------------------
-- Local references
------------------------------------------------------------
local TARGET_TAB_NAME = "Guild"
local isElvUI = (ElvUI ~= nil)

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

local GR_LastMessage = nil
local GR_LastError   = nil
GR_Events = {}

------------------------------------------------------------
-- Presence announcement settings from SavedVariables on login
------------------------------------------------------------
local GRPresenceMode
local GRPresenceTrace

------------------------------------------------------------
-- State
------------------------------------------------------------
local targetFrame = nil

-- For join/leave de-duplication
local lastJoinLeaveMessage = nil
local lastJoinLeaveTime    = 0

-- Cache: fullName ("Name-Realm") -> classFilename ("WARRIOR")
local nameClassCache = {}

------------------------------------------------------------
-- Name → realm cache (for presence, offline/online, etc.)
------------------------------------------------------------
GR_NameCache = GR_NameCache or {}

------------------------------------------------------------
-- Normalize a full name into name + realm
-- Handles apostrophes, Unicode, hyphens, missing realms
------------------------------------------------------------
function GR_NormalizeName(fullName)
    if not fullName or fullName == "" then
        return nil, nil
    end

    -- Split on the FIRST hyphen only
    local name, realm = fullName:match("^([^%-]+)%-(.+)$")

    if not name then
        -- No realm provided → assume player realm
        name  = fullName
        realm = GetRealmName()
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

------------------------------------------------------------
-- Safe docking (Blizzard + ElvUI compatible)
------------------------------------------------------------
local function SafeDock(frame)
    if not frame then return end

    frame:Show()
    frame.isDocked = 1

    if GeneralDockManager and GeneralDockManager.AddChatFrame then
        GeneralDockManager:AddChatFrame(frame)
    end

    if FCF_SelectDockFrame then
        FCF_SelectDockFrame(frame)
    end
end

------------------------------------------------------------
-- Order tab when running without ElvUI
------------------------------------------------------------
local function MoveTabToEnd_Blizzard(frame)
    local dock = GeneralDockManager.primary
    if not dock or not dock.DOCKED_CHAT_FRAMES then return end

    GeneralDockManager:UpdateTabs()

    local index
    for i, f in ipairs(dock.DOCKED_CHAT_FRAMES) do
        if f == frame then
            index = i
            break
        end
    end

    if index then
        table.remove(dock.DOCKED_CHAT_FRAMES, index)
        table.insert(dock.DOCKED_CHAT_FRAMES, frame)
        GeneralDockManager:LayoutTabs()
    end
end

------------------------------------------------------------
-- Order tab when running with ElvUI
------------------------------------------------------------
local function MoveTabToEnd_ElvUI(tabName)
    local E = ElvUI[1]
    local db = ElvDB and ElvDB.chat and ElvDB.chat.chatHistoryTab
    if not (E and db) then return end

    -- Remove existing entry
    for i, name in ipairs(db) do
        if name == tabName then
            table.remove(db, i)
            break
        end
    end

    -- Add to end
    table.insert(db, tabName)

    -- Force ElvUI to rebuild chat layout
    E:PositionChat(true)
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

    wipe(nameClassCache)

    local num = GetNumGuildMembers()
    for i = 1, num do
        local name, _, _, _, _, _, _, _, _, _, classFilename = GetGuildRosterInfo(i)
        if name and classFilename then
            -- name may be "Name" or "Name-Realm"
            local shortName, realm = name:match("^([^%-]+)%-(.+)$")
            if not shortName then
                shortName = name
                realm = GetRealmName()
            end

            local fullName = shortName .. "-" .. realm

            -- Store both keys so lookups succeed for either form
            nameClassCache[shortName] = classFilename
            nameClassCache[fullName]  = classFilename

            -- Cache the realm for the short name
            GR_CacheName(fullName)
        end
    end

    if GRPresenceTrace then
        print("|cff00ff00[GR Trace]|r RefreshNameCache completed: " .. tostring(num) .. " entries.")
    end
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
-- Escape Lua pattern characters in a name
------------------------------------------------------------
local function EscapePattern(text)
    return gsub(text, "(%W)", "%%%1")
end

------------------------------------------------------------
-- Replace two plain names in a message with clickable links
------------------------------------------------------------
local function LinkTwoNames(msg, name1, name2)
    if name1 then
        msg = gsub(msg, EscapePattern(name1), GetColoredPlayerLink(name1), 1)
    end
    if name2 then
        msg = gsub(msg, EscapePattern(name2), GetColoredPlayerLink(name2), 1)
    end
    return msg
end

------------------------------------------------------------
-- Debug: unhandled system messages
------------------------------------------------------------
local GRDebugEnabled = false
local lastDebugMsg = nil

SLASH_GRDEBUG1 = "/grdebug"
SlashCmdList["GRDEBUG"] = function()
    GRDebugEnabled = not GRDebugEnabled
    print("|cff00ff00GuildRouter Debug:|r " .. (GRDebugEnabled and "ON" or "OFF"))
end

local function DebugUnhandledSystemMessage(msg)
    if not GRDebugEnabled then return end
    if msg == lastDebugMsg then return end
    lastDebugMsg = msg
    print("|cffff8800[GR Debug]|r Unhandled system message: " .. msg)
end

------------------------------------------------------------
-- Guild member check for login/out routing
------------------------------------------------------------
local function IsGuildMember(fullName)
    return nameClassCache[fullName] ~= nil
end

------------------------------------------------------------
-- Core filter: reroute and reformat guild-related messages
------------------------------------------------------------
local function FilterGuildMessages(self, event, msg, sender, ...)
    if not targetFrame then
        targetFrame = FindTargetFrame() or EnsureGuildTabExists()
    end

--    -- Real MOTD
--    if event == "GUILD_MOTD" then
--        targetFrame:AddMessage(msg)
--        return true
--    end

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
                if GRPresenceTrace then
                    print("|cffff8800[GR Trace]|r Presence ignored (mode=off): " .. msg)
                end
                return false
            end
            
            if GRPresenceTrace then
                print("|cffff8800[GR Trace]|r Presence lookup: fullName='" .. tostring(fullName) .. "'; lookup=" .. tostring(nameClassCache[fullName]))
            end

            ------------------------------------------------------------
            -- Guild-only mode: ignore non-guild members
            ------------------------------------------------------------
            local isGuild = IsGuildMember(fullName)
            if GRPresenceMode == "guild-only" and not isGuild then
                if GRPresenceTrace then
                    print("|cffff8800[GR Trace]|r Presence ignored (not guild): " .. msg)
                end
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

            ------------------------------------------------------------
            -- Route to Guild tab
            ------------------------------------------------------------
            if GRPresenceTrace then
                print("|cff00ff00[GR Trace]|r Presence routed: " .. formatted)
            end

            targetFrame:AddMessage(formatted)
            return true
        end


        -- Roster changes
        local actor, target
        actor, target = match(msg, "^(.-) has promoted (.-) to ")
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end
        actor, target = match(msg, "^(.-) has demoted (.-) to ")
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end
        actor, target = match(msg, "^(.-) has changed the guild rank of (.-) from ")
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end
        actor, target = match(msg, "^(.-) has changed the Officer Note for (.-)%.")
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end
        actor, target = match(msg, "^(.-) has changed the Public Note for (.-)%.")
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

    if DebugUnhandledSystemMessage then
        DebugUnhandledSystemMessage(msg)
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
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        elseif RequestGuildRoster then
            RequestGuildRoster()
        elseif GuildRoster then
            GuildRoster()
        else
            if GRPresenceTrace then
                print("|cffff8800[GR Trace]|r No roster request API available; waiting for GUILD_ROSTER_UPDATE.")
            end
        end
    end
end)

------------------------------------------------------------
-- Temporary debug: inspect internal caches (remove after debugging)
------------------------------------------------------------

SLASH_GRDBG1 = "/grdbg"
SlashCmdList["GRDBG"] = function()
    print("|cff00ff00[GR Debug]|r Inspecting caches...")

    -- GR_NameCache (global)
    local nameCount = 0
    for k,v in pairs(GR_NameCache or {}) do
        nameCount = nameCount + 1
    end
    print("  GR_NameCache entries: " .. nameCount)
    if nameCount > 0 then
        for k,v in pairs(GR_NameCache) do
            print("    sample GR_NameCache: " .. k .. " -> " .. tostring(v))
            break
        end
    end

    -- nameClassCache (local in file)
    if nameClassCache then
        local classCount = 0
        for k,v in pairs(nameClassCache) do
            classCount = classCount + 1
        end
        print("  nameClassCache entries: " .. classCount)
        if classCount > 0 then
            for k,v in pairs(nameClassCache) do
                print("    sample nameClassCache: " .. k .. " -> " .. tostring(v))
                break
            end
        end
    else
        print("  nameClassCache: nil (not visible)")
    end

    -- GR_GetCacheInfo() sanity check (if present)
    if GR_GetCacheInfo then
        local info = GR_GetCacheInfo()
        if info then
            print("  GR_GetCacheInfo() -> names=" .. tostring(info.names) .. ", class=" .. tostring(info.class) .. ", realm=" .. tostring(info.realm))
        else
            print("  GR_GetCacheInfo() -> nil")
        end
    else
        print("  GR_GetCacheInfo() not defined")
    end

    -- GR_Events
    print("  GR_Events table present: " .. tostring(GR_Events ~= nil))
end

------------------------------------------------------------
-- Status, reporting guild tab info
------------------------------------------------------------
local function GR_GetGuildTabInfo()
    for i = 1, NUM_CHAT_WINDOWS do
        local name = GetChatWindowInfo(i)
        if name == TARGET_TAB_NAME then
            local frame = _G["ChatFrame"..i]
            return {
                index = i,
                frame = frame,
                docked = frame.isDocked or false,
                visible = frame:IsShown(),
                locked = frame.isLocked or false,
            }
        end
    end
    return nil
end

------------------------------------------------------------
-- Status, mesage groups assigne dto Guild tab
------------------------------------------------------------
local function GR_GetMessageGroups(frame)
    local groups = {}
    if not frame then return groups end

    local id = frame:GetID()
    for _, group in ipairs({
        "SYSTEM", "GUILD", "OFFICER", "GUILD_ACHIEVEMENT",
        "CHANNEL", "SAY", "YELL", "WHISPER", "PARTY", "RAID"
    }) do
        if ChatFrame_ContainsMessageGroup(frame, group) then
            table.insert(groups, group)
        end
    end

    return groups
end

------------------------------------------------------------
-- Status, memory use
------------------------------------------------------------
local function GR_GetMemory()
    UpdateAddOnMemoryUsage()
    return GetAddOnMemoryUsage("GuildRouter")
end

------------------------------------------------------------
-- Status, cache size
------------------------------------------------------------
local function GR_GetCacheInfo()
    local nameCount = 0
    for _ in pairs(GR_NameCache or {}) do
        nameCount = nameCount + 1
    end

    local classCount = 0
    for _ in pairs(nameClassCache or {}) do
        classCount = classCount + 1
    end

    return {
        names = nameCount,
        class = classCount,
        realm = 0,
    }
end

------------------------------------------------------------
-- Status, eventy hook status
------------------------------------------------------------
local function GR_GetEventStatus()
    return {
        system  = GR_Events and GR_Events["CHAT_MSG_SYSTEM"]  and "yes" or "no",
        guild   = GR_Events and GR_Events["CHAT_MSG_GUILD"]   and "yes" or "no",
        ach     = GR_Events and GR_Events["CHAT_MSG_GUILD_ACHIEVEMENT"] and "yes" or "no",
        roster  = GR_Events and GR_Events["GUILD_ROSTER_UPDATE"] and "yes" or "no",
    }
end

------------------------------------------------------------
-- Status, last routed msg and last error
------------------------------------------------------------
function GR_RecordMessage(msg)
    GR_LastMessage = msg
end

function GR_RecordError(err)
    GR_LastError = err
end

------------------------------------------------------------
-- /grreset — recreate the Guild tab
------------------------------------------------------------
SLASH_GRRESET1 = "/grreset"
SlashCmdList["GRRESET"] = function()
    if ElvUI then
        ------------------------------------------------
        -- ElvUI: DO NOT DELETE OR RECREATE
        -- Just find the existing tab and repair it
        ------------------------------------------------
        local frame
        for i = 1, NUM_CHAT_WINDOWS do
            if GetChatWindowInfo(i) == TARGET_TAB_NAME then
                frame = _G["ChatFrame"..i]
                break
            end
        end

        if not frame then
            print("|cffff0000GuildRouter:|r Under ElvUI, the Guild tab must be created once manually.")
            print("Open Chat → Create New Window → Name it: Guild")
            return
        end

        targetFrame = frame
        ConfigureGuildTab(targetFrame)

        print("|cff00ff00GuildRouter:|r Guild tab repaired (ElvUI).")
        return
    end

    ------------------------------------------------
    -- Blizzard UI: full delete + recreate
    ------------------------------------------------
    for i = 1, NUM_CHAT_WINDOWS do
        if GetChatWindowInfo(i) == TARGET_TAB_NAME then
            FCF_Close(_G["ChatFrame"..i])
            break
        end
    end

    targetFrame = EnsureGuildTabExists()
    ConfigureGuildTab(targetFrame)
    SafeDock(targetFrame)

    print("|cff00ff00GuildRouter:|r Guild tab has been reset.")
end

------------------------------------------------------------
-- /grdelete — permanently delete the Guild tab
------------------------------------------------------------
SLASH_GRDELETE1 = "/grdelete"
SlashCmdList["GRDELETE"] = function()
    for i = 1, NUM_CHAT_WINDOWS do
        local name = GetChatWindowInfo(i)
        if name == TARGET_TAB_NAME then
            local frame = _G["ChatFrame"..i]

            -- Undock it first (required for deletion)
            if frame.isDocked then
                FCF_UnDockFrame(frame)
            end

            -- Close (this deletes the window when undocked)
            FCF_Close(frame)

            print("|cffff0000GuildRouter:|r Guild tab permanently deleted.")
            return
        end
    end
    print("|cffff8800GuildRouter:|r No Guild tab found to delete.")
end

------------------------------------------------------------
-- /grsources — reliable message group listing (Blizzard + ElvUI)
------------------------------------------------------------
SLASH_GRSOURCES1 = "/grsources"
SlashCmdList["GRSOURCES"] = function()
    local frame = FindTargetFrame()
    if not frame then
        print("|cffff0000GuildRouter:|r Guild tab not found.")
        return
    end

    print("|cff00ff00GuildRouter Sources for 'Guild' tab:|r")

    -- The message groups we care about
    local groups = {
        "SYSTEM",
        "GUILD",
        "OFFICER",
        "GUILD_ACHIEVEMENT",
    }

    local found = false
    for _, group in ipairs(groups) do
        if ChatFrame_ContainsMessageGroup(frame, group) then
            print("  • Message Group: " .. group)
            found = true
        end
    end

    if not found then
        print("  • (No message groups enabled)")
    end
end


------------------------------------------------------------
-- /grfix — repair Guild tab message groups
------------------------------------------------------------
SLASH_GRFIX1 = "/grfix"
SlashCmdList["GRFIX"] = function()
    local frame = FindTargetFrame() or EnsureGuildTabExists()

    ChatFrame_AddMessageGroup(frame, "SYSTEM")
    ChatFrame_AddMessageGroup(frame, "GUILD")
    ChatFrame_AddMessageGroup(frame, "OFFICER")
    ChatFrame_AddMessageGroup(frame, "GUILD_ACHIEVEMENT")

    SafeDock(frame)

    print("|cff00ff00GuildRouter:|r Guild tab sources repaired.")
end

------------------------------------------------------------
-- /grtest — simulate guild events
------------------------------------------------------------
SLASH_GRTEST1 = "/grtest"
SlashCmdList["GRTEST"] = function(arg)
    local frame = FindTargetFrame() or EnsureGuildTabExists()

    if arg == "join" then
        FilterGuildMessages(nil, "CHAT_MSG_SYSTEM", "ArcNineOhNine has joined the guild.")
        print("|cff00ff00GR Test:|r join fired.")
    elseif arg == "leave" then
        FilterGuildMessages(nil, "CHAT_MSG_SYSTEM", "ArcNineOhNine has left the guild.")
        print("|cff00ff00GR Test:|r leave fired.")
    elseif arg == "promote" then
        FilterGuildMessages(nil, "CHAT_MSG_SYSTEM", "ArcNineOhNine has promoted LeeroyJenkins to rank Member.")
        print("|cff00ff00GR Test:|r promote fired.")
    elseif arg == "demote" then
        FilterGuildMessages(nil, "CHAT_MSG_SYSTEM", "ArcNineOhNine has demoted LeeroyJenkins to rank Initiate.")
        print("|cff00ff00GR Test:|r demote fired.")
    elseif arg == "note" then
        FilterGuildMessages(nil, "CHAT_MSG_SYSTEM", "ArcNineOhNine has changed the Officer Note for LeeroyJenkins.")
        print("|cff00ff00GR Test:|r officer note fired.")
    elseif arg == "ach" then
        FilterGuildMessages(nil, "CHAT_MSG_GUILD_ACHIEVEMENT",
            "%s has earned the achievement %s!", "ArcNineOhNine-Proudmoore",
            "|cffffff00|Hachievement:6:Player-1234-00000000:1:1:1:1:4294967295:4294967295:4294967295:4294967295|h[Level 10]|h|r")
        print("|cff00ff00GR Test:|r achievement fired.")
    else
        print("|cff00ff00GuildRouter Test Commands:|r")
        print("  /grtest join")
        print("  /grtest leave")
        print("  /grtest promote")
        print("  /grtest demote")
        print("  /grtest note")
        print("  /grtest ach")
    end
end

------------------------------------------------------------
-- /grpresence — control presence announcements
------------------------------------------------------------
SLASH_GRPRESENCE1 = "/grpresence"
SlashCmdList["GRPRESENCE"] = function(arg)
    arg = arg and arg:lower() or ""

    if arg == "guild-only" then
        GRPresenceMode = "guild-only"
        GuildRouterDB.presenceMode = "guild-only"
        print("|cff00ff00GuildRouter:|r Presence mode set to guild-only.")
        return

    elseif arg == "all" then
        GRPresenceMode = "all"
        GuildRouterDB.presenceMode = "all"
        print("|cff00ff00GuildRouter:|r Presence mode set to all.")
        return

    elseif arg == "off" then
        GRPresenceMode = "off"
        GuildRouterDB.presenceMode = "off"
        print("|cff00ff00GuildRouter:|r Presence announcements disabled.")
        return

    elseif arg == "trace" then
        GRPresenceTrace = not GRPresenceTrace
        GuildRouterDB.presenceTrace = GRPresenceTrace
        print("|cff00ff00GuildRouter Trace:|r " .. (GRPresenceTrace and "ON" or "OFF"))
        return
    end

    print("|cff00ff00GuildRouter Presence Options:|r")
    print("  /grpresence guild-only  - Only guild members (default)")
    print("  /grpresence all         - Everyone")
    print("  /grpresence off         - Disable presence announcements")
    print("  /grpresence trace       - Toggle trace output")
end

------------------------------------------------------------
-- /grdock — safely dock the Guild tab
------------------------------------------------------------
SLASH_GRDOCK1 = "/grdock"
SlashCmdList["GRDOCK"] = function()
    local frame = FindTargetFrame()
    if not frame then
        print("|cffff0000GuildRouter:|r Guild tab not found.")
        return
    end

    SafeDock(frame)
    print("|cff00ff00GuildRouter:|r Guild tab docked.")
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

------------------------------------------------------------
-- Helper: detect ElvUI
------------------------------------------------------------
local isElvUI = (ElvUI ~= nil)

------------------------------------------------------------
-- Helper: find the Guild tab
------------------------------------------------------------
local function GR_GetGuildTabInfo()
    for i = 1, NUM_CHAT_WINDOWS do
        local name = GetChatWindowInfo(i)
        if name == TARGET_TAB_NAME then
            local frame = _G["ChatFrame"..i]
            return {
                index   = i,
                frame   = frame,
                docked  = frame.isDocked or false,
                visible = frame:IsShown(),
                locked  = frame.isLocked or false,
                parent  = frame:GetParent() and frame:GetParent():GetName() or "nil",
                width   = frame:GetWidth(),
                height  = frame:GetHeight(),
            }
        end
    end
    return nil
end

------------------------------------------------------------
-- Helper: message groups assigned to the Guild tab
------------------------------------------------------------
local function GR_GetMessageGroups(frame)
    local groups = {}
    if not frame then return groups end

    local id = frame:GetID()
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

------------------------------------------------------------
-- Helper: memory usage
------------------------------------------------------------
local function GR_GetMemory()
    UpdateAddOnMemoryUsage()
    return GetAddOnMemoryUsage("GuildRouter")
end

------------------------------------------------------------
-- Status, cache size (definitive)
------------------------------------------------------------
local function GR_GetCacheInfo()
    local nameCount = 0
    for _ in pairs(GR_NameCache or {}) do
        nameCount = nameCount + 1
    end

    local classCount = 0
    for _ in pairs(nameClassCache or {}) do
        classCount = classCount + 1
    end

    return {
        names = nameCount,
        class = classCount,
        realm = 0,
    }
end


------------------------------------------------------------
-- Helper: event hook status
------------------------------------------------------------
local function GR_GetEventStatus()
    return {
        system = GR_Events and GR_Events["CHAT_MSG_SYSTEM"] and "yes" or "no",
        guild  = GR_Events and GR_Events["CHAT_MSG_GUILD"] and "yes" or "no",
        ach    = GR_Events and GR_Events["CHAT_MSG_GUILD_ACHIEVEMENT"] and "yes" or "no",
        roster = GR_Events and GR_Events["GUILD_ROSTER_UPDATE"] and "yes" or "no",
    }
end

------------------------------------------------------------
-- Last routed message / last error tracking
------------------------------------------------------------
GR_LastMessage = GR_LastMessage or "none"
GR_LastError   = GR_LastError   or "none"

function GR_RecordMessage(msg)
    GR_LastMessage = msg
end

function GR_RecordError(err)
    GR_LastError = err
end

------------------------------------------------------------
-- /grstatus — short (default) or full diagnostics
------------------------------------------------------------
SLASH_GRSTATUS1 = "/grstatus"
SlashCmdList["GRSTATUS"] = function(msg)
    local full = (msg and msg:lower():match("full"))

    print("|cff00ff00GuildRouter Status|r")
    print("----------------------------------------")

    ------------------------------------------------
    -- UI mode
    ------------------------------------------------
    print("UI mode: " .. (isElvUI and "ElvUI" or "Blizzard"))

    ------------------------------------------------
    -- Guild tab info
    ------------------------------------------------
    local info = GR_GetGuildTabInfo()
    if info then
        print("Guild tab: ChatFrame" .. info.index .. (info.docked and " (docked)" or " (undocked)"))
    else
        print("Guild tab: |cffff0000NOT FOUND|r")
    end

    ------------------------------------------------
    -- Short mode ends here unless full requested
    ------------------------------------------------
    if not full then
        print("Presence mode: " .. tostring(GRPresenceMode))
        print("Trace mode:    " .. tostring(GRPresenceTrace))

        if info then
            local groups = GR_GetMessageGroups(info.frame)
            print("Message groups: " .. #groups .. " assigned")
        end

        print("Last routed: " .. (GR_LastMessage or "none"))
        print("Last error:  " .. (GR_LastError or "none"))
        return
    end

    ------------------------------------------------
    -- FULL MODE BELOW
    ------------------------------------------------
    print("")
    print("FULL DIAGNOSTICS")
    print("----------------------------------------")

    ------------------------------------------------
    -- Detailed Guild tab info
    ------------------------------------------------
    if info then
        print("Guild tab details:")
        print("  Frame: ChatFrame" .. info.index)
        print("  Docked:  " .. tostring(info.docked))
        print("  Visible: " .. tostring(info.visible))
        print("  Locked:  " .. tostring(info.locked))
        print("  Parent:  " .. info.parent)
        print("  Size:    " .. string.format("%.0f x %.0f", info.width, info.height))
    end

    ------------------------------------------------
    -- Message groups
    ------------------------------------------------
    if info then
        print("Message groups:")
        local groups = GR_GetMessageGroups(info.frame)
        if #groups == 0 then
            print("  |cffff0000None assigned|r")
        else
            for _, g in ipairs(groups) do
                print("  " .. g)
            end
        end
    end

    ------------------------------------------------
    -- SavedVariables
    ------------------------------------------------
    print("SavedVariables:")
    print("  presenceMode  = " .. tostring(GRPresenceMode))
    print("  presenceTrace = " .. tostring(GRPresenceTrace))

    ------------------------------------------------
    -- Cache info
    ------------------------------------------------
    local cache = GR_GetCacheInfo()
    print("Caches:")
    print("  Name cache:  " .. cache.names)
    print("  Class cache: " .. cache.class)
    print("  Realm cache: " .. cache.realm)

    ------------------------------------------------
    -- Memory usage
    ------------------------------------------------
    print("Memory usage: " .. string.format("%.1f KB", GR_GetMemory()))

    ------------------------------------------------
    -- Event hooks
    ------------------------------------------------
    local ev = GR_GetEventStatus()
    print("Events hooked:")
    print("  CHAT_MSG_SYSTEM:            " .. ev.system)
    print("  CHAT_MSG_GUILD:             " .. ev.guild)
    print("  CHAT_MSG_GUILD_ACHIEVEMENT: " .. ev.ach)
    print("  GUILD_ROSTER_UPDATE:        " .. ev.roster)

    ------------------------------------------------
    -- Last message / error
    ------------------------------------------------
    print("Last routed: " .. (GR_LastMessage or "none"))
    print("Last error:  " .. (GR_LastError or "none"))

    ------------------------------------------------
    -- Version (optional)
    ------------------------------------------------
    if GR_VERSION then
        print("Version: " .. GR_VERSION)
    end
end

------------------------------------------------------------
-- /grforceroster — force acquire the guild roster
------------------------------------------------------------
SLASH_GRFORCERO1 = "/grforceroster"
SlashCmdList["GRFORCERO"] = function()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
        print("|cff00ff00GuildRouter:|r Requested roster via C_GuildInfo.GuildRoster().")
    elseif GuildRoster then
        GuildRoster()
        print("|cff00ff00GuildRouter:|r Requested roster via GuildRoster().")
    elseif RequestGuildRoster then
        RequestGuildRoster()
        print("|cff00ff00GuildRouter:|r Requested roster via RequestGuildRoster().")
    else
        print("|cffff0000GuildRouter:|r No roster API available.")
    end
end

------------------------------------------------------------
-- /grhelp — list all GuildRouter commands
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
    print(" /grdebug    - toggle debug mode for unhandled system messages")
    print(" /grhelp     - show this command list")
end
