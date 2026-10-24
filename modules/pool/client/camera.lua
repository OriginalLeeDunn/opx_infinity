--- A cue-ball view and a table view, owned only while this player is shooting.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model = M.Model
M.Camera = {}
local C = M.Camera
local id, pose, last, active
local function mix(a, b, amount) return a + (b-a)*amount end
function C.Clear()
	-- Destroying our definition restores the view only if THIS camera held it.
	-- Never deactivate another camera owned by a different module in Infinity.
	if id then
		local ok, why = Open77.camera.destroy(id)
		if not ok and why ~= 'camera_not_found' then OPX.Note('pool', 'camera cleanup: ' .. tostring(why)) end
	end
	id, pose, last, active = nil, nil, nil, false
end
function C.Pose(spec, points, angle, overview, height)
	local c, s = math.cos(angle), math.sin(angle)
	local ball = points[1]
	if overview then
		local at = Model.World(spec, -c*0.65, -s*0.65)
		at.z = at.z+2.35
		local aim = Model.World(spec, 0, 0)
		return { position = at, target = aim, fov = 62 }
	end
	local at = Model.World(spec, ball[1]-c*1.25, ball[2]-s*1.25)
	at.z = at.z+height
	local aim = Model.World(spec, ball[1]+c*0.45, ball[2]+s*0.45)
	aim.z = aim.z+0.015
	return { position = at, target = aim, fov = 52 }
end
function C.Update(spec, points, angle, overview, height, now)
	local wanted = C.Pose(spec, points, angle, overview, height)
	if not id then
		local why
		id, why = Open77.camera.create({ position = wanted.position, lookAt = wanted.target, fov = wanted.fov })
		if not id then return false, why end
		local ok, refusal = Open77.camera.activate(id, { blendMs = 250 })
		if not ok then C.Clear(); return false, refusal end
		pose, last, active = wanted, now, true
		return true
	end
	-- Frame-rate-independent smoothing, including the transition to the table.
	local amount = 1-math.exp(-math.max(0, math.min(100, now-last))/80)
	last = now
	for _, key in ipairs({ 'x', 'y', 'z' }) do
		pose.position[key] = mix(pose.position[key], wanted.position[key], amount)
		pose.target[key] = mix(pose.target[key], wanted.target[key], amount)
	end
	pose.fov = mix(pose.fov, wanted.fov, amount)
	local ok, why = Open77.camera.setTransform(id, { position = pose.position, fov = pose.fov })
	if not ok then C.Clear(); return false, why end
	ok, why = Open77.camera.lookAt(id, pose.target)
	if not ok then C.Clear(); return false, why end
	return true
end
function C.Check()
	if not active then return true end
	local snapshot, why = Open77.camera.cameras()
	if type(snapshot) ~= 'table' then return false, why end
	if snapshot.activeCamera ~= id or snapshot.held ~= true then return false, 'camera_released' end
	return true
end
