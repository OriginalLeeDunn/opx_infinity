--- The phases, the contract, the background loops and the last-chance writes.
-- @author dop42
--
-- Nothing here decides anything about a container: each contract function checks
-- its arguments and calls into `Containers`, `Actions` or `World`.
--
-- WHAT THIS RUNTIME DELETED. The contract below used to be seventeen exports,
-- each wrapped in a guard that read the calling resource off the host, checked it
-- against a read list and a writer list, refused it with an audit line, and bounded
-- the encoded answer against a 32 KiB ceiling with `GetInventory` and `GetItems`
-- paging under it. A contract inside one Lua state has no caller to identify, no
-- wire to fit under and no page to turn.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Catalog = M.Catalog
local Containers = M.Containers
local Players = M.Players
local World = M.World
local Actions = M.Actions
local Weapons = M.Weapons
local Requests = M.Requests
local Commands = M.Commands
local Currency = M.Currency

local Result = OPX.Result

-- Set by `Stop` so the background thread ends with the module.
local stopped = false

--- The bag of a player id or of a citizen id, online or not.
-- The second answer is true when this call is what loaded the bag, so the caller
-- knows it has to settle it again afterwards.
local function bagOf(target)
	if type(target) == 'number' then
		local source = Common.Integer(target, 1, 2147483647)
		if not source then return nil, false, 'bad_target' end
		local bag, reason = Players.Bag(source)
		if not bag and reason == 'not_loaded' then bag, reason = Players.Attach(source) end
		return bag, false, reason
	end
	local citizenId, reason = Players.Identify(target)
	if not citizenId then return nil, false, reason end
	local online = Players.SourceOf(citizenId)
	if online then
		local bag, bagReason = Players.Bag(online)
		return bag, false, bagReason
	end
	return Players.LoadBag(citizenId)
end

--- An item name argument when it is well formed, or nil.
local function itemName(value)
	return Common.Word(value, Catalog.NAME_MAX, Catalog.NAME)
end

--- Runs `body` against a target's bag, settling a borrowed one afterwards.
-- Yields. Every writing contract function goes through it, so that no path can
-- load an offline bag and forget to put it away again.
local function withBag(target, body)
	local bag, borrowed, reason = bagOf(target)
	if not bag then return Result.Err(reason or 'not_found', tostring(target)) end
	local answer = body(bag)
	if borrowed then Players.Settle(bag) end
	return answer
end

--- Turns the two answers of a container operation into a Result.
local function outcome(ok, code)
	if ok then return Result.Ok(true) end
	return Result.Err(code or 'failed')
end

-- ── the contract ─────────────────────────────────────────────────────────────

--- Adds catalogue items to a bag, copying the metadata onto each unit added.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param count integer|nil
-- @param metadata table|nil
-- @return Result
function M.AddItem(target, name, count, metadata)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end

	return withBag(target, function(bag)
		local ok, code = Containers.Add(bag, name, count, kept)
		OPX.Audit.Log({ event = 'inventory.add', severity = ok and 'info' or 'warn',
			message = ('%dx %s'):format(count, name), citizenId = bag.owner,
			data = { item = name, count = count, error = code } })
		return outcome(ok, code)
	end)
end

--- Takes items out of a bag, from the last slot backwards.
-- A nil metadata matches any stack of that item, which is what a caller taking
-- "three bandages" means.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param count integer|nil
-- @param metadata table|nil
-- @return Result
function M.RemoveItem(target, name, count, metadata)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end

	return withBag(target, function(bag)
		local ok, code = Containers.Remove(bag, name, count, kept)
		OPX.Audit.Log({ event = 'inventory.remove', severity = ok and 'info' or 'warn',
			message = ('%dx %s'):format(count, name), citizenId = bag.owner,
			data = { item = name, count = count, error = code } })
		return outcome(ok, code)
	end)
end

--- Takes units out of one precise slot, never a look-alike elsewhere.
-- @author dop42
-- @param target Source|CitizenId
-- @param slot integer
-- @param count integer|nil
-- @return Result
function M.RemoveFromSlot(target, slot, count)
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return Result.Err('bad_argument', 'slot') end

	return withBag(target, function(bag)
		local entry = Containers.GetSlot(bag, slot)
		if not entry then return Result.Err('empty_slot', tostring(slot)) end
		local ok, code = Containers.TakeFromSlot(bag, slot, count == nil and entry.count or count)
		OPX.Audit.Log({ event = 'inventory.removeSlot', severity = ok and 'info' or 'warn',
			message = ('slot %d'):format(slot), citizenId = bag.owner,
			data = { slot = slot, item = entry.name, error = code } })
		return outcome(ok, code)
	end)
end

--- Replaces the metadata of one stack.
-- @author dop42
-- @param target Source|CitizenId
-- @param slot integer
-- @param metadata table|nil
-- @return Result
function M.SetMetadata(target, slot, metadata)
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return Result.Err('bad_argument', 'slot') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end

	return withBag(target, function(bag)
		local ok, code = Containers.SetMetadata(bag, slot, kept)
		OPX.Audit.Log({ event = 'inventory.metadata', severity = ok and 'info' or 'warn',
			message = ('slot %d'):format(slot), citizenId = bag.owner,
			data = { slot = slot, error = code } })
		return outcome(ok, code)
	end)
