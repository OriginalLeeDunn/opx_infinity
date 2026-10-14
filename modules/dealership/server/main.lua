--- Server half: the dealers, the showroom floor, the purchase and the sale.
-- @author XEROX710
--
-- Everything the client believes is re-derived here before money moves: a
-- request is a hint, and the mask is these checks. The distance is measured
-- across the ground against the DECLARED position, exactly as the client
-- measures it, the bucket must agree, the model must be one THIS dealer sells,
-- and the money must really be there.
--
-- THE ORDER OF THE TWO WRITES IS NOT FREE. A purchase moves money and creates a
-- vehicle, and only one of those can be undone: the character contract can give
-- money back, and the vehicles contract creates a row and offers no way to
-- remove one. So the charge goes first and the registration second, and a
-- registration that is refused -- the ceiling, a refused insertion, a plate that
-- could not be drawn -- is answered with a refund of exactly what was taken. The
-- reverse order would hand out a free car every time a row could not be written.
--
-- This module owns no vehicle a player drives and no plate. What a character
-- owns, and every rule about how much of it they may own, stays in one place:
-- the vehicles contract. The one exception is the SHOWROOM, whose cars belong to
-- nobody, are created straight through `Open77.vehicles` with no row anywhere,
-- and are LOCKED -- an unlocked showroom car is a free car with an audience.
--
-- SELLING TO SOMEBODY STANDING IN FRONT OF YOU. Inside a dealer's zone the eye
-- grows a row on every other player, and a salesperson picks a model for them.
-- Nothing is charged by that press: an OFFER is recorded and the BUYER'S OWN
-- CLIENT confirms it, which is the owner's own choice over debiting an account
-- because somebody else clicked something. The price is paid into the COMPANY
-- BANK of the seller's job or gang and a configured percentage of it is paid to
-- the seller.
--
-- THE PLACEMENT COMMANDS ARE GONE. `/opx.dealership.add` and `.remove` wrote a
-- dealer into `opx77_dealerships`, so the shape of the world lived in a table
-- nobody had a copy of. A dealer is written in `config/dealership.lua` now, and
-- every row still in that table is ADOPTED at boot and printed as the line that
-- would check it in -- see "the legacy adoption".
--
-- Every value off the wire goes through `safe` before it reaches a format
-- string: a newline would forge a whole log line.

local M = OPX.Modules.Get('dealership')
local Access = M.Access

local Result = OPX.Result
local Store = M.Storage

-- The dealers an operator checked in, and the ones adopted out of the legacy
-- table at boot.
local configSpots = {}
local adopted = {}

-- Config overlaid by the adoption: the one list every read below uses.
local spots = {}

-- The showroom. `previews` is what was placed, by key; `showroom` is the engine
-- id each one is standing as, by the same key. Two tables and not one, because a
-- preview that is placed and NOT standing -- the record was refused, the host
-- said no -- is a thing an operator has to be able to see.
local previews, showroom = {}, {}

-- The two halves `previews` is merged from, and they are the dealer story told
-- a second time. `configPreviews` is `PREVIEW.POINTS` in `config/dealership.lua`;
-- `adoptedPreviews` is what `opx77_dealership_previews` still holds from before
-- 2026-09-21, when the staff menu's Dev screen wrote showroom cars straight into
-- it and the owner deleted the screen for exactly that reason.
local configPreviews, adoptedPreviews = {}, {}

-- Per-player rate-limit windows for requests that are not rate-limited by
-- `OPX.Cooling`.
local windows = {}

-- THERE IS NO PENDING PLACEMENT, and the table that used to be here went with
-- the reason for it. `/opx.dealership.add` was a CHAT COMMAND: it had no facing
-- of its own, so the server asked the operator's client for one and then had to
-- cope with an answer that never came -- a timeout, a watcher thread and a
-- "your client did not answer" toast, all to make one round trip survivable.
--
-- The placement path that replaced it ran ON THE CLIENT, so the client READ
-- ITS OWN FACING before it said anything at all: one message, no waiting,
-- nothing to expire. That path is still wired and nothing in this resource
-- calls it -- the menu it belonged to is gone and a showroom car is a row in
-- PREVIEW.POINTS in config/dealership.lua.
--
-- The offer each BUYER has not answered yet, by their player id. Keyed by the
-- buyer and not by the seller: a buyer may only be deciding about one vehicle at
-- a time, and a second offer replaces the first rather than queueing behind it.
local offers = {}

-- THE NAME AN OFFER IS ANSWERED BY, and it is a counter rather than the clock.
-- An offer is keyed by its BUYER, so a second one replaces the first -- and the
-- answer to the first, already in flight, must not settle the second: a
-- different car, at a different price, that the buyer never saw. The clock
-- cannot tell them apart, because two offers made in the same millisecond carry
-- the same one; a counter never repeats.
local nextOffer = 0

-- Citizen ids a purchase is part-way through, from the charge to the answer.
-- THE VEHICLE CEILING IS A COUNT, THEN A YIELD, THEN AN INSERT
-- (`vehicles.Register`), and the three doors into `purchase` -- the net BUY, the
-- `buy` command and an accepted offer -- held separate floors, or none: two of
-- them in one tick both passed the count and the character ended up over
-- `PER_CHARACTER`. What must not run twice at once is one character's purchase,
-- so that is what is claimed.
local buying = {}

-- The contracts, resolved in `Start`. `keys` is the vehicle keys contract, the
-- only one of the four whose absence costs nothing but the key.
local character, vehicles, garages, keys

-- The currency a price is denominated in, settled in `Start`, and nil when the
-- character contract does not know it. Nil refuses every purchase.
local currency

-- What is for sale, as the client reads it: `{ garage = {...}, avpad = {...} }`.
local stockFor = { [M.KIND.GARAGE] = {}, [M.KIND.AVPAD] = {} }

-- Whether the loop that sweeps rate-limit windows is running.
local running = false

-- Deposits that failed AND whose ledger row could not be written either, by
-- token: the database was down for both. The sweep writes them to the ledger
-- when it can. Memory only, so a restart in that window loses them -- which is
-- why each is still logged with everything needed to settle it by hand.
local unsaved = {}

-- A counter for the ledger tokens, beside the clock, for the reason `nextOffer`
-- is a counter: two sales settling in the same millisecond carry the same clock.
local nextPending = 0

-- ONE PER BOOT, IN EVERY LEDGER TOKEN. The clock is milliseconds since the
-- PROCESS started and the counter starts at zero with it, so the first deposit
-- that fails after a restart can carry exactly the token of a row still owed
-- from before it -- and the ledger's `INSERT IGNORE` (which is what makes a retry
-- of the same deposit harmless) then dropped the new debt in silence. A few hex
-- digits drawn at load, beside the low digits of a fresh table's address (in case
-- a host seeds its generator the same way every boot), make two boots' tokens two
-- different strings.
local bootTag = ('%04x%s'):format(math.random(0, 0xFFFF),
	(tostring({}):match('(%x%x%x%x%x%x)$') or ''))

--- The token a new ledger row is filed under.
-- @author dop42
-- @param kind string
-- @param group string
-- @return string
function M.PendingToken(kind, group)
	nextPending = nextPending + 1
	return ('%s:%s:%s:%d:%d'):format(kind, tostring(group), bootTag,
		math.floor(OPX.Now()), nextPending)
end

-- How often the ledger of owed deposits is retried, and how many rows a pass
-- settles. A pass is a handful of statements; a minute is soon enough for money
-- nobody is waiting at a counter for.
local PENDING_SWEEP_MS = 60000
local PENDING_PAGE = 32

-- Whether a ledger sweep is in flight, so two never settle the same row.
local sweeping = false

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

-- How long a rate-limit window lives past a player's last request.
local WINDOW_GC_MS = 60000

local coordinate, integer = Access.Coordinate, Access.Integer

-- Cleans and caps a wire value before it reaches a log line.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

-- Counts one event in a player's window, refusing at the limit rather than
-- counting on through the rest of it.
local function within(player, limit, spanMs)
	if limit <= 0 or spanMs <= 0 then return true end
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= spanMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limit then return false end
	window.count = window.count + 1
	return true
end

--- Answers the character this connection has loaded, or nil.
-- The only ownership oracle there is: a citizen id in a payload is a claim.
local function characterOf(source)
	if character == nil then return nil end
	local player = character.GetPlayer(source)
	return player and player.PlayerData or nil
end

--- Reads a connection's ground position and bucket, or nil.
local function pointOf(source)
	local position = Open77.players.position(source)
	if type(position) ~= 'table' then return nil end
	local x, y = coordinate(position.x), coordinate(position.y)
	if x == nil or y == nil then return nil end
	local bucket = integer(position.bucket)
	return { x = x, y = y, bucket = bucket or 0 }
end

--- Rebuilds the merged list. Called once at load and after the adoption.
local function rebuild()
	spots = {}
	for key, spot in pairs(configSpots) do spots[key] = spot end
	for key, spot in pairs(adopted) do
		-- CONFIG WINS, and this is the one precedence the rework reverses. A
		-- captured row used to overlay the config file, because the command was
		-- the authority and the file was the backup. There is no command now: the
		-- file IS the dealer, and a stale row of the same name silently moving it
		-- would be a dealer an operator cannot move by editing the one place they
		-- are told to edit.
		if spots[key] == nil then spots[key] = spot end
	end
end

--- The dealers of one bucket, ready for the wire.
local function payloadFor(bucket)
	local list = Access.InBucket(spots, bucket)
	local out = {}
	for index = 1, #list do out[index] = Access.Serialise(list[index]) end
	return out
end

