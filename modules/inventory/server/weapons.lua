--- Weapons as items: drawn through the relay, their rounds kept on the item.
-- @author dop42
--
-- Equipment is the engine state OF THE TARGETED CLIENT. `Open77.weapons.*` on the
-- server relays a request to that client and raises a completion in this VM
-- later, so every step answers in two parts and is tracked in `pending` by its
-- request id until it does.
--
-- THE ITEM IS THE REGISTER. Its `ammo` only ever comes DOWN to what a reading of
-- the engine says, and only ever goes UP when an ammunition item is spent on it.
-- A reading that raised the count would hand a player rounds nobody paid for.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Containers = M.Containers
local Players = M.Players
local KIND = M.KIND

M.Weapons = {}
local Weapons = M.Weapons

-- Raised by the host in this VM when a relayed weapon request finishes. Host-owned
-- and not one of this module's channels, so it is not built with `OPX.Event`.
local HOST_WEAPON_COMPLETED = 'open77:weapons:completed'

-- A relay request with no answer times out at the host in ten seconds; this only
-- bounds the table in case a completion never reaches this VM at all.
local PENDING_MS = 30000

-- The weapon this module put in each player's hands, and the relay steps waiting
-- for their completion, by request id.
local armed = {}
local pending = {}

-- Weapons whose rounds are being read back on the way to the holster, by
-- serial. Until the reading lands, the item still carries the count of the last
-- sync, and it must not leave the bag carrying it.
local reading = {}

--- Whether weapons are on and the whole relay is installed.
local function available()
	local weapons = Open77.weapons
	return Options.WEAPONS and type(weapons) == 'table' and type(weapons.assign) == 'function' and
		type(weapons.remove) == 'function' and type(weapons.setAmmo) == 'function' and
		type(weapons.requestSnapshot) == 'function'
end

--- Records a relay step under its request id, stamped with now.
local function remember(requestId, step)
	step.atMs = OPX.Now()
	pending[tostring(requestId)] = step
end

--- The bag slot still backing a held weapon, found by its serial.
local function findHeld(bag, held)
	if not bag then return nil, nil end
	for slot, entry in pairs(bag.items) do
		if entry.name == held.name and type(entry.metadata) == 'table' and
			entry.metadata.serial == held.serial then
			return slot, entry
		end
	end
	return nil, nil
end

--- The row of one game slot in a snapshot answer.
local function rowOf(rows, slot)
	if type(rows) ~= 'table' then return nil end
	for index = 1, #rows do
		local row = rows[index]
		if type(row) == 'table' and Common.Integer(row.slot, 1, 3) == slot then return row end
	end
	return nil
end

--- The weapon this module put in a player's hands, or nil.
-- @author dop42
-- @param source Source
-- @return table|nil
function Weapons.Held(source)
	return armed[source]
end

--- Tells a player's client which bag weapon is in hand, or that none is.
-- @author dop42
-- @param source Source
-- @param held table|nil
function Weapons.Announce(source, held)
	TriggerClientEvent(M.Event.ARMED, source, held and {
		name = held.name,
		serial = held.serial,
		slot = Options.WEAPON_SLOT,
	} or false)
end

--- Lowers an item's rounds to a reading. Never raises them.
local function lower(source, held, total)
	total = Common.Integer(total, 0, 1000000)
	if total == nil then return end
	local citizenId = Players.Citizen(source)
	local bag = citizenId and Containers.Find(KIND.CHARACTER, citizenId)
	local _, entry = findHeld(bag, held)
	if not entry then return end
	local ammo = Common.Integer(entry.metadata.ammo, 0, 1000000) or 0
	if total >= ammo then return end
	entry.metadata.ammo = total
	M.Storage.MarkDirty(bag.id)
	Containers.Publish(bag)
end

