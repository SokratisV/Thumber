local ADDON, ns = ...
local L = ns.L

-- The settings window (/thumber config), in the visual language of FlareUI by Malkkav
-- (MIT), as the Garu Combat Text and Unbuffed windows are: bronze trim over Blizzard's
-- Collections tile, the pages in a list on the left, the page's settings in the middle
-- under headings that fold, and on the right what the hovered setting does. Blizzard's
-- own controls throughout. There are few pages, so no search box, and the preview sits
-- above the settings on the pages that change how something looks, where scrolling can
-- never carry it out of sight.
--
-- Pages are plain data (definePages, below): each row says what it is, what it does,
-- how to read and write its value, and when it applies. The window is drawn from that
-- data and drawn again after every change, so a setting that stops applying goes, and
-- comes back when it applies again. Sliders are the exception: redrawing mid-drag would
-- drop the drag, and nothing a slider sets changes what is shown.

local WIDTH, HEIGHT = 900, 640
local HEADER_H = 34
local LEFT_W, RIGHT_W = 150, 230
local PAD = 12
local ROW_H, SECTION_H = 26, 28
local CONTENT_W = WIDTH - 12 - LEFT_W - RIGHT_W - 2 * PAD - 14
local PV_H = 178
local ICON = "Interface\\AddOns\\Thumber\\thumbsup.png"

local BORDER = { 0.80, 0.60, 0.34 }
local BRONZE = { 0.61, 0.48, 0.29 }

local MARK = ns.MARK

local function val(x) if type(x) == "function" then return x() end return x end
local function Sound(kit)
	local id = SOUNDKIT and SOUNDKIT[kit]
	if id and PlaySound then pcall(PlaySound, id) end
end

local Panel = {}
ns.OptionsPanel = Panel
local frame
local page, info, pv = {}, {}, { mark = "down", scene = "badges" }
ns._preview = pv
local pages, pageByKey
local current = "general"
local closed = {}             -- "page:section" -> folded, for this session
local pools, used = {}, {}
local navButtons = {}
local uid = 0

-- What "Reset badge look" puts back: how badges look and where they sit.
local BADGE_KEYS = {
	"badgeNameplate", "badgeTarget", "badgeStyle", "badgeSize", "popAnim",
	"badgeAnchor", "badgeOffsetX", "badgeOffsetY", "badgeCorner",
}

--------------------------------------------------------------------------
-- 1. ROW DEFINITIONS
--------------------------------------------------------------------------
-- Rows read the options when asked, never when made.
local function merge(row, extra)
	if extra then for k, v in pairs(extra) do row[k] = v end end
	return row
end
local function Toggle(name, label, desc, extra)
	return merge({ kind = "toggle", opt = name, label = label, desc = desc,
		get = function() return ns.Opt(name) and true or false end,
		set = function(v) ns.SetOpt(name, v) end }, extra)
end
local function Choice(name, label, desc, choices, extra)
	return merge({ kind = "choice", opt = name, label = label, desc = desc, choices = choices,
		get = function() return ns.Opt(name) end,
		set = function(v) ns.SetOpt(name, v) end }, extra)
end
local function Slider(name, label, desc, lo, hi, step, extra)
	return merge({ kind = "slider", opt = name, label = label, desc = desc, min = lo, max = hi, step = step,
		get = function() return tonumber(ns.Opt(name)) or lo end,
		set = function(v) ns.SetOpt(name, v) end }, extra)
end
local function Button(label, desc, text, run, extra)
	return merge({ kind = "button", label = label, desc = desc, buttonText = text, run = run }, extra)
end
local function Bind(action, label, desc, extra)
	return merge({ kind = "bind", binding = action, label = label, desc = desc }, extra)
end

