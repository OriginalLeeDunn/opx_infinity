--- Only visual objects; movement never respawns an entity or edits an alias.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model = M.Model
M.Render = {}
local R = M.Render
local ids, stick, created, failure = {}, nil, {}, nil
function R.Clear()
	for index, id in pairs(ids) do Open77.props.remove(id); ids[index] = nil end
	if stick then Open77.props.remove(stick); stick = nil end
	created = {}
end
function R.Reset() R.Clear(); failure = nil end
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
	local id, why = Open77.props.create({ model = model, position = position, yaw = yaw or 0, collision = false })
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
function R.Draw(spec, positions, aiming, angle, power)
	if failure then return false end
	local models = Model.Models()
	if not models then return fail('invalid model configuration') end
	for index, ball in ipairs(positions) do
		if ball[3] then
			local position = Model.World(spec, ball[1], ball[2])
			if not ids[index] then
				local id, why = make(index == 1 and models.cue or models.object, position)
				if not id then return fail(why) end
				ids[index] = id
			elseif not move(ids[index], { position = position }) then return false end
		elseif ids[index] then Open77.props.remove(ids[index]); created[ids[index]], ids[index] = nil, nil end
	end
	if aiming and positions[1][3] then
		local distance = models.stickOffset + power*0.35
		local at = Model.World(spec, positions[1][1]-math.cos(angle)*distance, positions[1][2]-math.sin(angle)*distance)
		local yaw = math.deg(angle) + spec.yaw - 90 + models.stickYaw
		if not stick then
			local id, why = make(models.stick, at, yaw)
			if not id then return fail(why) end
			stick = id
		elseif not move(stick, { position = at, yaw = yaw }) then return false end
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
