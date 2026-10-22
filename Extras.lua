-- Thumber extras: mark badges (nameplates, target frame, chat), the group-join
-- alert, and last-seen tracking. Everything here reads Thumber's data through the
-- shared addon table (set up at the top of Thumber.lua) and is switched on and off
-- from the Appearance section of /thumber config.

local ADDON, ns = ...

local MARK, DB, Marks = ns.MARK, ns.DB, ns.Marks
local IsSecret, UnitKey = ns.IsSecret, ns.UnitKey
local DisplayName, ClassHex, MarkIcon = ns.DisplayName, ns.ClassHex, ns.MarkIcon

----------------------------------------------------------------------
-- Options
----------------------------------------------------------------------
local DEFAULTS = {
	badgeNameplate = true,   -- badge above the nameplate of a marked player
	badgeStyle     = "ring", -- "icon" | "ring" | "glow"
	badgeSize      = 22,
	badgeTarget    = true,   -- badge on the target frame portrait
	badgeChat      = true,   -- icon in front of a marked player's chat lines
	groupAlert     = true,   -- toast when a marked player is in your group
	alertSound     = "raid", -- "none" | "raid" | "ready"
	popAnim        = true,   -- pop the target badge when you mark someone
	badgeAnchor    = "ABOVE", -- ABOVE | BELOW | LEFT | RIGHT of the nameplate
	badgeOffsetX   = 0,      -- nudge the nameplate badge sideways...
	badgeOffsetY   = 0,      -- ...and up or down
	badgeCorner    = "TOPRIGHT", -- which corner of the target portrait the badge sits on
	chatLogging    = true,   -- chat line when a keybind marks or un-marks a player
	tooltipFullNote = true,  -- the whole note in the unit tooltip, not just its start
	shareReceive   = true,   -- let other players offer you their marks (you still get asked)
	shareScope     = "all",  -- what you share: "all" marks, or "down" (thumbs downs only)
	showInTooltip  = true,   -- your mark in a player's tooltip
	showNoteInTooltip = true, -- ...and your note under it
}
ns.DEFAULTS = DEFAULTS -- the complete list of options, which a profile is built from

function ns.Opt(name)
	local v = DB()[name]
	if v == nil then return DEFAULTS[name] end
	return v
end

local OnMarksChanged
function ns.SetOpt(name, value)
	DB()[name] = value
	OnMarksChanged()
	if ns.OnOptionChanged then ns.OnOptionChanged() end -- the settings preview redraws
end

----------------------------------------------------------------------
-- Unit helpers
----------------------------------------------------------------------
-- UnitIsPlayer can come back as a secret boolean; testing one throws, so ask
-- through pcall and treat anything unreadable as "not a player we can mark".
local function IsPlayerUnit(unit)
	local ok, r = pcall(UnitIsPlayer, unit)
	if not ok or IsSecret(r) then return false end
	return r == true
end

-- The mark entry (and its key) for a unit, if it is a marked player.
local function MarkFor(unit)
	if not unit or not UnitExists(unit) or not IsPlayerUnit(unit) then return end
	local key = UnitKey(unit)
	local e = key and Marks()[key]
	if e then return e, key end
end

-- Remember where and when a marked player was last seen. Throttled so a
-- nameplate flickering in and out doesn't rewrite the entry every frame.
local SIGHT_EVERY = 60
local function Sighted(e, unit)
	local now = time()
	if e.lastSeen and now - e.lastSeen < SIGHT_EVERY then return end
	e.lastSeen = now
	local zone = (GetRealZoneText and GetRealZoneText()) or GetZoneText()
	if type(zone) == "string" and zone ~= "" and not IsSecret(zone) then e.zone = zone end
	local level = UnitLevel(unit)
	if type(level) == "number" and not IsSecret(level) and level > 0 then e.level = level end
end

----------------------------------------------------------------------
-- Badge widget: the mark's icon, optionally in a coloured ring
----------------------------------------------------------------------
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local FLAT   = "Interface\\Buttons\\WHITE8X8"

