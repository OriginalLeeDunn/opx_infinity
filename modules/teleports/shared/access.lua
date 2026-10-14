--- Config reads, coercions and the two decisions both halves share.
-- @author dop42
--
-- EVERYTHING IN THIS FILE IS A PURE FUNCTION OF ITS ARGUMENTS AND THE CONFIG
-- READ AT LOAD. There is no clock here, no host call and no network handler, so
-- every branch of every refusal is reachable from a test with no world -- which
-- is the whole reason the destination lookup and the job gate live here rather
-- than inline in the server half, where they would only ever be exercised
-- through a net event.
--
-- A TELEPORT IS A POINT WITH TWO ENDS; AN ENTRANCE IS ONE END OF ONE. The
-- config is written as points, because that is how an operator thinks about a
-- shortcut, and everything downstream wants ENTRANCES -- a marker is drawn per
-- entrance, a row is posted per entrance, a request names one. `Entrances`
-- below is the one place that turns the first into the second, so a two-way
-- point cannot end up with a marker at one end and a gate at the other.
--
-- Every value is coerced and never trusted: a coordinate that is a string, a
-- NaN or an unknown bucket reads as a warning at boot rather than a raise inside
-- a scan or a network handler. A point whose shape is broken is DROPPED, not
-- repaired -- a teleport with half a destination is a hole in the world.

local M = OPX.Modules.Get('teleports')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a yaw, a price and a millisecond
-- clock are all measured with this and must not be bounded like a coordinate.
local finiteNumber = OPX.Math.Finite
Access.FiniteNumber = finiteNumber

-- The world box, the two coercions over it and the engine's marker vocabulary,
-- all in `lib/shared/spots.lua`.
--
-- ONLY THOSE. A TELEPORT IS NOT A SPOT: it is a point with TWO ends and a leg,
-- and `FromDefinition`, `Coerce`, `Entrance`, `Nearest` and `InBucket` below are
-- about that shape and not about the placed-spot record `garages`, `dealership`
-- and `clothing` share. Bending this module onto that record would have needed a
-- parameter per difference -- two positions, two labels, a leg, a vertical band,
-- a two-key sort -- which is a shared function with nothing left to say. The
-- coordinate box and the marker look ARE the same question, so they come from
-- there.
Access.Coordinate = OPX.Spots.Coordinate
Access.Integer = OPX.Spots.Integer
local coordinate, integer = Access.Coordinate, Access.Integer

-- The %d ceiling quoted in this module's own refusal messages.
local BOUND = OPX.Spots.BOUND

local STYLES = OPX.Spots.STYLES

--- The largest allowed teleport key, and the longest label kept.
Access.MAX_KEY = 48
Access.MAX_LABEL = 64

-- Coerces one end of a teleport: a label, a position and a facing.
--
-- HEADING IS OPTIONAL AND DEFAULTS TO ZERO, unlike the three coordinates, which
-- are not optional at all. A missing facing lands somebody looking north, which
-- is merely untidy; a missing coordinate would land them at the world origin,
-- which is the sea.
local function endpoint(key, side, raw)
	if type(raw) ~= 'table' then
		return nil, ('%s: %s must be a table of LABEL, X, Y, Z and HEADING'):format(key, side)
	end
	local x, y, z = coordinate(raw.X), coordinate(raw.Y), coordinate(raw.Z)
	if x == nil or y == nil or z == nil then
		return nil, ('%s: %s X, Y and Z must be finite numbers inside %d'):format(key, side, BOUND)
	end
	local heading = finiteNumber(raw.HEADING) or 0.0
	-- Wrapped rather than refused: 370 and -350 are both an operator writing a
	-- compass bearing, and the engine wants 0..360.
	heading = heading % 360.0

	local label = raw.LABEL
	if label ~= nil and type(label) ~= 'string' then
		return nil, ('%s: %s LABEL must be a string'):format(key, side)
	end
	label = type(label) == 'string' and OPX.String.Trim(label) or ''
	if label == '' then label = side:lower() end
	if #label > Access.MAX_LABEL then label = label:sub(1, Access.MAX_LABEL) end

	return { label = label, x = x, y = y, z = z, heading = heading }
