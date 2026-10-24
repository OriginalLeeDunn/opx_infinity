--- Owned vehicles: the policy. Every statement it runs lives in server/storage.lua.
-- @author dop42

local M = OPX.Modules.Get('vehicles')

local Result = OPX.Result
local Store = M.Storage
local STATE = M.Storage.STATE

-- Spawned vehicles by plate, with their runtime id and owner. Rebuilt empty by
-- `Init`: the host removes what this resource created when it stops.
local live

-- Plates a `M.Spawn` is part-way through, so a second one is refused rather than
-- creating a second car from the same row. SEPARATE FROM `live`, which means "a
-- vehicle is out" and is read for exactly that by six other functions: a plate
-- is claimed both when nothing is out (a fresh spawn) and when something is (a
-- recall, which puts the old one away first and leaves `live` empty while it
-- does), and neither state fits in there. Rebuilt empty by `Init` with `live`,
-- because a claim held across a restart would be a plate nobody can ever bring
-- out again.
local claiming

-- Plates an `M.Store` is part-way through. NOT `claiming`: a recall holds the
-- claim and then calls `M.Store` itself, so the two have to be separate sets.
-- Without it two stores of one plate -- a save pass finding the owner gone while
-- the departure sweep puts the same car away, or a STORE request landing inside
-- a recall -- both read the snapshot and both yield on the row, and the one that
-- lost the removal saw `remove` answer false for a car that was already gone: it
-- wrote OUT over the STORED the winner had just written, logged "could not be
-- removed", and told the player the store was refused. Rebuilt with `live`.
local storing

-- The last citizen id each connection had a vehicle out for. The character
-- module logs a player out on its own disconnect handler, which runs before
-- this module's -- this module requires it, so it starts after it and registers
-- after it -- so by the time the departure reaches here the contract no longer
-- names the character that left.
local owners

-- The character contract, resolved in `Start`. Nil means nobody can prove they
-- own anything, and every door refuses.
local character

-- Plates drawn before the answer is `vehicle.plateExhausted`.
local PLATE_TRIES = 5

-- Longest TweakDB record accepted. Refused here for a reason a caller can read,
-- although the host caps it too.
local MAX_RECORD = 256

--- Answers a value as a finite number, or nil. Named for what it RETURNS: four
--- other files use a local called `finite` for the predicate, and one name for
--- both is an `if finite(x) then` that is true for nil.
local finiteNumber = OPX.Math.Finite

-- Re-read occupants at the final removal boundary, after storage yielded.
local function emptyBeforeRemoval(plateId)
	return function()
		local record = live[plateId]
		local snapshot = record ~= nil and Open77.vehicles.get(record.id) or nil
		local occupants = type(snapshot) == 'table' and snapshot.occupants or nil
		if type(occupants) == 'table' and #occupants > 0 then return false, 'vehicle.occupied' end
		return true
	end
end

--- Draws a plate in the configured shape.
-- `OPX.String.Random` draws ASCII capitals and digits, which is what the column
-- needs: `plate` is `ascii_bin`, so a lower-case or accented character would
-- either be refused or compare as a different plate.
local function plate()
	return OPX.String.Random(M.Settings.PLATE_FORMAT)
end

--- Answers the character this connection has loaded, or nil.
-- The only ownership oracle there is: a citizen id in a payload is a claim.
local function characterOf(source)
	if character == nil then return nil end
	local player = character.GetPlayer(source)
	return player and player.PlayerData or nil
end

--- Whether the character owning a plate is still loaded somewhere.
-- Unknown, when there is no contract to ask, reads as loaded: putting a vehicle
-- away because the question could not be answered would empty the world.
local function ownerLoaded(citizenId)
	if character == nil then return true end
	return character.GetPlayerByCitizenId(citizenId) ~= nil
end

--- The litres in a live vehicle's tank: the `fuel` field of its state bag, the
--- platform's (`open77_fuel`) and `modules/fuel`'s. Nil when nobody has written
--- one, which the row keeps as "never measured" rather than as empty.
-- READ OFF THE BAG AND NOT ASKED OF `fuel`: the field is the platform's, and a
-- server running `open77_fuel` without this resource's fuel module still has a
-- tank worth keeping. A read, so no permission and no yield.
local function fuelOf(vehicleId)
	local state = Open77.state
	if type(state) ~= 'table' or type(state.entity) ~= 'function' then return nil end
	local read, litres = pcall(function() return state.entity('vehicle', vehicleId).fuel end)
	litres = read and finiteNumber(litres) or nil
	if litres == nil or litres < 0 then return nil end
	return litres
end

--- Gives a vehicle that just came out the tank it was put away with. Through
--- the fuel contract when it runs -- it clamps to the tank and writes through
--- `open77_fuel` when standing down for it -- and straight onto the bag field
--- otherwise, which is all the contract would do.
local function restoreFuel(vehicleId, litres)
	if litres == nil then return end
	local fuel = OPX.Api.Get('fuel')
	if fuel ~= nil and type(fuel.Restore) == 'function' then
		local ran, written = pcall(fuel.Restore, vehicleId, litres)
		if ran and written == true then return end
	end
	local state = Open77.state
	if type(state) ~= 'table' or type(state.entity) ~= 'function' then return end
	local read, bag = pcall(state.entity, 'vehicle', vehicleId)
	if read and bag ~= nil then pcall(bag.set, bag, 'fuel', litres) end
