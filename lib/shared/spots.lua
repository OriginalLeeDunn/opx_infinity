--- The placed-spot vocabulary: the world box, the marker look and the record.
-- @author dop42
--
-- A PLACED SPOT IS A KEY, A POSITION, A BUCKET AND A LOOK, and this is the one
-- file that decides what one is. Five modules place something an operator writes
-- down as a coordinate and a player walks up to -- `garages`, `dealership`,
-- `clothing`, `teleports` and `elevators` -- and before this file each of them
-- carried its own copy of the same coercions under its own noun.
--
-- WHAT IT REPLACED, AND WHAT THE COPIES WOULD HAVE COST.
-- `modules/garages/shared/access.lua` and `modules/dealership/shared/access.lua`
-- held 334 identical non-blank lines between them, `diff`-clean: `build`,
-- `FromDefinition`, `FromWire`, `Serialise`, `Coerce`, `Spot`, `InBucket`,
-- `FlatDistanceSquared`, `Nearest`, `Marker` and `MaxDistance`, down to the
-- AVPAD-ring-else-cylinder fallback and the 0.06 ground offset.
-- `modules/clothing/shared/access.lua` carried the same record with the two
-- optional fields dropped, and `modules/teleports` and `modules/elevators`
-- carried the coordinate box.
--
-- They agreed on the day they were written, which is the only day copies ever
-- do. A drift in `Marker` is an AV pad drawn as a floor-height ring nobody can
-- see. A drift in the AVPAD fallback lift is an AV spawned half-buried in one
-- module and standing in the other. A drift in `build`'s bucket or key rules is
-- a car you can buy at a dealer and cannot recall at the garage a metre away,
-- because one of the two refused a spot the other accepted. None of those fails
-- at boot; all of them fail in front of a player.
--
-- WHAT IS DELIBERATELY NOT HERE.
--   * The BOUND box was left out of `lib/shared/math.lua` on the argument that
--     "a bound on world space is a policy about a map, and that library knows
--     nothing about one". That reasoning stands and this is the home it named:
--     a map policy, with the spot vocabulary that measures against it.
--   * `modules/gunsmith` publishes `Access.WholeInRange(value, low, high)` and
--     NOT `Access.Integer(value)`, deliberately -- one name for two signatures
--     is a call written from memory against the wrong one, and Lua drops the
--     surplus arguments in silence. It takes `Coordinate` from here and keeps
--     its own ranged helper.
--   * A teleport is a point with TWO ends and a leg, not a spot; an elevator is
--     a shaft with floors. Both take the coordinate box and the marker look from
--     here and keep their own record, because a shared record for four different
--     shapes would be a parameter per difference and no meaning of its own.
--   * The purchase-and-refund half of `dealership` and the bring-out-and-put-
--     away half of `garages` are NOT here and must not come here. They read the
--     same spots; they are not the same concern, and a base class over them is
--     the factoring this file exists to argue against.
--
-- IT IS PURE. No clock, no config read of its own, no module namespace: every
-- policy number a module owns -- its fallback shape, its default draw distance,
-- its use radius -- arrives as an argument, so every branch is reachable from a
-- test with no world and no two modules are forced to share a number they do
-- not actually share.

OPX.Spots = {}

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a yaw and a millisecond clock are
-- measured with this and must not be bounded like a coordinate.
local finiteNumber = OPX.Math.Finite

--- The box every accepted world coordinate fits in, and the `%d` in the message.
OPX.Spots.BOUND = 1000000
local BOUND = OPX.Spots.BOUND

-- The engine's own limits on a marker, named once because `Marker` clamps to
-- them and `MarkerProblems` reports them, and the two saying different numbers
-- would hand an operator a silently substituted default with no warning.
local MIN_RADIUS, MAX_RADIUS = 0.1, 50.0
local MIN_DRAW, MAX_DRAW = 1.0, 500.0
local MAX_GROUND_OFFSET = 2.0

