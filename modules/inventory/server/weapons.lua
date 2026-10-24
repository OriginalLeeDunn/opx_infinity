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
local secondary = {}
local policy = {}

local function slotOf(held) return held and held.slot or Options.WEAPON_SLOT end
local function mapOf(held) return held and held.hand == 'left' and secondary or armed end
local function otherOf(source, held)
	if held and held.hand == 'left' then return armed[source] end
	return secondary[source]
end
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
	if step.held and step.partner == nil then step.partner = otherOf(step.source, step.held) end
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
		if type(row) == 'table' and Common.Integer(row.slot, 1, 6) == slot then return row end
	end
	return nil
end

--- The weapon this module put in a player's hands, or nil.
-- @author dop42
-- @param source Source
-- @return table|nil
function Weapons.Held(source, hand)
	if hand == 'left' then return secondary[source] end
	return armed[source] or secondary[source]
end

--- Tells a player's client which bag weapon is in hand, or that none is.
-- @author dop42
-- @param source Source
-- @param held table|nil
function Weapons.Announce(source, held)
	held = armed[source] or secondary[source] or held
	TriggerClientEvent(M.Event.ARMED, source, held and {
		name = held.name,
		serial = held.serial,
		slot = slotOf(held),
		hand = held.hand or 'right',
		secondary = secondary[source] and { name = secondary[source].name, serial = secondary[source].serial,
			slot = slotOf(secondary[source]) } or nil,
	} or false)
end

