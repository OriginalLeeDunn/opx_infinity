--- Only visual objects; movement never respawns an entity or edits an alias.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model = M.Model
M.Render = {}
local R = M.Render
local ids, stick, created, failure, stroke = {}, nil, {}, nil, nil
local models
function R.Clear()
	for index, id in pairs(ids) do Open77.props.remove(id); ids[index] = nil end
	if stick then Open77.props.remove(stick); stick = nil end
	created, stroke = {}, nil
end
function R.Reset() R.Clear(); failure = nil; models = Model.Models() end
local function fail(why)
	if not failure then
		failure = tostring(why)
		OPX.Note('pool', 'local model/transform refused: ' .. failure)
		OPX.Toast.Locale('pool.models', nil, 'error')
	end
	R.Clear()
	return false
end
local function make(model, position, yaw)
	local id, why = Open77.props.create({ model = model, position = position, yaw = yaw or 0, collision = false, physics = "none", visible = true })
	if not id then return nil, why end
	created[id] = OPX.Now()
	return id
end
local function move(id, transform)
	local called, ok, why = pcall(Open77.props.setTransform, id, transform)
	if called and ok == true then return true end
	-- Native entities stream asynchronously after create. Keep the same object
	-- briefly instead of treating its first not-ready result as a broken model.
	if created[id] and OPX.Now()-created[id] < 3000 then return true end
	return fail('setTransform: ' .. tostring(called and why or ok))
end
function R.Strike(spec, positions, angle, power)
	if not positions or not positions[1] then return end
	stroke = { at = OPX.Now(), point = { positions[1][1], positions[1][2], true }, angle = angle, power = power }
end
function R.StickTransform(spec, ball, angle, power, forward)
	models = models or Model.Models()
	local distance = math.max(0.2, models.stickOffset + power*0.35-(forward or 0))
	local at = Model.World(spec, ball[1]-math.cos(angle)*distance, ball[2]-math.sin(angle)*distance)
	at.z = at.z+0.006
	return { position = at, yaw = math.deg(angle)+spec.yaw-90+models.stickYaw }
end
function R.Draw(spec, positions, aiming, angle, power)
	if failure then return false end
	models = models or Model.Models()
	if not models then return fail('invalid model configuration') end
	for index, ball in ipairs(positions) do
		if ball[3] then
			local position = Model.World(spec, ball[1], ball[2])
			if not ids[index] then
				local id, why = make(index == 1 and models.cue or models.objects[index-1], position)
				if not id then return fail(why) end
				ids[index] = id
			elseif not move(ids[index], { position = position }) then return false end
		elseif ids[index] then Open77.props.remove(ids[index]); created[ids[index]], ids[index] = nil, nil end
	end
	local shot = stroke and OPX.Now()-stroke.at < 220 and stroke or nil
	if stroke and not shot then stroke = nil end
	if (aiming and positions[1][3]) or shot then
		local point, direction, strength, forward = positions[1], angle, power, 0
		if shot then
			point, direction, strength = shot.point, shot.angle, shot.power
			forward = (strength*0.35+0.1)*math.min(1, (OPX.Now()-shot.at)/110)
		end
		local transform = R.StickTransform(spec, point, direction, strength, forward)
		if not stick then
			local id, why = make(models.stick, transform.position, transform.yaw)
			if not id then return fail(why) end
			stick = id
		elseif not move(stick, transform) then return false end
	elseif stick then Open77.props.remove(stick); created[stick], stick = nil, nil end
	return true
end
function R.Check()
	if failure then return false end
	local rows, why = Open77.props.list()
	if type(rows) ~= 'table' then return fail(why or 'no local prop inspection') end
	for _, row in ipairs(rows) do
		local since = created[row.id]
		if since and (row.failed == true or tostring(row.backend):lower():find('marker', 1, true)
			or (OPX.Now()-since > 3000 and row.rendered ~= true)) then return fail(row.backend or 'model not rendered') end
	end
	return true
end
function R.Failed() return failure ~= nil end