local function Mask(badge, texture)
	-- Masks arrived with the modern engine; without them the ring is just square.
	if not badge.CreateMaskTexture then return end
	local m = badge:CreateMaskTexture()
	m:SetTexture(CIRCLE, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	m:SetAllPoints(texture)
	texture:AddMaskTexture(m)
end

local function NewBadge(parent)
	local b = CreateFrame("Frame", nil, parent or UIParent)
	b:EnableMouse(false)
	b:Hide()

	b.ring = b:CreateTexture(nil, "BORDER")
	b.ring:SetTexture(FLAT)
	b.ring:SetAllPoints(b)
	Mask(b, b.ring)

	b.disc = b:CreateTexture(nil, "ARTWORK")
	b.disc:SetTexture(FLAT)
	b.disc:SetVertexColor(0.08, 0.07, 0.05, 1)
	b.disc:SetPoint("CENTER")
	Mask(b, b.disc)

	b.icon = b:CreateTexture(nil, "OVERLAY")
	return b
end

local function StyleBadge(b, mark, size)
	local info = MARK[mark] or MARK.neutral
	local c = info.color
	local style = ns.Opt("badgeStyle")
	b:SetSize(size, size)
	b.icon:SetTexture(info.tex)
	b.icon:ClearAllPoints()
	b.icon:SetPoint("CENTER")
	-- "icon" is the bare mark; anything else (including the retired "glow") is the ring.
	if style == "icon" then
		b.ring:Hide(); b.disc:Hide()
		b.icon:SetSize(size, size)
		return
	end
	b.ring:SetVertexColor(c[1], c[2], c[3], 1)
	b.ring:Show()
	b.disc:SetSize(size - 4, size - 4)
	b.disc:Show()
	b.icon:SetSize(size - 8, size - 8)
end

local function HideBadge(b)
	b:Hide()
	b:ClearAllPoints()
end

-- Frame strata and level can be unreadable on a restricted plate; ask safely.
local function SafeGet(frame, method)
	local ok, v = pcall(frame[method], frame)
	if ok and not IsSecret(v) then return v end
end

-- Where a nameplate badge goes, by the chosen side: above the name when there is one
-- showing (else the health bar, else the plate), below the health bar, left of it, or
-- right of the level box (else of the bar); then the X / Y offsets on top. parts =
-- { plate, name, bar, level }, any of them may be missing. Unless `noLayer` (the
-- settings preview, which lives inside a window), it is also layered above Blizzard's
-- level box, which draws at HIGH strata and would otherwise cover a badge on a lower one.
local function PlacePlateBadge(b, parts, noLayer)
	local side = ns.Opt("badgeAnchor")
	local base = parts.bar or parts.plate -- the health bar, or the plate
	local frame, point, relPoint, x, y
	if side == "BELOW" then
		frame, point, relPoint, x, y = base, "TOP", "BOTTOM", 0, -4
	elseif side == "LEFT" then
		frame, point, relPoint, x, y = base, "RIGHT", "LEFT", -4, 0
	elseif side == "RIGHT" then
		-- clear of Blizzard's level box, which sits at the right end of the bar
		frame = (parts.level and SafeGet(parts.level, "IsShown")) and parts.level or base
		point, relPoint, x, y = "LEFT", "RIGHT", 4, 0
	else
		frame, point, relPoint, x, y = parts.plate, "BOTTOM", "TOP", 0, 4
		if parts.name and SafeGet(parts.name, "IsShown") then
			frame, y = parts.name, 2
		elseif parts.bar then
			frame = parts.bar
		end
	end
	b:ClearAllPoints()
	b:SetPoint(point, frame, relPoint, x + ns.Opt("badgeOffsetX"), y + ns.Opt("badgeOffsetY"))
	if noLayer then return end
	local strata, level = "HIGH", (SafeGet(parts.plate, "GetFrameLevel") or 0) + 50
	if parts.level then
		local s2, l2 = SafeGet(parts.level, "GetFrameStrata"), SafeGet(parts.level, "GetFrameLevel")
		if type(s2) == "string" then strata = s2 end
		if type(l2) == "number" then level = math.max(level, l2 + 5) end
	end
	b:SetFrameStrata(strata)
	b:SetFrameLevel(level)
end

-- A target badge sits just inside a corner of the portrait. Blizzard puts the
-- target's level in one of the lower corners, so the default is top right.
local CORNERS = {
	TOPRIGHT = { -4, -4 }, TOPLEFT = { 4, -4 }, BOTTOMRIGHT = { -4, 4 }, BOTTOMLEFT = { 4, 4 },
}
-- The layer a frame and everything inside it draws on: its strata, and the highest frame
-- level among its descendants on that strata. A badge placed just above that sits over
-- the unit frame's portrait ring and level number, yet on the frame's own strata, so
-- windows still draw over it. (HIGH covered everything; the frame's level + 20 sat
-- under the ring, whose frame is built far above its parent's level.)
local STRATA_RANK = {
	BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
	FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8,
}
local function TopLayer(roots)
	local strata, level = "MEDIUM", 0
	for _, root in ipairs(roots) do
		local s2 = SafeGet(root, "GetFrameStrata")
		if (STRATA_RANK[s2] or 0) > (STRATA_RANK[strata] or 0) then strata, level = s2, 0 end
	end
	local budget = 600 -- frames looked at, so a huge tree can't cost a hitch
	local function consider(f)
		if SafeGet(f, "GetFrameStrata") == strata then
			local l = SafeGet(f, "GetFrameLevel")
			if type(l) == "number" and l > level then level = l end
		end
	end
	local function walk(f, depth)
		if depth > 6 or budget <= 0 then return end
		local ok, kids = pcall(function() return { f:GetChildren() } end)
		if not ok then return end
		for _, kid in ipairs(kids) do
			budget = budget - 1
			if not (kid.IsForbidden and kid:IsForbidden()) then
				consider(kid)
				walk(kid, depth + 1)
			end
		end
	end
	for _, root in ipairs(roots) do
		consider(root)
		walk(root, 1)
	end
	return strata, level
end
ns._TopLayer = TopLayer

local function PlaceTargetBadge(b, anchor, frame)
	local corner = CORNERS[ns.Opt("badgeCorner")] and ns.Opt("badgeCorner") or "TOPRIGHT"
	local off = CORNERS[corner]
	b:ClearAllPoints()
	b:SetPoint("CENTER", anchor, corner, off[1], off[2])
	if frame then
		-- Just above whatever the unit frame draws, on its own strata.
		local roots = { frame }
		local holder = anchor.GetParent and anchor:GetParent()
		if holder and holder ~= frame then roots[2] = holder end
		local strata, level = TopLayer(roots)
		b:SetFrameStrata(strata)
		b:SetFrameLevel(level + 2)
	end
end

ns.NewBadge, ns.StyleBadge, ns.HideBadge = NewBadge, StyleBadge, HideBadge
ns.PlacePlateBadge, ns.PlaceTargetBadge = PlacePlateBadge, PlaceTargetBadge

----------------------------------------------------------------------
-- Nameplate badges
----------------------------------------------------------------------
local plateBadges, badgePool = {}, {}  -- plate frame -> badge, and spare badges
-- The unit tokens that have a nameplate right now, kept from the add / remove events.
-- Re-scanning by reading Blizzard's own plate fields is not reliable on every client
-- (a mark changing then left the badge showing the old state), so we keep our own list.
local plateUnits = {}
ns._plateBadges = plateBadges

local function ReleasePlateBadge(plate)
	local b = plateBadges[plate]
	if not b then return end
	plateBadges[plate] = nil
	HideBadge(b)
	b.unit = nil
	badgePool[#badgePool + 1] = b
end

local function UpdatePlate(unit)
	if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
	local plate = C_NamePlate.GetNamePlateForUnit(unit)
	-- Forbidden plates (restricted content) can't be anchored to or inspected.
	if not plate or (plate.IsForbidden and plate:IsForbidden()) then return end
	local e = ns.Opt("badgeNameplate") and MarkFor(unit)
	if not e then ReleasePlateBadge(plate) return end
	Sighted(e, unit)
	local b = plateBadges[plate]
	if not b then
		b = table.remove(badgePool) or NewBadge()
		plateBadges[plate] = b
	end
	b.unit = unit
	local uf = plate.UnitFrame
	if uf and uf.IsForbidden and uf:IsForbidden() then uf = nil end
	local bar = uf and uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar
	if bar and bar.IsForbidden and bar:IsForbidden() then bar = nil end
	local level = uf and uf.PlayerLevelDiffFrame
	if level and level.IsForbidden and level:IsForbidden() then level = nil end
	PlacePlateBadge(b, { plate = plate, name = uf and uf.name, bar = bar, level = level })
	StyleBadge(b, e.mark, ns.Opt("badgeSize"))
	b:Show()
end

local function RefreshPlates()
	for unit in pairs(plateUnits) do UpdatePlate(unit) end
	-- A badge whose unit no longer has a plate.
	for plate, b in pairs(plateBadges) do
		if not (b.unit and plateUnits[b.unit]) or not plate:IsShown() then ReleasePlateBadge(plate) end
	end
end

-- Plates that were already up when the addon loaded (a /reload): ask the game, and
-- accept a token from whichever field it keeps it in.
local function SeedPlates()
	if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
	for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
		local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
		if type(unit) == "string" and not IsSecret(unit) then plateUnits[unit] = true end
	end
end

----------------------------------------------------------------------
-- Target frame badge, and the pop when you mark someone
----------------------------------------------------------------------
local targetBadge

local function TargetAnchor()
	local tf = _G.TargetFrame
	local portrait = (tf and tf.TargetFrameContainer and tf.TargetFrameContainer.Portrait)
		or _G.TargetFramePortrait
	return portrait or tf, tf
end

local function UpdateTarget()
	local e = ns.Opt("badgeTarget") and MarkFor("target")
	if not e then
		if targetBadge then HideBadge(targetBadge) end
		return
	end
	Sighted(e, "target")
	local anchor, tf = TargetAnchor()
	-- Another unit-frame addon may have hidden Blizzard's frame; a badge pinned to
	-- it would float in the wrong place, so only show where the portrait is.
	if not anchor or not anchor:IsVisible() then
		if targetBadge then HideBadge(targetBadge) end
		return
	end
	targetBadge = targetBadge or NewBadge()
	PlaceTargetBadge(targetBadge, anchor, tf)
	StyleBadge(targetBadge, e.mark, math.max(14, ns.Opt("badgeSize") - 4))
	targetBadge:Show()
end

-- Grow-and-settle on the target badge. Driven by hand with OnUpdate: scale
-- animations aren't available on every client this addon runs on.
local POP_TIME = 0.35
local function PopBadge(b)
	local t = 0
	b:SetScript("OnUpdate", function(self, dt)
		t = t + dt
		if t >= POP_TIME then
			self:SetScale(1)
			self:SetScript("OnUpdate", nil)
			return
		end
		self:SetScale(1 + 0.9 * math.sin(math.pi * t / POP_TIME))
	end)
end
ns.PopBadge = PopBadge

function ns.Pop()
	if not ns.Opt("popAnim") or not targetBadge or not targetBadge:IsShown() then return end
	PopBadge(targetBadge)
end

-- Called by Thumber_QuickMark after a keybind changed a mark.
function ns.OnQuickMark(_, result)
	if result ~= "removed" then ns.Pop() end
end

----------------------------------------------------------------------
-- Chat badges
----------------------------------------------------------------------
-- The icon goes at the front of the message: a chat filter can edit the text but
-- not what is drawn before the sender's name.
local CHAT_EVENTS = {
	"CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
	"CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
	"CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_WHISPER",
	"CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_CHANNEL",
}

local function ChatFilter(_, _, msg, author, ...)
	if not ns.Opt("badgeChat") then return false end
	if type(msg) ~= "string" or type(author) ~= "string" then return false end
	if IsSecret(msg) or IsSecret(author) then return false end
	local marks = Marks()
	local e = marks[author]
	if not e and Ambiguate then
		-- Senders arrive as "Name-Realm" or "First Surname"; marks are keyed the
		-- way the unit APIs spell them, so try the spellings in turn.
		e = marks[Ambiguate(author, "none")] or marks[Ambiguate(author, "short")]
	end
	if not e then return false end
	return false, MarkIcon(e.mark) .. " " .. msg, author, ...
end

if ChatFrame_AddMessageEventFilter then
	for _, event in ipairs(CHAT_EVENTS) do ChatFrame_AddMessageEventFilter(event, ChatFilter) end
end

----------------------------------------------------------------------
-- Group-join alert
----------------------------------------------------------------------
-- The alert's sounds, by SOUNDKIT name; one this client doesn't have is simply not offered.
local KITS = {
	{ "raid", "Raid Warning", "RAID_WARNING" },
	{ "alarm", "Alarm Clock", "ALARM_CLOCK_WARNING_3" },
	{ "pvpqueue", "PvP Queue", "PVP_THROUGH_QUEUE" },
}

-- What the Sound setting can be: None, then the sounds above.
function ns.SoundChoices()
	local out = { { value = "none", text = "None" } }
	for _, k in ipairs(KITS) do
		if SOUNDKIT and SOUNDKIT[k[3]] then out[#out + 1] = { value = k[1], text = k[2] } end
	end
	return out
end

-- A saved choice that is no longer on offer (an earlier version listed more sounds)
-- reads as Raid Warning, so an alert is never silent by accident.
function ns.NormalizeSound(value)
	if value == "none" then return "none" end
	for _, k in ipairs(KITS) do
		if k[1] == value then return value end
	end
	return "raid"
end

function ns.PlayAlertSound(value)
	value = ns.NormalizeSound(value or ns.Opt("alertSound"))
	if value == "none" then return end
	for _, k in ipairs(KITS) do
		if k[1] == value then
			local kit = SOUNDKIT and SOUNDKIT[k[3]]
			if kit then PlaySound(kit) end
			return
		end
	end
end

local BRONZE = { 0.80, 0.60, 0.34 }

-- A plain alpha fade driven from OnUpdate. Blizzard's UIFrameFadeIn / Out would do
-- the same, but they register the frame in a Blizzard-owned table, which is a
-- needless way to taint the UI for something this small.
local function Fade(f, from, to, duration)
	local t = 0
	f:SetAlpha(from)
	f:SetScript("OnUpdate", function(self, dt)
		t = t + dt
		local p = math.min(1, t / duration)
		self:SetAlpha(from + (to - from) * p)
		if p >= 1 then self:SetScript("OnUpdate", nil) end
	end)
end

local toast
local queue, showing = {}, false
local ShowNext

-- Where the alert sits: wherever it was dragged to (saved as point, relative point, x, y),
-- else just under the top right of the screen.
local function ApplyToastPos(f)
	local p = DB().alertPos
	f:ClearAllPoints()
	if type(p) == "table" and p[1] and p[3] then
		f:SetPoint(p[1], UIParent, p[2] or p[1], p[3], p[4] or 0)
	else
		f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -24, -220)
	end
end

local function FillToast(f, info, nameText, note)
	f.icon:SetTexture(info.tex)
	f:SetBackdropBorderColor(info.color[1], info.color[2], info.color[3], 1)
	f.name:SetText(nameText)
	f.note:SetText(note or "")
end

local function BuildToast()
	local f = CreateFrame("Button", "ThumberAlert", UIParent, "BackdropTemplate")
	f:SetSize(330, 64)
	ApplyToastPos(f)
	f:SetFrameStrata("FULLSCREEN_DIALOG")
	f:SetClampedToScreen(true)
	f:SetBackdrop({
		bgFile = FLAT, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	f:SetBackdropColor(0.08, 0.067, 0.043, 0.95)
	f:Hide()

	f.icon = f:CreateTexture(nil, "ARTWORK")
	f.icon:SetSize(36, 36)
	f.icon:SetPoint("LEFT", 14, 0)
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, 2)
	f.title:SetText("Marked player in your group")
	f.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.name:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
	f.note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.note:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -2)
	f.note:SetPoint("RIGHT", f, "RIGHT", -12, 0)
	f.note:SetJustifyH("LEFT")
	f.note:SetWordWrap(false)

	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) if ns.alertUnlocked then self:StartMoving() end end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		if point then DB().alertPos = { point, relPoint, x, y } end
	end)
	-- A click of either mouse button dismisses it (not while it is unlocked for moving).
	f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	f:SetScript("OnClick", function() if not ns.alertUnlocked then ns.DismissAlert() end end)
	return f
end

function ns.DismissAlert()
	local f = toast
	if not f or not f:IsShown() or f.dismissing then return end
	f.dismissing = true
	f.token = (f.token or 0) + 1
	Fade(f, f:GetAlpha(), 0, 0.4)
	C_Timer.After(0.45, function()
		f:Hide()
		showing = false
		ShowNext()
	end)
end

ShowNext = function()
	if showing or #queue == 0 then return end
	showing = true
	local item = table.remove(queue, 1)
	toast = toast or BuildToast()
	local f = toast
	ns.alertUnlocked = false -- a real alert takes the frame back from the move placeholder
	local info = MARK[item.entry.mark] or MARK.neutral
	f.dismissing = false
	f.token = (f.token or 0) + 1
	local token = f.token
	local nameHex = ClassHex(item.entry.class) or info.hex
	local note = item.entry.note
	FillToast(f, info, "|cff" .. nameHex .. item.name .. "|r  |cff9a8b6e" .. info.label .. "|r",
		(note and note ~= "") and ("\"" .. note .. "\"") or "")
	f:Show()
	Fade(f, 0, 1, 0.25)
	ns.PlayAlertSound()
	C_Timer.After(7, function() if f.token == token then ns.DismissAlert() end end)
end

local function Alert(key, entry, unit)
	local class = entry.class
	if not class and unit then class = select(2, UnitClass(unit)) end
	local copy = setmetatable({ class = class }, { __index = entry })
	queue[#queue + 1] = { name = DisplayName(key, entry), entry = copy }
	ShowNext()
end

-- /thumber test
function ns.TestAlert()
	Alert("Test Player", { mark = "down", note = "ninja looted last run", class = "DRUID" })
end

-- Moving the alert: unlocked, the toast sits on screen as a placeholder you can drag;
-- locked, it only appears for real alerts. The position is remembered.
ns.alertUnlocked = false
function ns.SetAlertLocked(locked)
	ns.alertUnlocked = not locked
	toast = toast or BuildToast()
	local f = toast
	-- Whatever real alert was on screen is dropped either way: its timer is cancelled
	-- here, so it must not stay marked as showing and block the ones behind it.
	f.token = (f.token or 0) + 1
	f.dismissing = false
	f:SetScript("OnUpdate", nil)
	showing = false
	if ns.alertUnlocked then
		local info = MARK.down
		FillToast(f, info, "|cffff7d0aTest Player|r  |cff9a8b6e" .. info.label .. "|r", "Drag me where alerts should appear")
		f:SetAlpha(1)
		f:Show()
	else
		f:Hide()
		ShowNext() -- anything that queued up meanwhile
	end
	if ns.OnOptionChanged then ns.OnOptionChanged() end
end

function ns.ResetAlertPosition()
	DB().alertPos = nil
	if toast then ApplyToastPos(toast) end
end

-- Put the alert where the saved position says (after a profile import).
function ns.ApplyAlertPosition()
	if toast then ApplyToastPos(toast) end
end

local announced = {}  -- keys already alerted for this group

local function GroupUnits()
	local units = {}
	if IsInRaid and IsInRaid() then
		for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
	elseif IsInGroup and IsInGroup() then
		for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
	end
	return units
end

-- The alert is for a marked player ARRIVING, so it fires once per arrival, however many
-- times the roster changes after it. `announced` remembers who has had theirs.
--
-- Blizzard sends GROUP_ROSTER_UPDATE for every join and leave, and while the roster is
-- changing its party1..4 slots shift and a name can be unreadable for a moment. If a
-- marked player merely looked absent in such a scan and was forgotten, they would be
-- announced again on the next one. So someone is forgotten only after a scan in which
-- the whole roster could be read and they were not in it.
local function ScanGroup()
	if not (IsInGroup and IsInGroup()) then wipe(announced) return end
	local present, complete = {}, true
	for _, unit in ipairs(GroupUnits()) do
		if not UnitExists(unit) then
			complete = false                      -- a slot the game says is full, still empty
		elseif not UnitIsUnit(unit, "player") then
			local key = UnitKey(unit)
			if not key then
				complete = false                  -- a name that cannot be read yet
			else
				present[key] = true
				local e = Marks()[key]
				if e then
					Sighted(e, unit)
					if not announced[key] and ns.Opt("groupAlert") then
						announced[key] = true
						Alert(key, e, unit)
					end
				end
			end
		end
	end
	if not complete then return end
	-- Someone who really left and comes back later should be announced again.
	for key in pairs(announced) do
		if not present[key] then announced[key] = nil end
	end
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
OnMarksChanged = function()
	RefreshPlates()
	UpdateTarget()
	if ns.RefreshShareScope then ns.RefreshShareScope() end -- the share window's counts
end
ns.OnMarksChanged = OnMarksChanged

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("NAME_PLATE_UNIT_ADDED")
ev:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
ev:SetScript("OnEvent", function(_, event, unit)
	if event == "NAME_PLATE_UNIT_ADDED" then
		if type(unit) ~= "string" or IsSecret(unit) then return end
		plateUnits[unit] = true
		UpdatePlate(unit)
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		if type(unit) ~= "string" or IsSecret(unit) then return end
		plateUnits[unit] = nil
		for plate, b in pairs(plateBadges) do
			if b.unit == unit then ReleasePlateBadge(plate) end
		end
	elseif event == "PLAYER_TARGET_CHANGED" then
		UpdateTarget()
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		local e = MarkFor("mouseover")
		if e then Sighted(e, "mouseover") end
	elseif event == "GROUP_ROSTER_UPDATE" then
		ScanGroup()
	elseif event == "PLAYER_ENTERING_WORLD" then
		SeedPlates()
		OnMarksChanged()
		ScanGroup()
	end
end)