--------------------------------------------------------------------------
-- 2. SMALL PIECES
--------------------------------------------------------------------------
local function Text(parent, font, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

local function Line(parent, layer)
	local t = parent:CreateTexture(nil, layer or "ARTWORK")
	t:SetColorTexture(BRONZE[1], BRONZE[2], BRONZE[3], 0.6)
	t:SetHeight(1)
	return t
end

-- A redraw after a change, a frame later: a menu's own click is still running.
local function Changed()
	C_Timer.After(0, function() if frame and frame:IsShown() then Panel.Refresh() end end)
end

--------------------------------------------------------------------------
-- 3. THE RIGHT COLUMN: what the hovered setting does
--------------------------------------------------------------------------
local function ShowInfo(title, desc, tip)
	if not info.title then return end
	info.title:SetText(title or "")
	info.desc:SetText(desc or "")
	info.tip:SetText(tip and ("|cffffd100" .. L["Tip:"] .. "|r " .. tip) or "")
end

local function ShowPageInfo()
	local p = pageByKey and pageByKey[current]
	if p then ShowInfo(val(p.title), val(p.desc), L["Hover any setting to see what it does."]) end
end

--------------------------------------------------------------------------
-- 4. ROWS
--------------------------------------------------------------------------
-- One pool per kind. A row spans the page: its name on the left, its control on the
-- right; hovering it fills the right column.
local Build, Fill = {}, {}

local function RowEnter(self)
	if self.row then ShowInfo(val(self.row.label), val(self.row.desc), self.row.tip) end
	self.hover:Show()
end
local function RowLeave(self)
	self.hover:Hide()
	ShowPageInfo()
end
local function Forward(control, f)
	if not control or not control.HookScript then return end
	control:HookScript("OnEnter", function() RowEnter(f) end)
	control:HookScript("OnLeave", function() RowLeave(f) end)
end

local function NewRow(parent, kind)
	local f = CreateFrame("Frame", nil, parent)
	f:SetHeight(ROW_H)
	f:EnableMouse(true)
	f:SetScript("OnEnter", RowEnter)
	f:SetScript("OnLeave", RowLeave)
	f.hover = f:CreateTexture(nil, "BACKGROUND")
	f.hover:SetAllPoints()
	f.hover:SetColorTexture(1, 0.82, 0, 0.06)
	f.hover:Hide()
	f.label = Text(f, "GameFontHighlight")
	f.label:SetPoint("LEFT", 6, 0)
	f.kind = kind
	Build[kind](f)
	return f
end

local function Acquire(parent, kind)
	pools[kind] = pools[kind] or {}
	local f = table.remove(pools[kind]) or NewRow(parent, kind)
	f:SetParent(parent)
	f:Show()
	used[#used + 1] = f
	return f
end

local function ReleaseAll()
	for _, f in ipairs(used) do
		f:Hide()
		f:ClearAllPoints()
		f.row = nil
		table.insert(pools[f.kind], f)
	end
	wipe(used)
end

-- toggle: a checkbox at the right
Build.toggle = function(f)
	local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
	check:SetSize(26, 26)
	check:SetPoint("RIGHT", -4, 0)
	check:SetScript("OnClick", function(self)
		local on = self:GetChecked() and true or false
		Sound(on and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
		if f.row then f.row.set(on); Changed() end
	end)
	Forward(check, f)
	f.check = check
end
Fill.toggle = function(f, row)
	f.check:SetChecked(row.get() and true or false)
end

-- choice: Blizzard's stepper from its Settings (a dark box with an arrow either side;
-- the box opens the list, the arrows step through it). Where a client has no such
-- template, a plain dropdown; where it has no menus either, the old one.
local function SetupMenu(dropdown, f)
	dropdown:SetupMenu(function(_, root)
		local row = f.row
		if not row then return end
		local choices = val(row.choices)
		-- a long list (every shared-media sound) scrolls instead of running off screen
		if #choices > 20 and root.SetScrollMode then root:SetScrollMode(440) end
		for _, c in ipairs(choices) do
			root:CreateRadio(c.text,
				function() return row.get() == c.value end,
				function() row.set(c.value); Changed() end,
				c.value)
		end
	end)
end

Build.choice = function(f)
	local ok, stepper = pcall(CreateFrame, "Frame", nil, f, "SettingsDropdownWithButtonsTemplate")
	if ok and stepper and stepper.Dropdown and stepper.IncrementButton and stepper.DecrementButton
		and stepper.Dropdown.SetupMenu then
		if stepper.Label then stepper.Label:Hide() end
		stepper:SetPoint("RIGHT", 4, 0)
		stepper.Dropdown:SetWidth(160)
		-- the template lays its arrows out past its own right edge: placed from the
		-- row's right edge instead, so the right arrow is never clipped
		stepper.IncrementButton:ClearAllPoints()
		stepper.IncrementButton:SetPoint("RIGHT", f, "RIGHT", -6, 0)
		stepper.Dropdown:ClearAllPoints()
		stepper.Dropdown:SetPoint("RIGHT", stepper.IncrementButton, "LEFT", -5, 0)
		stepper.DecrementButton:ClearAllPoints()
		stepper.DecrementButton:SetPoint("RIGHT", stepper.Dropdown, "LEFT", -5, 0)
		Forward(stepper.Dropdown, f); Forward(stepper.IncrementButton, f); Forward(stepper.DecrementButton, f)
		SetupMenu(stepper.Dropdown, f)
		f.dropdown = stepper.Dropdown
		f:SetHeight(ROW_H + 6)
		return
	end
	if ok and stepper then stepper:Hide() end

	if MenuUtil then
		local okd, dd = pcall(CreateFrame, "DropdownButton", nil, f, "WowStyle1DropdownTemplate")
		if okd and dd and dd.SetupMenu then
			dd:SetWidth(180)
			dd:SetPoint("RIGHT", -6, 0)
			Forward(dd, f)
			SetupMenu(dd, f)
			f.dropdown = dd
			return
		end
	end

	uid = uid + 1
	local dd = CreateFrame("Frame", "ThumberDrop" .. uid, f, "UIDropDownMenuTemplate")
	dd:SetPoint("RIGHT", 10, -2)
	UIDropDownMenu_SetWidth(dd, 150)
	UIDropDownMenu_Initialize(dd, function(_, level)
		local row = f.row
		if not row then return end
		for _, c in ipairs(val(row.choices)) do
			local entry = UIDropDownMenu_CreateInfo()
			entry.text, entry.checked = c.text, (row.get() == c.value)
			entry.func = function() row.set(c.value); CloseDropDownMenus(); Changed() end
			UIDropDownMenu_AddButton(entry, level)
		end
	end)
	f.legacy = dd
	f:SetHeight(ROW_H + 6)
end
Fill.choice = function(f, row)
	if f.dropdown then
		f.dropdown:GenerateMenu()
	elseif f.legacy then
		local text = ""
		for _, c in ipairs(val(row.choices)) do if c.value == row.get() then text = c.text end end
		UIDropDownMenu_SetText(f.legacy, text)
	end
end

-- slider: Blizzard's minimal slider with its stepper arrows, and the value in a box
-- you can type into
local function Snap(v, step)
	if step >= 1 then return math.floor(v / step + 0.5) * step end
	local m = 1 / step
	return math.floor(v * m + 0.5) / m
end
local function ValueText(row, v)
	if row.fmt then return row.fmt(v) end
	if row.step < 1 then return string.format("%.1f", v) end
	return tostring(v)
end

local function SliderChanged(f, value)
	local row = f.row
	if f.filling or not row then return end
	value = Snap(value, row.step)
	if value ~= row.get() then row.set(value) end
	f.edit:SetText(ValueText(row, value))
end

Build.slider = function(f)
	local ok, s = pcall(CreateFrame, "Frame", nil, f, "MinimalSliderWithSteppersTemplate")
	if ok and s and s.Init and s.RegisterCallback and MinimalSliderWithSteppersMixin
		and MinimalSliderWithSteppersMixin.Event then
		s:SetWidth(180)
		s:SetPoint("RIGHT", -54, 0)
		if s.MinText then s.MinText:Hide() end
		if s.MaxText then s.MaxText:Hide() end
		s:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged,
			function(_, value) SliderChanged(f, value) end, f)
		Forward(s, f); Forward(s.Slider, f)
		f.slider = s
	else
		if ok and s then s:Hide() end
		-- no template: a bare slider in the same place
		local bare = CreateFrame("Slider", nil, f)
		bare:SetOrientation("HORIZONTAL")
		bare:SetSize(170, 14)
		bare:SetPoint("RIGHT", -60, 0)
		bare:SetHitRectInsets(0, 0, -6, -6)
		pcall(bare.SetObeyStepOnDrag, bare, true)
		local track = bare:CreateTexture(nil, "ARTWORK")
		track:SetColorTexture(0.30, 0.30, 0.34, 0.9); track:SetHeight(4)
		track:SetPoint("LEFT"); track:SetPoint("RIGHT")
		local thumb = bare:CreateTexture(nil, "OVERLAY")
		thumb:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 1); thumb:SetSize(10, 16)
		bare:SetThumbTexture(thumb)
		bare:SetScript("OnValueChanged", function(_, value) SliderChanged(f, value) end)
		Forward(bare, f)
		f.slider = bare
	end

	local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	edit:SetSize(42, 18)
	edit:SetPoint("RIGHT", -6, 0)
	edit:SetAutoFocus(false)
	edit:SetJustifyH("CENTER")
	edit:SetMaxLetters(7)
	local function restore(self)
		if f.row then self:SetText(ValueText(f.row, f.row.get())) end
		self:ClearFocus()
	end
	edit:SetScript("OnEditFocusGained", function(self)
		if f.row then self:SetText(tostring(f.row.get())) end
		self:HighlightText()
	end)
	edit:SetScript("OnEnterPressed", function(self)
		local row, v = f.row, tonumber(self:GetText())
		if row and v then
			v = Snap(math.min(row.max, math.max(row.min, v)), row.step)
			f.slider:SetValue(v)
			row.set(v)
		end
		restore(self)
	end)
	edit:SetScript("OnEscapePressed", restore)
	edit:SetScript("OnEditFocusLost", restore)
	Forward(edit, f)
	f.edit = edit
	f:SetHeight(ROW_H + 4)