--- Lowers owned rounds to a reading. A paired reserve is counted once.
-- With shared ammunition, consumption is attributed to the observed hand first
-- and then its partner; total ownership never increases from a client report.
local function lower(source, held, total, partner)
	total = Common.Integer(total, 0, 1000000)
	if total == nil then return end
	local citizenId = Players.Citizen(source)
	local bag = citizenId and Containers.Find(KIND.CHARACTER, citizenId)
	local _, entry = findHeld(bag, held)
	if not entry then return end
	local ammo = Common.Integer(entry.metadata.ammo, 0, 1000000) or 0
	partner = partner or otherOf(source, held)
	if partner and partner.ammoItem == held.ammoItem and held.sharedAmmo ~= false then
		local _, other = findHeld(bag, partner)
		if other then
			local spare = Common.Integer(other.metadata.ammo, 0, 1000000) or 0
			local spent = math.max(0, ammo + spare - total)
			local taken = math.min(ammo, spent)
			entry.metadata.ammo = ammo - taken
			other.metadata.ammo = math.max(0, spare - (spent - taken))
			if spent > 0 then M.Storage.MarkDirty(bag.id); Containers.Publish(bag) end
			return
		end
	end
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
	local partner = otherOf(source, held)
	if partner and partner.ammoItem == held.ammoItem then
		if partner.loading then return end
		local id = Open77.weapons.requestSnapshot(source)
		if not id then return end
		held.loading, partner.loading = true, true
		remember(id, { source = source, kind = 'pairRead', held = held, partner = partner })
		return
	end
	local citizenId = Players.Citizen(source)
	local bag = citizenId and Containers.Find(KIND.CHARACTER, citizenId)
	local _, entry = findHeld(bag, held)
	if not entry then return end
	local ammo = math.min(Common.Integer(entry.metadata.ammo, 0, 1000000) or 0, held.max)

	local capacity = type(state) == 'table' and Common.Integer(state.capacity, 1, 100000) or nil
	local magazine = type(state) == 'table' and Common.Integer(state.magazine, 0, 100000) or nil
	local amounts = Weapons.Amounts(ammo, capacity, magazine, keepMagazine)

	local requestId, reason = Open77.weapons.setAmmo(source, slotOf(held), amounts)
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
function Weapons.Use(source, bag, slot, item, hand, prepared)
	if not available() then return false, 'weapons_unavailable' end
	if hand ~= nil and hand ~= 'right' and hand ~= 'left' then return false, 'bad_request' end
	local left = hand == 'left'
	local map = left and secondary or armed
	if left and (not Options.DUAL_WIELD or type(Open77.weapons.setDualWieldAllowed) ~= 'function'
		or type(Open77.weapons.clear) ~= 'function') then
		return false, 'dual_wield_unavailable'
	end
	if left and not armed[source] then return false, 'primary_required' end
	-- The pair shares native ammunition and cannot change while a dependent
	-- assignment, ammunition write or holster is waiting for completion.
	for _, step in pairs(pending) do
		if step.source == source and (step.kind ~= 'sync' and step.kind ~= 'scan') then
			return false, 'holstering'
		end
	end
	if left and not policy[source] then
		local id = Open77.weapons.setDualWieldAllowed(source, true)
		if not id then return false, 'dual_wield_unavailable' end
		remember(id, { source = source, kind = 'policy', bag = bag, slot = slot, item = item, name = bag.items[slot].name,
			serial = bag.items[slot].metadata and bag.items[slot].metadata.serial })
		return true
	end
	if left and not prepared and not secondary[source] then
		local right = armed[source]
		if right.state ~= 'armed' or right.loading then return false, 'holstering' end
		local id = Open77.weapons.requestSnapshot(source)
		if not id then return false, 'weapon_refused' end
		right.loading = true
		remember(id, { source = source, kind = 'prePair', held = right, bag = bag, slot = slot,
			item = item, name = bag.items[slot].name, serial = bag.items[slot].metadata and bag.items[slot].metadata.serial })
		return true
	end
	local entry = bag.items[slot]
	if type(entry.metadata) == 'table' and reading[entry.metadata.serial] then
		return false, 'holstering'
	end

	local held = map[source]
	local other = left and armed[source] or secondary[source]
	if other and entry.metadata and entry.metadata.serial == other.serial then return false, 'weapon_in_other_hand' end
	if held and other then Weapons.Holster(source, true); return false, 'holstering' end
	if held and Weapons.InHand(source) then
		local heldSlot = findHeld(bag, held)
		Weapons.Holster(source, true, hand or 'right')
		-- Using the weapon already in hand is how a player puts it away.
		if heldSlot == slot then return true, nil end
		-- Assigning a replacement before the reading lands destroys the old
		-- engine count. Retry once its ammunition has been saved to the item.
		if reading[held.serial] then return false, 'holstering' end
	elseif held then
		-- A game holster leaves the last inventory count stale. Read the old
		-- weapon BEFORE assigning another one: assign can refill its magazine.
		-- Keep the serial held until the reply so moving or reusing it cannot
		-- race the reading. A refused relay leaves it available for a retry.
		if held.ammoItem and held.state == 'armed' then
			if held.loading or reading[held.serial] then return false, 'holstering' end
			local requestId = Open77.weapons.requestSnapshot(source)
			if not requestId then return false, 'weapon_refused' end
			reading[held.serial] = true
			held.loading = true
			remember(requestId, { source = source, kind = 'redraw', held = held,
				bag = bag, slot = slot, item = item, name = entry.name,
				serial = entry.metadata and entry.metadata.serial })
			return true, nil
		end
		map[source] = nil
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
		hand = left and 'left' or 'right',
		slot = Options.WEAPON_SLOT + (left and 3 or 0),
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
	map[source] = held
	if left then policy[source] = nil end

	local requestId, refusal = Open77.weapons.assign(source, item.weapon.record,
		slotOf(held), { active = true, addToInventory = true })
	if not requestId then
		map[source] = nil
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
function Weapons.Holster(source, sync, hand)
	if sync == false and secondary[source] and type(Open77.weapons.clear) == 'function' then
		Open77.weapons.clear(source)
		armed[source], secondary[source] = nil, nil
		Weapons.Announce(source, nil)
		return
	end
	if hand == nil and secondary[source] and armed[source] then
		local right, left = armed[source], secondary[source]
		if right.loading or left.loading then return end
		local id = Open77.weapons.requestSnapshot(source)
		if not id then return end
		right.loading, left.loading = true, true
		reading[right.serial], reading[left.serial] = true, true
		remember(id, { source = source, kind = 'pairHolster', held = right, partner = left })
		return
	end
	if hand == nil then
		Weapons.Holster(source, sync, 'left')
		Weapons.Holster(source, sync, 'right')
		return
	end
	local map = hand == 'left' and secondary or armed
	local held = map[source]
	if not held then return end
	map[source] = nil
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
	local requestId = Open77.weapons.remove(source, slotOf(held))
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
	if source and secondary[source] and secondary[source].serial == serial then held = secondary[source] end
	if not held or held.serial ~= serial or held.name ~= entry.name then return nil end
	if held.loading or held.state ~= 'armed' then return 'holstering' end
	if not held.ammoItem or not available() then
		Weapons.Holster(source, false)
		return nil
	end
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
function Weapons.Reload(source, bag, slot, hand, fresh)
	if not available() then return false, 'weapons_unavailable' end
	local held
	if hand == 'left' then held = secondary[source] else held = armed[source] end
	local entry = bag.items[slot]
	if hand == nil and (not held or held.ammoItem ~= entry.name) then held = secondary[source] end
	if held and held.loading then return false, 'holstering' end
	if not held or held.state ~= 'armed' or held.ammoItem ~= entry.name then
		return false, 'no_weapon_for_ammo'
	end
	local partner = otherOf(source, held)
	if partner and not fresh then
		if partner.loading then return false, 'holstering' end
		local id = Open77.weapons.requestSnapshot(source)
		if not id then return false, 'weapon_refused' end
		held.loading, partner.loading = true, true
		remember(id, { source = source, kind = 'pairReload', held = held, partner = partner,
			bag = bag, slot = slot, name = entry.name })
		return true
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
	policy[source] = nil
	if connected and secondary[source] and type(Open77.weapons.clear) == 'function' then
		Open77.weapons.clear(source)
		armed[source], secondary[source] = nil, nil
		Weapons.Announce(source, nil)
	elseif connected then
		Weapons.Holster(source, false)
	else
		armed[source] = nil
		secondary[source] = nil
	end
	for key, step in pairs(pending) do
		if step.source == source then
			if step.held then reading[step.held.serial] = nil end
			if step.partner then reading[step.partner.serial] = nil end
			pending[key] = nil
		end
	end