end

--- Copies a spawned vehicle's health, damage, flags and tank onto its row.
local function applyCondition(vehicle, record, snapshot)
	vehicle.health = finiteNumber(snapshot.health) or vehicle.health
	vehicle.damage = Open77.vehicles.getDamage(record.id)
	vehicle.metadata = vehicle.metadata or {}
	vehicle.metadata.flags = finiteNumber(snapshot.flags)
	vehicle.fuel = fuelOf(record.id) or vehicle.fuel
end

-- ONE REGISTRATION PER CHARACTER AT A TIME, citizen id -> when it began. The
-- ceiling is counted (a yield) and then the row inserted (another), so two
-- registrations for one character in the same moment both counted the same
-- number and both went in: a character at PER_CHARACTER - 1 ended with one
-- over. The dealership serialises its own buyers; a staff grant, a reward from
-- another module and a purchase did not. A registration now waits for the one
-- in flight for that character, then counts afresh.
local registering = {}
local REGISTER_WAIT_MS = 5000
local REGISTER_POLL_MS = 50

local registerNow

--- Stores a new vehicle for a character under a fresh plate.
-- @author dop42
-- @param citizenId CitizenId
-- @param record string A TweakDB vehicle record.
-- @param options table|nil appearance, garage, paint and metadata.
-- @return Result
function M.Register(citizenId, record, options)
	if type(citizenId) ~= 'string' then
		return Result.Err('error.badRequest', 'citizenId and record are required')
	end
	local deadline = OPX.Now() + REGISTER_WAIT_MS
	while registering[citizenId] ~= nil do
		if OPX.Now() >= deadline then return Result.Err('vehicle.registering', citizenId) end
		Wait(REGISTER_POLL_MS)
	end
	local mine = { since = OPX.Now() }
	registering[citizenId] = mine
	local ran, answer = pcall(registerNow, citizenId, record, options)
	if registering[citizenId] == mine then registering[citizenId] = nil end
	if not ran then error(answer, 0) end
	return answer
end

registerNow = function(citizenId, record, options)
	options = options or {}
	if type(citizenId) ~= 'string' or type(record) ~= 'string' or record == '' then
		return Result.Err('error.badRequest', 'citizenId and record are required')
	end
	if #record > MAX_RECORD then return Result.Err('vehicle.badRecord', 'record is too long') end

	if M.Settings.PER_CHARACTER > 0 then
		local owned = Store.CountByOwner(citizenId)
		if not owned.ok then return owned end
		if owned.value >= M.Settings.PER_CHARACTER then
			return Result.Err('vehicle.limit', tostring(M.Settings.PER_CHARACTER))
		end
	end

	local entity
	for _ = 1, PLATE_TRIES do
		entity = {
			plate = plate(),
			citizenId = citizenId,
			record = record,
			appearance = options.appearance,
			garage = options.garage or M.Settings.DEFAULT_GARAGE,
			state = STATE.STORED,
			health = 1.0,
			paint = options.paint,
			metadata = options.metadata or {},
		}
		local inserted = Store.Insert(entity)
		if inserted.ok then
			Open77.log.info(('[vehicles] %s given %s (%s)')
				:format(citizenId, entity.plate, record))
			local owner = character ~= nil and character.GetPlayerByCitizenId(citizenId) or nil
			OPX.Publish(M.Event.ON_REGISTERED, owner and owner.PlayerData.source or nil, {
				citizenId = citizenId,
				plate = entity.plate,
				record = record,
				garage = entity.garage,
			})
			return Result.Ok(entity)
		end
		-- A duplicate plate is the only insertion failure worth another draw;
		-- every other one is the database, and drawing again would hide it. The
		-- detail is lowered first: the wording of the message depends on the
		-- bridge and on the server version.
		if not tostring(inserted.detail or ''):lower():find('duplicate', 1, true) then
			return inserted
		end
	end
	return Result.Err('vehicle.plateExhausted', entity and entity.plate or '?')
end

--- Trusted server purchase: wallet debit and ownership share one receipt.
-- A pending reply is not refundable; the stored car is recoverable at a garage.
function M.Purchase(source, record, options, payment)
	options, payment = options or {}, payment or {}
	if not character or type(character.AtomicMoney) ~= 'function' then return Result.Err('error.unavailable') end
	local owner = character.GetPlayer(source)
	if not owner then return Result.Err('error.notLoggedIn') end
	if type(record) ~= 'string' or record == '' or #record > MAX_RECORD then return Result.Err('vehicle.badRecord') end
	local amount = math.tointeger(payment.amount)
	if not amount or amount < 0 then return Result.Err('money.badAmount') end
	local citizenId = owner.PlayerData.citizenId
	local deadline = OPX.Now() + REGISTER_WAIT_MS
	while registering[citizenId] do
		if OPX.Now() >= deadline then return Result.Err('vehicle.registering') end
		Wait(REGISTER_POLL_MS)
	end
	local mine = { since = OPX.Now(), pending = true }
	registering[citizenId] = mine
	local function release()
		if registering[citizenId] == mine then registering[citizenId] = nil end
	end
	local entity = { plate = plate(), citizenId = citizenId, record = record,
		appearance = options.appearance, garage = options.garage or M.Settings.DEFAULT_GARAGE,
		state = STATE.STORED, health = 1.0, paint = options.paint, metadata = options.metadata or {} }
	local ran, answer = pcall(character.AtomicMoney, owner, payment.moneyType, amount,
		amount == 0 and 'touch' or 'remove', payment.reason, payment.opId, function(op)
			op.release = release
			op.publish = function()
				OPX.Publish(M.Event.ON_REGISTERED, owner.PlayerData.source, {
					citizenId = citizenId, plate = entity.plate, record = record, garage = entity.garage })
			end
			return function(attempt)
				local statements, guard = Store.PurchaseStatements(entity, attempt, M.Settings.PER_CHARACTER)
				if payment.participant then
					local extra = payment.participant(attempt, entity)
					for index = 1, #(extra or {}) do statements[#statements + 1] = extra[index] end
				end
				return statements, guard
			end
		end)
	if not ran then
		-- AtomicMoney normally catches dispatch exceptions and owns its recovery.
		-- Retain the registration guard if it reports an unresolved operation.
		if not character.IsMoneyPending(citizenId) then release() end
		return Result.Err('money.pending')
	end
	if answer.error ~= 'money.pending' then release() end
	if not answer.ok then return answer end
	local stored = Store.ByPurchase(answer.value.opId)
	if not stored.ok or not stored.value then return Result.Err('money.pending', answer.value.opId) end
	stored.value.opId = answer.value.opId
	return stored