end

--- Empties a bag.
-- @author dop42
-- @param target Source|CitizenId
-- @return Result
function M.ClearInventory(target)
	return withBag(target, function(bag)
		local stacks = OPX.Table.Count(bag.items)
		local ok, code = Containers.Clear(bag)
		OPX.Audit.Log({ event = 'inventory.clear', severity = ok and 'info' or 'warn',
			message = ('%d stack(s)'):format(stacks), citizenId = bag.owner,
			data = { stacks = stacks, error = code } })
		return outcome(ok, code)
	end)
end

--- How many units of an item a bag holds.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param metadata table|nil nil counts every stack of that item
-- @return Result integer
function M.GetItemCount(target, name, metadata)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	return withBag(target, function(bag)
		return Result.Ok(Containers.CountIn(bag, name, kept))
	end)
end

--- How many units of an item carry every metadata field of `match`.
-- The metadata question `GetItemCount` cannot ask: it compares whole tables, so
-- "a key to plate 12ABC345" is answered only by a caller that can rebuild the
-- key's metadata byte for byte. This compares the fields named and ignores the
-- rest.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param match table
-- @return Result integer
function M.CountWhere(target, name, match)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(match, Options.MAX_METADATA_BYTES)
	if not allowed or kept == nil then return Result.Err('bad_argument', 'match') end
	return withBag(target, function(bag)
		return Result.Ok(Containers.CountWhere(bag, name, kept))
	end)
end

--- Whether a bag holds at least `count` of an item.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param count integer|nil
-- @return Result boolean
function M.HasItem(target, name, count)
	local counted = M.GetItemCount(target, name, nil)
	if not counted.ok then return counted end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end
	return Result.Ok(counted.value >= count)
end

--- Whether a bag would take the units, by slots and by weight.
-- @author dop42
-- @param target Source|CitizenId
-- @param name string
-- @param count integer|nil
-- @param metadata table|nil
-- @return Result boolean
function M.CanCarry(target, name, count, metadata)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end
	return withBag(target, function(bag)
		local ok = Containers.CanCarry(bag, name, count, kept)
		return Result.Ok(ok)
	end)
end

-- ── a vehicle's trunk ────────────────────────────────────────────────────────

--- Runs `body` against a vehicle's trunk. Yields: an owned trunk loads by plate.
--
-- `source`, when given, is held to the rule `Actions.OpenVehicle` applies to a
-- player opening the boot by hand: an owned trunk answers to its owner only while
-- TRUNK_OWNER_ONLY is on. A job putting things into a stranger's car, or selling
-- them out of it, is the same theft as the screen, done by another door.
local function withTrunk(vehicleId, source, body)
	if type(vehicleId) == 'string' and vehicleId:match('^%d+$') and #vehicleId <= 19 then
		vehicleId = math.tointeger(tonumber(vehicleId))
	end
	vehicleId = Common.Integer(vehicleId, 1, math.maxinteger)
	if not vehicleId then return Result.Err('bad_argument', 'vehicleId') end
	-- A LOCKED VEHICLE'S BOOT IS SHUT TO A JOB TOO. The owner: "si veh fermé
	-- coffre de veh inaccessible". The screen refuses it in `Actions.OpenVehicle`;
	-- this is the same rule for a module putting things in or taking them out.
	if World.TrunkLocked(vehicleId) then return Result.Err('locked', tostring(vehicleId)) end
	local trunk, reason = World.VehicleContainer(vehicleId, M.KIND.TRUNK)
	if not trunk then return Result.Err(reason or 'not_found', tostring(vehicleId)) end
	if source ~= nil and Options.TRUNK_OWNER_ONLY and trunk.ownerCitizenId
		and trunk.ownerCitizenId ~= Players.Citizen(source) then
		return Result.Err('not_yours', tostring(vehicleId))
	end
	return body(trunk)
end

--- Adds catalogue items to a vehicle's trunk.
-- @author dop42
-- @param vehicleId integer|string
-- @param name string
-- @param count integer|nil
-- @param metadata table|nil
-- @param source Source|nil held to the trunk owner rule when given
-- @return Result
function M.AddToTrunk(vehicleId, name, count, metadata, source)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end

	return withTrunk(vehicleId, source, function(trunk)
		local ok, code = Containers.Add(trunk, name, count, kept)
		OPX.Audit.Log({ event = 'inventory.trunkAdd', severity = ok and 'info' or 'warn',
			message = ('%dx %s'):format(count, name),
			data = { vehicle = tostring(vehicleId), item = name, count = count, error = code } })
		return outcome(ok, code)
	end)
end

--- Takes items out of a vehicle's trunk; nil metadata matches any stack.
-- @author dop42
-- @param vehicleId integer|string
-- @param name string
-- @param count integer|nil
-- @param metadata table|nil
-- @param source Source|nil held to the trunk owner rule when given
-- @return Result
function M.RemoveFromTrunk(vehicleId, name, count, metadata, source)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end

	return withTrunk(vehicleId, source, function(trunk)
		local ok, code = Containers.Remove(trunk, name, count, kept)
		OPX.Audit.Log({ event = 'inventory.trunkRemove', severity = ok and 'info' or 'warn',
			message = ('%dx %s'):format(count, name),
			data = { vehicle = tostring(vehicleId), item = name, count = count, error = code } })
		return outcome(ok, code)
	end)
