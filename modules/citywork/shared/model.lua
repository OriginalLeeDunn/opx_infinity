--- Bounded work definitions and pay, independent of client claims.
-- @author dop42
local M = OPX.Modules.Get('citywork')
M.Model = {}
local Model = M.Model
local function whole(value, low, high)
	local n = OPX.Math.Finite(value)
	if n and n % 1 == 0 and n >= low and n <= high then return math.tointeger(n) end
end
local function point(raw)
	if type(raw) ~= 'table' then return nil end
	local x, y, z = OPX.Spots.Coordinate(raw.x), OPX.Spots.Coordinate(raw.y), OPX.Spots.Coordinate(raw.z)
	local bucket = whole(raw.bucket, 0, 65535)
	if not x or not y or not z or not bucket or (x == 0 and y == 0 and z == 0) then return nil end
	return { x = x, y = y, z = z, bucket = bucket }
end
function Model.Build(raw, pause)
	raw = type(raw) == 'table' and raw or {}
	local built = { dispatch = point(raw.DISPATCH), routes = {}, order = {}, pay = {},
		selfEnrol = raw.SELF_ENROL == true, reach = OPX.Math.Finite(raw.REACH),
		maxOpen = whole(raw.MAX_OPEN, 1, 12), travel = whole(raw.MIN_TRAVEL_S, 10, 600),
		handover = whole(raw.HANDOVER_MS, 1000, 30000), service = whole(raw.SERVICE_MS, 1000, 60000),
		command = type(raw.COMMAND) == 'string' and raw.COMMAND:match('^[%w_]+$') and raw.COMMAND or nil }
	if not built.dispatch or not built.reach or built.reach <= 0 or built.reach > 5
		or not built.maxOpen or not built.travel or not built.handover or not built.service then return nil end
	for _, job in ipairs({ 'courier', 'technician' }) do
		local pay = type(raw.PAY) == 'table' and raw.PAY[job] or nil
		if type(pay) ~= 'table' then return nil end
		local free, pro, grade = whole(pay.freelance, 100, 2000), whole(pay.professional, 100, 2000), whole(pay.perGrade, 0, 100)
		if not free or not pro or not grade then return nil end
		built.pay[job] = { freelance = free, professional = pro, perGrade = grade }
		if pause then pause() end
	end
	for key, rawPoint in pairs(type(raw.ROUTES) == 'table' and raw.ROUTES or {}) do
		local at = point(rawPoint)
		if type(key) == 'string' and #key <= 32 and key:match('^[%w_]+$') and at then
			local dx, dy, dz = at.x - built.dispatch.x, at.y - built.dispatch.y, at.z - built.dispatch.z
			if dx * dx + dy * dy + dz * dz >= 10000 then built.routes[key] = at; built.order[#built.order + 1] = key end
		end
		if pause then pause() end
	end
	table.sort(built.order)
	if #built.order == 0 or #built.order > 12 then return nil end
	return built
end
function Model.Professional(data, job)
	local primary = type(data) == 'table' and data.job or nil
	if type(primary) ~= 'table' or primary.name ~= job or primary.onDuty ~= true then return nil end
	return type(primary.grade) == 'table' and whole(primary.grade.level, 0, 2) or nil
end
function Model.Pay(built, data, job, professional)
	local pay = built.pay[job]
	if not pay then return nil end
	if not professional then return pay.freelance end
	local grade = Model.Professional(data, job)
	return grade and (pay.professional + grade * pay.perGrade) or nil
end