--- Sends one player the dealers of their own bucket and what is for sale.
local function sync(player)
	if type(player) ~= 'number' then return end
	local at = pointOf(player)
	if at == nil then return end
	TriggerClientEvent(M.Event.SYNC, player, { spots = payloadFor(at.bucket) })
	TriggerClientEvent(M.Event.STOCK, player, { kinds = stockFor })
end

--- Sends every connected player their own list. Guarded: a placement must not
--- fail because one connection could not be read.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(sync, tonumber(ids[index]))
		if not sent then
			Open77.log.warn('[dealership] sync failed: ' .. tostring(failure))
		end
	end
end

--- Answers a destination garage a purchase named, or nil when it may not be used.
-- The rules are all here and none of them are the client's: the named place has
-- to exist, be a garage of the SAME category as the dealer (a car is not filed
-- to an AV pad) and have at least one location in the player's own routing
-- bucket.
--
-- A GARAGE AND NOT A POINT. The garages rework made a garage a key with several
-- locations, and a vehicle is filed under the KEY -- naming one of its markers
-- here would file a car under a door, which is a car that comes out of exactly
-- one location and nowhere else.
-- @author XEROX710
-- @param key any
-- @param kind string
-- @param bucket integer
-- @return table|nil
local function destination(key, kind, bucket)
	if garages == nil or type(key) ~= 'string' or key == '' then return nil end
	if type(garages.Garages) ~= 'function' then return nil end
	local listed = garages.Garages()
	local built = type(listed) == 'table' and listed[key] or nil
	if built == nil or built.kind ~= kind then return nil end
	for _, place in ipairs(type(built.locations) == 'table' and built.locations or {}) do
		if place.bucket == bucket then return built end
	end
	return nil
end

--- The dealer a request names, resolved against where the connection stands.
-- @param at table the connection's point
-- @param dealerKey any
-- @return table|nil
-- @return Result|nil
local function dealerAt(at, dealerKey)
	local dealer
	if dealerKey == nil or dealerKey == '' then
		-- IN THE CONNECTION'S OWN BUCKET. Over every bucket, an instanced copy of
		-- a dealer on the same spot that sorted first won the search and was then
		-- refused as `wrongBucket` to somebody standing on a dealer in theirs.
		dealer = Access.Nearest(Access.InBucket(spots, at.bucket), at.x, at.y,
			OPX.Spots.ServerReachSq(Access.USE_RADIUS))
	else
		dealer = Access.Spot(spots, dealerKey)
	end
	if dealer == nil then return nil, Result.Err('dealership.noSuchSpot') end
	if dealer.bucket ~= at.bucket then return nil, Result.Err('dealership.wrongBucket') end

	local flat = Access.FlatDistanceSquared(dealer, at.x, at.y)
	-- With the server's slack, as garages: see `REACH_SLACK`.
	if flat == nil or flat > OPX.Spots.ServerReachSq(Access.USE_RADIUS) then
		return nil, Result.Err('dealership.tooFar', dealer.key)
	end
	return dealer, nil
end

--- Whether a connection is anywhere inside one dealer's ZONE.
-- Wider than `dealerAt`, and a different question: standing ON the marker is
-- what buys, and being IN THE ROOM is what lets a salesperson walk a customer
-- around it.
-- @param at table|nil
-- @param dealer table
-- @return boolean
local function inZone(at, dealer)
	if at == nil or dealer == nil then return false end
	if at.bucket ~= dealer.bucket then return false end
	local flat = Access.FlatDistanceSquared(dealer, at.x, at.y)
	return flat ~= nil and flat <= Access.ZONE_RADIUS_SQ
end

-- ── the purchase itself ─────────────────────────────────────────────────────

--- Pays one CITIZEN, through the connection while it still holds them.
-- A payment made after a yield cannot trust that `source` is still the
-- character it was: the player may have left, or loaded another character. The
-- connection is used when it still holds that citizen -- with nothing between
-- the check and the payment that yields -- and otherwise `AddMoneyOffline`,
-- which pays the loaded balance wherever they are now, or the row.
-- @return boolean paid
-- @return any why not
local function payCitizen(source, citizenId, amount, reason)
	local data = source ~= nil and characterOf(source) or nil
	if data ~= nil and data.citizenId == citizenId then
		return character.AddMoney(source, currency, amount, reason)
	end
	if type(character.AddMoneyOffline) ~= 'function' then return false, 'money.offline' end
	local paid = character.AddMoneyOffline(citizenId, currency, amount, reason)
	if type(paid) ~= 'table' then return false, 'no answer' end
	return paid.ok == true, paid.error or paid.detail
end

-- How far a parked car must be from a hand-over spot for the spot to be free,
-- and how far apart the fallback spots beside the marker stand. A car's width.
local HAND_OVER_CLEARANCE = 3.0
local HAND_OVER_STEP = 4.5