end

--- Answers every vehicle a character owns.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.List(citizenId)
	return Store.FetchByOwner(citizenId)
end

--- Answers the plate and owner of a vehicle this module spawned.
-- Only those: a vehicle created by anything else has no row, and nothing durable
-- may be attached to it.
-- @author dop42
-- @param vehicleId integer
-- @return string|nil plate
-- @return CitizenId|nil owner
function M.PlateOf(vehicleId)
	for plateId, record in pairs(live) do
		if record.id == vehicleId then return plateId, record.citizenId end
	end
	return nil, nil
end

--- Answers the stored row and whether it is spawned now.
-- @author dop42
-- @param plateId string
-- @return Result
function M.Get(plateId)
	local fetched = Store.FetchOne(plateId)
	if not fetched.ok then return fetched end
	local record = live[plateId]
	fetched.value.id = record and record.id or nil
	fetched.value.spawned = record ~= nil
	return fetched
end

--- Spawns a loaded character's own vehicle beside them, or at a named place.
-- `at` is the marker path: a caller that names a position has already decided
-- where the vehicle belongs -- a garage or a pad, validated by whoever owns that
-- spot -- and it is created THERE and turned to `at.yaw`, with no offset, so a
-- marker puts the vehicle on the marker rather than a car's width to one side.
-- A caller that names nothing keeps the beside-the-player behaviour.
--
-- A NAMED PLACE IS ALSO A PROMISE ABOUT A VEHICLE THAT IS ALREADY OUT. See the
-- block below: the vehicle is put away and created again AT the place, so a
-- marker delivers what it says it delivered. Beside-the-player carries no such
-- promise, so it keeps answering with the id the vehicle already has.
-- @author dop42
-- @param source Source
-- @param plateId string
-- @param at table|nil position { x, y, z }, yaw, bucket
-- @return Result
function M.Spawn(source, plateId, at)
	local data = characterOf(source)
	if not data then return Result.Err('vehicle.notLoggedIn', tostring(source)) end
	if type(plateId) ~= 'string' then return Result.Err('error.badRequest', 'plate') end

	-- THE CLAIM IS TAKEN BEFORE THE ROW IS READ (see the long note below for
	-- why there is a claim at all). It used to come after, and the read yields:
	-- `SetState` impounding the plate in that window wrote IMPOUNDED under a
	-- spawn that had already read STORED, which then created the car and wrote
	-- OUT over the impound. `SetState` takes this same claim, so the row this
	-- spawn reads is the row it acts on.
	if claiming[plateId] then return Result.Err('vehicle.busy', plateId) end
	claiming[plateId] = true

	--- Gives the claim back and answers. Every exit below goes through it.
	local function done(result)
		claiming[plateId] = nil
		return result
	end

	local fetched = Store.FetchOne(plateId)
	if not fetched.ok then return done(fetched) end
	local vehicle = fetched.value
	-- Somebody else's vehicle answers exactly what a plate nobody owns answers:
	-- a distinct refusal would tell an attacker the plate is real.
	if vehicle.citizenId ~= data.citizenId then
		OPX.Audit.Security('vehicle.notYours',
			('%s asked for %s'):format(data.citizenId, plateId),
			{ owner = vehicle.citizenId }, source)
		return done(Result.Err('vehicle.notFound', plateId))
	end
	-- AN IMPOUNDED VEHICLE STAYS WHERE IT IS until something releases it with
	-- `SetState`. The state existed in the schema and nothing ever wrote it, so
	-- nothing ever had to refuse it; a pound that the owner's own garage key
	-- empties is not a pound.
	if vehicle.state == STATE.IMPOUNDED then
		return done(Result.Err('vehicle.impounded', plateId))
	end

	-- ── the plate is claimed HERE, before anything else can be ───────────────
	-- THE DUPLICATION RACE, AND WHY THE GUARD BELOW IS NOT ONE ON ITS OWN.
	-- `Store.FetchOne` is a database read and it YIELDS -- `lib/server/storage`
	-- awaits it -- and it happens ABOVE the "already out" test, so two `M.Spawn`
	-- threads for one plate reach that test together.
	--
	-- On the beside-the-player path that is survivable by luck: whichever thread
	-- the database answers first then runs the test, `vehicles.create` and the
	-- `live` write with nothing in between that suspends, so the second finds the
	-- car out. THE RECALL PATH IS NOT. A caller that names a place -- every
	-- garage marker, every pad, every dealer handover -- goes through `M.Store`,
	-- which clears `live` and yields, and then fetches again and yields again.
	-- The plate stands empty in the middle of that, the second thread walks
	-- through, creates a car and writes `live`, and the recaller wakes and
	-- creates another over the top. Two cars from one row, and the first is
	-- ORPHANED: `live` holds one entry per plate, so nothing knows it exists and
	-- nothing will ever put it away, save it or remove it.
	-- `modules/garages/server/main.lua:330` names this race; this is it shut.
	--
	-- A SEPARATE TABLE AND NOT A PLACEHOLDER IN `live`. `live` means "a vehicle
	-- is out" and six other functions read it for exactly that; a plate can be
	-- claimed while nothing is out (a fresh spawn) and while something is (a
	-- recall, which puts the old one away first), and neither is a state `live`
	-- can express without every one of those readers learning about it.
	--
	-- CLAIM FIRST, THEN DO THE WORK, the shape `modules/hauling/server/claim.lua`
	-- uses: there is no yield between the test and the write, so two threads
	-- cannot both pass it. From here to the end of this function EVERY exit goes
	-- through `done`, or a spawn that failed locks the plate for the session.
	--
	-- The three doors in (`vehicle.spawn`, `garages.bring`, `dealership.buy`)
	-- still hold three separate per-player cooldowns, and deliberately: they are
	-- three operations an operator prices separately, and a per-player floor was
	-- never the right shape for this anyway. The thing that must not be done
	-- twice is a PLATE, and that is what is claimed. It is taken above.

	-- ── already out: recalled to the named place, or answered as it is ────
	-- WHAT HAPPENS NEXT IS THE WHOLE OF A MARKER'S PROMISE. Answering `Ok` with
	-- the id the vehicle already has, while it sits on the other side of the map,
	-- is a marker that spawns nothing and says it did: the player is told "brought
	-- out", stands there looking at an empty spot, and presses the key again.
	-- That is the bug this block exists for.
	--
	-- So a caller that NAMED a place -- a garage marker, a pad, a dealer handing
	-- a bought car over -- gets the vehicle THERE: it is put away first, which is
	-- what writes its condition back, and created again below, on the marker and
	-- facing the marker's heading. A caller that named nothing keeps the old
	-- answer, because moving a player's car for a request that said "somewhere
	-- near me" would be a surprise rather than a service.
	local recalled = false
	if live[plateId] ~= nil then
		if type(at) ~= 'table' then
			return done(Result.Ok({ plate = plateId, id = live[plateId].id, alreadyOut = true }))
		end
		-- NOTHING IS YANKED OUT FROM UNDER ANYBODY. The occupant of a live vehicle
		-- is not necessarily the player who asked -- a marker is a public place --
		-- and removing it would take the car out of a driver's hands.
		local snapshot = Open77.vehicles.get(live[plateId].id)
		local occupants = type(snapshot) == 'table' and snapshot.occupants or nil
		if type(occupants) == 'table' and #occupants > 0 then
			return done(Result.Err('vehicle.occupied', plateId))
		end
		local put = M.Store(plateId, nil, emptyBeforeRemoval(plateId))
		if not put.ok then return done(put) end
		-- Read again, because putting it away is what wrote the condition back:
		-- the vehicle created below has to be the row as it now stands.
		fetched = Store.FetchOne(plateId)
		if not fetched.ok then return done(fetched) end
		vehicle = fetched.value
		recalled = true
	end

	local position = Open77.players.position(source)
	if position == nil then
		return done(Result.Err('vehicle.noPosition', tostring(source)))
	end

	-- A named place is read through the same coercions as the player's own, so a
	-- NaN or a string from a caller cannot reach the engine as a coordinate.
	local place, yaw, bucket = nil, nil, finiteNumber(position.bucket)
	if type(at) == 'table' then
		local x, y, z = finiteNumber(at.x), finiteNumber(at.y), finiteNumber(at.z)
		if x ~= nil and y ~= nil and z ~= nil then
			place = { x = x, y = y, z = z }
		end
		yaw = finiteNumber(at.yaw)
		local atBucket = finiteNumber(at.bucket)
		if place ~= nil and atBucket ~= nil then bucket = math.floor(atBucket) end
	end
	if place == nil then
		place = {
			x = position.x + M.Settings.SPAWN_OFFSET,
			y = position.y,
			z = position.z + 0.25,
		}
	end

	local id, reason = Open77.vehicles.create({
		record = vehicle.record,
		appearance = vehicle.appearance,
		position = place,
		yaw = yaw,
		bucket = bucket,
		health = vehicle.health,
		primaryColor = vehicle.paint and vehicle.paint.primary or nil,
		secondaryColor = vehicle.paint and vehicle.paint.secondary or nil,
	})
	if id == nil then return done(Result.Err('vehicle.spawnRefused', tostring(reason))) end

	-- The stored damage and flags are given back, or a put-away-and-fetch cycle
	-- would repair windows, lights, tyres, dents and the destroyed flag for free.
	-- Both answer a boolean, and both were discarded -- so the free repair the
	-- comment above says this prevents happened anyway whenever the host refused,
	-- with nothing said. It is not worth refusing the spawn over, but it is worth
	-- an operator being able to find it.
	if type(vehicle.damage) == 'table' then
		if Open77.vehicles.setDamage(id, vehicle.damage) ~= true then
			Open77.log.warn(('[vehicles] %s came out with its stored damage unapplied; ' ..
				'this fetch repaired it for free'):format(plateId))
		end
	end
	local flags = finiteNumber(vehicle.metadata and vehicle.metadata.flags)
	if flags ~= nil and Open77.vehicles.update(id, { flags = flags }) ~= true then
		Open77.log.warn(('[vehicles] %s came out without its stored flags'):format(plateId))
	end
	-- And the tank, before anything yields: a burn pass that found the bag empty
	-- first would fill it as a fresh car's, and the next store would keep that.
	restoreFuel(id, vehicle.fuel)

	-- The connection is read again after the database read, which yielded:
	-- writing `live` for a character that left meanwhile would leave a vehicle
	-- nothing will ever put away, so it is removed instead.
	local still = characterOf(source)
	if not still or still.citizenId ~= data.citizenId then
		-- The removal is the whole point of this branch -- the comment above says
		-- it is here so there is no vehicle "nothing will ever put away" -- and a
		-- discarded refusal produces precisely that orphan. It cannot be undone
		-- from here, so it is named where an operator will find it.
		if Open77.vehicles.remove(id) ~= true then
			Open77.log.error(('[vehicles] %s was spawned for a character who left and could ' ..
				'not be removed; it is in the world with nothing owning it'):format(plateId))
		end
		return done(Result.Err('vehicle.notLoggedIn', tostring(source)))
	end

	live[plateId] = { id = id, citizenId = data.citizenId }
	owners[source] = data.citizenId
	Store.SetState(plateId, STATE.OUT)
	OPX.Audit.Player(character.GetPlayer(source), 'vehicle.spawn', plateId,
		{ id = tostring(id) })
	-- The engine id goes out as TEXT as well as itself: it carries a generation
	-- and can pass 2^53, where a listener that turns it into JSON stops being exact.
	OPX.Publish(M.Event.ON_SPAWNED, source, {
		citizenId = data.citizenId,
		plate = plateId,
		record = vehicle.record,
		vehicleId = id,
		vehicleKey = tostring(id),
		recalled = recalled or nil,
	})
	-- The claim is given back only now, with `live` already written: a gap
	-- between the two would be the same window in miniature.
	return done(Result.Ok({ plate = plateId, id = id, recalled = recalled or nil }))
