--- Config reads, coercions and the decisions both halves share.
-- @author XEROX710
--
-- WHAT A SPOT IS, AND WHO DECIDES IT. The record, the two input shapes that
-- normalise into it, the marker look and the coordinate box are all
-- `lib/shared/spots.lua`, and this file only names this module's own words to
-- them: its noun, its two KINDs, its key width and its fallback marker. That is
-- not tidying. `modules/dealership/shared/access.lua` held 334 `diff`-clean
-- identical lines of it, and the two must agree exactly or a car bought at a
-- dealer cannot be recalled at the garage beside it.
--
-- WHAT IS STILL THIS MODULE'S. Everything below the vocabulary: which distances
-- and cadences it scans at, how long a capture may take, and what a broken one
-- of those reads as. Those are numbers about THIS surface, not about what a spot
-- is, and a shared file that owned them would be forcing a dealer and a garage
-- to poll at the same rate for no reason. The job fleet is this module's too --
-- `JOB_VEHICLES`, who may take which row out, below the AV annex.
--
-- Every value is coerced and never trusted: a coordinate that is a string, a
-- NaN, an unknown KIND or a radius outside the engine's range reads as a
-- warning at boot rather than a raise inside a scan or a network handler. Only X
-- and Y are ever measured against; Z is validated and then carried to the create
-- call.

local M = OPX.Modules.Get('garages')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a yaw, a price and a millisecond
-- clock are all measured with this and must not be bounded like a coordinate.
local finiteNumber = OPX.Math.Finite
Access.FiniteNumber = finiteNumber

-- The world box and the two coercions over it, in `lib/shared/spots.lua`. Kept
-- as names on `Access` because the whole module already reads spot rules through
-- `Access` and a caller should not have to know which of them is shared.
Access.Coordinate = OPX.Spots.Coordinate
Access.Integer = OPX.Spots.Integer

-- The two kinds. A style or a shape outside the engine's own sets is refused by
-- `Open77.markers` with a status, so those live in `lib/shared/spots.lua` beside
-- the resolver that falls back to them.
local KINDS = { [M.KIND.GARAGE] = true, [M.KIND.AVPAD] = true }
Access.KINDS = KINDS

-- The two roles a DRAWN point may have. An exit is not one: nothing is drawn at
-- an exit and no key is pressed on one.
local ROLES = { [M.ROLE.MENU] = true, [M.ROLE.ENTRY] = true }
Access.ROLES = ROLES

--- The largest allowed GARAGE key, which is what a vehicle's `garage` column
--- holds and therefore the width that column is declared at.
Access.MAX_KEY = 48

--- The largest allowed POINT key. Longer than a garage key because a point key
--- is DERIVED from one -- `<garage>#<location>` and `<garage>#<location>.in` --
--- and a garage named at the full 48 would otherwise build points nothing would
--- accept. Nothing stores a point key: it exists on the wire and in this
--- process, which is why it may be wider than any column.
Access.MAX_POINT_KEY = 64

-- This module's words for the shared record: a point has a KIND, because a
-- garage and an AV pad are drawn and used differently, and a HEADING, because a
-- vehicle is CREATED at an entry and at an exit and something has to say which
-- way it faces.
local SPEC = {
	noun = 'spot',
	maxKey = Access.MAX_POINT_KEY,
	kinds = KINDS,
	kindNames = 'garage, avpad',
	heading = true,
}

--- Normalises one config or database row, in the operator's upper-case spelling.
-- @author XEROX710
-- @param key string
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromDefinition(key, raw)
	local spot, why = OPX.Spots.FromDefinition(SPEC, key, raw)
	if spot == nil then return nil, why end
	return Access.Attach(spot, raw)
end

--- Hangs the three fields the shared record knows nothing about onto a point.
-- @author XEROX710
--
-- `lib/shared/spots.lua` IS THE VOCABULARY OF A PLACE and deliberately not of a
-- garage: it knows a key, a position, a bucket and a look, and five modules
-- share it on those terms. Which GARAGE a point belongs to, which of its
-- LOCATIONS, and whether it is the menu or the door are facts about this module
-- alone, so they are attached here rather than pushed into a record four other
-- modules would then carry three unread fields of.
--
-- The defaults are what a point with nothing said about it means: it belongs to
-- the garage of its own name, at its first location, and it is the menu. That is
-- exactly a spot of the shape this module had before the rework, which is what
-- lets a legacy row and a test's hand-built spot both go straight through.
-- @param spot table
-- @param raw table|nil the definition or wire row it came from
-- @return table the same spot
function Access.Attach(spot, raw)
	raw = type(raw) == 'table' and raw or {}
	local garage = raw.GARAGE or raw.garage
	spot.garage = (type(garage) == 'string' and garage ~= '') and garage or spot.key
	local role = raw.ROLE or raw.role
	role = type(role) == 'string' and role:lower() or nil
	spot.role = (role ~= nil and ROLES[role]) and role or M.ROLE.MENU
	local at = OPX.Spots.Integer(raw.LOCATION or raw.location)
	spot.location = (at ~= nil and at >= 1) and at or 1
	return spot
end

--- Normalises one point off the wire, in the shape `Access.Serialise` writes.
-- @author XEROX710
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWire(raw)
	local spot, why = OPX.Spots.FromWire(SPEC, raw)
	if spot == nil then return nil, why end
	return Access.Attach(spot, raw)
end

--- The fields of one point, as the wire and the SYNC event carry them.
-- The three this module adds travel with it: a client that knew a point's
-- position and not which garage it opens could draw a marker and could not name
-- what pressing the key would list.
-- @author XEROX710
-- @param spot table
-- @return table
function Access.Serialise(spot)
	local wire = OPX.Spots.Serialise(spot)
	wire.garage = spot.garage
	wire.role = spot.role
	wire.location = spot.location
	return wire
end

