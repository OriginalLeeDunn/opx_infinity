--- Bounded shared configuration, rejecting unplaced or malformed sites.
-- @author dop42
local M = OPX.Modules.Get('salvage')
M.Model = {}
local Model = M.Model
local function point(raw)
	if type(raw) ~= 'table' then return nil end
	local x, y, z = OPX.Spots.Coordinate(raw.x), OPX.Spots.Coordinate(raw.y), OPX.Spots.Coordinate(raw.z)
	local bucket = OPX.Spots.Integer(raw.bucket)
	if not x or not y or not z or not bucket or bucket < 0 or bucket > 65535 then return nil end
	if x == 0 and y == 0 and z == 0 then return nil end
	return { x = x, y = y, z = z, bucket = bucket }
end
function Model.Settings()
	local settings = OPX.Config.MODULES.salvage
	return type(settings) == 'table' and settings or {}
end
function Model.Limits()
	local cfg = Model.Settings()
	local duration, cooldown, reach = OPX.Math.Finite(cfg.DURATION_MS), OPX.Math.Finite(cfg.COOLDOWN_SECONDS), OPX.Math.Finite(cfg.REACH)
	if not duration or duration % 1 ~= 0 or duration < 1000 or duration > 60000 then return nil end
	if not cooldown or cooldown % 1 ~= 0 or cooldown < 60 or cooldown > 86400 then return nil end
	if not reach or reach <= 0 or reach > 5 then return nil end
	return { duration = duration, cooldown = cooldown, reach = reach }
end
function Model.Sites()
	local sites, keys = {}, {}
	if not Model.Limits() then return sites end
	local configured = Model.Settings().SITES
	if type(configured) ~= 'table' then return sites end
	for key in pairs(configured) do
		if type(key) == 'string' and #key <= 40 and key:match('^[%w_%-]+$') then keys[#keys + 1] = key end
	end
	table.sort(keys)
	for i = 1, math.min(#keys, 16) do
		local raw = Model.Settings().SITES[keys[i]]
		local pickup, bench = type(raw) == 'table' and point(raw.pickup), type(raw) == 'table' and point(raw.bench)
		if pickup and bench then sites[#sites + 1] = { key = keys[i], pickup = pickup, bench = bench } end
	end
	return sites
end