end

--- How many units of an item a vehicle's trunk holds.
-- @author dop42
-- @param vehicleId integer|string
-- @param name string
-- @param metadata table|nil nil counts every stack of that item
-- @param source Source|nil held to the trunk owner rule when given
-- @return Result integer
function M.CountInTrunk(vehicleId, name, metadata, source)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	return withTrunk(vehicleId, source, function(trunk)
		return Result.Ok(Containers.CountIn(trunk, name, kept))
	end)
end

-- ── a named stash ────────────────────────────────────────────────────────────

-- How long a stash loaded by name, and not opened by anybody, stays in memory
-- after its last touch, when `SERVER.EXPORTS.STASHES.IDLE_MS` says nothing.
local STASH_IDLE_MS = 60000

-- How many stashes one resource may create, when the call names no cap.
local STASH_CREATE_CAP = 25

--- The configured stash of a name, or nil.
local function configuredStash(name)
	local configured = Options.STASHES[name]
	if configured ~= nil then return configured end
	for _, stash in ipairs(Options.STASH_LIST) do
		if stash.name == name then return stash end
	end
	return nil
end

--- Whether a stash that does not exist yet may be created, and why not.
--
-- THE CREATION RULE FOR ANOTHER RESOURCE (`creator` set; this resource's own
-- modules pass none and keep creating as they always have). A stash in
-- `config/inventory` may always be created: the operator listed it. Anything
-- else must be named in the caller's own namespace, `<resource>.<name>`, and a
-- resource may hold at most `cap` of those, counted in the database so a
-- restart does not reset it. Without the rule a caller walking names would
-- create a row, and hold a container, for every one.
-- @return boolean
-- @return string|nil the refusal code
local function mayCreate(name, options)
	local creator = options and options.creator
	if creator == nil then return true, nil end
	if configuredStash(name) ~= nil then return true, nil end
	local prefix = tostring(creator) .. '.'
	if #name <= #prefix or name:sub(1, #prefix) ~= prefix then
		return false, 'stash_namespace'
	end
	local cap = math.tointeger(tonumber(options.cap)) or STASH_CREATE_CAP
	local held = M.Storage.CountPrefixed(M.KIND.STASH, prefix)
	if not held.ok then return false, 'storage' end
	if held.value >= cap then return false, 'stash_cap' end
	return true, nil
end

--- Runs `body` against a stash by its storage name. Yields: a stash loads by name.
--
-- THE STASH IS LOADED, NEVER OPENED. `OpenStash` and the configured markers put
-- a stash in front of a player and give it its anchor; this path only reads and
-- writes what is in it, so it goes to `Containers.Load` itself rather than
-- through `World.Stash`, which would mark an anchorless load as reachable from
-- anywhere and say so in the journal. A configured stash is created at its own
-- size, anything else at `OpenStash`'s defaults -- and only on the first touch:
-- an existing stash keeps the size it was made with.
--
-- A STASH THAT DOES NOT EXIST is answered by `absent` when only `create` may
-- make one: a count is 0 and a removal finds nothing, without a row or a
-- container for either. A stash this path loaded is marked `external` and put
-- away by `Containers.SweepExternal` once idle, unless a player opens it.
-- @param name string
-- @param body fun(container: table, name: string): Result
-- @param create boolean whether a missing stash may be created (see `mayCreate`)
-- @param absent fun(name: string): Result what a missing stash answers
-- @param options table|nil creator, cap
local function withStash(name, body, create, absent, options)
	name = Common.Word(name, 48, '^[%w_%-%.]+$')
	if not name then return Result.Err('bad_argument', 'stash') end

	local container = Containers.Find(M.KIND.STASH, name)
	if container == nil then
		local found = M.Storage.Find(M.KIND.STASH, name)
		if not found.ok then return Result.Err('unavailable', name) end
		if found.value == nil then
			if not create then return absent(name) end
			local allowed, why = mayCreate(name, options)
			if not allowed then return Result.Err(why, name) end
		end
		local configured = configuredStash(name)
		local reason
		container, reason = Containers.Load(M.KIND.STASH, name,
			configured and configured.slots or 50, configured and configured.maxWeight or 100000)
		if not container then return Result.Err(reason or 'unavailable', name) end
		-- Only one this path brought in: a stash a player opened keeps its own life.
		if not Containers.IsViewed(container.id) and container.anchor == nil
			and container.anywhere == nil then
			container.external = true
		end
	end
	if container.external then container.externalAt = OPX.Now() end
	return body(container, name)
end

--- Puts away the stashes loaded by name and idle since. Yields.
-- @author dop42
-- @return integer
function M.SweepStashes()
	local exports = OPX.Config.SERVER and OPX.Config.SERVER.EXPORTS
	local stashes = type(exports) == 'table' and exports.STASHES or nil
	local idle = type(stashes) == 'table' and math.tointeger(tonumber(stashes.IDLE_MS)) or nil
	return Containers.SweepExternal(idle or STASH_IDLE_MS)
