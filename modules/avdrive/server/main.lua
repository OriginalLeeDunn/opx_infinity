--- Server half: the autopilot itself -- one flight per pilot, posed by this file
--- and handed back at the hover.
-- @author XEROX710
--
-- THE FLIGHT IS POSED, NOT SIMULATED. `Open77.vehicles.setTransform` per tick
-- is the primitive: server-authoritative, revoking the physics lease and
-- republishing the canonical transform to every viewer, which is exactly the
-- route `modules/ncpd/server/av.lua` flies the MaxTac insertion on. There is
-- no engine task for an AV (`Open77.vehicles.ai` does not support them), so
-- the three legs below ARE the flight model: climb over where you are, cruise
-- straight to the pin, descend to a hover above it. Each leg is eased at both
-- ends so the phase boundaries read as one continuous flight rather than three
-- snaps.
--
-- FROZEN FOR THE WHOLE RUN, AND THE FREEZE IS THE RIDE. A seated player in an
-- AV is its pilot as far as the platform is concerned: their client claims the
-- hull and reports its own poses. Left alone, that client and this file would
-- be two hands on one airframe -- the fight `av.lua` documents and refuses to
-- have. `setFrozen` is the platform's own referee: while the bit is up, the
-- physics owner's transform reports are DISCARDED rather than merged ("kept,
-- not punished" in the host's own words), so the pose this file publishes is
-- the only pose there is and the pilot rides instead of wrestling. The bit
-- comes off the moment the run ends, and the platform then hands the airframe
-- to whoever is seated in it -- the same hand-over rule, in the other
-- direction.
--
-- THE SEAT READ IS THE ONLY PROOF. What a toggle claims is nothing; what a
-- body holds is `getPlayerSeat`, and the run checks it every tick. A pilot who
-- leaves the seat, an aircraft taken out of the world, a pilot who vanishes --
-- each ends the run by name, unfreezes the hull and stops posing. Nobody is
-- ever left frozen in mid-air under a controller that has stopped caring.
--
-- NOTHING HERE IS OWNED. This module creates no vehicle, writes no row and
-- moves no player. It reads the host's own seat and hull reads, poses a hull
-- somebody else created, and puts both hands back on the controls at the end.

local M = OPX.Modules.Get('avdrive')

--- The vehicle seam, resolved per call rather than captured at load: a resource
--- that starts before the vehicles API exists must still say WHY nothing flew
--- rather than failing at load.
local function vehicles()
	return Open77 and Open77.vehicles or nil
end

--- Live runs, by the pilot who asked for one. One per pilot -- the key is a
--- toggle, and a second press is always the OFF half of it.
local runs = {}

local PHASE = {
	CLIMB = 'climb',
	CRUISE = 'cruise',
	DESCEND = 'descend',
}

-- How far a destination may be from the world's centre on each axis, and the
-- band a destination's height may sit in. A payload off the wire is a claim,
-- and a claim is checked before it becomes a flight plan: NaN and the two
-- infinities are finite-check failures, and a pin beyond the world is a pin
-- nobody placed.
local MAX_COORDINATE = 20000.0
local MIN_ALTITUDE = -500.0
local MAX_ALTITUDE = 3000.0

-- How long one toggle may follow another, in milliseconds. Read per press
-- rather than captured at load, like every other knob here: `0` is "no
-- window", which is the shape both an operator's "stop rate-limiting me" and
-- the tests' own rapid toggles want.
local function cooldownMs()
	local config = M.Settings
	local value = type(config) == 'table' and tonumber(config.COOLDOWN_MS) or nil
	if value == nil or value ~= value or value < 0 then return 400 end
	return value
end

local function lerp(a, b, t) return a + (b - a) * t end

--- Ease-in-out, so a leg starts and ends at rest. A linear lerp snaps the
--- airframe through every phase boundary, which reads as a stutter per phase.
local function smooth(t) return t * t * (3.0 - 2.0 * t) end

--- The constant heading of a run: from where it started to where it is going,
--- in the game's degrees -- 0 faces +Y and it grows counter-clockwise, so +X is
--- 270 (`docs/camera.md`). The airframe turns toward its destination as it
--- climbs and holds that heading for the whole flight, which is what a pilot
--- would do with one pin to fly to. This used to be the math angle
--- (`atan(dy, dx)`, 0 = +X), 90 degrees off: the aircraft flew to the pin
--- side-on.
local function headingTo(from, to)
	local dx = to.x - from.x
	local dy = to.y - from.y
	if dx == 0.0 and dy == 0.0 then return 0.0 end
	return math.deg(math.atan(-dx, dy)) % 360.0