end

--- The engine id one plate is out as right now, or nil when it is not out.
-- @author XEROX710
--
-- THE ONE READ IN THIS CONTRACT THAT DOES NOT TOUCH THE DATABASE, and that is
-- the whole reason it exists beside `Get`, which answers the same fact among
-- several others. `garages` asks it once per bring-out, to leave the vehicle it
-- is about to fetch out of its own occupancy check -- a car left standing on the
-- only exit of its own garage would otherwise be a car that can never be
-- recalled. Through `Get` that question cost a `FetchOne`, which YIELDS: one
-- more database round trip on the hottest path this module has, for a fact
-- already sitting in memory.
--
-- It says nothing about ownership on purpose. A caller that needs to know whose
-- vehicle it is has `Get` or `Spawn`, both of which prove it; this answers only
-- "is there an entity for this plate, and which one".
-- @param plateId string
-- @return any|nil the engine id
function M.LiveId(plateId)
	if type(plateId) ~= 'string' then return nil end
	local record = live[plateId]
	return record and record.id or nil
end

--- Answers the plate of a vehicle this connection is sitting in, when it OWNS it.
-- The oracle for "put this away": the seat assignment names the vehicle and the
-- plate table names its owner, so nothing on the wire is consulted -- a plate in
-- a payload is a claim, and this is the one door where the claim would be worth
-- making. A vehicle this module never spawned has no plate and answers nothing;
-- neither does one the connection is only riding in.
-- @author XEROX710
-- @param source Source
-- @return Result Ok({ plate, id }) | Ok(nil) when the connection is on foot
function M.Occupied(source)
	local data = characterOf(source)
	if data == nil then return Result.Err('vehicle.notLoggedIn', tostring(source)) end

	local players = Open77.players
	if type(players) ~= 'table' or type(players.getVehicleSeat) ~= 'function' then
		return Result.Ok(nil)
	end
	local read, assignment = pcall(players.getVehicleSeat, source)
	if not read or type(assignment) ~= 'table' then return Result.Ok(nil) end

	-- Compared as text on purpose: the id is opaque to Lua and the host answers
	-- it as an integer, so an equality test would refuse a vehicle it just made.
	local id = assignment.vehicleId
	if id == nil then return Result.Ok(nil) end
	for plateId, record in pairs(live) do
		if tostring(record.id) == tostring(id) and record.citizenId == data.citizenId then
			return Result.Ok({ plate = plateId, id = record.id })
		end
	end
	return Result.Ok(nil)
