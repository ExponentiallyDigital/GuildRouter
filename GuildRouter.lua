-- Guild Router
-- Routes guild MOTD, join/leave, achievements, and roster changes ONLY to the tab named "Guild"
--
-- to test: achieve toon name is clickable

local TARGET_TAB_NAME = "Guild"
local targetFrame = nil
local lastJoinLeaveMessage = nil
local lastJoinLeaveTime = 0

local function FindTargetFrame()
    for i = 1, NUM_CHAT_WINDOWS do
        local name = GetChatWindowInfo(i)
        if name == TARGET_TAB_NAME then
            return _G["ChatFrame"..i]
        end
    end
    return nil
end

local function FilterGuildMessages(self, event, msg, sender, ...)
    if not targetFrame then
        targetFrame = FindTargetFrame()
    end
    if not targetFrame then
        return false
    end

    -- Ignore MOTD echoes in CHAT_MSG_SYSTEM
    if msg:find("Message of the Day") then
        return true
    end

    -- 2. Guild join/leave (clickable names)
    local joinName = msg:match("^(.-) has joined the guild")
    local leaveName = msg:match("^(.-) has left the guild")
    local name = joinName or leaveName
    if name then
        local formatted
        if joinName then
            formatted = GetColoredPlayerLink(name) .. " has joined the guild."
        else
            formatted = GetColoredPlayerLink(name) .. " has left the guild."
        end

        -- Prevent duplicates (Blizzard fires this message multiple times)
        local now = GetTime()
        if formatted == lastJoinLeaveMessage and (now - lastJoinLeaveTime) < 1 then
            return true -- suppress duplicate
        end

        lastJoinLeaveMessage = formatted
        lastJoinLeaveTime = now

        targetFrame:AddMessage(formatted)
        return true
    end

    -- 3. Guild achievements (clickable names + clickable achievement)
    if event == "CHAT_MSG_GUILD_ACHIEVEMENT" then
        local player = sender or "Unknown"
        local achievementLink = ...
        -- Create clickable player link
        local playerLink = GetColoredPlayerLink(player)
        -- Format exactly like Blizzard
        local formatted = format(msg, playerLink, achievementLink)
        targetFrame:AddMessage(formatted)
        return true
    end

    -- 4. Roster changes (plain text, as requested)
    if msg:find("promoted") or msg:find("demoted") or msg:find("changed the guild rank")
       or msg:find("changed the Officer Note") or msg:find("changed the Public Note") then
        targetFrame:AddMessage(msg)
        return true
    end

    return false
end

local function GetColoredPlayerLink(fullName)
    -- fullName may include realm, e.g. "Arcette-Jubei'Thos"
    local nameOnly = fullName:gsub("%-.*", "") -- for display only
    -- Find class from guild roster
    if IsInGuild() then
        local num = GetNumGuildMembers()
        for i = 1, num do
            local rosterName, _, _, _, _, _, _, _, _, _, classFilename = GetGuildRosterInfo(i)
            if rosterName == fullName then
                local color = RAID_CLASS_COLORS[classFilename]
                if color then
                    local hex = color.colorStr -- Blizzard provides the hex code
                    return "|Hplayer:" .. fullName .. "|h|c" .. hex .. nameOnly .. "|r|h"
                end
            end
        end
    end
    -- fallback: clickable but white
    return "|Hplayer:" .. fullName .. "|h[" .. nameOnly .. "]|h"
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", FilterGuildMessages)
ChatFrame_AddMessageEventFilter("CHAT_MSG_GUILD_ACHIEVEMENT", FilterGuildMessages)

local f = CreateFrame("Frame")
f:RegisterEvent("GUILD_MOTD")
f:SetScript("OnEvent", function(_, _, msg)
    FilterGuildMessages(nil, "GUILD_MOTD", msg)
end)