end

--- A heading `t` of the way from one to another, the short way round.
local function turn(from, to, t)
	if t >= 1.0 then return to % 360.0 end
	local delta = ((to - from + 540.0) % 360.0) - 180.0
	return (from + delta * t) % 360.0
end

--- The flight the config names, read fresh for every run. Invalid numbers read
--- as their defaults rather than as a refusal -- `M.Init` says each one out
--- loud at boot, and a pilot who mistyped a config should not find out by the
--- key going dead -- but a config that switched the module off is a refusal,
--- and named as one.
-- @return table|nil
local function plan()
	local config = M.Settings
	if type(config) ~= 'table' or config.enabled == false then return nil end
	local function positive(name, fallback)
		local value = tonumber(config[name])
		if value == nil or value ~= value or value <= 0 then return fallback end
		return value
	end
	local function nonNegative(name, fallback)
		local value = tonumber(config[name])
		if value == nil or value ~= value or value < 0 then return fallback end
		return value
	end
	return {
		cruiseAltitude = positive('CRUISE_ALTITUDE', 120.0),
		cruiseSpeed = positive('CRUISE_SPEED', 22.0),
		climbSpeed = positive('CLIMB_SPEED', 5.0),
		descendSpeed = positive('DESCEND_SPEED', 3.5),
		hoverHeight = nonNegative('HOVER_HEIGHT', 8.0),
		tickMs = math.floor(positive('TICK_MS', 100.0)),
		maxRange = positive('MAX_RANGE', 4000.0),
		maxSeconds = positive('MAX_MINUTES', 20.0) * 60.0,
	}
end

