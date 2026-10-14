--- Vehicle keys, the server half: cutting a key, and turning one.
-- @author dop42
--
-- NOTHING A CLIENT SENDS IS BELIEVED BUT WHICH VEHICLE IT IS POINTING AT. The
-- plate of that vehicle is this module's own answer (`Identity`), the key is
-- looked for in the server's copy of the bag (`inventory.CountWhere`), and the
-- distance is measured between two positions the host reports. A plate in a
-- payload is never read -- it would be the one field worth forging.

local M = OPX.Modules.Get('vehiclekeys')

local Result = OPX.Result

-- The contracts, resolved in `Start`. Nil is a feature off, never a fault.
local vehicles, inventory

-- Minted identities for vehicles `vehicles` never registered, by the host id as
-- text, and the reverse by plate. Rebuilt empty by `Init`: the host removes what
-- this resource created when it stops, so a carried table would name vehicles
-- that are gone -- and a minted plate is only ever as durable as its vehicle.
local minted, mintedBy

-- Floor between two lock requests from one connection. A lock is one bit, and
-- the only thing a faster door buys is a horn someone can spam.
local TOGGLE_MS = 1000

-- Draws before a mint gives up. Six characters of letters and digits collide
-- only when thousands of vehicles are live at once, so this is a bound on a loop
-- and not a real expectation.
local MINT_TRIES = 8

-- Longest model name a key's label carries, and the whole label.
local MODEL_MAX, LABEL_MAX = 40, 64

--- The host's live snapshot of one vehicle, or nil.
local function snapshotOf(vehicleId)
	local host = Open77.vehicles
	if vehicleId == nil or type(host) ~= 'table' or type(host.get) ~= 'function' then return nil end
	local read, snapshot = pcall(host.get, vehicleId)
	if not read or type(snapshot) ~= 'table' then return nil end
	return snapshot
end

--- A vehicle id off the wire, in whichever shape the host answers to, or nil.
-- The client sends a DECIMAL STRING, because a vehicle id carries a generation and
-- can pass 2^53 where a JSON number stops being exact. Both spellings are tried
-- rather than guessed at, exactly as `modules/admin/server/vehicles.lua` does,
-- and an id that names no live vehicle is refused here.
local function resolveId(token)
	if math.type(token) == 'integer' then
		return snapshotOf(token) ~= nil and token or nil
	end
	if type(token) ~= 'string' or #token < 1 or #token > 32 or token:find('%s') then return nil end
	if token:match('^%d+$') then
		local number = math.tointeger(tonumber(token))
		if number ~= nil and number > 0 and snapshotOf(number) ~= nil then return number end
	end
	if snapshotOf(token) ~= nil then return token end
	return nil
end

--- A plate a caller handed in, byte for byte, when it is one a key can carry.
--
-- PRINTABLE ASCII, KEPT EXACTLY AS IT CAME. This used to be `^[%w%-]+$`, which
-- is what this module and `vehicles` draw today -- and a legacy row whose plate
-- has a space or a dot in it (`ABC 123`, `NC.2077`) was refused, so the garage's
-- `Ensure` answered `error.badRequest` and the OWNER of that car never got a
-- key. The column is `VARCHAR(12) ascii_bin`, so printable ASCII is the whole
-- set a real plate can hold.
--
-- NOT NORMALISED. Uppercasing or stripping the space would make a key that
-- names a plate no row and no live vehicle has: `vehicles.LiveId` and the bag's
-- `CountWhere` both match the string exactly, so a "cleaned" plate is a key
-- that opens nothing. Refused are only what cannot be a plate at all: control
-- characters (a newline in a log line forges one), non-ASCII, nothing but
-- blanks, and anything longer than a minted plate could be.
local function plateOf(value)
	if type(value) ~= 'string' or #value < 1 or #value > 16 then return nil end
	if not value:match('^[\32-\126]+$') or not value:find('%S') then return nil end
	return value
end

--- The words a key's label carries for a model. Shared with the garage list
--- now, so a car is called the same thing on its key and in the garage.
local function modelName(model)
	return OPX.Vehicle.DisplayName(model, MODEL_MAX)
end

--- A key's label: the model and the plate, or the plate alone.
local function labelFor(plate, model)
	local name = modelName(model)
	local label = name and ('%s · %s'):format(name, plate) or plate
	if #label > LABEL_MAX then label = plate end
	return label
end

--- Forgets the minted identity of a vehicle the host removed.
local function forget(vehicleId)
	local key = tostring(vehicleId)
	local entry = minted[key]
	if entry == nil then return end
	minted[key] = nil
	if mintedBy[entry.plate] == key then mintedBy[entry.plate] = nil end
