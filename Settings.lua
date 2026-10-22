local ADDON, ns = ...
local L = ns.L

-- Blizzard's own Settings window only gets a small page for Thumber: a pointer to the
-- real settings window (Options.lua), which is where everything lives.

local panel = CreateFrame("Frame")
panel.name = "Thumber"
local category -- new Settings API category, when available

local titleFS = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
titleFS:SetPoint("TOPLEFT", 16, -16)
titleFS:SetText("Thumber")

local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
sub:SetPoint("TOPLEFT", 16, -44)
sub:SetPoint("RIGHT", -16, 0)
sub:SetJustifyH("LEFT")
sub:SetSpacing(3)
sub:SetText(L["Thumber's settings have their own window: tooltips and chat, the badges above nameplates, the group alert, sharing, and keybinds, each with a live preview."])

local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
open:SetSize(200, 26)
open:SetScript("OnShow", function(self)
	local fs = self:GetFontString()
	self:SetWidth(math.max(200, math.ceil(fs and fs:GetStringWidth() or 150) + 32))
end)
open:SetPoint("TOPLEFT", 16, -96)
open:SetText(L["Open Thumber settings"])
open:SetScript("OnClick", function() if ns.OpenOptions then ns.OpenOptions() end end)

local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
hint:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -10)
hint:SetText(L["You can also type /thumber config, or right-click the minimap button."])

panel.OnRefresh = function() end
panel.OnCommit  = function() end
panel.OnDefault = function() end

----------------------------------------------------------------------
-- Register + open helper (supports both the new and legacy options APIs)
----------------------------------------------------------------------
if Settings and Settings.RegisterCanvasLayoutCategory then
	category = Settings.RegisterCanvasLayoutCategory(panel, "Thumber")
	Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
	InterfaceOptions_AddCategory(panel)
end

-- Everything that used to open Blizzard's page (the slash command, the minimap button,
-- the marks window's gear) now toggles the settings window.
function Thumber_OpenSettings()
	if ns.ToggleOptions then ns.ToggleOptions() end
end