end

--- Whether a game slot row holds the weapon this module put there.
-- During arming the slot may already show the weapon before the completion names
-- its id, so a held weapon with no id yet counts as backed.
local function backed(source, row)
	local held = tonumber(row.slot) == Options.WEAPON_SLOT + 3 and secondary[source] or armed[source]

	if not held then return false end
	if Common.Integer(row.slot, 1, 6) ~= slotOf(held) then return false end
	if held.state ~= 'armed' or held.tweakDbId == nil then return true end
	return row.tweakDbId == held.tweakDbId
end

--- Clears a pair whose native initialization could not be verified.
local function failPair(source, first, second)
	if type(Open77.weapons.clear) == 'function' then
		local id = Open77.weapons.clear(source)
		if id then remember(id, { source = source, kind = 'clear' }) end
	else
		Open77.weapons.remove(source, Options.WEAPON_SLOT + 3)
		Open77.weapons.remove(source, Options.WEAPON_SLOT)
	end
	armed[source], secondary[source] = nil, nil
	if first then first.loading = false; reading[first.serial] = nil end
	if second then second.loading = false; reading[second.serial] = nil end
	Weapons.Announce(source, nil)
	OPX.NotifyLocale(source, 'inventory.error.weapon_refused', nil, 'error')
end

--- Resumes the relay step a completion answers.
local function completed(playerId, requestId, _operation, accepted, reason, result)
	local key = tostring(requestId)
	local step = pending[key]
	if step == nil then return end
	local source = step.source
	if tonumber(playerId) ~= source then return end
	local expected = ({ policy = 'setDualWieldAllowed', assign = 'assign', load = 'setAmmo', remove = 'remove', clear = 'clear', pairFirst = 'setAmmo', pairLast = 'setAmmo', pairRemoveLeft = 'remove', pairRemoveRight = 'remove' })[step.kind] or 'snapshot'
	if _operation ~= expected then return end
	pending[key] = nil
	local map = mapOf(step.held)
	local held = map[source]
	if step.kind == 'policy' then
		if accepted ~= true then OPX.NotifyLocale(source, 'inventory.error.dual_wield_unavailable', nil, 'error'); return end
		policy[source] = true
		local hauling = OPX.Api.Get('hauling')
		if hauling and type(hauling.IsCarrying) == 'function' and hauling.IsCarrying(source) then return end
		local entry = step.bag.items[step.slot]
		if Players.Citizen(source) == step.bag.owner and Players.MayAct(source) and entry
			and entry.name == step.name and (entry.metadata and entry.metadata.serial) == step.serial then
			Weapons.Use(source, step.bag, step.slot, step.item, 'left')
		end
		return
	end

	if step.kind == 'prePair' or step.kind == 'pairReload' then
		if held ~= step.held then return end
		held.loading = false
		if step.partner then step.partner.loading = false end
		local row = rowOf(result, slotOf(held))
		if accepted ~= true or not row or row.tweakDbId ~= held.tweakDbId then return end
		if held.ammoItem and type(row.ammo) == 'table' then lower(source, held, row.ammo.total, step.partner) end
		local entry = step.bag.items[step.slot]
		if not entry or entry.name ~= step.name or Players.Citizen(source) ~= step.bag.owner
			or not Players.MayAct(source) then return end
		local hauling = OPX.Api.Get('hauling')
		if hauling and type(hauling.IsCarrying) == 'function' and hauling.IsCarrying(source) then return end
		if step.kind == 'prePair' then
			if (entry.metadata and entry.metadata.serial) ~= step.serial then return end
			Weapons.Use(source, step.bag, step.slot, step.item, 'left', true)
		else Weapons.Reload(source, step.bag, step.slot, held.hand, true) end
		return
	end
	if step.kind == 'pairHolster' then
		local right, left = step.held, step.partner
		if armed[source] ~= right or secondary[source] ~= left then return end
		if accepted ~= true then
			right.loading, left.loading = false, false
			reading[right.serial], reading[left.serial] = nil, nil
			return
		end
		local row = rowOf(result, slotOf(right))
		local leftRow = rowOf(result, slotOf(left))
		if not row or not leftRow or row.tweakDbId ~= right.tweakDbId or leftRow.tweakDbId ~= left.tweakDbId then
			right.loading, left.loading = false, false
			reading[right.serial], reading[left.serial] = nil, nil
			return
		end
		if type(row.ammo) == 'table' then lower(source, right, row.ammo.total, left) end
		if (left.ammoItem ~= right.ammoItem or right.sharedAmmo == false) and type(leftRow.ammo) == 'table' then lower(source, left, leftRow.ammo.total) end
		local id = Open77.weapons.remove(source, slotOf(left))
		if id then remember(id, { source = source, kind = 'pairRemoveLeft', held = right, partner = left })
		else
			right.loading, left.loading = false, false
			reading[right.serial], reading[left.serial] = nil, nil
		end
		return
	end
	if step.kind == 'pairRemoveLeft' or step.kind == 'pairRemoveRight' then
		local right, left = step.held, step.partner
		if accepted == true and step.kind == 'pairRemoveLeft' then
			secondary[source] = nil
			local id = Open77.weapons.remove(source, slotOf(right))
			if id then remember(id, { source = source, kind = 'pairRemoveRight', held = right, partner = left }); return end
		elseif accepted == true then armed[source] = nil end
		right.loading, left.loading = false, false
		reading[right.serial], reading[left.serial] = nil, nil
		Weapons.Announce(source, armed[source])
		return
	end
	if step.kind == 'pairRead' then
		local partner = step.partner
		if held ~= step.held or mapOf(partner)[source] ~= partner then return end
		local a, b = rowOf(result, slotOf(held)), rowOf(result, slotOf(partner))
		local citizen = Players.Citizen(source)
		local bag = citizen and Containers.Find(KIND.CHARACTER, citizen)
		local _, first = findHeld(bag, held)
		local _, second = findHeld(bag, partner)
		if accepted ~= true or not first or not second or not a or not b
			or type(a.ammo) ~= 'table' or type(b.ammo) ~= 'table' then
			failPair(source, held, partner)
			return
		end
		local capacityA = Common.Integer(a.ammo.capacity, 1, 100000)
		local capacityB = Common.Integer(b.ammo.capacity, 1, 100000)
		if not capacityA or not capacityB then
			failPair(source, held, partner)
			return
		end
		local ammoA = Common.Integer(first.metadata.ammo, 0, held.max) or 0
		local ammoB = Common.Integer(second.metadata.ammo, 0, partner.max) or 0
		local magA, magB = math.min(ammoA, capacityA), math.min(ammoB, capacityB)
		local shared = a.ammo.tweakDbId == b.ammo.tweakDbId
		local reserve = shared and (ammoA + ammoB - magA - magB) or (ammoB - magB)
		held.sharedAmmo, partner.sharedAmmo = shared, shared
		local id = Open77.weapons.setAmmo(source, slotOf(held), { reserve = shared and 0 or (ammoA - magA), magazine = magA, activate = true })
		if id then
			remember(id, { source = source, kind = 'pairFirst', held = held, partner = partner,
				amounts = { reserve = reserve, magazine = magB, activate = true } })
		else failPair(source, held, partner) end
		return
	end
	if step.kind == 'pairFirst' or step.kind == 'pairLast' then
		if held ~= step.held or mapOf(step.partner)[source] ~= step.partner then return end
		if accepted == true and step.kind == 'pairFirst' then
			local id = Open77.weapons.setAmmo(source, slotOf(step.partner), step.amounts)
			if id then remember(id, { source = source, kind = 'pairLast', held = held, partner = step.partner }); return end
			failPair(source, held, step.partner)
			return
		end
		held.loading, step.partner.loading = false, false
		if accepted ~= true then failPair(source, held, step.partner) end
		return
	end

	if step.kind == 'redraw' then
		reading[step.held.serial] = nil
		step.held.loading = false
		if held ~= step.held then return end
		if Players.Citizen(source) ~= step.bag.owner then return end
		local row = rowOf(result, slotOf(step.held))
		if accepted ~= true or row == nil or type(row.ammo) ~= 'table'
			or held.tweakDbId == nil or row.tweakDbId ~= held.tweakDbId
			or Common.Integer(row.ammo.total, 0, 1000000) == nil then
			OPX.NotifyLocale(source, 'inventory.error.weapon_refused', nil, 'error')
			return
		end
		lower(source, held, row.ammo.total)
		local entry = step.bag.items[step.slot]
		if Players.Citizen(source) ~= step.bag.owner or entry == nil
			or entry.name ~= step.name
			or (entry.metadata and entry.metadata.serial) ~= step.serial then return end
		map[source] = nil
		Weapons.Announce(source, nil)
		if not Players.MayAct(source) then return end
		local hauling = OPX.Api.Get('hauling')
		if hauling and type(hauling.IsCarrying) == 'function' and hauling.IsCarrying(source) then return end
		Weapons.Use(source, step.bag, step.slot, step.item, step.held.hand)
		return
	end

	if step.kind == 'assign' then
		if held ~= step.held then return end
		if accepted ~= true then
			if step.held.hand == 'left' then failPair(source, step.held, step.partner); return end
			map[source] = nil
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
		if step.kind == 'holster' and map[source] == nil then
			local removal = Open77.weapons.remove(source, slotOf(step.held))
			if removal then remember(removal, { source = source, kind = 'remove' }) end
		end
		return
	end

	local row = rowOf(result, slotOf(step.held))

	if step.kind == 'holster' then
		-- Only a reading of THIS weapon lowers its rounds. A different weapon may
		-- already be in the slot, and if this one was drawn again the assign has
		-- replaced what is there, so there is nothing to remove.
		if row and type(row.ammo) == 'table' and step.held.tweakDbId ~= nil and
			row.tweakDbId == step.held.tweakDbId then
			lower(source, step.held, row.ammo.total, step.partner)
		end
		if map[source] == nil then
			local removal = Open77.weapons.remove(source, slotOf(step.held))
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
		if held and held == step.held and held.state == 'armed' and not held.loading
			and step.partner == otherOf(source, held)
			and not (otherOf(source, held) and otherOf(source, held).loading) then
			if not row or row.equipped ~= true or
				(held.tweakDbId ~= nil and row.tweakDbId ~= held.tweakDbId) then
				-- Taken off or replaced by another path -- the game's own inventory
				-- screen, for one. It is no longer ours.
				map[source] = nil
				Weapons.Announce(source, nil)
			elseif held.ammoItem and type(row.ammo) == 'table' then
				lower(source, held, row.ammo.total)
			end
		end

		if step.kind == 'scan' and Options.REMOVE_UNBACKED and type(result) == 'table' then
			for index = #result, 1, -1 do
				local slotRow = result[index]
				if type(slotRow) == 'table' and slotRow.equipped == true and
					slotRow.locked ~= true and not backed(source, slotRow) then
					local slot = Common.Integer(slotRow.slot, 1, 6)
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
	local left = source and secondary[source]
	if left and not findHeld(bag, left) then Weapons.Holster(source, false) end
	if held and not findHeld(bag, held) then Weapons.Holster(source, false) end