end

--- The identity a vehicle already has, without minting one.
-- @return table|nil { plate, record, owned, owner }
local function lookup(vehicleId, snapshot)
	snapshot = snapshot or snapshotOf(vehicleId)
	if snapshot == nil then return nil end
	if vehicles ~= nil and type(vehicles.PlateOf) == 'function' then
		local plate, owner = vehicles.PlateOf(vehicleId)
		if plate ~= nil then
			return { plate = plate, record = snapshot.record, owned = true, owner = owner }
		end
	end
	local entry = minted[tostring(vehicleId)]
	-- A RECYCLED ID. The host hands an id out again once its vehicle is gone, and
	-- a removal this module never heard about would leave the old car's plate on
	-- the new one; a record that no longer matches is that case, and the stale
	-- identity is dropped rather than inherited.
	if entry ~= nil and entry.record ~= snapshot.record then
		forget(vehicleId)
		entry = nil
	end
	if entry == nil then return nil end
	return { plate = entry.plate, record = entry.record, owned = false }
end

--- The live host id of the vehicle a plate belongs to, or nil when it is not out.
local function liveIdOf(plate)
	if vehicles ~= nil and type(vehicles.LiveId) == 'function' then
		local id = vehicles.LiveId(plate)
		if id ~= nil then return id end
	end
	local key = mintedBy[plate]
	if key == nil then return nil end
	local entry = minted[key]
	return entry and entry.id or nil
end

--- The identity of a vehicle, minting a plate for one nobody registered.
-- @author dop42
-- @param vehicleId any the host's id
-- @return Result { plate, record, owned, label }
function M.Identity(vehicleId)
	local snapshot = snapshotOf(vehicleId)
	if snapshot == nil then return Result.Err('vehiclekeys.noVehicle') end
	local known = lookup(vehicleId, snapshot)
	if known ~= nil then
		known.label = labelFor(known.plate, known.record)
		return Result.Ok(known)
	end

	-- Drawn and checked with nothing in between that yields, so two cuts for two
	-- plateless cars in one tick cannot draw the same plate and both keep it.
	for _ = 1, MINT_TRIES do
		local plate = M.MINTED_PREFIX .. OPX.String.Random('AAA111')
		if mintedBy[plate] == nil then
			local key = tostring(vehicleId)
			minted[key] = { plate = plate, record = snapshot.record, id = vehicleId }
			mintedBy[plate] = key
			return Result.Ok({ plate = plate, record = snapshot.record, owned = false,
				label = labelFor(plate, snapshot.record) })
		end
	end
	return Result.Err('vehiclekeys.unavailable', 'no plate could be minted')
end

--- How many keys to one plate a bag holds.
-- @author dop42
-- @param target Source|CitizenId
-- @param plate string
-- @return integer
function M.Count(target, plate)
	plate = plateOf(plate)
	if inventory == nil or plate == nil then return 0 end
	local counted = inventory.CountWhere(target, M.ITEM, { plate = plate })
	if type(counted) ~= 'table' or not counted.ok then return 0 end
	return tonumber(counted.value) or 0
end

--- Whether a bag holds a key to one live vehicle, by the host's id.
-- @author dop42
--
-- LOOKED UP, NEVER MINTED, the rule `Toggle` follows: a vehicle nobody ever cut
-- a key for has no plate, and minting one to ask the question would only prove
-- that nobody holds it. For a caller deciding whether a vehicle is this
-- player's to use -- `hauling` selling out of a trunk -- without turning a lock.
-- @param target Source|CitizenId
-- @param vehicleId any the host's id
-- @return boolean
function M.Holds(target, vehicleId)
	local snapshot = snapshotOf(vehicleId)
	if snapshot == nil then return false end
	local identity = lookup(vehicleId, snapshot)
	if identity == nil then return false end
	return M.Count(target, identity.plate) > 0
end

--- Cuts one key to a plate into a bag. Always one more: the caller decided.
-- @author dop42
-- @param target Source|CitizenId
-- @param plate string
-- @param model string|nil a catalogue label or a TweakDB record, for the label
-- @return Result { plate, label }
function M.Give(target, plate, model)
	if inventory == nil then return Result.Err('vehiclekeys.unavailable', 'no inventory') end
	plate = plateOf(plate)
	if plate == nil then return Result.Err('error.badRequest', 'plate') end
	local label = labelFor(plate, model)
	local added = inventory.AddItem(target, M.ITEM, 1, { plate = plate, label = label })
	if type(added) ~= 'table' or not added.ok then
		local code = type(added) == 'table' and tostring(added.error) or 'failed'
		Open77.log.warn(('[vehiclekeys] a key to %s was not given to %s: %s')
			:format(plate, tostring(target), code))
		-- A full bag and a heavy one are the two a player can do something about.
		if code == 'no_room' or code == 'too_heavy' or code == 'no_space' then
			return Result.Err('vehiclekeys.noRoom', label)
		end
		return Result.Err('vehiclekeys.unavailable', code)
	end
	return Result.Ok({ plate = plate, label = label })