-- The lift a marker gets when the operator has not said. A ring left at floor
-- height is co-planar with the floor and draws nothing at all.
local DEFAULT_GROUND_OFFSET = 0.06

--- Coerces a world coordinate: finite and inside `BOUND`.
-- @author dop42
-- @param value any
-- @return number|nil
function OPX.Spots.Coordinate(value)
	-- INLINE AND NOT THROUGH `finiteNumber`: the bound already refuses both
	-- infinities, so a number only has to be checked for NaN. This runs several
	-- times for every spot on every list a server sends, and the two calls it
	-- saved were most of what one cost.
	if type(value) ~= 'number' then
		value = tonumber(value)
		if value == nil then return nil end
	end
	if value ~= value or value > BOUND or value < -BOUND then return nil end
	return value
end
local coordinate = OPX.Spots.Coordinate

--- Coerces a whole number inside `BOUND`.
-- @author dop42
-- @param value any
-- @return integer|nil
function OPX.Spots.Integer(value)
	local parsed = coordinate(value)
	if parsed == nil or parsed % 1 ~= 0 then return nil end
	return math.floor(parsed)
end
local integer = OPX.Spots.Integer

-- ── the marker look ─────────────────────────────────────────────────────────

--- The engine's own marker vocabulary. A shape outside this set is refused by
--- `Open77.markers` with a status, so picking one here would only move the
--- refusal to a place with less to say about it.
OPX.Spots.SHAPES = { ring = true, cylinder = true }

--- The engine's own marker styles, on the same terms as `SHAPES`.
OPX.Spots.STYLES = { interaction = true, objective = true, spawn = true, danger = true }

local SHAPES, STYLES = OPX.Spots.SHAPES, OPX.Spots.STYLES

--- Resolves one marker's look from what the operator declared.
-- @author dop42
--
-- FALLS BACK PER FIELD AND NOT AS A BLOCK, so a config that names a good shape
-- and a bad style keeps the shape. An operator who mistyped one word should not
-- silently lose the other three.
--
-- The lift is part of the look and not of the spot, so it is decided with the
-- shape that needs it rather than at every call site; 0 is a real choice -- a
-- marker deliberately on the floor -- so only a broken value falls back.
-- @param declared any the operator's block for this kind, or nil
-- @param fallback table { shape, style, RADIUS } this module's own defaults
-- @param groundOffset any the operator's GROUND_OFFSET
-- @return table shape, style, radius, lift
function OPX.Spots.Marker(declared, fallback, groundOffset)
	declared = type(declared) == 'table' and declared or {}

	local shape = type(declared.shape) == 'string' and declared.shape:lower() or fallback.shape
	if not SHAPES[shape] then shape = fallback.shape end
	local style = type(declared.style) == 'string' and declared.style:lower() or fallback.style
	if not STYLES[style] then style = fallback.style end

	local radius = finiteNumber(declared.RADIUS)
	if radius == nil or radius < MIN_RADIUS or radius > MAX_RADIUS then radius = fallback.RADIUS end

	local lift = finiteNumber(groundOffset)
	if lift == nil or lift < 0.0 or lift > MAX_GROUND_OFFSET then lift = DEFAULT_GROUND_OFFSET end

	return { shape = shape, style = style, radius = radius, lift = lift }
end

--- How far away a marker is still drawn, clamped to what the engine accepts.
-- @author dop42
-- @param value any the operator's MAX_DISTANCE
-- @param fallback number this module's own default, in metres
-- @return number
function OPX.Spots.MaxDistance(value, fallback)
	local distance = finiteNumber(value)
	if distance == nil or distance < MIN_DRAW or distance > MAX_DRAW then return fallback end
	return distance
end