end
Fill.slider = function(f, row)
	f.filling = true
	local v = row.get()
	if f.slider.Init then
		local steps = math.max(1, math.floor((row.max - row.min) / row.step + 0.5))
		f.slider:Init(v, row.min, row.max, steps, {})
	else
		f.slider:SetMinMaxValues(row.min, row.max)
		f.slider:SetValueStep(row.step)
		f.slider:SetValue(v)
	end
	f.edit:SetText(ValueText(row, v))
	f.edit:SetCursorPosition(0)
	f.filling = false
end

-- button: an action, at the right
Build.button = function(f)
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetHeight(22)
	b:SetPoint("RIGHT", -4, 0)
	b:SetScript("OnClick", function()
		Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
		if f.row and f.row.run then f.row.run(); Changed() end
	end)
	Forward(b, f)
	f.button = b
end
Fill.button = function(f, row)
	f.button:SetText(val(row.buttonText) or "")
	f.button:SetWidth(math.max(90, (f.button:GetFontString() and f.button:GetFontString():GetStringWidth() or 60) + 28))
end

-- bind: click, then press a key; right-click clears. Bound straight to a Bindings.xml
-- action, so it shows what Esc > Key Bindings shows.
Build.bind = function(f)
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetSize(190, 22)
	b:SetPoint("RIGHT", -4, 0)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	local function action() return f.row and f.row.binding end
	local function refresh()
		if b.listening then return end
		local act = action()
		local k = act and GetBindingKey(act)
		b:SetText(k and ("|cff00ff00" .. k .. "|r") or L["Click to set key"])
	end
	b.refresh = refresh

	-- Whatever ends a capture, the keyboard goes back to the game. SetPropagateKeyboardInput
	-- is protected in combat, so it is skipped there.
	local function stop()
		b.listening = false
		Thumber_CapturingKey = false
		b:EnableKeyboard(false)
		if not InCombatLockdown() then b:SetPropagateKeyboardInput(true) end
	end
	b:SetScript("OnHide", function() if b.listening then stop() end end)

	b:SetScript("OnClick", function(self, mouseButton)
		local act = action()
		if not act then return end
		if mouseButton == "RightButton" then
			local o1, o2 = GetBindingKey(act)
			if o1 then SetBinding(o1) end
			if o2 then SetBinding(o2) end
			Thumber_SaveBindings()
			stop()
			refresh()
			return
		end
		-- SetPropagateKeyboardInput is blocked in combat lockdown; don't start a
		-- capture there (it would throw ADDON_ACTION_BLOCKED).
		if InCombatLockdown() then return end
		self.listening = true
		Thumber_CapturingKey = true
		self:SetText(L["Press a key… (Esc cancels)"])
		self:EnableKeyboard(true)
		self:SetPropagateKeyboardInput(false) -- consume keys only while capturing
	end)
	b:SetScript("OnKeyDown", function(self, key)
		-- Not capturing: every key passes straight through to the game, so the
		-- keyboard can never stay "stuck".
		if not self.listening then
			if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
			return
		end
		if key == "ESCAPE" then
			stop()
			refresh()
			return
		end
		-- Wait for a real key; a lone modifier keeps the capture going.
		if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
			or key == "LALT" or key == "RALT" or key == "UNKNOWN" then
			return
		end
		-- WoW's canonical modifier order is ALT-CTRL-SHIFT; a wrong order silently
		-- fails to register a multi-modifier combo.
		local combo = ""
		if IsAltKeyDown() then combo = combo .. "ALT-" end
		if IsControlKeyDown() then combo = combo .. "CTRL-" end
		if IsShiftKeyDown() then combo = combo .. "SHIFT-" end
		combo = combo .. key
		local act = action()
		if act then
			local o1, o2 = GetBindingKey(act)
			if o1 then SetBinding(o1) end
			if o2 then SetBinding(o2) end
			if SetBinding(combo, act) then Thumber_SaveBindings() end
		end
		stop()
		refresh()
	end)
	Forward(b, f)
	f.bindButton = b
end
Fill.bind = function(f)
	f.bindButton.refresh()
end

-- What the control at the right of a row leaves for the label, which wraps to a second
-- line (and the row grows) when a translation is longer than English.
local LABEL_ROOM = { toggle = 50, choice = 250, slider = 262, bind = 214 }
local ROW_BASE = { choice = ROW_H + 6, slider = ROW_H + 4 }
local function FillRow(f, row)
	f.row = row
	f.label:SetText(val(row.label) or "")
	Fill[f.kind](f, row)
	local room = LABEL_ROOM[f.kind]
	if f.kind == "button" then room = (f.button:GetWidth() or 120) + 24 end
	f.label:SetWidth(CONTENT_W - 6 - (room or 50))
	f.label:SetWordWrap(true)
	local lines = math.ceil((f.label:GetStringHeight() or 14) / 14)
	f:SetHeight(math.max(ROW_BASE[f.kind] or ROW_H, lines > 1 and (lines * 14 + 12) or 0))
end

--------------------------------------------------------------------------
-- 5. THE PREVIEW: mock nameplate, target portrait, chat and alert
--------------------------------------------------------------------------
-- Built from the same badge code the game uses (Extras.lua), so what it shows is what
-- you get: the badge is placed, sized and styled by the very functions the real
-- nameplates and target frame call. The mock's proportions are approximate; the
-- badge, its style, size and offsets are real. Redrawn whenever an option changes.
local function SceneLabel(parent, text)
	local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	fs:SetPoint("TOPLEFT", 4, -2)
	fs:SetText(text)
	return fs
end

-- A flat coloured bar.
local function MockBar(parent, w, h, r, g, b)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetSize(w, h)
	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.85)
	local fill = bar:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("TOPLEFT", 1, -1)
	fill:SetPoint("BOTTOMRIGHT", -1, 1)
	fill:SetColorTexture(r, g, b, 1)
	return bar
end

-- A button wide enough for its text, never narrower than `min`.
local function FitButton(b, min)
	local fs = b:GetFontString()
	b:SetWidth(math.max(min, (fs and fs:GetStringWidth() or 60) + 28))
end

