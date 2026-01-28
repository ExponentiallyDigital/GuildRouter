-- Guild Router
-- Routes guild MOTD, join/leave, achievements, and roster changes to the tab named "Guild".
--      All player names (except in roster changes) are class-coloured and clickable.
--      Join/leave messages are de-duplicated (Blizzard fires them multiple times).
-- Architecture:
--   To test:
--      1. achievement toon name is clickable
--      2. if Guild tab doesn't exist, it is created and set up correctly
--      3. all toon names are class coloured
--

------------------------------------------------------------
-- Local references
------------------------------------------------------------
local TARGET_TAB_NAME = "Guild"

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

------------------------------------------------------------
-- Presence announcement settings
------------------------------------------------------------
local GRPresenceMode = "guild-only"   -- "guild-only", "all", "off"
local GRPresenceTrace = false

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
------------------------------------------------------------
local function RefreshNameCache()
    if not IsInGuild() then return end

    wipe(nameClassCache)
    local num = GetNumGuildMembers()

    for i = 1, num do
        local name, _, _, _, _, _, _, _, _, _, classFilename = GetGuildRosterInfo(i)
        if name and classFilename then
            nameClassCache[name] = classFilename
        end
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

    -- Real MOTD
    if event == "GUILD_MOTD" then
        targetFrame:AddMessage(msg)
        return true
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
        local onlineName  = match(msg, "^(.-) has come online%.$")
        local offlineName = match(msg, "^(.-) has gone offline%.$")

        local name = onlineName or offlineName
        if name then
            -- Presence mode: off
            if GRPresenceMode == "off" then
                if GRPresenceTrace then
                    print("|cffff8800[GR Trace]|r Presence ignored (mode=off): " .. msg)
                end
                return false
            end

            local isGuild = IsGuildMember(name)

            -- Presence mode: guild-only
            if GRPresenceMode == "guild-only" and not isGuild then
                if GRPresenceTrace then
                    print("|cffff8800[GR Trace]|r Presence ignored (not guild): " .. msg)
                end
                return false
            end

            -- Presence mode: all OR guild-only + guild member
            if GRPresenceTrace then
                print("|cff00ff00[GR Trace]|r Presence routed: " .. msg)
            end

            local formatted = GetColoredPlayerLink(name) ..
                (onlineName and " has come online." or " has gone offline.")

            -- De-duplicate
            local now = GetTime()
            if formatted == lastJoinLeaveMessage and (now - lastJoinLeaveTime) < 1 then
                return true
            end

            lastJoinLeaveMessage = formatted
            lastJoinLeaveTime    = now

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
ChatFrame_AddMessageEventFilter("CHAT_MSG_GUILD_ACHIEVEMENT", FilterGuildMessages)

------------------------------------------------------------
-- Refresh name cache when the roster updates
------------------------------------------------------------
local rosterFrame = CreateFrame("Frame")
rosterFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
rosterFrame:SetScript("OnEvent", RefreshNameCache)

------------------------------------------------------------
-- Show the real guild MOTD in the Guild tab
------------------------------------------------------------
local motdFrame = CreateFrame("Frame")
motdFrame:RegisterEvent("GUILD_MOTD")
motdFrame:SetScript("OnEvent", function(_, _, msg)
    FilterGuildMessages(nil, "GUILD_MOTD", msg)
end)

------------------------------------------------------------
-- Auto-create Guild tab on login
------------------------------------------------------------
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    targetFrame = FindTargetFrame() or EnsureGuildTabExists()
    RefreshNameCache()
end)

------------------------------------------------------------
-- /grreset — delete + recreate the Guild tab
------------------------------------------------------------
SLASH_GRRESET1 = "/grreset"
SlashCmdList["GRRESET"] = function()
    for i = 1, NUM_CHAT_WINDOWS do
        if GetChatWindowInfo(i) == TARGET_TAB_NAME then
            FCF_Close(_G["ChatFrame"..i])
            break
        end
    end

    targetFrame = EnsureGuildTabExists()
    SafeDock(targetFrame)

    print("|cff00ff00GuildRouter:|r Guild tab has been reset.")
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
        print("|cff00ff00GuildRouter:|r Presence mode set to guild-only.")
        return
    elseif arg == "all" then
        GRPresenceMode = "all"
        print("|cff00ff00GuildRouter:|r Presence mode set to all.")
        return
    elseif arg == "off" then
        GRPresenceMode = "off"
        print("|cff00ff00GuildRouter:|r Presence announcements disabled.")
        return
    elseif arg == "trace" then
        GRPresenceTrace = not GRPresenceTrace
        print("|cff00ff00GuildRouter Trace:|r " .. (GRPresenceTrace and "ON" or "OFF"))
        return
    end

    print("|cff00ff00GuildRouter Presence Options:|r")
    print("  /grpresence guild-only  - Only guild members")
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
-- /grhelp — list all GuildRouter commands
------------------------------------------------------------
SLASH_GRHELP1 = "/grhelp"
SlashCmdList["GRHELP"] = function()
    print("|cff00ff00GuildRouter Commands:|r")
    print(" /grreset    - Delete and recreate the Guild tab")
    print(" /grdock     - Dock the Guild tab if it’s not visible")
    print(" /grfix      - Repair Guild tab message groups and dock it")
    print(" /grsources  - Show message groups/channels for the Guild tab")
    print(" Debug")
    print(" /grtest     - Simulate guild events (join, leave, promote, demote, note, ach)")
    print(" /grpresence - Control login/logout announcements (guild-only, all, off, trace)")
    print(" /grdebug    - Toggle debug mode for unhandled system messages")
    print(" /grhelp     - Show this command list")
end
