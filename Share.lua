-- Thumber sharing: hand your marks to someone else.
--
-- Two ways, one import path:
--   * Send to a player: a whisper transfer over addon messages. The other player is
--     asked first (Accept / Decline) and the marks are sent in small throttled chunks.
--   * Export / import: one pasteable string ("THUMBER:...") for Discord or anywhere
--     else, with a preview of what an import would change.
-- Everything that comes in is treated as untrusted: marks are validated, text is
-- stripped of escape codes, sizes are capped, and an import only ever adds new marks
-- unless you explicitly choose to overwrite.

local ADDON, ns = ...
local L = ns.L

local MARK, Marks = ns.MARK, ns.Marks
local IsSecret, DisplayName = ns.IsSecret, ns.DisplayName

local PREFIX        = "THUMBER"
local VERSION       = 1
local CHUNK         = 200    -- characters of payload per addon message (limit is 255)
local STEP          = 0.3    -- seconds between chunks, well under the server's rate limit
local MAX_MARKS     = 5000
local MAX_CHUNKS    = 1500
local OFFER_WAIT    = 60     -- how long a sender waits for Accept
local RETRY_RESULTS = { [3] = true, [8] = true, [11] = true } -- throttled / locked down

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffThumber|r: " .. msg) end

----------------------------------------------------------------------
-- Encoding: base64 (so the string survives chat boxes, Discord, and the edit
-- box's treatment of the | character) over a small tab-separated text format.
----------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
	local c = B64:sub(i, i)
	ENC[i - 1], DEC[c] = c, i - 1
end

local function B64Encode(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local v = a * 65536 + (b or 0) * 256 + (c or 0)
		out[#out + 1] = ENC[math.floor(v / 262144)] .. ENC[math.floor(v / 4096) % 64]
			.. (b and ENC[math.floor(v / 64) % 64] or "=") .. (c and ENC[v % 64] or "=")
	end
	return table.concat(out)
end

-- Returns the decoded string, or nil if the text isn't valid base64.
local function B64Decode(text)
	text = text:gsub("=+$", "")
	if text:find("[^A-Za-z0-9+/]") or #text % 4 == 1 then return nil end
	local out = {}
	for i = 1, #text, 4 do
		local s = text:sub(i, i + 3)
		local d1, d2, d3, d4 = DEC[s:sub(1, 1)], DEC[s:sub(2, 2)], DEC[s:sub(3, 3)], DEC[s:sub(4, 4)]
		local v = d1 * 262144 + d2 * 4096 + (d3 or 0) * 64 + (d4 or 0)
		out[#out + 1] = string.char(math.floor(v / 65536))
		if d3 then out[#out + 1] = string.char(math.floor(v / 256) % 256) end
		if d4 then out[#out + 1] = string.char(v % 256) end
	end
	return table.concat(out)
end

local ESC = { ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "" }
local function Esc(s) return (tostring(s or ""):gsub("[\\\t\n\r]", ESC)) end
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

-- Text from outside: no escape codes (colours, textures, links), no control
-- characters, trimmed, and cut to length without splitting a character.
local function Clean(s, max)
	s = s:gsub("|", ""):gsub("%c", " ")
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return (ns.CutAt(s, max))
end

-- What can be shared: every mark, or only the thumbs downs (to warn someone about the
-- people you would rather they avoided, without handing over your whole list).
local SCOPES = {
	all  = {
		label = L["All marks"],
		none = L["You have no marks to share."],
		noneExport = L["You have no marks to export."],
		exported = L["%d marks exported. Press Ctrl+C to copy, then paste it wherever you like."],
		waiting = L["Waiting for %s to accept %d marks..."],
	},
	down = {
		label = L["Thumbs down only"],
		none = L["You have no thumbs down marks to share."],
		noneExport = L["You have no thumbs down marks to export."],
		exported = L["%d thumbs down marks exported. Press Ctrl+C to copy, then paste it wherever you like."],
		waiting = L["Waiting for %s to accept %d thumbs down marks..."],
	},
}
local function ScopeOf(scope)
	return SCOPES[scope] and scope or "all"
end

-- The marks in a scope as one text block, and how many there were.
local function Serialize(scope)
	scope = ScopeOf(scope)
	local lines = { "THUMBER" .. VERSION, "u=" .. (ns.UniqueNames() and "1" or "0") }
	local n = 0
	for key, e in pairs(Marks()) do
		if scope == "all" or e.mark == scope then
		n = n + 1
		lines[#lines + 1] = table.concat({
			Esc(key), e.mark or "neutral", e.class or "",
			tostring(math.floor(tonumber(e.time) or 0)), Esc(e.note),
		}, "\t")
		end
	end
	return table.concat(lines, "\n"), n
end

-- Text block back into a validated list of marks, or nil and a reason.
local function ParsePayload(raw)
	local lines = Split(raw, "\n")
	if lines[1] ~= "THUMBER" .. VERSION then return nil, L["This was made by a different version of Thumber."] end
	local unique = lines[2] == "u=1"
	if unique ~= ns.UniqueNames() then
		return nil, unique and L["These marks come from WoW Forever, where names have surnames, so they can't be used here."]
			or L["These marks come from the Anniversary client, so they can't be used on WoW Forever."]
	end
	local entries = {}
	for i = 3, #lines do
		if lines[i] ~= "" then
			local f = Split(lines[i], "\t")
			local key = Clean(Unesc(f[1] or ""), 64)
			local mark = f[2]
			if key ~= "" and MARK[mark] then
				if #entries >= MAX_MARKS then break end
				local class = (f[3] or ""):match("^%u+$")
				if class and #class > 12 then class = nil end
				local note = Clean(Unesc(f[5] or ""), 255)
				entries[#entries + 1] = {
					key = key, mark = mark, class = class,
					time = tonumber(f[4]) or 0, note = note ~= "" and note or nil,
				}
			end
		end
	end
	return entries
end

-- The pasteable form, and its reverse.
local function Export(scope)
	local payload, n = Serialize(scope)
	return "THUMBER:" .. B64Encode(payload), n
end

local function Parse(text)
	text = (text or ""):gsub("%s+", "")
	local body = text:match("^THUMBER:(.+)$")
	if not body then return nil, L["That doesn't look like a Thumber export."] end
	local raw = B64Decode(body)
	if not raw then return nil, L["The text is damaged. Copy the whole string again."] end
	return ParsePayload(raw)
end

-- How an import would land: new marks, marks that differ from yours, and ones you
-- already have exactly.
local function Compare(entries)
	local marks, new, differ, same = Marks(), 0, 0, 0
	for _, ent in ipairs(entries) do
		local cur = marks[ent.key]
		if not cur then
			new = new + 1
		elseif cur.mark ~= ent.mark or (cur.note or "") ~= (ent.note or "") then
			differ = differ + 1
		else
			same = same + 1
		end
	end
	return new, differ, same
end

-- Add the new marks; with `overwrite`, also replace the ones that differ.
local function Apply(entries, overwrite)
	local marks, added, updated = Marks(), 0, 0
	for _, ent in ipairs(entries) do
		local cur = marks[ent.key]
		if not cur then
			marks[ent.key] = {
				name = DisplayName(ent.key), mark = ent.mark, class = ent.class,
				note = ent.note, time = ent.time > 0 and ent.time or time(),
			}
			added = added + 1
		elseif overwrite and (cur.mark ~= ent.mark or (cur.note or "") ~= (ent.note or "")) then
			cur.mark, cur.note, cur.class = ent.mark, ent.note, ent.class or cur.class
			if ent.time > 0 then cur.time = ent.time end
			updated = updated + 1
		end
	end
	if ns.Refresh then ns.Refresh() end
	return added, updated
end

ns.Share = {
	B64Encode = B64Encode, B64Decode = B64Decode, Serialize = Serialize, Export = Export, ScopeOf = ScopeOf,
	Parse = Parse, Compare = Compare, Apply = Apply,
}

----------------------------------------------------------------------
-- Sending to a player
----------------------------------------------------------------------
local Status = function() end -- replaced once the dialog exists

local out      -- the transfer we are sending
local inc      -- the transfer we are receiving
local offer    -- an offer waiting for Accept / Decline
local lastOffer = {}

local function SendMsg(msg, target)
	local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
	if not send then return false end
	local ok, res = pcall(send, PREFIX, msg, "WHISPER", target)
	if not ok then return false end
	if res == nil or res == true or res == 0 then return true end
	return false, res
end

local function SameName(a, b)
	local function norm(n)
		n = Ambiguate and Ambiguate(n, "short") or n
		return n:lower()
	end
	return norm(a) == norm(b)
end

local function Pump(o)
	if out ~= o then return end
	local chunk = o.chunks[o.idx + 1]
	if not chunk then
		Status(L["Sent %d marks to %s."]:format(o.count, o.target))
		Print(L["sent %d marks to %s."]:format(o.count, o.target))
		out = nil
		return
	end
	local ok, res = SendMsg(("C:%s:%d:%s"):format(o.id, o.idx + 1, chunk), o.target)
	if ok then
		o.idx, o.tries = o.idx + 1, 0
		Status(L["Sending to %s... %d / %d"]:format(o.target, o.idx, #o.chunks))
	else
		o.tries = (o.tries or 0) + 1
		if not (res and RETRY_RESULTS[res]) or o.tries > 5 then
			Status(L["Sending stopped: the game wouldn't take the messages. Try again in a moment."])
			out = nil
			return
		end
	end
	C_Timer.After(ok and STEP or 1, function() Pump(o) end)
end

-- Offer our marks to `target`; the transfer starts when they accept.
function ns.SendMarks(target, scope)
	scope = ScopeOf(scope or ns.Opt("shareScope"))
	target = ns.NormalizeKey(target or "")
	if target == "" then return false, L["Type a player's name first."] end
	local payload, count = Serialize(scope)
	if count == 0 then return false, SCOPES[scope].none end
	local data = B64Encode(payload)
	local chunks = {}
	for i = 1, #data, CHUNK do chunks[#chunks + 1] = data:sub(i, i + CHUNK - 1) end
	if #chunks > MAX_CHUNKS then return false, L["That's too many marks to send. Use export instead."] end

	local id = ("%06x"):format(math.random(0, 0xFFFFFF))
	local ok = SendMsg(("O:%s:%d:%d:%d"):format(id, #chunks, count, ns.UniqueNames() and 1 or 0), target)
	if not ok then return false, L["Couldn't send anything to %s."]:format(target) end
	local o = { id = id, target = target, chunks = chunks, idx = 0, count = count }
	out = o
	Status(SCOPES[scope].waiting:format(target, count))
	C_Timer.After(OFFER_WAIT, function()
		if out == o and not o.sending then
			out = nil
			Status(L["No answer from %s. They may be offline, not have Thumber, or have said no."]:format(target))
		end
	end)
	return true
end

----------------------------------------------------------------------
-- Receiving
----------------------------------------------------------------------
local function Watch(i)
	C_Timer.After(10, function()
		if inc ~= i then return end
		if GetTime() - i.last > 40 then
			Print(L["the transfer from %s timed out."]:format(i.sender))
			inc = nil
		else
			Watch(i)
		end
	end)
end

local function Finish(i)
	inc = nil
	local parts = {}
	for n = 1, i.total do parts[n] = i.got[n] end
	local entries, err = Parse("THUMBER:" .. table.concat(parts))
	if not entries then
		Print(L["what %s sent couldn't be read: %s"]:format(i.sender, err or L["damaged data"]))
		return
	end
	local added = Apply(entries, false)
	Print(L["received %d marks from %s: %d new, %d you already had."]:format(#entries, i.sender, added, #entries - added))
end

local function Decline(o, reason)
	if offer == o then offer = nil end
	SendMsg(("D:%s:%s"):format(o.id, reason or "no"), o.sender)
end

local function Accept(o)
	if offer ~= o then return end
	offer = nil
	local i = { id = o.id, sender = o.sender, total = o.total, count = o.count, got = {}, n = 0, last = GetTime() }
	inc = i
	SendMsg("A:" .. o.id, o.sender)
	Print(L["receiving %d marks from %s..."]:format(o.count, o.sender))
	Watch(i)
end

-- The Accept / Decline prompt is Thumber's own frame, built below. It deliberately
-- does not use Blizzard's StaticPopup system: registering a dialog means writing to
-- Blizzard's StaticPopupDialogs global, and that taint is read by the game menu's
-- Escape handling, which then blocks the menu ("Thumber has been blocked...").
local ShowOffer

local function OnOffer(sender, rest)
	local id, total, count, unique = rest:match("^(%x+):(%d+):(%d+):(%d)$")
	if not id then return end
	total, count = tonumber(total), tonumber(count)
	local o = { id = id, sender = sender, total = total, count = count }
	local now = GetTime()
	if lastOffer[sender] and now - lastOffer[sender] < 15 then return end -- no popup spam
	lastOffer[sender] = now
	if not ns.Opt("shareReceive") then return Decline(o, "off") end
	if inc or offer then return Decline(o, "busy") end
	if (unique == "1") ~= ns.UniqueNames() then
		Print(L["%s tried to send marks from a different kind of client; ignored."]:format(sender))
		return Decline(o, "style")
	end
	if total < 1 or total > MAX_CHUNKS or count > MAX_MARKS then return Decline(o, "size") end
	offer = o
	ShowOffer(o)
end

local DECLINED = {
	busy = L["%s is busy with another transfer."], off = L["%s isn't accepting shared marks."],
	style = L["%s is on a different kind of client."], size = L["%s can't take that many marks."],
}

local function OnMessage(prefix, text, _, sender)
	if prefix ~= PREFIX or type(text) ~= "string" or type(sender) ~= "string" then return end
	if IsSecret(text) or IsSecret(sender) then return end
	local kind, rest = text:match("^(%a):(.*)$")
	if kind == "O" then
		OnOffer(sender, rest)
	elseif kind == "A" then
		if out and out.id == rest and not out.sending and SameName(sender, out.target) then
			out.sending = true
			Status(L["%s accepted. Sending..."]:format(out.target))
			Pump(out)
		end
	elseif kind == "D" then
		local id, reason = rest:match("^(%x+):(%a*)$")
		if out and out.id == id and SameName(sender, out.target) then
			Status((DECLINED[reason] or L["%s said no."]):format(out.target))
			out = nil
		end
	elseif kind == "C" then
		local id, n, data = rest:match("^(%x+):(%d+):(.*)$")
		n = tonumber(n)
		if inc and inc.id == id and SameName(sender, inc.sender) and n and n >= 1 and n <= inc.total
			and not inc.got[n] and #data <= CHUNK + 8 and not data:find("[^A-Za-z0-9+/=]") then
			inc.got[n], inc.n, inc.last = data, inc.n + 1, GetTime()
			if inc.n == inc.total then Finish(inc) end
		end
	end
end

----------------------------------------------------------------------
-- The share window
----------------------------------------------------------------------
local BRONZE       = { 0.80, 0.60, 0.34 }
local BRONZE_MUTED = { 0.61, 0.48, 0.29 }
local dlg

local function Rule(parent, y)
	local t = parent:CreateTexture(nil, "ARTWORK")
	t:SetColorTexture(BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
	t:SetHeight(1)
	t:SetPoint("TOPLEFT", 6, y)
	t:SetPoint("TOPRIGHT", -6, y)
end

-- A button as wide as its own text needs (never narrower than minWidth); the caller places
-- it. German and Russian labels run much longer than English ones.
local function Button(parent, text, minWidth, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetHeight(22)
	b:SetText(text)
	local fs = b:GetFontString()
	b:SetWidth(math.max(minWidth, math.ceil(fs and fs:GetStringWidth() or 60) + 28))
	b:SetScript("OnClick", onClick)
	return b
end

local function BuildDialog()
	local f = CreateFrame("Frame", "ThumberShareFrame", UIParent, "BackdropTemplate")
	f:SetSize(460, 410)
	f:SetPoint("CENTER", 0, 20)
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
	title:SetText(L["Share marks"])
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	Rule(f, -34)

	-- What to share, for both ways below: two choices side by side, the chosen one lit,
	-- each with how many marks it covers.
	f.scopePills = {}
	local function ScopePill(scope)
		local p = CreateFrame("Button", nil, f, "BackdropTemplate")
		p:SetHeight(22)
		p:SetBackdrop({ bgFile = "Interface\Buttons\WHITE8X8", edgeFile = "Interface\Buttons\WHITE8X8", edgeSize = 1 })
		p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		p.text:SetPoint("CENTER")
		p.scope = scope
		p:SetScript("OnClick", function()
			ns.SetOpt("shareScope", scope)
			f.UpdateScope()
		end)
		p:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
			GameTooltip:SetText(SCOPES[scope].label)
			GameTooltip:AddLine(scope == "all"
				and L["Share every mark you have. Applies to sending to a player and to exporting."]
				or L["Share only the players you marked thumbs down, so you can warn someone without handing over your whole list. Applies to sending to a player and to exporting."],
				0.85, 0.85, 0.85, true)
			GameTooltip:Show()
		end)
		p:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return p
	end
	local downPill, allPill = ScopePill("down"), ScopePill("all")
	downPill:SetPoint("TOPRIGHT", -40, -8)
	allPill:SetPoint("RIGHT", downPill, "LEFT", -4, 0)
	f.scopePills[1], f.scopePills[2] = allPill, downPill

	function f.UpdateScope()
		local scope = ScopeOf(ns.Opt("shareScope"))
		local counts = { all = 0, down = 0 }
		for _, e in pairs(Marks()) do
			counts.all = counts.all + 1
			if e.mark == "down" then counts.down = counts.down + 1 end
		end
		for _, p in ipairs(f.scopePills) do
			p.text:SetText(SCOPES[p.scope].label .. " (" .. counts[p.scope] .. ")")
			p:SetWidth(math.ceil(p.text:GetStringWidth() or 80) + 22)
			local on = p.scope == scope
			local c = on and BRONZE or { 0.23, 0.18, 0.11 }
			p:SetBackdropBorderColor(c[1], c[2], c[3], 1)
			if on then p:SetBackdropColor(0.25, 0.18, 0.07, 0.9) else p:SetBackdropColor(0.055, 0.047, 0.035, 0.8) end
			if on then p.text:SetTextColor(1, 0.82, 0) else p.text:SetTextColor(0.78, 0.72, 0.58) end
		end
	end

	-- Send to a player
	local sendLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	sendLabel:SetPoint("TOPLEFT", 16, -46)
	sendLabel:SetText(L["Send to a player"])

	local nameBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	nameBox:SetAutoFocus(false)
	nameBox:SetFontObject(ChatFontNormal)
	nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f.nameBox = nameBox

	local sendBtn = Button(f, L["Send"], 70, function()
		local ok, err = ns.SendMarks(nameBox:GetText())
		if not ok then Status(err) end
	end)
	sendBtn:SetPoint("TOPRIGHT", -16, -67)
	local targetBtn = Button(f, L["Target"], 70, function()
		local key = ns.UnitKey("target") or ns.UnitKey("mouseover")
		if key then nameBox:SetText(key) else Status(L["Target a player first."]) end
	end)
	targetBtn:SetPoint("RIGHT", sendBtn, "LEFT", -6, 0)
	nameBox:SetPoint("TOPLEFT", 22, -68)
	nameBox:SetPoint("TOPRIGHT", targetBtn, "TOPLEFT", -8, -1)
	nameBox:SetHeight(20)

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", 16, -98)
	status:SetPoint("TOPRIGHT", -16, -98)
	status:SetJustifyH("LEFT")
	status:SetHeight(28)
	status:SetText(L["They get asked first. Only marks they don't already have are added."])
	f.status = status
	Rule(f, -134)

	-- Export / import
	local ioLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ioLabel:SetPoint("TOPLEFT", 16, -146)
	ioLabel:SetText(L["Export or import (copy and paste)"])

	local eb
	local ok, sf = pcall(CreateFrame, "ScrollFrame", nil, f, "InputScrollFrameTemplate")
	if ok and sf and sf.EditBox then
		sf:SetPoint("TOPLEFT", 16, -170)
		sf:SetPoint("TOPRIGHT", -16, -170)
		sf:SetHeight(130)
		-- the edit box follows the window's width, which grows with its button rows
		sf:HookScript("OnSizeChanged", function(self, w) eb:SetWidth(math.max(50, (w or 410) - 20)) end)
		if sf.CharCount then sf.CharCount:Hide() end
		eb = sf.EditBox
		eb:SetWidth(390)
		eb:SetMaxLetters(0)
	else
		eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
		eb:SetPoint("TOPLEFT", 22, -170)
		eb:SetPoint("TOPRIGHT", -22, -170)
		eb:SetHeight(130)
		eb:SetMultiLine(true)
	end
	eb:SetFontObject(ChatFontNormal)
	eb:SetAutoFocus(false)
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f.eb = eb

	local summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	summary:SetPoint("TOPLEFT", 16, -342)
	summary:SetPoint("TOPRIGHT", -16, -342)
	summary:SetJustifyH("LEFT")
	summary:SetHeight(28)
	f.summary = summary

	local addNew = Button(f, L["Add new only"], 120, function()
		if not f.parsed then return end
		local added = Apply(f.parsed, false)
		summary:SetText(L["Added %d new marks."]:format(added))
		Print(L["imported %d new marks."]:format(added))
		f.parsed = nil
		f.addNew:Hide(); f.addAll:Hide()
	end)
	local addAll = Button(f, L["Add new and overwrite"], 170, function()
		if not f.parsed then return end
		local added, updated = Apply(f.parsed, true)
		summary:SetText(L["Added %d new marks and updated %d."]:format(added, updated))
		Print(L["imported %d new marks and updated %d."]:format(added, updated))
		f.parsed = nil
		f.addNew:Hide(); f.addAll:Hide()
	end)
	addNew:SetPoint("TOPLEFT", 16, -376)
	addAll:SetPoint("TOPLEFT", 16, -376)
	addNew:Hide(); addAll:Hide()
	f.addNew, f.addAll = addNew, addAll
	-- the second sits beside the first, or alone at the left when the first is not offered
	local function PlaceAddAll(besideFirst)
		addAll:ClearAllPoints()
		if besideFirst then addAll:SetPoint("LEFT", addNew, "RIGHT", 6, 0) else addAll:SetPoint("TOPLEFT", 16, -376) end
	end

	local function ClearParsed() f.parsed = nil; addNew:Hide(); addAll:Hide() end
	local exportBtn = Button(f, L["Export"], 100, function()
		ClearParsed()
		local scope = ScopeOf(ns.Opt("shareScope"))
		local text, n = Export(scope)
		if n == 0 then summary:SetText(SCOPES[scope].noneExport) return end
		eb:SetText(text)
		eb:HighlightText()
		eb:SetFocus()
		summary:SetText(SCOPES[scope].exported:format(n))
	end)
	local previewBtn = Button(f, L["Preview import"], 120, function()
		ClearParsed()
		local entries, err = Parse(eb:GetText())
		if not entries then summary:SetText("|cffff6060" .. err .. "|r") return end
		if #entries == 0 then summary:SetText(L["There are no marks in that text."]) return end
		local new, differ, same = Compare(entries)
		summary:SetText(L["%d marks: %d new, %d different from yours, %d the same."]:format(#entries, new, differ, same))
		f.parsed = entries
		addNew:SetShown(new > 0)
		addAll:SetShown(new > 0 or differ > 0)
		PlaceAddAll(addNew:IsShown())
	end)
	local clearBtn = Button(f, L["Clear"], 60, function()
		eb:SetText("")
		ClearParsed()
		summary:SetText("")
	end)
	exportBtn:SetPoint("TOPLEFT", 16, -312)
	previewBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
	clearBtn:SetPoint("LEFT", previewBtn, "RIGHT", 6, 0)

	-- The window is as wide as its widest row of buttons needs, and as the header does:
	-- the title and the two share choices.
	local rowB = exportBtn:GetWidth() + previewBtn:GetWidth() + clearBtn:GetWidth() + 12
	local rowC = addNew:GetWidth() + addAll:GetWidth() + 6
	local probe = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	local pillsWidth = 4
	for _, sc in ipairs({ "all", "down" }) do
		probe:SetText(SCOPES[sc].label .. " (999)")
		pillsWidth = pillsWidth + math.ceil(probe:GetStringWidth() or 100) + 22
	end
	probe:Hide()
	local header = math.ceil(title:GetStringWidth() or 100) + pillsWidth + 16 + 40 + 24
	f:SetWidth(math.max(460, rowB + 32, rowC + 32, header))

	f.UpdateScope()
	f:Hide()
	return f
end

-- The prompt shown when someone offers marks. Not in UISpecialFrames, so Escape
-- leaves it alone; it declines itself after 45 seconds.
local offerFrame
function ShowOffer(o)
	local f = offerFrame
	if not f then
		f = CreateFrame("Frame", "ThumberOffer", UIParent, "BackdropTemplate")
		f:SetSize(360, 104)
		f:SetPoint("TOP", UIParent, "TOP", 0, -160)
		f:SetFrameStrata("FULLSCREEN_DIALOG")
		f:SetClampedToScreen(true)
		f:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		f:SetBackdropColor(0.08, 0.067, 0.043, 0.97)
		f:SetBackdropBorderColor(BRONZE[1], BRONZE[2], BRONZE[3], 1)
		f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		f.text:SetPoint("TOPLEFT", 16, -14)
		f.text:SetPoint("TOPRIGHT", -16, -14)
		f.text:SetJustifyH("CENTER")
		f.accept = Button(f, ACCEPT or L["Accept"], 110, function()
			local cur = f.offer
			f:Hide()
			if cur then Accept(cur) end
		end)
		f.accept:SetPoint("TOPRIGHT", f, "TOP", -4, -68)
		f.decline = Button(f, DECLINE or L["Decline"], 110, function()
			local cur = f.offer
			f:Hide()
			if cur and offer == cur then Decline(cur) end
		end)
		f.decline:SetPoint("TOPLEFT", f, "TOP", 4, -68)
		offerFrame = f
	end
	f.offer = o
	f.text:SetText(L["|cffffd100%s|r wants to share %d Thumber marks with you.\nYour own marks are kept; only new ones are added."]:format(o.sender, o.count))
	f:Show()
	C_Timer.After(45, function()
		if f.offer == o and offer == o then
			f:Hide()
			Decline(o)
		end
	end)
end

function ns.RefreshShareScope()
	if dlg then dlg.UpdateScope() end
end

function ns.OpenShare()
	dlg = dlg or BuildDialog()
	dlg.UpdateScope()
	Status = function(text) if dlg then dlg.status:SetText(text or "") end end
	if dlg:IsShown() then dlg:Hide() else dlg:Show() end
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_LOGIN" then
		local register = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
		if register then pcall(register, PREFIX) end
	else
		OnMessage(...)
	end
end)