end

--- Adds catalogue items to a named stash.
-- @author dop42
-- @param name string the stash's storage key
-- @param item string
-- @param count integer|nil
-- @param metadata table|nil
-- @param options table|nil `{ creator = <resource>, cap = <n> }` for a call
--   from another resource: a missing stash is then created only under the rule
--   of `mayCreate`. Omitted, a missing stash is created as before.
-- @return Result
function M.AddToStash(name, item, count, metadata, options)
	item = itemName(item)
	if not item then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end

	return withStash(name, function(stash, key)
		local ok, code = Containers.Add(stash, item, count, kept)
		OPX.Audit.Log({ event = 'inventory.stashAdd', severity = ok and 'info' or 'warn',
			message = ('%dx %s'):format(count, item),
			data = { stash = key, item = item, count = count, error = code,
				creator = options and options.creator or nil } })
		return outcome(ok, code)
	end, true, nil, options)
end

--- Takes items out of a named stash; nil metadata matches any stack. Never
--- creates one: a stash that does not exist holds nothing to take.
-- @author dop42
-- @param name string
-- @param item string
-- @param count integer|nil
-- @param metadata table|nil
-- @return Result
function M.RemoveFromStash(name, item, count, metadata)
	item = itemName(item)
	if not item then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end
	count = count == nil and 1 or Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return Result.Err('bad_argument', 'count') end

	return withStash(name, function(stash, key)
		local ok, code = Containers.Remove(stash, item, count, kept)
		OPX.Audit.Log({ event = 'inventory.stashRemove', severity = ok and 'info' or 'warn',
			message = ('%dx %s'):format(count, item),
			data = { stash = key, item = item, count = count, error = code } })
		return outcome(ok, code)
	end, false, function() return Result.Err('not_enough') end)
end

--- How many units of an item a named stash holds. Never creates one: a stash
--- that does not exist holds 0.
-- @author dop42
-- @param name string
-- @param item string
-- @param metadata table|nil nil counts every stack of that item
-- @return Result integer
function M.CountInStash(name, item, metadata)
	item = itemName(item)
	if not item then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(metadata, Options.MAX_METADATA_BYTES)
	if not allowed then return Result.Err('bad_argument', 'metadata') end
	return withStash(name, function(stash)
		return Result.Ok(Containers.CountIn(stash, item, kept))
	end, false, function() return Result.Ok(0) end)
end

