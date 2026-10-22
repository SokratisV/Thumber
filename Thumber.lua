-- Thumber — mark other players thumbs up / neutral / thumbs down, with an
-- optional note. Marks surface in unit tooltips and in a sortable list window.
--
-- WoW Forever (Interface 16001, Midnight 12.x API) and TBC Classic / Anniversary
-- (Interface 20505). Self-contained apart from the embedded LibDBIcon stack.

local ADDON, ns = ...

-- Friendly names shown in Esc > Key Bindings (next to Thumber).
BINDING_HEADER_THUMBER = "Thumber"
BINDING_NAME_THUMBER_UP = "Thumbs up target  (default: Arrow Up)"
BINDING_NAME_THUMBER_DOWN = "Thumbs down target  (default: Arrow Down)"
BINDING_NAME_THUMBER_NEUTRAL = "Neutral target  (default: Arrow Left)"
BINDING_NAME_THUMBER_TOGGLE = "Open the marks list  (default: Arrow Right)"

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
-- The look of each mark, and its list sort order. The ReadyCheck textures ship
-- with every client and read cleanly as up (green check) / neutral (yellow ?) /
-- down (red cross).
local MARK = {
	up = {
		label = "Thumbs Up",
		tex   = "Interface\\RaidFrame\\ReadyCheck-Ready",
		color = { 0.30, 0.85, 0.35 },
		order = 1,
	},
	neutral = {
		label = "Neutral",
		tex   = "Interface\\RaidFrame\\ReadyCheck-Waiting",
		color = { 0.95, 0.82, 0.25 },
		order = 2,
	},
	down = {
		label = "Thumbs Down",
		tex   = "Interface\\RaidFrame\\ReadyCheck-NotReady",
		color = { 0.92, 0.32, 0.32 },
		order = 3,
	},
}
-- Precompute the per-mark colour hex and the size-0 icon escape once; these are
-- constant and would otherwise be string.format'd on every row render and every
-- tooltip refresh frame.
for _, info in pairs(MARK) do
	info.hex = ("%02x%02x%02x"):format(info.color[1] * 255, info.color[2] * 255, info.color[3] * 255)
	info.icon0 = ("|T%s:0|t"):format(info.tex)
end

local function MarkIcon(mark, size)
	local info = MARK[mark]
	if not info then return "" end
	if not size or size == 0 then return info.icon0 end
	return ("|T%s:%d|t"):format(info.tex, size)
end
local function MarkHex(mark)
	local info = MARK[mark]
	return info and info.hex or "ffffff"
end

local NOTE_PREVIEW = 40 -- chars of the note shown inline in a list row

-- The window borrows FlareUI's look: Blizzard's own tooltip border and
-- Collections tile, tinted bronze, under a black wash.
local BRONZE       = { 0.80, 0.60, 0.34 }
local BRONZE_MUTED = { 0.61, 0.48, 0.29 }

-- Midnight can hand addon-tainted code opaque "secret" values. A secret still
-- reports its underlying type, so testing for one has to come before any compare.
local issecret = _G.issecretvalue
local function IsSecret(v)
	return issecret ~= nil and issecret(v)
end

----------------------------------------------------------------------
-- Saved-variables helpers
----------------------------------------------------------------------
local function DB()
	ThumberDB = ThumberDB or {}
	return ThumberDB
end
local function Marks()
	local d = DB()
	d.marks = d.marks or {}
	return d.marks
end

-- WoW Forever gives every character a first name and a surname, unique across
-- the region, and UnitName answers (first name, surname) where Classic answers
-- (name, realm). So there the second value is a surname to keep, not a realm to
-- append. Detected by feature, never by client flavour.
local function UniqueNames()
	return RegionalUniqueNamesEnabled ~= nil and RegionalUniqueNamesEnabled() == true
end

local function SurnameSeparator()
	local consts = Constants and Constants.CharacterNameSeparatorConsts
	return consts and consts.CHARACTERNAME_SURNAME_SEPARATOR or " "
end

-- A unit's full name as the key form: "First Surname" on Forever, "Name-Realm"
-- for a cross-realm player elsewhere, the bare name otherwise. Returns the key
-- and the first name, or nothing if it can't be read (a secret, or no unit).
local function UnitKey(unit)
	-- The player's own surname only comes back from the unmodified name.
	local getName = (unit == "player" and UnitNameUnmodified) or UnitName
	local name, second = getName(unit)
	if not name or IsSecret(name) or name == "" then return end
	if second and IsSecret(second) then return end
	local hasSecond = second and second ~= ""
	if UniqueNames() then
		local sep = SurnameSeparator()
		if hasSecond and not name:find(sep, 1, true) then return name .. sep .. second, name end
		return name, name
	end
	return hasSecond and (name .. "-" .. second) or name, name
end