end

--- Cuts a key to one live vehicle, by the host's id. The staff door, and the one
--- an admin spawn uses: the plate is resolved HERE, never handed in.
-- @author dop42
-- @param target Source|CitizenId
-- @param vehicleId any
-- @param model string|nil overrides the record for the label, e.g. a catalogue name
-- @return Result { plate, label }
function M.GiveFor(target, vehicleId, model)
	local identity = M.Identity(vehicleId)
	if not identity.ok then return identity end
	return M.Give(target, identity.value.plate, model or identity.value.record)
end

--- Makes sure a bag holds a key to a plate, cutting one only when it holds none.
-- THE RULE FOR EVERY AUTOMATIC KEY, and it is what stops a garage turning into a
-- key press: the owner who takes the car out ten times gets one key, not ten. A
-- key they GAVE AWAY is a key they no longer hold, so the next take-out cuts
-- them another -- which is a lost-key replacement, and the friend's copy still
-- works. Only the bag is counted, not a trunk or a stash: a key in the glovebox
-- of the car it opens is a key the owner cannot reach.
-- @author dop42
-- @param target Source|CitizenId
-- @param plate string
-- @param model string|nil
-- @return Result { given = boolean, plate, label }
function M.Ensure(target, plate, model)
	if inventory == nil then return Result.Err('vehiclekeys.unavailable', 'no inventory') end
	plate = plateOf(plate)
	if plate == nil then return Result.Err('error.badRequest', 'plate') end
	if M.Count(target, plate) > 0 then
		return Result.Ok({ given = false, plate = plate, label = labelFor(plate, model) })
	end
	local given = M.Give(target, plate, model)
	if not given.ok then return given end
	given.value.given = true
	return given
end

--- Takes every key to one plate out of one bag.
-- @author dop42
--
-- EVERY KEY, by plate and whatever its label says: a label is written in the
-- language and with the model name of the day it was cut, and a key that
-- survived a revoke because its label was spelled differently is a key that
-- still opens the car. Only the bag: a key left in a stash or a boot is a key
-- nobody is carrying, and `RevokeAll` says so in its answer.
-- @param target Source|CitizenId
-- @param plate string
-- @return Result { plate, removed }
function M.Revoke(target, plate)
	if inventory == nil then return Result.Err('vehiclekeys.unavailable', 'no inventory') end
	if type(inventory.RemoveWhere) ~= 'function' then
		return Result.Err('vehiclekeys.unavailable', 'the inventory cannot remove by metadata')
	end
	plate = plateOf(plate)
	if plate == nil then return Result.Err('error.badRequest', 'plate') end
	local removed = inventory.RemoveWhere(target, M.ITEM, { plate = plate })
	if type(removed) ~= 'table' or not removed.ok then
		return Result.Err('vehiclekeys.unavailable',
			type(removed) == 'table' and tostring(removed.error) or 'failed')
	end
	return Result.Ok({ plate = plate, removed = removed.value })
end

--- Takes every key to one plate out of every bag in the world.
-- @author dop42
--
-- Every LOADED character, which is every bag that can turn a lock right now: a
-- key only works in the hand of somebody standing beside the car. An offline
-- character's bag is not walked -- that is a query over every row ever written,
-- not a revoke -- so a caller re-keying a car for good also changes its plate,
-- which is the identity every key names.
-- @param plate string
-- @return Result { plate, removed, holders }
function M.RevokeAll(plate)
	plate = plateOf(plate)
	if plate == nil then return Result.Err('error.badRequest', 'plate') end
	local character = OPX.Api.Get('character')
	if character == nil then return Result.Err('vehiclekeys.unavailable', 'no character') end
	local players = character.GetPlayers()
	local removed, holders = 0, 0
	for index = 1, #players do
		local source = players[index].PlayerData.source
		local answer = M.Revoke(source, plate)
		if not answer.ok then return answer end
		if answer.value.removed > 0 then
			removed = removed + answer.value.removed
			holders = holders + 1
		end
	end
	OPX.Audit.Log({ event = 'vehiclekeys.revokeAll', message = plate,
		data = { plate = plate, removed = removed, holders = holders } })
	return Result.Ok({ plate = plate, removed = removed, holders = holders })
