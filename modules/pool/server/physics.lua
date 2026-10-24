--- Original equal-mass disk solver with swept time-of-impact collisions.
-- @author dop42
-- Every fixed tick advances to the earliest ball/rail/pocket event. No client
-- integrates physics or supplies outcomes. The contact ceiling fails stationary.
local M = OPX.Modules.Get('pool')
local Model, R = M.Model, M.Model.RADIUS
M.Physics = {}
local P = M.Physics
local DRAG, RESTITUTION, RAIL, EPS = 0.7, 0.97, 0.82, 1e-8
function P.Rack(spec)
	local balls = { { x = -spec.halfLength*0.5, y = 0, vx = 0, vy = 0, alive = true } }
	-- Five rows, a tiny gap to avoid overlapping contact chains at the break.
	local spacing = R*2.02
	for row = 0, 4 do
		for column = 0, row do
			balls[#balls+1] = { x = spec.halfLength*0.35+row*spacing*math.sqrt(3)/2,
				y = (column-row/2)*spacing, vx = 0, vy = 0, alive = true }
		end
	end
	return balls
end
local function hitTime(x, y, vx, vy, radius, limit)
	local c = x*x + y*y - radius*radius
	local dot = x*vx + y*vy
	if c <= EPS then return dot < -EPS and 0 or nil end
	local a = vx*vx + vy*vy
	if a < EPS or dot >= 0 then return nil end
	local discriminant = dot*dot - a*c
	if discriminant < 0 then return nil end
	local t = (-dot - math.sqrt(discriminant)) / a
	return t >= -EPS and t <= limit + EPS and math.max(0, t) or nil
end
function P.Moving(balls)
	for _, ball in ipairs(balls) do if ball.alive and ball.vx*ball.vx + ball.vy*ball.vy > 0 then return true end end
	return false
end
function P.Shoot(balls, angle, strength)
	if not Model.Number(angle, -math.pi * 2, math.pi * 2) or not Model.Number(strength, 0.02, 1)
		or P.Moving(balls) or not balls[1].alive then return false end
	local speed = 0.2 + 4.3 * strength
	balls[1].vx, balls[1].vy = math.cos(angle)*speed, math.sin(angle)*speed
	return true
end
function P.Frame(balls, time)
	local frame = { time = time, balls = {} }
	for index, ball in ipairs(balls) do frame.balls[index] = { ball.x, ball.y, ball.alive } end
	return frame
end
function P.Step(balls, spec, dt, contact)
	local remaining, contacts = dt, 0
	local pockets = { {-spec.halfLength,-spec.halfWidth}, {0,-spec.halfWidth}, {spec.halfLength,-spec.halfWidth},
		{-spec.halfLength,spec.halfWidth}, {0,spec.halfWidth}, {spec.halfLength,spec.halfWidth} }
	while remaining > EPS do
		local soon, kind, one, two = remaining, nil, nil, nil
		local function offer(time, what, a, b)
			if time and time <= soon then soon, kind, one, two = time, what, a, b end
		end
		for index, ball in ipairs(balls) do
			if ball.alive then
				if ball.vx > EPS then offer((spec.halfLength-R-ball.x)/ball.vx, 'x', index)
				elseif ball.vx < -EPS then offer((-spec.halfLength+R-ball.x)/ball.vx, 'x', index) end
				if ball.vy > EPS then offer((spec.halfWidth-R-ball.y)/ball.vy, 'y', index)
				elseif ball.vy < -EPS then offer((-spec.halfWidth+R-ball.y)/ball.vy, 'y', index) end
				for _, pocket in ipairs(pockets) do
					if (ball.x-pocket[1])^2 + (ball.y-pocket[2])^2 <= 0.065^2 then offer(0, 'pocket', index)
					else offer(hitTime(ball.x-pocket[1], ball.y-pocket[2], ball.vx, ball.vy, 0.065, remaining), 'pocket', index) end
				end
				for other = index + 1, #balls do
					local b = balls[other]
					if b.alive then offer(hitTime(b.x-ball.x, b.y-ball.y, b.vx-ball.vx, b.vy-ball.vy, R*2, remaining), 'ball', index, other) end
				end
			end
		end
		-- Reject a negative rail event caused by corrupt/outside state.
		if soon < -EPS then return false end
		soon = math.max(0, soon)
		for _, ball in ipairs(balls) do
			if ball.alive then ball.x, ball.y = ball.x + ball.vx*soon, ball.y + ball.vy*soon end
		end
		remaining = remaining - soon
		if not kind then break end
		contacts = contacts + 1
		if contacts > 128 then
			for _, ball in ipairs(balls) do ball.vx, ball.vy = 0, 0 end
			return false
		end
		local a = balls[one]
		if kind == 'pocket' then
			if contact then contact('pocket', a.x, a.y, 0.8) end
			a.alive, a.vx, a.vy = false, 0, 0
		elseif kind == 'x' then
			if contact then contact('rail', a.x, a.y, math.abs(a.vx)) end
			a.vx = -a.vx * RAIL
		elseif kind == 'y' then
			if contact then contact('rail', a.x, a.y, math.abs(a.vy)) end
			a.vy = -a.vy * RAIL
		else
			local b = balls[two]
			local dx, dy = b.x-a.x, b.y-a.y
			local distance = math.sqrt(dx*dx+dy*dy)
			local nx, ny = dx / math.max(distance, EPS), dy / math.max(distance, EPS)
			local relative = (a.vx-b.vx)*nx + (a.vy-b.vy)*ny
			if relative > 0 then
				if contact then contact('ball', (a.x+b.x)*0.5, (a.y+b.y)*0.5, relative) end
				local impulse = relative * (1 + RESTITUTION) * 0.5
				a.vx, a.vy = a.vx-impulse*nx, a.vy-impulse*ny
				b.vx, b.vy = b.vx+impulse*nx, b.vy+impulse*ny
			end
			local correction = math.max(0, R*2-distance)*0.5 + 1e-7
			a.x, a.y, b.x, b.y = a.x-nx*correction, a.y-ny*correction, b.x+nx*correction, b.y+ny*correction
		end
	end
	for _, ball in ipairs(balls) do
		local speed = math.sqrt(ball.vx*ball.vx+ball.vy*ball.vy)
		if speed > 0 then
			local nextSpeed = math.max(0, speed-DRAG*dt)
			if nextSpeed < 0.012 then nextSpeed = 0 end
			ball.vx, ball.vy = ball.vx*nextSpeed/speed, ball.vy*nextSpeed/speed
		end
	end
	return true
end
--- Practice scratch recovery: choose a free point, never overlap an object ball.
function P.Respot(balls, spec)
	if balls[1].alive then return true end
	for row = 0, 8 do
		for column = -4, 4 do
			local x, y = -spec.halfLength*0.55 + row*R*2.2, column*R*2.2
			local clear = true
			for index = 2, #balls do
				local b = balls[index]
				if b.alive and (b.x-x)^2+(b.y-y)^2 < (R*2.05)^2 then clear = false end
			end
			if clear then balls[1] = { x = x, y = y, vx = 0, vy = 0, alive = true }; return true end
		end
	end
	return false
end
