--- The character's gameplay needs, and the status-effect registry every module
--- adds a chip to.
-- @author dop42
--
-- Two things live here: the effects (a chip with a label, a tone, a priority and
-- an optional countdown, owned by whoever added it) and the needs -- `hunger`,
-- `thirst`, `stamina` and `streetCred` -- in their own table, keyed on the
-- citizen id. This module draws nothing: it publishes what it holds and a view
-- module draws it.
--
-- `health`, `armor`, `isDead` and `inLastStand` are deliberately NOT here. They
-- belong to the character, which reads the stored health to clamp a respawn and
-- applies armour after it; a need is a value this module owns outright.
--
-- The bounds below load on both sides, so the two halves cannot clamp
-- differently. The SERVER owns the values (the owner's ruling, 2026-10): it
-- decays them, raises them, stores them and sends them; the client reads what it
-- is sent through the same bounds and draws it.

OPX.Modules.Declare{
	id = 'needs',
	side = 'both',
	fatal = false,
	-- Every row is keyed on the citizen id, and only the character module knows
	-- which character a player has loaded.
	requires = { 'character' },
}

local M = OPX.Modules.Get('needs')

-- Need name to its MIN, MAX, DEFAULT and optional DECAY_PER_MINUTE, read from
-- the settings in `Init` rather than at load.
M.Fields = {}

M.Bounds = {}
local Bounds = M.Bounds

--- Adopts the configured needs. Called from both halves' `Init`.
-- @author dop42
function M.ReadSettings()
	local fields = M.Settings.NEEDS
	if type(fields) ~= 'table' or next(fields) == nil then
		error('config/needs.lua declares no NEEDS')
	end
	M.Fields = fields
end

--- Whether a key names a need this module owns.
-- @author dop42
-- @param key any
-- @return boolean
function M.Bounds.IsField(key)
	return type(key) == 'string' and M.Fields[key] ~= nil
end

--- Answers a value within its need's bounds, or nil when it is not finite.
-- @author dop42
-- @param key string
-- @param value any
-- @return number|nil
function M.Bounds.Clamp(key, value)
	local field = M.Fields[key]
	if field == nil then return nil end
	local number = tonumber(value)
	-- A NaN passes inside every bound written and an infinity outside every one,
	-- so finiteness is checked before the clamp and never by it.
	if not OPX.Math.IsFinite(number) then return nil end
	return OPX.Math.Clamp(number, field.MIN, field.MAX)
end

--- Answers every configured need at its default value.
-- @author dop42
-- @return table
function M.Bounds.Defaults()
	local values = {}
	for key, field in pairs(M.Fields) do values[key] = field.DEFAULT end
	return values
end

--- Clamps every configured need of a payload, defaults filling the gaps.
-- @author dop42
--
-- The count tells a payload of needs from a table holding none, which the server
-- refuses. A stored row missing a need -- one added to the configuration after
-- it was written -- takes that need's default.
-- @param raw any
-- @return table, integer
function M.Bounds.Read(raw)
	local values, count = {}, 0
	for key, field in pairs(M.Fields) do
		local clamped = nil
		if type(raw) == 'table' then clamped = Bounds.Clamp(key, raw[key]) end
		if clamped == nil then
			values[key] = field.DEFAULT
		else
			values[key] = clamped
			count = count + 1
		end
	end
	return values, count
end
