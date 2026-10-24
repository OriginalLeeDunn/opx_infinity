--- Timestamped playback, bounded history, no extrapolation or client physics.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Number = M.Model.Number
M.Playback = {}
local B = M.Playback
function B.New() return { frames = {}, sequence = -1, epoch = -1, cursor = 0 } end
function B.Push(buffer, packet, now)
	if type(packet) ~= 'table' or not Number(packet.epoch, 0, 1e15) or packet.epoch % 1 ~= 0
		or not Number(packet.sequence, 0, 1e15) or packet.sequence % 1 ~= 0
		or not Number(packet.revision, 1, 1e9) or packet.revision % 1 ~= 0
		or not Number(packet.owner, 0, 1e9) or packet.owner % 1 ~= 0
		or not Number(packet.readyAt, 0, 1e12)
		or (packet.phase ~= 'ready' and packet.phase ~= 'rolling')
		or type(packet.frames) ~= 'table' or #packet.frames < 1 or #packet.frames > 7
		or packet.epoch < buffer.epoch or (packet.epoch == buffer.epoch and packet.sequence <= buffer.sequence) then return false end
	local game = packet.game ~= nil and M.Match.Read(packet.game) or nil
	if packet.game ~= nil and (not game or packet.owner ~= M.Match.Owner(game)) then return false end
	local previous = packet.epoch == buffer.epoch and buffer.lastTime or nil
	local frames = {}
	for _, frame in ipairs(packet.frames) do
		if type(frame) ~= 'table' or not Number(frame.time, 0, 1e12) or (previous and frame.time <= previous)
			or type(frame.balls) ~= 'table' or #frame.balls ~= M.Model.BALLS then return false end
		local clean = { time = frame.time, balls = {} }
		for index = 1, M.Model.BALLS do
			local ball = frame.balls[index]
			if type(ball) ~= 'table' or not Number(ball[1], -3, 3) or not Number(ball[2], -2, 2)
				or type(ball[3]) ~= 'boolean' then return false end
			clean.balls[index] = { ball[1], ball[2], ball[3] }
		end
		frames[#frames+1], previous = clean, frame.time
	end
	if packet.epoch ~= buffer.epoch then buffer.frames, buffer.offset, buffer.cursor = {}, nil, 0 end
	buffer.epoch, buffer.sequence, buffer.lastTime = packet.epoch, packet.sequence, previous
	buffer.offset = math.min(buffer.offset or math.huge, now - previous)
	for _, frame in ipairs(frames) do buffer.frames[#buffer.frames+1] = frame end
	while #buffer.frames > 40 do table.remove(buffer.frames, 1) end
	local assistance = Number(packet.assistance, 0, 3)
	if not assistance or assistance%1 ~= 0 then assistance = 0 end
	local aim = type(packet.aim) == 'table' and packet.aim or {}
	buffer.state = { owner = packet.owner, phase = packet.phase, revision = packet.revision,
		readyAt = packet.readyAt, game = game, assistance = assistance, angle = Number(aim.angle, -math.pi*2, math.pi*2) or 0,
		power = Number(aim.power, 0, 1) or 0, aiming = aim.visible == true }
	return true
end
function B.Sample(buffer, now)
	local frames = buffer.frames
	if #frames == 0 then return nil end
	local time = math.max(buffer.cursor, math.min(buffer.lastTime, now-buffer.offset-M.Model.DELAY))
	time = math.max(frames[1].time, time)
	buffer.cursor = time
	while #frames > 2 and frames[2].time <= time do table.remove(frames, 1) end
	local a, b = frames[1], frames[2] or frames[1]
	local ratio = b.time > a.time and math.max(0, math.min(1, (time-a.time)/(b.time-a.time))) or 0
	local result = {}
	for index = 1, M.Model.BALLS do
		local first, last = a.balls[index], b.balls[index]
		local alive = first[3]
		if ratio >= 1 then alive = last[3] end
		result[index] = { first[1]+(last[1]-first[1])*ratio, first[2]+(last[2]-first[2])*ratio, alive }
	end
	return result
end