--- How an item's rounds are split between the magazine and the reserve.
--
-- PURE, AND SEPARATE FROM THE RELAY BELOW, because the arithmetic is where the
-- defect was and the relay is what made it hard to see.
--
-- BOTH HALVES ARE ALWAYS STATED. `setAmmo` changes only what it is told about,
-- and the fallback here used to name the reserve and say nothing of the
-- magazine -- so the engine kept the one it loaded when the weapon was
-- assigned, a full one, and an item holding ZERO rounds came out of the bag
-- shooting. Rounds nobody paid for, which is the one thing the header of this
-- file says must never happen.
--
-- A magazine ABOVE the weapon's capacity is refused by the engine, which is why
-- one is never guessed upward: a reload keeps what is already chambered and the
-- reading taken at that moment decides the split. But zero is always safe --
-- no capacity is below it -- so when the capacity is unknown the rounds go to
-- the reserve and the player chambers them. That is honest: we know how many
-- rounds they own and not how many fit.
-- @author dop42
-- @param ammo integer rounds the item holds
-- @param capacity integer|nil the weapon's magazine, when the engine said
-- @param magazine integer|nil what is chambered now, when the engine said
-- @param keepMagazine boolean whether to leave what is chambered alone
-- @return table the amounts for `Open77.weapons.setAmmo`
function Weapons.Amounts(ammo, capacity, magazine, keepMagazine)
	local amounts = { activate = true }
	if keepMagazine and magazine then
		local kept = math.min(magazine, ammo)
		amounts.magazine = kept
		amounts.reserve = ammo - kept
	elseif capacity then
		amounts.magazine = math.min(ammo, capacity)
		amounts.reserve = ammo - amounts.magazine
	else
		amounts.magazine = 0
		amounts.reserve = ammo
	end
	return amounts
end

--- States the item's rounds to the engine.
local function load(source, held, state, keepMagazine)
	local citizenId = Players.Citizen(source)
	local bag = citizenId and Containers.Find(KIND.CHARACTER, citizenId)
	local _, entry = findHeld(bag, held)
	if not entry then return end
	local ammo = math.min(Common.Integer(entry.metadata.ammo, 0, 1000000) or 0, held.max)

	local capacity = type(state) == 'table' and Common.Integer(state.capacity, 1, 100000) or nil
	local magazine = type(state) == 'table' and Common.Integer(state.magazine, 0, 100000) or nil
	local amounts = Weapons.Amounts(ammo, capacity, magazine, keepMagazine)

	local requestId, reason = Open77.weapons.setAmmo(source, Options.WEAPON_SLOT, amounts)
	if not requestId then
		Open77.log.warn(('[inventory] setAmmo for player %d refused: %s')
			:format(source, tostring(reason)))
		return
	end
	held.loading = true
	remember(requestId, { source = source, kind = 'load', held = held })
end

--- Whether the engine says a weapon is drawn right now.
--
-- THE ONLY HONEST ANSWER TO "IS IT IN HAND", and the reason it is asked at all:
-- `armed[source]` is OUR record of what we last put there, and the game holsters
-- a weapon on its own often enough that the two drift. When they drift, Use --
-- which reads as a toggle -- puts away a weapon that is already away.
--
-- `Open77.weapons.get` is a CACHE and the platform says so plainly: "read it to
-- decide, never to assert". It carries two ages because its halves refresh at
-- different rates, and `fresh` applies a two-second rule to the half that
-- matters here -- `drawn` rides the ordinary 20 Hz player snapshot.
--
-- SO A STALE OR ABSENT ANSWER MEANS "DO NOT KNOW", AND DO-NOT-KNOW KEEPS THE OLD
-- BEHAVIOUR. `weapons_unreported` is a player the host has heard nothing from,
-- which is not the same as a player carrying nothing; a build without the call
-- is not a build where every weapon is holstered. Treating either as "not in
-- hand" would trade a rare wrong holster for a constant wrong draw.
-- @author dop42
-- @param source Source
-- @return boolean
function Weapons.InHand(source)
	local weapons = Open77.weapons
	if type(weapons) ~= 'table' or type(weapons.get) ~= 'function' then return true end

	local read, state = pcall(weapons.get, source)
	if not read or type(state) ~= 'table' then return true end
	if state.fresh ~= true then return true end
	return state.drawn == true
end