-- Build a stable key from a unit. Returns key, displayName, class. On Forever
-- the display name keeps the surname ("First Surname"); elsewhere it is the bare
-- name and the realm lives only in the key.
local function KeyFromUnit(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
	local key, name = UnitKey(unit)
	if not key then return end
	local _, class = UnitClass(unit)
	return key, UniqueNames() and key or name, class
end

-- Capitalise the first letter of a typed name (WoW always does) and, on Forever,
-- of the surname after it. The old "First-Surname" spelling is accepted too.
local function NormalizeKey(text)
	local key = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if UniqueNames() then
		local sep = SurnameSeparator()
		key = key:gsub("^([^%-%s]+)%-([^%-%s]+)$", "%1" .. sep:gsub("%%", "%%%%") .. "%2")
		local first, rest = key:find(sep, 1, true)
		if first then
			local surname = key:sub(rest + 1):gsub("^%l", string.upper)
			key = key:sub(1, rest) .. surname
		end
	end
	return (key:gsub("^%l", string.upper))
end

-- Before Thumber understood surnames, a Forever mark was saved as "First-Surname"
-- with only the first name to show. Re-key those as "First Surname". Only ever
-- touches keys that look like exactly that, and never overwrites an existing mark.
local function MigrateSurnameKeys()
	if not UniqueNames() then return end
	local marks = Marks()
	local sep, moving = SurnameSeparator(), {}
	for key in pairs(marks) do
		local first, surname = key:match("^([^%-%s]+)%-([^%-%s]+)$")
		if first and not marks[first .. sep .. surname] then
			moving[#moving + 1] = { key, first .. sep .. surname }
		end
	end
	for _, m in ipairs(moving) do
		local entry = marks[m[1]]
		entry.name = m[2]
		marks[m[2]], marks[m[1]] = entry, nil
	end
end

-- Display name for a key (strip the "-Realm" suffix for the local realm look).
local function DisplayName(key, entry)
	if entry and entry.name then return entry.name end
	return (key or ""):match("^([^-]+)") or key
end

local function ClassHex(class)
	local c = class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
	if c then return ("%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
	return nil
end

-- Shared with Extras.lua, which loads right after this file.
ns.MARK, ns.DB, ns.Marks = MARK, DB, Marks
ns.IsSecret, ns.UnitKey, ns.UniqueNames = IsSecret, UnitKey, UniqueNames
ns.DisplayName, ns.ClassHex, ns.MarkIcon = DisplayName, ClassHex, MarkIcon
ns.NormalizeKey = NormalizeKey

----------------------------------------------------------------------
-- Data API
----------------------------------------------------------------------
local RefreshList -- forward decl (defined with the window)
local function Refresh()
	if RefreshList then RefreshList() end
	if ns.OnMarksChanged then ns.OnMarksChanged() end -- badges follow the data
end
ns.Refresh = Refresh

local function SetMark(key, name, mark, class)
	if not key or key == "" then return end
	local m = Marks()
	local e = m[key]
	if not e then e = { name = name or DisplayName(key) }; m[key] = e end
	if name then e.name = name end
	if class then e.class = class end
	e.mark = mark
	e.time = time()
	Refresh()
	return e
end

local function SetNote(key, note)
	if not key or key == "" then return end
	local m = Marks()
	local e = m[key]
	if not e then
		-- Saving a note for someone not yet marked implies a neutral mark.
		e = SetMark(key, nil, "neutral")
	end
	e.note = (note and note ~= "") and note or nil
	e.time = time()
	Refresh()
end

local function RemoveMark(key)
	Marks()[key] = nil
	Refresh()
end

-- Quick-action helper: if the player already has exactly `mark`, remove them
-- (toggle off); otherwise set/change it. Returns "removed", "set", or "changed".
local function ToggleMark(key, name, mark, class)
	if not key or key == "" then return end
	local e = Marks()[key]
	if e and e.mark == mark then
		RemoveMark(key)
		return "removed"
	end
	local existed = e ~= nil
	SetMark(key, name, mark, class)
	return existed and "changed" or "set"
end

-- Sorted snapshot of all marks: grouped by mark (up, neutral, down) then name.
local function SortedMarks(filter, search)
	local list = {}
	for key, e in pairs(Marks()) do
		local keep = not filter or filter == "all" or e.mark == filter
		if keep and search and search ~= "" then
			keep = DisplayName(key, e):lower():find(search, 1, true)
				or (e.note and e.note:lower():find(search, 1, true))
		end
		if keep then list[#list + 1] = { key = key, entry = e } end
	end
	table.sort(list, function(a, b)
		local oa = (MARK[a.entry.mark] or MARK.neutral).order
		local ob = (MARK[b.entry.mark] or MARK.neutral).order
		if oa ~= ob then return oa < ob end
		return DisplayName(a.key, a.entry):lower() < DisplayName(b.key, b.entry):lower()
	end)
	return list
end

-- "just now", "5m ago", "3h ago", "2d ago", "4w ago".
local function Ago(t)
	if not t then return "" end
	local d = time() - t
	if d < 60 then return "just now" end
	if d < 3600 then return ("%dm ago"):format(math.floor(d / 60)) end
	if d < 86400 then return ("%dh ago"):format(math.floor(d / 3600)) end
	if d < 604800 then return ("%dd ago"):format(math.floor(d / 86400)) end
	return ("%dw ago"):format(math.floor(d / 604800))
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local ROW_H, MAX_VIEW = 20, 250
local win, rows

local function SavePos(frame)
	local left, bottom = frame:GetLeft(), frame:GetBottom()
	if not left then return end
	DB().pos = { left, bottom }
end
local function RestorePos(frame)
	local s = DB().pos
	if not s then return false end
	frame:ClearAllPoints()
	frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", s[1], s[2])
	return true
end

-- Move the marks window to the saved position (after a profile import), or back to the centre.
function ns.ApplyWindowPos()
	if not win then return end
	if not RestorePos(win) then
		win:ClearAllPoints()
		win:SetPoint("CENTER")
	end
end

local function HeaderIcon(parent, texture, tip, onClick, x)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(16, 16)
	b:SetPoint("TOPRIGHT", parent, "TOPRIGHT", x, -9)
	b:SetNormalTexture(texture)
	b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	b:SetScript("OnClick", onClick)
	b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(tip); GameTooltip:Show() end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

----------------------------------------------------------------------
-- The Manually Mark dialog: add or change a mark by typing a name
----------------------------------------------------------------------
local dlg

-- Escape closes a window by way of UISpecialFrames, and one press closes every listed
-- window that is open. So while this dialog is up the marks window steps off the list,
-- and goes back on once the dialog has closed: Escape then closes the dialog first,
-- and the window on the next press.
local function EscapeList(name, on)
	local at
	for i, n in ipairs(UISpecialFrames) do
		if n == name then at = i break end
	end
	if on and not at then
		tinsert(UISpecialFrames, name)
	elseif not on and at then
		tremove(UISpecialFrames, at)
	end
end

-- The Use target button and the keybinds all go through KeyFromUnit, which refuses
-- anything that isn't a player. A name typed into the box has no unit behind it to
-- check -- unless it happens to name something we can see right now, which is how an
-- NPC gets in: target a wolf, type its name, mark it. So check the units we *can*
-- resolve and refuse a known non-player.
local function IsKnownNonPlayer(name)
	-- A cross-realm key is "Name-Realm" while UnitName gives the bare name, so
	-- compare on the display form or the check silently never matches. On
	-- Forever the key is the full "First Surname", which is what UnitKey builds.
	local bare = UniqueNames() and name or DisplayName(name)
	for _, unit in ipairs({ "target", "mouseover", "focus", name }) do
		local key, first
		if UnitExists(unit) then key, first = UnitKey(unit) end
		if key and (UniqueNames() and key or first) == bare then
			-- Only a real "no" refuses. If the client won't say whether this is a
			-- player -- a secret, or anything that isn't a plain boolean -- allow
			-- the mark. Refusing on an unreadable answer would block legitimate
			-- players, and "unknown" is not "no" anywhere else in this addon.
			local isPlayer = UnitIsPlayer(unit)
			if IsSecret(isPlayer) or type(isPlayer) ~= "boolean" then return false end
			return isPlayer == false
		end
	end
	return false   -- nobody we can see by that name; can't say, so allow it
end

local PILL_OFF = { 0.23, 0.18, 0.11 }
local function StylePill(b, selected)
	local c = selected and BRONZE or PILL_OFF
	b:SetBackdropBorderColor(c[1], c[2], c[3], 1)
	if selected then b:SetBackdropColor(0.25, 0.18, 0.07, 0.9) else b:SetBackdropColor(0.055, 0.047, 0.035, 0.8) end
	if selected then b.text:SetTextColor(1, 0.82, 0) else b.text:SetTextColor(0.78, 0.72, 0.58) end
end

local function DialogButton(parent, text, w, x, y, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(w, 22)
	b:SetPoint("TOPLEFT", x, y)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

----------------------------------------------------------------------
-- Bulk clear: remove every mark the list is showing
----------------------------------------------------------------------
-- The filter and the search both apply, so "thumbs down" + Clear removes the thumbs
-- downs and nothing else. It takes a second click (no dialog), and what it removed can
-- be brought back with Undo for a little while.
local CLEAR_ARM, UNDO_FOR = 4, 15
local clearState = { armedSig = nil, undo = nil }

local function ShownKeys()
	local keys = {}
	for _, item in ipairs(SortedMarks(win.filter, win.search)) do keys[#keys + 1] = item.key end
	return keys
end

-- What the button would clear right now; arming is only good for this exact list.
local function ClearSig(n) return (win.filter or "all") .. "|" .. (win.search or "") .. "|" .. n end

local function ClearClick()
	if clearState.undo then
		local undo = clearState.undo
		clearState.undo = nil
		for key, entry in pairs(undo.entries) do
			if not Marks()[key] then Marks()[key] = entry end -- never over something added since
		end
		Refresh()
		return
	end
	local keys = ShownKeys()
	if #keys == 0 then return end
	local sig = ClearSig(#keys)
	if clearState.armedSig ~= sig then
		clearState.armedSig = sig
		C_Timer.After(CLEAR_ARM, function()
			if clearState.armedSig == sig then
				clearState.armedSig = nil
				RefreshList()
			end
		end)
		RefreshList()
		return
	end
	local stash = {}
	for _, key in ipairs(keys) do
		stash[key] = Marks()[key]
		Marks()[key] = nil
	end
	clearState.armedSig = nil
	local undo = { entries = stash, n = #keys }
	clearState.undo = undo
	C_Timer.After(UNDO_FOR, function()
		if clearState.undo == undo then
			clearState.undo = nil
			RefreshList()
		end
	end)
	Refresh()
end

-- The button's label, from the list as it is now.
local function UpdateClearButton(n)
	local b = win.clearBtn
	if clearState.armedSig and clearState.armedSig ~= ClearSig(n) then clearState.armedSig = nil end
	if clearState.undo then
		b:SetText("Undo clear (" .. clearState.undo.n .. ")")
		b:Enable()
	elseif n == 0 then
		b:SetText("Nothing to clear")
		b:Disable()
	elseif clearState.armedSig then
		b:SetText("|cffff6060Click again: clear " .. n .. "|r")
		b:Enable()
	else
		local everything = (win.filter or "all") == "all" and (win.search or "") == ""
		b:SetText((everything and "Clear all (" or "Clear shown (") .. n .. ")")
		b:Enable()
	end
end

local function BuildMarkDialog()
	local f = CreateFrame("Frame", "ThumberMarkFrame", UIParent, "BackdropTemplate")
	-- Each mark button is as wide as its own text needs ("Thumbs Down" is the longest),
	-- and the dialog is as wide as the three of them side by side.
	local MARKS = { "up", "neutral", "down" }
	local LEFT, RIGHT, GAP = 72, 16, 4
	local probe = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	local pillW, total = {}, 0
	for i, mark in ipairs(MARKS) do
		probe:SetText(MarkIcon(mark, 14) .. " " .. MARK[mark].label)
		pillW[i] = math.max(70, math.ceil(probe:GetStringWidth() or 60) + 24)
		total = total + pillW[i] + (i > 1 and GAP or 0)
	end
	probe:Hide()
	local W = math.max(344, LEFT + total + RIGHT)
	f:SetSize(W, 262)
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

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOPLEFT", 16, -12)
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	local rule = f:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
	rule:SetHeight(1)
	rule:SetPoint("TOPLEFT", 6, -34)
	rule:SetPoint("TOPRIGHT", -6, -34)

	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.hint:SetPoint("TOPLEFT", 16, -44)
	f.hint:SetPoint("TOPRIGHT", -16, -44)
	f.hint:SetJustifyH("LEFT")
	f.hint:SetText("Type a player's name or use your target, choose a mark, then save.")

	f.classHint = {}

	-- Player
	local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	nameLabel:SetPoint("TOPLEFT", 16, -78)
	nameLabel:SetText("Player")
	local nameBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	nameBox:SetPoint("TOPLEFT", LEFT, -73)
	nameBox:SetSize(W - LEFT - RIGHT - 86 - 8, 20)
	nameBox:SetAutoFocus(false)
	nameBox:SetFontObject(ChatFontNormal)
	f.nameBox = nameBox
	local nameHint = nameBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	nameHint:SetPoint("LEFT", 2, 0)
	nameHint:SetText("Name, e.g. Meowly Meow")
	f.nameHint = nameHint

	-- Mark
	local markLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	markLabel:SetPoint("TOPLEFT", 16, -118)
	markLabel:SetText("Mark")
	f.pills = {}
	local px = LEFT
	for i, mark in ipairs(MARKS) do
		local info = MARK[mark]
		local p = CreateFrame("Button", nil, f, "BackdropTemplate")
		p:SetSize(pillW[i], 26)
		p:SetPoint("TOPLEFT", px, -112)
		px = px + pillW[i] + GAP
		p:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
		p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		p.text:SetPoint("CENTER")
		p.text:SetText(MarkIcon(mark, 14) .. " " .. info.label)
		p.mark = mark
		p:SetScript("OnClick", function() f.mark, f.autoMark = mark, nil; f.Refresh() end)
		f.pills[i] = p
	end

	-- Note
	local noteLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	noteLabel:SetPoint("TOPLEFT", 16, -154)
	noteLabel:SetText("Note")
	local noteBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	noteBox:SetPoint("TOPLEFT", LEFT, -149)
	noteBox:SetSize(W - LEFT - RIGHT, 20)
	noteBox:SetAutoFocus(false)
	noteBox:SetFontObject(ChatFontNormal)
	noteBox:SetMaxLetters(255)
	f.noteBox = noteBox
	local noteHint = noteBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	noteHint:SetPoint("LEFT", 2, 0)
	noteHint:SetText("Optional: shown in their tooltip")
	f.noteHint = noteHint

	f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.status:SetPoint("TOPLEFT", 16, -186)
	f.status:SetPoint("TOPRIGHT", -16, -186)
	f.status:SetJustifyH("LEFT")
	f.status:SetHeight(14)

	local function Key()
		local k = NormalizeKey(nameBox:GetText())
		return k ~= "" and k or nil
	end

	-- Redraw everything that depends on what is typed and picked.
	function f.Refresh()
		local key = Key()
		local e = key and Marks()[key]
		-- A mark picked for you (their current one) is not carried over to someone else.
		if f.autoMark and f.autoKey ~= key then f.mark, f.autoMark, f.autoKey = nil, nil, nil end
		-- Someone already marked: their current mark is simply shown selected, which says
		-- so by itself, until you pick another.
		if e and not f.mark then f.mark, f.autoMark, f.autoKey = e.mark, true, key end
		f.title:SetText(f.editKey and "Edit mark" or "Manually Mark")
		nameHint:SetShown((nameBox:GetText() or "") == "")
		noteHint:SetShown((noteBox:GetText() or "") == "")
		for _, p in ipairs(f.pills) do StylePill(p, f.mark == p.mark) end
		f.status:SetText((key and not e) and "New player" or "")
		f.save:SetText(e and "Update mark" or "Save mark")
		f.remove:SetShown(e ~= nil)
	end

	local function Fail(msg) f.status:SetText("|cffff6060" .. msg .. "|r") end

	-- Fill the form from an existing mark (or just the name, for someone new).
	local function Load(key)
		nameBox:SetText(key or "")
		nameBox:SetCursorPosition(0)
		local e = key and Marks()[key]
		if e then f.mark, f.autoMark, f.autoKey = e.mark, true, key end
		noteBox:SetText((e and e.note) or noteBox:GetText() or "")
		noteBox:SetCursorPosition(0)
		f.editKey = e and key or nil
		f.Refresh()
	end

	local function Save()
		local key = Key()
		if not key then return Fail("Type a player's name, or press Use target.") end
		if not f.mark then return Fail("Pick a mark.") end
		if IsKnownNonPlayer(key) then return Fail(key .. " isn't a player.") end
		SetMark(key, DisplayName(key), f.mark, f.classHint[key])
		SetNote(key, noteBox:GetText())
		f:Hide()
	end
	f.Save = Save

	local useTarget = DialogButton(f, "Use target", 86, W - RIGHT - 86, -72, function()
		local key, _, class = KeyFromUnit("target")
		if not key then key, _, class = KeyFromUnit("mouseover") end
		if not key then return Fail("Target a player first.") end
		f.classHint[key] = class
		Load(key)
	end)
	useTarget:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Fill the name from your target (or mouseover).", nil, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	useTarget:SetScript("OnLeave", function() GameTooltip:Hide() end)

	nameBox:SetScript("OnTextChanged", function() f.Refresh() end)
	nameBox:SetScript("OnEnterPressed", function() noteBox:SetFocus() end)
	nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	noteBox:SetScript("OnTextChanged", function() f.Refresh() end)
	noteBox:SetScript("OnEnterPressed", Save)
	noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	f.remove = DialogButton(f, "Remove", 80, 16, -222, function()
		local key = Key()
		if key and Marks()[key] then RemoveMark(key) end
		f:Hide()
	end)
	DialogButton(f, "Cancel", 74, W - RIGHT - 88 - 6 - 74, -222, function() f:Hide() end)
	f.save = DialogButton(f, "Save mark", 88, W - RIGHT - 88, -222, Save)

	f.Load = Load
	f:SetScript("OnShow", function() EscapeList("ThumberFrame", false) end)
	f:SetScript("OnHide", function(self)
		self.editKey = nil
		RefreshList()
		-- Put the marks window back a frame later, not now: this hide may be the Escape
		-- loop itself, which would reach the name we just added and close it too.
		C_Timer.After(0, function()
			if win and win:IsShown() and not self:IsShown() then EscapeList("ThumberFrame", true) end
		end)
	end)
	f:Hide()
	EscapeList("ThumberMarkFrame", true)
	return f
end

-- Open the dialog empty (Manually Mark), or on an existing mark to edit it.
function ns.OpenMarkDialog(key)
	dlg = dlg or BuildMarkDialog()
	dlg.mark, dlg.editKey, dlg.autoMark, dlg.autoKey = nil, nil, nil, nil
	dlg.classHint = {}
	dlg.nameBox:SetText("")
	dlg.noteBox:SetText("")
	dlg:ClearAllPoints()
	if win and win:IsShown() then
		dlg:SetPoint("TOPLEFT", win, "TOPRIGHT", 8, 0)
	else
		dlg:SetPoint("CENTER", 0, 40)
	end
	if key and Marks()[key] then dlg.Load(key) else dlg.Refresh() end
	dlg:Show()
	if not (key and Marks()[key]) then dlg.nameBox:SetFocus() end
	RefreshList()
end

local function GetWindow()
	if win then return win end

	local f = CreateFrame("Frame", "ThumberFrame", UIParent, "BackdropTemplate")
	f:SetSize(400, 392)
	if not RestorePos(f) then f:SetPoint("CENTER") end
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos(self) end)
	f:SetScript("OnHide", function(self)
		SavePos(self)
		if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_CLOSE then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE) end
	end)
	f:SetClampedToScreen(true)
	f:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 })
	f:SetBackdropBorderColor(BRONZE[1], BRONZE[2], BRONZE[3], 1)
	-- Blizzard's Collections tile under a black wash, inside the border.
	local art = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	art:SetPoint("TOPLEFT", 5, -5)
	art:SetPoint("BOTTOMRIGHT", -5, 5)
	art:SetTexture("Interface\\Collections\\CollectionsBackgroundTile", "REPEAT", "REPEAT")
	art:SetHorizTile(true)
	art:SetVertTile(true)
	local wash = f:CreateTexture(nil, "BACKGROUND", nil, 2)
	wash:SetAllPoints(art)
	wash:SetColorTexture(0, 0, 0, 0.5)
	f:SetScript("OnShow", function()
		-- Closes on Escape, unless the Manually Mark dialog is up: that closes first.
		EscapeList("ThumberFrame", not (dlg and dlg:IsShown()))
		if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end
	end)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -12)
	title:SetText("Thumber")

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	HeaderIcon(f, "Interface\\Buttons\\UI-OptionsButton", "Settings",
		function() if Thumber_OpenSettings then Thumber_OpenSettings() end end, -38)

	local shareBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	shareBtn:SetSize(54, 20)
	shareBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -60, -9)
	shareBtn:SetText("Share")
	shareBtn:SetScript("OnClick", function() if ns.OpenShare then ns.OpenShare() end end)
	shareBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Send your marks to someone, or export and import them.", nil, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	shareBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Bronze rule under the header, as in FlareUI's windows.
	local headerLine = f:CreateTexture(nil, "ARTWORK")
	headerLine:SetColorTexture(BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
	headerLine:SetHeight(1)
	headerLine:SetPoint("TOPLEFT", 6, -34)
	headerLine:SetPoint("TOPRIGHT", -6, -34)

	----------------------------------------------------------------
	-- Toolbar: the one way to add someone by hand
	----------------------------------------------------------------
	local markBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	markBtn:SetSize(130, 22)
	markBtn:SetPoint("TOPLEFT", 14, -43)
	markBtn:SetText("Manually Mark")
	markBtn:SetScript("OnClick", function() ns.OpenMarkDialog(nil) end)
	markBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Manually Mark")
		GameTooltip:AddLine("Mark someone by typing their name, without targeting them. You can also set their note.", 0.85, 0.85, 0.85, true)
		GameTooltip:Show()
	end)
	markBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.markBtn = markBtn

	----------------------------------------------------------------
	-- Search and filter
	----------------------------------------------------------------
	f.filter, f.search = "all", ""

	local searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	searchBox:SetPoint("TOPLEFT", 20, -72)
	searchBox:SetPoint("TOPRIGHT", -20, -72)
	searchBox:SetHeight(20)
	searchBox:SetAutoFocus(false)
	searchBox:SetFontObject(ChatFontNormal)
	local hint = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", 2, 0)
	hint:SetText("Search names and notes")
	searchBox:SetScript("OnTextChanged", function(self)
		local text = self:GetText() or ""
		hint:SetShown(text == "")
		f.search = text:gsub("^%s+", ""):gsub("%s+$", ""):lower()
		RefreshList()
	end)
	searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
	f.searchBox = searchBox

	-- One pill per filter, right-aligned: All, thumbs up, neutral, thumbs down.
	f.pills = {}
	local PILLS = { { "all", 52 }, { "up", 46 }, { "neutral", 46 }, { "down", 46 } }
	local x = -14
	for i = #PILLS, 1, -1 do
		local key, w = PILLS[i][1], PILLS[i][2]
		local p = CreateFrame("Button", nil, f, "BackdropTemplate")
		p:SetSize(w, 20)
		p:SetPoint("TOPRIGHT", x, -44)
		p:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
		p:SetBackdropColor(0.055, 0.047, 0.035, 0.8)
		p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		p.text:SetPoint("CENTER")
		p.key = key
		p:SetScript("OnClick", function() f.filter = key; RefreshList() end)
		f.pills[i] = p
		x = x - w - 4
	end

	----------------------------------------------------------------
	-- Scrollable list
	----------------------------------------------------------------
	local scroll = CreateFrame("ScrollFrame", "ThumberScroll", f)
	scroll:SetPoint("TOPLEFT", 12, -102)
	scroll:SetPoint("TOPRIGHT", -26, -102)
	scroll:SetHeight(MAX_VIEW)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(362, 1)
	scroll:SetScrollChild(content)
	f.scroll, f.content = scroll, content

	-- A faint track and a bronze thumb, shown only when there is something to
	-- scroll. Drag the thumb or click the track; the wheel scrolls the list.
	local line = CreateFrame("Frame", nil, f)
	line:SetWidth(10)
	line:EnableMouse(true)
	line:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
	line:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
	local track = line:CreateTexture(nil, "ARTWORK")
	track:SetWidth(2)
	track:SetPoint("TOP")
	track:SetPoint("BOTTOM")
	track:SetColorTexture(BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.25)
	local thumb = line:CreateTexture(nil, "OVERLAY")
	thumb:SetWidth(2)
	thumb:SetColorTexture(BRONZE[1], BRONZE[2], BRONZE[3], 1)

	local function ScrollRange() return scroll:GetVerticalScrollRange() or 0 end
	local function UpdateLine()
		local range, h = ScrollRange(), scroll:GetHeight() or 0
		if range <= 0.5 or h <= 0 then line:Hide() return end
		line:Show()
		local th = math.max(16, h * h / (h + range))
		local pos = math.max(0, math.min(1, (scroll:GetVerticalScroll() or 0) / range))
		thumb:SetHeight(th)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", line, "TOP", 0, -(h - th) * pos)
	end
	local function CursorToScroll()
		local _, y = GetCursorPosition()
		y = y / line:GetEffectiveScale()
		local top, h, th = line:GetTop(), line:GetHeight(), thumb:GetHeight()
		if not (top and h and h > th) then return end
		local pos = math.max(0, math.min(1, (top - y - th / 2) / (h - th)))
		scroll:SetVerticalScroll(pos * ScrollRange())
	end
	line:SetScript("OnMouseDown", function(self) self.dragging = true; thumb:SetWidth(4); CursorToScroll() end)
	line:SetScript("OnMouseUp", function(self) self.dragging = nil; thumb:SetWidth(self:IsMouseOver() and 4 or 2) end)
	line:SetScript("OnEnter", function() thumb:SetWidth(4) end)
	line:SetScript("OnLeave", function(self) if not self.dragging then thumb:SetWidth(2) end end)
	line:SetScript("OnUpdate", function(self) if self.dragging then CursorToScroll() end end)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		self:SetVerticalScroll(math.max(0, math.min(ScrollRange(), (self:GetVerticalScroll() or 0) - delta * ROW_H * 2)))
	end)
	scroll:HookScript("OnVerticalScroll", UpdateLine)
	scroll:HookScript("OnScrollRangeChanged", UpdateLine)
	scroll:HookScript("OnSizeChanged", UpdateLine)
	f.UpdateScrollLine = UpdateLine

	local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	empty:SetPoint("TOPLEFT", 18, -108)
	empty:SetText("No marked players yet. Press Manually Mark, or target someone")
	local empty2 = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	empty2:SetPoint("TOPLEFT", 18, -122)
	empty2:SetText("and use /thumbsup | /thumbsdown | /neutral, or the arrow keys.")
	f.empty, f.empty2 = empty, empty2
	f.emptyText = { empty:GetText(), empty2:GetText() }

	local tip = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	tip:SetPoint("BOTTOMLEFT", 16, 12)
	tip:SetText("Click a player to edit them.")

	local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	clearBtn:SetSize(160, 20)
	clearBtn:SetPoint("BOTTOMRIGHT", -14, 8)
	clearBtn:SetScript("OnClick", ClearClick)
	clearBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Clear marks")
		GameTooltip:AddLine("Removes every mark the list is showing; the filter and the search both apply. Click twice to confirm. Afterwards an Undo button is offered for " .. UNDO_FOR .. " seconds.", 0.85, 0.85, 0.85, true)
		GameTooltip:Show()
	end)
	clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	f.clearBtn = clearBtn

	-- CreateFrame frames are shown by default; start hidden so the first toggle
	-- opens the window instead of hiding the freshly-created (already-shown) one.
	f:Hide()
	win, rows = f, {}
	return f