end

--- Removes a spawned vehicle and writes its condition back.
-- @author dop42
-- @param plateId string
-- @param garage string|nil Omitted keeps the current garage.
-- @return Result
-- canRemove: optional synchronous predicate, checked after SQL and before removal.
function M.Store(plateId, garage, canRemove)
	local record = live[plateId]
	if record == nil then return Result.Err('vehicle.notSpawned', tostring(plateId)) end
	-- One store per plate at a time; see `storing`. Tested and set with nothing
	-- in between that yields, and every exit below goes through `done`.
	if storing[plateId] then return Result.Err('vehicle.busy', plateId) end
	storing[plateId] = true
	local function done(result)
		storing[plateId] = nil
		return result
	end

	-- The snapshot is read BEFORE the removal: it disappears with the vehicle.
	local priorGarage
	local snapshot = Open77.vehicles.get(record.id)
	if snapshot ~= nil then
		local fetched = Store.FetchOne(plateId)
		if not fetched.ok then
			if type(canRemove) == 'function' then return done(fetched) end
			-- The removal happens anyway, and the line says the condition is
			-- lost rather than deferred: nothing retries it.
			Open77.log.error(('[vehicles] %s is being removed but its row could not be read (%s); ' ..
				'its condition is not written'):format(plateId, tostring(fetched.detail)))
		else
			local vehicle = fetched.value
			priorGarage = vehicle.garage
			applyCondition(vehicle, record, snapshot)
			vehicle.state = STATE.STORED
			if garage ~= nil then vehicle.garage = garage end
			Store.Save(vehicle)
		end
	else
		if type(canRemove) == 'function' then
			local fetched = Store.FetchOne(plateId)
			if not fetched.ok then return done(fetched) end
			priorGarage = fetched.value and fetched.value.garage
		end
		Store.SetState(plateId, STATE.STORED, garage)
	end

	-- THE ANSWER IS READ, AND IT WAS NOT. `Open77.vehicles.remove` answers a
	-- boolean and this discarded it, after the row had already been moved to
	-- STORED. A refused removal therefore ended as: the database says the car is
	-- in the garage, and the car is still standing in the street. Fetching it
	-- again spawns a second one on the same plate -- one row, two cars. That is
	-- a duplication vector, not a cosmetic leak, so the state does not move
	-- until the world has actually given the vehicle up.
	if type(canRemove) == 'function' then
		local called, allowed, code = pcall(canRemove)
		if not called or allowed ~= true then
			Store.SetState(plateId, STATE.OUT, priorGarage)
			return done(Result.Err(called and code or 'vehicle.storeRefused', plateId))
		end
	end
	if Open77.vehicles.remove(record.id) ~= true then
		Open77.log.error(('[vehicles] %s could not be removed from the world; leaving it ' ..
			'spawned rather than recording it as stored'):format(plateId))
		Store.SetState(plateId, STATE.OUT, garage)
		return done(Result.Err('vehicle.storeRefused', plateId))
	end

	live[plateId] = nil
	done(nil)
	-- The owner's connection, when they are still here: the plate's owner is a
	-- citizen id, and a store from a sweep after they left has nobody to name.
	local owner = character ~= nil and character.GetPlayerByCitizenId(record.citizenId) or nil
	OPX.Publish(M.Event.ON_STORED, owner and owner.PlayerData.source or nil, {
		citizenId = record.citizenId,
		plate = plateId,
		garage = garage,
	})
	return Result.Ok({ plate = plateId })