--- Draws a bag weapon, or puts it away when it is already in hand.
-- @author dop42
-- @param source Source
-- @param bag table
-- @param slot integer
-- @param item table the catalogue entry, already checked by the caller
-- @return boolean
-- @return string|nil
function Weapons.Use(source, bag, slot, item)
	if not available() then return false, 'weapons_unavailable' end
	local entry = bag.items[slot]

	local held = armed[source]
	if held and Weapons.InHand(source) then
		local heldSlot = findHeld(bag, held)
		Weapons.Holster(source, true)
		-- Using the weapon already in hand is how a player puts it away.
		if heldSlot == slot then return true, nil end
	elseif held then
		-- IT IS NOT IN THEIR HAND, WHATEVER THIS TABLE SAYS. The game holsters a
		-- weapon on its own -- a vehicle, a scripted beat, a knockdown -- and
		-- nothing tells us. Pressing Use then put away something already away,
		-- and the player pressed it again to get the same nothing. Forgotten
		-- here rather than holstered: `Holster` would ask the client to remove a
		-- slot the engine has already emptied, and then this Use would fall
		-- through to an assign anyway. So the bookkeeping is corrected and the
		-- press does what the player meant, which is draw.
		armed[source] = nil
		Weapons.Announce(source, nil)
	end

	if type(entry.metadata) ~= 'table' then entry.metadata = {} end
	if type(entry.metadata.serial) ~= 'string' or entry.metadata.serial == '' then
		entry.metadata.serial = Containers.NewSerial()
		M.Storage.MarkDirty(bag.id)
		Containers.Publish(bag)
	end

	local ammoItem = item.weapon.ammo
	held = {
		name = entry.name,
		serial = entry.metadata.serial,
		record = item.weapon.record,
		ammoItem = ammoItem,
		-- THE GUN'S MAGAZINE, NOT THE BOX'S STACK. This read the ammo item's
		-- `MAX` -- how many rounds fit in a crate, five hundred for a handgun --
		-- so a player loaded the whole crate into a pistol and never reloaded.
		-- `magazine` is stated per weapon class in `data/weapons.lua`, and a
		-- class that names ammunition without one is a boot warning: the gun
		-- then loads nothing, which gets noticed, rather than everything, which
		-- does not.
		max = ammoItem and item.weapon.magazine or 0,
		state = 'arming',
		loading = false,
	}
	armed[source] = held

	local requestId, refusal = Open77.weapons.assign(source, item.weapon.record,
		Options.WEAPON_SLOT, { active = true, addToInventory = true })
	if not requestId then
		armed[source] = nil
		Open77.log.warn(('[inventory] assign for player %d refused: %s')
			:format(source, tostring(refusal)))
		return false, 'weapon_refused'
	end
	remember(requestId, { source = source, kind = 'assign', held = held })
	Weapons.Announce(source, held)
	return true, nil
end

--- Puts the held weapon away, reading its rounds back first when asked to.
-- @author dop42
-- @param source Source
-- @param sync boolean
function Weapons.Holster(source, sync)
	local held = armed[source]
	if not held then return end
	armed[source] = nil
	Weapons.Announce(source, nil)
	if not available() then return end

	if sync and held.ammoItem and held.state == 'armed' and not held.loading then
		local requestId = Open77.weapons.requestSnapshot(source)
		if requestId then
			reading[held.serial] = true
			remember(requestId, { source = source, kind = 'holster', held = held })
			return
		end
	end
	local requestId = Open77.weapons.remove(source, Options.WEAPON_SLOT)
	if requestId then remember(requestId, { source = source, kind = 'remove' }) end
end

--- Whether a bag stack may leave its bag right now, and the refusal if not.
--
-- THE ROUNDS FIRED SINCE THE LAST SYNC. The item's `ammo` only comes down when a
-- reading of the engine says so, and the sync runs every `AMMO_SYNC_MS`. A drawn
-- weapon moved, handed over or dropped was holstered by `CheckHeld` WITHOUT a
-- reading -- the item had already left the bag the reading lowers -- so every
-- round fired since the last sync came back with it: empty the magazine, drop
-- the gun, pick it up, and it was full again.
--
-- So the drawn weapon does not leave the bag while it is drawn. The first
-- attempt holsters it WITH a reading and is refused `holstering`; the reading
-- lowers the item where it still is, in the bag; and the attempt after it goes
-- through with the true count. A weapon with nothing to read (no ammunition, or
-- still being drawn) is let go as before.
-- Called by `Containers.Move` for every stack leaving a container.
-- @author dop42
-- @param bag table the container the stack is leaving
-- @param entry table the stack
-- @return string|nil the refusal code
function Weapons.BeforeLeave(bag, entry)
	if bag.kind ~= KIND.CHARACTER then return nil end
	local metadata = entry.metadata
	local serial = type(metadata) == 'table' and metadata.serial or nil
	if type(serial) ~= 'string' then return nil end
	if reading[serial] then return 'holstering' end
	local source = Players.SourceOf(bag.owner)
	local held = source and armed[source]
	if not held or held.serial ~= serial or held.name ~= entry.name then return nil end
	if not held.ammoItem or held.state ~= 'armed' or not available() then return nil end
	Weapons.Holster(source, true)
	-- No reading could be asked for (the relay refused it, or rounds are being
	-- loaded and the item was just set from a fresh reading): the weapon is
	-- away, and the stack goes as it always did.
	if not reading[serial] then return nil end
	return 'holstering'