--- The key one drawn point is known by, derived from its garage and never
--- stored. `<garage>#<location>` is the menu and `<garage>#<location>.in` the
--- door, so a key read in a log names the garage, which location, and which of
--- the two it is, without a lookup.
-- @author XEROX710
-- @param garageKey string
-- @param location integer
-- @param role string
-- @return string
function Access.PointKey(garageKey, location, role)
	if role == M.ROLE.ENTRY then
		return ('%s#%d.in'):format(garageKey, location)
	end
	return ('%s#%d'):format(garageKey, location)
end

--- Builds a key -> spot table from a list of definitions.
-- @author XEROX710
-- @param definitions table|nil map of key -> row
-- @param problems table|nil collector, appended to
-- @return table
function Access.Coerce(definitions, problems)
	return OPX.Spots.Coerce(SPEC, definitions, problems)
end

--- Answers one spot by key, or nil.
-- @author XEROX710
-- @param spots table
-- @param key any
-- @return table|nil
Access.Spot = OPX.Spots.Spot

--- Every spot in a bucket, sorted by key.
-- @author XEROX710
-- @param spots table
-- @param bucket integer
-- @return table[] array of spots
Access.InBucket = OPX.Spots.InBucket

--- Squared horizontal distance from a point to a spot's declared position.
-- @author XEROX710
-- @param spot table
-- @param x any
-- @param y any
-- @return number|nil
Access.FlatDistanceSquared = OPX.Spots.FlatDistanceSquared

--- Answers the spot a point stands on, or nil. The nearest wins; at equal
-- distance the key decides, so `pairs` order never chooses between two markers
-- a metre apart.
-- @author XEROX710
-- @param spots table
-- @param x any
-- @param y any
-- @param radius number|nil squared radius; USE_RADIUS_SQ by default
-- @return table|nil
-- @return number|nil squared distance
function Access.Nearest(spots, x, y, radius)
	return OPX.Spots.Nearest(spots, x, y, radius or Access.USE_RADIUS_SQ)
end

--- Whether a TweakDB vehicle record is an AV.
--
-- ONE RULE, OVER ONE CONFIG KEY: `OPX.Vehicle.IsAvRecord` and
-- `OPX.Config.SHARED.AV_PREFIXES`. This module, the dealership and the admin
-- catalogue each carried their own copy over their own key, and the copies had
-- already stopped agreeing about what a non-string or an emptied list means.
-- Whether a record flies is a fact about the record; a car you can buy at a pad
-- you cannot recall it at is what two answers to it costs.
--
-- Kept as a name on `Access` because the whole module already reads spot rules
-- through `Access`, and a caller should not have to know which of them is local.
-- @author XEROX710
-- @param record any
-- @return boolean
function Access.IsAv(record)
	return OPX.Vehicle.IsAvRecord(record)
end

-- What a marker falls back to per kind when the operator named nothing usable. A
-- pad is a RING, because an AV lands inside it and a filled cylinder would be
-- drawn through the hull; a garage is a cylinder you walk into.
-- A DOOR IS NOT A LIST, and the third entry is why this table is keyed by two
-- different things. `garage` and `avpad` are KINDS and describe the menu point;
-- `entry` is a ROLE and describes the door, whatever the garage holds. A player
-- who cannot tell the two apart drives into the one that opens a menu.
local FALLBACK = {
	[M.KIND.AVPAD] = { shape = 'ring', style = 'objective', RADIUS = 3.5 },
	[M.KIND.GARAGE] = { shape = 'cylinder', style = 'spawn', RADIUS = 2.5 },
	[M.ROLE.ENTRY] = { shape = 'ring', style = 'interaction', RADIUS = 3.0 },
}

--- The marker one drawn point is drawn with.
-- The per-field fallback and the ground lift are `lib/shared/spots.lua`; the
-- three looks below are this module's own choice and stay here.
--
-- The ROLE decides first and the KIND second: a door is a door at a garage and
-- at an AV pad alike. `role` omitted is the menu point, which is what every
-- caller meant before there were roles at all.
-- @author XEROX710
-- @param kind string
-- @param role string|nil
-- @return table shape, style, radius, lift
function Access.Marker(kind, role)
	local slot = (role == M.ROLE.ENTRY) and M.ROLE.ENTRY
		or (kind == M.KIND.AVPAD and M.KIND.AVPAD or M.KIND.GARAGE)
	local declared = type(Config.MARKER) == 'table' and Config.MARKER[slot] or nil
	return OPX.Spots.Marker(declared, FALLBACK[slot], Config.GROUND_OFFSET)
end

--- How far away a marker is still drawn, clamped to what the engine accepts.
-- @author XEROX710
-- @return number
function Access.MaxDistance()
	return OPX.Spots.MaxDistance(Config.MAX_DISTANCE, 150.0)
end

-- The distances and cadences, read once. A value `Problems` refuses reads as
-- zero here, so a bad one becomes a boot warning rather than a raise inside a
-- scan.
local USE_RADIUS = finiteNumber(Config.USE_RADIUS) or 0
Access.USE_RADIUS = USE_RADIUS
Access.USE_RADIUS_SQ = USE_RADIUS * USE_RADIUS

-- A seated pilot's reach to a pad's door (`AV_PUTAWAY` in config/garages.lua):
-- never shorter than the walk-up reach, never absurd, and a missing block is the
-- shipped values.
local putaway = type(Config.AV_PUTAWAY) == 'table' and Config.AV_PUTAWAY or {}
local PUTAWAY_RADIUS = math.max(USE_RADIUS, math.min(40.0, finiteNumber(putaway.RADIUS) or 14.0))
Access.AV_PUTAWAY_RADIUS = PUTAWAY_RADIUS
Access.AV_PUTAWAY_RADIUS_SQ = PUTAWAY_RADIUS * PUTAWAY_RADIUS
Access.AV_PUTAWAY_HEIGHT = math.max(1.0, math.min(50.0, finiteNumber(putaway.HEIGHT) or 6.0))