end

--- Puts away every spawned vehicle of one character, or of everyone.
-- @author dop42
-- @param citizenId CitizenId|nil
-- @return integer how many were put away
function M.StoreAll(citizenId)
	-- The plates are collected BEFORE anything yields: a spawn during the walk
	-- would insert a key into the table being walked, which `next` leaves
	-- undefined in Lua.
	local plates = {}
	for plateId, record in pairs(live) do
		if citizenId == nil or record.citizenId == citizenId then plates[#plates + 1] = plateId end
	end

	local stored = 0
	for index = 1, #plates do
		local plateId = plates[index]
		-- Read again: it may have been put away or removed while an earlier one
		-- was awaited.
		if live[plateId] ~= nil and M.Store(plateId).ok then stored = stored + 1 end
	end
	return stored
end

--- The states a caller may move a row to, by name. `out` is not one of them:
--- only `Spawn` puts a vehicle in the world, because only `Spawn` creates it.
local SETTABLE = { stored = STATE.STORED, impounded = STATE.IMPOUNDED }

--- Moves an owned vehicle to stored or impounded, optionally under a garage.
-- @author dop42
--
-- THE IMPOUND DOOR. A vehicle that is out is put away first -- which writes its
-- condition back and takes it off the street -- and refused with
-- `vehicle.occupied` while anybody sits in it, for the reason `Spawn` refuses a
-- recall: the occupant is not necessarily the owner, and a car does not vanish
-- from under a driver because a tow job said so. `impounded` is then refused by
-- `Spawn` until a caller sets it back to `stored`.
-- @param plateId string
-- @param state string `stored` or `impounded`
-- @param garage string|nil the garage key it is filed under; omitted keeps it
-- @return Result { plate, state, garage }
function M.SetState(plateId, state, garage)
	if type(plateId) ~= 'string' or #plateId < 1 or #plateId > 12
		or not plateId:match('^[%w%-]+$') then
		return Result.Err('error.badRequest', 'plate')
	end
	local wanted = type(state) == 'string' and SETTABLE[state:lower()] or nil
	if wanted == nil then return Result.Err('vehicle.badState', tostring(state)) end
	if garage ~= nil and (type(garage) ~= 'string' or #garage < 1 or #garage > 48
		or not garage:match('^[%w_%-%.:]+$')) then
		return Result.Err('error.badRequest', 'garage')
	end

	-- THE PLATE IS CLAIMED FOR THE WHOLE CHANGE, the claim `Spawn` holds from
	-- its read to its `live` write. Without it a spawn that read the row before
	-- this wrote IMPOUNDED went on to create the car and write OUT over the
	-- impound, and a recall's `Store` ran beside this one on the same car.
	if claiming[plateId] then return Result.Err('vehicle.busy', plateId) end
	claiming[plateId] = true
	local function done(result)
		claiming[plateId] = nil
		return result
	end

	local fetched = Store.FetchOne(plateId)
	if not fetched.ok then return done(fetched) end

	local record = live[plateId]
	if record ~= nil then
		local snapshot = Open77.vehicles.get(record.id)
		local occupants = type(snapshot) == 'table' and snapshot.occupants or nil
		if type(occupants) == 'table' and #occupants > 0 then
			return done(Result.Err('vehicle.occupied', plateId))
		end
		local put = M.Store(plateId, garage, emptyBeforeRemoval(plateId))
		if not put.ok then return done(put) end
	end

	local written = Store.SetState(plateId, wanted, garage)
	done(nil)
	if not written.ok then return written end
	OPX.Audit.Log({
		event = 'vehicle.state',
		message = ('%s -> %s'):format(plateId, state:lower()),
		citizenId = fetched.value.citizenId,
		data = { plate = plateId, state = state:lower(), garage = garage },
	})
	local owner = character ~= nil and character.GetPlayerByCitizenId(fetched.value.citizenId) or nil
	OPX.Publish(M.Event.ON_STATE, owner and owner.PlayerData.source or nil, {
		citizenId = fetched.value.citizenId,
		plate = plateId,
		state = state:lower(),
		garage = garage or fetched.value.garage,
	})
	return Result.Ok({ plate = plateId, state = state:lower(),
		garage = garage or fetched.value.garage })
end

--- Saves, or puts away, one vehicle that is out.
local function savePlate(plateId)
	local record = live[plateId]
	if record == nil then return end

	-- A character going back to a selection screen is not a departure and
	-- nothing announces it, so the roster is asked instead: a vehicle whose
	-- owner is no longer loaded is put away rather than saved in place.
	if not ownerLoaded(record.citizenId) then
		M.Store(plateId)
		return
	end

	local snapshot = Open77.vehicles.get(record.id)
	if snapshot == nil then return end
	local fetched = Store.FetchOne(plateId)
	if not fetched.ok then return end
	-- READ AGAIN AFTER THE YIELD. `Save` writes the whole row, state and garage
	-- included, as this read found them -- OUT, under the old garage. A store
	-- that ran while the read was awaited had already written STORED under the
	-- garage the player chose, and this write put it back: the car was in the
	-- garage and the row said it was in the street, filed where it used to be.
	if live[plateId] ~= record or storing[plateId] then return end
	local vehicle = fetched.value
	applyCondition(vehicle, record, snapshot)
	Store.Save(vehicle)
end

--- One pass of the save loop over everything that is out.
-- This loop, and not the stop handler, is what guarantees damage survives: it
-- photographs the keys and wraps each save in a `pcall`, because one raise would
-- end persistence for the whole process, silently.
local function savePass()
	local plates = {}
	for plateId in pairs(live) do plates[#plates + 1] = plateId end

	for index = 1, #plates do
		local plateId = plates[index]
		local ok, failure = pcall(savePlate, plateId)
		if not ok then
			Open77.log.error(('[vehicles] saving %s: %s'):format(plateId, tostring(failure)))
		end
	end
end

--- Puts away what a departing character left out.
local function departed(rawPlayerId)
	local source = tonumber(rawPlayerId)
	if source == nil then return end

	-- The contract first for a departure nobody else has handled yet, then the
	-- id this connection last had a vehicle out for.
	local data = characterOf(source)
	local citizenId = data and data.citizenId or owners[source]
	owners[source] = nil
	if citizenId == nil then return end

	-- On a thread: this handler must return, and every write yields.
	CreateThread(function()
		local stored = M.StoreAll(citizenId)
		if stored > 0 then
			Open77.log.debug(('[vehicles] %s left with %d vehicle(s) out')
				:format(citizenId, stored))
		end
	end)
end

--- Forgets a spawned vehicle the host removed and marks it stored.
local function removed(id, reason)
	id = tonumber(id)
	for plateId, record in pairs(live) do
		-- A STORE IN FLIGHT OWNS THIS PLATE: it is what is removing the car, and
		-- it writes the row and publishes the store itself. Handling the removal
		-- here as well announced one put-away twice.
		if record.id == id and storing[plateId] then return end
		if record.id == id then
			-- Forgotten immediately, and the state written on a thread: the
			-- platform lets an event handler yield, but this one returns at once
			-- and the write waits for nobody.
			live[plateId] = nil
			CreateThread(function() Store.SetState(plateId, STATE.STORED) end)
			Open77.log.info(('[vehicles] %s removed: %s'):format(plateId, tostring(reason)))
			-- Stored as far as the row is concerned, so said as a store, with
			-- the host's reason: a listener tracking what is out must not keep
			-- a car the world took away.
			local owner = character ~= nil and character.GetPlayerByCitizenId(record.citizenId) or nil
			OPX.Publish(M.Event.ON_STORED, owner and owner.PlayerData.source or nil, {
				citizenId = record.citizenId,
				plate = plateId,
				removed = OPX.Audit.Safe(reason, 64),
			})
			return
		end
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state and contributes this module's table. Never yields.
-- @author dop42
function M.Init()
	live = {}
	claiming = {}
	storing = {}
	owners = {}
	registering = {}
	OPX.Schema.Add(M.Storage.SCHEMA)
	OPX.Schema.AddColumns(M.Storage.COLUMNS)
end

--- Publishes the contract. Nothing may read one before this phase ends.
-- @author dop42
function M.Api()
	OPX.Api.Provide('vehicles', 1, {
		Register = M.Register,
		Purchase = M.Purchase,
		List = M.List,
		Get = M.Get,
		PlateOf = M.PlateOf,
		LiveId = M.LiveId,
		Occupied = M.Occupied,
		Spawn = M.Spawn,
		Store = M.Store,
		StoreAll = M.StoreAll,
		-- Stored or impounded, by name; the impound door. See `M.SetState`.
		SetState = M.SetState,
	})
end

--- Wires the host events and starts the save loop. Runs on a coroutine.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.warn('[vehicles] no character contract: nobody can prove they own a vehicle, ' ..
			'so every spawn and every store is refused')
	end

	-- NO NET DOOR. `opx:net:vehicles:spawn` and `:store` were registered here and
	-- nothing in this resource ever sent either: every car comes out and goes
	-- back through `garages` (a marker, its bucket, its exits and its clearance)
	-- or through staff. What they did was let any client skip all of that. A
	-- spawn with no place put an owned car beside the player WHEREVER they stood,
	-- garage or not; a store took the car out of the world from across the map
	-- with whoever was sitting in it, which `garages` refuses as
	-- `garages.passengers`. The contract below is unchanged, and is the door.
	AddEventHandler(OPX.Host.VEHICLE_REMOVED, removed)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)

	-- A DELETED CHARACTER TAKES ITS CARS WITH IT, and this is what does it: the
	-- table's foreign key never fires, because a character delete is a soft one.
	-- Left to the cascade, a deleted character's vehicles stayed in the table for
	-- ever, owned by a citizen id nothing can ever log in as. See
	-- `character.Event.IN_DELETED`.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			local purged = M.Storage.PurgeCharacter(citizenId)
			if purged ~= nil and not purged.ok then
				Open77.log.warn(('[vehicles] the cars of the deleted %s were not removed: %s')
					:format(citizenId, tostring(purged.detail or purged.error)))
			end
		end)

	local everyMs = math.max(1000, math.floor(tonumber(M.Settings.SAVE_SECONDS) or 120) * 1000)
	OPX.Scheduler.Every('vehicles:save', everyMs, savePass)