end

--- Whether a connection stands within reach of a vehicle, or sits in it.
-- Both positions are the host's. A seat counts wherever the car is: a driver
-- locking the doors from inside is the commonest use of a key there is.
local function reaches(source, vehicleId, snapshot)
	-- A PLAYER ID FROM 1 UP, checked before the host is asked. `Toggle` is a
	-- published contract, and `Open77.players.position(0)` does not answer nil:
	-- it throws past every `pcall` and stops the whole resource (devkit card
	-- `server:Open77.players.position`). The console, a citizen id, a stale
	-- source -- none of them stands beside a car.
	source = math.tointeger(tonumber(source))
	if source == nil or source < 1 then return false end
	local host = Open77.vehicles
	if type(host) == 'table' and type(host.getPlayerSeat) == 'function' then
		local read, seat = pcall(host.getPlayerSeat, source)
		if read and type(seat) == 'table' and seat.vehicleId ~= nil
			and tostring(seat.vehicleId) == tostring(vehicleId) then
			return true
		end
	end
	local players = Open77.players
	if type(players) ~= 'table' or type(players.position) ~= 'function' then return false end
	local read, here = pcall(players.position, source)
	if not read or type(here) ~= 'table' then return false end
	local at = type(snapshot.position) == 'table' and snapshot.position or snapshot
	local x, y, z = OPX.Math.Finite(at.x), OPX.Math.Finite(at.y), OPX.Math.Finite(at.z)
	local hx, hy, hz = OPX.Math.Finite(here.x), OPX.Math.Finite(here.y), OPX.Math.Finite(here.z)
	if not (x and y and z and hx and hy and hz) then return false end
	-- Same bucket only: a car three metres away in another bucket is not a car
	-- the player can see, let alone unlock.
	if (math.tointeger(tonumber(snapshot.bucket)) or 0) ~= (math.tointeger(tonumber(here.bucket)) or 0) then
		return false
	end
	local dx, dy, dz = x - hx, y - hy, z - hz
	-- The eye row offers the key out to REACH from where the client stood; this
	-- measures where the player was last observed, so it allows REACH_SLACK.
	local reach = OPX.Spots.ServerReach(M.REACH)
	return dx * dx + dy * dy + dz * dz <= reach * reach
end

--- Locks or unlocks a vehicle for a connection that holds its key and stands by it.
-- @author dop42
-- @param source Source
-- @param vehicleId any the host's id, already resolved
-- @return Result { locked, label }
function M.Toggle(source, vehicleId)
	local snapshot = snapshotOf(vehicleId)
	if snapshot == nil then return Result.Err('vehiclekeys.noVehicle') end
	if not reaches(source, vehicleId, snapshot) then return Result.Err('vehiclekeys.tooFar') end

	-- LOOKED UP, NOT MINTED. A vehicle nobody ever cut a key for has no plate,
	-- and minting one here would only prove that nobody holds it.
	local identity = lookup(vehicleId, snapshot)
	if identity == nil or M.Count(source, identity.plate) < 1 then
		return Result.Err('vehiclekeys.noKey')
	end

	local host = Open77.vehicles
	if type(host) ~= 'table' or type(host.isLocked) ~= 'function'
		or type(host.setLocked) ~= 'function' then
		return Result.Err('vehiclekeys.lockRefused', 'no lock native on this build')
	end
	local read, current = pcall(host.isLocked, vehicleId)
	if not read or type(current) ~= 'boolean' then
		return Result.Err('vehiclekeys.lockRefused', tostring(current))
	end
	local locked = current
	-- `setLocked` and NOT `setLockedForAll`: it moves the canonical bit and
	-- nothing else, so a per-player exception another resource granted survives a
	-- key turned by somebody else. This module grants none of its own.
	--
	-- UNDER PCALL, like `isLocked` above it. Called bare, a raise -- a vehicle
	-- removed between the read and the write, an argument a build rejects --
	-- unwound the thread `onToggleRequested` started for it: no toast, no log
	-- line, a key that did nothing and said nothing. A raise is now one more
	-- refusal, read as the `false, reason` the card documents.
	local called, ok, reason = pcall(host.setLocked, vehicleId, not locked)
	if not called or ok ~= true then
		local why = called and tostring(reason) or ('raised: ' .. tostring(ok))
		Open77.log.warn(('[vehiclekeys] setLocked(%s, %s) refused: %s')
			:format(tostring(vehicleId), tostring(not locked), OPX.Text.Clean(why, 120, '...') or ''))
		return Result.Err('vehiclekeys.lockRefused', why)
	end
	-- The chirp is the answer everybody standing there hears, and it is only ever
	-- a nicety: a build that refuses it has still locked the car.
	if type(host.triggerHorn) == 'function' then pcall(host.triggerHorn, vehicleId, 150) end
	return Result.Ok({ locked = not locked, label = labelFor(identity.plate, identity.record) })