--- The nearest DOOR (`M.ROLE.ENTRY`) within reach of a SEATED player: the walk-up
--- reach for every door, and a pilot's reach for a pad's door when they sit in an
--- aircraft. Seated, the key is the door's -- the menu beside it lists what to
--- bring OUT, which is not what a driver at the door came for -- and a pad
--- captured in game puts its menu and its door on the same spot, where the plain
--- nearest-point rule always handed the tie to the menu.
-- @param spots table points by key
-- @param x number
-- @param y number
-- @param aircraft boolean the player sits in an aircraft
-- @return table|nil the door
-- @return number|nil its squared flat distance
function Access.NearestDoor(spots, x, y, aircraft)
	x, y = OPX.Spots.Coordinate(x), OPX.Spots.Coordinate(y)
	if x == nil or y == nil then return nil end
	local best, bestDistance
	for _, spot in pairs(spots) do
		if spot.role == M.ROLE.ENTRY then
			local limit = (aircraft and spot.kind == M.KIND.AVPAD) and Access.AV_PUTAWAY_RADIUS_SQ
				or Access.USE_RADIUS_SQ
			local dx, dy = x - spot.x, y - spot.y
			local flat = dx * dx + dy * dy
			if flat <= limit and (bestDistance == nil or flat < bestDistance or
				(flat == bestDistance and spot.key < best.key)) then
				best, bestDistance = spot, flat
			end
		end
	end
	return best, bestDistance
end
Access.SCAN_MS = math.floor(finiteNumber(Config.SCAN_MS) or 0)
Access.POLL_MS = math.floor(finiteNumber(Config.POLL_MS) or 0)
Access.COOLDOWN_MS = math.floor(finiteNumber(Config.COOLDOWN_MS) or 0)
Access.REQUEST_WINDOW_MS = math.floor(finiteNumber(Config.REQUEST_WINDOW_MS) or 0)
Access.REQUESTS_PER_WINDOW = math.floor(finiteNumber(Config.REQUESTS_PER_WINDOW) or 0)

-- How much room an exit needs to count as free, squared once because every
-- occupancy test is a squared comparison -- no square root is ever taken of a
-- distance that is only ever compared.
local EXIT_CLEARANCE = finiteNumber(Config.EXIT_CLEARANCE) or 0
Access.EXIT_CLEARANCE = EXIT_CLEARANCE
Access.EXIT_CLEARANCE_SQ = EXIT_CLEARANCE * EXIT_CLEARANCE

--- The AV lift, clamped to something a chassis will not fall through.
-- The rule is `lib/shared/vehicle.lua`, beside the one that says whether a
-- record is an AV at all: the staff spawner had a third copy with no bound.
-- @author XEROX710
-- @return number
function Access.AvLift()
	return OPX.Vehicle.AvLift(Config.AV_LIFT)
end

-- ── a garage, its locations and the points they draw ────────────────────────