--- Takes EVERY unit of an item whose metadata carries the fields of `match`
--- out of a bag. The removing half of `CountWhere`.
-- @author dop42
--
-- What a key asks: "every key to plate 12ABC345", whatever its label says.
-- `RemoveItem` compares whole metadata tables and would leave a key whose label
-- was written in another language; this compares only the fields named. Slot by
-- slot, from the last, so it never takes a look-alike that does not match.
-- @param target Source|CitizenId
-- @param name string
-- @param match table field -> string|number|boolean
-- @return Result integer how many units were taken
function M.RemoveWhere(target, name, match)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	local kept, allowed = Common.Metadata(match, Options.MAX_METADATA_BYTES)
	if not allowed or kept == nil or next(kept) == nil then
		return Result.Err('bad_argument', 'match')
	end
	for _, value in pairs(kept) do
		if type(value) == 'table' then return Result.Err('bad_argument', 'match') end
	end

	return withBag(target, function(bag)
		local slots = {}
		for slot, entry in pairs(bag.items) do
			local metadata = entry.metadata
			if entry.name == name and type(metadata) == 'table' then
				local carries = true
				for key, value in pairs(kept) do
					if metadata[key] ~= value then carries = false break end
				end
				if carries then slots[#slots + 1] = slot end
			end
		end
		table.sort(slots, function(a, b) return a > b end)
		local taken = 0
		for index = 1, #slots do
			local entry = bag.items[slots[index]]
			if entry ~= nil then
				local count = entry.count
				if Containers.TakeFromSlot(bag, slots[index], count) then taken = taken + count end
			end
		end
		if taken > 0 then
			OPX.Audit.Log({ event = 'inventory.removeWhere', message = ('%dx %s'):format(taken, name),
				citizenId = bag.owner, data = { item = name, count = taken, match = kept } })
		end
		return Result.Ok(taken)
	end)
end

--- A bag as a screen would draw it: the slots, the stacks and the weight.
-- Answered whole. It used to be paged by 64 stacks under a 32 KiB ceiling because
-- it crossed a network argument; it does not cross anything now.
-- @author dop42
-- @param target Source|CitizenId
-- @return Result
function M.GetInventory(target)
	return withBag(target, function(bag)
		return Result.Ok(Containers.Describe(bag))
	end)
end

--- The stack in one slot of a bag, or nil.
-- A COPY, so a caller cannot edit a container by editing the answer.
-- @author dop42
-- @param target Source|CitizenId
-- @param slot integer
-- @return Result
function M.GetSlot(target, slot)
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return Result.Err('bad_argument', 'slot') end
	return withBag(target, function(bag)
		local entry = Containers.GetSlot(bag, slot)
		if not entry then return Result.Ok(nil) end
		return Result.Ok({ slot = slot, name = entry.name, count = entry.count,
			metadata = Common.Copy(entry.metadata) })
	end)
end

--- One catalogue entry as a screen reads it, or nil.
-- @author dop42
-- @param name string
-- @return table|nil
function M.GetItem(name)
	return Catalog.ViewOf(name)
end

--- Every catalogue entry, by name.
-- @author dop42
-- @return table<string, table>
function M.GetItems()
	local out = {}
	local names = Catalog.Names()
	for index = 1, #names do out[names[index]] = Catalog.ViewOf(names[index]) end
	return out
end

-- ── items another resource registers ─────────────────────────────────────────

-- Items one `opx:net:inventory:catalog` carries. Small, because the client
-- validates each one inside the resume that received them (see
-- `Catalog.Register`): FOUR. An item at every bound the validator allows costs
-- the client about 1,500 instructions, so eight of them (the first figure here)
-- overran the ~10,000 a resume may spend and the client's handler was killed --
-- every item in that event missing on that client while the server kept them.
-- Four at the bounds is about 6,500; a long list simply arrives in more events.
local RUNTIME_CHUNK = 4

-- The ceiling on items one owner registers when the caller names none.
local RUNTIME_DEFAULT_CAP = 64

--- Sends runtime definitions to one client, or to every client with -1.
local function sendRuntime(target, list)
	for first = 1, #list, RUNTIME_CHUNK do
		local part = {}
		for index = first, math.min(#list, first + RUNTIME_CHUNK - 1) do
			part[#part + 1] = list[index]
		end
		TriggerClientEvent(M.Event.CATALOG, target, part)
	end
end

--- Adds an item to the catalogue at runtime, on both halves, or replaces one its
--- own owner registered before.
-- Validated by `Catalog.Register`, which every client runs on the same table, and
-- sent to every connected client; a client that joins later is sent the whole
-- runtime list on its hello. Never persisted: the owner registers it again on
-- every start, and a stack of it in a bag waits for that.
-- @author dop42
-- @param name string
-- @param definition table label, description, weight, stack, drop, category, image, model, use
-- @param owner string who registers it, e.g. `ext:my_shop`
-- @param cap integer|nil most items this owner may hold registered
-- @return Result the item as a screen reads it
function M.RegisterItem(name, definition, owner, cap)
	if type(owner) ~= 'string' or owner == '' then return Result.Err('bad_argument', 'owner') end
	local held = Catalog.Get(name)
	if held == nil then
		local ceiling = Common.Integer(cap, 0, 100000) or RUNTIME_DEFAULT_CAP
		if Catalog.RuntimeCount(owner) >= ceiling then return Result.Err('item_cap') end
	end
	local registered, why = Catalog.Register(name, definition, owner)
	if not registered then return Result.Err(why) end
	sendRuntime(-1, { { name = name, owner = owner, definition = Common.Copy(definition) } })
	return Result.Ok(Catalog.ViewOf(name))
end

--- Sends one client every item registered at runtime so far.
-- @author dop42
-- @param player Source
function M.SendRuntimeItems(player)
	local list = {}
	for name, held in pairs(Catalog.Runtime()) do
		list[#list + 1] = { name = name, owner = held.owner, definition = held.definition }
	end
	if #list > 0 then sendRuntime(player, list) end
end

--- Opens a stash beside a player's bag and raises their screen.
-- The CALLER answers for whether this player may open this stash -- a job, a key,
-- a code. This module only checks the reach, and only when a position is given: a
-- stash opened with no position has no anchor and stays in reach.
-- @author dop42
-- @param playerId Source
-- @param name string the storage key; never reuse one for somewhere else
-- @param options table|nil slots, maxWeight, label, position, bucket
-- @return Result the container id
function M.OpenStash(playerId, name, options)
	playerId = Common.Integer(playerId, 1, 2147483647)
	name = Common.Word(name, 48, '^[%w_%-%.]+$')
	if not playerId or not name then return Result.Err('bad_argument', 'playerId or name') end
	options = type(options) == 'table' and options or {}

	local size = {
		slots = options.slots == nil and 50 or Common.Integer(options.slots, 1, 200),
		maxWeight = options.maxWeight == nil and 100000 or
			Common.Integer(options.maxWeight, 0, 4000000000),
	}
	if not size.slots or not size.maxWeight then return Result.Err('bad_argument', 'size') end
	-- A CONFIGURED STASH IS MADE AT ITS CONFIGURED SIZE, whoever opens it first:
	-- the size is written into the row on creation and kept for ever after, so a
	-- caller's (or the default 50) would replace the operator's for good. The
	-- same rule `withStash` and the stash marker follow.
	local configured = configuredStash(name)
	if configured ~= nil then
		size = { slots = configured.slots, maxWeight = configured.maxWeight }
	end
	-- `MayAct`, not `GateOpen` alone: the one door `Players.MayAct` was written
	-- to close -- "a player on the floor could empty their bag into a boot" --
	-- stayed open here, through the armoury chests and every creator stash.
	local may, refusal = Players.MayAct(playerId)
	if not may then return Result.Err(refusal) end
	if not Players.Bag(playerId) then return Result.Err('not_loaded') end

	-- ANOTHER RESOURCE OPENS ONLY WHAT IT MAY NAME: a stash the operator listed,
	-- or one in its own `<resource>.` namespace -- and a new one of those only
	-- under the creation cap, the rule `AddToStash` keeps. Never a stash that
	-- belongs to a module or to another resource, which would be a back door
	-- into somebody else's storage.
	if options.creator ~= nil then
		local prefix = tostring(options.creator) .. '.'
		local own = #name > #prefix and name:sub(1, #prefix) == prefix
		if configuredStash(name) == nil and not own then
			return Result.Err('stash_namespace', name)
		end
		if Containers.Find(M.KIND.STASH, name) == nil then
			local found = M.Storage.Find(M.KIND.STASH, name)
			if not found.ok then return Result.Err('unavailable', name) end
			if found.value == nil then
				local allowed, why = mayCreate(name, options)
				if not allowed then return Result.Err(why, name) end
			end
		end
	end

	local anchor
	if type(options.position) == 'table' then
		local x, y, z = tonumber(options.position.x), tonumber(options.position.y),
			tonumber(options.position.z)
		if not (OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)) then
			return Result.Err('bad_argument', 'position')
		end
		anchor = { x = x, y = y, z = z,
			bucket = Common.Integer(options.bucket, 0, 2147483647) or 0 }
		if not World.InReach(World.Position(playerId), anchor) then
			return Result.Err('too_far')
		end
	end

	local container, reason = World.Stash(name, size, anchor, Common.Clean(options.label, 64))
	if not container then return Result.Err(reason or 'unavailable', name) end
	Containers.View(playerId, container)
	TriggerClientEvent(M.Event.OPEN, playerId)
	OPX.Audit.Log({ event = 'inventory.openStash', message = name, source = playerId,
		data = { stash = name } })
	return Result.Ok(container.id)
end

--- Closes a player's screen and whatever it had open beside the bag.
-- @author dop42
-- @param playerId Source
-- @return Result
function M.CloseInventory(playerId)
	playerId = Common.Integer(playerId, 1, 2147483647)
	if not playerId then return Result.Err('bad_argument', 'playerId') end
	Containers.CloseSecondary(playerId, true)
	TriggerClientEvent(M.Event.RESET, playerId)
	return Result.Ok(true)
end

--- The weapon this module has put in a player's hands, or nil.
-- @author dop42
-- @param playerId Source
-- @return table|nil
function M.GetHeldWeapon(playerId)
	local held = Weapons.Held(Common.Integer(playerId, 1, 2147483647) or -1)
	if not held then return nil end
	return { name = held.name, serial = held.serial, slot = Options.WEAPON_SLOT }
end

--- Puts away the weapon this module put in a player's hands, reading its rounds
--- back into the bag first. The one way another module may holster somebody:
--- taking the engine slot behind this module's back would leave it believing
--- the player is still armed.
-- @author dop42
-- @param playerId Source
-- @return Result carrying { name, serial } of what was put away
function M.HolsterWeapon(playerId)
	playerId = Common.Integer(playerId, 1, 2147483647)
	if not playerId then return Result.Err('bad_argument', 'playerId') end
	local held = Weapons.Held(playerId)
	if not held then return Result.Err('not_armed') end
	Weapons.Holster(playerId, true)
	return Result.Ok({ name = held.name, serial = held.serial })
end

--- Whether a kind names one of the container kinds. A non-string used to
--- raise on `:upper()` inside the caller instead of being refused.
local function knownKind(kind)
	return type(kind) == 'string' and M.KIND[kind:upper()] ~= nil
end

--- Unloads a container a contract call loaded itself, unless somebody now has
--- it open or its owner is playing. Yields: an unload writes first.
local function putBack(container)
	if Containers.IsViewed(container.id) then return end
	if container.kind == M.KIND.CHARACTER and Players.SourceOf(container.owner) then return end
	Containers.Unload(container.id)
end

--- Changes a stored container's slot count and weight limit.
-- `Ensure` only writes a size for the row that creates it, so a container keeps
-- the size it was made with for ever; this is the one way that changes. The copy
-- in memory is moved with it, or the two would disagree until it was unloaded.
-- @author dop42
-- @param kind string
-- @param owner string
-- @param slots integer
-- @param maxWeight integer
-- @return Result
function M.ResizeContainer(kind, owner, slots, maxWeight)
	if not knownKind(kind) then return Result.Err('bad_argument', 'kind') end
	owner = Common.Word(owner, 64, '^[%w_%-%.:]+$')
	slots = Common.Integer(slots, 1, 200)
	maxWeight = Common.Integer(maxWeight, 0, 4000000000)
	if not owner or not slots or not maxWeight then
		return Result.Err('bad_argument', 'owner or size')
	end

	local held = Containers.Find(kind, owner)
	local id = held and not held.transient and held.id or nil
	local borrowed = false
	if id == nil then
		local loaded, reason = Containers.Load(kind, owner, slots, maxWeight)
		if not loaded then return Result.Err(reason or 'not_found', owner) end
		if loaded.transient then return Result.Err('not_found', owner) end
		held, id, borrowed = loaded, loaded.id, true
	end

	local written = M.Storage.Resize(id, slots, maxWeight)
	if not written.ok then
		if borrowed then putBack(held) end
		return written
	end
	held.slots = slots
	held.maxWeight = maxWeight
	-- Stacks beyond the new slot count are kept, counted and removable; they are
	-- simply not drawn and nothing new is put there.
	Containers.Publish(held)
	-- A CONTAINER THIS CALL LOADED IS PUT AWAY AGAIN. Resizing an offline bag or
	-- a stash nobody had open used to leave it loaded for the life of the
	-- resource: nothing else ever unloads a bag whose owner is not here, and a
	-- stash loaded here was not marked for the idle sweep either.
	if borrowed then putBack(held) end
	OPX.Audit.Log({ event = 'inventory.resize', message = ('%s %s'):format(kind, owner),
		data = { kind = kind, owner = owner, slots = slots, maxWeight = maxWeight } })
	return Result.Ok(id)
end

--- Deletes a stored container. Its stacks go by cascade, and EVERYTHING IN IT
--- goes with them.
-- The copy in memory is discarded first and without writing: writing it back
-- would put the rows that were just deleted straight in again.
-- @author dop42
-- @param kind string
-- @param owner string
-- @return Result
function M.DeleteContainer(kind, owner)
	if not knownKind(kind) then return Result.Err('bad_argument', 'kind') end
	owner = Common.Word(owner, 64, '^[%w_%-%.:]+$')
	if not owner then return Result.Err('bad_argument', 'owner') end

	local held = Containers.Find(kind, owner)
	if held then
		if held.transient then return Result.Err('bad_argument', 'kind') end
		Containers.Discard(held.id)
	end

	-- `Find` and never `Ensure`: ensuring would CREATE the row it is about to
	-- delete, and for a linked kind it would create it with no owner column set.
	local found = M.Storage.Find(kind, owner)
	if not found.ok then return found end
	if not found.value then return Result.Err('not_found', owner) end
	local removed = M.Storage.Delete(found.value.id)
	if not removed.ok then return removed end
	OPX.Audit.Log({ event = 'inventory.delete', severity = 'warn',
		message = ('%s %s'):format(kind, owner), data = { kind = kind, owner = owner } })
	return Result.Ok(true)
end

--- The containers holding an item, largest stacks first.
-- @author dop42
-- @param name string
-- @param limit integer|nil
-- @return Result
function M.Holders(name, limit)
	name = itemName(name)
	if not name then return Result.Err('bad_argument', 'name') end
	return M.Storage.Holders(name, Common.Integer(limit, 1, 200) or 20)
end

-- ── the background pass ──────────────────────────────────────────────────────

--- Runs a loop body forever, reading its period on every pass.
-- `OPX.Scheduler` is the client's loop; the server VM has none, so each loop
-- keeps its own thread. `guarded` says whether the pass may run under a `pcall` --
-- which it may only if it never yields, because a yield does not cross one.
local function every(periodMs, label, guarded, body)
	CreateThread(function()
		local failing = false
		while not stopped do
			Wait(periodMs())
			if not stopped and not OPX.BootError then
				if guarded then
					local ok, failure = pcall(body)
					if ok then
						failing = false
					elseif not failing then
						failing = true
						Open77.log.error(('[inventory] the %s pass raised: %s')
							:format(label, tostring(failure)))
					end
				else
					body()
				end
			end
		end
	end)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state, contributes the tables and declares the tunables. Never yields.
-- @author dop42
function M.Init()
	-- Filled in `Start`: `Init` runs before any contract is published, so reading
	-- one here would answer nil for the life of the resource. It exists now so
	-- that a read before `Start` is a nil field and not a nil index.
	M.Contracts = {}

	OPX.Schema.Add(M.Storage.SCHEMA)
	OPX.Tune.Declare(M.TUNABLES)
end

--- Publishes the contract. Nothing may read one before this phase ends.
-- @author dop42
function M.Api()
	OPX.Api.Provide('inventory', 1, {
		AddItem = M.AddItem,
		RemoveItem = M.RemoveItem,
		RemoveFromSlot = M.RemoveFromSlot,
		SetMetadata = M.SetMetadata,
		ClearInventory = M.ClearInventory,

		GetItemCount = M.GetItemCount,
		CountWhere = M.CountWhere,
		HasItem = M.HasItem,
		CanCarry = M.CanCarry,
		GetInventory = M.GetInventory,
		GetSlot = M.GetSlot,

		AddToTrunk = M.AddToTrunk,
		RemoveFromTrunk = M.RemoveFromTrunk,
		CountInTrunk = M.CountInTrunk,

		-- A named stash, by its storage key, loaded and never opened: what a job
		-- filling an evidence locker or a shop restocking its back room needs.
		AddToStash = M.AddToStash,
		RemoveFromStash = M.RemoveFromStash,
		CountInStash = M.CountInStash,

		-- `CountWhere`'s removing half; what revoking a key needs.
		RemoveWhere = M.RemoveWhere,

		GetItem = M.GetItem,
		GetItems = M.GetItems,
		Holders = M.Holders,

		ResizeContainer = M.ResizeContainer,
		DeleteContainer = M.DeleteContainer,

		OpenStash = M.OpenStash,
		CloseInventory = M.CloseInventory,

		RegisterUsable = Actions.RegisterUsable,
		UnregisterUsable = Actions.UnregisterUsable,
		UsableOwner = Actions.UsableOwner,
		UnregisterUsables = Actions.UnregisterOwner,

		RegisterItem = M.RegisterItem,

		-- THE MONEY BRIDGE, and the only two functions that may move a balance
		-- and a stack of notes in the same breath. Published so that a job, a
		-- heist or an ATM asks for a conversion instead of writing its own pair
		-- of calls -- a caller that debits and inserts by hand is a caller that
		-- will one day do only one of the two. See `server/currency.lua`.
		Withdraw = Currency.Withdraw,
		Deposit = Currency.Deposit,
		CurrencyWired = Currency.Wired,

		GetHeldWeapon = M.GetHeldWeapon,
		HolsterWeapon = M.HolsterWeapon,

		-- Whether a vehicle's trunk is shut to everybody right now. Published so
		-- that every path that puts something in a trunk or takes it out -- the
		-- screen here, and a job loading crates through this contract -- asks the
		-- one question the same way. See `World.TrunkLocked`.
		TrunkLocked = World.TrunkLocked,
	})
end

--- Wires the doors, registers the commands and starts the loops. On a coroutine.
-- @author dop42
function M.Start()
	M.Contracts.character = OPX.Api.Get('character')
	M.Contracts.vehicles = OPX.Api.Get('vehicles')

	if M.Contracts.character == nil then
		Open77.log.warn('[inventory] no character contract: no bag can be identified, so every ' ..
			'request is refused')
	end
	if M.Contracts.vehicles == nil then
		Open77.log.warn('[inventory] no vehicles contract: no vehicle is owned here, so every ' ..
			'trunk and glovebox is memory-only and nothing in one survives a restart')
	end

	for _, line in ipairs(M.Problems) do Open77.log.warn('[inventory] config: ' .. line) end

	Players.Wire()
	Weapons.Wire()
	Requests.Wire()
	Commands.Register()

	-- AFTER the contracts are resolved above, and not in `Init`: the money-to-item
	-- bridge refuses to wire itself at all without a `character` contract to draw
	-- a note against, and `Init` runs before any contract is published.
	Currency.Register()

	-- A DELETED CHARACTER TAKES ITS CONTAINERS WITH IT, and their stacks with
	-- them: the item rows really do cascade off `inventory_id`, and this is a real
	-- DELETE on the parent, so that one fires. The cascade that does NOT fire is
	-- the one from the character table, because a character delete is a soft one.
	-- Left to it, every bag, every trunk and every glovebox of a deleted character
	-- stayed, full, owned by a citizen id nothing can log in as. See
	-- `character.Event.IN_DELETED`.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			local purged = M.Storage.PurgeCharacter(citizenId)
			if purged ~= nil and not purged.ok then
				Open77.log.warn(('[inventory] the containers of the deleted %s were not ' ..
					'removed: %s'):format(citizenId, tostring(purged.detail or purged.error)))
			end
		end)

	Open77.log.info(('[inventory] ready: %d item(s), %d stash(es), bag %d slots / %d g')
		:format(#Catalog.Names(), #Options.STASH_LIST, Options.BAG_SLOTS, Options.BAG_MAX_WEIGHT))

	-- These four reach the database or another module's state and yield, so they
	-- may not be guarded: a yield does not cross a `pcall`.
	every(function() return Options.SAVE_SWEEP_MS end, 'save', false, M.Storage.Sweep)
	every(function() return 1000 end, 'reach', false, World.SweepReach)
	every(function() return 5000 end, 'vehicles', false, World.SweepVehicles)
	every(function() return 30000 end, 'prune', false, Players.PruneVanished)
	every(function() return 15000 end, 'stash idle', false, M.SweepStashes)

	-- These four only touch host calls and tables of this module, and are guarded:
	-- a raise from a host read must end the pass, not the loop.
	every(function() return 60000 end, 'drop sweep', true, World.SweepDrops)
	every(function() return Options.AMMO_SYNC_MS end, 'ammo sync', true, Weapons.SyncAmmo)
	every(function() return Options.WEAPON_SCAN_MS end, 'weapon scan', true, Weapons.Scan)
	every(function() return 10000 end, 'weapon steps', true, Weapons.SweepPending)

	if Options.WEAPONS and type(Open77.weapons) ~= 'table' then
		Open77.log.warn('[inventory] this host installs no weapon relay: drawing a weapon from ' ..
			'the bag is refused')
	end
end

--- The last chance to write: one thread per container, never one loop.
-- A single loop would send the first transaction, suspend, and never be resumed.
-- This is best effort, and the log line says so. It is also all that is needed
-- now: the write used to have to cross into another resource, which a stopping VM
-- cannot do at all, and the whole carry-across-a-reload protocol existed for that.
-- @author dop42
function M.Stop()
	stopped = true
	local pending = M.Storage.Pending()
	local dispatched = M.Storage.FlushAll()
	if pending > 0 then
		Open77.log.info(('[inventory] stopping: dispatched a write for %d of %d unwritten ' ..
			'container(s), best effort'):format(dispatched, pending))
	end
end