--- Where a bought car can be handed over: the dealer's marker when nothing is
--- parked on it, otherwise one or two car-widths to either side, or nil.
-- Only cars in the dealer's own bucket count. A host that cannot list vehicles
-- answers the marker, which is what every hand-over did before this check.
-- @param dealer table
-- @return number|nil x
-- @return number|nil y
local function handOverSpot(dealer)
	local parked = {}
	local api = Open77.vehicles
	if type(api) == 'table' and type(api.all) == 'function' then
		local read, listed = pcall(api.all, dealer.bucket)
		if read and type(listed) == 'table' then
			for index = 1, #listed do
				local car = listed[index]
				local at = type(car) == 'table' and (type(car.position) == 'table' and car.position
					or car) or nil
				local x, y = at and coordinate(at.x), at and coordinate(at.y)
				if x ~= nil and y ~= nil then parked[#parked + 1] = { x = x, y = y } end
			end
		end
	end
	-- Sideways is across the dealer's own heading, so the fallbacks line up
	-- beside the marker rather than in front of it.
	local radians = math.rad(tonumber(dealer.heading) or 0)
	local sideX, sideY = math.cos(radians), math.sin(radians)
	local clearSq = HAND_OVER_CLEARANCE * HAND_OVER_CLEARANCE
	for _, step in ipairs({ 0, 1, -1, 2, -2 }) do
		local x = dealer.x + sideX * step * HAND_OVER_STEP
		local y = dealer.y + sideY * step * HAND_OVER_STEP
		local free = true
		for index = 1, #parked do
			local dx, dy = parked[index].x - x, parked[index].y - y
			if dx * dx + dy * dy <= clearSq then free = false break end
		end
		if free then return x, y end
	end
	return nil, nil
end

--- Charges the buyer, registers the vehicle and hands it over.
-- @author XEROX710
--
-- THE ONE PLACE MONEY LEAVES A BUYER, and both doors go through it: the
-- self-service `Buy` and the face-to-face `Accept`. A second copy for the second
-- door would be a second answer to the question of what happens when the
-- registration fails after the charge -- which is the one failure in this module
-- that can cost a player money.
-- @param source Source the BUYER's connection
-- @param data table their PlayerData
-- @param dealer table
-- @param entry table the stock row
-- @param dest table|nil the destination garage
-- @return Result
local function purchaseOnce(source, data, dealer, entry, dest)
	local paid, refusal = character.RemoveMoney(source, currency, entry.price,
		'dealership:' .. entry.key)
	if not paid then
		-- The character contract answers a catalogue key of its own
		-- (`money.insufficient`, `money.offline`), which is a code the player
		-- can be shown; anything that is not a string is a fault of ours.
		return Result.Err(type(refusal) == 'string' and refusal or 'dealership.paymentFailed')
	end

	-- GUARDED, BECAUSE OF WHAT IS ON THE OTHER SIDE OF IT. The row is written by
	-- another module, and a throw inside it unwinds THIS frame -- past the refund
	-- below and out of the caller -- so the player is charged and owns nothing,
	-- with no line anywhere that says how much. That is not hypothetical: a
	-- setting `vehicles` never received made `Register` compare a nil, the money
	-- went out twice and not one row was written. A throw is a refusal like any
	-- other, and the message is kept for the log so the next one is diagnosable.
	local answered, made = pcall(vehicles.Register, data.citizenId, entry.record, {
		garage = dest ~= nil and dest.key or nil,
	})
	if not answered then
		Open77.log.error(('[dealership] %s: vehicles.Register threw for %s: %s')
			:format(tostring(data.citizenId), entry.key, tostring(made)))
		made = Result.Err('dealership.registerFailed')
	elseif type(made) ~= 'table' then
		-- THE OTHER WAY THE SAME MONEY GETS LOST. The pcall above guards a THROW;
		-- this guards a RETURN that is not a Result. `made.ok` on a nil raises
		-- here, three lines after `RemoveMoney` and before the refund that the
		-- comment above exists to protect -- so the throw the pcall was added to
		-- survive would simply move down the function. A contract that answers
		-- the wrong shape is a refusal like any other.
		Open77.log.error(('[dealership] %s: vehicles.Register answered a %s for %s')
			:format(tostring(data.citizenId), type(made), entry.key))
		made = Result.Err('dealership.registerFailed')
	end
	if not made.ok then
		-- THE HALF THAT CAN BE UNDONE. Nothing was owned, so the money goes
		-- back; a refund that itself fails is the one outcome that costs a
		-- player money, and it is said in the log with everything needed to
		-- settle it by hand.
		-- TO THE CITIZEN WHO PAID, NOT TO THE CONNECTION. `Register` yielded,
		-- and in that window the buyer can have logged off -- `AddMoney(source)`
		-- then answered `notLoggedIn` and the money was simply gone -- or gone
		-- back to the selection screen and loaded ANOTHER character, which was
		-- then refunded money it never paid. `AddMoneyOffline` pays the loaded
		-- balance when the character is online and the row when it is not;
		-- `payCitizen` asks it only when the connection no longer holds them.
		local back, why = payCitizen(source, data.citizenId, entry.price,
			'dealership:refund:' .. entry.key)
		if not back then
			Open77.log.error(
				('[dealership] %s was charged %d %s for %s and the vehicle was refused (%s); ' ..
					'the refund ALSO failed (%s) -- settle this by hand')
					:format(tostring(data.citizenId), entry.price, currency, entry.key,
						tostring(made.error), tostring(why)))
		else
			Open77.log.warn(
				('[dealership] %s refused %s after payment (%s); %d %s refunded')
					:format(tostring(data.citizenId), entry.key, tostring(made.error),
						entry.price, currency))
		end
		return made
	end

	local plate = made.value and made.value.plate or nil

	-- THE KEY GOES WITH THE SALE, not with the hand-over: a car filed under a
	-- garage and never driven off the lot is still a car the buyer owns, and the
	-- key is how they get into it at the kerb. `Ensure` and not `Give`, so the
	-- key the garage would otherwise cut on the first take-out is this one. A key
	-- that did not fit in the bag is NOT a failed sale -- the garage cuts one the
	-- first time the car comes out -- so it is logged, and said to the buyer when
	-- it was their bag that was full, which is the one cause they can act on.
	local keyed = false
	if plate ~= nil and keys ~= nil then
		-- GUARDED, for the reason `Register` is: the money is gone and the row
		-- exists, and a throw here unwound past the answer, the audit line, the
		-- sale event and -- on an accepted offer -- the company's share and the
		-- commission. A throw is one more key that was not cut.
		local called, cut = pcall(keys.Ensure, source, plate, entry.label or entry.record)
		if not called then
			Open77.log.error(('[dealership] keys.Ensure threw for %s: %s')
				:format(tostring(plate), tostring(cut)))
			cut = nil
		end
		keyed = type(cut) == 'table' and cut.ok == true
		if not keyed then
			local code = type(cut) == 'table' and cut.error or 'vehiclekeys.unavailable'
			if code == 'vehiclekeys.noRoom' then
				OPX.NotifyLocale(source, code, { label = tostring(cut.detail or plate) }, 'error')
			end
			Open77.log.warn(('[dealership] %s owns %s but was not given its key: %s')
				:format(tostring(data.citizenId), tostring(plate), tostring(code)))
		end
	end

	local handOver = M.Settings.HAND_OVER ~= false
	local spawned = false
	-- Where the car went when it could not be handed over, said AFTER "You
	-- bought X" by whoever tells the buyer (`toldBought`): said here, it came
	-- first, and read as a car that had gone somewhere before it was bought.
	local note = nil

	if handOver and plate ~= nil then
		-- AT THE DEALER, turned to the dealer's own heading, so a bought car
		-- appears where it was bought rather than a car's width to one side.
		-- An AV is lifted clear of the ground it is sold on.
		local z = dealer.z
		if entry.av then z = z + Access.AvLift() end
		-- ON A FREE SPOT. The marker first, then a car's width either side of
		-- it; a hand-over created inside the car the last buyer has not driven
		-- off yet is two cars welded together.
		local spotX, spotY = handOverSpot(dealer)
		local handed
		if spotX == nil then
			handed = { ok = false, error = 'every spot beside the dealer is taken' }
			note = 'dealership.handOverBlocked'
		else
			-- Guarded like the key above, and for the same reason.
			local called
			called, handed = pcall(vehicles.Spawn, source, plate, {
				x = spotX, y = spotY, z = z,
				yaw = dealer.heading,
				bucket = dealer.bucket,
			})
			if not called or type(handed) ~= 'table' then
				handed = { ok = false, error = called and 'no answer' or ('threw: ' .. tostring(handed)) }
			end
		end
		spawned = handed.ok == true
		if not spawned then
			-- NOT A FAILED SALE. The vehicle is owned and it is filed under the
			-- garage the player chose, so it comes out there; the hand-over is
			-- the convenience, and its refusal is reported rather than undone.
			Open77.log.warn(('[dealership] %s owns %s but the hand-over at %s was refused: %s')
				:format(tostring(data.citizenId), tostring(plate), safe(dealer.key),
					tostring(handed.error)))
			-- SAID, as a blocked spot already was. Any other refusal of the
			-- spawn was a log line only, and the buyer read "You bought X" with
			-- no car in front of them and no word of where it went.
			if spotX ~= nil then note = 'dealership.handOverFailed' end
		end
	end

	return Result.Ok({
		plate = plate,
		entry = entry.key,
		model = entry.label,
		dealer = dealer.key,
		label = dealer.label,
		garage = dest ~= nil and dest.key or nil,
		price = entry.price,
		currency = currency,
		spawned = spawned,
		keyed = keyed,
		handOver = note ~= nil and {
			key = note,
			garage = dest ~= nil and dest.label or locale('dealership.defaultGarage'),
		} or nil,
	})
end

--- Tells a buyer what they bought, and only then where the car is when it was
--- not handed over at the counter.
-- @param source Source
-- @param value table a purchase's answer
local function toldBought(source, value)
	OPX.NotifyLocale(source, 'dealership.bought',
		{ model = value.model, plate = value.plate }, 'success')
	local note = type(value.handOver) == 'table' and value.handOver or nil
	if note ~= nil then
		OPX.NotifyLocale(source, note.key, { garage = note.garage }, 'info')
	end
end

--- `purchaseOnce`, one at a time per character. See `buying`.
-- Every door goes through this and never through `purchaseOnce` directly. The
-- claim is taken and given back with nothing in between that can skip the
-- release: a throw is caught, logged, and answered like a failed payment --
-- by the guards inside it, a throw can only come from before the charge.
local function purchase(source, data, dealer, entry, dest)
	local who = data.citizenId
	if buying[who] then return Result.Err('error.tooFast') end
	buying[who] = true
	local ran, result = pcall(purchaseOnce, source, data, dealer, entry, dest)
	buying[who] = nil
	if not ran then
		Open77.log.error(('[dealership] the purchase of %s by %s threw: %s')
			:format(safe(entry.key), tostring(who), tostring(result)))
		return Result.Err('dealership.paymentFailed')
	end
	return result
end

--- Buys one model from the dealer the connection is standing on.
-- @author XEROX710
-- @param source Source
-- @param dealerKey string|nil the dealer's name; the nearest one when omitted
-- @param entryKey string the stock row being bought
-- @param destKey string|nil the garage the vehicle is filed under
-- @return Result
function M.Buy(source, dealerKey, entryKey, destKey)
	if vehicles == nil then return Result.Err('dealership.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('dealership.noCharacter')
	end
	local at = pointOf(source)
	if at == nil then return Result.Err('dealership.noPosition') end

	local dealer, refusal = dealerAt(at, dealerKey)
	if dealer == nil then return refusal end

	local entry = Access.Entry(entryKey)
	if entry == nil then return Result.Err('dealership.noSuchEntry') end
	-- WHAT THIS DEALER SELLS, and it is the dealer's category that decides: a
	-- garage sells ground vehicles, a pad sells AVs. A row is refused rather
	-- than quietly redirected to the dealer that does stock it.
	if not Access.SoldHere(dealer.kind, entry) then
		return Result.Err('dealership.notSold', entry.key)
	end
	if currency == nil then return Result.Err('dealership.noCurrency') end

	-- Read before anything is charged, so the common refusal costs the player
	-- nothing at all: the money is still re-checked by the removal itself, which
	-- is the only check that counts -- this one is the courtesy.
	local balance = character.GetMoney(source, currency)
	if type(balance) ~= 'number' or balance < entry.price then
		return Result.Err('dealership.cannotAfford', entry.key)
	end

	local dest = nil
	if type(destKey) == 'string' and destKey ~= '' then
		dest = destination(destKey, dealer.kind, at.bucket)
		if dest == nil then return Result.Err('dealership.noSuchGarage', destKey) end
	end

	local bought = purchase(source, data, dealer, entry, dest)
	if not bought.ok then return bought end

	local player = character.GetPlayer(source)
	if player ~= nil then
		OPX.Audit.Player(player, 'dealership.buy', tostring(bought.value.plate), {
			entry = entry.key,
			dealer = dealer.key,
			garage = dest ~= nil and dest.key or '',
			price = tostring(entry.price),
			currency = currency,
		})
	end
	Open77.log.info(('[dealership] %s bought %s (%s) at %s for %d %s%s'):format(
		tostring(data.citizenId), safe(entry.key), safe(entry.record), safe(dealer.key),
		entry.price, currency, dest ~= nil and (' -> ' .. safe(dest.key)) or ''))
	OPX.Publish(M.Event.ON_SOLD, source, {
		kind = 'counter',
		citizenId = data.citizenId,
		plate = bought.value.plate,
		entry = entry.key,
		record = entry.record,
		dealer = dealer.key,
		garage = dest ~= nil and dest.key or nil,
		price = entry.price,
		currency = currency,
	})

	return bought
end

-- ── the company bank ────────────────────────────────────────────────────────

--- The company one connection sells for, or nil with the reason.
-- @author XEROX710
-- @param source Source
-- @return string|nil kind
-- @return string|nil group
local function companyOf(source)
	local data = characterOf(source)
	if data == nil then return nil, nil end
	local job = type(data.job) == 'table' and data.job.name or nil
	local gang = type(data.gang) == 'table' and data.gang.name or nil
	return Access.CompanyOf(job, gang)
end

--- Pays a sale into a company's account, answering what actually landed.
-- @author XEROX710
--
-- EVERY DEPOSIT GOES THROUGH THE LEDGER, UNDER ITS OWN TOKEN. It used to be a
-- plain `balance = balance + amount`, and a deposit whose answer was lost after
-- it committed was then ALSO written to the ledger as owed -- and the sweep paid
-- it a second time. Now the debt is written first (`INSERT IGNORE` on the token,
-- so writing it twice is one row) and settled at once by `Store.SettleOwed`,
-- which deposits only a row that is still there and strikes it off in the same
-- transaction: a settlement retried, or raced by the sweep, pays nothing twice.
-- The arithmetic is still the database's. A deposit that fails is NOT a failed
-- sale: the buyer owns the vehicle and the seller has been paid, and undoing
-- either from here would be two more writes that can fail in turn.
--
-- IT IS OWED, NOT FORGOTTEN. This used to log "settle this by hand" and stop
-- there, so the company's money depended on somebody reading the journal. It
-- is now written to `opx77_company_pending` and the sweep pays it in when the
-- database answers -- one transaction per row, deposit and strike-off together,
-- so a retry can never pay it twice. When even the ledger cannot be written it
-- is held in memory and the sweep writes it later; the log line stays, because a
-- restart inside that window is the one case only a person can settle.
-- @param kind string
-- @param group string
-- @param amount integer
-- @param plate any
-- @return boolean
local function bank(kind, group, amount, plate)
	if amount <= 0 then return true end
	local token = M.PendingToken(kind, group)
	local owed = { token = token, kind = kind, group = group, amount = amount,
		plate = plate ~= nil and tostring(plate) or nil }
	local pended = Store.Pend(token, kind, group, amount, owed.plate)
	local put = pended
	if pended ~= nil and pended.ok then put = Store.SettleOwed('token', token) end
	if put == nil or not put.ok then
		if pended == nil or not pended.ok then
			unsaved[token] = owed
			Open77.log.error(('[dealership] %d %s from the sale of %s did NOT reach the %s account ' ..
				'of %s (%s), and the pending ledger could not be written either; it is held ' ..
				'in memory and retried, and a restart before then means settling it by hand')
				:format(amount, tostring(currency), safe(plate), kind, safe(group),
					tostring(put and put.detail or 'no answer')))
		else
			Open77.log.warn(('[dealership] %d %s from the sale of %s did not reach the %s account ' ..
				'of %s (%s); it is in the pending ledger and will be paid in when the ' ..
				'database answers'):format(amount, tostring(currency), safe(plate), kind,
					safe(group), tostring(put and put.detail or 'no answer')))
		end
		return false
	end
	return true
end

--- Pays in what the ledger says is owed. One pass, never two at once.
-- @author dop42
-- @return integer how many rows were settled
function M.SettlePending()
	if sweeping then return 0 end
	sweeping = true
	local settled = 0
	local ran, failure = pcall(function()
		-- What could not even be written to the ledger goes there first.
		-- The tokens are collected BEFORE anything yields: `Store.Pend` does, and
		-- a `bank` that fails meanwhile inserts into `unsaved`, which `next`
		-- leaves undefined for a table being walked.
		local tokens = {}
		for token in pairs(unsaved) do tokens[#tokens + 1] = token end
		for index = 1, #tokens do
			local token = tokens[index]
			local owed = unsaved[token]
			if owed ~= nil then
				local pended = Store.Pend(token, owed.kind, owed.group, owed.amount, owed.plate)
				if pended ~= nil and pended.ok then unsaved[token] = nil end
			end
		end

		local rows = Store.FetchPending(PENDING_PAGE)
		if rows == nil or not rows.ok or type(rows.value) ~= 'table' then return end
		for index = 1, #rows.value do
			local row = rows.value[index]
			local amount = math.tointeger(tonumber(row.amount))
			if amount ~= nil and amount > 0 then
				local paid = Store.SettleOwed('id', row.id)
				if paid ~= nil and paid.ok then
					settled = settled + 1
					Open77.log.info(('[dealership] paid %d owed from the sale of %s into the %s ' ..
						'account of %s'):format(amount, safe(row.plate), tostring(row.kind),
							safe(row.group_key)))
				else
					-- The database is still not answering: the rest can wait for
					-- the next pass rather than each failing in turn.
					break
				end
			end
		end
	end)
	sweeping = false
	if not ran then
		Open77.log.error('[dealership] the pending ledger sweep raised: ' .. tostring(failure))
	end
	return settled
end

-- ── selling to another player ───────────────────────────────────────────────

--- Offers one model to another player, who has to say yes themselves.
-- @author XEROX710
--
-- NOTHING IS CHARGED HERE. The owner chose that the buyer's own client confirms
-- over debiting them the moment a salesperson presses a row, and this function
-- is the whole of that choice: it proves everything it can prove NOW, records
-- the offer, and sends it. `Accept` proves all of it again, because everything
-- provable here can have stopped being true by the time the buyer answers --
-- they can walk out of the room, spend the money, or log off.
-- @param seller Source
-- @param buyer any the player id the seller picked off the eye
-- @param entryKey any
-- @return Result
function M.Offer(seller, buyer, entryKey)
	if vehicles == nil then return Result.Err('dealership.noVehicles') end
	if currency == nil then return Result.Err('dealership.noCurrency') end

	buyer = tonumber(buyer)
	if buyer == nil or buyer == seller then return Result.Err('dealership.noSuchBuyer') end

	-- THE SELLER'S SIDE FIRST, THEN WHETHER THE BUYER IS IN THE ROOM, AND ONLY
	-- THEN ANYTHING ABOUT THE BUYER. The buyer's character was read first, so a
	-- salesperson naming arbitrary server ids was told `noCharacter` or
	-- `noPosition` for one and `buyerNotInZone` for another -- which slots were
	-- connected and which had a character loaded, from anywhere. Somebody who is
	-- not standing in the showroom is `buyerNotInZone`, whoever they are and
	-- whether or not they exist.
	local sellerData = characterOf(seller)
	if sellerData == nil then return Result.Err('dealership.noCharacter') end

	local kind, group = companyOf(seller)
	if kind == nil then return Result.Err('dealership.noCompany') end

	local sellerAt = pointOf(seller)
	if sellerAt == nil then return Result.Err('dealership.noPosition') end

	-- THE SELLER'S OWN NEAREST DEALER decides which showroom this is, and both
	-- of them have to be standing in it: a salesperson who can sell to somebody
	-- across the city is a salesperson who can sell to somebody who has never
	-- seen a dealership.
	-- In the seller's own bucket, for the reason `dealerAt` gives.
	local dealer = Access.Nearest(Access.InBucket(spots, sellerAt.bucket), sellerAt.x, sellerAt.y,
		Access.ZONE_RADIUS_SQ)

	if dealer == nil or not inZone(sellerAt, dealer) then
		return Result.Err('dealership.notInZone')
	end
	local buyerAt = pointOf(buyer)
	if buyerAt == nil or not inZone(buyerAt, dealer) then
		return Result.Err('dealership.buyerNotInZone')
	end
	local buyerData = characterOf(buyer)
	if buyerData == nil or type(buyerData.citizenId) ~= 'string' then
		return Result.Err('dealership.noSuchBuyer')
	end

	local entry = Access.Entry(entryKey)
	if entry == nil then return Result.Err('dealership.noSuchEntry') end
	if not Access.SoldHere(dealer.kind, entry) then
		return Result.Err('dealership.notSold', entry.key)
	end

	-- NO "CAN THEY AFFORD IT" HERE. A courtesy check stood here and answered the
	-- SELLER `buyerCannotAfford` before the buyer was asked anything: offering
	-- one stranger cars of rising price read their balance, to the eddy, without
	-- them ever seeing an offer. A player's money is nobody else's business. The
	-- buyer is asked; the payment is what refuses, and the seller hears only
	-- that it was refused (`Accept`).

	local at = OPX.Now()
	nextOffer = nextOffer + 1
	local token = nextOffer
	offers[buyer] = {
		token = token,
		at = at,
		seller = seller,
		sellerCitizen = sellerData.citizenId,
		buyerCitizen = buyerData.citizenId,
		dealer = dealer.key,
		entry = entry.key,
		price = entry.price,
		kind = kind,
		group = group,
	}

	local cut, company = Access.Split(entry.price)
	TriggerClientEvent(M.Event.OFFERED, buyer, {
		token = token,
		entry = entry.key,
		model = entry.label,
		price = entry.price,
		text = character.FormatMoney(entry.price, currency),
		-- NO SELLER. This carried the seller's account gamertag (and their server
		-- id when it had none) to the buyer: out-of-character, and a name the
		-- buyer had not been given. Never a name to a stranger, the owner's
		-- decision (#91); the buyer is looking at the person selling.
		dealer = dealer.key,
		label = dealer.label,
		-- The dealer's kind, so the buyer's own screen lists only the garages a
		-- vehicle of this kind may be filed under.
		kind = dealer.kind,
		timeoutMs = Access.OFFER_TIMEOUT_MS,
	})

	-- The offer settles itself. Without this a buyer who simply walks away
	-- leaves a row in `offers` that the seller is waiting on for ever, and the
	-- seller is told nothing at all.
	if Access.OFFER_TIMEOUT_MS > 0 then
		CreateThread(function()
			local deadline = at + Access.OFFER_TIMEOUT_MS
			while OPX.Now() < deadline do
				local live = offers[buyer]
				if live == nil or live.token ~= token then return end
				Wait(250)
			end
			local live = offers[buyer]
			if live == nil or live.token ~= token then return end
			offers[buyer] = nil
			-- The seller's SETTLED handler raises the one toast; a second one
			-- from here doubled it. And the BUYER is told too, so the screen
			-- asking them to buy a car nobody is selling any more comes down.
			TriggerClientEvent(M.Event.SETTLED, live.seller, { ok = false,
				error = 'dealership.offerExpired', entry = live.entry })
			TriggerClientEvent(M.Event.WITHDRAWN, buyer, { token = live.token,
				error = 'dealership.offerExpired' })
		end)
	end

	return Result.Ok({
		buyer = buyer,
		token = token,
		entry = entry.key,
		price = entry.price,
		cut = cut,
		company = company,
		dealer = dealer.key,
	})
end

--- The buyer's own answer to an offer. This is where the money moves.
-- @author XEROX710
-- @param buyer Source
-- @param token any the offer's own name, so a stale answer cannot settle a new one
-- @param yes boolean
-- @param destKey string|nil the garage the BUYER chose to file it under; the
--   vehicles module's default when omitted, exactly as `Buy` treats it
-- @return Result
function M.Accept(buyer, token, yes, destKey)
	local offer = offers[buyer]
	if offer == nil then return Result.Err('dealership.noOffer') end
	-- IDENTIFIED BY ITS OWN NAME. A second offer replaces the first -- the table
	-- is keyed by the buyer -- and a confirm that was already in flight for the
	-- first would otherwise buy the second: a different car, at a different
	-- price, that the buyer never saw. It is a counter and not the clock,
	-- because two offers made in the same millisecond carry the same clock.
	if Access.FiniteNumber(token) ~= offer.token then return Result.Err('dealership.noOffer') end
	offers[buyer] = nil

	-- The seller is told by SETTLED, whose handler raises the one toast; a
	-- second one from here doubled it.
	if yes ~= true then
		TriggerClientEvent(M.Event.SETTLED, offer.seller, { ok = false,
			error = 'dealership.offerDeclined', entry = offer.entry })
		return Result.Err('dealership.offerDeclined')
	end

	-- THE SELLER IS TOLD HOW IT ENDED, on every refusal from here down. The
	-- offer is already gone from the table, so the timeout that would otherwise
	-- report it finds nothing and says nothing: a seller whose buyer said yes
	-- and was then refused for the zone or the catalogue was left waiting on a
	-- sale that no longer existed. `told` is the seller's own sentence where
	-- the buyer's would read wrong to them, and false when the seller is the
	-- one who left -- the connection may belong to somebody else by now.
	local function refused(code, told)
		if told ~= false then
			TriggerClientEvent(M.Event.SETTLED, offer.seller, { ok = false,
				error = told or code, entry = offer.entry })
		end
		return Result.Err(code)
	end

	if vehicles == nil then return refused('dealership.noVehicles') end
	if currency == nil then return refused('dealership.noCurrency') end

	-- EVERYTHING IS PROVED AGAIN. The buyer may have walked out of the room,
	-- spent the money, changed character or logged off since the offer, and the
	-- seller may have done the same.
	local sellerData = characterOf(offer.seller)
	local sellerHere = sellerData ~= nil and sellerData.citizenId == offer.sellerCitizen
	local buyerData = characterOf(buyer)
	if buyerData == nil or buyerData.citizenId ~= offer.buyerCitizen then
		return refused('dealership.noCharacter', sellerHere and 'dealership.buyerNotInZone')
	end
	if not sellerHere then return refused('dealership.sellerGone', false) end
	-- THE SELLER STILL SELLS FOR THE COMPANY THE OFFER BANKS TO. It was read once,
	-- when the offer was made; a seller fired or moved to another job before the
	-- buyer answered still earned the commission and paid the old company.
	local kind, group = companyOf(offer.seller)
	if kind ~= offer.kind or group ~= offer.group then
		return refused('dealership.sellerNoCompany', 'dealership.noCompany')
	end

	local dealer = Access.Spot(spots, offer.dealer)
	local buyerAt = pointOf(buyer)
	local sellerAt = pointOf(offer.seller)
	if dealer == nil or not inZone(buyerAt, dealer) then
		return refused('dealership.notInZone', 'dealership.buyerNotInZone')
	end
	if not inZone(sellerAt, dealer) then
		return refused('dealership.sellerGone', 'dealership.notInZone')
	end

	local entry = Access.Entry(offer.entry)
	if entry == nil or entry.price ~= offer.price then
		-- The catalogue was edited and reloaded under an open offer. Refused
		-- rather than honoured at either price: one of them is not what the
		-- buyer agreed to and the other is not what the shop sells for.
		return refused('dealership.noSuchEntry')
	end

	-- THE BUYER'S GARAGE, and it was ignored. A sale at the counter has always
	-- asked which garage to file the car under; a sale from a salesperson
	-- passed nil here, so the car went to the vehicles module's default garage
	-- whatever the buyer would have chosen -- and came out somewhere they never
	-- picked. Resolved in the buyer's own bucket, as `Buy` resolves it, and a
	-- name that does not resolve is refused rather than quietly defaulted.
	local dest = nil
	if type(destKey) == 'string' and destKey ~= '' then
		dest = destination(destKey, dealer.kind, buyerAt.bucket)
		if dest == nil then
			TriggerClientEvent(M.Event.SETTLED, offer.seller, { ok = false,
				error = 'dealership.noSuchGarage', entry = offer.entry })
			return Result.Err('dealership.noSuchGarage', destKey)
		end
	end

	-- THE BUYER IS TOLD THEY ARE SHORT; THE SELLER, THAT THE PAYMENT WAS REFUSED.
	-- Never the buyer's balance to anybody else -- see `Offer`. The removal
	-- below is still the check that counts; this is the courtesy, on the
	-- buyer's side of the sale where it belongs.
	local balance = character.GetMoney(buyer, currency)
	if type(balance) ~= 'number' or balance < entry.price then
		TriggerClientEvent(M.Event.SETTLED, offer.seller, { ok = false,
			error = 'dealership.paymentFailed', entry = offer.entry })
		return Result.Err('dealership.cannotAfford', entry.key)
	end

	local bought = purchase(buyer, buyerData, dealer, entry, dest)
	if not bought.ok then
		local why = tostring(bought.error)
		local money = why == 'dealership.cannotAfford' or why:sub(1, 6) == 'money.'
		TriggerClientEvent(M.Event.SETTLED, offer.seller, { ok = false,
			error = money and 'dealership.paymentFailed' or bought.error, entry = offer.entry })
		return bought
	end

	-- ── where the money goes ─────────────────────────────────────────────
	local cut, company = Access.Split(entry.price)
	local paid = true
	if cut > 0 then
		-- TO THE SELLER'S CITIZEN, for the reason the refund is: `purchase`
		-- yielded, and a seller who swapped character meanwhile had the
		-- commission paid to whichever character the connection held now.
		local given, why = payCitizen(offer.seller, offer.sellerCitizen, cut,
			'dealership:commission:' .. entry.key)
		if not given then
			paid = false
			-- NOT A FAILED SALE, and it is banked to the company instead rather
			-- than evaporating: the buyer owns the vehicle, and a commission
			-- that could not be paid is money that belongs to somebody.
			Open77.log.warn(('[dealership] the %d %s commission for %s could not be paid to ' ..
				'player %d (%s); it is banked to the company instead'):format(cut,
				tostring(currency), safe(entry.key), offer.seller, tostring(why)))
			company = company + cut
			cut = 0
		end
	end
	local banked = bank(offer.kind, offer.group, company, bought.value.plate)

	local player = character.GetPlayer(buyer)
	if player ~= nil then
		OPX.Audit.Player(player, 'dealership.sold', tostring(bought.value.plate), {
			entry = entry.key,
			dealer = dealer.key,
			price = tostring(entry.price),
			currency = currency,
			seller = tostring(offer.sellerCitizen),
			company = offer.kind .. ':' .. offer.group,
			commission = tostring(cut),
		})
	end
	Open77.log.info(('[dealership] %s sold %s (%s) to %s for %d %s; %d to the %s account of ' ..
		'%s, %d commission'):format(tostring(offer.sellerCitizen), safe(entry.key),
		safe(bought.value.plate), tostring(offer.buyerCitizen), entry.price, currency,
		company, offer.kind, safe(offer.group), cut))
	OPX.Publish(M.Event.ON_SOLD, buyer, {
		kind = 'offer',
		citizenId = offer.buyerCitizen,
		plate = bought.value.plate,
		entry = entry.key,
		record = entry.record,
		dealer = dealer.key,
		garage = dest ~= nil and dest.key or nil,
		price = entry.price,
		currency = currency,
		seller = offer.seller,
		sellerCitizenId = offer.sellerCitizen,
		company = offer.kind .. ':' .. offer.group,
		commission = cut,
		banked = company,
		-- The company's share did not land and is in `opx77_company_pending`;
		-- the sweep pays it in later. The sale itself is done either way.
		pending = not banked,
	})

	TriggerClientEvent(M.Event.SETTLED, offer.seller, {
		ok = true, entry = offer.entry, model = entry.label,
		cut = cut, company = company, banked = banked,
	})
	-- A CUT OF NOTHING IS NOT "YOU EARNED €$0". It is nothing when the seller
	-- could not be paid (the money went to the company) or the operator set no
	-- commission; the seller still hears that the sale is done.
	if (tonumber(cut) or 0) > 0 then
		OPX.NotifyLocale(offer.seller, 'dealership.commission',
			{ amount = character.FormatMoney(cut, currency), model = entry.label }, 'success')
	else
		OPX.NotifyLocale(offer.seller, 'dealership.soldNoCut', { model = entry.label }, 'success')
	end

	bought.value.commission = cut
	bought.value.banked = company
	bought.value.paid = paid
	return bought
end

-- ── the showroom ────────────────────────────────────────────────────────────

--- Creates one preview vehicle, or answers why it could not be.
-- @author XEROX710
--
-- THE LOCK IS ASKED FOR AT CREATION AND READ BACK. `Open77.vehicles.create`
-- takes the flag names as booleans in its definition, and `flags` on a snapshot
-- is the bitfield they land in -- so a lock the host silently dropped is
-- visible, and a showroom car that anybody may drive away is a line in the
-- journal rather than a surprise.
--
-- `persistent` and no `ttlMs`: a showroom car is furniture. One that despawned
-- when nobody was looking would come back only when the resource restarted.
-- @param spot table a preview point
-- @return string|integer|nil the engine id
-- @return string|nil why not
local function raise(spot)
	local entry = Access.Entry(spot.entry)
	if entry == nil then return nil, 'no stock row named ' .. tostring(spot.entry) end
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		return nil, 'this host cannot create vehicles'
	end

	local locked = Access.PreviewLocked()
	local created, id, reason = pcall(api.create, {
		record = entry.record,
		position = { x = spot.x, y = spot.y, z = spot.z + Access.PreviewLift() },
		yaw = spot.heading,
		bucket = spot.bucket,
		locked = locked,
		persistent = true,
	})
	if not created then return nil, tostring(id) end
	if id == nil then return nil, tostring(reason or 'refused') end

	if locked and type(api.get) == 'function' then
		local read, snapshot = pcall(api.get, id)
		local bits = type(api.flags) == 'table' and api.flags or nil
		local mask = bits ~= nil and bits.locked or nil
		local flags = read and type(snapshot) == 'table' and Access.FiniteNumber(snapshot.flags)
			or nil
		if mask ~= nil and flags ~= nil and (math.floor(flags) & math.floor(mask)) == 0 then
			-- ASKED FOR AND NOT GIVEN. Said rather than retried: a second write
			-- that the host refuses for the same reason is a second line saying
			-- the same thing, and what an operator needs is to know the car is
			-- open.
			Open77.log.warn(('[dealership] the showroom car %s at %s came up UNLOCKED: anybody ' ..
				'may drive it away'):format(safe(spot.key), safe(spot.dealer)))
		end
	end
	return id, nil
end

--- Takes one preview vehicle out of the world. Never raises.
local function lower(key)
	local id = showroom[key]
	if id == nil then return end
	showroom[key] = nil
	local api = Open77.vehicles
	if type(api) == 'table' and type(api.remove) == 'function' then
		local removed, answer = pcall(api.remove, id)
		if not removed or answer ~= true then
			Open77.log.warn(('[dealership] the showroom car %s was not removed: %s')
				:format(safe(key), tostring(removed and answer or 'raised')))
		end
	end
end

--- Brings one preview point's car into line with what the point says.
local function dress(spot)
	lower(spot.key)
	if not Access.PreviewsEnabled() then return end
	local id, why = raise(spot)
	if id == nil then
		Open77.log.warn(('[dealership] the showroom car %s was not created: %s')
			:format(safe(spot.key), tostring(why)))
		return
	end
	showroom[spot.key] = id
end

--- Rebuilds the merged showroom. Called at load and after the adoption.
-- CONFIG WINS, the same way and for the same reason it wins for dealers: the
-- file is the copy somebody has, and a stale database row of the same key
-- silently moving a car an operator moved in the file would be a car they cannot
-- move by editing the one place they are told to edit.
local function rebuildPreviews()
	previews = {}
	for key, spot in pairs(configPreviews) do previews[key] = spot end
	for key, spot in pairs(adoptedPreviews) do
		if previews[key] == nil then previews[key] = spot end
	end
end

--- Stands a car on every point that has a dealer to stand in. Yields per car.
-- @author XEROX710
--
-- ONE RESUME PER CAR, and this is the loop that needs it most in the resource:
-- every pass is a `vehicles.create` round trip. A loop that did the whole floor
-- in one resume runs out of the per-resume instruction budget partway down and
-- the coroutine unwinds with NO error, NO log and NO refusal -- leaving the cars
-- it reached standing and the rest silently missing. That failure has cost this
-- codebase five outages; `core/shared/lifecycle.lua` `runPhase` and
-- `modules/admin/client/target.lua` `register()` are the worked examples.
--
-- MUST BE CALLED FROM A THREAD. It is called from the boot thread and nowhere
-- else; `Wait` outside one is a raise.
--
-- The per-dealer LIMIT is enforced here and not only at the config check,
-- because an adopted row can push a configured floor over it and nothing
-- validates the two together until they are merged.
local function raiseFloor()
	local keys = {}
	for key in pairs(previews) do keys[#keys + 1] = key end
	table.sort(keys)
	local standing = {}
	for index = 1, #keys do
		Wait(0)
		local spot = previews[keys[index]]
		if spots[spot.dealer] == nil then
			-- A preview whose dealer is gone is a car in a field. It is kept in
			-- the table -- the dealer may come back on the next edit of the
			-- config -- and simply not stood up.
			Open77.log.warn(('[dealership] the showroom car %s names the dealer %s, ' ..
				'which does not exist; it is not created')
				:format(safe(spot.key), safe(spot.dealer)))
		elseif Access.PREVIEW_LIMIT > 0
			and (standing[spot.dealer] or 0) >= Access.PREVIEW_LIMIT then
			Open77.log.warn(('[dealership] the showroom car %s is over PREVIEW.LIMIT (%d) for ' ..
				'the dealer %s; it is not created')
				:format(safe(spot.key), Access.PREVIEW_LIMIT, safe(spot.dealer)))
		else
			standing[spot.dealer] = (standing[spot.dealer] or 0) + 1
			dress(spot)
		end
	end
end

-- THE TWO WRITERS ARE GONE. `M.PlacePreview` and `M.RemovePreview` stood here,
-- and the whole of what they wrote is now `PREVIEW.POINTS` in
-- `config/dealership.lua`. The reader below is untouched: rows an operator
-- placed before today are still adopted at boot and still printed as the config
-- line that recreates them, so nothing anybody put on a showroom floor is lost.
--
-- `Store.PlacePreview` and `Store.RemovePreview` go with them for the reason
-- `modules/garages/server/storage.lua` gives about its own: a writer with no
-- caller is one the next reader wires a new command to.

--- Every preview point, as a client or a menu reads them.
-- @author XEROX710
-- @return table[]
local function previewList()
	local listed = {}
	for _, spot in pairs(previews) do
		local entry = Access.Entry(spot.entry)
		listed[#listed + 1] = {
			key = spot.key,
			dealer = spot.dealer,
			entry = spot.entry,
			model = entry ~= nil and entry.label or spot.entry,
			standing = showroom[spot.key] ~= nil,
		}
	end
	table.sort(listed, function(left, right) return left.key < right.key end)
	return listed
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- One purchase off the wire. Rate-limited, then answered either way.
--- The stock key an answer names back to the client: a row of the stock, or nil.
---
--- THE CLIENT'S OWN ARGUMENT WAS ECHOED, whatever it was: an entry key of 48
--- KiB came back as 48 KiB on every refusal. Only a key that names a row is
--- one the client can match an answer to.
local function echoOf(entryKey)
	if Access.Entry(entryKey) ~= nil then return entryKey end
	return nil
end

local function onRequested(dealerKey, entryKey, destKey)
	local src = tonumber(source)
	if src == nil then return end
	if dealerKey ~= nil and type(dealerKey) ~= 'string' then dealerKey = nil end
	if destKey ~= nil and type(destKey) ~= 'string' then destKey = nil end
	if type(entryKey) ~= 'string' or entryKey == '' then
		return OPX.Refuse(src, 'error.badRequest', M.Operation.BUY)
	end

	-- The floor between two purchases. Long enough that a double-tap on a menu
	-- row is one car: the menu closes on the first press and a second is a
	-- request the player did not mean to make.
	if Access.COOLDOWN_MS > 0 and OPX.Cooling(src, 'dealership.buy', Access.COOLDOWN_MS) then
		return OPX.Refuse(src, 'error.tooFast', M.Operation.BUY)
	end
	if not within(src, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
		return OPX.Refuse(src, 'error.tooFast', M.Operation.BUY)
	end

	CreateThread(function()
		local bought = OPX.Life.Down(src) and Result.Err('error.incapacitated')
			or M.Buy(src, dealerKey, entryKey, destKey)
		if not bought.ok then
			-- The refusal is the toast. A second one through the platform's
			-- notifications put the same sentence on screen twice.
			OPX.Refuse(src, bought.error, M.Operation.BUY)
			TriggerClientEvent(M.Event.ANSWER, src, false, bought.error, echoOf(entryKey))
			Open77.log.info(('[dealership] player %d refused %s: %s'):format(src,
				safe(entryKey), tostring(bought.error)))
			return
		end
		local value = bought.value
		toldBought(src, value)
		TriggerClientEvent(M.Event.ANSWER, src, true, nil, echoOf(entryKey), value)
		Open77.log.info(('[dealership] player %d bought %s'):format(src, safe(value.plate)))
	end)
end

--- One offer off the wire, from a salesperson to the player they picked.
local function onOffered(buyer, entryKey)
	local src = tonumber(source)
	if src == nil then return end
	if type(entryKey) ~= 'string' or entryKey == '' then
		return OPX.Refuse(src, 'error.badRequest', M.Operation.OFFER)
	end
	if not within(src, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
		return OPX.Refuse(src, 'error.tooFast', M.Operation.OFFER)
	end

	CreateThread(function()
		local offered = OPX.Life.Down(src) and Result.Err('error.incapacitated')
			or M.Offer(src, buyer, entryKey)
		if not offered.ok then
			-- No toast from here: the SETTLED handler on the seller's client
			-- raises one. This comment was written over an `OPX.Refuse` that
			-- was still here, so the seller read every refusal twice.
			TriggerClientEvent(M.Event.SETTLED, src,
				{ ok = false, error = offered.error, entry = echoOf(entryKey) })
			return
		end
		OPX.NotifyLocale(src, 'dealership.offerSent', nil, 'info')
	end)
end

--- One buyer's answer off the wire.
local function onDecided(token, yes, destKey)
	local src = tonumber(source)
	if src == nil then return end
	if not within(src, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
		return OPX.Refuse(src, 'error.tooFast', M.Operation.DECIDE)
	end

	CreateThread(function()
		-- A YES FROM THE FLOOR IS NOT A YES. The money is the buyer's and the
		-- down screen is the client's; a no still goes through, so the seller
		-- is not left waiting on somebody who cannot answer.
		local settled
		if yes == true and OPX.Life.Down(src) then
			settled = Result.Err('error.incapacitated')
		else
			settled = M.Accept(src, token, yes == true,
				type(destKey) == 'string' and destKey or nil)
		end
		-- A DECLINE IS THE BUYER'S OWN ANSWER. `Accept` answers it as
		-- `offerDeclined`, which is the SELLER's sentence -- "They turned the
		-- offer down." -- and the buyer who said no was shown it as an error,
		-- twice (this toast and the client's). They know; nothing is said.
		if yes ~= true and not settled.ok and settled.error == 'dealership.offerDeclined' then
			return
		end

		if not settled.ok then
			OPX.Refuse(src, settled.error, M.Operation.DECIDE)
			TriggerClientEvent(M.Event.ANSWER, src, false, settled.error)
			return
		end
		toldBought(src, settled.value)
		TriggerClientEvent(M.Event.ANSWER, src, true, nil, settled.value.entry, settled.value)
	end)
end

-- ── the commands ────────────────────────────────────────────────────────────

--- Registers one command from the config, or nothing when it is unnamed.
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

--- Prints the stock the way the catalogue reads: class, model, price and which
--- kind of dealer sells it.
local function reportStock(source)
	local entries = {}
	for kind in pairs(Access.KINDS) do
		local listed = Access.For(kind)
		for index = 1, #listed do
			local entry = listed[index]
			entries[#entries + 1] = ('%s %s %s %s %s'):format(
				kind, entry.class, entry.key, entry.label,
				currency ~= nil and character ~= nil
					and character.FormatMoney(entry.price, currency)
					or tostring(entry.price))
		end
	end
	table.sort(entries)
	if #entries == 0 then
		return OPX.CommandResult(source, true, 'the stock list is empty: nothing is for sale')
	end
	entries[#entries + 1] = ('%d row(s); %d garage, %d avpad'):format(#entries,
		#Access.For(M.KIND.GARAGE), #Access.For(M.KIND.AVPAD))
	OPX.CommandResult(source, true, table.concat(entries, '\n'))
end

--- Prints every dealer, every showroom car standing on its floor, and whether
--- the dealer came from config or was adopted out of the legacy table.
local function report(source)
	local lines = {}
	local keys, adoptedCount = {}, 0
	for key in pairs(spots) do keys[#keys + 1] = key end
	table.sort(keys)
	for index = 1, #keys do
		local spot = spots[keys[index]]
		local legacy = adopted[spot.key] ~= nil and configSpots[spot.key] == nil
		if legacy then adoptedCount = adoptedCount + 1 end
		lines[#lines + 1] = ('%s %s %s pos=%.2f,%.2f,%.2f yaw=%.1f bucket=%d %s'):format(
			spot.key, spot.kind, spot.label, spot.x, spot.y, spot.z, spot.heading,
			spot.bucket, legacy and 'legacy' or 'config')
	end
	for _, preview in ipairs(previewList()) do
		lines[#lines + 1] = ('  preview %s at %s: %s %s'):format(preview.key, preview.dealer,
			preview.model, preview.standing and 'standing' or 'NOT STANDING')
	end
	lines[#lines + 1] = ('%d dealer(s): %d from config, %d adopted; %d showroom car(s)')
		:format(#keys, #keys - adoptedCount, adoptedCount, #previewList())
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- Registers the listing and purchase commands.
-- `add` and `remove` are gone: they placed a dealer from a chat line into a
-- table only one host had. See the header.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.list, { restricted = true, help = 'dealership.help.list' }, function(source)
		report(source)
	end)

	register(names.stock, { restricted = false, help = 'dealership.help.stock' }, function(source)
		reportStock(source)
	end)

	register(names.buy, {
		restricted = false,
		help = 'dealership.help.buy',
		params = {
			{ name = 'key', help = locale('dealership.help.buyKey') },
			{ name = 'garage', optional = true, help = locale('dealership.help.buyGarage') },
		},
		cooldownMs = Access.COOLDOWN_MS,
		-- THE NET DOOR'S WINDOW, not one of its own: the command and the menu
		-- are one purchase, and two floors let a player use one, then the other.
		key = 'dealership.buy',
	}, function(source, args)
		local entryKey = type(args[1]) == 'string' and args[1] or ''
		if #entryKey == 0 then
			return OPX.CommandResult(source, false, 'usage: buy <key> [garage] -- stand on a ' ..
				'dealership marker; /' .. tostring(names.stock or '') .. ' lists what is for sale')
		end
		local destKey = type(args[2]) == 'string' and args[2] or nil
		CreateThread(function()
			local bought = M.Buy(source, nil, entryKey, destKey)
			if not bought.ok then
				OPX.NotifyLocale(source, bought.error, nil, 'error')
				return OPX.CommandResult(source, false, tostring(bought.error))
			end
			local value = bought.value
			toldBought(source, value)
			OPX.CommandResult(source, true, ('%s bought: %s%s'):format(value.model,
				tostring(value.plate),
				value.garage ~= nil and (' delivered to ' .. tostring(value.garage)) or ''))
		end)
	end)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state from config and contributes this module's tables. Never
--- yields.
-- @author XEROX710
function M.Init()
	configSpots = Access.SPOTS
	adopted = {}
	rebuild()
	configPreviews = Access.PREVIEW_POINTS
	adoptedPreviews = {}
	showroom = {}
	rebuildPreviews()
	windows = {}
	offers = {}
	buying = {}
	nextOffer = 0
	unsaved, nextPending, sweeping = {}, 0, false
	running = false
	currency = nil
	stockFor = { [M.KIND.GARAGE] = {}, [M.KIND.AVPAD] = {} }
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server half of the dealership contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('dealership', 1, {
		Buy = M.Buy,
		Offer = M.Offer,
		Accept = M.Accept,
		Previews = function() return Result.Ok({ previews = previewList() }) end,
		Spots = function() return spots end,
		Stock = function()
			local listed = {}
			for key, entry in pairs(Access.STOCK) do
				listed[key] = { label = entry.label, class = entry.class,
					price = entry.price, av = entry.av }
			end
			return Result.Ok({ currency = currency, stock = listed })
		end,
		--- One company's balance, for whatever grows a bank screen next.
		Balance = function(kind, group)
			if type(kind) ~= 'string' or type(group) ~= 'string' then
				return Result.Err('error.badRequest')
			end
			local read = Store.Balance(kind, group)
			if not read.ok then return read end
			local row = type(read.value) == 'table' and read.value or nil
			return Result.Ok({ kind = kind, group = group,
				balance = math.floor(Access.FiniteNumber(row and row.balance) or 0) })
		end,
		State = function()
			local dealers = {}
			for key, spot in pairs(spots) do
				dealers[key] = { kind = spot.kind, label = spot.label,
					adopted = adopted[key] ~= nil and configSpots[key] == nil }
			end
			local total = OPX.Table.Count(Access.STOCK)
			return Result.Ok({ dealers = dealers, stock = total, currency = currency,
				previews = #previewList(), standing = OPX.Table.Count(showroom) })
		end,
	})
end

--- Resolves the contracts, adopts the legacy dealers, dresses the floor and
--- wires the doors.
-- @author XEROX710
function M.Start()
	character = OPX.Api.Get('character')
	vehicles = OPX.Api.Get('vehicles')
	garages = OPX.Api.Get('garages')
	keys = OPX.Api.Get('vehiclekeys')

	if character == nil then
		Open77.log.warn('[dealership] no character contract: nothing can be charged or proved ' ..
			'owned, so every purchase is refused')
	end
	if vehicles == nil then
		Open77.log.error('[dealership] no vehicles contract: nothing can be sold, and every ' ..
			'purchase is refused')
	end
	-- Said once, at start, because the difference is one choice and not a
	-- broken dealership: without it the vehicles module's own default garage is
	-- where a bought vehicle is filed.
	if garages == nil then
		Open77.log.info('[dealership] no garages contract: a purchase is filed under the ' ..
			'vehicles module\'s default garage, and no destination can be chosen')
	end

	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[dealership] config: ' .. line)
	end

	-- THE CURRENCY IS CHECKED ONCE, HERE. A price denominated in something the
	-- character contract does not know would refuse every purchase with
	-- `money.badType` in the middle of a player's evening; said at boot it is a
	-- line an operator reads after editing the config, and every purchase
	-- afterwards refuses with one code that names the configuration.
	currency = type(M.Settings.CURRENCY) == 'string' and M.Settings.CURRENCY or nil
	if character ~= nil and currency ~= nil and not character.IsMoneyType(currency) then
		Open77.log.error(('[dealership] CURRENCY %s is not a money type on this server: ' ..
			'nothing can be sold until it is fixed'):format(tostring(currency)))
		currency = nil
	end

	-- The stock as a client reads it, with the price formatted by the contract
	-- that owns the currency table. Built once: a payload rebuilt per ask would
	-- format the whole catalogue on every poll of every player.
	for kind in pairs(Access.KINDS) do
		local rows = {}
		local listed = Access.For(kind)
		for index = 1, #listed do
			local entry = listed[index]
			local text = currency ~= nil and character ~= nil
				and character.FormatMoney(entry.price, currency)
				or tostring(entry.price)
			rows[index] = Access.Wire(entry, text)
		end
		stockFor[kind] = rows
	end

	registerCommands()

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		-- A FLOOR, as every other door here has one: each ask is a character
		-- read, a bucket filter, a sort and a payload, and a client polls every
		-- POLL_MS (15 s). Faster than once a second is not a client polling.
		if OPX.Cooling(player, 'dealership.ask', 1000) then return end
		sync(player)
	end)

	RegisterNetEvent(M.Event.BUY, onRequested)
	RegisterNetEvent(M.Event.OFFER, onOffered)
	RegisterNetEvent(M.Event.DECIDE, onDecided)
	-- THE PLACEMENT DOOR IS GONE. `M.PlacePreview`, `M.RemovePreview`, the two
	-- net handlers behind them and the `opx.dealership.place` right that gated
	-- them all stood here until the owner said "retire cela aussi".
	--
	-- They were the runtime half of a feature that no longer has a runtime half:
	-- the staff Dev screen was the only caller, it was removed on the owner's
	-- word ("pass moi tous dans les config"), and the showroom is now written in
	-- `PREVIEW.POINTS`. What was left was a door with no handle on the inside --
	-- a wire verb nothing sends, guarded by an ACL right granted to somebody, on
	-- a write path with no reader. That is worse than either having it or not:
	-- it is a live entry point nobody exercises and therefore nobody notices.
	--
	-- The TABLE is untouched. `opx77_dealership_previews` is still created, still
	-- read, and every row in it is still adopted at boot and still printed as the
	-- config line that recreates it. Nothing an operator placed is lost.

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player ~= nil then
			windows[player] = nil
			-- An offer whose buyer left is an offer nobody can answer. The seller
			-- is told, rather than left waiting for a timeout that says nothing
			-- about why.
			local offer = offers[player]
			if offer ~= nil then
				offers[player] = nil
				TriggerClientEvent(M.Event.SETTLED, offer.seller,
					{ ok = false, error = 'dealership.buyerGone', entry = offer.entry })
			end
			-- And one whose SELLER left cannot be settled either: the commission
			-- has nowhere to go and the zone check would refuse it anyway.
			for buyer, live in pairs(offers) do
				if live.seller == player then
					offers[buyer] = nil
					-- WITHDRAWN, which the buyer's client acts on: it closes the
					-- offer screen. SETTLED is the seller's channel, and the
					-- buyer's client published it and left the screen up.
					TriggerClientEvent(M.Event.WITHDRAWN, buyer,
						{ token = live.token, error = 'dealership.sellerGone' })
				end
			end
		end
	end)

	running = true
	CreateThread(function()
		local rows = Store.FetchAll()
		if not rows.ok then
			Open77.log.error('[dealership] the legacy dealers could not be read: ' ..
				tostring(rows.detail))
		else
			local loaded = type(rows.value) == 'table' and rows.value or {}
			local accepted, refused = 0, 0
			for index = 1, #loaded do
				-- ONE RESUME PER ROW, for the reason written at the same loop in
				-- `modules/garages/server/main.lua`: a resume that runs out of
				-- instruction budget unwinds with no error and no log, leaving
				-- the rows it reached and silently dropping the rest.
				Wait(0)
				local row = loaded[index]
				local spot, why = Access.FromDefinition(row.spot_key, {
					KIND = row.kind, LABEL = row.label,
					X = row.x, Y = row.y, Z = row.z, HEADING = row.heading, BUCKET = row.bucket,
				})
				if spot == nil then
					refused = refused + 1
					Open77.log.warn('[dealership] a legacy dealer was refused: ' .. tostring(why))
				else
					accepted = accepted + 1
					adopted[spot.key] = spot
				end
			end
			rebuild()

			local orphans = {}
			for key in pairs(adopted) do
				if configSpots[key] == nil then orphans[#orphans + 1] = key end
			end
			table.sort(orphans)
			Open77.log.info(('[dealership] ready: %d config, %d adopted, %d refused; ' ..
				'%d garage row(s) and %d avpad row(s) for sale in %s'):format(
				OPX.Table.Count(configSpots), #orphans, refused,
				#Access.For(M.KIND.GARAGE), #Access.For(M.KIND.AVPAD),
				tostring(currency or 'no currency')))

			-- EVERY ADOPTED DEALER, AS THE CONFIG LINE THAT WOULD RECREATE IT.
			-- The line the old `add` handed the operator was handed to one
			-- player, once, in a chat box. THIS IS THE OTHER HALF OF THE
			-- MIGRATION: the adoption keeps the server running, and these lines
			-- are how an operator stops needing it.
			for index = 1, #orphans do
				Wait(0)
				local spot = adopted[orphans[index]]
				Open77.log.info(('[dealership] config line: %s = { LABEL = %q, KIND = %q, ' ..
					'X = %.2f, Y = %.2f, Z = %.2f, HEADING = %.1f, BUCKET = %d },')
					:format(spot.key, spot.label, spot.kind, spot.x, spot.y, spot.z,
						spot.heading, spot.bucket))
			end
			if #orphans > 0 then
				Open77.log.warn(('[dealership] %d dealer(s) exist only in opx77_dealerships. ' ..
					'The commands that made them are gone: paste the config line(s) above into ' ..
					'config/dealership.lua, or they are one dropped database away from lost')
					:format(#orphans))
			end
		end

		-- ── the showroom, once the dealers are known ─────────────────────
		--
		-- A SHOWROOM CAR IS CONFIG NOW, exactly like the dealer it stands in.
		-- `PREVIEW.POINTS` in `config/dealership.lua` is the list; the database
		-- is read for the cars placed before 2026-09-21, when the staff menu's
		-- Dev screen still wrote them, and every one of those is printed back
		-- as the config line that recreates it. Same two halves as the dealer
		-- migration above: the adoption keeps the floor dressed, and the lines
		-- are how an operator stops needing it.
		local floor = Store.FetchPreviews()
		if not floor.ok then
			Open77.log.error('[dealership] the showroom could not be read: ' ..
				tostring(floor.detail))
		else
			local listed = type(floor.value) == 'table' and floor.value or {}
			for index = 1, #listed do
				-- ONE RESUME PER ROW. This loop no longer creates a vehicle --
				-- `raiseFloor` below does -- but a coercion apiece is still
				-- enough to walk into the per-resume instruction budget on a
				-- large showroom, and a resume that runs out unwinds with no
				-- error and no log.
				Wait(0)
				local row = listed[index]
				local spot, why = Access.PreviewFromDefinition(row.preview_key, {
					X = row.x, Y = row.y, Z = row.z, HEADING = row.heading, BUCKET = row.bucket,
					DEALER = row.dealer_key, ENTRY = row.entry_key,
				})
				if spot == nil then
					Open77.log.warn('[dealership] a legacy showroom car was refused: ' ..
						tostring(why))
				else
					adoptedPreviews[spot.key] = spot
				end
			end
			rebuildPreviews()

			-- EVERY CAR THAT EXISTS ONLY IN THE DATABASE, as the config line
			-- that would recreate it. Printed at EVERY start and not once into
			-- one operator's chat box, which is what the Dev screen did and why
			-- nobody ever had a copy of their own showroom.
			local orphans = {}
			for key in pairs(adoptedPreviews) do
				if configPreviews[key] == nil then orphans[#orphans + 1] = key end
			end
			table.sort(orphans)
			for index = 1, #orphans do
				Wait(0)
				local spot = adoptedPreviews[orphans[index]]
				Open77.log.info(('[dealership] config line: %s = { X = %.2f, Y = %.2f, ' ..
					'Z = %.2f, HEADING = %.1f, BUCKET = %d, DEALER = %q, ENTRY = %q },')
					:format(spot.key, spot.x, spot.y, spot.z, spot.heading, spot.bucket,
						spot.dealer, spot.entry))
			end
			if #orphans > 0 then
				Open77.log.warn(('[dealership] %d showroom car(s) exist only in ' ..
					'opx77_dealership_previews. The menu that placed them is gone: paste the ' ..
					'config line(s) above into PREVIEW.POINTS in config/dealership.lua, or ' ..
					'they are one dropped database away from lost'):format(#orphans))
			end

			raiseFloor()
			Open77.log.info(('[dealership] showroom: %d from config, %d adopted, %d standing')
				:format(OPX.Table.Count(configPreviews), #orphans,
					OPX.Table.Count(showroom)))
		end

		-- A player who connected while the database was being read asked too
		-- early and was told nothing; they ask again on their own cadence.
		syncAll()
	end)

	-- The ledger of deposits that did not land, paid in once at boot -- a
	-- previous run may have left some -- and then every PENDING_SWEEP_MS.
	CreateThread(function()
		M.SettlePending()
		while running do
			Wait(PENDING_SWEEP_MS)
			if running then M.SettlePending() end
		end
	end)

	-- A sweep for the rate-limit windows, so a long session does not accumulate
	-- one per player that ever asked.
	CreateThread(function()
		while running do
			Wait(WINDOW_GC_MS)
			local at = OPX.Now()
			for player, window in pairs(windows) do
				if at - (window.started or at) > WINDOW_GC_MS then windows[player] = nil end
			end
		end
	end)
end

--- Takes the showroom down and stops the sweep.
-- THE SHOWROOM IS THE ONLY THING THIS MODULE HAS TO CLEAN UP. Its cars are
-- `persistent`, which is what stops them despawning when nobody is looking --
-- and which means a reload that left them standing would leave a duplicate
-- showroom behind every time.
-- @author XEROX710
function M.Stop()
	running = false
	for key in pairs(showroom) do lower(key) end
	showroom = {}
	windows = {}
	offers = {}
end