end

--- Normalises one configured teleport, or answers why it was refused.
-- @author dop42
-- @param key any the durable name, which is the config table's own key
-- @param raw any the definition as an operator wrote it
-- @return table|nil
-- @return string|nil
function Access.FromDefinition(key, raw)
	if type(key) ~= 'string' then return nil, 'every teleport key must be a string' end
	key = OPX.String.Trim(key)
	if key == '' or #key > Access.MAX_KEY then
		return nil, ('key must be a string of 1 to %d characters'):format(Access.MAX_KEY)
	end
	if type(raw) ~= 'table' then return nil, key .. ': every teleport must be a table' end

	local entry, why = endpoint(key, 'ENTRY', raw.ENTRY)
	if entry == nil then return nil, why end
	local exit, exitWhy = endpoint(key, 'EXIT', raw.EXIT)
	if exit == nil then return nil, exitWhy end

	local bucket = raw.BUCKET == nil and 0 or integer(raw.BUCKET)
	if bucket == nil or bucket < 0 then
		return nil, ('%s: BUCKET must be a whole number, 0 or more'):format(key)
	end

	local label = raw.LABEL
	if label ~= nil and type(label) ~= 'string' then
		return nil, ('%s: LABEL must be a string'):format(key)
	end
	label = type(label) == 'string' and OPX.String.Trim(label) or ''
	if label == '' then label = key end
	if #label > Access.MAX_LABEL then label = label:sub(1, Access.MAX_LABEL) end

	if raw.JOBS ~= nil and type(raw.JOBS) ~= 'table' then
		return nil, ('%s: JOBS must be a table of name -> minimum grade'):format(key)
	end
	local reason = type(raw.REASON) == 'string' and OPX.String.Trim(raw.REASON) or nil
	if reason == '' then reason = nil end
	if reason ~= nil and #reason > Access.MAX_LABEL then
		reason = reason:sub(1, Access.MAX_LABEL)
	end

	return {
		key = key,
		label = label,
		enabled = raw.enabled ~= false,
		bucket = bucket,
		entry = entry,
		exit = exit,
		-- Two-way only when the operator said so in as many words. Anything else
		-- -- nil, a string, a zero -- is one-way, because the direction a player
		-- can be sent in is not somewhere to be generous with a coercion.
		twoWay = raw.RETURN == true,
		dismount = raw.DISMOUNT == true,
		jobs = type(raw.JOBS) == 'table' and raw.JOBS or nil,
		onDuty = raw.ON_DUTY == true,
		reason = reason,
	}
end

