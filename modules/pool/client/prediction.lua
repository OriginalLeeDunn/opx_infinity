--- Bounded optical estimates: static balls, one transferred impact, no game mutations.
-- @author dop42
local M = OPX.Modules.Get('pool')
local R, Number = M.Model.RADIUS, M.Model.Number
local DRAG, RAIL, TRANSFER = 0.7, 0.82, 0.985
M.Prediction = {}
local P = M.Prediction
local function circle(x, y, dx, dy, cx, cy, radius)
	local rx, ry = cx-x, cy-y
	local ahead = rx*dx+ry*dy
	if ahead <= 0 then return nil end
	local side = rx*dy-ry*dx
	local square = radius*radius-side*side
	if square < 0 then return nil end
	return math.max(0, ahead-math.sqrt(square))
end
local function first(spec, points, x, y, dx, dy, limit, self, skip)
	local distance, kind, index = limit, 'stop', nil
	local function offer(t, what, which)
		if t and t >= 0 and t < distance then distance, kind, index = t, what, which end
	end
	if math.abs(dx) > 1e-8 then offer(((dx > 0 and spec.halfLength-R or -spec.halfLength+R)-x)/dx, 'x') end
	if math.abs(dy) > 1e-8 then offer(((dy > 0 and spec.halfWidth-R or -spec.halfWidth+R)-y)/dy, 'y') end
	for slot = 1, M.Model.BALLS do
		local ball = points[slot]
		if slot ~= self and slot ~= skip and ball and ball[3] then
			local t = circle(x,y,dx,dy,ball[1],ball[2],R*2)
			if t and t < distance then distance,kind,index = t,'ball',slot end
		end
	end
	for side = -1, 1, 2 do
		for column = -1, 1 do offer(circle(x,y,dx,dy,column*spec.halfLength,side*spec.halfWidth,0.065), 'pocket') end
	end
	return distance, kind, index
end
function P.End(spec, points, angle)
	local x,y,dx,dy = points[1][1],points[1][2],math.cos(angle),math.sin(angle)
	local distance = first(spec,points,x,y,dx,dy,6,1)
	return x+dx*distance,y+dy*distance,distance
end
function P.Trace(spec, points, angle, power, profile)
	local paths, contact = {}, nil
	if not profile or profile.level == 0 or not points[1] or not points[1][3] then return paths end
	angle = Number(angle, -math.pi*2, math.pi*2) or 0
	angle = math.floor(angle/profile.angleStep+0.5)*profile.angleStep
	power = Number(power, 0.02, 1) or profile.power
	power = math.max(0.02, math.min(1, math.floor(power/profile.powerStep+0.5)*profile.powerStep))
	local function walk(x, y, dx, dy, speed, bounces, self, skip, color, range, capture)
		for bounce = 0, bounces do
			local limit = math.min(range, speed*speed/(2*DRAG))
			if limit < 0.001 then return nil end
			local distance, kind, index = first(spec,points,x,y,dx,dy,limit,self,skip)
			local ex, ey = x+dx*distance, y+dy*distance
			if capture and not contact and (kind == 'ball' or kind == 'x' or kind == 'y') then contact={ex,ey} end
			if distance > 0.00001 then paths[#paths+1] = { x, y, ex, ey, color } end
			speed = math.sqrt(math.max(0, speed*speed-2*DRAG*distance))
			if kind == 'ball' then return { x=ex, y=ey, dx=dx, dy=dy, speed=speed, index=index, bounces=bounce, remaining=range-distance } end
			if kind ~= 'x' and kind ~= 'y' then return nil end
			if kind == 'x' then dx = -dx else dy = -dy end
			speed, range = speed*RAIL, range-distance
			x, y = ex+dx*0.00001, ey+dy*0.00001
		end
	end
	local ball = points[1]
	local hit = walk(ball[1],ball[2],math.cos(angle),math.sin(angle),0.2+4.3*power,
		profile.bounces,1,nil,'#ADEFFFC0',profile.distance,true)
	if hit and profile.outgoing then
		local object = points[hit.index]
		local nx, ny = object[1]-hit.x, object[2]-hit.y
		local length = math.sqrt(nx*nx+ny*ny)
		nx, ny = nx/math.max(length,1e-8), ny/math.max(length,1e-8)
		local transfer = math.max(0, hit.dx*nx+hit.dy*ny)*TRANSFER
		walk(object[1],object[2],nx,ny,hit.speed*transfer,profile.bounces,hit.index,1,'#FFD166CC',profile.distance)
		local vx, vy = hit.dx-nx*transfer, hit.dy-ny*transfer
		local speed = math.sqrt(vx*vx+vy*vy)
		if speed > 0.02 then walk(hit.x,hit.y,vx/speed,vy/speed,hit.speed*speed,
			math.max(0,profile.bounces-hit.bounces),1,hit.index,'#78DBF0B0',hit.remaining) end
	end
	return paths, contact
end
