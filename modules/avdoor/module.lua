--- The AV door: board a parked aircraft you may fly, step out of it cleanly,
--- and hear a MaxTac AV that a player flies.
-- @author XEROX710
--
-- THE BASE GAME HAS NO WAY INTO AN AIRCRAFT. V boards an AV in a scene, never
-- through an interaction, so a hull that is standing on a pad or a rooftop has
-- no "enter" choice on it at all -- which is why every AV in this resource used
-- to be boarded exactly once: by the pad's hand-off the moment it was recalled
-- (`modules/garages`), or through the MaxTac crew door during the insertion's
-- twenty-second hold (`modules/ncpd/server/av.lua`). This module is the door
-- the aircraft never had, for all of them.
--
-- THE SERVER FINDS AND DECIDES. Only the server holds a vehicle's world
-- coordinates -- a client snapshot deliberately carries none
-- (`wiki/vehicles.md`, "Client snapshot fields") -- so the server measures
-- every player on foot against every aircraft in their bucket, judges the
-- nearest one in reach from its own reads (the hull's canonical transform, the
-- asker's position, bucket, seat and life, the vehicles module's owner and job
-- books, and any rule another module registered for the hull through `Allow`),
-- and tells that client which door is open to it. The row is drawn from that
-- word alone, and the press is judged again from scratch before
-- `warpPlayerIntoVehicle` is called: the row is a hint, never a permission.
--
-- NOTHING HERE OWNS A VEHICLE. No hull is created, stored or removed by this
-- module; it reads other modules' books and seats a player through the
-- platform's own mount.