end

--- Writes back everything that is out before the resource goes.
-- @author dop42
--
-- ON THE STOP HANDLER'S OWN STACK, which is not a coroutine, so nothing here may
-- await. This used to call `StoreAll`, whose every `Store` begins with a
-- `FetchOne` -- and a database read off a coroutine does not wait, it fails. So
-- every vehicle out at a stop logged "its condition is not written" and went
-- with its row still saying OUT: the damage since the last save pass was lost,
-- and the garage list showed cars in the street that were not there.
--
-- Now the condition is read from the engine on this stack, while it still
-- answers, and written with the bridge's callback form, which sends the
-- statement before it returns (`Storage.SaveConditionNow`). Best effort: the
-- save loop is still what guarantees damage survives a crash.
--
-- BOUNDED: at most STOP_SAVE_MAX vehicles are written, two engine reads and one
-- statement each, inside the one resume a stop handler gets; the rest keep the
-- last save pass.
local STOP_SAVE_MAX = 64

function M.Stop()
	local plates = {}
	for plateId in pairs(live) do plates[#plates + 1] = plateId end
	table.sort(plates)

	local dispatched = 0
	for index = 1, #plates do
		local record = live[plates[index]]
		if index <= STOP_SAVE_MAX then
			local read, snapshot = pcall(Open77.vehicles.get, record.id)
			if read and type(snapshot) == 'table' then
				local gotDamage, damage = pcall(Open77.vehicles.getDamage, record.id)
				local entity = {
					plate = plates[index],
					state = STATE.STORED,
					health = finiteNumber(snapshot.health) or 1.0,
					damage = gotDamage and type(damage) == 'table' and damage or nil,
					flags = finiteNumber(snapshot.flags),
					fuel = fuelOf(record.id),
				}
				local sent, why = Store.SaveConditionNow(entity, function(ok, reason)
					if not ok then
						Open77.log.warn(('[vehicles] %s: the condition taken at stop was not written (%s)')
							:format(entity.plate, tostring(reason)))
					end
				end)
				if sent then
					dispatched = dispatched + 1
				else
					Open77.log.warn(('[vehicles] %s: the condition taken at stop could not be sent (%s)')
						:format(entity.plate, tostring(why)))
				end
			end
		end
		pcall(Open77.vehicles.remove, record.id)
	end
	live, claiming, storing = {}, {}, {}

	if #plates > 0 then
		Open77.log.info(('[vehicles] stopping: %d vehicle(s) out, %d condition save(s) sent, ' ..
			'best effort'):format(#plates, dispatched))
	end
end