local function HeaderButton(parent, text, w, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(w, 22)
	b:SetText(text)
	local fs = b:GetFontString()
	b:SetWidth(math.max(w, math.ceil(fs and fs:GetStringWidth() or 40) + 28))
	b:SetScript("OnClick", function() Sound("IG_MAINMENU_OPTION_CHECKBOX_ON"); onClick() end)
	return b
end

local PREVIEW_MARKS = { "up", "neutral", "down" }

local function BuildPreview(parent, header)
	local box = CreateFrame("Frame", nil, parent)
	box:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
	box:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -4)
	box:SetHeight(PV_H)
	pcall(box.SetClipsChildren, box, true)
	local bg = box:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.35)
	local top = Line(box)
	top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT")
	local bottom = Line(box)
	bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT")
	local label = Text(box, "GameFontDisableSmall")
	label:SetPoint("TOPLEFT", 6, -5)
	label:SetText(L["Preview"])
	pv.box = box

	-- which mark the preview shows, and the replays
	pv.markBtn = HeaderButton(box, "", 150, function()
		local i = 1
		for n, m in ipairs(PREVIEW_MARKS) do if m == pv.mark then i = n end end
		pv.mark = PREVIEW_MARKS[i % #PREVIEW_MARKS + 1]
		pv.update()
	end)
	pv.markBtn:SetHeight(20)
	pv.markBtn:SetPoint("TOPRIGHT", -6, -3)
	pv.markBtn:SetScript("OnEnter", function()
		ShowInfo(L["Preview as"], L["Switches the preview between the three marks: thumbs up, neutral and thumbs down."],
			L["Nothing is marked; this only changes the preview."])
	end)
	pv.markBtn:SetScript("OnLeave", ShowPageInfo)

	pv.popBtn = HeaderButton(box, L["Replay pop"], 90, function()
		if ns.Opt("popAnim") and pv.targetBadge:IsShown() then ns.PopBadge(pv.targetBadge) end
	end)
	pv.popBtn:SetHeight(20)
	pv.popBtn:SetPoint("RIGHT", pv.markBtn, "LEFT", -4, 0)
	pv.popBtn:SetScript("OnEnter", function()
		ShowInfo(L["Replay pop"], L["Plays the animation the target badge makes when a keybind marks your target."], L["Needs Pop animation on."])
	end)
	pv.popBtn:SetScript("OnLeave", ShowPageInfo)

	pv.alertBtn = HeaderButton(box, L["Show real alert"], 120, function() if ns.TestAlert then ns.TestAlert() end end)
	pv.alertBtn:SetHeight(20)
	pv.alertBtn:SetPoint("RIGHT", pv.markBtn, "LEFT", -4, 0)
	pv.alertBtn:SetScript("OnEnter", function()
		ShowInfo(L["Show real alert"], L["Pops the actual group alert on your screen, with its sound, exactly as it appears when a marked player is in your group."],
			L["Also /thumber test."])
	end)
	pv.alertBtn:SetScript("OnLeave", ShowPageInfo)

	-- scene group A: badges
	local A = CreateFrame("Frame", nil, box)
	A:SetAllPoints()
	pv.A = A

	local plate = CreateFrame("Frame", nil, A)
	plate:SetPoint("TOPLEFT", 8, -28)
	plate:SetSize(230, 110)
	local pname = plate:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	pname:SetPoint("TOP", plate, "TOP", 0, -52)
	pname:SetText("|cffff7d0aKhalitas Shadowclaw|r")
	local pbar = MockBar(plate, 112, 10, 0.78, 0.2, 0.2)
	pbar:SetPoint("TOP", pname, "BOTTOM", -12, -3)
	local plvl = CreateFrame("Frame", nil, plate)
	plvl:SetSize(22, 14)
	plvl:SetPoint("LEFT", pbar, "RIGHT", 4, 0)
	local plvlBg = plvl:CreateTexture(nil, "BACKGROUND")
	plvlBg:SetAllPoints()
	plvlBg:SetColorTexture(0, 0, 0, 0.7)
	local plvlText = plvl:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	plvlText:SetPoint("CENTER")
	plvlText:SetText("60")
	SceneLabel(plate, L["Nameplate"])
	pv.plate = { plate = plate, name = pname, bar = pbar, level = plvl }
	pv.plateBadge = ns.NewBadge(plate)

	local tgt = CreateFrame("Frame", nil, A)
	tgt:SetPoint("TOPLEFT", 246, -28)
	tgt:SetSize(210, 110)
	local port = CreateFrame("Frame", nil, tgt)
	port:SetSize(56, 56)
	port:SetPoint("LEFT", 30, 6)
	local portTex = port:CreateTexture(nil, "ARTWORK")
	portTex:SetAllPoints()
	portTex:SetColorTexture(0.30, 0.24, 0.14, 1)
	if port.CreateMaskTexture then
		local m = port:CreateMaskTexture()
		m:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		m:SetAllPoints(portTex)
		portTex:AddMaskTexture(m)
	end
	local tname = tgt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	tname:SetPoint("LEFT", port, "RIGHT", 8, 10)
	tname:SetText("|cffff7d0aKhalitas|r")
	local tbar = MockBar(tgt, 80, 10, 0.2, 0.7, 0.25)
	tbar:SetPoint("TOPLEFT", tname, "BOTTOMLEFT", 0, -3)
	SceneLabel(tgt, L["Target frame"])
	pv.port = port
	pv.targetBadge = ns.NewBadge(tgt)

	pv.chat1 = A:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	pv.chat1:SetPoint("BOTTOMLEFT", 8, 26)
	pv.chat1:SetJustifyH("LEFT")
	pv.chat2 = A:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	pv.chat2:SetPoint("BOTTOMLEFT", 8, 10)
	pv.chat2:SetJustifyH("LEFT")

	-- scene group B: the group alert at full size
	local B = CreateFrame("Frame", nil, box)
	B:SetAllPoints()
	pv.B = B
	local toast = CreateFrame("Frame", nil, B, "BackdropTemplate")
	toast:SetSize(330, 64)
	toast:SetPoint("CENTER", 0, -6)
	toast:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
	toast:SetBackdropColor(0.08, 0.067, 0.043, 0.95)
	pv.toast = toast
	pv.toastIcon = toast:CreateTexture(nil, "ARTWORK")
	pv.toastIcon:SetSize(36, 36)
	pv.toastIcon:SetPoint("LEFT", 14, 0)
	local ttitle = toast:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ttitle:SetPoint("TOPLEFT", pv.toastIcon, "TOPRIGHT", 10, 2)
	ttitle:SetText(L["Marked player in your group"])
	pv.toastName = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	pv.toastName:SetPoint("TOPLEFT", ttitle, "BOTTOMLEFT", 0, -3)
	pv.toastNote = toast:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	pv.toastNote:SetPoint("TOPLEFT", pv.toastName, "BOTTOMLEFT", 0, -2)

	function pv.update()
		if not pv.box then return end
		local mark = MARK[pv.mark] or MARK.neutral
		local size = ns.Opt("badgeSize")
		pv.markBtn:SetText(L["Preview as: %s"]:format(mark.label))
		FitButton(pv.markBtn, 120)
		pv.A:SetShown(pv.scene == "badges")
		pv.B:SetShown(pv.scene == "alert")
		pv.popBtn:SetShown(pv.scene == "badges")
		pv.alertBtn:SetShown(pv.scene == "alert")

		if pv.scene == "badges" then
			if ns.Opt("badgeNameplate") then
				ns.PlacePlateBadge(pv.plateBadge, pv.plate, true)
				ns.StyleBadge(pv.plateBadge, pv.mark, size)
				pv.plateBadge:Show()
			else
				ns.HideBadge(pv.plateBadge)
			end
			if ns.Opt("badgeTarget") then
				ns.PlaceTargetBadge(pv.targetBadge, pv.port)
				ns.StyleBadge(pv.targetBadge, pv.mark, math.max(14, size - 4))
				pv.targetBadge:Show()
			else
				ns.HideBadge(pv.targetBadge)
			end
			pv.chat1:SetText("|cffaaaaff[" .. (PARTY or "Party") .. "]|r |cffff7d0a[Khalitas Shadowclaw]|r: " ..
				(ns.Opt("badgeChat") and (ns.MarkIcon(pv.mark) .. " ") or "") .. L["pull now"])
			if ns.Opt("chatLogging") then
				pv.chat2:SetText(ns.MarkIcon(pv.mark) .. " |cff66ccffThumber|r: " ..
					L["%s marked %s."]:format("Khalitas Shadowclaw", "|cff" .. mark.hex .. mark.label .. "|r"))
			else
				pv.chat2:SetText("|cff777777" .. L["(no chat message when a keybind marks someone)"] .. "|r")
			end
		else
			pv.toastIcon:SetTexture(mark.tex)
			pv.toast:SetBackdropBorderColor(mark.color[1], mark.color[2], mark.color[3], 1)
			pv.toastName:SetText("|cffff7d0aKhalitas Shadowclaw|r  |cff9a8b6e" .. mark.label .. "|r")
			pv.toastNote:SetText("\"" .. L["ninja looted last run"] .. "\"")
			pv.toast:SetAlpha(ns.Opt("groupAlert") and 1 or 0.3)
		end
	end
	box:Hide()
end

-- The preview redraws on every option change, wherever it was made.
ns.OnOptionChanged = function() if pv.update then pv.update() end end

--------------------------------------------------------------------------
-- 6. PAGES
--------------------------------------------------------------------------
local STYLES = { { value = "icon", text = L["Icon"] }, { value = "ring", text = L["Ring"] } }
local ANCHORS = {
	{ value = "ABOVE", text = L["Above the nameplate"] }, { value = "BELOW", text = L["Below the nameplate"] },
	{ value = "LEFT", text = L["Left of the nameplate"] }, { value = "RIGHT", text = L["Right of the nameplate"] },
}
local CORNERS = {
	{ value = "TOPRIGHT", text = L["Top right"] }, { value = "TOPLEFT", text = L["Top left"] },
	{ value = "BOTTOMRIGHT", text = L["Bottom right"] }, { value = "BOTTOMLEFT", text = L["Bottom left"] },
}

local function definePages()
	local function noteShown() return ns.Opt("showInTooltip") and ns.Opt("showNoteInTooltip") end

	-- Two clicks rather than a dialog: the first arms the button and says so, and it
	-- disarms itself if the second never comes.
	local RESET_LABEL = L["Reset badge look"]
	local confirming, armed = false, 0
	local function resetClick()
		if confirming then
			confirming = false
			for _, key in ipairs(BADGE_KEYS) do ns.DB()[key] = nil end
			ns.OnMarksChanged()
			if ns.OnOptionChanged then ns.OnOptionChanged() end
			return
		end
		confirming = true
		armed = armed + 1
		local mine = armed
		C_Timer.After(4, function()
			if armed == mine and confirming then
				confirming = false
				if frame and frame:IsShown() then Panel.Refresh() end
			end
		end)
	end

	pages = {
		{
			key = "general", title = L["General"],
			desc = L["What Thumber shows in tooltips and chat, and the minimap button. Marks themselves are made with the keybinds, the slash commands, or the marks window."],
			sections = {
				{ key = "tooltips", title = L["Tooltips"], rows = {
					Toggle("showInTooltip", L["Show my mark in player tooltips"],
						L["Adds a coloured line to the tooltip of a player you have marked, with their mark and, if you like, your note."]),
					Toggle("showNoteInTooltip", L["Also show the note"],
						L["Adds your note under the mark line."], { vis = function() return ns.Opt("showInTooltip") end }),
					Toggle("tooltipFullNote", L["Show the whole note"],
						L["Wraps the full note onto as many lines as it needs. Off keeps it to one shortened line."],
						{ vis = noteShown }),
				} },
				{ key = "chat", title = L["Chat"], rows = {
					Toggle("chatLogging", L["Message when a keybind marks"],
						L["Prints a line in chat when a keybind marks or un-marks your target. The slash commands always reply, since typing one is already a chat interaction."],
						{ tip = L["The Badges preview shows this line."] }),
					Toggle("badgeChat", L["Icon in front of chat lines"],
						L["Puts a marked player's icon at the start of what they say in chat."],
						{ tip = L["The Badges preview shows it."] }),
				} },
				{ key = "minimap", title = L["Minimap"], rows = {
					{ kind = "toggle", label = L["Show the minimap button"],
					  desc = L["Left-click opens the marks list, right-click opens these settings, and you can drag it around the minimap."],
					  get = function() return not (ns.DB().minimap and ns.DB().minimap.hide) end,
					  set = function(v)
						  local d = ns.DB()
						  d.minimap = d.minimap or {}
						  d.minimap.hide = not v
						  if Thumber_UpdateMinimapButton then Thumber_UpdateMinimapButton() end
					  end },
				} },
			},
		},
		{
			key = "badges", title = L["Badges"], preview = "badges",
			desc = L["The icon that marks a player where you see them: above their nameplate, on your target frame, and in chat. The preview above shows every change as you make it."],
			sections = {
				{ key = "where", title = L["Where"], rows = {
					Toggle("badgeNameplate", L["Above nameplates"],
						L["A badge above the nameplate of a marked player, so you spot them in a crowd. It sits above the name and is layered over Blizzard's level box."]),
					Toggle("badgeTarget", L["On the target frame"],
						L["A small badge on your target's portrait. It only shows where Blizzard's target frame is visible; another unit-frame addon may hide it."]),
				} },
				{ key = "look", title = L["Look"], rows = {
					Choice("badgeStyle", L["Style"],
						L["Icon is the bare mark. Ring puts it in a ring in the mark's colour."], STYLES,
						{ get = function() return ns.Opt("badgeStyle") == "icon" and "icon" or "ring" end }),
					Slider("badgeSize", L["Size"], L["How big the nameplate badge is, in pixels. The target badge is slightly smaller."], 14, 40, 2),
					Toggle("popAnim", L["Pop animation"],
						L["The target badge pops when a keybind marks your target."],
						{ vis = function() return ns.Opt("badgeTarget") end, tip = L["Replay pop in the preview shows it."] }),
				} },
				{ key = "position", title = L["Position"], rows = {
					Choice("badgeAnchor", L["Nameplate anchor"],
						L["Which side of the nameplate the badge sits on. Above is over the name; Below is under the health bar; Left is beside the bar; Right is beside Blizzard's level box."],
						ANCHORS, { vis = function() return ns.Opt("badgeNameplate") end }),
					Slider("badgeOffsetX", L["Nameplate offset X"],
						L["Moves the nameplate badge sideways from its anchor, left below zero and right above it. Useful if another addon puts something there."], -200, 200, 1,
						{ vis = function() return ns.Opt("badgeNameplate") end }),
					Slider("badgeOffsetY", L["Nameplate offset Y"],
						L["Moves the nameplate badge up (above zero) or down (below zero) from its anchor."], -200, 200, 1,
						{ vis = function() return ns.Opt("badgeNameplate") end }),
					Choice("badgeCorner", L["Target badge corner"],
						L["Which corner of your target's portrait the badge sits on. Blizzard puts the level number in a lower corner, so top right is the default."],
						CORNERS, { vis = function() return ns.Opt("badgeTarget") end }),
				} },
				{ key = "reset", title = L["Reset"], rows = {
					Button(L["Reset badge look"], L["Puts the badge switches, style, size, pop animation and position back to their defaults. Your marks, tooltips, chat and alert settings are left alone."],
						function() return confirming and ("|cffff5555" .. L["Click again to confirm"] .. "|r") or RESET_LABEL end, resetClick),
				} },
			},
		},
		{
			key = "alerts", title = L["Alerts"], preview = "alert",
			desc = L["A toast that appears when a marked player is in your group or raid, once each time they join, so you hear about a thumbs down before the pull."],
			sections = {
				{ key = "group", title = L["Group alert"], rows = {
					Toggle("groupAlert", L["Alert when a marked player is in my group"],
						L["Shows the toast with the player's name, mark and your note. Right-click (or click) it to dismiss; it goes by itself after a few seconds."]),
					Choice("alertSound", L["Sound"],
						L["The sound that plays with the alert. Picking one plays it."],
						function() return ns.SoundChoices() end,
						{ vis = function() return ns.Opt("groupAlert") end,
						  get = function() return ns.NormalizeSound(ns.Opt("alertSound")) end,
						  set = function(v) ns.SetOpt("alertSound", v); if ns.PlayAlertSound then ns.PlayAlertSound() end end,
						  tip = L["Show real alert in the preview plays it too."] }),
					Button(L["Try it"], L["Pops the actual alert on your screen, with its sound, exactly as it appears when a marked player is in your group."],
						L["Show real alert"], function() if ns.TestAlert then ns.TestAlert() end end,
						{ tip = L["Also /thumber test."] }),
				} },
				{ key = "position", title = L["Position"], rows = {
					Button(L["Alert position"], L["Unlock the alert to show it on screen as a placeholder you can drag anywhere. Lock it again, or close this window, to keep the spot. It is remembered between sessions."],
						function() return ns.alertUnlocked and L["Lock the alert"] or L["Unlock the alert"] end,
						function() if ns.SetAlertLocked then ns.SetAlertLocked(ns.alertUnlocked) end end,
						{ tip = L["Drag the placeholder with the left mouse button."] }),
					Button(L["Reset position"], L["Puts the alert back at the top right of the screen."],
						L["Reset position"], function() if ns.ResetAlertPosition then ns.ResetAlertPosition() end end),
				} },
			},
		},
		{
			key = "sharing", title = L["Sharing"],
			desc = L["Hand your marks to a friend, or take theirs. A transfer to a player asks them first and never overwrites their marks; an export is one string you can paste anywhere."],
			sections = {
				{ key = "receive", title = L["Receiving"], rows = {
					Toggle("shareReceive", L["Let other players offer me their marks"],
						L["When someone offers to share their marks you get an Accept / Decline prompt. Nothing arrives unless you accept, and only marks you don't already have are added. Off declines every offer."]),
				} },
				{ key = "share", title = L["Share"], rows = {
					Choice("shareScope", L["What to share"],
						L["All marks, or only your thumbs downs: handy for warning a friend about the players you would rather they avoided, without handing over your whole list. It applies to sending to a player and to exporting."],
						{ { value = "all", text = L["All marks"] }, { value = "down", text = L["Thumbs down only"] } }),
					Button(L["Share window"], L["Opens the share window: send your marks to a player, or export them as text and import someone else's, with a preview of what an import would change."],
						L["Open sharing"], function() if ns.OpenShare then ns.OpenShare() end end,
						{ tip = L["Also /thumber share."] }),
				} },
			},
		},
		{
			key = "profile", title = L["Profile"],
			desc = L["All of Thumber's settings, positions and keybinds as one string: to move your setup to another character or install, or to keep a backup. Your marks have their own sharing and are not part of it."],
			sections = {
				{ key = "profile", title = L["Profile"], rows = {
					Button(L["Export or import"], L["Opens the profile window. Export gives you one string to copy. Import checks a pasted string first, tells you what is in it, and applies it only when you press Apply: it replaces your settings, the positions of the marks window, alert and minimap button, and your four keybinds, and everything updates on the spot."],
						L["Open profile window"], function() if ns.OpenProfile then ns.OpenProfile() end end,
						{ tip = L["Also /thumber profile."] }),
				} },
			},
		},
		{
			key = "keybinds", title = L["Keybinds"],
			desc = L["Mark your target (or mouseover) with a key. Marking a player with the mark they already have removes them. Click a button, then press the key; right-click clears it."],
			sections = {
				{ key = "keys", title = L["Keybinds"], rows = {
					Bind("THUMBER_UP", L["Thumbs up"], L["Marks your target thumbs up, or removes the mark if they already have it. Default: Arrow Up."]),
					Bind("THUMBER_DOWN", L["Thumbs down"], L["Marks your target thumbs down, or removes the mark if they already have it. Default: Arrow Down."]),
					Bind("THUMBER_NEUTRAL", L["Neutral"], L["Marks your target neutral, or removes the mark if they already have it. Default: Arrow Left."]),
					Bind("THUMBER_TOGGLE", L["Open the list"], L["Opens or closes the marks list. Default: Arrow Right."]),
					Button(L["Restore the defaults"], L["Puts the four arrow-key defaults back: Up, Down, Left and Right. They take the keys from character movement, as they did the first time."],
						L["Restore defaults"], function() if SlashCmdList and SlashCmdList.THUMBER then SlashCmdList.THUMBER("resetbinds") end end),
				} },
			},
		},
	}
	pageByKey = {}
	for _, p in ipairs(pages) do pageByKey[p.key] = p end
	ns._optionPages = pages
end

-- What each setting accepts (a slider's range, a choice's values), read from the rows
-- above, so an imported profile is held to exactly what this window lets you pick.
function ns.OptionRules()
	if not pages then definePages() end
	local rules = {}
	for _, p in ipairs(pages) do
		for _, section in ipairs(p.sections) do
			for _, row in ipairs(section.rows) do
				if row.opt then
					local rule = { kind = row.kind }
					if row.kind == "slider" then
						rule.min, rule.max = row.min, row.max
					elseif row.kind == "choice" then
						rule.values = {}
						for _, c in ipairs(val(row.choices)) do rule.values[c.value] = true end
					end
					rules[row.opt] = rule
				end
			end
		end
	end
	return rules
end

--------------------------------------------------------------------------
-- 7. THE MIDDLE COLUMN: the page
--------------------------------------------------------------------------
local function SectionClick(h)
	if not h.sectionKey then return end
	Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
	closed[h.sectionKey] = not closed[h.sectionKey] or nil
	Panel.Refresh()
end

local function SectionHeader(parent, text, y, sectionKey)
	pools.section = pools.section or {}
	local h = table.remove(pools.section)
	if not h then
		h = CreateFrame("Frame", nil, parent)
		h:SetHeight(SECTION_H)
		h.kind = "section"
		h.text = Text(h, "GameFontNormal")
		h.text:SetPoint("BOTTOMLEFT", 6, 6)
		h.sign = Text(h, "GameFontNormal")
		h.sign:SetPoint("BOTTOMRIGHT", -10, 6)
		h.line = Line(h)
		h.line:SetPoint("BOTTOMLEFT", 0, 2)
		h.line:SetPoint("BOTTOMRIGHT", 0, 2)
		h.hover = h:CreateTexture(nil, "BACKGROUND")
		h.hover:SetAllPoints()
		h.hover:SetColorTexture(1, 0.82, 0, 0.06)
		h.hover:Hide()
		h:EnableMouse(true)
		h:SetScript("OnEnter", function(self) self.hover:Show() end)
		h:SetScript("OnLeave", function(self) self.hover:Hide() end)
		h:SetScript("OnMouseUp", SectionClick)
	end
	h:SetParent(parent)
	h.sectionKey = sectionKey
	h.sign:SetText(sectionKey and (closed[sectionKey] and "+" or "-") or "")
	h.text:SetText(text)
	h:ClearAllPoints()
	h:SetPoint("TOPLEFT", 0, y)
	h:SetWidth(CONTENT_W)
	h:Show()
	used[#used + 1] = h
	return SECTION_H
end

-- Lays rows out from y down and returns the new y.
local function PlaceRows(parent, rows, y)
	for _, row in ipairs(rows) do
		local f = Acquire(parent, row.kind)
		f:ClearAllPoints()
		f:SetPoint("TOPLEFT", 0, y)
		f:SetWidth(CONTENT_W)
		FillRow(f, row)
		y = y - f:GetHeight()
	end
	return y
end

local function visibleRows(section)
	local out = {}
	for _, row in ipairs(section.rows) do
		if not row.vis or row.vis() then out[#out + 1] = row end
	end
	return out
end

local function UpdateNav()
	for key, b in pairs(navButtons) do
		b.selected:SetShown(key == current)
		b.text:SetText(val(pageByKey[key].title))
	end
end

function Panel.Refresh()
	if not frame then return end
	ReleaseAll()
	local p = pageByKey[current]

	page.title:SetText(val(p.title))
	pv.scene = p.preview or pv.scene
	pv.box:SetShown(p.preview and true or false)
	page.scroll:ClearAllPoints()
	page.scroll:SetPoint("TOPLEFT", p.preview and pv.box or page.header, "BOTTOMLEFT", 0, -6)
	page.scroll:SetPoint("BOTTOMRIGHT")
	if p.preview then pv.update() end

	local y = 0
	for _, section in ipairs(p.sections) do
		local rows = visibleRows(section)
		if #rows > 0 then
			local key = p.key .. ":" .. section.key
			y = y - SectionHeader(page.content, val(section.title), y, key)
			if not closed[key] then y = PlaceRows(page.content, rows, y) - 4 end
		end
	end
	page.content:SetHeight(math.max(1, -y + 8))
	if page.scrollLine then page.scrollLine.Update() end
	UpdateNav()
end

function Panel.Select(key)
	if not pageByKey[key] then return end
	current = key
	ns.DB().optionsPage = key
	page.scroll:SetVerticalScroll(0)
	Panel.Refresh()
	ShowPageInfo()
end

--------------------------------------------------------------------------
-- 8. THE WINDOW
--------------------------------------------------------------------------
-- A thin scroll line beside the page, like FlareUI's: a faint track and a bronze thumb,
-- shown only when there is something to scroll; the wheel scrolls the page.
local function AttachScrollLine(scroll, parent)
	local line = CreateFrame("Frame", nil, parent)
	line:SetWidth(8)
	line:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
	line:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
	line.track = line:CreateTexture(nil, "ARTWORK")
	line.track:SetWidth(2); line.track:SetPoint("TOP"); line.track:SetPoint("BOTTOM")
	line.track:SetColorTexture(BRONZE[1], BRONZE[2], BRONZE[3], 0.25)
	line.thumb = line:CreateTexture(nil, "OVERLAY")
	line.thumb:SetWidth(2)
	line.thumb:SetColorTexture(BORDER[1], BORDER[2], BORDER[3], 1)
	function line.Update()
		local range = scroll:GetVerticalScrollRange() or 0
		local h = line:GetHeight() or 0
		if not scroll:IsShown() or range <= 0.5 or h <= 0 then line:Hide() return end
		line:Show()
		local visible = scroll:GetHeight() / (scroll:GetHeight() + range)
		local th = math.max(16, h * visible)
		line.thumb:SetHeight(th)
		line.thumb:ClearAllPoints()
		line.thumb:SetPoint("TOP", line, "TOP", 0, -(h - th) * ((scroll:GetVerticalScroll() or 0) / range))
	end
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = self:GetVerticalScrollRange() or 0
		self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 40)))
	end)
	scroll:HookScript("OnVerticalScroll", line.Update)
	scroll:HookScript("OnScrollRangeChanged", line.Update)
	scroll:HookScript("OnSizeChanged", line.Update)
	return line
