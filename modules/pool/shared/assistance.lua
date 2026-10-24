--- Installed chrome selects presentation only; all real shot outcomes stay server-owned.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Number = M.Model.Number
M.Assistance = {}
local A = M.Assistance
local function integer(value, low, high, fallback)
	return Number(value, low, high) and value%1 == 0 and value or fallback
end
function A.Read(raw)
	raw = type(raw) == 'table' and raw or {}
	local settings = { enabled = raw.ENABLED == nil or raw.ENABLED == true,
		baseline = integer(raw.BASE_LEVEL, 0, 3, 0), condition = Number(raw.MIN_CONDITION, 0, 100) or 1,
		bounces = integer(raw.MAX_BOUNCES, 0, 2, 2), distance = Number(raw.MAX_DISTANCE, 0.5, 6) or 4.5,
		angleStep = Number(raw.ANGLE_STEP, 0.001, 0.05) or 0.005,
		powerStep = Number(raw.POWER_STEP, 0.01, 0.2) or 0.05,
		power = Number(raw.DEFAULT_POWER, 0.02, 1) or 0.5, implants = {} }
	local implants = raw.IMPLANTS
	if implants == nil then implants = { kiroshi_optics = { SLOT = 'eyes', TIERS = { 1, 2, 3 } } } end
	local count = 0
	for id, entry in pairs(type(implants) == 'table' and implants or {}) do
		if count >= 32 then break end
		count = count+1
		if type(id) == 'string' and #id <= 64 and id:match('^[%w_.-]+$')
			and type(entry) == 'table' and type(entry.SLOT) == 'string' and #entry.SLOT > 0 and #entry.SLOT <= 32 and type(entry.TIERS) == 'table' then
			local tiers = {}
			for tier = 1, 5 do tiers[tier] = integer(entry.TIERS[tier], 0, 3, 0) end
			settings.implants[id] = { slot = entry.SLOT, tiers = tiers }
		end
	end
	return settings
end
function A.Level(settings, installed)
	if not settings.enabled then return 0 end
	local level = settings.baseline
	if type(installed) ~= 'table' then return level end
	for index = 1, math.min(#installed, 32) do
		local entry = installed[index]
		local implant = type(entry) == 'table' and settings.implants[entry.chrome]
		local tier = implant and integer(entry.tier, 1, 5)
		if tier and entry.slot == implant.slot and Number(entry.condition, settings.condition, 100) then
			level = math.max(level, implant.tiers[tier])
		end
	end
	return level
end
function A.Profile(settings, level)
	level = settings.enabled and integer(level, 0, 3, 0) or 0
	return { level = level, distance = math.min(settings.distance, level == 1 and 1.5 or level == 2 and 3 or 6),
		bounces = level == 3 and settings.bounces or 0, outgoing = level >= 2,
		angleStep = settings.angleStep*(4-level), powerStep = settings.powerStep, power = settings.power }
end