end

--- Spends an ammunition item on the held weapon, up to its maximum.
-- @author dop42
-- @param source Source
-- @param bag table
-- @param slot integer
-- @return boolean
-- @return string|nil
function Weapons.Reload(source, bag, slot)
	if not available() then return false, 'weapons_unavailable' end
	local held = armed[source]
	local entry = bag.items[slot]
	if not held or held.state ~= 'armed' or held.ammoItem ~= entry.name then
		return false, 'no_weapon_for_ammo'
	end
	local _, weapon = findHeld(bag, held)
	if not weapon then
		Weapons.Holster(source, false)
		return false, 'no_weapon_for_ammo'
	end

	local ammo = Common.Integer(weapon.metadata.ammo, 0, 1000000) or 0
	local room = held.max - ammo
	if room <= 0 then return false, 'weapon_full' end
	local take = math.min(room, entry.count)
	local taken, refusal = Containers.TakeFromSlot(bag, slot, take)
	if not taken then return false, refusal end

	weapon.metadata.ammo = ammo + take
	M.Storage.MarkDirty(bag.id)
	Containers.Publish(bag)

	local requestId = Open77.weapons.requestSnapshot(source)
	if requestId then
		held.loading = true
		remember(requestId, { source = source, kind = 'reload', held = held })
	else
		load(source, held, nil, false)
	end
	return true, nil
end

--- Drops a departing character's weapon and every relay step waiting on them.
-- The weapon goes AT ONCE while the client is still there to take it off.
-- @author dop42
-- @param source Source
-- @param connected boolean
function Weapons.Forget(source, connected)
	if connected then
		Weapons.Holster(source, false)
	else
		armed[source] = nil
	end
	for key, step in pairs(pending) do
		if step.source == source then
			if step.kind == 'holster' and step.held then reading[step.held.serial] = nil end
			pending[key] = nil
		end
	end
end

--- Whether a game slot row holds the weapon this module put there.
-- During arming the slot may already show the weapon before the completion names
-- its id, so a held weapon with no id yet counts as backed.
local function backed(source, row)
	local held = armed[source]
	if not held then return false end
	if Common.Integer(row.slot, 1, 3) ~= Options.WEAPON_SLOT then return false end
	if held.state ~= 'armed' or held.tweakDbId == nil then return true end
	return row.tweakDbId == held.tweakDbId
end

