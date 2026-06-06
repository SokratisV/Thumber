local ADDON = ...

local panel = CreateFrame("Frame")
panel.name = "Thumber"
local category -- new Settings API category, when available

local function db()
	ThumberDB = ThumberDB or {}
	return ThumberDB
end

----------------------------------------------------------------------
-- Widgets
----------------------------------------------------------------------
local function AddCheck(label, get, set, x, y)
	local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", x, y)
	local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
	fs:SetText(label)
	cb:SetScript("OnShow", function(self) self:SetChecked(get() and true or false) end)
	cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
	return cb
end

-- A click-then-press-a-key capture row bound directly to a Bindings.xml action.
local function AddBindRow(bindingName, label, x, y)
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOPLEFT", x, y)
	title:SetText(label)

	local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	btn:SetSize(175, 24)
	btn:SetPoint("TOPLEFT", x, y - 16)

	local function refresh()
		if btn.listening then return end
		local k = GetBindingKey(bindingName)
		btn:SetText(k and ("|cff00ff00" .. k .. "|r") or "Click to set key")
	end

	local function clear()
		local o1, o2 = GetBindingKey(bindingName)
		if o1 then SetBinding(o1) end
		if o2 then SetBinding(o2) end
		SaveBindings(GetCurrentBindingSet())
		btn.listening = false; btn:EnableKeyboard(false)
		refresh()
	end

	btn:SetScript("OnShow", refresh)
	btn:SetScript("OnHide", function(self)
		self.listening = false
		self:EnableKeyboard(false)
		-- Make sure we never leave the keyboard "consumed" if the panel is closed
		-- mid-capture. SetPropagateKeyboardInput is protected in combat — skip then.
		if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
	end)
	btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Left-click: set key\nRight-click: clear", nil, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	btn:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then clear(); return end
		-- SetPropagateKeyboardInput is protected and blocked in combat lockdown;
		-- don't start key capture there (it would throw ADDON_ACTION_BLOCKED).
		if InCombatLockdown() then return end
		self.listening = true
		self:SetText("Press a key… (Esc cancels)")
		self:EnableKeyboard(true)
		self:SetPropagateKeyboardInput(false) -- consume keys only while capturing
	end)
	btn:SetScript("OnKeyDown", function(self, key)
		-- Not capturing → let every key pass straight through to the game. This is
		-- the safety net that guarantees the keyboard can never stay "stuck".
		if not self.listening then
			if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
			return
		end
		if key == "ESCAPE" then
			self.listening = false
			self:EnableKeyboard(false)
			if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
			refresh()
			return
		end
		-- Wait for a real key; ignore lone modifiers (stay in capture mode).
		if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
			or key == "LALT" or key == "RALT" or key == "UNKNOWN" then
			return
		end
		-- WoW's canonical modifier order is ALT-CTRL-SHIFT; a wrong order silently
		-- fails to register multi-modifier combos.
		local combo = ""
		if IsAltKeyDown() then combo = combo .. "ALT-" end
		if IsControlKeyDown() then combo = combo .. "CTRL-" end
		if IsShiftKeyDown() then combo = combo .. "SHIFT-" end
		combo = combo .. key
		local o1, o2 = GetBindingKey(bindingName)
		if o1 then SetBinding(o1) end
		if o2 then SetBinding(o2) end
		if SetBinding(combo, bindingName) then SaveBindings(GetCurrentBindingSet()) end
		self.listening = false
		self:EnableKeyboard(false)
		if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
		refresh()
	end)
	return btn
end

----------------------------------------------------------------------
-- Layout
----------------------------------------------------------------------
local titleFS = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
titleFS:SetPoint("TOPLEFT", 16, -16)
titleFS:SetText("Thumber")

local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
sub:SetPoint("TOPLEFT", 16, -40)
sub:SetText("Mark players thumbs up / neutral / thumbs down, with an optional note.")

AddCheck("Show my mark in player tooltips",
	function() return db().showInTooltip ~= false end,
	function(v) db().showInTooltip = v end,
	18, -72)

AddCheck("Also show the note text in tooltips",
	function() return db().showNoteInTooltip ~= false end,
	function(v) db().showNoteInTooltip = v end,
	36, -100)

AddCheck("Show the minimap button  (left-click opens the list, drag to move)",
	function() return not (db().minimap and db().minimap.hide) end,
	function(v)
		local m = db(); m.minimap = m.minimap or {}; m.minimap.hide = not v
		if Thumber_UpdateMinimapButton then Thumber_UpdateMinimapButton() end
	end,
	18, -132)

local kb = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
kb:SetPoint("TOPLEFT", 16, -176)
kb:SetText("Keybinds")

AddBindRow("THUMBER_UP", "Thumbs up", 18, -200)
AddBindRow("THUMBER_DOWN", "Thumbs down", 215, -200)
AddBindRow("THUMBER_NEUTRAL", "Neutral", 18, -252)
AddBindRow("THUMBER_TOGGLE", "Open the list", 215, -252)

local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
note:SetPoint("TOPLEFT", 18, -302)
note:SetText("Bind: left-click a slot then press a key. Right-click a slot to clear.")
local note2 = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
note2:SetPoint("TOPLEFT", 18, -316)
note2:SetText("These also appear under Esc > Key Bindings > Thumber.")

----------------------------------------------------------------------
-- Register + open helper (supports both the new and legacy options APIs)
----------------------------------------------------------------------
if Settings and Settings.RegisterCanvasLayoutCategory then
	category = Settings.RegisterCanvasLayoutCategory(panel, "Thumber")
	Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
	InterfaceOptions_AddCategory(panel)
end

function Thumber_OpenSettings()
	if category and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(panel) -- called twice to work around
		InterfaceOptionsFrame_OpenToCategory(panel) -- a long-standing classic bug
	end
end