--- Builds one garage from a config block, or answers why it was refused.
-- @author XEROX710
--
-- A GARAGE IS REFUSED WHOLE, never repaired. A location with no exits is a
-- location nothing can ever come out of, and a garage half-loaded is a garage
-- whose second door silently does nothing -- which is the failure mode an
-- operator cannot diagnose from inside the game. Every refusal is a boot warning
-- naming the garage and the location by their own numbering.
--
-- The three kinds of point are validated through the SAME `build` every spot in
-- this resource goes through, so a NaN in an exit is refused in the place a NaN
-- in a menu point is, and by the same rule.
-- @param key any
-- @param raw any
-- @param problems table|nil collector, appended to
-- @return table|nil
local function garage(key, raw, problems)
	local function refuse(line)
		if problems ~= nil then problems[#problems + 1] = line end
		return nil
	end

	if type(key) ~= 'string' or key == '' or #key > Access.MAX_KEY then
		return refuse('a garage key must be a string of 1 to ' .. Access.MAX_KEY .. ' characters')
	end
	if type(raw) ~= 'table' then return refuse(key .. ': every garage must be a table') end

	local kind = type(raw.KIND) == 'string' and raw.KIND:lower() or ''
	if not KINDS[kind] then
		return refuse(('%s: KIND must be one of garage, avpad'):format(key))
	end
	if raw.LABEL ~= nil and type(raw.LABEL) ~= 'string' then
		return refuse(('%s: LABEL must be a string'):format(key))
	end
	local locations = raw.LOCATIONS
	if type(locations) ~= 'table' or #locations == 0 then
		return refuse(('%s: LOCATIONS must be a list of at least one location'):format(key))
	end

	local built = {
		key = key,
		label = (type(raw.LABEL) == 'string' and raw.LABEL ~= '') and raw.LABEL or key,
		kind = kind,
		locations = {},
	}

	for index = 1, #locations do
		local place = locations[index]
		local where = ('%s location %d'):format(key, index)
		if type(place) ~= 'table' then return refuse(where .. ': must be a table') end

		-- The bucket is the LOCATION'S, not a point's: a location whose menu and
		-- door were in two routing buckets would be a location half of which no
		-- player can ever see.
		local bucket = place.BUCKET

		local function point(block, role, needHeading)
			local fields = type(block) == 'table' and block or {}
			return Access.FromDefinition(Access.PointKey(key, index, role), {
				KIND = kind,
				LABEL = built.label,
				X = fields.X, Y = fields.Y, Z = fields.Z,
				HEADING = needHeading and fields.HEADING or 0.0,
				BUCKET = bucket,
				GARAGE = key, ROLE = role, LOCATION = index,
			})
		end

		local menu, menuWhy = point(place.MENU, M.ROLE.MENU, false)
		if menu == nil then return refuse(where .. ' MENU: ' .. tostring(menuWhy)) end
		local entry, entryWhy = point(place.ENTRY, M.ROLE.ENTRY, true)
		if entry == nil then return refuse(where .. ' ENTRY: ' .. tostring(entryWhy)) end

		local exits = place.EXITS
		if type(exits) ~= 'table' or #exits == 0 then
			return refuse(where .. ': EXITS must be a list of at least one exit')
		end
		local out = {}
		for slot = 1, #exits do
			local spot, why = Access.FromDefinition(
				('%s#%d.out%d'):format(key, index, slot), {
					KIND = kind, LABEL = built.label,
					X = type(exits[slot]) == 'table' and exits[slot].X or nil,
					Y = type(exits[slot]) == 'table' and exits[slot].Y or nil,
					Z = type(exits[slot]) == 'table' and exits[slot].Z or nil,
					HEADING = type(exits[slot]) == 'table' and exits[slot].HEADING or nil,
					BUCKET = bucket,
					GARAGE = key, LOCATION = index,
				})
			if spot == nil then
				return refuse(('%s EXITS[%d]: %s'):format(where, slot, tostring(why)))
			end
			out[slot] = spot
		end

		built.locations[index] = {
			index = index,
			bucket = menu.bucket,
			menu = menu,
			entry = entry,
			exits = out,
		}
	end

	return built
end

--- Builds every garage, and the flat table of drawn points they add up to.
-- @author XEROX710
-- @param definitions any map of key -> garage block
-- @param problems table|nil collector, appended to
-- @return table key -> garage
-- @return table pointKey -> point
function Access.CoerceGarages(definitions, problems)
	local garages, points = {}, {}
	if type(definitions) ~= 'table' then
		if problems ~= nil then
			problems[#problems + 1] = 'GARAGES must be a table of key -> garage'
		end
		return garages, points
	end
	for key, raw in pairs(definitions) do
		local built = garage(key, raw, problems)
		if built ~= nil then
			garages[key] = built
			for _, place in ipairs(built.locations) do
				points[place.menu.key] = place.menu
				points[place.entry.key] = place.entry
			end
		end
	end
	return garages, points
end

--- Every drawn point of one garage, so a caller that has the garage does not
--- have to walk the flat table to find its own.
-- @author XEROX710
-- @param built table a garage
-- @return table[] array of points
function Access.PointsOf(built)
	local listed = {}
	for _, place in ipairs(built.locations) do
		listed[#listed + 1] = place.menu
		listed[#listed + 1] = place.entry
	end
	return listed
end

-- ── the AV annex: config/avgarages.lua ───────────────────────────────────

--- The AV annex block, or nil when this server ships none or switched it off.
-- `config/avgarages.lua` is the SAME machinery with two differences -- its own
-- file, and a job gate -- and this is the seam where the second one lands. The
-- block is read through `OPX.Config` and not through `M.Settings`, because it
-- is ANOTHER module's config namespace by design: a MaxTac hangar is edited in
-- its own file and must not become a block an operator finds by reading this
-- module's.
-- @return table|nil
local function avAnnex()
	local modules = type(OPX.Config) == 'table' and OPX.Config.MODULES or nil
	local block = type(modules) == 'table' and modules.avgarages or nil
	if type(block) ~= 'table' or block.enabled == false then return nil end
	return block
end

--- The annex policy a captured pad is governed by, or nil when the annex is
-- off. THE SAME GATE `CoerceAll` attaches to every configured pad -- a pad an
-- operator captured in game is a pad like any other and is not a door around
-- the job gate -- plus the capture command names, so the server reads one
-- block for both and the two can never drift apart.
-- @return table|nil { gate = { jobs, onDuty }, commands = { add, remove } }
function Access.Annex()
	local annex = avAnnex()
	if type(annex) ~= 'table' then return nil end
	local jobs = annex.JOBS
	if jobs ~= nil and type(jobs) ~= 'table' then jobs = nil end
	return {
		gate = { jobs = jobs, onDuty = annex.ON_DUTY == true },
		commands = type(annex.COMMANDS) == 'table' and annex.COMMANDS or {},
	}
end

-- The four canonical seat names the runtime ever REPORTS, so a `PILOT_SEAT`
-- the operator mistyped is a boot problem and not a seat the recall silently
-- skips. Aliases the host would ACCEPT are deliberately not taken here: a
-- config that says `driver` and a custody read that answers `seat_front_left`
-- are two spellings of one seat, and the knob is the one place they are told
-- apart.
local PILOT_SEATS = {
	seat_front_left = true,
	seat_front_right = true,
	seat_back_left = true,
	seat_back_right = true,
}

--- The seat an AV recall places its pilot in, or nil for "hands off".
-- @author XEROX710
--
-- THE DEFAULT IS THE CONTROLS. A config that predates the knob gets
-- `seat_front_left` -- the seat the platform's own flight claim reaches for --
-- because "the MaxTac AV is pilotable from inside" is the behaviour, and a
-- knob that turns it on is how an operator opts OUT. `false` is that opt-out;
-- a value that is neither `false` nor a canonical seat name reads as no seat
-- at all and is reported by `Problems`.
-- @return string|nil the canonical seat
function Access.PilotSeat()
	local block = avAnnex()
	-- A REAL INDEX, NOT `and/or`: the knob's OFF value is `false`, and
	-- `a and b or nil` cannot carry a false -- it would read "hands off" as
	-- "unset" and hand over the seat the operator just refused.
	local seat = nil
	if type(block) == 'table' then seat = block.PILOT_SEAT end
	if seat == false then return nil end
	if seat == nil then return 'seat_front_left' end
	if type(seat) == 'string' and PILOT_SEATS[seat] then return seat end
	return nil
end

-- Normalises one `FLEET` block -- the division's own aircraft a pad may
-- issue. `false` is a pad that issues nothing, a list is its hulls in the
-- order the menu shows them, and anything else is refused whole. Each row
-- carries a RECORD the vehicles contract can create; LABEL is the operator's
-- own words and may be absent, in which case the row shows its record.
-- Returns the list and the faults to report against it.
local function fleetOf(raw)
	if raw == nil then return nil, {} end
	-- `false` is KEPT as false rather than flattened to an empty list: the
	-- built garage then reads as "issues nothing" (`M.Issue` answers
	-- `fleetNotHere`) instead of "issues everything but that hull".
	if raw == false then return false, {} end
	if type(raw) ~= 'table' then
		return nil, { 'FLEET must be a list of hull rows or false' }
	end
	local list, faults = {}, {}
	for index = 1, #raw do
		local row = raw[index]
		if type(row) ~= 'table' or type(row.RECORD) ~= 'string' or row.RECORD == '' then
			faults[#faults + 1] = ('FLEET row %d must carry a non-empty RECORD'):format(index)
		elseif row.LABEL ~= nil and type(row.LABEL) ~= 'string' then
			faults[#faults + 1] = ('FLEET row %d LABEL must be a string'):format(index)
		else
			list[#list + 1] = {
				record = row.RECORD,
				label = (type(row.LABEL) == 'string' and row.LABEL ~= '') and row.LABEL or row.RECORD,
			}
		end
	end
	return list, faults
end

--- Builds every garage of BOTH files, and the flat point table under them.
-- @author XEROX710
--
-- THE ANNEX IS MERGED, NOT LOADED ALONGSIDE. Both files name garages in one
-- key space -- a vehicle's `garage` column may hold either -- so there is one
-- map and one coercion, and the only annex-specific work is the rule that puts
-- each annex garage behind the gate and the two refusals that keep the files
-- honest: a key named in BOTH files is refused to the annex (config/garages.lua
-- wins, exactly as config wins over a legacy row above), and an annex block
-- that is not an `avpad` is refused whole. A ground garage in the division's
-- hangar file is a garage the operator will look for in the wrong file.
--
-- THE GATE TRAVELS ON THE BUILT GARAGE as `requirement`, and nothing here
-- decides it: `Access.Evaluate` below is the one adapter over
-- `lib/shared/jobgate.lua`, and the server is the only half that asks.
-- @param definitions any map of key -> garage block, from config/garages.lua
-- @param annex any the config/avgarages.lua block, or nil
-- @param problems table|nil collector, appended to
-- @return table key -> garage
-- @return table pointKey -> point
function Access.CoerceAll(definitions, annex, problems)
	local function refuse(line)
		if problems ~= nil then problems[#problems + 1] = line end
	end

	local merged = {}
	if type(definitions) == 'table' then
		for key, raw in pairs(definitions) do merged[key] = raw end
	end

	local gated, fleets = {}, {}
	if type(annex) == 'table' then
		local avGarages = annex.GARAGES
		if avGarages ~= nil and type(avGarages) ~= 'table' then
			refuse('avgarages: GARAGES must be a table of key -> garage')
			avGarages = nil
		end
		local jobs = annex.JOBS
		if jobs ~= nil and type(jobs) ~= 'table' then jobs = nil end
		OPX.JobGate.Problems(jobs, 'avgarages', problems)
		if avGarages ~= nil and next(avGarages) ~= nil and (jobs == nil or next(jobs) == nil) then
			refuse('avgarages: JOBS names no job, so every pad below is CLOSED to everybody')
		end
		-- THE KNOB IS VALIDATED WITH THE REST OF THE FILE. A `PILOT_SEAT` the
		-- platform cannot spell is refused to no seat at all -- the recall then
		-- leaves the pilot to climb in, exactly as before the knob existed --
		-- and this line is what keeps that choice from being a silent one.
		local seat = annex.PILOT_SEAT
		if seat ~= nil and seat ~= false and not (type(seat) == 'string' and PILOT_SEATS[seat]) then
			refuse('avgarages: PILOT_SEAT must be a canonical seat name or false')
		end
		for key, raw in pairs(avGarages or {}) do
			if merged[key] ~= nil then
				refuse(('%s: named in both config/garages.lua and config/avgarages.lua; ' ..
					'the garages file wins'):format(tostring(key)))
			else
				local kind = type(raw) == 'table' and type(raw.KIND) == 'string'
					and raw.KIND:lower() or ''
				if kind ~= M.KIND.AVPAD then
					refuse(('%s: an avgarages block must be KIND = "avpad"; a ground garage ' ..
						'belongs in config/garages.lua'):format(tostring(key)))
				else
					merged[key] = raw
					gated[key] = { jobs = jobs, onDuty = annex.ON_DUTY == true }
					-- A pad's own FLEET replaces the file's; `false` is a pad
					-- that issues nothing, and an absent one is the file's list.
					local stock = annex.FLEET
					if type(raw) == 'table' and raw.FLEET ~= nil then stock = raw.FLEET end
					local fleet, faults = fleetOf(stock)
					for index = 1, #faults do
						refuse(('%s: %s'):format(tostring(key), faults[index]))
					end
					fleets[key] = fleet
				end
			end
		end
	end

	local garages, points = Access.CoerceGarages(merged, problems)
	for key, requirement in pairs(gated) do
		if garages[key] ~= nil then garages[key].requirement = requirement end
	end
	-- The fleet rides the built garage beside the requirement: `M.List` offers
	-- it and `M.Issue` refuses anything that is not on it.
	for key, fleet in pairs(fleets) do
		if garages[key] ~= nil then garages[key].fleet = fleet end
	end
	return garages, points
end

--- The refusal one gate answers with, by the code `lib/shared/jobgate.lua`
-- names. The codes are internal; what a player reads is a catalogue key.
Access.GATE_REFUSAL = {
	no_character = 'garages.noCharacter',
	job_stale = 'garages.noCharacter',
	job_required = 'garages.jobRequired',
	grade_too_low = 'garages.gradeTooLow',
	off_duty = 'garages.offDuty',
	closed = 'garages.padClosed',
}

--- Whether a character snapshot may use one garage, through the one adapter
-- over `lib/shared/jobgate.lua`.
-- @author XEROX710
--
-- A garage with NO requirement is public and costs no snapshot at all -- the
-- ground garages every server carries are the common case and must not read a
-- character roster for nothing. A gated garage closes on every doubt: no
-- snapshot, a snapshot with no job table, a clock that cannot be read. The
-- asymmetry is the job gate's own, and it is why this is an adapter and not a
-- second copy of five branches.
--
-- THE GATE IS ASKED ONLY BY THE SERVER, off a snapshot stamped from the same
-- clock read that is handed in as `nowMs`, so the age is exactly zero and no
-- staleness bound is declared: a config knob that can never change an answer
-- would be a lie in the config file.
-- @param built table|nil a garage
-- @param snapshot table|nil { job, jobs, atMs }
-- @param nowMs number
-- @return boolean
-- @return string|nil no_such_spot, no_character, job_stale, job_required,
--   grade_too_low, off_duty
function Access.Evaluate(built, snapshot, nowMs)
	-- Closed for a garage that is not a table: reading `.requirement` off a nil
	-- raises out of whichever handler was asking, and every sibling adapter
	-- answers closed here.
	if type(built) ~= 'table' then return false, 'no_such_spot' end
	local requirement = built.requirement
	if type(requirement) ~= 'table' then return true end
	-- A PAD WHOSE GATE NAMES NO JOB IS CLOSED, NOT PUBLIC. The owner decided
	-- that an emptied `JOBS` in config/avgarages.lua must never hand the
	-- division's hangar to everybody: `OPX.JobGate.Evaluate` reads no jobs as
	-- open, which is right for a public floor and wrong for a requirement that
	-- was meant to name a crew and names none.
	if type(requirement.jobs) ~= 'table' or next(requirement.jobs) == nil then
		return false, 'closed'
	end
	return OPX.JobGate.Evaluate(requirement, snapshot, nowMs, { maxAgeMs = 0 })
end

--- The job an issued hull is held under: what `M.Issue` writes into the row.
-- @author sh104
--
-- THE JOB THE GATE LET THEM THROUGH ON. The worked job when the pad names it
-- -- the gate reads the worked job -- and otherwise the first job by name the
-- pad names that the character holds at its floor. Nil for a pad that names no
-- job at all, which the gate already refuses.
-- @param requirement table|nil the pad's `{ jobs, onDuty }`
-- @param data table the character's PlayerData
-- @param garage string the pad's key
-- @return table|nil `{ job, grade, garage }`
function Access.IssuedBy(requirement, data, garage)
	local required = type(requirement) == 'table' and requirement.jobs or nil
	if type(required) ~= 'table' or type(data) ~= 'table' then return nil end
	local worked = type(data.job) == 'table' and data.job.name or nil
	if type(worked) == 'string' and required[worked] ~= nil then
		return { job = worked, grade = OPX.Math.Finite(required[worked]) or 0, garage = garage }
	end
	local held = type(data.jobs) == 'table' and data.jobs or {}
	local best = nil
	for name, minimum in pairs(required) do
		local grade = OPX.Math.Finite(held[name])
		local floor = OPX.Math.Finite(minimum) or 0
		if type(name) == 'string' and grade ~= nil and grade >= floor
			and (best == nil or name < best.job) then
			best = { job = name, grade = floor, garage = garage }
		end
	end
	return best
end

--- Whether a character may still keep a hull a job issued them.
-- @author sh104
--
-- THE MEMBERSHIP, NOT THE SHIFT: a member who clocks off keeps the aircraft
-- the division issued them; one who is fired, quits, or is demoted below the
-- pad's floor for that job does not. A row with no `issued` mark was never a
-- job's to take back.
-- @param metadata table|nil the vehicle row's metadata
-- @param jobs table|nil the character's memberships, job -> grade
-- @return boolean
function Access.MayKeepIssued(metadata, jobs)
	local issued = type(metadata) == 'table' and metadata.issued or nil
	if type(issued) ~= 'table' or type(issued.job) ~= 'string' then return true end
	local held = type(jobs) == 'table' and OPX.Math.Finite(jobs[issued.job]) or nil
	return held ~= nil and held >= (OPX.Math.Finite(issued.grade) or 0)
end

--- The configured garages of BOTH files and their points, already validated.
-- Read as empty rather than refused: every read is reachable from the contract.
-- @author XEROX710
Access.GARAGES, Access.SPOTS = Access.CoerceAll(Config.GARAGES, avAnnex(), nil)

-- ── the job fleet: config/garages.lua JOB_VEHICLES ─────────────────────────

--- The widest fleet KEY. It is the slot a job vehicle is held under and a menu
--- row's id, so it is a bounded word, as wide as a garage key.
Access.MAX_JOB_KEY = 48

-- What a KEY may be spelled with: a menu row id accepts these and nothing else.
local JOB_KEY_PATTERN = '^[%w_%-%.]+$'

-- The longest RECORD a row may name, the vehicles module's own ceiling.
local MAX_JOB_RECORD = 256

--- Whether the PLATFORM flies a record as an aircraft: a `Vehicle.av_*` record,
--- or exactly `Vehicle.max_tac_av`, spelled in that case
--- (`client/src/api/VehicleFlight.cpp` `IsAvRecord`). Narrower than this
--- server's own AV rule, which also sorts hulls like `Vehicle.q001_police_av`
--- onto a pad: those come out and stay on the ground.
--- @param record string
--- @return boolean
function Access.PlatformFlies(record)
	if type(record) ~= 'string' then return false end
	return record:sub(1, #'Vehicle.av_') == 'Vehicle.av_' or record == 'Vehicle.max_tac_av'
end

-- The longest APPEARANCE a row may name: the vehicles table's own column
-- (`appearance VARCHAR(128)`), so a job vehicle's variant is spelled within
-- what an owned one's may be.
local MAX_JOB_APPEARANCE = 128

-- What an APPEARANCE may be spelled with: an entity appearance name is one
-- CName of letters, digits and underscores (`zetatech_atlus_ncpd_01`).
local JOB_APPEARANCE_PATTERN = '^[%w_]+$'

--- The character catalogue's jobs, or nil when it cannot be read -- in which
--- case job and grade names go unchecked rather than every row being refused.
local function jobCatalogue()
	local modules = type(OPX.Config) == 'table' and OPX.Config.MODULES or nil
	local character = type(modules) == 'table' and modules.character or nil
	local jobs = type(character) == 'table' and character.JOBS or nil
	return type(jobs) == 'table' and jobs or nil
end

--- Builds the job fleet out of the `JOB_VEHICLES` block.
-- @author XEROX710
--
-- A ROW IS REFUSED ALONE, never the fleet: a typo in the Captain's armoured car
-- must not take the Cadet's patrol car away from every Cadet on the server. A
-- job or a grade the character catalogue does not define is refused whole --
-- rows for a rank nobody can hold are rows listed to nobody -- and every
-- refusal is a boot line naming the job, the grade and the row.
--
-- The order is the list's order: grade by grade from the lowest, and within a
-- grade the order written, so a Captain's list reads the way the ladder does.
-- @param raw any the JOB_VEHICLES block
-- @param problems table|nil collector, appended to
-- @return table { byKey = { [key] = row }, byJob = { [job] = { onDuty, rows } } }
function Access.CoerceJobFleet(raw, problems)
	local fleet = { byKey = {}, byJob = {} }
	local function refuse(line)
		if problems ~= nil then problems[#problems + 1] = line end
	end
	if raw == nil then return fleet end
	if type(raw) ~= 'table' then
		refuse('JOB_VEHICLES must be a table of job name -> { ON_DUTY, GRADES }')
		return fleet
	end
	local catalogue = jobCatalogue()

	local names = {}
	for name in pairs(raw) do
		if type(name) == 'string' and name ~= '' then
			names[#names + 1] = name
		else
			refuse('JOB_VEHICLES is keyed by job name; ' .. tostring(name) .. ' is not one')
		end
	end
	table.sort(names)

	-- One row, or nil with the line that says why.
	local function coerceRow(row, jobName, level, onDuty, where)
		if type(row) ~= 'table' then return nil, where .. ' must be a table' end
		local key = row.KEY
		if type(key) ~= 'string' or #key == 0 or #key > Access.MAX_JOB_KEY
			or key:match(JOB_KEY_PATTERN) == nil then
			return nil, ('%s KEY must be 1 to %d letters, digits, _ - or .')
				:format(where, Access.MAX_JOB_KEY)
		end
		if fleet.byKey[key] ~= nil then
			return nil, ('%s KEY %s is already the key of another row; a KEY is unique ' ..
				'across every job'):format(where, key)
		end
		local record = row.RECORD
		if type(record) ~= 'string' or record == '' or #record > MAX_JOB_RECORD then
			return nil, ('%s (%s) RECORD must be a vehicle record of 1 to %d characters')
				:format(where, key, MAX_JOB_RECORD)
		end
		if type(row.LABEL) ~= 'string' or row.LABEL == '' then
			return nil, ('%s (%s) LABEL must name the vehicle -- a catalogue key in ' ..
				'modules/garages/locales.lua'):format(where, key)
		end
		-- OPTIONAL: the livery, one of the appearance names the record's entity
		-- template carries. Absent, the record's own. Only the spelling can be
		-- checked here: a name the template does not carry is drawn as the
		-- record's own livery, and the engine says nothing about it.
		local appearance = row.APPEARANCE
		if appearance ~= nil and (type(appearance) ~= 'string' or #appearance == 0
			or #appearance > MAX_JOB_APPEARANCE or appearance:match(JOB_APPEARANCE_PATTERN) == nil) then
			return nil, ('%s (%s) APPEARANCE must be an appearance name of 1 to %d letters, ' ..
				'digits or _'):format(where, key, MAX_JOB_APPEARANCE)
		end
		return {
			key = key,
			job = jobName,
			grade = level,
			record = record,
			appearance = appearance,
			label = row.LABEL,
			onDuty = onDuty,
			-- The record's own fact, by the one AV rule: which kind of garage the
			-- row comes out of is never written by hand.
			av = Access.IsAv(record),
		}
	end

	for index = 1, #names do
		local jobName = names[index]
		local block = raw[jobName]
		local where = 'JOB_VEHICLES.' .. jobName
		local defined = catalogue ~= nil and catalogue[jobName] or nil
		if type(block) ~= 'table' then
			refuse(where .. ' must be a table of ON_DUTY and GRADES')
		elseif catalogue ~= nil and type(defined) ~= 'table' then
			refuse(where .. ': config/character.lua defines no job of that name')
		elseif type(block.GRADES) ~= 'table' then
			refuse(where .. '.GRADES must be a table of grade -> list of vehicle rows')
		else
			if block.ON_DUTY ~= nil and type(block.ON_DUTY) ~= 'boolean' then
				refuse(where .. '.ON_DUTY must be true or false; read as true')
			end
			-- ON BY DEFAULT, the MaxTac pads' own rule: a job's vehicles are for
			-- the crew on duty unless the file says otherwise, in as many words.
			local onDuty = block.ON_DUTY ~= false
			local levels = {}
			for level in pairs(block.GRADES) do
				if math.type(level) == 'integer' and level >= 0 then
					levels[#levels + 1] = level
				else
					refuse(('%s.GRADES is keyed by grade number from 0; %s is not one')
						:format(where, tostring(level)))
				end
			end
			table.sort(levels)
			local entry = { onDuty = onDuty, rows = {} }
			for at = 1, #levels do
				local level = levels[at]
				local rows = block.GRADES[level]
				local grades = type(defined) == 'table' and defined.grades or nil
				if catalogue ~= nil and (type(grades) ~= 'table' or grades[level] == nil) then
					refuse(('%s grade %d: config/character.lua gives %s no such grade')
						:format(where, level, jobName))
				elseif type(rows) ~= 'table' then
					refuse(('%s grade %d must be a list of vehicle rows'):format(where, level))
				else
					for slot = 1, #rows do
						local built, why = coerceRow(rows[slot], jobName, level, onDuty,
							('%s grade %d row %d'):format(where, level, slot))
						if built == nil then
							refuse(why)
						else
							fleet.byKey[built.key] = built
							entry.rows[#entry.rows + 1] = built
							-- Kept, and said: an aircraft by this server's rule that
							-- the platform will not fly comes out of a pad and never
							-- leaves it.
							if built.av and not Access.PlatformFlies(built.record) then
								refuse(('%s grade %d row %d (%s): %s is an AV here, but the platform ' ..
									'flies only Vehicle.av_* and Vehicle.max_tac_av: it comes out and ' ..
									'never leaves the ground'):format(where, level, slot, built.key, built.record))
							end
						end
					end
				end
			end
			fleet.byJob[jobName] = entry
		end
	end
	return fleet
end

--- The job fleet this server ships, already validated.
-- @author XEROX710
Access.JOB_FLEET = Access.CoerceJobFleet(Config.JOB_VEHICLES, nil)

--- Milliseconds between two passes over the job vehicles that are out. A value
--- the config got wrong reads as the shipped five seconds, and `Problems` says
--- so: a pass that never ran would leave a fired officer his patrol car.
Access.JOB_SWEEP_MS = math.floor(finiteNumber(Config.JOB_SWEEP_MS) or 0)
if Access.JOB_SWEEP_MS <= 0 then Access.JOB_SWEEP_MS = 5000 end

--- Whether a character snapshot may take out one fleet row, and when it may
--- not, the closest near-miss.
-- @author XEROX710
--
-- THE JOB GATE, UNCHANGED: `{ jobs = { [job] = grade }, onDuty }` through
-- `lib/shared/jobgate.lua` with the default PRIMARY membership -- the worked
-- job, the one that is clocked on -- and a snapshot stamped by the caller at
-- `nowMs`, exactly as the pad adapter above asks it. A row that is not a table
-- closes, for the reason every adapter closes on a subject it cannot read.
-- @param row table|nil a fleet row
-- @param snapshot table|nil { job, jobs, atMs }
-- @param nowMs number
-- @return boolean
-- @return string|nil no_character, job_stale, job_required, grade_too_low, off_duty
function Access.JobVehicleVerdict(row, snapshot, nowMs)
	if type(row) ~= 'table' or type(row.job) ~= 'string' then return false, 'job_required' end
	return OPX.JobGate.Evaluate({ jobs = { [row.job] = row.grade }, onDuty = row.onDuty ~= false },
		snapshot, nowMs, { maxAgeMs = 0 })
end

--- Every fleet row a snapshot may take out at a garage of one kind, in the
--- fleet's order.
-- @author XEROX710
--
-- Only the PRIMARY job's rows are read: a detective hired into MaxTac is
-- MaxTac's while MaxTac is the job they work, which is what the gate says too.
-- `kind` nil is every row of either kind.
-- @param snapshot table|nil { job, jobs, atMs }
-- @param nowMs number
-- @param kind string|nil `garage` or `avpad`
-- @param fleet table|nil a built fleet; the shipped one by default
-- @return table[] rows
function Access.JobFleetFor(snapshot, nowMs, kind, fleet)
	fleet = type(fleet) == 'table' and fleet or Access.JOB_FLEET
	local list = {}
	if type(snapshot) ~= 'table' or type(snapshot.job) ~= 'table' then return list end
	local block = fleet.byJob[snapshot.job.name]
	if type(block) ~= 'table' then return list end
	for index = 1, #block.rows do
		local row = block.rows[index]
		if kind == nil or row.av == (kind == M.KIND.AVPAD) then
			if (Access.JobVehicleVerdict(row, snapshot, nowMs)) then list[#list + 1] = row end
		end
	end
	return list
end

--- The refusal a player reads for one job-vehicle verdict, by the code
-- `lib/shared/jobgate.lua` names. Its own words and not the pad's: a pad
-- refuses a PLACE, and these refuse one vehicle in a list the player can see.
Access.JOB_REFUSAL = {
	no_character = 'garages.noCharacter',
	job_stale = 'garages.noCharacter',
	job_required = 'garages.job.required',
	grade_too_low = 'garages.job.gradeTooLow',
	off_duty = 'garages.job.offDuty',
}

-- Config keys that must be a finite number above zero.
local NUMBERS = { 'USE_RADIUS', 'EXIT_CLEARANCE', 'SCAN_MS', 'POLL_MS', 'COOLDOWN_MS',
	'REQUEST_WINDOW_MS', 'REQUESTS_PER_WINDOW', 'JOB_SWEEP_MS' }

--- Lists every configuration error visible without a world, sorted.
-- @author XEROX710
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

	-- The draw distance and the ground offset are reported against the same
	-- bounds `Access.Marker` and `Access.MaxDistance` clamp to, because they are
	-- literally the same constants.
	OPX.Spots.DrawProblems(Config.MAX_DISTANCE, Config.GROUND_OFFSET, lines)

	OPX.Vehicle.AvLiftProblem(Config.AV_LIFT, lines)

	-- The door's look is reported beside the two kinds, because `Access.Marker`
	-- falls back to the same table for all three and a validator that checked two
	-- of them would hand an operator a silently substituted third.
	for _, slot in ipairs({ M.KIND.GARAGE, M.KIND.AVPAD, M.ROLE.ENTRY }) do
		local declared = type(Config.MARKER) == 'table' and Config.MARKER[slot] or nil
		OPX.Spots.MarkerProblems(declared, 'MARKER.' .. slot, lines)
	end

	-- The garages of BOTH files are validated once at load; the errors are
	-- re-derived here so the diagnostic reports them rather than only the boot
	-- log -- the AV annex's refusals included.
	Access.CoerceAll(Config.GARAGES, avAnnex(), lines)

	-- And the job fleet the same way, row by row, against the character
	-- catalogue's own jobs and grades.
	Access.CoerceJobFleet(Config.JOB_VEHICLES, lines)

	-- A CONFIG THAT STILL CARRIES THE OLD BLOCK IS SAID OUT LOUD. `SPOTS` was
	-- what a garage was before the rework, and a file that still has one is a
	-- file whose garages are all silently missing -- which reads from inside the
	-- game as a server with no markers at all and nothing anywhere saying why.
	if Config.SPOTS ~= nil then
		lines[#lines + 1] = 'SPOTS is no longer read: a garage is a key with LOCATIONS now, ' ..
			'see the header of config/garages.lua'
	end

	local key = type(Config.KEY) == 'table' and Config.KEY or nil
	if key == nil then
		lines[#lines + 1] = 'KEY must be a table of ID, NAME and DEFAULT'
	else
		if type(key.ID) ~= 'string' or key.ID == '' then lines[#lines + 1] = 'KEY.ID must be a string' end
		if type(key.NAME) ~= 'string' or key.NAME == '' then
			lines[#lines + 1] = 'KEY.NAME must be a catalogue key'
		end
		if key.DEFAULT ~= false and (type(key.DEFAULT) ~= 'string' or key.DEFAULT == '') then
			lines[#lines + 1] = 'KEY.DEFAULT must be a key name, or false for no key at all'
		end
	end

	table.sort(lines)
	return lines
end