end

--- Asks for a reading of every drawn weapon that loads rounds.
-- @author dop42
function Weapons.SyncAmmo()
	if not available() then return end
	for _, map in ipairs({ armed, secondary }) do
		for source, held in pairs(map) do
			if held.ammoItem and held.state == 'armed' and not held.loading and
				not (otherOf(source, held) and otherOf(source, held).loading) and
				Players.GateOpen(source) then
				local requestId = Open77.weapons.requestSnapshot(source)
				if requestId then
					remember(requestId, { source = source, kind = 'sync', held = held })
				end
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
				if secondary[source] then
					local leftId = Open77.weapons.requestSnapshot(source)
					if leftId then remember(leftId, { source = source, kind = 'sync', held = secondary[source] }) end
				end
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
			if step.kind == 'pairRead' or step.kind == 'pairFirst' or step.kind == 'pairLast'
				or (step.kind == 'assign' and step.held and step.held.hand == 'left') then
				failPair(step.source, step.held, step.partner)
			end
			if step.held then step.held.loading = false; reading[step.held.serial] = nil end
			if step.partner then step.partner.loading = false; reading[step.partner.serial] = nil end
			if (step.kind == 'holster' or step.kind == 'redraw') and step.held then reading[step.held.serial] = nil end
		end
	end
end

--- Wires the relay's completion event.
-- @author dop42
function Weapons.Wire()
	AddEventHandler(HOST_WEAPON_COMPLETED, completed)
end
