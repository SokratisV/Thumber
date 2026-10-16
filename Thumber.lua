-- Thumber — mark other players thumbs up / neutral / thumbs down, with an
-- optional note. Marks surface in unit tooltips and in a sortable list window.
--
-- WoW Forever (Interface 16001, Midnight 12.x API) and TBC Classic / Anniversary
-- (Interface 20505). Self-contained apart from the embedded LibDBIcon stack.

local ADDON = ...

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

----------------------------------------------------------------------
-- Data API
----------------------------------------------------------------------
local RefreshList -- forward decl (defined with the window)
local function Refresh() if RefreshList then RefreshList() end end

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
local function SortedMarks()
	local list = {}
	for key, e in pairs(Marks()) do
		list[#list + 1] = { key = key, entry = e }
	end
	table.sort(list, function(a, b)
		local oa = (MARK[a.entry.mark] or MARK.neutral).order
		local ob = (MARK[b.entry.mark] or MARK.neutral).order
		if oa ~= ob then return oa < ob end
		return DisplayName(a.key, a.entry):lower() < DisplayName(b.key, b.entry):lower()
	end)
	return list
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local ROW_H, MAX_VIEW = 20, 220
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

-- One thumbs button in the compose row. Clicking it applies that mark to the
-- player currently in the name box.
local function MakeMarkButton(parent, mark, x, applyFn)
	local info = MARK[mark]
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(28, 28)
	b:SetPoint("TOPLEFT", x, -70)
	b:SetNormalTexture(info.tex)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

	-- Selection glow shown when this is the active mark for the edited player.
	local sel = b:CreateTexture(nil, "OVERLAY")
	sel:SetPoint("CENTER")
	sel:SetSize(36, 36)
	sel:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	sel:SetBlendMode("ADD")
	sel:Hide()
	b.sel = sel
	b.mark = mark

	b:SetScript("OnClick", function() applyFn(mark) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(info.label)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return b
end

local function GetWindow()
	if win then return win end

	local f = CreateFrame("Frame", "ThumberFrame", UIParent, "BackdropTemplate")
	f:SetSize(380, 384)
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
	tinsert(UISpecialFrames, "ThumberFrame") -- closes on Escape
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
		if SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end
	end)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -12)
	title:SetText("Thumber")

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	HeaderIcon(f, "Interface\\Buttons\\UI-OptionsButton", "Settings",
		function() if Thumber_OpenSettings then Thumber_OpenSettings() end end, -38)

	-- Bronze rule under the header, as in FlareUI's windows.
	local headerLine = f:CreateTexture(nil, "ARTWORK")
	headerLine:SetColorTexture(BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
	headerLine:SetHeight(1)
	headerLine:SetPoint("TOPLEFT", 6, -34)
	headerLine:SetPoint("TOPRIGHT", -6, -34)

	----------------------------------------------------------------
	-- Compose / edit area
	----------------------------------------------------------------
	f.classHint = {}

	local nameBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	nameBox:SetPoint("TOPLEFT", 16, -44)
	nameBox:SetSize(196, 20)
	nameBox:SetAutoFocus(false)
	nameBox:SetFontObject(ChatFontNormal)
	f.nameBox = nameBox

	local targetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	targetBtn:SetSize(80, 22)
	targetBtn:SetPoint("LEFT", nameBox, "RIGHT", 12, 0)
	targetBtn:SetText("Target")
	targetBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Fill from your target (or mouseover).", nil, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	targetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Current mark of whoever is in the name box. The name is trimmed and its
	-- first letter capitalised so a typed "bob" matches the "Bob" that the Target
	-- button and slash commands produce (WoW always capitalises player names).
	local function CurrentEntry()
		local key = NormalizeKey(nameBox:GetText())
		if key == "" then return nil end
		return key, Marks()[key]
	end

	-- Highlight which mark button is active for the edited player.
	local function RefreshSelection()
		local _, e = CurrentEntry()
		local active = e and e.mark
		for _, b in ipairs(f.markButtons) do
			b.sel:SetShown(b.mark == active)
		end
	end
	f.RefreshSelection = RefreshSelection

	-- Load an existing entry into the compose area.
	local function LoadEntry(key)
		nameBox:SetText(key or "")
		nameBox:SetCursorPosition(0)
		local e = key and Marks()[key]
		f.noteBox:SetText((e and e.note) or "")
		f.noteBox:SetCursorPosition(0)
		RefreshSelection()
	end
	f.LoadEntry = LoadEntry

	-- The Target button and the keybinds all go through KeyFromUnit, which refuses
	-- anything that isn't a player. A name typed into the box has no unit behind it
	-- to check -- unless it happens to name something we can see right now, which is
	-- how an NPC gets in: target a wolf, type its name, mark it. So check the units
	-- we *can* resolve and refuse a known non-player.
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

	local function ApplyMark(mark)
		local key = CurrentEntry()
		if not key then
			UIErrorsFrame:AddMessage("Thumber: type a name or click Target first.", 1, 0.4, 0.4)
			return
		end
		if IsKnownNonPlayer(key) then
			UIErrorsFrame:AddMessage("Thumber: " .. key .. " isn't a player.", 1, 0.4, 0.4)
			return
		end
		local name = DisplayName(key)
		SetMark(key, name, mark, f.classHint[key])
		-- A note already typed but not yet committed should stick to the mark.
		local note = f.noteBox:GetText()
		if note and note ~= "" then SetNote(key, note) end
		RefreshSelection()
	end

	targetBtn:SetScript("OnClick", function()
		local key, name, class = KeyFromUnit("target")
		if not key then key, name, class = KeyFromUnit("mouseover") end
		if not key then
			UIErrorsFrame:AddMessage("Thumber: no player targeted.", 1, 0.4, 0.4)
			return
		end
		f.classHint[key] = class
		LoadEntry(key)
	end)

	-- Mark buttons + a "Mark:" label.
	local markLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	markLabel:SetPoint("TOPLEFT", 16, -78)
	markLabel:SetText("Mark:")
	f.markButtons = {
		MakeMarkButton(f, "up", 56, ApplyMark),
		MakeMarkButton(f, "neutral", 92, ApplyMark),
		MakeMarkButton(f, "down", 128, ApplyMark),
	}

	local delBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	delBtn:SetSize(80, 22)
	delBtn:SetPoint("TOPRIGHT", -16, -72)
	delBtn:SetText("Remove")
	delBtn:SetScript("OnClick", function()
		local key = CurrentEntry()
		if key and Marks()[key] then
			RemoveMark(key)
			LoadEntry(nil)
		end
	end)

	-- Note box (saves on Enter or focus loss).
	local noteLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	noteLabel:SetPoint("TOPLEFT", 16, -110)
	noteLabel:SetText("Note:")
	local noteBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	noteBox:SetPoint("LEFT", noteLabel, "RIGHT", 10, 0)
	noteBox:SetPoint("RIGHT", f, "RIGHT", -16, 0)
	noteBox:SetHeight(20)
	noteBox:SetAutoFocus(false)
	noteBox:SetFontObject(ChatFontNormal)
	noteBox:SetMaxLetters(255)
	f.noteBox = noteBox
	local function CommitNote()
		local key = CurrentEntry()
		if key then SetNote(key, noteBox:GetText()) end
		noteBox:ClearFocus()
	end
	noteBox:SetScript("OnEnterPressed", CommitNote)
	noteBox:SetScript("OnEditFocusLost", CommitNote)
	noteBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	-- Refresh the selection glow as the typed name changes.
	nameBox:SetScript("OnTextChanged", function() RefreshSelection() end)
	nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

	-- Divider.
	local div = f:CreateTexture(nil, "ARTWORK")
	div:SetColorTexture(BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
	div:SetPoint("TOPLEFT", 6, -136)
	div:SetPoint("TOPRIGHT", -6, -136)
	div:SetHeight(1)

	----------------------------------------------------------------
	-- Scrollable list
	----------------------------------------------------------------
	local scroll = CreateFrame("ScrollFrame", "ThumberScroll", f)
	scroll:SetPoint("TOPLEFT", 12, -144)
	scroll:SetPoint("TOPRIGHT", -26, -144)
	scroll:SetHeight(MAX_VIEW)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(342, 1)
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
	empty:SetPoint("TOPLEFT", 18, -150)
	empty:SetText("No marked players yet. Target someone and press the Target button,")
	local empty2 = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	empty2:SetPoint("TOPLEFT", 18, -164)
	empty2:SetText("or use /thumbsup | /thumbsdown | /neutral, or the arrow keys.")
	f.empty, f.empty2 = empty, empty2

	-- CreateFrame frames are shown by default; start hidden so the first toggle
	-- opens the window instead of hiding the freshly-created (already-shown) one.
	f:Hide()
	win, rows = f, {}
	return f
end

local function GetRow(i)
	if rows[i] then return rows[i] end
	local r = CreateFrame("Button", nil, win.content)
	r:SetSize(342, ROW_H)

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

	r.text = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
	r.text:SetPoint("RIGHT", r.del, "LEFT", -6, 0)
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
		if self.key then win.LoadEntry(self.key) end
	end)
	r:SetScript("OnEnter", function(self)
		local e = self.key and Marks()[self.key]
		if not e then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(DisplayName(self.key, e), 1, 1, 1)
		local info = MARK[e.mark] or MARK.neutral
		GameTooltip:AddLine(MarkIcon(e.mark) .. " |cff" .. MarkHex(e.mark) .. info.label .. "|r")
		if e.note then GameTooltip:AddLine("\"" .. e.note .. "\"", 0.85, 0.85, 0.85, true) end
		GameTooltip:Show()
	end)
	r:SetScript("OnLeave", function() GameTooltip:Hide() end)

	rows[i] = r
	return r
end

-- (Re)render the list of all marked players.
function RefreshList()
	if not win or not win:IsShown() then return end
	local list = SortedMarks()
	win.empty:SetShown(#list == 0)
	win.empty2:SetShown(#list == 0)

	-- Normalised key currently in the compose box, to highlight its row.
	local curKey = NormalizeKey(win.nameBox:GetText())

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
		r.selbg:SetShown(item.key == curKey)
		r:Show()
	end
	for i = #list + 1, #rows do rows[i]:Hide() end

	win.content:SetHeight(math.max(1, #list * ROW_H))
	if win.UpdateScrollLine then win.UpdateScrollLine() end
	if win.RefreshSelection then win.RefreshSelection() end
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
		self:AddLine("\"" .. e.note .. "\"", 0.85, 0.85, 0.85, true)
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