--- Appends every fault in one MARKER block, in the operator's own spelling.
-- @author dop42
--
-- `label` is what the operator called the block, so a module with one marker
-- reports `MARKER.shape` and a module with one per kind reports
-- `MARKER.avpad.shape`. The bounds are the same constants `Marker` clamps to:
-- a validator that accepted a radius the resolver then replaced would be a
-- default substituted with no warning at all, which is the failure this whole
-- diagnostic exists to prevent.
-- @param declared any
-- @param label string 'MARKER', or 'MARKER.<kind>'
-- @param lines string[] collector, appended to
-- @return string[] the same collector
function OPX.Spots.MarkerProblems(declared, label, lines)
	if type(declared) ~= 'table' then
		lines[#lines + 1] = label .. ' must be a table of shape, style and RADIUS'
		return lines
	end

	local shape = type(declared.shape) == 'string' and declared.shape:lower() or nil
	if shape ~= nil and not SHAPES[shape] then
		lines[#lines + 1] = label .. '.shape must be ring or cylinder'
	end
	local style = type(declared.style) == 'string' and declared.style:lower() or nil
	if style ~= nil and not STYLES[style] then
		lines[#lines + 1] = label .. '.style must be interaction, objective, spawn or danger'
	end
	local radius = finiteNumber(declared.RADIUS)
	if radius == nil or radius < MIN_RADIUS or radius > MAX_RADIUS then
		lines[#lines + 1] = label .. '.RADIUS must be a finite number, 0.1 to 50'
	end
	return lines
end

--- Appends the two faults every drawn module reports the same way.
-- @author dop42
-- @param maxDistance any the operator's MAX_DISTANCE
-- @param groundOffset any the operator's GROUND_OFFSET
-- @param lines string[] collector, appended to
-- @return string[] the same collector
function OPX.Spots.DrawProblems(maxDistance, groundOffset, lines)
	local distance = finiteNumber(maxDistance)
	if distance == nil or distance < MIN_DRAW or distance > MAX_DRAW then
		lines[#lines + 1] = 'MAX_DISTANCE must be a finite number, 1 to 500 metres'
	end
	local lift = finiteNumber(groundOffset)
	if lift == nil or lift < 0.0 or lift > MAX_GROUND_OFFSET then
		lines[#lines + 1] = 'GROUND_OFFSET must be a finite number, 0 to 2 metres'
	end
	return lines
end

-- ── the record ──────────────────────────────────────────────────────────────

-- A SPEC IS THE THINGS A MODULE'S SPOTS DIFFER BY, and nothing else:
--
--   noun      what one is called in a refusal an operator reads -- 'spot',
--             'dealer', 'store'. It is the module's word, not this file's.
--   maxKey    the largest key, which is also the database column width.
--   kinds     the set of legal KINDs, or nil when the module has one category.
--             `clothing` has one kind of store, so a store has no `kind` field
--             at all rather than a constant one nobody reads.
--   kindNames those kinds as an operator reads them, for the refusal.
--   heading   whether a facing is part of the record. A garage spot is created
--             at, so it has one; a store is only stood in front of, so it does
--             not -- and a heading defaulted to zero on a record nothing turns
--             is a field a later author will wire up by mistake.
--
-- Anything else that differs between two modules is NOT a spec key: it is a
-- reason those two modules do not share this record.

--- Builds one validated spot, or answers why it was refused.
--
-- EVERY VALUE IS COERCED AND NEVER TRUSTED. A coordinate that is a string, a
-- NaN, an unknown KIND or a negative bucket reads as a refusal here -- which
-- the caller turns into a boot warning -- rather than as a raise inside a scan
-- or a network handler, where it would take the whole loop down.
-- @param spec table
-- @param key any
-- @param kind any
-- @param label any
-- @param x any
-- @param y any
-- @param z any
-- @param heading any
-- @param bucket any
-- @return table|nil
-- @return string|nil
local function build(spec, key, kind, label, x, y, z, heading, bucket)
	if type(key) ~= 'string' or key == '' or #key > spec.maxKey then
		return nil, 'key must be a string of 1 to ' .. spec.maxKey .. ' characters'
	end
	if spec.kinds ~= nil then
		if type(kind) ~= 'string' or not spec.kinds[kind:lower()] then
			return nil, ('%s: KIND must be one of %s'):format(key, spec.kindNames)
		end
	end
	x, y, z = coordinate(x), coordinate(y), coordinate(z)
	if x == nil or y == nil or z == nil then
		return nil, ('%s: X, Y and Z must be finite numbers inside %d'):format(key, BOUND)
	end
	local headingNumber
	if spec.heading then
		headingNumber = heading == nil and 0.0 or finiteNumber(heading)
		if headingNumber == nil then
			return nil, ('%s: HEADING must be a finite number'):format(key)
		end
	end
	local bucketNumber = bucket == nil and 0 or integer(bucket)
	if bucketNumber == nil or bucketNumber < 0 then
		return nil, ('%s: BUCKET must be a whole number, 0 or more'):format(key)
	end
	if label ~= nil and type(label) ~= 'string' then
		return nil, ('%s: LABEL must be a string'):format(key)
	end
	return {
		key = key,
		label = (type(label) == 'string' and label ~= '') and label or key,
		kind = spec.kinds ~= nil and kind:lower() or nil,
		x = x,
		y = y,
		z = z,
		heading = headingNumber,
		bucket = bucketNumber,
	}
end

--- Normalises one config or database row, in the operator's upper-case spelling.
-- @author dop42
--
-- A SEPARATE FUNCTION FROM `FromWire` ON PURPOSE. A DEFINITION is what an
-- operator writes in a config file and what a captured row holds in the
-- database: upper-case fields. A WIRE spot is what the server sends a client,
-- already normalised and lower-case. Each is validated on its own terms and
-- both end in the one `build`, so there is one place that decides what a spot
-- is and one place that decides whether one is usable.
-- @param spec table
-- @param key any
-- @param raw any
-- @return table|nil
-- @return string|nil
function OPX.Spots.FromDefinition(spec, key, raw)
	if type(raw) ~= 'table' then
		return nil, tostring(key) .. ': every ' .. spec.noun .. ' must be a table'
	end
	return build(spec, key, raw.KIND, raw.LABEL, raw.X, raw.Y, raw.Z, raw.HEADING, raw.BUCKET)
end

--- Normalises one spot off the wire, in the shape `Serialise` writes.
-- @author dop42
-- @param spec table
-- @param raw any
-- @return table|nil
-- @return string|nil
function OPX.Spots.FromWire(spec, raw)
	if type(raw) ~= 'table' then return nil, 'every ' .. spec.noun .. ' must be a table' end
	return build(spec, raw.key, raw.kind, raw.label, raw.x, raw.y, raw.z, raw.heading, raw.bucket)
end

--- The fields of one spot, as the wire and the SYNC event carry them.
-- A module whose spec has no kind and no heading carries neither: the fields
-- are nil on the record, so they are absent from the table rather than sent as
-- a constant nobody reads.
-- @author dop42
-- @param spot table
-- @return table
function OPX.Spots.Serialise(spot)
	return {
		key = spot.key, label = spot.label, kind = spot.kind,
		x = spot.x, y = spot.y, z = spot.z,
		heading = spot.heading, bucket = spot.bucket,
	}
end

--- Builds a key -> spot table from a block of definitions.
-- @author dop42
-- @param spec table
-- @param definitions any map of key -> row
-- @param problems table|nil collector, appended to
-- @return table
function OPX.Spots.Coerce(spec, definitions, problems)
	local spots = {}
	if type(definitions) ~= 'table' then
		if problems ~= nil then
			problems[#problems + 1] = 'SPOTS must be a table of key -> definition'
		end
		return spots
	end
	for key, raw in pairs(definitions) do
		local spot, why = OPX.Spots.FromDefinition(spec, key, raw)
		if spot == nil then
			if problems ~= nil then problems[#problems + 1] = why end
		else
			spots[key] = spot
		end
	end
	return spots
end

--- Answers one spot by key, or nil. The key is matched exactly.
-- @author dop42
-- @param spots table
-- @param key any
-- @return table|nil
function OPX.Spots.Spot(spots, key)
	if type(key) ~= 'string' then return nil end
	return spots[key]
end

--- Every spot in a bucket, sorted by key.
-- Sorted because `pairs` order would reshuffle a listing, a SYNC payload and a
-- determinism check between runs.
-- @author dop42
-- @param spots table
-- @param bucket integer
-- @return table[] array of spots
function OPX.Spots.InBucket(spots, bucket)
	local list = {}
	for _, spot in pairs(spots) do
		if spot.bucket == bucket then list[#list + 1] = spot end
	end
	table.sort(list, function(left, right) return left.key < right.key end)
	return list
end

--- Squared horizontal distance from a point to a spot's declared position.
-- Only X and Y are ever measured against; Z is validated and then carried to
-- the create call.
-- @author dop42
-- @param spot table
-- @param x any
-- @param y any
-- @return number|nil
function OPX.Spots.FlatDistanceSquared(spot, x, y)
	x, y = coordinate(x), coordinate(y)
	if spot == nil or x == nil or y == nil then return nil end
	local dx, dy = x - spot.x, y - spot.y
	return dx * dx + dy * dy
end

--- The squared reach the SERVER allows for a radius the client draws: the radius
--- plus `OPX.Config.SHARED.REACH_SLACK`, for the latency between the press and
--- the position the server last observed. See `config/shared.lua`.
-- @author dop42
-- @param radius number metres, as the module's own USE_RADIUS
-- @return number squared metres
function OPX.Spots.ServerReachSq(radius)
	local reach = OPX.Spots.ServerReach(radius)
	return reach * reach
end

--- The reach the SERVER allows, in metres, for a radius the client draws or the
--- eye row offers: the radius plus `OPX.Config.SHARED.REACH_SLACK`.
-- @author dop42
-- @param radius number metres
-- @return number metres
function OPX.Spots.ServerReach(radius)
	local shared = OPX.Config and OPX.Config.SHARED
	local slack = type(shared) == 'table' and shared.REACH_SLACK or nil
	if type(slack) ~= 'number' or slack ~= slack then slack = 1.0 end
	if slack < 0 then slack = 0 elseif slack > 4 then slack = 4 end
	return (type(radius) == 'number' and radius == radius and radius or 0) + slack
end

--- Answers the spot a point stands on, or nil.
-- The nearest wins; at equal distance the key decides, so `pairs` order never
-- chooses between two markers a metre apart.
-- @author dop42
-- @param spots table
-- @param x any
-- @param y any
-- @param radiusSq number the squared radius; the caller's, because the radius
--   is a number the module owns and not one this file may choose
-- @return table|nil
-- @return number|nil squared distance
--
-- THE POINT IS COERCED ONCE, NOT ONCE PER SPOT. This runs every scan of every
-- spot module over the whole list, and `FlatDistanceSquared` re-coerced the
-- player's position for each spot: ~85 VM instructions a spot, in a scheduler
-- pass that shares one resume's budget (~10,000) with other jobs.
function OPX.Spots.Nearest(spots, x, y, radiusSq)
	-- THE POSITION IS COERCED ONCE, NOT ONCE PER SPOT. This runs on every scan of
	-- every marker module, and on a client every resume is on a clock checked
	-- each 10,000 VM instructions: two coercions per spot made it ~100
	-- instructions a spot, most of the budget of a scan over a long list. The
	-- answer is the same -- the spots were coerced when they were read in.
	x, y = coordinate(x), coordinate(y)
	if x == nil or y == nil then return nil, nil end
	local best, bestDistance
	for _, spot in pairs(spots) do
		local dx, dy = x - spot.x, y - spot.y
		local flat = dx * dx + dy * dy
		if flat <= radiusSq and
			(bestDistance == nil or flat < bestDistance or
				(flat == bestDistance and spot.key < best.key)) then
			best, bestDistance = spot, flat
		end
	end
	return best, bestDistance
end