end

local function GetRow(i)
	if rows[i] then return rows[i] end
	local r = CreateFrame("Button", nil, win.content)
	r:SetSize(362, ROW_H)

	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(16, 16)
	r.icon:SetPoint("LEFT", 2, 0)

	r.del = CreateFrame("Button", nil, r)
	r.del:SetSize(16, 16)
	r.del:SetPoint("RIGHT", 0, 0)
	r.del:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
	r.del:GetNormalTexture():SetVertexColor(0.9, 0.4, 0.4)
	r.del:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
	r.del:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Remove this mark")
		GameTooltip:Show()
	end)
	r.del:SetScript("OnLeave", function() GameTooltip:Hide() end)
	r.del:SetScript("OnClick", function()
		if r.key then RemoveMark(r.key) end
	end)

	r.time = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	r.time:SetPoint("RIGHT", r.del, "LEFT", -6, 0)
	r.time:SetWidth(58)
	r.time:SetJustifyH("RIGHT")

	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
	r.text:SetPoint("RIGHT", r.time, "LEFT", -6, 0)
	r.text:SetJustifyH("LEFT")
	r.text:SetWordWrap(false)

	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 0.82, 0, 0.06)

	r.selbg = r:CreateTexture(nil, "BACKGROUND")
	r.selbg:SetAllPoints()
	r.selbg:SetColorTexture(BRONZE[1], BRONZE[2], BRONZE[3], 0.18)
	r.selbg:Hide()

	r:SetScript("OnClick", function(self)
		if self.key then ns.OpenMarkDialog(self.key) end
	end)
	r:SetScript("OnEnter", function(self)
		local e = self.key and Marks()[self.key]
		if not e then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(DisplayName(self.key, e), 1, 1, 1)
		local info = MARK[e.mark] or MARK.neutral
		GameTooltip:AddLine(MarkIcon(e.mark) .. " |cff" .. MarkHex(e.mark) .. info.label .. "|r")
		if e.note then GameTooltip:AddLine("\"" .. e.note .. "\"", 0.85, 0.85, 0.85, true) end
		if e.lastSeen then
			GameTooltip:AddLine(("Last seen %s%s%s"):format(Ago(e.lastSeen),
				e.zone and (" in " .. e.zone) or "", e.level and (", level " .. e.level) or ""), 0.6, 0.55, 0.43, true)
		end
		if e.time then
			GameTooltip:AddLine("Marked " .. date("%Y-%m-%d", e.time), 0.6, 0.55, 0.43)
		end
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)

	rows[i] = r
	return r
