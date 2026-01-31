local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event, addon)
    if addon ~= "GuildRouter" then return end
    ------------------------------------------------------------
    -- Interface Options Panel
    ------------------------------------------------------------
    local panel = CreateFrame("Frame", "GuildRouterOptionsPanel", UIParent)
    panel.name = "GuildRouter"
    -- When the panel is shown, refresh the status text
    panel:SetScript("OnShow", function()
        if cbShow then
            cbShow:SetChecked(GRShowLoginLogout)
        end
        if cbTrace then
            cbTrace:SetChecked(GRPresenceTrace)
        end
        if panel.statusBox then
            panel.statusBox:SetText(GR_GetStatusText())
        end
        if panel.helpBox then
            panel.helpBox:SetText(GR_GetHelpText())
        end
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)

    ------------------------------------------------------------
    -- Helper: Create Checkbox
    ------------------------------------------------------------
    local function CreateCheckbox(parent, label, tooltip, x, y, initial, onClick)
        local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", x, y)
        cb.Text:SetText(label)
        cb.tooltipText = tooltip
        cb:SetChecked(initial)
        cb:SetScript("OnClick", function(self)
            onClick(self:GetChecked())
        end)
        return cb
    end

    ------------------------------------------------------------
    -- Helper: Create Dropdown
    ------------------------------------------------------------
    local function CreateDropdown(parent, label, items, initialValue, onSelect, x, y)
        local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
        dd:SetPoint("TOPLEFT", x, y)
        local title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("BOTTOMLEFT", dd, "TOPLEFT", 20, 0)
        title:SetText(label)
        UIDropDownMenu_SetWidth(dd, 160)
        UIDropDownMenu_Initialize(dd, function(self, level)
            for _, item in ipairs(items) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = item.text
                info.value = item.value
                info.func = function()
                    UIDropDownMenu_SetSelectedValue(dd, item.value)
                    onSelect(item.value)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetSelectedValue(dd, initialValue)
        return dd
    end

    ------------------------------------------------------------
    -- Helper: display scrollable panels for status and help text
    ------------------------------------------------------------
    local function CreateTextPanel(parent, labelText, x, y, height, getTextFunc)
        local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOPLEFT", x, y)
        label:SetText(labelText)

        -- ScrollFrame
        local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -5)
        scrollFrame:SetSize(500, height)

        -- Container frame (REQUIRED)
        local container = CreateFrame("Frame", nil, scrollFrame)
        container:SetSize(480, height)

        -- Text inside container
        local content = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        content:SetPoint("TOPLEFT", 0, 0)
        content:SetJustifyH("LEFT")
        content:SetJustifyV("TOP")
        content:SetWidth(480)
        content:SetText(getTextFunc())

        -- Now safe to set scroll child
        scrollFrame:SetScrollChild(container)

        return scrollFrame, content
    end

    ------------------------------------------------------------
    -- Helper: display status text for UI
    ------------------------------------------------------------
    function GR_GetStatusText()
        return table.concat(GR_BuildStatusLines(), "\n")
    end

    ------------------------------------------------------------
    -- Helper: display help text in UI
    ------------------------------------------------------------
    function GR_GetHelpText()
        return table.concat(GR_HELP_TEXT, "\n")
    end

    ------------------------------------------------------------
    -- 1. Checkbox: Show login/logout messages
    ------------------------------------------------------------
    local cbShow = CreateCheckbox(
        panel,
        "Show login/logout messages",
        "Toggle visibility of guild member login/logout notifications.",
        20, -20,
        GRShowLoginLogout,
        function(val)
            GRShowLoginLogout = val
            GuildRouterDB = GuildRouterDB or {}; GuildRouterDB.showLoginLogout = val
        end
    )

    ------------------------------------------------------------
    -- 2. Dropdown: Presence mode
    ------------------------------------------------------------
    local presenceItems = {
        { text = "Off",        value = "off" },
        { text = "Guild-only", value = "guild-only" },
        { text = "All",        value = "all" },
    }

    local initialPresenceMode =
        (GRPresenceMode == "guild-only" or GRPresenceMode == "off" or GRPresenceMode == "all")
        and GRPresenceMode
        or "guild-only"

    local ddPresence = CreateDropdown(
        panel,
        "Show login/logout messages for:",
        presenceItems,
        initialPresenceMode,
        function(val)
            GRPresenceMode = val
            GuildRouterDB = GuildRouterDB or {}; GuildRouterDB.presenceMode = val
        end,
        20, -70
    )

    ------------------------------------------------------------
    -- 3. Checkbox: Debug trace
    ------------------------------------------------------------
    local cbTrace = CreateCheckbox(
        panel,
        "Debug: enable presence trace",
        "Print detailed presence routing debug information.",
        20, -110,
        GRPresenceTrace,
        function(val)
            GRPresenceTrace = val
            GuildRouterDB = GuildRouterDB or {}; GuildRouterDB.presenceTrace = val
        end
    )

    ------------------------------------------------------------
    -- Status Box (shows /grstatus output)
    ------------------------------------------------------------
    local statusLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusLabel:SetPoint("TOPLEFT", 20, -200)
    statusLabel:SetText("Current Status (/grstatus):")
    local statusBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    statusBox:SetPoint("TOPLEFT", statusLabel, "BOTTOMLEFT", 0, -5)
    statusBox:SetSize(500, 200)
    statusBox:SetMultiLine(true)
    statusBox:SetAutoFocus(false)
    statusBox:SetFontObject("GameFontHighlightSmall")
    statusBox:SetCursorPosition(0)
    statusBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    panel.statusBox = statusBox

    ------------------------------------------------------------
    -- Display status and command line text
    ------------------------------------------------------------
    panel.helpBoxFrame, panel.helpBox = CreateTextPanel(panel, "Slash Commands (/grhelp):", 20, -420, 160, GR_GetHelpText)
end)