end

local NAV = { "general", "badges", "alerts", "sharing", "keybinds", "profile" }

-- Blizzard's own Settings window is where people find the launcher page for this one
-- (Esc > Options > AddOns). Like other addons' settings windows, ours closes it when it
-- opens, so the two are never up together. Skipped in combat, when UI panels can't be
-- hidden from addon code; the window still opens.
local function CloseBlizzardSettings()
	if InCombatLockdown() or not HideUIPanel then return end
	local sp = _G.SettingsPanel or _G.InterfaceOptionsFrame
	if sp and sp:IsShown() then HideUIPanel(sp) end
end

local function BuildWindow()
	if not pages then definePages() end
	local saved = ns.DB().optionsPage
	current = pageByKey[saved] and saved or "general"

	frame = CreateFrame("Frame", "ThumberOptions", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 })
	frame:SetBackdropBorderColor(BORDER[1], BORDER[2], BORDER[3], 1)
	-- a dark base, Blizzard's Collections tile over it, and a black wash (FlareUI's)
	local base = frame:CreateTexture(nil, "BACKGROUND", nil, 0)
	base:SetPoint("TOPLEFT", 5, -5); base:SetPoint("BOTTOMRIGHT", -5, 5)
	base:SetColorTexture(0.06, 0.055, 0.045, 0.97)
	local art = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	art:SetAllPoints(base)
	art:SetTexture("Interface\\Collections\\CollectionsBackgroundTile", "REPEAT", "REPEAT")
	art:SetHorizTile(true); art:SetVertTile(true)
	local wash = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
	wash:SetAllPoints(base)
	wash:SetColorTexture(0, 0, 0, 0.5)
	frame:Hide()
	tinsert(UISpecialFrames, "ThumberOptions")
	frame:SetScript("OnShow", function()
		Sound("IG_CHARACTER_INFO_OPEN")
		Panel.Refresh()
		ShowPageInfo()
	end)
	frame:SetScript("OnHide", function()
		Sound("IG_CHARACTER_INFO_CLOSE")
		if ns.alertUnlocked and ns.SetAlertLocked then ns.SetAlertLocked(true) end
	end)

	-- header: name, version, the two windows you reach for most, close
	local title = Text(frame, "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", PAD + 4, -12)
	title:SetText("Thumber")
	local version = Text(frame, "GameFontDisableSmall")
	version:SetPoint("LEFT", title, "RIGHT", 8, -1)
	local meta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
	version:SetText(meta and meta(ADDON, "Version") or "")
	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	local shareBtn = HeaderButton(frame, L["Share"], 80, function() if ns.OpenShare then ns.OpenShare() end end)
	shareBtn:SetPoint("RIGHT", close, "LEFT", -4, 0)
	local listBtn = HeaderButton(frame, L["Marks list"], 100, function() if Thumber_Open then Thumber_Open() end end)
	listBtn:SetPoint("RIGHT", shareBtn, "LEFT", -4, 0)
	local headerLine = Line(frame)
	headerLine:SetPoint("TOPLEFT", 6, -HEADER_H)
	headerLine:SetPoint("TOPRIGHT", -6, -HEADER_H)

	local body = CreateFrame("Frame", nil, frame)
	body:SetPoint("TOPLEFT", 6, -HEADER_H - 1)
	body:SetPoint("BOTTOMRIGHT", -6, 6)

	-- left column: the pages
	local left = CreateFrame("Frame", nil, body)
	left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT")
	left:SetWidth(LEFT_W)
	local leftLine = Line(body)
	leftLine:SetWidth(1)
	leftLine:SetPoint("TOPLEFT", left, "TOPRIGHT"); leftLine:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT")

	local y = -PAD + 4
	for _, key in ipairs(NAV) do
		local b = CreateFrame("Button", nil, left)
		b:SetSize(LEFT_W - 2 * PAD, 24)
		b:SetPoint("TOPLEFT", PAD, y)
		b.selected = b:CreateTexture(nil, "BACKGROUND")
		b.selected:SetAllPoints()
		b.selected:SetColorTexture(1, 0.82, 0, 0.12)
		b:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
		b:GetHighlightTexture():SetAlpha(0.25)
		b.text = Text(b, "GameFontHighlight")
		b.text:SetPoint("LEFT", 8, 0)
		b:SetScript("OnClick", function()
			Sound("IG_CHARACTER_INFO_TAB")
			Panel.Select(key)
		end)
		navButtons[key] = b
		y = y - 24
	end

	-- right column: what the hovered setting does
	local right = CreateFrame("Frame", nil, body)
	right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT")
	right:SetWidth(RIGHT_W)
	local rightBg = right:CreateTexture(nil, "BACKGROUND")
	rightBg:SetAllPoints()
	rightBg:SetColorTexture(0, 0, 0, 0.25)
	local rightLine = Line(body)
	rightLine:SetWidth(1)
	rightLine:SetPoint("TOPRIGHT", right, "TOPLEFT"); rightLine:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
	local icon = right:CreateTexture(nil, "ARTWORK")
	icon:SetSize(40, 40)
	icon:SetPoint("TOPLEFT", PAD, -PAD)
	icon:SetTexture(ICON)
	info.title = Text(right, "GameFontNormalLarge")
	info.title:SetPoint("LEFT", icon, "RIGHT", 10, 0)
	info.title:SetPoint("RIGHT", -PAD, 0)
	info.title:SetWordWrap(true)
	info.desc = Text(right, "GameFontHighlight")
	info.desc:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -12)
	info.desc:SetPoint("RIGHT", -PAD, 0)
	info.desc:SetSpacing(3)
	info.desc:SetTextColor(0.85, 0.85, 0.85)
	info.tip = Text(right, "GameFontNormalSmall")
	info.tip:SetPoint("TOPLEFT", info.desc, "BOTTOMLEFT", 0, -10)
	info.tip:SetPoint("RIGHT", -PAD, 0)
	info.tip:SetSpacing(2)

	-- middle column: the page, with the preview pinned above its settings where there is one
	local middle = CreateFrame("Frame", nil, body)
	middle:SetPoint("TOPLEFT", left, "TOPRIGHT", PAD, -PAD)
	middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", -PAD - 10, PAD)

	local header = CreateFrame("Frame", nil, middle)
	header:SetPoint("TOPLEFT"); header:SetPoint("TOPRIGHT")
	header:SetHeight(34)
	page.header = header
	page.title = Text(header, "GameFontNormalHuge")
	page.title:SetPoint("LEFT", 4, 0)

	BuildPreview(middle, header)

	local scroll = CreateFrame("ScrollFrame", nil, middle)
	scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
	scroll:SetPoint("BOTTOMRIGHT")
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(CONTENT_W, 1)
	scroll:SetScrollChild(content)
	page.scroll, page.content = scroll, content
	page.scrollLine = AttachScrollLine(scroll, middle)
end

function ns.ToggleOptions()
	if not frame then BuildWindow() end
	if frame:IsShown() then
		frame:Hide()
	else
		CloseBlizzardSettings()
		frame:Show()
	end
end

function ns.OpenOptions()
	if not frame then BuildWindow() end
	CloseBlizzardSettings()
	frame:Show()
end

-- Something outside the window changed a setting: redraw it.
function ns.RefreshOptions()
	if frame and frame:IsShown() then Panel.Refresh() end
end

-- Keys changed elsewhere (Esc > Key Bindings, /thumber resetbinds): the key rows follow.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("UPDATE_BINDINGS")
watcher:SetScript("OnEvent", function() ns.RefreshOptions() end)