--- Resumes the relay step a completion answers.
local function completed(playerId, requestId, _operation, accepted, reason, result)
	local key = tostring(requestId)
	local step = pending[key]
	if step == nil then return end
	pending[key] = nil
	local source = step.source
	if tonumber(playerId) ~= source then return end
	local held = armed[source]

	if step.kind == 'assign' then
		if held ~= step.held then return end
		if accepted ~= true then
			armed[source] = nil
			Weapons.Announce(source, nil)
			Open77.log.warn(('[inventory] drawing %s for player %d failed: %s')
				:format(step.held.record, source, tostring(reason)))
			OPX.NotifyLocale(source, 'inventory.error.weapon_refused', nil, 'error')
			return
		end
		result = type(result) == 'table' and result or {}
		held.state = 'armed'
		held.tweakDbId = type(result.tweakDbId) == 'string' and result.tweakDbId ~= '' and
			result.tweakDbId or nil
		if held.ammoItem then load(source, held, result.ammo, false) end
		return
	end

	if step.kind == 'load' then
		if step.held then step.held.loading = false end
		if accepted ~= true then
			Open77.log.warn(('[inventory] loading rounds for player %d failed: %s')
				:format(source, tostring(reason)))
		end
		return
	end

	-- The reading on the way to the holster has landed, or been refused: either
	-- way the item may leave the bag now.
	if step.kind == 'holster' and step.held then reading[step.held.serial] = nil end

	if accepted ~= true then
		if step.held then step.held.loading = false end
		-- A refused read on the way to holstering still has to take the weapon off.
		if step.kind == 'holster' and armed[source] == nil then
			local removal = Open77.weapons.remove(source, Options.WEAPON_SLOT)
			if removal then remember(removal, { source = source, kind = 'remove' }) end
		end
		return
	end

	local row = rowOf(result, Options.WEAPON_SLOT)

	if step.kind == 'holster' then
		-- Only a reading of THIS weapon lowers its rounds. A different weapon may
		-- already be in the slot, and if this one was drawn again the assign has
		-- replaced what is there, so there is nothing to remove.
		if row and type(row.ammo) == 'table' and step.held.tweakDbId ~= nil and
			row.tweakDbId == step.held.tweakDbId then
			lower(source, step.held, row.ammo.total)
		end
		if armed[source] == nil then
			local removal = Open77.weapons.remove(source, Options.WEAPON_SLOT)
			if removal then remember(removal, { source = source, kind = 'remove' }) end
		end
		return
	end

	if step.kind == 'reload' then
		if held ~= step.held then return end
		held.loading = false
		load(source, held, row and row.ammo or nil, true)
		return
	end

	if step.kind == 'sync' or step.kind == 'scan' then
		if held and held == step.held and held.state == 'armed' and not held.loading then
			if not row or row.equipped ~= true or
				(held.tweakDbId ~= nil and row.tweakDbId ~= held.tweakDbId) then
				-- Taken off or replaced by another path -- the game's own inventory
				-- screen, for one. It is no longer ours.
				armed[source] = nil
				Weapons.Announce(source, nil)
			elseif held.ammoItem and type(row.ammo) == 'table' then
				lower(source, held, row.ammo.total)
			end
		end

		if step.kind == 'scan' and Options.REMOVE_UNBACKED and type(result) == 'table' then
			for index = 1, #result do
				local slotRow = result[index]
				if type(slotRow) == 'table' and slotRow.equipped == true and
					slotRow.locked ~= true and not backed(source, slotRow) then
					local slot = Common.Integer(slotRow.slot, 1, 3)
					if slot then
						Open77.log.info(('[inventory] player %d had a weapon in slot %d nothing ' ..
							'backs; taking it off'):format(source, slot))
						local removal = Open77.weapons.remove(source, slot)
						if removal then remember(removal, { source = source, kind = 'remove' }) end
					end
				end
			end
		end
	end
end

--- Puts a held weapon away as soon as its item has left the bag.
-- Called by every change to a bag: moved, dropped, handed over or taken.
-- @author dop42
-- @param bag table
function Weapons.CheckHeld(bag)
	local source = Players.SourceOf(bag.owner)
	local held = source and armed[source]
	if not held then return end
	if not findHeld(bag, held) then Weapons.Holster(source, false) end
end

--- Asks for a reading of every drawn weapon that loads rounds.
-- @author dop42
function Weapons.SyncAmmo()
	if not available() then return end
	for source, held in pairs(armed) do
		if held.ammoItem and held.state == 'armed' and not held.loading and
			Players.GateOpen(source) then
			local requestId = Open77.weapons.requestSnapshot(source)
			if requestId then
				remember(requestId, { source = source, kind = 'sync', held = held })
			end
		end
	end
end

--- Asks for a reading of every loaded player's slots, looking for weapons nothing
--- in their bag backs.
-- @author dop42
function Weapons.Scan()
	if not available() then return end
	local players = Players.List()
	for index = 1, #players do
		local source = players[index].source
		if Players.GateOpen(source) then
			local requestId = Open77.weapons.requestSnapshot(source)
			if requestId then
				remember(requestId, { source = source, kind = 'scan', held = armed[source] })
			end
		end
	end
end

--- Drops relay steps whose completion never came.
-- @author dop42
function Weapons.SweepPending()
	local now = OPX.Now()
	for key, step in pairs(pending) do
		if now - (step.atMs or now) > PENDING_MS then
			pending[key] = nil
			if step.held then step.held.loading = false end
			if step.kind == 'holster' and step.held then reading[step.held.serial] = nil end
		end
	end
end

--- Wires the relay's completion event.
-- @author dop42
function Weapons.Wire()
	AddEventHandler(HOST_WEAPON_COMPLETED, completed)
end
