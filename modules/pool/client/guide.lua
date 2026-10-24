--- A bounded straight aiming aid, ending at the first ball or cushion.
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
function G.End(spec, points, angle)
	local x, y, c, s = points[1][1], points[1][2], math.cos(angle), math.sin(angle)
	local length = 6
	local r = Model.RADIUS
	if math.abs(c) > 1e-6 then length = math.min(length, ((c > 0 and spec.halfLength-r or -spec.halfLength+r)-x)/c) end
	if math.abs(s) > 1e-6 then length = math.min(length, ((s > 0 and spec.halfWidth-r or -spec.halfWidth+r)-y)/s) end
	for index = 2, Model.BALLS do
		local ball = points[index]
		if ball[3] then
			local dx, dy = ball[1]-x, ball[2]-y
			local ahead, side = dx*c+dy*s, dx*s-dy*c
			if ahead > 0 and math.abs(side) < r*2 then
				local touch = ahead-math.sqrt(math.max(0, r*r*4-side*side))
				if touch >= 0 then length = math.min(length, touch) end
			end
		end
	end
	length = math.max(0, length)
	return x+c*length, y+s*length, length
end
function G.Draw(spec, points, angle, now)
	if refused or now-last < 50 then return end
	last = now
	local x, y, length = G.End(spec, points, angle)
	local ball = points[1]
	local lines = {}
	local function point(px, py)
		local p = Model.World(spec, px, py); p.z = p.z-Model.RADIUS+0.003; return p
	end
	local count = math.min(12, math.max(1, math.ceil(length/0.08)))
	for index = 0, count-1 do
		local a, b = index/count, math.min(1, (index+0.55)/count)
		lines[#lines+1] = { a = point(ball[1]+(x-ball[1])*a, ball[2]+(y-ball[2])*a),
			b = point(ball[1]+(x-ball[1])*b, ball[2]+(y-ball[2])*b), color = '#ADEFFFC0' }
	end
	for index = 0, 7 do
		local a, b = index*math.pi/4, (index+1)*math.pi/4
		lines[#lines+1] = { a = point(x+math.cos(a)*Model.RADIUS, y+math.sin(a)*Model.RADIUS),
			b = point(x+math.cos(b)*Model.RADIUS, y+math.sin(b)*Model.RADIUS), color = '#ADEFFFCC' }
	end
	local ok, why = Open77.debugDraw.set('pool.aim', { lines = lines, ttl = 0.2, maxDistance = 8, thickness = 1.5 })
	if not ok then
		refused = true; G.Clear(); OPX.Note('pool', 'aim guide unavailable: ' .. tostring(why)); return
	end
	shown = true
end
