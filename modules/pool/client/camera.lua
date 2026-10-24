--- A cue-ball view and a table view, owned only while this player is shooting.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model = M.Model
M.Camera = {}
local C = M.Camera
local id, pose, last, active
local bodyWarning = false
local function bodyFallback(why)
	return why == 'invalid_camera_body' or why == 'camera_body_unavailable' or why == 'invalid_camera_options'
end
local function createView(wanted, fullBody)
	-- Verified in the signed op77.152 client: create reads thirdPersonBody and
	-- cameras() reports it. The op77.148 reference omits this optional field.
	local options = { position = wanted.position, lookAt = wanted.target, fov = wanted.fov }
	if fullBody then options.thirdPersonBody = true end
	local camera, why = Open77.camera.create(options)
	if not camera then return nil, why end
	local ok, refusal = Open77.camera.activate(camera, { blendMs = 250 })
	if not ok then Open77.camera.destroy(camera); return nil, refusal end
	return camera
end
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
		-- A stable broadside view: fit the full cloth instead of hovering over it.
		local distance = math.max(spec.halfWidth+1.8, spec.halfLength*1.45+spec.halfWidth)
		local at = Model.World(spec, 0, -distance)
		at.z = at.z+(Model.Number((M.Settings or {}).OVERVIEW_HEIGHT, 1.2, 2.4) or 1.65)
		return { position = at, target = Model.World(spec, 0, 0), fov = 60 }
	end
	-- The ball is the exact look-at point, on the shot axis with no shoulder offset.
	local at = Model.World(spec, ball[1]-c*1.25, ball[2]-s*1.25)
	at.z = at.z+height
	return { position = at, target = Model.World(spec, ball[1], ball[2]), fov = 52 }
end
function C.Update(spec, points, angle, overview, height, now)
	local wanted = C.Pose(spec, points, angle, overview, height)
	if not id then
		local why
		id, why = createView(wanted, true)
		if not id and bodyFallback(why) then
			if not bodyWarning then OPX.Note('pool', 'full-body camera unavailable; legacy view: ' .. tostring(why)); bodyWarning = true end
			id, why = createView(wanted, false)
		end
		if not id then return false, why end
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