end

-- (Re)render the list of all marked players.
function RefreshList()
	if not win or not win:IsShown() then return end
	local list = SortedMarks(win.filter, win.search)
	win.empty:SetShown(#list == 0)
	win.empty2:SetShown(#list == 0)

	-- Counts for the filter pills, and which pill is active.
	local counts = { all = 0, up = 0, neutral = 0, down = 0 }
	for _, e in pairs(Marks()) do
		counts.all = counts.all + 1
		counts[e.mark] = (counts[e.mark] or 0) + 1
	end
	for _, p in ipairs(win.pills) do
		local active = win.filter == p.key
		local label = p.key == "all" and ("All " .. counts.all) or (MarkIcon(p.key) .. " " .. (counts[p.key] or 0))
		p.text:SetText(label)
		p.text:SetTextColor(active and 1 or 0.7, active and 0.82 or 0.65, active and 0 or 0.5)
		local c = active and BRONZE or { 0.23, 0.18, 0.11 }
		p:SetBackdropBorderColor(c[1], c[2], c[3], 1)
	end
	if counts.all == 0 then
		win.empty:SetText(win.emptyText[1]); win.empty2:SetText(win.emptyText[2])
	else
		win.empty:SetText("No marks match your search or filter."); win.empty2:SetText("")
	end

	-- The player being edited in the dialog, to highlight their row.
	local curKey = dlg and dlg:IsShown() and dlg.editKey or nil

	for i, item in ipairs(list) do
		local e = item.entry
		local r = GetRow(i)
		r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
		r.key = item.key
		r.icon:SetTexture((MARK[e.mark] or MARK.neutral).tex)

		local nameHex = ClassHex(e.class) or MarkHex(e.mark)
		local text = "|cff" .. nameHex .. DisplayName(item.key, e) .. "|r"
		if e.note and e.note ~= "" then
			local preview = e.note
			if #preview > NOTE_PREVIEW then preview = preview:sub(1, NOTE_PREVIEW) .. "..." end
			text = text .. "  |cff909090" .. preview .. "|r"
		end
		r.text:SetText(text)
		r.time:SetText(Ago(e.lastSeen or e.time))
		r.selbg:SetShown(item.key == curKey)
		r:Show()
	end
	for i = #list + 1, #rows do rows[i]:Hide() end

	win.content:SetHeight(math.max(1, #list * ROW_H))
	if win.UpdateScrollLine then win.UpdateScrollLine() end
	UpdateClearButton(#list)
end

----------------------------------------------------------------------
-- Public window controls
----------------------------------------------------------------------
function Thumber_Toggle()
	-- Bound to Arrow Right by default, so it would fire while that key is being
	-- captured in the settings panel. See Thumber_CapturingKey.
	if Thumber_CapturingKey then return end
	local f = GetWindow()
	if f:IsShown() then
		f:Hide()
	else
		f:Show()
		RefreshList()
	end
end

function Thumber_Open()
	GetWindow():Show()
	RefreshList()
end

----------------------------------------------------------------------
-- Tooltip integration
----------------------------------------------------------------------
-- `resize` is only wanted on the legacy OnTooltipSetUnit path, where the line is
-- appended after the tooltip has already sized itself. The tooltip data API lays
-- the tooltip out again after every post-call, and calling Show() from inside one
-- can re-enter the processor, so we skip it there.
-- A cut that never lands inside a multi-byte character.
local function CutAt(text, n)
	if #text <= n then return text, "" end
	local cut = n
	while cut > 1 do
		local b = text:byte(cut + 1)
		if not (b and b >= 128 and b <= 191) then break end
		cut = cut - 1
	end
	return text:sub(1, cut), text:sub(cut + 1)
end
ns.CutAt = CutAt

-- The note as tooltip lines. It is wrapped here, word by word, instead of with
-- AddLine's wrap flag: a wrapped line added after the tooltip has sized itself is
-- not given the extra height on the modern tooltip path, so a long note was cut
-- off. Separate plain lines size correctly everywhere.
local NOTE_LINE = 38
local function AddNoteLines(tip, note)
	if not (ns.Opt and ns.Opt("tooltipFullNote")) then
		local head, rest = CutAt(note, NOTE_PREVIEW)
		tip:AddLine("\"" .. head .. (rest ~= "" and "..." or "") .. "\"", 0.85, 0.85, 0.85)
		return
	end
	local lines, line = {}, ""
	for word in note:gmatch("%S+") do
		while #word > NOTE_LINE do -- a word longer than a line is split
			if line ~= "" then lines[#lines + 1] = line; line = "" end
			local head, rest = CutAt(word, NOTE_LINE)
			lines[#lines + 1] = head
			word = rest
		end
		if line == "" then
			line = word
		elseif #line + 1 + #word <= NOTE_LINE then
			line = line .. " " .. word
		else
			lines[#lines + 1] = line
			line = word
		end
	end
	if line ~= "" then lines[#lines + 1] = line end
	for i, text in ipairs(lines) do
		tip:AddLine((i == 1 and "\"" or "") .. text .. (i == #lines and "\"" or ""), 0.85, 0.85, 0.85)
	end
end

local function OnTooltipUnit(self, resize)
	if DB().showInTooltip == false then return end
	if self.IsForbidden and self:IsForbidden() then return end
	local _, unit = self:GetUnit()
	local key = KeyFromUnit(unit)
	local e = key and Marks()[key]
	if not e then return end
	local info = MARK[e.mark] or MARK.neutral
	self:AddLine(MarkIcon(e.mark) .. " Thumber: |cff" .. MarkHex(e.mark) .. info.label .. "|r")
	if e.note and e.note ~= "" and DB().showNoteInTooltip ~= false then
		AddNoteLines(self, e.note)
	end
	if resize then self:Show() end
end

-- WoW Forever / Midnight (12.x) build tooltips through TooltipDataProcessor, and
-- OnTooltipSetUnit never fires there. Keep the script hook for the older Classic
-- clients that predate the tooltip data API.
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and C_TooltipInfo then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
		if tooltip == GameTooltip or tooltip == GameTooltipTooltip then
			OnTooltipUnit(tooltip, false)
		end
	end)
else
	GameTooltip:HookScript("OnTooltipSetUnit", function(self) OnTooltipUnit(self, true) end)
end

----------------------------------------------------------------------
-- Keybind / quick-mark
----------------------------------------------------------------------
-- True while a key-capture row in the settings panel is waiting for a keypress.
-- SetPropagateKeyboardInput(false) is supposed to stop the pressed key reaching
-- its binding, but it evidently doesn't here, so the actions check this instead:
-- pressing Arrow Up to bind it should not also mark your target.
Thumber_CapturingKey = false

function Thumber_QuickMark(mark)
	if Thumber_CapturingKey then return end
	local chat = DB().chatLogging ~= false -- on unless the player turned it off
	local key, name, class = KeyFromUnit("target")
	if not key then key, name, class = KeyFromUnit("mouseover") end
	if not key then
		UIErrorsFrame:AddMessage("Thumber: no player targeted.", 1, 0.4, 0.4)
		return
	end
	local info = MARK[mark] or MARK.neutral
	local result = ToggleMark(key, name, mark, class)
	if ns.OnQuickMark then ns.OnQuickMark(key, result, mark) end
	if not chat then return end
	if result == "removed" then
		DEFAULT_CHAT_FRAME:AddMessage(MarkIcon(mark) .. " Thumber: " .. name ..
			" un-marked (was |cff" .. MarkHex(mark) .. info.label .. "|r).")
	else
		DEFAULT_CHAT_FRAME:AddMessage(MarkIcon(mark) .. " Thumber: " .. name ..
			" marked |cff" .. MarkHex(mark) .. info.label .. "|r.")
	end
end

----------------------------------------------------------------------
-- Minimap button (via LibDataBroker + LibDBIcon, so button collectors and
-- managers recognise it as a standard launcher instead of nagging).
----------------------------------------------------------------------
local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
local LDBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
local ldbObject

local function EnsureBroker()
	if ldbObject or not LDB then return ldbObject end
	ldbObject = LDB:NewDataObject("Thumber", {
		type = "launcher",
		text = "Thumber",
		icon = "Interface\\RaidFrame\\ReadyCheck-Ready",
		OnClick = function(_, button)
			if button == "RightButton" then
				if Thumber_OpenSettings then Thumber_OpenSettings() end
			else
				Thumber_Toggle()
			end
		end,
		OnTooltipShow = function(tt)
			tt:AddLine("Thumber")
			tt:AddLine("Left-click: open the marks list", 0.9, 0.9, 0.9)
			tt:AddLine("Right-click: settings", 0.9, 0.9, 0.9)
		end,
	})
	return ldbObject
end

function Thumber_UpdateMinimapButton()
	local db = DB()
	db.minimap = db.minimap or {}
	-- If the libraries somehow didn't load, do nothing (no hand-rolled button,
	-- so nothing for a collector to flag).
	if not (LDB and LDBIcon) then return end
	EnsureBroker()
	if not LDBIcon:IsRegistered("Thumber") then
		-- LibDBIcon reads/writes db.minimap.hide and db.minimap.minimapPos itself,
		-- which lines up with the "Show the minimap button" settings toggle.
		LDBIcon:Register("Thumber", ldbObject, db.minimap)
	end
	if db.minimap.hide then
		LDBIcon:Hide("Thumber")
	else
		LDBIcon:Show("Thumber")
	end
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
local ApplyDefaultBindings -- defined in the keybind section below
local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffThumber|r: " .. msg) end

SLASH_THUMBER1 = "/thumber"
SLASH_THUMBER2 = "/th"
SlashCmdList.THUMBER = function(msg)
	msg = msg or ""
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	if cmd == "" or cmd == "show" or cmd == "list" then
		Thumber_Toggle()
	elseif cmd == "note" then
		local key, name, class = KeyFromUnit("target")
		if not key then key, name, class = KeyFromUnit("mouseover") end
		if not key then Print("note who? target a player, then /thumber note <text>."); return end
		if class then SetMark(key, name, (Marks()[key] and Marks()[key].mark) or "neutral", class) end
		SetNote(key, rest)
		Print(name .. "'s note set.")
	elseif cmd == "config" or cmd == "options" then
		if Thumber_OpenSettings then Thumber_OpenSettings() end
	elseif cmd == "share" or cmd == "export" or cmd == "import" then
		if ns.OpenShare then ns.OpenShare() end
	elseif cmd == "profile" then
		if ns.OpenProfile then ns.OpenProfile() end
	elseif cmd == "send" then
		local ok, err = ns.SendMarks(rest)
		Print(ok and ("offering your marks to " .. rest .. ".") or err)
	elseif cmd == "test" then
		if ns.TestAlert then ns.TestAlert() end
	elseif cmd == "resetbinds" or cmd == "bindreset" then
		local ok, count = ApplyDefaultBindings(true)
		if not ok then
			Print("can't change keybinds in combat — try again after combat.")
		else
			Print(("arrow-key defaults applied (%d set). Up=thumbs up, Down=thumbs down, Left=neutral, Right=list.")
				:format(count or 0))
		end
	else
		Print("commands:")
		Print("  /thumbsup (/tu) | /thumbsdown (/td) | /neutral (/nt) [note] — mark your target")
		Print("  /thumber (/th) — open the marks list")
		Print("  /thumber note <text> — set a note on your target")
		Print("  /thumber config — settings & keybinds")
		Print("  /thumber resetbinds — re-apply the arrow-key defaults")
		Print("  /thumber test — preview the group-join alert")
		Print("  /thumber share — export, import, or send your marks")
		Print("  /thumber profile — export or import all your settings, positions and keybinds")
		Print("  /thumber send <player> — offer your marks to a player")
	end
end

-- Dedicated /thumbsup /thumbsdown /neutral commands (+ /tu /td aliases). These
-- always act on your target (or mouseover); the whole argument is the note.
-- "config"/"options" instead opens the settings panel.
local function MarkTargetWithNote(mark, msg)
	local arg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if arg:lower() == "config" or arg:lower() == "options" then
		if Thumber_OpenSettings then Thumber_OpenSettings() end
		return
	end
	-- Allow the note to be wrapped in quotes, e.g. /tu "ninja looter".
	arg = arg:match('^"(.*)"$') or arg:match("^'(.*)'$") or arg

	local key, name, class = KeyFromUnit("target")
	if not key then key, name, class = KeyFromUnit("mouseover") end
	if not key then
		Print("no player targeted — target someone, then /" ..
			(mark == "up" and "tu" or mark == "down" and "td" or "neutral") .. " [note].")
		return
	end
	local info = MARK[mark] or MARK.neutral
	-- With no note, pressing the mark a player already has toggles it off.
	if arg == "" then
		if ToggleMark(key, name, mark, class) == "removed" then
			Print(MarkIcon(mark) .. " " .. name .. " un-marked (was |cff" .. MarkHex(mark) .. info.label .. "|r).")
		else
			Print(MarkIcon(mark) .. " " .. name .. " marked |cff" .. MarkHex(mark) .. info.label .. "|r.")
		end
		return
	end
	-- A supplied note always sets/updates (never removes).
	SetMark(key, name, mark, class)
	SetNote(key, arg)
	Print(MarkIcon(mark) .. " " .. name .. " marked |cff" .. MarkHex(mark) .. info.label .. "|r — \"" .. arg .. "\".")
end

SLASH_THUMBERUP1 = "/thumbsup"
SLASH_THUMBERUP2 = "/tu"
SlashCmdList.THUMBERUP = function(msg) MarkTargetWithNote("up", msg) end

SLASH_THUMBERDOWN1 = "/thumbsdown"
SLASH_THUMBERDOWN2 = "/td"
SlashCmdList.THUMBERDOWN = function(msg) MarkTargetWithNote("down", msg) end

SLASH_THUMBERNEUTRAL1 = "/neutral"
SLASH_THUMBERNEUTRAL2 = "/nt"
SlashCmdList.THUMBERNEUTRAL = function(msg) MarkTargetWithNote("neutral", msg) end

----------------------------------------------------------------------
-- Default keybinds
----------------------------------------------------------------------
-- Arrow keys are normally held by movement, so the Bindings.xml `default=`
-- attribute alone won't claim them on an existing character. We claim them once
-- (tracked by a saved flag) by KEY: if an arrow isn't already pointing at our
-- action, we rebind it — overriding movement, which is exactly the requested
-- behaviour. It's one-time, so it never fights bindings you set afterwards; use
-- /thumber resetbinds to force it again. Existing keys you bound to these actions are
-- left in place (an action can hold two keys), so the arrows are simply added.
local DEFAULT_BINDS = {
	{ "UP", "THUMBER_UP" },
	{ "DOWN", "THUMBER_DOWN" },
	{ "LEFT", "THUMBER_NEUTRAL" },
	{ "RIGHT", "THUMBER_TOGGLE" },
}
-- SaveBindings takes 1 (account) or 2 (character) and raises on anything else.
-- At PLAYER_LOGIN the binding set isn't resolved yet on every client -- Forever
-- answers nil there -- so this reports whether the save actually happened, and
-- callers retry on UPDATE_BINDINGS rather than losing the binding.
function Thumber_SaveBindings()
	local set = GetCurrentBindingSet and GetCurrentBindingSet()
	if type(set) ~= "number" or set < 1 or set > 2 then return false end
	return (pcall(SaveBindings, set))
end

ApplyDefaultBindings = function(force)
	local db = DB()
	if db.bindDefaultsV2 and not force then return true, 0 end
	if InCombatLockdown() then return false end -- SetBinding is unsafe in combat
	local count = 0
	for _, b in ipairs(DEFAULT_BINDS) do
		local key, action = b[1], b[2]
		if GetBindingAction(key) ~= action then -- arrow not on our action → claim it
			if SetBinding(key, action) then count = count + 1 end
		end
	end
	-- Persist before marking it done. A binding we set but couldn't save is gone
	-- after the next logout, and the saved flag would stop us ever re-applying it.
	if not Thumber_SaveBindings() then return false end
	db.bindDefaultsV2 = true
	return true, count
end

----------------------------------------------------------------------
-- Init
----------------------------------------------------------------------
local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function(self, event)
	DB() -- ensure table
	MigrateSurnameKeys()
	Thumber_UpdateMinimapButton()
	if ApplyDefaultBindings() then
		self:UnregisterEvent("PLAYER_REGEN_ENABLED")
		self:UnregisterEvent("UPDATE_BINDINGS")
	else
		-- Either we logged in mid-combat (SetBinding is unsafe there) or the
		-- binding set wasn't resolved yet. Both resolve themselves shortly, so
		-- wait for whichever announces it.
		self:RegisterEvent("PLAYER_REGEN_ENABLED")
		self:RegisterEvent("UPDATE_BINDINGS")
	end
end)