--- Builds a key -> teleport table from a POINTS block.
-- A point with `enabled = false` is dropped here and not later: it must not draw
-- a marker, must not appear on the wire and must not be usable, and one place
-- deciding that is one place to get it wrong.
-- @author dop42
-- @param definitions table|nil
-- @param problems table|nil collector, appended to
-- @return table
function Access.Coerce(definitions, problems)
	local points = {}
	if type(definitions) ~= 'table' then
		if problems ~= nil then
			problems[#problems + 1] = 'POINTS must be a table of key -> definition'
		end
		return points
	end
	for key, raw in pairs(definitions) do
		local point, why = Access.FromDefinition(key, raw)
		if point == nil then
			if problems ~= nil then problems[#problems + 1] = why end
		elseif point.enabled then
			points[point.key] = point
		end
	end
	return points
end

--- The configured teleports, already validated and with the disabled dropped.
-- Read as empty rather than refused: every read below is reachable from the
-- contract, and a config file that failed to load must not raise inside a net
-- handler.
Access.POINTS = Access.Coerce(Config.POINTS, nil)

--- Answers one teleport by key, or nil.
-- @author dop42
-- @param points table
-- @param key any
-- @return table|nil
function Access.Point(points, key)
	if type(points) ~= 'table' or type(key) ~= 'string' then return nil end
	return points[key]
end

--- The two ends of one leg: where a player must stand, and where they land.
-- @author dop42
-- @param point table
-- @param leg any one of M.Leg
-- @return table|nil the end stood on
-- @return table|nil the end landed at
local function legs(point, leg)
	if leg == M.Leg.OUT then return point.entry, point.exit end
	-- THE BACK LEG ONLY EXISTS ON A TWO-WAY, and this is the check that makes
	-- `RETURN` mean something. Without it a client could name `back` on a one-way
	-- hatch and be carried up out of the maintenance level the operator meant
	-- them to walk out of.
	if leg == M.Leg.BACK and point.twoWay then return point.exit, point.entry end
	return nil, nil
end

--- Builds one entrance: one end of one leg of one teleport.
-- @author dop42
-- @param point table
-- @param leg string
-- @return table|nil
function Access.Entrance(point, leg)
	if type(point) ~= 'table' then return nil end
	local from, to = legs(point, leg)
	if from == nil then return nil end
	return {
		key = point.key,
		leg = leg,
		-- What the ROW says, which is where the player is going and not where
		-- they are standing: a marker that announced its own position would tell
		-- a player something they can already see.
		label = to.label,
		-- The teleport's own name, for the log line and the diagnostic.
		title = point.label,
		bucket = point.bucket,
		x = from.x, y = from.y, z = from.z,
		to = to,
		dismount = point.dismount,
		-- THE GATE IS CARRIED ON THE OUTBOUND LEG ALONE. The back leg of a locked
		-- two-way is deliberately ungated: somebody whose duty ends on the secure
		-- floor has, by this module's own premise, no walkable way down.
		jobs = leg == M.Leg.OUT and point.jobs or nil,
		onDuty = leg == M.Leg.OUT and point.onDuty or false,
		reason = leg == M.Leg.OUT and point.reason or nil,
	}
end

--- Looks one entrance up by the two things a client is allowed to name.
-- This is THE destination validation: a key that is not configured, a leg that
-- is not one of the two, and the back leg of a one-way all answer nil here, and
-- the server turns that into a refusal without ever having read a coordinate off
-- the wire.
-- @author dop42
-- @param points table
-- @param key any
-- @param leg any
-- @return table|nil
function Access.Lookup(points, key, leg)
	local point = Access.Point(points, key)
	if point == nil then return nil end
	if leg ~= M.Leg.OUT and leg ~= M.Leg.BACK then return nil end
	return Access.Entrance(point, leg)
end

--- Normalises one entrance off the wire, in the shape the server sends.
-- @author dop42
--
-- A SEPARATE FUNCTION FROM `FromDefinition` ON PURPOSE. A DEFINITION is what an
-- operator writes -- upper-case fields, two ends, a JOBS block -- and a WIRE
-- entrance is one end of one leg, already judged, in lower case. Validating the
-- second with the first's rules would demand fields the server never sends; not
-- validating it at all would let a malformed payload put a NaN into a distance
-- and quietly stop the whole scan from ever finding anything.
--
-- `allowed` is carried through and is PRESENTATION ONLY: it colours a marker and
-- writes a sentence. The server decides again when the key is pressed.
-- @param raw any
-- @return table|nil
-- @return string|nil
function Access.FromWire(raw)
	if type(raw) ~= 'table' then return nil, 'every entrance must be a table' end
	if type(raw.key) ~= 'string' or raw.key == '' or #raw.key > Access.MAX_KEY then
		return nil, 'an entrance arrived with no usable key'
	end
	if raw.leg ~= M.Leg.OUT and raw.leg ~= M.Leg.BACK then
		return nil, raw.key .. ': leg must be out or back'
	end
	local x, y, z = coordinate(raw.x), coordinate(raw.y), coordinate(raw.z)
	if x == nil or y == nil or z == nil then
		return nil, raw.key .. ': x, y and z must be finite numbers'
	end
	local label = type(raw.label) == 'string' and OPX.String.Trim(raw.label) or ''
	if label == '' then label = raw.key end
	if #label > Access.MAX_LABEL then label = label:sub(1, Access.MAX_LABEL) end
	local reason = type(raw.reason) == 'string' and OPX.String.Trim(raw.reason) or nil
	if reason == '' then reason = nil end
	if reason ~= nil and #reason > Access.MAX_LABEL then reason = reason:sub(1, Access.MAX_LABEL) end
	return {
		key = raw.key,
		leg = raw.leg,
		label = label,
		x = x, y = y, z = z,
		allowed = raw.allowed == true,
		error = type(raw.error) == 'string' and raw.error or nil,
		reason = reason,
	}
end

--- The entrance a body is standing on, or nil.
-- The nearest wins; at equal distance the key and then the leg decide, so
-- `pairs` order never chooses between the two ends of a teleport whose author
-- put them a metre apart. The vertical band is applied here too, for the reason
-- `AtEntrance` gives: a body falling through the marker's column is not standing
-- on it.
-- @author dop42
-- @param entrances table key|index -> entrance
-- @param x any
-- @param y any
-- @param z any
-- @return table|nil
-- @return number|nil squared flat distance
function Access.Nearest(entrances, x, y, z)
	if type(entrances) ~= 'table' then return nil, nil end
	z = coordinate(z)
	local best, bestDistance
	for _, entrance in pairs(entrances) do
		local flat = Access.FlatDistanceSquared(entrance, x, y)
		local within = flat ~= nil and flat <= Access.USE_RADIUS_SQ
		if within and z ~= nil then
			local rise = z - entrance.z
			if rise < 0 then rise = -rise end
			within = rise <= Access.USE_HEIGHT
		end
		if within and (bestDistance == nil or flat < bestDistance or
			(flat == bestDistance and (entrance.key < best.key or
				(entrance.key == best.key and entrance.leg < best.leg)))) then
			best, bestDistance = entrance, flat
		end
	end
	return best, bestDistance
end

--- Every entrance in one routing bucket, sorted.
-- Sorted because `pairs` order would reshuffle a SYNC payload, a listing and a
-- determinism check between runs.
-- @author dop42
-- @param points table
-- @param bucket any
-- @return table[]
function Access.InBucket(points, bucket)
	bucket = integer(bucket) or 0
	local list = {}
	for _, point in pairs(points) do
		if point.bucket == bucket then
			for _, leg in ipairs({ M.Leg.OUT, M.Leg.BACK }) do
				local entrance = Access.Entrance(point, leg)
				if entrance ~= nil then list[#list + 1] = entrance end
			end
		end
	end
	table.sort(list, function(left, right)
		if left.key ~= right.key then return left.key < right.key end
		return left.leg < right.leg
	end)
	return list
end

--- Decides whether a character snapshot may take one entrance.
-- The rule itself is `lib/shared/jobgate.lua`, shared with the elevators module:
-- an entrance with no JOBS is open to everybody including a character that could
-- not be read, and a gated one closes on every doubt. This function only names
-- an ENTRANCE's fields to it and supplies this module's own two numbers.
-- @author dop42
-- @param entrance table
-- @param snapshot table|nil
-- @param nowMs number
-- @return boolean
-- @return string|nil
function Access.Evaluate(entrance, snapshot, nowMs)
	if type(entrance) ~= 'table' then return false, 'no_such_teleport' end
	return OPX.JobGate.Evaluate({ jobs = entrance.jobs, onDuty = entrance.onDuty },
		snapshot, nowMs,
		{ maxAgeMs = Access.JOB_MAX_AGE_MS, membership = Config.MEMBERSHIP })
end

--- Squared horizontal distance from a point to an entrance.
-- @author dop42
-- @param entrance table
-- @param x any
-- @param y any
-- @return number|nil
function Access.FlatDistanceSquared(entrance, x, y)
	x, y = coordinate(x), coordinate(y)
	if type(entrance) ~= 'table' or x == nil or y == nil then return nil end
	local dx, dy = x - entrance.x, y - entrance.y
	return dx * dx + dy * dy
end

--- Whether a body at this position and bucket is standing on this entrance.
-- @author dop42
--
-- FLAT RADIUS AND A VERTICAL BAND, which is the one measurement this module does
-- differently from the elevators. A lift is called from every floor of its own
-- shaft, so that module measures across the ground and throws Z away. A teleport
-- pad is a disc: the walkway six metres overhead is not it, and neither is a body
-- FALLING THROUGH the marker's column, which passes a flat-only test for the
-- whole of the fall.
-- @param entrance table
-- @param x any
-- @param y any
-- @param z any
-- @param bucket any
-- @return boolean
-- @return string|nil one of no_position, wrong_bucket, too_far
function Access.AtEntrance(entrance, x, y, z, bucket)
	if type(entrance) ~= 'table' then return false, 'no_such_teleport' end
	x, y, z = coordinate(x), coordinate(y), coordinate(z)
	if x == nil or y == nil or z == nil then return false, 'no_position' end
	local at = integer(bucket)
	if at == nil or at ~= entrance.bucket then return false, 'wrong_bucket' end
	local flat = Access.FlatDistanceSquared(entrance, x, y)
	-- The server is the only caller, so its slack is applied here: see
	-- `REACH_SLACK` in config/shared.lua.
	if flat == nil or flat > OPX.Spots.ServerReachSq(Access.USE_RADIUS) then return false, 'too_far' end
	local rise = z - entrance.z
	if rise < 0 then rise = -rise end
	if rise > Access.USE_HEIGHT then return false, 'too_far' end
	return true, nil
end

-- What a marker falls back to when the operator named nothing usable. A teleport
-- pad is a small cylinder: a player must stand ON it, and a wide ring would
-- invite them to stand in a hole the trigger does not cover.
local FALLBACK = { shape = 'cylinder', style = 'interaction', RADIUS = 1.2 }

--- The marker an entrance is drawn with, open or locked.
-- The per-field fallback and the ground lift are `lib/shared/spots.lua`. The
-- LOCKED override is this module's own and stays here: no other module draws a
-- refusal it will still let a player walk up to.
-- @author dop42
-- @param locked boolean|nil
-- @return table shape, style, radius, lift
function Access.Marker(locked)
	local look = OPX.Spots.Marker(Config.MARKER, FALLBACK, Config.GROUND_OFFSET)
	if locked then
		local refused = type(Config.LOCKED_STYLE) == 'string' and Config.LOCKED_STYLE:lower()
			or 'danger'
		look.style = STYLES[refused] and refused or 'danger'
	end
	return look
end

--- How far away a marker is still drawn, clamped to what the engine accepts.
-- @author dop42
-- @return number
function Access.MaxDistance()
	return OPX.Spots.MaxDistance(Config.MAX_DISTANCE, 120.0)
end

--- Whether a refused entrance is still drawn at all.
-- @author dop42
-- @return boolean
function Access.HidesDenied()
	return Config.DENIED == 'hidden'
end

-- The distances and cadences, read once. A value `Problems` refuses reads as
-- zero here, so a bad one becomes a boot warning rather than a raise inside a
-- scan, a contract call or a network handler.
local USE_RADIUS = finiteNumber(Config.USE_RADIUS) or 0
Access.USE_RADIUS = USE_RADIUS
Access.USE_RADIUS_SQ = USE_RADIUS * USE_RADIUS
Access.USE_HEIGHT = finiteNumber(Config.USE_HEIGHT) or 0
Access.SCAN_MS = math.floor(finiteNumber(Config.SCAN_MS) or 0)
Access.POLL_MS = math.floor(finiteNumber(Config.POLL_MS) or 0)
Access.JOB_MAX_AGE_MS = finiteNumber(Config.JOB_MAX_AGE_MS) or 0

-- Config keys a distance or a timer uses, all of which must be above zero.
local NUMBERS = { 'USE_RADIUS', 'USE_HEIGHT', 'SCAN_MS', 'POLL_MS', 'JOB_MAX_AGE_MS',
	'FADE_MS', 'SETTLE_MS', 'REQUEST_WINDOW_MS', 'REQUESTS_PER_WINDOW' }

--- Lists every configuration error visible without a world, sorted.
-- @author dop42
--
-- Job NAMES are not checked and cannot be: they live in the character module's
-- own config, and this runs at load with nothing waited on. A JOBS block naming
-- a job that does not exist on this server is a teleport nobody can take, and no
-- amount of shape checking will say so -- which is why `config/teleports.lua`
-- says it in words instead.
--
-- A COORDINATE IS NOT CHECKED EITHER, and that is the failure this module's
-- config header is loudest about: a made-up position is shaped exactly like a
-- surveyed one, and `config/elevators.lua` shipped four of them for weeks.
-- @return string[]
function Access.Problems()
	local lines = {}
	for index = 1, #NUMBERS do
		local name = NUMBERS[index]
		local value = finiteNumber(Config[name])
		if value == nil or value <= 0 then
			lines[#lines + 1] = name .. ' must be a finite number above zero'
		end
	end

	local settle = finiteNumber(Config.SETTLE_MS)
	if settle ~= nil and (settle < 1000 or settle > 30000) then
		lines[#lines + 1] = 'SETTLE_MS must be 1000 to 30000 milliseconds, ' ..
			'which is the range the arrival watch accepts'
	end

	-- The draw distance and the ground offset are reported against the same
	-- bounds `Access.Marker` and `Access.MaxDistance` clamp to, because they are
	-- literally the same constants.
	OPX.Spots.DrawProblems(Config.MAX_DISTANCE, Config.GROUND_OFFSET, lines)

	if Config.DENIED ~= 'shown' and Config.DENIED ~= 'hidden' then
		lines[#lines + 1] = 'DENIED must be shown or hidden'
	end
	if Config.MEMBERSHIP ~= 'primary' and Config.MEMBERSHIP ~= 'any' then
		lines[#lines + 1] = 'MEMBERSHIP must be primary or any'
	end

	OPX.Spots.MarkerProblems(Config.MARKER, 'MARKER', lines)
	local lockedStyle = type(Config.LOCKED_STYLE) == 'string' and Config.LOCKED_STYLE:lower()
		or nil
	if lockedStyle ~= nil and not STYLES[lockedStyle] then
		lines[#lines + 1] = 'LOCKED_STYLE must be interaction, objective, spawn or danger'
	end

	local key = type(Config.KEY) == 'table' and Config.KEY or nil
	if key == nil then
		lines[#lines + 1] = 'KEY must be a table of ID, NAME and DEFAULT'
	else
		if type(key.ID) ~= 'string' or key.ID == '' then
			lines[#lines + 1] = 'KEY.ID must be a string'
		end
		if type(key.NAME) ~= 'string' or key.NAME == '' then
			lines[#lines + 1] = 'KEY.NAME must be a catalogue key'
		end
		if key.DEFAULT ~= false and (type(key.DEFAULT) ~= 'string' or key.DEFAULT == '') then
			lines[#lines + 1] = 'KEY.DEFAULT must be a key name, or false for no key at all'
		end
	end

	-- POINTS are validated once at load; the errors are re-derived here so the
	-- diagnostic reports them rather than only the boot log.
	Access.Coerce(Config.POINTS, lines)
	-- The JOBS blocks go through the same checker the gate that reads them uses,
	-- so the two can never drift into accepting different shapes. Walked off the
	-- raw config rather than off `POINTS`, because a disabled point is dropped
	-- there and an operator still wants its typo named.
	if type(Config.POINTS) == 'table' then
		for key, raw in pairs(Config.POINTS) do
			if type(raw) == 'table' then
				OPX.JobGate.Problems(raw.JOBS, tostring(key), lines)
			end
		end
	end

	-- Sorted, because `pairs` order would reshuffle the report between runs.
	table.sort(lines)
	return lines
end