local M = OPX.Modules.Declare{
	id = 'avdoor',
	side = 'both',
	fatal = false,
	-- Nothing is required: without the character contract nobody can prove who
	-- they are and every ask is refused by name, and without the vehicles books
	-- only hulls another module registered have a door. `prompts` is the strip
	-- the row lives on; without it the key still boards.
	requires = {},
	optional = { 'character', 'vehicles', 'prompts' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Server to client, to that client alone: the aircraft door open to this
	-- player right now -- `{ open = true, id, role }` -- or `{ open = false }`.
	-- Sent when it changes, never per scan.
	DOOR = OPX.Event(NET, 'avdoor', 'door'),
	-- Client to server: the key, on a hull whose row is up. Checked again in
	-- full; the payload names the hull and nothing more.
	BOARD = OPX.Event(NET, 'avdoor', 'board'),
	-- Server to client, to the asker alone: what the press came to.
	BOARDED = OPX.Event(NET, 'avdoor', 'boarded'),
	-- Client to server, from the pilot's own client: the flight just did one of
	-- the three things the MaxTac AV has a voice for. Relayed only when the
	-- asker is seated in that hull.
	SOUND = OPX.Event(NET, 'avdoor', 'sound'),
	-- Server to client, to every listener within range of the hull, the pilot
	-- included: `{ id, event, which, duration, token }` -- play this event on
	-- the hull.
	PLAY = OPX.Event(NET, 'avdoor', 'play'),
	-- Client to server, from a listener: what its client did with a `PLAY`
	-- (`{ token, ok, how, streamed, reason }`). It carries no authority -- the
	-- token names a sound that listener was sent, and it is answered once --
	-- and exists because a sound that fails on somebody else's machine leaves
	-- no line in the server's log and none in the pilot's. A refusal by the
	-- host is rescued through the platform's own fan-out (`SOUNDS.RESCUE`).
	PLAYED = OPX.Event(NET, 'avdoor', 'played'),
	-- Client to server, from any client: an aircraft this client does not
	-- simulate is drawn far from where the server's last sample put it (`WATCH`),
	-- or has come back. `{ id, state = 'open'|'still'|'closed', drawn, sampled,
	-- metres, worst, seconds, owner, epoch, frozen, speed, seated }`. It carries
	-- no authority: the server journals it beside its own reads, and at most
	-- re-publishes an EMPTY hull where the server already has it.
	SIGHT = OPX.Event(NET, 'avdoor', 'sight'),
	-- Server to client, to every player near a hull the server flies:
	-- `{ id, on, record, platform }` -- draw the landing pad under this hull
	-- (`on = true`), or stop (`on = false`). `platform` is a hull the client
	-- pads itself, which is only measured (`server/pad.lua`).
	PAD = OPX.Event(NET, 'avdoor', 'pad'),
	-- Server to client, to every player in a calling hull's bucket within
	-- `CALLOUTS.MAX_METRES` (`CALLOUTS.TRANSPORT = 'local'`):
	-- `{ id, kind, on = true, at, elapsedMs, volume, near, far }` -- play this
	-- kind's landing call on the hull, in this game's own language, from where
	-- the loop has reached -- or `{ id, on = false, fadeMs }`, end it.
	CALL = OPX.Event(NET, 'avdoor', 'call'),
	-- The client's own bus: every verdict, local refusals included.
	ON_DECISION = OPX.Event(LOCAL, 'avdoor', 'decision'),
}

--- The console command that explains the door nearest to the caller.
M.Command = { WHY = 'opx.avdoor.why' }

--- The three moments of a flight the MaxTac AV has a voice for, and the config
--- field each one is read from.
M.SOUNDS = { takeoff = 'TAKEOFF', descent = 'DESCENT', touchdown = 'TOUCHDOWN' }

--- Every moment a pilot's client may report. `abort` has no sound of its own:
--- a hull that climbed back out of its descent ends its landing call
--- (`CALLOUTS`), and that is all it does.
M.MOMENTS = { takeoff = true, descent = true, touchdown = true, abort = true }

--- The landing call a record makes (`CALLOUTS.KINDS`), or nil.
-- Kinds are tried by name, in order, so a record two kinds match always makes
-- the same call.
-- @param record any
-- @param block table|nil the CALLOUTS block; `M.Settings.CALLOUTS` when nil
-- @return string|nil kind
-- @return table|nil that kind's block
function M.CalloutKind(record, block)
	if block == nil then block = type(M.Settings) == 'table' and M.Settings.CALLOUTS or nil end
	if type(block) ~= 'table' or type(block.KINDS) ~= 'table' then return nil end
	if type(record) ~= 'string' or record == '' then return nil end
	local names = {}
	for name in pairs(block.KINDS) do
		if type(name) == 'string' then names[#names + 1] = name end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local kind = block.KINDS[name]
		if type(kind) == 'table' and M.IsAircraft(record, kind.RECORDS) then return name, kind end
	end
	return nil
end

--- Every refusal the door can name, as the sentence a player reads.
M.Refusal = {
	no_character = 'avdoor.refused.noCharacter',
	no_aircraft = 'avdoor.refused.noAircraft',
	not_aircraft = 'avdoor.refused.noAircraft',
	wrecked = 'avdoor.refused.wrecked',
	seated = 'avdoor.refused.seated',
	down = 'avdoor.refused.down',
	no_position = 'avdoor.refused.noPosition',
	too_far = 'avdoor.refused.tooFar',
	moving = 'avdoor.refused.moving',
	not_yours = 'avdoor.refused.notYours',
	not_crew = 'avdoor.refused.notCrew',
	no_seat = 'avdoor.refused.noSeat',
	busy = 'avdoor.refused.busy',
	seat_refused = 'avdoor.refused.failed',
}

--- Whether a record names an aircraft this module draws a door on.
-- @param record any
-- @param patterns table|nil Lua patterns; `M.Settings.RECORDS` when nil
-- @return boolean
function M.IsAircraft(record, patterns)
	if type(record) ~= 'string' or record == '' then return false end
	local list = patterns
	if list == nil then
		list = type(M.Settings) == 'table' and M.Settings.RECORDS or nil
	end
	if type(list) ~= 'table' then return false end
	local lowered = record:lower()
	for _, pattern in ipairs(list) do
		if type(pattern) == 'string' and pattern ~= '' then
			local read, found = pcall(string.find, lowered, pattern:lower())
			if read and found ~= nil then return true end
		end
	end
	return false
end

--- A number from config, finite and inside a band, or the fallback.
-- @param value any
-- @param low number
-- @param high number
-- @param fallback number
-- @return number
function M.Number(value, low, high, fallback)
	local number = tonumber(value)
	if number == nil or number ~= number or number < low or number > high then return fallback end
	return number
end

--- The seats a role may take, in the order they are filled.
-- @param role string `pilot` or `passenger`
-- @return string[]
function M.SeatsFor(role)
	local declared = type(M.Settings) == 'table' and M.Settings.SEATS or nil
	local seats = {}
	for _, seat in ipairs(type(declared) == 'table' and declared or {}) do
		if type(seat) == 'string' and seat:match('^seat_[%a_]+$') then
			if role ~= 'passenger' or seat ~= 'seat_front_left' then seats[#seats + 1] = seat end
		end
	end
	if #seats == 0 then
		seats = role == 'passenger'
			and { 'seat_front_right', 'seat_back_left', 'seat_back_right' }
			or { 'seat_front_left', 'seat_front_right', 'seat_back_left', 'seat_back_right' }
	end
	return seats
end

-- ── the seat's door and the exit's geometry ──────────────────────────────────
--
-- Everything below is shared because both halves read the same settings and the
-- suite has to be able to call the geometry without a running game.

--- The canonical seat name of a ledger entry: the platform's own names, or the
--- FiveM numbers a seat is sometimes spelt as.
-- @param seat any
-- @return string|nil
function M.SeatName(seat)
	if type(seat) == 'string' and seat ~= '' then return seat end
	local number = tonumber(seat)
	if number == -1 then return 'seat_front_left' end
	if number == 0 then return 'seat_front_right' end
	if number == 1 then return 'seat_back_left' end
	if number == 2 then return 'seat_back_right' end
	return nil
end

--- The doors the platform names. A name outside this set is never sent to it.
M.DOOR_NAMES = { frontLeft = true, frontRight = true, backLeft = true, backRight = true }

--- The seat the flight controls are at: the one a PILOT's exit is ejected from
--- by the platform's flight code, and the one a passenger is never offered.
M.PILOT_SEAT = 'seat_front_left'

--- The door of the hull a seat uses, or nil when the seat has none.
-- @param seat any a seat name, `seat_front_left` and so on
-- @return string|nil the platform's door name
function M.DoorOf(seat)
	local declared = type(M.Settings) == 'table' and M.Settings.DOORS or nil
	if type(declared) ~= 'table' or type(seat) ~= 'string' then return nil end
	local door = declared[seat]
	if type(door) == 'string' and M.DOOR_NAMES[door] == true then return door end
	return nil
end

--- The boarding settings, each one inside a band.
-- @return table `{ delay, hold }` in milliseconds
function M.BoardSettings()
	local block = type(M.Settings) == 'table' and M.Settings.BOARD or nil
	if type(block) ~= 'table' then block = {} end
	return {
		delay = math.floor(M.Number(block.DELAY_MS, 0, 5000, 450)),
		hold = math.floor(M.Number(block.HOLD_MS, 0, 60000, 1500)),
		settle = math.floor(M.Number(block.SETTLE_MS, 0, 15000, 2500)),
	}
end

--- The exit settings, each one inside a band; a missing or malformed block is
--- the defaults, and `EXIT = false` is no guard and no door at all.
-- @return table
function M.ExitSettings()
	-- NOT `x and x.EXIT or nil`: an `EXIT = false` is the answer, and `false or
	-- nil` would throw it away.
	local declared = nil
	if type(M.Settings) == 'table' then declared = M.Settings.EXIT end
	local off = declared == false
	local block = type(declared) == 'table' and declared or {}
	return {
		off = off,
		place = not off and block.PLACE ~= false,
		side = M.Number(block.SIDE_METRES, 1.0, 20.0, 6.0),
		forward = M.Number(block.FORWARD_METRES, -20.0, 20.0, 1.5),
		lift = M.Number(block.LIFT_METRES, 0.0, 3.0, 0.25),
		air = M.Number(block.MAX_AIR_METRES, 0.5, 50.0, 4.0),
		near = M.Number(block.NEAR_METRES, 2.0, 200.0, 14.0),
		guard = math.floor(M.Number(block.GUARD_MS, 200, 15000, 2800)),
		jump = M.Number(block.JUMP_METRES, 0.5, 30.0, 2.5),
		danger = M.Number(block.DANGER_METRES, 0.0, 20.0, 3.2),
		settle = math.floor(M.Number(block.SETTLE_MS, 0, 5000, 350)),
		doorHold = math.floor(M.Number(block.DOOR_HOLD_MS, 500, 120000, 6000)),
		reassertEvery = math.floor(M.Number(block.DOOR_REASSERT_MS, 100, 5000, 400)),
		reassertFor = math.floor(M.Number(block.DOOR_REASSERT_FOR_MS, 0, 30000, 3200)),
	}
end

--- The watch settings (`WATCH`), each one inside a band; a missing or malformed
--- block is the defaults, and `WATCH = false` is no watch at all.
-- @return table
function M.WatchSettings()
	local declared = nil
	if type(M.Settings) == 'table' then declared = M.Settings.WATCH end
	local block = type(declared) == 'table' and declared or {}
	return {
		off = declared == false,
		sight = math.floor(M.Number(block.SIGHT_MS, 100, 10000, 500)),
		range = M.Number(block.RANGE, 10.0, 1000.0, 350.0),
		hulls = math.floor(M.Number(block.MAX_HULLS, 1, 16, 3)),
		drift = M.Number(block.DRIFT_METRES, 1.0, 500.0, 10.0),
		perSpeed = M.Number(block.DRIFT_PER_SPEED, 0.0, 5.0, 0.4),
		settle = M.Number(block.SETTLE_METRES, 0.5, 100.0, 4.0),
		repeatMs = math.floor(M.Number(block.REPEAT_MS, 500, 600000, 5000)),
		jump = M.Number(block.JUMP_METRES, 5.0, 5000.0, 45.0),
		heal = declared ~= false and block.HEAL ~= false,
		healEvery = math.floor(M.Number(block.HEAL_EVERY_MS, 1000, 600000, 10000)),
	}
end

--- The drift at which a hull moving at `speed` m/s counts as drawn elsewhere.
-- An observer draws a moving hull a jitter buffer (75 to 180 ms, plus up to
-- 180 ms of prediction) behind its newest sample, so a fast hull is always
-- some metres from it; that much is not a drift.
-- @param watch table `M.WatchSettings()`
-- @param speed number|nil
-- @return number metres
function M.DriftLimit(watch, speed)
	local moving = tonumber(speed)
	if moving == nil or moving ~= moving or moving < 0 then moving = 0.0 end
	if moving > 200.0 then moving = 200.0 end
	return watch.drift + watch.perSpeed * moving
end

--- Which side of the hull a seat's door is on: `1` for the left, `-1` for the
--- right. The pilot's seat is the left one.
-- @param seat any
-- @return integer
function M.SeatSide(seat)
	if type(seat) == 'string' and seat:find('right', 1, true) ~= nil then return -1 end
	return 1
end

--- Where on the map a body that stepped out of a seat is put. The first
--- attempt is beside that seat's door: `SIDE_METRES` out from the hull's centre
--- and `FORWARD_METRES` toward the nose. The others are the places to try when
--- that one has no ground under it (a hull parked at the edge of a roof): the
--- other side, then behind the hull, then ahead of it. The height is a separate
--- question (`M.ExitLevel`) because the ground has to be measured at THIS point.
-- @param centre table `{ x, y }` the hull's centre
-- @param forward table `{ x, y }` the way the hull faces (any length but zero)
-- @param seat any the seat that was left
-- @param settings table `M.ExitSettings()`
-- @param attempt integer|nil 1 (the default) to `M.EXIT_ATTEMPTS`
-- @return number|nil x
-- @return number y
function M.ExitPoint(centre, forward, seat, settings, attempt)
	if type(centre) ~= 'table' or type(forward) ~= 'table' then return nil end
	local cx, cy = tonumber(centre.x), tonumber(centre.y)
	local fx, fy = tonumber(forward.x), tonumber(forward.y)
	if cx == nil or cy == nil or fx == nil or fy == nil then return nil end
	if cx ~= cx or cy ~= cy or fx ~= fx or fy ~= fy then return nil end
	local length = math.sqrt(fx * fx + fy * fy)
	if length < 1e-6 then return nil end
	fx, fy = fx / length, fy / length
	-- The left of a heading, in the game's own axes (x east, y north): facing
	-- north (0, 1) the left is west (-1, 0).
	local lx, ly = -fy, fx
	local which = math.floor(tonumber(attempt) or 1)
	local side, along = 0.0, 0.0
	if which == 1 then
		side, along = M.SeatSide(seat) * settings.side, settings.forward
	elseif which == 2 then
		side, along = -M.SeatSide(seat) * settings.side, settings.forward
	elseif which == 3 then
		side, along = 0.0, -settings.side
	else
		side, along = 0.0, settings.side
	end
	return cx + lx * side + fx * along, cy + ly * side + fy * along
end

--- How many places `M.ExitPoint` offers.
M.EXIT_ATTEMPTS = 4

--- The height a stepped-out body is put at, and whether the hull is in the air.
-- @param hullZ number the hull's centre
-- @param ground number|nil the static ground under the exit point
-- @param settings table `M.ExitSettings()`
-- @return number z
-- @return boolean airborne
-- @return number|nil height the hull's centre over that ground, when known
function M.ExitLevel(hullZ, ground, settings)
	hullZ = tonumber(hullZ) or 0.0
	ground = tonumber(ground)
	if ground ~= nil and ground == ground then
		local height = hullZ - ground
		if height > settings.air then return hullZ - 0.8, true, height end
		return ground + settings.lift, false, height
	end
	-- No ground under the point: a hull at rest has its centre a metre or two
	-- over it (the platform's own eject reckons two), so the body goes a little
	-- under the centre and the mover settles it the rest of the way.
	return hullZ - 1.6 + settings.lift, false, nil
end

--- A platform id as the decimal string its typed targets take, or nil.
-- The 64-bit ids the host issues survive a Lua number only up to 2^53, and are
-- spelt as decimal strings for that reason; a number that is a whole is
-- formatted rather than concatenated, which would print a float as `1.0`.
-- @param id any
-- @return string|nil
function M.DecimalId(id)
	if type(id) == 'number' then
		if id ~= id or id < 0 or id ~= math.floor(id) or id >= 2 ^ 63 then return nil end
		return ('%d'):format(id)
	end
	if type(id) ~= 'string' then return nil end
	if id:match('^%d+$') then return id end
	local hex = id:match('^0[xX](%x+)$')
	if hex ~= nil and (#hex < 16 or (#hex == 16 and tonumber(hex:sub(1, 1), 16) < 8)) then
		return ('%d'):format(tonumber(hex, 16))
	end
	return nil
end
