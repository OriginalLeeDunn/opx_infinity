--- Config reads, coercions and the decisions both halves share.
-- @author XEROX710
--
-- Two vocabularies live here and they are deliberately separate things. A SPOT
-- is a place: where a dealer stands, which category it sells, and how it is
-- drawn. A STOCK ROW is a thing for sale: a name, a class, a TweakDB record and
-- a price. A purchase names one of each, and the server proves both again.
--
-- THE SPOT HALF IS NOT WRITTEN HERE. The record, the two input shapes that
-- normalise into it, the marker look and the coordinate box are all
-- `lib/shared/spots.lua`, and this file only names this module's own words to
-- them. `modules/garages/shared/access.lua` held 334 `diff`-clean identical
-- lines of it, and the two must agree exactly: a car bought at a dealer is
-- recalled at a garage, and a spot one of them accepts and the other refuses is
-- a car that exists nowhere.
--
-- THE STOCK HALF IS, and stays. What is for sale, at what price, and which kind
-- of dealer sells it is this module's own question -- no other module asks it --
-- and a shared catalogue would be a shape with one user.
--
-- Every value is coerced and never trusted: a coordinate that is a string, a
-- NaN, an unknown KIND or a price that is not a whole number above zero reads
-- as a warning at boot rather than a raise inside a scan, a menu or a purchase.

local M = OPX.Modules.Get('dealership')

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

--- The largest allowed spot key, which is also the column width.
Access.MAX_KEY = 48

-- The largest record and the longest text a stock row may carry. Both are
-- refused here rather than at the vehicles contract, which caps a record too.
local MAX_RECORD = 256
local MAX_STOCK_LABEL = 64
local MAX_CLASS = 32

-- ── spots ───────────────────────────────────────────────────────────────────