--- A hull's canonical position as the server reads it, or nil. The two shapes
--- are the host's own: the canonical snapshot is flat, and a fixture may nest
--- the same three numbers under `position` -- the garages exits read both the
--- same way, and a second rule for the same fact would be a second answer.
-- @param hull table
-- @return table|nil `{ x, y, z }`
local function at(hull)
	if type(hull) ~= 'table' then return nil end
	local where = type(hull.position) == 'table' and hull.position or hull
	local x, y, z = tonumber(where.x), tonumber(where.y), tonumber(where.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

--- A destination off the wire, checked before it is believed. Finite, inside
--- the world's own bounds, and in the height band an aircraft flies in.
-- @param value any
-- @return table|nil `{ x, y, z }`
local function destination(value)
	if type(value) ~= 'table' then return nil end
	local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
	if x == nil or y == nil or z == nil then return nil end
	if x ~= x or y ~= y or z ~= z then return nil end
	if math.abs(x) > MAX_COORDINATE or math.abs(y) > MAX_COORDINATE then return nil end
	if z < MIN_ALTITUDE or z > MAX_ALTITUDE then return nil end
	return { x = x, y = y, z = z }
end

--- The pose of a leg at `u` in [0, 1]. Each leg moves one thing at a time --
--- height, then ground, then height -- which is the shape of a circuit and
--- keeps the cruise leg level for the whole of its length.
local function pose(run, phase, u)
	local eased = smooth(u)
	if phase == PHASE.CLIMB then
		return { x = run.from.x, y = run.from.y,
			z = lerp(run.from.z, run.cruiseZ, eased) }
	end
	if phase == PHASE.CRUISE then
		return { x = lerp(run.from.x, run.to.x, eased),
			y = lerp(run.from.y, run.to.y, eased), z = run.cruiseZ }
	end
	-- DESCEND
	return { x = run.to.x, y = run.to.y, z = lerp(run.cruiseZ, run.releaseZ, eased) }
end

--- Ends a run: the posing stops, the freeze comes off, and the reason goes in
--- the log with the notice the pilot reads. Idempotent -- a run already ended
--- is a run that unfreezes nothing a second time.
-- @param run table
-- @param why string named reason, for the log line
-- @param notice string|nil a catalogue key to tell the pilot with
-- @param kind string|nil toast kind
local function finish(run, why, notice, kind)
	if runs[run.playerId] ~= run then return end
	runs[run.playerId] = nil
	if run.handle ~= nil then
		OPX.Scheduler.Cancel(run.handle)
		run.handle = nil
	end
	-- THE HAND-OVER, IN THE OTHER DIRECTION. The bit comes off before the
	-- notice: a pilot told "you have the controls" while the hull is still
	-- frozen has been told a lie for as long as the packet takes.
	local contract = vehicles()
	if contract ~= nil and type(contract.setFrozen) == 'function' then
		contract.setFrozen(run.hullId, false)
	end
	Open77.log.info(('[avdrive] autopilot for %d off after %.1fs (%s): %s')
		:format(run.playerId, run.clock, run.legPhase or PHASE.CLIMB, why))
	if notice ~= nil then
		OPX.NotifyLocale(run.playerId, notice, nil, kind or 'info')
	end
end

--- One tick. THE SEAT IS RE-READ EVERY ONE OF THEM: a body that left the
--- controls is a run that must not keep flying an aircraft they are no longer
--- in, and the read is the platform's own, never the client's word.
-- @param playerId number
local function step(playerId)
	local run = runs[playerId]
	if run == nil then return end

	local contract = vehicles()
	if contract == nil or type(contract.get) ~= 'function' then
		return finish(run, 'the vehicle contract went away', 'avdrive.cancelled')
	end
	if contract.get(run.hullId) == nil then
		return finish(run, 'the airframe was taken away', 'avdrive.cancelled')
	end
	local seated = type(contract.getPlayerSeat) == 'function'
		and contract.getPlayerSeat(playerId) or nil
	if type(seated) ~= 'table' or tostring(seated.vehicleId) ~= tostring(run.hullId) then
		return finish(run, 'the pilot left the controls', 'avdrive.pilotLeft')
	end

	run.clock = run.clock + run.plan.tickMs / 1000.0
	if run.clock > run.plan.maxSeconds then
		return finish(run, 'the flight took its ceiling', 'avdrive.timeout')
	end

	local leg = run.legs[run.leg]
	run.legClock = run.legClock + run.plan.tickMs / 1000.0
	local u = leg.seconds > 0.0 and math.min(1.0, run.legClock / leg.seconds) or 1.0
	local to = pose(run, leg.phase, u)
	-- `yaw` is passed every tick on purpose: the platform's `setTransform`
	-- reads an absent heading as 0, not as "keep the current one".
	-- The turn toward the pin is made on the climb, from the heading the hull
	-- stood at, so it never snaps round on the first pose.
	local yaw = leg.phase == PHASE.CLIMB and turn(run.fromYaw, run.heading, smooth(u)) or run.heading
	local moved, reason = contract.setTransform(run.hullId,
		{ x = to.x, y = to.y, z = to.z, yaw = yaw })
	if moved ~= true then
		run.refused = run.refused + 1
		if run.refused == 1 then
			Open77.log.warn(('[avdrive] the aircraft of %d refused a pose: %s')
				:format(playerId, tostring(reason)))
		end
	end

	if u < 1.0 then return end
	run.legPhase = leg.phase
	if run.leg < #run.legs then
		run.leg = run.leg + 1
		run.legClock = 0.0
		return
	end
	finish(run, 'the waypoint was reached', 'avdrive.arrived', 'success')
end

--- Engages the autopilot on the hull the pilot is seated in, flying to the
--- destination named. Every refusal is a toast that says WHICH door said no.
-- @param src number
-- @param payload table|nil `{ position, unreadable }`
local function engage(src, payload)
	local settings = plan()
	local contract = vehicles()
	if settings == nil or contract == nil or type(contract.get) ~= 'function'
		or type(contract.setTransform) ~= 'function'
		or type(contract.getPlayerSeat) ~= 'function' then
		OPX.Refuse(src, 'avdrive.unavailable', M.Operation.ENGAGE)
		return OPX.NotifyLocale(src, 'avdrive.unavailable', nil, 'error')
	end

	-- THE SEAT, THE HULL AND THE RECORD, all from the host and none from the
	-- wire: a client that names an aircraft is not a client sitting in one.
	local seated = contract.getPlayerSeat(src)
	if type(seated) ~= 'table' or seated.vehicleId == nil then
		OPX.Refuse(src, 'avdrive.notSeated', M.Operation.ENGAGE)
		return OPX.NotifyLocale(src, 'avdrive.notSeated', nil, 'error')
	end
	local hullId = seated.vehicleId
	local hull = contract.get(hullId)
	if type(hull) ~= 'table' then
		OPX.Refuse(src, 'avdrive.noAircraft', M.Operation.ENGAGE)
		return OPX.NotifyLocale(src, 'avdrive.noAircraft', nil, 'error')
	end
	if not OPX.Vehicle.IsAvRecord(hull.record) then
		OPX.Refuse(src, 'avdrive.notAv', M.Operation.ENGAGE)
		return OPX.NotifyLocale(src, 'avdrive.notAv', nil, 'error')
	end
	-- ONE PILOT PER AIRFRAME. Two runs on one hull would be two controllers
	-- posing the same body at the same cadence -- the exact fight the freeze
	-- exists to prevent, this time between two copies of ourselves.
	for _, other in pairs(runs) do
		if tostring(other.hullId) == tostring(hullId) then
			OPX.Refuse(src, 'avdrive.busy', M.Operation.ENGAGE)
			return OPX.NotifyLocale(src, 'avdrive.busy', nil, 'error')
		end
	end
	-- THE CONTROLS ARE ONE SEAT. Being aboard is not flying: a passenger the
	-- crew door seated in the back is in the same hull, and without this read
	-- could freeze the pilot's aircraft and fly it to a pin of their own.
	if seated.seat ~= 'seat_front_left' then
		OPX.Refuse(src, 'avdrive.notPilot', M.Operation.ENGAGE)
		return OPX.NotifyLocale(src, 'avdrive.notPilot', nil, 'error')
	end

	-- THE DESTINATION IS THE ONLY THING THE PAYLOAD MAY SAY. A waypoint the
	-- map could not be read for is a refusal that names the map, because "no
	-- waypoint" and "the map would not answer" are different things to fix.
	local to = nil
	if type(payload) == 'table' then to = destination(payload.position) end
	if to == nil then
		local unreadable = type(payload) == 'table' and payload.unreadable == true
		local key = unreadable and 'avdrive.waypointUnavailable' or 'avdrive.noWaypoint'
		OPX.Refuse(src, key, M.Operation.ENGAGE)
		return OPX.NotifyLocale(src, key, nil, 'error')
	end

	local from = at(hull)
	if from == nil then
		OPX.Refuse(src, 'avdrive.noAircraft', M.Operation.ENGAGE)
		return OPX.NotifyLocale(src, 'avdrive.noAircraft', nil, 'error')
	end
	local dx, dy = to.x - from.x, to.y - from.y
	if math.sqrt(dx * dx + dy * dy) > settings.maxRange then
		OPX.Refuse(src, 'avdrive.tooFar', M.Operation.ENGAGE)
		return OPX.NotifyLocale(src, 'avdrive.tooFar', nil, 'error')
	end

	-- THE GEOMETRY, AND IT IS ALL ARITHMETIC BEFORE ANYTHING MOVES. The cruise
	-- altitude is measured from the HIGHER of the two ends, so a pin in a
	-- valley and a take-off on a roof cannot put the cruise leg under either;
	-- the release height is clamped below the cruise leg so a config that
	-- hovers higher than it cruises is a zero-length descent and not a climb
	-- that calls itself a descent.
	local cruiseZ = math.max(from.z, to.z) + settings.cruiseAltitude
	local releaseZ = math.min(to.z + settings.hoverHeight, cruiseZ)
	local run = {
		playerId = src,
		hullId = hullId,
		plan = settings,
		from = from,
		to = to,
		cruiseZ = cruiseZ,
		releaseZ = releaseZ,
		heading = headingTo(from, to),
		-- The heading the hull stands at now, which the climb turns from; the
		-- run's own when the snapshot carries none.
		fromYaw = nil,
		leg = 1,
		legClock = 0.0,
		legPhase = nil,
		clock = 0.0,
		refused = 0,
		handle = nil,
		legs = {
			{ phase = PHASE.CLIMB,
				seconds = math.max(0.0, cruiseZ - from.z) / settings.climbSpeed },
			{ phase = PHASE.CRUISE,
				seconds = math.sqrt(dx * dx + dy * dy) / settings.cruiseSpeed },
			{ phase = PHASE.DESCEND,
				seconds = math.max(0.0, cruiseZ - releaseZ) / settings.descendSpeed },
		},
	}

	local standing = tonumber(hull.yaw or hull.heading)
	if standing ~= nil and standing == standing and math.abs(standing) ~= math.huge then
		run.fromYaw = standing % 360.0
	else
		run.fromYaw = run.heading
	end

	-- FROZEN BEFORE THE FIRST POSE, and the order is the whole of the
	-- hand-over: the pilot's client claims the hull the moment it sees the
	-- seat, and a claim accepted before the freeze is a claim whose reports
	-- are merged for as long as the gap lasts.
	if type(contract.setFrozen) == 'function' then contract.setFrozen(hullId, true) end
	runs[src] = run
	run.handle = OPX.Scheduler.Every(('avdrive.%d'):format(src), settings.tickMs, function()
		step(src)
	end)

	Open77.log.info(('[avdrive] autopilot for %d: %s to %.0f,%.0f at %.0fm cruise, ' ..
		'%.0fm range, %.1fs of legs')
		:format(src, tostring(hullId), to.x, to.y, cruiseZ - from.z,
			math.sqrt(dx * dx + dy * dy),
			run.legs[1].seconds + run.legs[2].seconds + run.legs[3].seconds))
	OPX.NotifyLocale(src, 'avdrive.engaged', nil, 'success')
end

--- The one press off the wire. A run in flight is the OFF half of the toggle,
--- wherever the aircraft happens to be; anything else is an ask to engage.
-- @param payload table|nil
local function onToggle(payload)
	local src = tonumber(source)
	if src == nil then return end
	local everyMs = cooldownMs()
	if everyMs > 0 and OPX.Cooling(src, 'avdrive.toggle', everyMs) then
		return OPX.NotifyLocale(src, 'avdrive.rateLimited', nil, 'error')
	end

	local run = runs[src]
	if run ~= nil then
		finish(run, 'the pilot took the controls', 'avdrive.cancelled')
		return
	end
	engage(src, payload)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state. Nothing is captured from config here: the flight plan is
--- read per run, so a live edit and the tests' own numbers are the numbers
--- that fly.
-- @author XEROX710
function M.Init()
	runs = {}
	-- THE BOOT JOURNAL SAYS EACH BAD NUMBER BY NAME. The reader above falls
	-- back to the default for one, and an operator who mistyped a knob must
	-- not learn it by the aircraft flying at the wrong speed.
	local config = M.Settings
	if type(config) ~= 'table' then return end
	local function warn(name, line)
		local value = tonumber(config[name])
		if value == nil or value ~= value or value < 0 then
			Open77.log.warn(('[avdrive] config: %s %s'):format(name, line))
		end
	end
	warn('CRUISE_ALTITUDE', 'is not a height')
	warn('CRUISE_SPEED', 'is not a speed')
	warn('CLIMB_SPEED', 'is not a rate')
	warn('DESCEND_SPEED', 'is not a rate')
	warn('HOVER_HEIGHT', 'is not a height')
	warn('MAX_RANGE', 'is not a distance')
	warn('MAX_MINUTES', 'is not a duration')
	warn('TICK_MS', 'is not a cadence')
	warn('COOLDOWN_MS', 'is not a window')
	if type(config.KEY) ~= 'table' or type(config.KEY.ID) ~= 'string'
		or type(config.KEY.NAME) ~= 'string' then
		Open77.log.warn('[avdrive] config: KEY is not a table of ID, NAME and DEFAULT')
	end
end

--- Wires the one door.
-- @author XEROX710
function M.Start()
	RegisterNetEvent(M.Event.TOGGLE, onToggle)

	-- A pilot who vanishes mid-flight leaves an aircraft frozen under a run
	-- nobody will ever press a key for again. The disconnect is a seat left,
	-- by the only name that matters.
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local run = runs[tonumber(playerId) or playerId]
		if run ~= nil then finish(run, 'the pilot disconnected', nil) end
	end)
end

--- Takes every flight down. A resource restart must not leave an aircraft
--- frozen at altitude with nobody left to unfreeze it.
-- @author XEROX710
function M.Stop()
	local list = {}
	for _, run in pairs(runs) do list[#list + 1] = run end
	for index = 1, #list do
		finish(list[index], 'the module stopped', 'avdrive.cancelled')
	end
end
