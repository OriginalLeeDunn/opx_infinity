--- Resource-owned optical preview; finite geometry with a short native expiry.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model = M.Model
M.Guide = {}
local G = M.Guide
local shown, refused, last = false, false, -math.huge
function G.Clear()
	if shown then Open77.debugDraw.clear('pool.aim'); shown = false end
end
function G.Reset() G.Clear(); refused, last = false, -math.huge end
function G.End(spec, points, angle) return M.Prediction.End(spec,points,angle) end
function G.Draw(spec, points, angle, now, profile, power)
	profile = profile or M.Assistance.Profile(M.Assistance.Read(), 1)
	if profile.level == 0 then G.Clear(); return end
	if refused or now-last < 100 then return end
	last = now
	local paths, contact = M.Prediction.Trace(spec, points, angle, power, profile)
	local lines = {}
	local c, s = math.cos(math.rad(spec.yaw)), math.sin(math.rad(spec.yaw))
	local function point(x, y)
		return { x=spec.x+x*c-y*s, y=spec.y+x*s+y*c, z=spec.z-Model.RADIUS+0.003 }
	end
	for _, path in ipairs(paths) do
		lines[#lines+1] = { a=point(path[1],path[2]), b=point(path[3],path[4]), color=path[5] }
	end
	if contact then
		for index = 0, 7 do
			local a, b = index*math.pi/4, (index+1)*math.pi/4
			lines[#lines+1] = { a=point(contact[1]+math.cos(a)*Model.RADIUS,contact[2]+math.sin(a)*Model.RADIUS),
				b=point(contact[1]+math.cos(b)*Model.RADIUS,contact[2]+math.sin(b)*Model.RADIUS), color='#ADEFFFCC' }
		end
	end
	if #lines == 0 then G.Clear(); return end
	local ok, why = Open77.debugDraw.set('pool.aim', { lines=lines, ttl=0.2, maxDistance=8, thickness=1.5 })
	if not ok then refused=true; G.Clear(); OPX.Note('pool', 'aim guide unavailable: '..tostring(why)); return end
	shown = true
end
