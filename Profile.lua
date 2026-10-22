-- Thumber profile: every setting, position and keybind as one copyable string.
--
--   Export: the options, the marks window / alert / minimap button positions, which
--           settings page was last open, and the four keybinds, as "THUMBERPROFILE:1:..."
--   Import: pasted back (here or on another character or install) it is checked, then
--           applied on top of the defaults, and everything is redrawn on the spot.
--
-- Marks are not part of a profile: they have their own sharing (Share.lua), and a profile
-- never touches them. Everything that comes in is untrusted: only known settings are
-- accepted, each must be the right type and inside the range the settings window allows,
-- and anything else is ignored and counted rather than applied.

local ADDON, ns = ...

local DB = ns.DB
local TAG, VERSION = "THUMBERPROFILE", 1
local MAX_TEXT, MAX_LINES = 60000, 300
local KEY_ACTIONS = { "THUMBER_UP", "THUMBER_DOWN", "THUMBER_NEUTRAL", "THUMBER_TOGGLE" }
local POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
	RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}
-- What the minimap button (LibDBIcon) keeps in ThumberDB.minimap.
local MINIMAP_BOOLS = { hide = true, lock = true, showInCompartment = true }
local MINIMAP_NUMS = { minimapPos = true, radius = true }

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffThumber|r: " .. msg) end

----------------------------------------------------------------------
-- Small text helpers
----------------------------------------------------------------------
local ESC = { ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "" }
local function Esc(s) return (tostring(s):gsub("[\\\t\n\r]", ESC)) end
local function Unesc(s)
	return (s:gsub("\\(.)", function(c) return c == "t" and "\t" or c == "n" and "\n" or c end))
end