end

--- Answers a toggle to the player, one toast either way.
local function tell(source, answer)
	if answer.ok then
		OPX.NotifyLocale(source, answer.value.locked and 'vehiclekeys.locked' or 'vehiclekeys.unlocked',
			{ label = answer.value.label }, 'success')
	else
		OPX.NotifyLocale(source, answer.error, { label = tostring(answer.detail or '') }, 'error')
	end
end

--- The row's door: lock or unlock the vehicle the eye landed on.
local function onToggleRequested(payload)
	local src = tonumber(source)
	if not src then return end
	if OPX.Cooling(src, 'vehiclekeys.toggle', TOGGLE_MS) then
		return OPX.NotifyLocale(src, 'vehiclekeys.tooFast', nil, 'warning')
	end
	-- Not from the floor: the lock is a hand on the car, and the down screen is
	-- the client's. Asked on the net door only -- the contract's callers decide
	-- for themselves.
	if OPX.Life.Down(src) then
		return tell(src, Result.Err('error.incapacitated'))
	end
	-- `payload.vehicleId` is the only field read. Anything else in the table --
	-- a plate, a label, a "locked" -- is a claim and goes nowhere.
	local vehicleId = resolveId(type(payload) == 'table' and payload.vehicleId or nil)
	if vehicleId == nil then return OPX.NotifyLocale(src, 'vehiclekeys.noVehicle', nil, 'error') end
	-- On a thread: the bag read may yield.
	CreateThread(function() tell(src, M.Toggle(src, vehicleId)) end)
end

--- Using a key from the bag: turn it on the vehicle it opens, if that is in reach.
-- The plate is read off the SERVER'S copy of the stack the player used, so the
-- key decides which car, and the player only decides when.
local function onKeyUsed(source, info)
	local metadata = type(info) == 'table' and info.metadata or nil
	local plate = type(metadata) == 'table' and plateOf(metadata.plate) or nil
	local answer
	if plate == nil then
		answer = Result.Err('vehiclekeys.noVehicle')
	else
		local vehicleId = liveIdOf(plate)
		answer = vehicleId == nil and Result.Err('vehiclekeys.notOut') or M.Toggle(source, vehicleId)
	end
	tell(source, answer)
	-- Always a use that happened and consumed nothing: the toast above says what
	-- the key did, and a refusal here would raise a second, vaguer one.
	return { ok = true, consume = 0 }
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state. Never yields.
-- @author dop42
function M.Init()
	minted, mintedBy = {}, {}
end

--- Publishes the contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('vehiclekeys', 1, {
		Identity = M.Identity,
		Count = M.Count,
		Holds = M.Holds,
		Give = M.Give,
		GiveFor = M.GiveFor,
		Ensure = M.Ensure,
		Toggle = M.Toggle,
		Revoke = M.Revoke,
		RevokeAll = M.RevokeAll,
	})
end

--- Resolves the contracts and wires the door and the item. On a coroutine.
-- @author dop42
function M.Start()
	vehicles = OPX.Api.Get('vehicles')
	inventory = OPX.Api.Get('inventory')

	if inventory == nil then
		Open77.log.warn('[vehiclekeys] no inventory contract: there is nowhere to keep a key, so ' ..
			'none is ever cut and no lock can be turned')
	elseif type(inventory.CountWhere) ~= 'function' then
		inventory = nil
		Open77.log.warn('[vehiclekeys] the inventory contract cannot count by metadata; keys are off')
	else
		local registered, why = inventory.RegisterUsable(M.ITEM, onKeyUsed, 'vehiclekeys')
		if not registered then
			Open77.log.warn(('[vehiclekeys] the key item could not be made usable: %s')
				:format(tostring(why)))
		end
	end
	if vehicles == nil then
		Open77.log.info('[vehiclekeys] no vehicles contract: every vehicle is keyed by a minted plate')
	end
	local host = Open77.vehicles
	if type(host) ~= 'table' or type(host.setLocked) ~= 'function' then
		Open77.log.warn('[vehiclekeys] this host has no Open77.vehicles.setLocked: keys are cut ' ..
			'but lock nothing')
	end

	RegisterNetEvent(M.Event.TOGGLE, onToggleRequested)
	AddEventHandler(OPX.Host.VEHICLE_REMOVED, function(id) forget(id) end)
end