-- This module's words for the shared record: a dealer has a KIND, because a
-- showroom and an AV pad sell different halves of the catalogue, and a HEADING,
-- because a bought vehicle is CREATED at one and something has to say which way
-- it faces.
local SPEC = {
	noun = 'dealer',
	maxKey = Access.MAX_KEY,
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
	return OPX.Spots.FromDefinition(SPEC, key, raw)
end

--- Normalises one spot off the wire, in the shape `Access.Serialise` writes.
-- @author XEROX710
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWire(raw)
	return OPX.Spots.FromWire(SPEC, raw)
end

--- The fields of one spot, as the wire and the SYNC event carry them.
-- @author XEROX710
-- @param spot table
-- @return table
Access.Serialise = OPX.Spots.Serialise

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
-- `OPX.Config.SHARED.AV_PREFIXES`. The comment that used to sit here claimed
-- this WAS the rule the garages module uses; it was a second copy over a second
-- key, and the admin catalogue had a third that behaved differently again. It is
-- one rule now, which is what makes a record air for every part of the server or
-- for none of it.
-- @author XEROX710
-- @param record any
-- @return boolean
function Access.IsAv(record)
	return OPX.Vehicle.IsAvRecord(record)
end

-- What a marker falls back to per kind when the operator named nothing usable. A
-- pad is a RING, because an AV lands inside it and a filled cylinder would be
-- drawn through the hull; a showroom is a cylinder you walk into.
local FALLBACK = {
	[M.KIND.AVPAD] = { shape = 'ring', style = 'objective', RADIUS = 3.5 },
	[M.KIND.GARAGE] = { shape = 'cylinder', style = 'spawn', RADIUS = 2.5 },
}

--- The marker an engine spot of this kind is drawn with.
-- The per-field fallback and the ground lift are `lib/shared/spots.lua`; the two
-- shapes below are this module's own choice and stay here.
-- @author XEROX710
-- @param kind string
-- @return table shape, style, radius, lift
function Access.Marker(kind)
	local declared = type(Config.MARKER) == 'table' and Config.MARKER[kind] or nil
	local fallback = kind == M.KIND.AVPAD and FALLBACK[M.KIND.AVPAD] or FALLBACK[M.KIND.GARAGE]
	return OPX.Spots.Marker(declared, fallback, Config.GROUND_OFFSET)
end

--- The AV lift, clamped to something a chassis will not fall through.
-- The rule is `lib/shared/vehicle.lua`, beside the one that says whether a
-- record is an AV at all: the staff spawner had a third copy with no bound.
-- @author XEROX710
-- @return number
function Access.AvLift()
	return OPX.Vehicle.AvLift(Config.AV_LIFT)
end

--- How far away a marker is still drawn, clamped to what the engine accepts.
-- @author XEROX710
-- @return number
function Access.MaxDistance()
	return OPX.Spots.MaxDistance(Config.MAX_DISTANCE, 150.0)
end

-- The distances and cadences, read once. A value `Problems` refuses reads as
-- zero here, so a bad one becomes a boot warning rather than a raise.
local USE_RADIUS = finiteNumber(Config.USE_RADIUS) or 0
Access.USE_RADIUS = USE_RADIUS
Access.USE_RADIUS_SQ = USE_RADIUS * USE_RADIUS
Access.SCAN_MS = math.floor(finiteNumber(Config.SCAN_MS) or 0)
Access.POLL_MS = math.floor(finiteNumber(Config.POLL_MS) or 0)
Access.COOLDOWN_MS = math.floor(finiteNumber(Config.COOLDOWN_MS) or 0)
Access.REQUEST_WINDOW_MS = math.floor(finiteNumber(Config.REQUEST_WINDOW_MS) or 0)
Access.REQUESTS_PER_WINDOW = math.floor(finiteNumber(Config.REQUESTS_PER_WINDOW) or 0)

--- The configured dealers, already validated.
-- Read as empty rather than refused: every read is reachable from the contract.
-- @author XEROX710
Access.SPOTS = Access.Coerce(Config.SPOTS, nil)

-- ── preview points ──────────────────────────────────────────────────────────

-- A PREVIEW IS NOT A DEALER, and it has its own spec for exactly two
-- differences. It has no KIND -- what it shows is decided by the stock row it
-- names, and a preview whose kind disagreed with its own model would be a
-- showroom car nobody can buy. And its noun is its own, so a refusal an operator
-- reads says "preview" rather than "dealer" about a thing they placed from a
-- different menu.
--
-- It keeps the HEADING, because a showroom car parked at zero degrees faces
-- whichever way the map was built rather than the way the floor is laid out.
local PREVIEW_SPEC = {
	noun = 'preview',
	maxKey = Access.MAX_KEY,
	kinds = nil,
	heading = true,
}

--- Normalises one preview point, in the operator's upper-case spelling.
-- @author XEROX710
-- @param key any
-- @param raw any
-- @return table|nil
-- @return string|nil
function Access.PreviewFromDefinition(key, raw)
	local spot, why = OPX.Spots.FromDefinition(PREVIEW_SPEC, key, raw)
	if spot == nil then return nil, why end
	return Access.AttachPreview(spot, raw)
end

--- Hangs the two fields the shared record knows nothing about onto a preview.
-- @author XEROX710
--
-- WHICH DEALER'S FLOOR IT STANDS ON and WHICH MODEL IS STANDING ON IT. Neither
-- belongs in `lib/shared/spots.lua`: five modules share that record and none of
-- the other four has a catalogue to point at.
--
-- Both are REQUIRED, and a preview missing either is refused rather than
-- defaulted. A preview with no entry would be an empty parking space that
-- nothing can ever be put on; a preview with no dealer would be a car standing
-- in a field that no zone ever cleans up.
-- @param spot table
-- @param raw table
-- @return table|nil
-- @return string|nil
function Access.AttachPreview(spot, raw)
	raw = type(raw) == 'table' and raw or {}
	local dealer = raw.DEALER or raw.dealer
	local entry = raw.ENTRY or raw.entry
	if type(dealer) ~= 'string' or dealer == '' or #dealer > Access.MAX_KEY then
		return nil, ('%s: DEALER must name a dealer'):format(spot.key)
	end
	if type(entry) ~= 'string' or entry == '' or #entry > Access.MAX_KEY then
		return nil, ('%s: ENTRY must name a stock row'):format(spot.key)
	end
	spot.dealer = dealer
	spot.entry = entry
	return spot
end

--- Builds a key -> preview table from a block of `PREVIEW.POINTS` definitions.
-- @author XEROX710
--
-- THE SAME JOB `Access.Coerce` DOES FOR DEALERS, and written out rather than
-- handed to `OPX.Spots.Coerce` for one reason: a preview is a shared spot record
-- PLUS two fields the shared record knows nothing about, and `Coerce` stops at
-- the shared half. A point that passed the coordinate check and then named no
-- dealer would be accepted here and refused at the moment a car had to stand on
-- it, which is a config error found at the wrong end of the day.
--
-- `nil` is an empty showroom and NOT a problem: a server with no preview points
-- is a server whose dealers are counters rather than halls, which is the
-- ordinary case. Anything that is not nil and not a table IS reported.
-- @param definitions any map of key -> row
-- @param problems table|nil collector, appended to
-- @return table
function Access.CoercePreviews(definitions, problems)
	local points = {}
	if definitions == nil then return points end
	if type(definitions) ~= 'table' then
		if problems ~= nil then
			problems[#problems + 1] = 'PREVIEW.POINTS must be a table of key -> definition'
		end
		return points
	end
	for key, raw in pairs(definitions) do
		local spot, why = Access.PreviewFromDefinition(key, raw)
		if spot == nil then
			if problems ~= nil then problems[#problems + 1] = 'PREVIEW.POINTS.' .. tostring(why) end
		else
			points[spot.key] = spot
		end
	end
	return points
end

--- The configured showroom, already validated.
-- @author XEROX710
--
-- THIS IS WHERE A SHOWROOM CAR LIVES NOW. It used to live in
-- `opx77_dealership_previews`, written there by the staff menu's Dev screen,
-- and the owner deleted that screen on 2026-09-21 ("il y a pas de config live
-- c'est tous par les fichier config"). The database is still READ at boot -- a
-- car an operator placed before this version is adopted and printed back as the
-- config line that recreates it -- but nothing writes to it from a menu, and a
-- point named here SHADOWS an adopted row of the same key. Config wins, always:
-- the file is the copy somebody has.
Access.PREVIEW_POINTS = Access.CoercePreviews(
	type(Config.PREVIEW) == 'table' and Config.PREVIEW.POINTS or nil, nil)

-- How many previews one dealer's floor may hold. Every one of them is a network
-- vehicle that never despawns, so this is a frame budget and not a taste.
Access.PREVIEW_LIMIT = math.floor(
	finiteNumber(type(Config.PREVIEW) == 'table' and Config.PREVIEW.LIMIT or nil) or 0)

--- Whether the showroom is dressed at all.
-- @author XEROX710
-- @return boolean
function Access.PreviewsEnabled()
	local block = type(Config.PREVIEW) == 'table' and Config.PREVIEW or nil
	return block ~= nil and block.ENABLED ~= false
end

--- Whether a preview is created locked.
-- @author XEROX710
-- @return boolean
function Access.PreviewLocked()
	local block = type(Config.PREVIEW) == 'table' and Config.PREVIEW or nil
	return block == nil or block.LOCKED ~= false
end

--- Metres a preview is lifted off its declared Z, clamped to something a chassis
--- neither rests inside nor falls out of.
-- @author XEROX710
-- @return number
function Access.PreviewLift()
	local block = type(Config.PREVIEW) == 'table' and Config.PREVIEW or nil
	local lift = finiteNumber(block ~= nil and block.LIFT or nil)
	if lift == nil or lift < 0.0 or lift > 2.0 then return 0.1 end
	return lift
end

-- ── the zone, the offer and the money ───────────────────────────────────────

-- Flat metres from a dealer inside which the eye grows a row on other players,
-- squared once because every test against it is a squared comparison.
local ZONE_RADIUS = finiteNumber(Config.ZONE_RADIUS) or 0
Access.ZONE_RADIUS = ZONE_RADIUS
Access.ZONE_RADIUS_SQ = ZONE_RADIUS * ZONE_RADIUS

Access.OFFER_TIMEOUT_MS = math.floor(finiteNumber(Config.OFFER_TIMEOUT_MS) or 0)

-- `Access.PlacementRight` stood here and named the ACL right that gated placing
-- a preview point. Both it and the right went when the write path did.

--- What the seller is paid out of a sale, and what the company banks.
-- @author XEROX710
--
-- ROUNDED DOWN TO THE SELLER AND THE REMAINDER TO THE COMPANY. The other way
-- round mints a unit of currency on every odd price, which over a shift is a
-- company account that grows without anybody buying anything.
--
-- The percentage is clamped rather than refused: 0 is a company that pays no
-- commission, 100 is one that keeps nothing, and a number outside that is an
-- operator's typo -- which must not become a negative deposit.
-- @param price number
-- @return integer the seller's cut
-- @return integer what the company banks
function Access.Split(price)
	local total = finiteNumber(price)
	if total == nil or total <= 0 then return 0, 0 end
	total = math.floor(total)
	local percent = finiteNumber(Config.SELLER_CUT_PERCENT) or 0
	if percent < 0 then percent = 0 elseif percent > 100 then percent = 100 end
	local cut = math.floor(total * percent / 100)
	if cut > total then cut = total end
	return cut, total - cut
end

--- The company a seller sells for: their job, or their gang, or neither.
-- @author XEROX710
--
-- THE JOB WINS. A gang member with a day job sells for the day job, because that
-- is the company the customer believes they are buying from. `EXCLUDED` names
-- the entries that are the ABSENCE of a group -- `unemployed` and `none` are
-- rows in `config/character.lua` rather than nils, precisely so nothing has to
-- handle nil, and an account for either would be one account every player on the
-- server pays into and nobody can be the boss of.
-- @param job any the job name
-- @param gang any the gang name
-- @return string|nil 'job' or 'gang'
-- @return string|nil the group name
function Access.CompanyOf(job, gang)
	local block = type(Config.COMPANY) == 'table' and Config.COMPANY or {}
	local excluded = type(block.EXCLUDED) == 'table' and block.EXCLUDED or {}
	if block.JOBS ~= false and type(job) == 'string' and job ~= '' and not excluded[job] then
		return 'job', job
	end
	if block.GANGS ~= false and type(gang) == 'string' and gang ~= '' and not excluded[gang] then
		return 'gang', gang
	end
	return nil, nil
end

-- ── the stock ───────────────────────────────────────────────────────────────

--- Builds the catalogue from config, naming every row it refused.
-- @author XEROX710
--
-- A ROW IS REFUSED WHOLE, never repaired: a car the operator priced at nothing,
-- or one whose record is empty, is a row that would sell something nobody meant
-- to sell. Whether a row is a vehicle or an AV is DERIVED from its record, so a
-- row cannot disagree with itself about which category it is in.
-- @param problems table|nil collector, appended to
-- @return table key -> entry
local function stock(problems)
	local listed = {}
	local rows = Config.STOCK
	local function refuse(line)
		if problems ~= nil then problems[#problems + 1] = line end
	end

	if type(rows) ~= 'table' then
		refuse('STOCK must be an array of KEY, LABEL, CLASS, RECORD and PRICE')
		return listed
	end

	for index = 1, #rows do
		local raw = rows[index]
		local where = ('STOCK[%d]'):format(index)
		if type(raw) ~= 'table' then
			refuse(where .. ': every row must be a table')
		else
			local key = raw.KEY
			local price = finiteNumber(raw.PRICE)
			if type(key) ~= 'string' or key == '' or #key > Access.MAX_KEY then
				refuse(where .. ': KEY must be a string of 1 to ' .. Access.MAX_KEY .. ' characters')
			elseif listed[key] ~= nil then
				refuse(where .. ': KEY ' .. key .. ' is declared twice')
			elseif type(raw.RECORD) ~= 'string' or raw.RECORD == '' or #raw.RECORD > MAX_RECORD then
				refuse(where .. ' (' .. key .. '): RECORD must be a TweakDB record name')
			elseif price == nil or price <= 0 or price % 1 ~= 0 then
				-- Zero is refused and not honoured: a free car is a stock-list
				-- mistake, and honouring it hands out something nobody meant to
				-- give away.
				refuse(where .. ' (' .. key .. '): PRICE must be a whole number above zero')
			elseif type(raw.LABEL) ~= 'string' or raw.LABEL == '' or #raw.LABEL > MAX_STOCK_LABEL then
				refuse(where .. ' (' .. key .. '): LABEL must be a string of 1 to ' .. MAX_STOCK_LABEL .. ' characters')
			elseif type(raw.CLASS) ~= 'string' or raw.CLASS == '' or #raw.CLASS > MAX_CLASS then
				refuse(where .. ' (' .. key .. '): CLASS must be a string of 1 to ' .. MAX_CLASS .. ' characters')
			else
				listed[key] = {
					key = key,
					label = raw.LABEL,
					class = raw.CLASS,
					record = raw.RECORD,
					price = price,
					av = Access.IsAv(raw.RECORD),
				}
			end
		end
	end
	return listed
end

--- Everything for sale, by key.
-- Read as empty rather than refused: every read is reachable from the contract.
-- @author XEROX710
Access.STOCK = stock(nil)

--- Answers one stock row by key, or nil. The key is matched exactly.
-- @author XEROX710
-- @param key any
-- @return table|nil
function Access.Entry(key)
	if type(key) ~= 'string' then return nil end
	return Access.STOCK[key]
end

--- Whether a dealer of this kind may sell this entry.
-- The one rule that decides it: a `garage` dealer sells ground vehicles, an
-- `avpad` dealer sells AVs, and the entry's own record is what says which it is.
-- @author XEROX710
-- @param kind string
-- @param entry table|nil
-- @return boolean
function Access.SoldHere(kind, entry)
	if kind ~= M.KIND.GARAGE and kind ~= M.KIND.AVPAD then return false end
	if type(entry) ~= 'table' then return false end
	return (kind == M.KIND.AVPAD) == (entry.av == true)
end

--- What one dealer sells, sorted by class and then by name.
-- Sorted for the same reason a spot list is: `pairs` order would reshuffle the
-- menu between two opens and a determinism check between two runs.
-- @author XEROX710
-- @param kind string
-- @return table[] array of entries
function Access.For(kind)
	local list = {}
	for _, entry in pairs(Access.STOCK) do
		if Access.SoldHere(kind, entry) then list[#list + 1] = entry end
	end
	table.sort(list, function(left, right)
		if left.class ~= right.class then return left.class < right.class end
		if left.label ~= right.label then return left.label < right.label end
		return left.key < right.key
	end)
	return list
end

--- Normalises one stock row off the wire.
-- The client draws what it is sent and re-checks the shape rather than trusting
-- it: a row with no key or an unreadable price is dropped, so a malformed
-- catalogue costs one row and not the whole list.
-- @author XEROX710
-- @param raw table|nil
-- @return table|nil
-- @return string|nil
function Access.FromWireRow(raw)
	if type(raw) ~= 'table' then return nil, 'every row must be a table' end
	if type(raw.key) ~= 'string' or raw.key == '' or #raw.key > Access.MAX_KEY then
		return nil, 'a row key must be a string of 1 to ' .. Access.MAX_KEY .. ' characters'
	end
	if type(raw.label) ~= 'string' or raw.label == '' or #raw.label > MAX_STOCK_LABEL then
		return nil, ('%s: LABEL must be a string of 1 to %d characters'):format(raw.key, MAX_STOCK_LABEL)
	end
	local price = finiteNumber(raw.price)
	if price == nil or price <= 0 then
		return nil, ('%s: PRICE must be a number above zero'):format(raw.key)
	end
	return {
		key = raw.key,
		label = raw.label,
		class = type(raw.class) == 'string' and raw.class or '',
		price = price,
		-- What the row shows in the affordance column. The server formats it and
		-- this is a display string only: the price above is what a purchase is
		-- checked against, on the server.
		text = type(raw.text) == 'string' and raw.text or tostring(price),
	}
end

--- One stock row as the client reads it, with the price already formatted.
-- The SERVER formats it: it owns the currency table and the grouping rule, and a
-- client that formatted its own would be a second answer to the same question.
-- @author XEROX710
-- @param entry table
-- @param text string the formatted price
-- @return table
function Access.Wire(entry, text)
	return {
		key = entry.key,
		label = entry.label,
		class = entry.class,
		price = entry.price,
		text = text,
	}
end

-- ── the configuration, read back ────────────────────────────────────────────

-- Config keys that must be a finite number above zero.
local NUMBERS = { 'USE_RADIUS', 'ZONE_RADIUS', 'SCAN_MS', 'POLL_MS', 'COOLDOWN_MS',
	'REQUEST_WINDOW_MS', 'REQUESTS_PER_WINDOW', 'OFFER_TIMEOUT_MS' }

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

	-- An empty stock is not an error -- an operator may be between suppliers --
	-- but a row that was refused is.
	stock(lines)

	if type(Config.STOCK) == 'table' then
		local total = OPX.Table.Count(Access.STOCK)
		if total > 0 and #Access.For(M.KIND.GARAGE) + #Access.For(M.KIND.AVPAD) == 0 then
			lines[#lines + 1] = 'STOCK has rows but no dealer kind can sell any of them'
		end
	end

	for _, kind in ipairs({ M.KIND.GARAGE, M.KIND.AVPAD }) do
		local declared = type(Config.MARKER) == 'table' and Config.MARKER[kind] or nil
		OPX.Spots.MarkerProblems(declared, 'MARKER.' .. kind, lines)
	end

	-- SPOTS are validated once at load; the errors are re-derived here so the
	-- diagnostic reports them rather than only the boot log.
	Access.Coerce(Config.SPOTS, lines)

	-- THE ZONE HAS TO CONTAIN THE MARKER. A zone smaller than the radius a
	-- dealer is USED at would grow the salesperson's row on players who are
	-- already too far to buy anything, and take it away from one standing on the
	-- marker -- which reads from inside the game as an eye that works everywhere
	-- except at the counter.
	if (finiteNumber(Config.ZONE_RADIUS) or 0) > 0 and
		(finiteNumber(Config.ZONE_RADIUS) or 0) < (finiteNumber(Config.USE_RADIUS) or 0) then
		lines[#lines + 1] = 'ZONE_RADIUS must be at least USE_RADIUS: the zone has to contain ' ..
			'the marker it is drawn around'
	end

	local percent = finiteNumber(Config.SELLER_CUT_PERCENT)
	if percent == nil or percent < 0 or percent > 100 then
		lines[#lines + 1] = 'SELLER_CUT_PERCENT must be a number from 0 to 100'
	end


	local preview = Config.PREVIEW
	if preview ~= nil and type(preview) ~= 'table' then
		lines[#lines + 1] = 'PREVIEW must be a table of ENABLED, LIMIT, LOCKED and LIFT'
	elseif type(preview) == 'table' then
		local limit = finiteNumber(preview.LIMIT)
		if limit == nil or limit < 1 or limit % 1 ~= 0 then
			lines[#lines + 1] = 'PREVIEW.LIMIT must be a whole number of showroom cars, 1 or more'
		end
		local lift = finiteNumber(preview.LIFT)
		if lift == nil or lift < 0.0 or lift > 2.0 then
			lines[#lines + 1] = 'PREVIEW.LIFT must be a finite number, 0 to 2 metres'
		end

		-- THE SHOWROOM ITSELF, validated at load exactly as SPOTS is. The errors
		-- are re-derived here rather than kept from the load, so the diagnostic
		-- reports them and not only the boot log.
		local points = Access.CoercePreviews(preview.POINTS, lines)

		-- AND WHAT EACH POINT NAMES. ENTRY is checked because the stock list is
		-- ENTIRELY config: a point naming a row that is not in it can never
		-- stand a car up, on this start or any other, so it is a config error
		-- and not a runtime one. DEALER is deliberately NOT checked here -- a
		-- dealer may still be adopted out of `opx77_dealerships` at boot, which
		-- happens long after this file loads, so a name that is missing now may
		-- be there in a second. The server says so per car when it dresses the
		-- floor, which is the moment it is actually knowable.
		local ordered = {}
		for key in pairs(points) do ordered[#ordered + 1] = key end
		table.sort(ordered)
		for _, key in ipairs(ordered) do
			local point = points[key]
			if Access.STOCK[point.entry] == nil then
				lines[#lines + 1] = ('PREVIEW.POINTS.%s: ENTRY names %q, which is not a KEY in ' ..
					'STOCK; nothing can ever stand on it'):format(key, point.entry)
			end
		end

		-- A SHOWROOM BIGGER THAN ITS OWN LIMIT is a config that refuses half of
		-- itself at boot with a line per car. Counted per dealer, because the
		-- limit is per floor.
		local perDealer = {}
		for _, point in pairs(points) do
			perDealer[point.dealer] = (perDealer[point.dealer] or 0) + 1
		end
		local dealers = {}
		for dealer in pairs(perDealer) do dealers[#dealers + 1] = dealer end
		table.sort(dealers)
		for _, dealer in ipairs(dealers) do
			if Access.PREVIEW_LIMIT > 0 and perDealer[dealer] > Access.PREVIEW_LIMIT then
				lines[#lines + 1] = ('PREVIEW.POINTS: %d point(s) name the dealer %q, which is ' ..
					'more than PREVIEW.LIMIT (%d); the ones over the line are not created')
					:format(perDealer[dealer], dealer, Access.PREVIEW_LIMIT)
			end
		end
	end

	local company = Config.COMPANY
	if type(company) ~= 'table' then
		lines[#lines + 1] = 'COMPANY must be a table of JOBS, GANGS and EXCLUDED'
	elseif company.JOBS == false and company.GANGS == false then
		-- Not a fault of shape but of meaning: with neither banked, no seller
		-- anywhere has a company, so every face-to-face sale refuses and the
		-- whole feature is off without anything saying so.
		lines[#lines + 1] = 'COMPANY.JOBS and COMPANY.GANGS are both off: nobody can sell to ' ..
			'another player, because no seller has an account to pay into'
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
