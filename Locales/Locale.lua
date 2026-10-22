local _, ns = ...

-- Every player-visible string in Thumber goes through ns.L, keyed by its English text:
-- a locale file adds L["English text"] = "translation", and anything without a
-- translation (or on an English client) simply shows the English text itself.
ns.L = setmetatable({}, { __index = function(_, key) return key end })
