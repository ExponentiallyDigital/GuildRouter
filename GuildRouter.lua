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
-- Local references (faster than global lookups)
------------------------------------------------------------
local TARGET_TAB_NAME = "Guild"

local _G                = _G
local NUM_CHAT_WINDOWS  = NUM_CHAT_WINDOWS
local GetChatWindowInfo = GetChatWindowInfo
local FCF_OpenNewWindow = FCF_OpenNewWindow
local FCF_SetLocked     = FCF_SetLocked

local IsInGuild         = IsInGuild
local GetNumGuildMembers= GetNumGuildMembers
local GetGuildRosterInfo= GetGuildRosterInfo
local RAID_CLASS_COLORS = RAID_CLASS_COLORS

local GetTime           = GetTime
local format            = string.format
local match             = string.match
local find              = string.find
local gsub              = string.gsub
local wipe              = wipe

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
-- Create the "Guild" tab if it doesn't exist
------------------------------------------------------------
local function EnsureGuildTabExists()
    local frame = FindTargetFrame()
    if frame then
        return frame -- Do NOT modify existing tabs
    end

    -- Create the tab
    frame = FCF_OpenNewWindow(TARGET_TAB_NAME)
    FCF_SetLocked(frame, true)

    -- Configure it once
    ConfigureGuildTab(frame)
    return frame
end


------------------------------------------------------------
-- Configure the Guild tab ONLY when we create it
------------------------------------------------------------
local function ConfigureGuildTab(frame)
    -- Enable guild chat
    ChatFrame_AddChannel(frame, "Guild")

    -- Enable officer chat (if player has permission)
    ChatFrame_AddChannel(frame, "Officer")

    -- Enable system messages
    ChatFrame_AddMessageGroup(frame, "SYSTEM")

    -- Enable guild achievements / announcements
    ChatFrame_AddMessageGroup(frame, "GUILD_ACHIEVEMENT")
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
-- fullName: "Name-Realm" (realm kept for whispering)
------------------------------------------------------------
local function GetColoredPlayerLink(fullName)
    if not fullName then return "" end

    -- Safe realm strip: "Name-Realm" -> "Name"
    local nameOnly = fullName:gsub("%-.*", "")

    local class = nameClassCache[fullName]
    if class then
        local color = RAID_CLASS_COLORS[class]
        if color and color.colorStr then
            return "|Hplayer:" .. fullName .. "|h|c" .. color.colorStr .. nameOnly .. "|r|h"
        end
    end

    -- Fallback: clickable but white
    return "|Hplayer:" .. fullName .. "|h[" .. nameOnly .. "]|h"
end

------------------------------------------------------------
-- Escape Lua pattern characters in a name (for safe gsub)
------------------------------------------------------------
local function EscapePattern(text)
    return gsub(text, "(%W)", "%%%1")
end

------------------------------------------------------------
-- Replace two plain names in a message with clickable links
-- (Used for roster changes: actor + target)
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
-- Core filter: reroute and reformat guild-related messages
------------------------------------------------------------
local function FilterGuildMessages(self, event, msg, sender, ...)
    -- Ensure the Guild tab exists
    if not targetFrame then
        targetFrame = FindTargetFrame() or EnsureGuildTabExists()
    end

    --------------------------------------------------------
    -- Real MOTD (sent manually from GUILD_MOTD event)
    --------------------------------------------------------
    if event == "GUILD_MOTD" then
        targetFrame:AddMessage(msg)
        return true
    end

    --------------------------------------------------------
    -- System messages (join/leave, roster changes, MOTD echo)
    --------------------------------------------------------
    if event == "CHAT_MSG_SYSTEM" then
        -- Suppress MOTD echo
        if find(msg, "Message of the Day") then
            return true
        end

        ----------------------------------------------------
        -- Join / Leave
        ----------------------------------------------------
        local joinName  = match(msg, "^(.-) has joined the guild")
        local leaveName = match(msg, "^(.-) has left the guild")
        local name = joinName or leaveName

        if name then
            local formatted = GetColoredPlayerLink(name) ..
                (joinName and " has joined the guild." or " has left the guild.")

            -- Prevent duplicates fired close together
            local now = GetTime()
            if formatted == lastJoinLeaveMessage and (now - lastJoinLeaveTime) < 1 then
                return true
            end

            lastJoinLeaveMessage = formatted
            lastJoinLeaveTime    = now

            targetFrame:AddMessage(formatted)
            return true
        end

        ----------------------------------------------------
        -- Roster changes (actor + target names)
        ----------------------------------------------------
        local actor, target

        -- Promote: "A has promoted B to rank ..."
        actor, target = match(msg, "^(.-) has promoted (.-) to ")
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end

        -- Demote: "A has demoted B to rank ..."
        actor, target = match(msg, "^(.-) has demoted (.-) to ")
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end

        -- Rank change: "A has changed the guild rank of B from ..."
        actor, target = match(msg, "^(.-) has changed the guild rank of (.-) from ")
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end

        -- Officer note: "A has changed the Officer Note for B."
        actor, target = match(msg, "^(.-) has changed the Officer Note for (.-)%.")
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end

        -- Public note: "A has changed the Public Note for B."
        actor, target = match(msg, "^(.-) has changed the Public Note for (.-)%.")
        if actor and target then
            targetFrame:AddMessage(LinkTwoNames(msg, actor, target))
            return true
        end
    end

    --------------------------------------------------------
    -- Guild achievements
    --------------------------------------------------------
    if event == "CHAT_MSG_GUILD_ACHIEVEMENT" then
        local player = sender or "Unknown"
        local achievementLink = ...

        local formatted = format(msg, GetColoredPlayerLink(player), achievementLink)
        targetFrame:AddMessage(formatted)
        return true
    end
    
    -- Nothing matched, let WoW handle it normally
    DebugUnhandledSystemMessage(msg)
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
-- Debug Mode
-- /grdebug toggles printing unhandled system messages
------------------------------------------------------------
local GRDebugEnabled = false
local lastDebugMsg = nil

SLASH_GRDEBUG1 = "/grdebug"
SlashCmdList["GRDEBUG"] = function()
    GRDebugEnabled = not GRDebugEnabled
    print("|cff00ff00GuildRouter Debug:|r " .. (GRDebugEnabled and "ON" or "OFF"))
end

-- Debug hook: prints unhandled CHAT_MSG_SYSTEM lines
local function DebugUnhandledSystemMessage(msg)
    if not GRDebugEnabled then return end
    if msg == lastDebugMsg then return end -- avoid spam
    lastDebugMsg = msg
    print("|cffff8800[GR Debug]|r Unhandled system message: " .. msg)
end
