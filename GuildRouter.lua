-- Guild Router
-- Routes guild MOTD, join/leave, achievements, and roster changes to the tab named "Guild".
--      All player names (except in roster changes) are class-coloured and clickable.
--      Join/leave messages are de-duplicated (Blizzard fires them multiple times).
-- Architecture:
--   To test:
--      1. achieve toon name is clickable
--      2. what to do if chat tab doesn't exist, craete one?
--      3. all toon names are class coloured

local TARGET_TAB_NAME = "Guild"
local targetFrame = nil

-- Used to suppress duplicate join/leave messages
local lastJoinLeaveMessage = nil
local lastJoinLeaveTime = 0

-- Cache: fullName → classFilename
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
-- Create the Guild tab if it doesn't exist
------------------------------------------------------------
local function EnsureGuildTabExists()
    local frame = FindTargetFrame()
    if frame then return frame end

    frame = FCF_OpenNewWindow(TARGET_TAB_NAME)
    FCF_SetLocked(frame, true)
    return frame
end

------------------------------------------------------------
-- Update name → class cache when roster changes
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
-- Build a class-coloured clickable player link
------------------------------------------------------------
local function GetColoredPlayerLink(fullName)
    local nameOnly = fullName:gsub("%-.*", "") -- hide realm in display
    local class = nameClassCache[fullName]

    if class and RAID_CLASS_COLORS[class] then
        local hex = RAID_CLASS_COLORS[class].colorStr
        return "|Hplayer:" .. fullName .. "|h|c" .. hex .. nameOnly .. "|r|h"
    end

    -- fallback: clickable but white
    return "|Hplayer:" .. fullName .. "|h[" .. nameOnly .. "]|h"
end

------------------------------------------------------------
-- Replace all player names in a message with clickable links
-- (Used for roster changes where two names may appear)
------------------------------------------------------------
local function ReplaceNamesWithLinks(msg)
    for fullName in pairs(nameClassCache) do
        local nameOnly = fullName:gsub("%-.*", "")
        msg = msg:gsub(nameOnly, GetColoredPlayerLink(fullName))
    end
    return msg
end

------------------------------------------------------------
-- Main filter: reroute and reformat guild-related messages
------------------------------------------------------------
local function FilterGuildMessages(self, event, msg, sender, ...)
    -- Ensure the Guild tab exists
    if not targetFrame then
        targetFrame = FindTargetFrame() or EnsureGuildTabExists()
    end

    --------------------------------------------------------
    -- Ignore MOTD echoes (we handle the real MOTD below)
    --------------------------------------------------------
    if msg:find("Message of the Day") then
        return true
    end

    --------------------------------------------------------
    -- Join / Leave messages
    --------------------------------------------------------
    local joinName = msg:match("^(.-) has joined the guild")
    local leaveName = msg:match("^(.-) has left the guild")
    local name = joinName or leaveName

    if name then
        local formatted = GetColoredPlayerLink(name) ..
            (joinName and " has joined the guild." or " has left the guild.")

        -- Prevent duplicates
        local now = GetTime()
        if formatted == lastJoinLeaveMessage and (now - lastJoinLeaveTime) < 1 then
            return true
        end

        lastJoinLeaveMessage = formatted
        lastJoinLeaveTime = now

        targetFrame:AddMessage(formatted)
        return true
    end

    --------------------------------------------------------
    -- Achievement messages
    --------------------------------------------------------
    if event == "CHAT_MSG_GUILD_ACHIEVEMENT" then
        local player = sender or "Unknown"
        local achievementLink = ...
        local formatted = format(msg, GetColoredPlayerLink(player), achievementLink)

        targetFrame:AddMessage(formatted)
        return true
    end

    --------------------------------------------------------
    -- Roster changes (now clickable + class coloured)
    --------------------------------------------------------
    if msg:find("promoted") or msg:find("demoted")
       or msg:find("changed the guild rank")
       or msg:find("changed the Officer Note")
       or msg:find("changed the Public Note") then

        msg = ReplaceNamesWithLinks(msg)
        targetFrame:AddMessage(msg)
        return true
    end

    return false
end

------------------------------------------------------------
-- Hook chat events
------------------------------------------------------------
ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", FilterGuildMessages)
ChatFrame_AddMessageEventFilter("CHAT_MSG_GUILD_ACHIEVEMENT", FilterGuildMessages)

------------------------------------------------------------
-- Refresh name cache when roster updates
------------------------------------------------------------
local rosterFrame = CreateFrame("Frame")
rosterFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
rosterFrame:SetScript("OnEvent", RefreshNameCache)

------------------------------------------------------------
-- Show the real MOTD in the Guild tab
------------------------------------------------------------
local motdFrame = CreateFrame("Frame")
motdFrame:RegisterEvent("GUILD_MOTD")
motdFrame:SetScript("OnEvent", function(_, _, msg)
    FilterGuildMessages(nil, "GUILD_MOTD", msg)
end)
