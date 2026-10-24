--- Bounded geometry and wire vocabulary; pure in both sandboxes.
-- @author dop42
local M = OPX.Modules.Get('pool')
M.Model = { RADIUS = 0.028575, BALLS = 16, STEP = 1 / 120, DELAY = 100 }
local Model = M.Model
function Model.Number(value, low, high)
	return type(value) == 'number' and value == value and value >= low and value <= high and value or nil
end
function Model.Table()
	local cfg = OPX.Config.MODULES.pool or {}
	local choice = cfg.TABLE
	if type(choice) ~= 'table' or choice.enabled ~= true then return nil end
	local raw = choice
	if choice.preset ~= nil then
		if type(choice.preset) ~= 'string' or type(cfg.PRESETS) ~= 'table' then return nil end
		raw = cfg.PRESETS[choice.preset]
		if type(raw) ~= 'table' then return nil end
	end
	local x, y, z = Model.Number(raw.x, -20000, 20000), Model.Number(raw.y, -20000, 20000), Model.Number(raw.z, -2000, 5000)
	local yaw, bucket = Model.Number(raw.yaw, -360, 360), Model.Number(raw.bucket, 0, 65535)
	local length, width = Model.Number(raw.halfLength, 0.9, 2), Model.Number(raw.halfWidth, 0.4, 1)
	if not x or not y or not z or not yaw or not bucket or bucket % 1 ~= 0 or not length or not width
		or (x == 0 and y == 0 and z == 0) then return nil end
	return { x = x, y = y, z = z, yaw = yaw, bucket = bucket, halfLength = length, halfWidth = width,
		label = OPX.Text.Clean(raw.label, 48) or 'Pool' }
end
function Model.World(spec, x, y)
	local angle = math.rad(spec.yaw)
	local c, s = math.cos(angle), math.sin(angle)
	return { x = spec.x + x * c - y * s, y = spec.y + x * s + y * c, z = spec.z }
end
function Model.Local(spec, x, y)
	local angle = math.rad(spec.yaw)
	local c, s = math.cos(angle), math.sin(angle)
	return (x-spec.x)*c + (y-spec.y)*s, -(x-spec.x)*s + (y-spec.y)*c
end
function Model.Models()
	local raw = (OPX.Config.MODULES.pool or {}).MODELS
	if type(raw) ~= 'table' then return nil end
	local result = {}
	for _, name in ipairs({ 'cue', 'object', 'stick' }) do
		local path = raw[name]
		if type(path) ~= 'string' or #path == 0 or #path > 256 or path:find('%c') then return nil end
		result[name] = path
	end
	result.objects = {}
	local used = {}
	if raw.objects ~= nil and (type(raw.objects) ~= 'table' or #raw.objects ~= Model.BALLS-1) then return nil end
	for number = 1, Model.BALLS-1 do
		local path = raw.objects and raw.objects[number] or
			('base\\environment\\decoration\\recreation\\sports\\ball\\ball_' .. string.char(98+number) .. '_billiard.mesh')
		if type(path) ~= 'string' or #path == 0 or #path > 256 or path:find('%c') or used[path] then return nil end
		used[path] = true
		result.objects[number] = path
	end
	result.stickYaw = Model.Number(raw.stickYaw, -360, 360) or 0
	result.stickOffset = Model.Number(raw.stickOffset, 0.2, 2) or 0.7
	return result
end