local function Split(s, sep)
	local parts, from = {}, 1
	while true do
		local i = s:find(sep, from, true)
		if not i then parts[#parts + 1] = s:sub(from) break end
		parts[#parts + 1] = s:sub(from, i - 1)
		from = i + #sep
	end
	return parts
end

local function Sorted(set)
	local names = {}
	for name in pairs(set) do names[#names + 1] = name end
	table.sort(names)
	return names
end

local function FormatNumber(n) return ("%.14g"):format(n) end

local function IsFinite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function AddonVersion()
	local meta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
	return meta and meta(ADDON, "Version") or "?"
end

-- A typed value as a line's last two fields, and back.
local function Encode(value)
	local t = type(value)
	if t == "boolean" then return "b", value and "1" or "0" end
	if t == "number" then return "n", FormatNumber(value) end
	return "s", Esc(value)
end

local function Decode(kind, text)
	if kind == "b" then
		if text == "1" then return true end
		if text == "0" then return false end
	elseif kind == "n" then
		local n = tonumber(text)
		if IsFinite(n) then return n end
	elseif kind == "s" then
		return Unesc(text)
	end
	return nil
end

----------------------------------------------------------------------
-- Export
----------------------------------------------------------------------
-- The profile as text lines, and what it holds (for the summary).
local function BuildLines()
	local db = DB()
	local lines = { TAG .. " " .. VERSION, "addon\t" .. Esc(AddonVersion()) }
	local info = { settings = 0, positions = {}, keys = 0 }

	-- Every setting there is, as the saved value; one never changed is simply absent, and
	-- so comes out as the default wherever the profile lands.
	for _, name in ipairs(Sorted(ns.DEFAULTS)) do
		local value = db[name]
		if value ~= nil and type(value) == type(ns.DEFAULTS[name]) then
			local kind, text = Encode(value)
			lines[#lines + 1] = ("o\t%s\t%s\t%s"):format(name, kind, text)
			info.settings = info.settings + 1
		end
	end

	local pos = db.pos
	if type(pos) == "table" and IsFinite(pos[1]) and IsFinite(pos[2]) then
		lines[#lines + 1] = "pos\t1\tn\t" .. FormatNumber(pos[1])
		lines[#lines + 1] = "pos\t2\tn\t" .. FormatNumber(pos[2])
		info.positions[#info.positions + 1] = "marks window"
	end

	local ap = db.alertPos
	if type(ap) == "table" and type(ap[1]) == "string" and IsFinite(ap[3]) then
		lines[#lines + 1] = "alertPos\t1\ts\t" .. Esc(ap[1])
		lines[#lines + 1] = "alertPos\t2\ts\t" .. Esc(type(ap[2]) == "string" and ap[2] or ap[1])
		lines[#lines + 1] = "alertPos\t3\tn\t" .. FormatNumber(ap[3])
		lines[#lines + 1] = "alertPos\t4\tn\t" .. FormatNumber(IsFinite(ap[4]) and ap[4] or 0)
		info.positions[#info.positions + 1] = "alert"
	end

	local mm = db.minimap
	if type(mm) == "table" then
		local any = false
		for _, k in ipairs(Sorted(MINIMAP_BOOLS)) do
			if type(mm[k]) == "boolean" then
				lines[#lines + 1] = ("minimap\t%s\tb\t%s"):format(k, mm[k] and "1" or "0")
				any = true
			end
		end
		for _, k in ipairs(Sorted(MINIMAP_NUMS)) do
			if IsFinite(mm[k]) then
				lines[#lines + 1] = ("minimap\t%s\tn\t%s"):format(k, FormatNumber(mm[k]))
				any = true
			end
		end
		if any then info.positions[#info.positions + 1] = "minimap button" end
	end

	if type(db.optionsPage) == "string" then
		lines[#lines + 1] = "ui\toptionsPage\ts\t" .. Esc(db.optionsPage)
	end

	-- Keybinds live in WoW's binding system, not in ThumberDB; the marker says they were
	-- included, so an import also clears keys the profile left unbound.
	lines[#lines + 1] = "keys\tincluded\tb\t1"
	for _, action in ipairs(KEY_ACTIONS) do
		for _, key in ipairs({ GetBindingKey(action) }) do
			lines[#lines + 1] = ("key\t%s\ts\t%s"):format(action, Esc(key))
			info.keys = info.keys + 1
		end
	end
	return lines, info
end

-- The profile as one pasteable string, and its summary.
local function Export()
	local lines, info = BuildLines()
	return ("%s:%d:%s"):format(TAG, VERSION, ns.Share.B64Encode(table.concat(lines, "\n"))), info
end

----------------------------------------------------------------------
-- Import: read and validate
----------------------------------------------------------------------
-- A parsed profile, or nil and a reason. Nothing is applied here.
local function Parse(text)
	text = (text or ""):gsub("%s+", "")
	if text == "" then return nil, "Paste a profile string first." end
	if #text > MAX_TEXT then return nil, "That text is far too long to be a Thumber profile." end
	if text:match("^THUMBER:") then
		return nil, "That is a marks export. Use Share > Import for marks; this window is for settings."
	end
	local version, body = text:match("^" .. TAG .. ":(%d+):(.+)$")
	if not version then return nil, "That doesn't look like a Thumber profile." end
	if tonumber(version) ~= VERSION then
		return nil, "This profile was made by a different version of Thumber (format " .. version .. ")."
	end
	local raw = ns.Share.B64Decode(body)
	if not raw then return nil, "The text is damaged. Copy the whole string again." end

	local lines = Split(raw, "\n")
	if #lines > MAX_LINES then return nil, "That profile is far bigger than Thumber ever writes." end
	if lines[1] ~= TAG .. " " .. VERSION then return nil, "That profile's contents are not recognised." end

	local rules = ns.OptionRules()
	local p = { options = {}, ignored = 0, from = "?" }
	local pos, alert, minimap = {}, {}, {}
	local keys

	local function Ignore() p.ignored = p.ignored + 1 end

	for i = 2, #lines do
		local line = lines[i]
		if line ~= "" then
			local f = Split(line, "\t")
			local section, name, kind, raw = f[1], f[2], f[3], f[4]
			if section == "addon" then
				p.from = Unesc(name or "?"):sub(1, 20)
			elseif section == "keys" then
				keys = keys or {}
			elseif section == "o" then
				local value = Decode(kind, raw or "")
				local default = ns.DEFAULTS[name]
				local rule = rules[name]
				local ok = default ~= nil and value ~= nil and type(value) == type(default)
				if ok and type(value) == "number" and rule and rule.min then
					ok = value >= rule.min and value <= rule.max
				end
				if ok and type(value) == "string" then
					ok = #value <= 40 and not (rule and rule.values and not rule.values[value])
				end
				if ok then p.options[name] = value else Ignore() end
			elseif section == "pos" then
				local v = Decode(kind, raw or "")
				if (name == "1" or name == "2") and kind == "n" and v and math.abs(v) <= 20000 then
					pos[tonumber(name)] = v
				else
					Ignore()
				end
			elseif section == "alertPos" then
				local v = Decode(kind, raw or "")
				local n = tonumber(name)
				if n == 1 or n == 2 then
					if kind == "s" and v and POINTS[v] then alert[n] = v else Ignore() end
				elseif n == 3 or n == 4 then
					if kind == "n" and v and math.abs(v) <= 20000 then alert[n] = v else Ignore() end
				else
					Ignore()
				end
			elseif section == "minimap" then
				local v = Decode(kind, raw or "")
				if MINIMAP_BOOLS[name or ""] and kind == "b" and v ~= nil then
					minimap[name] = v
				elseif MINIMAP_NUMS[name or ""] and kind == "n" and v and math.abs(v) <= 100000 then
					minimap[name] = v
				else
					Ignore()
				end
			elseif section == "ui" then
				local v = Decode(kind, raw or "")
				local valid = false
				for _, page in ipairs(ns._optionPages or {}) do if page.key == v then valid = true end end
				if name == "optionsPage" and v and valid then p.optionsPage = v else Ignore() end
			elseif section == "key" then
				local v = Decode(kind, raw or "")
				local known = false
				for _, a in ipairs(KEY_ACTIONS) do if a == name then known = true end end
				if known and v and #v <= 40 and v:match("^[%u%d%-_]+$") then
					keys = keys or {}
					keys[name] = keys[name] or {}
					if #keys[name] < 2 then table.insert(keys[name], v) else Ignore() end
				else
					Ignore()
				end
			else
				Ignore()
			end
		end
	end

	if pos[1] and pos[2] then p.pos = { pos[1], pos[2] } elseif pos[1] or pos[2] then Ignore() end
	if alert[1] and alert[3] then
		p.alertPos = { alert[1], alert[2] or alert[1], alert[3], alert[4] or 0 }
	elseif next(alert) then
		Ignore()
	end
	if next(minimap) then p.minimap = minimap end
	p.keys = keys

	-- a summary line for the preview
	local n = 0
	for _ in pairs(p.options) do n = n + 1 end
	p.count = n
	p.where = {}
	if p.pos then p.where[#p.where + 1] = "marks window" end
	if p.alertPos then p.where[#p.where + 1] = "alert" end
	if p.minimap and (p.minimap.minimapPos or p.minimap.hide ~= nil) then p.where[#p.where + 1] = "minimap button" end
	p.keyCount = 0
	for _, list in pairs(keys or {}) do p.keyCount = p.keyCount + #list end
	return p
end

----------------------------------------------------------------------
-- Import: apply
----------------------------------------------------------------------
-- Everything a profile covers goes back to the defaults first, then the profile's own
-- values go on top: a setting the profile left at its default comes out at the default
-- here too, whatever it was before. Marks are not touched.
local function Apply(p)
	local db = DB()
	for name in pairs(ns.DEFAULTS) do db[name] = nil end
	db.pos, db.alertPos, db.optionsPage = nil, nil, nil

	-- The minimap button's library keeps a reference to this very table, so it is filled
	-- in place, never replaced.
	if type(db.minimap) ~= "table" then db.minimap = {} end
	for k in pairs(db.minimap) do if MINIMAP_BOOLS[k] or MINIMAP_NUMS[k] then db.minimap[k] = nil end end
	for k, v in pairs(p.minimap or {}) do db.minimap[k] = v end

	for name, value in pairs(p.options) do db[name] = value end
	if p.pos then db.pos = { p.pos[1], p.pos[2] } end
	if p.alertPos then db.alertPos = { p.alertPos[1], p.alertPos[2], p.alertPos[3], p.alertPos[4] } end
	if p.optionsPage then db.optionsPage = p.optionsPage end

	-- Keybinds, unless the profile has none to give or the game won't allow it now.
	local keysResult = "none"
	if p.keys then
		if InCombatLockdown() then
			keysResult = "combat"
		else
			for _, action in ipairs(KEY_ACTIONS) do
				for _, key in ipairs({ GetBindingKey(action) }) do SetBinding(key) end
			end
			for _, action in ipairs(KEY_ACTIONS) do
				for _, key in ipairs(p.keys[action] or {}) do SetBinding(key, action) end
			end
			if Thumber_SaveBindings then Thumber_SaveBindings() end
			keysResult = "applied"
		end
	end

	-- And everything on screen follows, no reload needed.
	if Thumber_UpdateMinimapButton then Thumber_UpdateMinimapButton() end
	local LDBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
	if LDBIcon and LDBIcon:IsRegistered("Thumber") then LDBIcon:Refresh("Thumber", db.minimap) end
	if ns.ApplyWindowPos then ns.ApplyWindowPos() end
	if ns.ApplyAlertPosition then ns.ApplyAlertPosition() end
	if ns.OnMarksChanged then ns.OnMarksChanged() end      -- badges
	if ns.OnOptionChanged then ns.OnOptionChanged() end    -- the settings preview
	if ns.RefreshOptions then ns.RefreshOptions() end      -- the settings window
	return keysResult
end

ns.Profile = { Export = Export, Parse = Parse, Apply = Apply }

----------------------------------------------------------------------
-- The profile window
----------------------------------------------------------------------
local BRONZE       = { 0.80, 0.60, 0.34 }
local BRONZE_MUTED = { 0.61, 0.48, 0.29 }
local dlg

local function Describe(count, where, keyCount)
	local parts = { count .. (count == 1 and " setting" or " settings") }
	if #where > 0 then parts[#parts + 1] = "positions (" .. table.concat(where, ", ") .. ")" end
	if keyCount and keyCount > 0 then parts[#parts + 1] = keyCount .. (keyCount == 1 and " keybind" or " keybinds") end
	return table.concat(parts, ", ")
end

local function BuildDialog()
	local f = CreateFrame("Frame", "ThumberProfileFrame", UIParent, "BackdropTemplate")
	f:SetSize(460, 322)
	f:SetPoint("CENTER", 0, 30)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	f:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 })
	f:SetBackdropBorderColor(BRONZE[1], BRONZE[2], BRONZE[3], 1)
	local art = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	art:SetPoint("TOPLEFT", 5, -5)
	art:SetPoint("BOTTOMRIGHT", -5, 5)
	art:SetTexture("Interface\\Collections\\CollectionsBackgroundTile", "REPEAT", "REPEAT")
	art:SetHorizTile(true)
	art:SetVertTile(true)
	local wash = f:CreateTexture(nil, "BACKGROUND", nil, 2)
	wash:SetAllPoints(art)
	wash:SetColorTexture(0, 0, 0, 0.5)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -12)
	title:SetText("Profile")
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	local rule = f:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
	rule:SetHeight(1)
	rule:SetPoint("TOPLEFT", 6, -34)
	rule:SetPoint("TOPRIGHT", -6, -34)

	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", 16, -44)
	hint:SetPoint("TOPRIGHT", -16, -44)
	hint:SetJustifyH("LEFT")
	hint:SetHeight(30)
	hint:SetText("All of Thumber's settings, positions and keybinds as one string, to move to another character or install, or to keep as a backup. Your marks are not included.")

	local eb
	local ok, sf = pcall(CreateFrame, "ScrollFrame", nil, f, "InputScrollFrameTemplate")
	if ok and sf and sf.EditBox then
		sf:SetPoint("TOPLEFT", 16, -86)
		sf:SetSize(410, 130)
		if sf.CharCount then sf.CharCount:Hide() end
		eb = sf.EditBox
		eb:SetWidth(390)
		eb:SetMaxLetters(0)
	else
		eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
		eb:SetPoint("TOPLEFT", 22, -86)
		eb:SetSize(400, 130)
		eb:SetMultiLine(true)
	end
	eb:SetFontObject(ChatFontNormal)
	eb:SetAutoFocus(false)
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f.eb = eb

	local summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	summary:SetPoint("TOPLEFT", 16, -226)
	summary:SetPoint("TOPRIGHT", -16, -226)
	summary:SetJustifyH("LEFT")
	summary:SetHeight(32)
	f.summary = summary

	local function Button(text, w, x, y, onClick)
		local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		b:SetSize(w, 22)
		b:SetPoint("TOPLEFT", x, y)
		b:SetText(text)
		b:SetScript("OnClick", onClick)
		return b
	end

	local function ClearParsed()
		f.parsed = nil
		f.apply:Hide()
	end

	Button("Export profile", 100, 16, -280, function()
		ClearParsed()
		local text, info = Export()
		eb:SetText(text)
		eb:HighlightText()
		eb:SetFocus()
		summary:SetText(("Exported %s. Press Ctrl+C to copy it, then paste it wherever you like."):format(
			Describe(info.settings, info.positions, info.keys)))
	end)
	Button("Check pasted profile", 140, 120, -280, function()
		ClearParsed()
		local p, err = Parse(eb:GetText())
		if not p then summary:SetText("|cffff6060" .. err .. "|r") return end
		f.parsed = p
		local text = ("Made with Thumber %s. It holds %s."):format(p.from, Describe(p.count, p.where, p.keyCount))
		if p.ignored > 0 then text = text .. (" (%d entries were not recognised and will be skipped.)"):format(p.ignored) end
		summary:SetText(text .. " Applying it replaces your current settings.")
		f.apply:Show()
	end)
	Button("Clear box", 66, 264, -280, function()
		eb:SetText("")
		ClearParsed()
		summary:SetText("")
	end)
	f.apply = Button("Apply profile", 100, 334, -280, function()
		local p = f.parsed
		if not p then return end
		local keysResult = Apply(p)
		f.parsed = nil
		f.apply:Hide()
		local text = "Profile applied."
		if keysResult == "combat" then
			text = text .. " Keybinds were left as they are, because you are in combat: apply it again after combat."
		end
		summary:SetText(text)
		Print(text)
	end)
	f.apply:Hide()
	f:Hide()
	return f
end

function ns.OpenProfile()
	dlg = dlg or BuildDialog()
	if dlg:IsShown() then dlg:Hide() else dlg:Show() end
end
