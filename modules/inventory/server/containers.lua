--- Containers in memory, and every operation that changes one.
-- @author dop42
--
-- The server is the only authority on what a container holds. A screen predicts a
-- change and draws it; the next `Publish` corrects it.
--
-- A stored container carries the positive id of its row. A memory-only one --
-- a pile, the storage of a vehicle nobody owns -- carries a negative id from a
-- counter that only ever goes down, is created empty on first request, and is
-- never written. Reading the sign is how anything tells the two apart.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Catalog = M.Catalog
local KIND = M.KIND

M.Containers = {}
local Containers = M.Containers

-- Loaded containers by id, and their ids by kind-and-owner identity.
local loaded = {}
local byIdentity = {}

-- Loads in flight by identity, shared between concurrent callers.
local loading = {}

-- How long a caller waits on another's load in flight, and how old that load
-- may be before it can only be one whose thread was dropped and is taken over.
-- A real load is a handful of statements; ten seconds is a database in trouble.
local LOAD_WAIT_MS = 35000
local LOAD_STALE_MS = 10000

-- What each player has open beside their bag, and whether it is a staff search.
local viewing = {}

local transientSequence = 0
local serialSequence = 0

--- Builds the lookup key of a kind and an owner.
-- A NUL between them, because an owner may contain anything an ascii column
-- takes and two identities must not be able to collide by concatenation.
local function identityOf(kind, owner)
	return kind .. '\0' .. owner
end

--- Units of each item a container holds, by name.
local function tallyOf(container)
	local counts = {}
	for _, entry in pairs(container.items or {}) do
		counts[entry.name] = (counts[entry.name] or 0) + (entry.count or 0)
	end
	return counts
end

--- Records a container as loaded under its id and its identity.
-- A bag is tallied as it arrives, so the first change to it can be announced as
-- what moved rather than as everything it holds.
local function register(container)
	if container.kind == KIND.CHARACTER then container.tally = tallyOf(container) end
	loaded[container.id] = container
	byIdentity[identityOf(container.kind, container.owner)] = container.id
	return container
end

--- Loads a stored container once, sharing a load already in flight.
-- Concurrent callers wait on the same read rather than each starting one: two
-- reads of the same container would each build a copy, and the loser's copy would
-- take every change made to it into the void.
-- @author dop42
-- @param kind string
-- @param owner string
-- @param slots integer used only if this call creates the container
-- @param maxWeight integer
-- @return table|nil
-- @return string|nil
function Containers.Load(kind, owner, slots, maxWeight)
	owner = tostring(owner)
	local identity = identityOf(kind, owner)
	local id = byIdentity[identity]
	if id and loaded[id] then return loaded[id], nil end

	-- A LOAD IN FLIGHT IS WAITED ON, BUT NOT FOR EVER. The thread that set the
	-- marker can be dropped mid-read and never come back -- the host abandons an
	-- export coroutine whose synchronous caller it yielded under, or whose
	-- asynchronous caller stopped -- and a marker nobody will ever clear made
	-- every later load of that stash or bag wait 35 s and fail, for the life of
	-- the resource. A marker older than `LOAD_STALE_MS` is taken over: this
	-- caller loads the container itself, and the abandoned load, should it ever
	-- finish after all, finds the container already registered and adopts it.
	local deadline = OPX.Now() + LOAD_WAIT_MS
	while loading[identity] ~= nil do
		local pending = loading[identity]
		if OPX.Now() - pending.since >= LOAD_STALE_MS then
			Open77.log.warn(('[inventory] the load of %s %s has been in flight for %d ms; ' ..
				'taking it over'):format(kind, owner, OPX.Now() - pending.since))
			loading[identity] = nil
			break
		end
		if OPX.Now() >= deadline then return nil, 'load_timeout' end
		Wait(50)
		if pending.done then
			local shared = pending.container
			if shared == nil then return nil, pending.error or 'load_timeout' end
			-- STILL REGISTERED, OR IT IS NOT THE CONTAINER ANY MORE. This caller
			-- polls every 50 ms, and in that time the loader can finish, change
			-- it, settle a borrowed bag and `Discard` it -- one write is a single
			-- trip. Handing back the discarded table gave the waiter a container
			-- nothing would ever write again: its change was marked dirty against
			-- an id the sweep no longer knew, and dropped. A staff give to an
			-- offline bag racing a contract call was the way in. The loop goes
			-- round instead, and the next read finds it or loads it afresh.
			if loaded[shared.id] == shared then return shared, nil end
		end
	end
	id = byIdentity[identity]
	if id and loaded[id] then return loaded[id], nil end

	local pending = { done = false, since = OPX.Now() }
	loading[identity] = pending
	local container, reason = M.Storage.Read(kind, owner, slots, maxWeight)
	if container then
		-- The read yielded, and another path may have registered the same
		-- container meanwhile. That one is the one everybody else already holds.
		local already = byIdentity[identity] and loaded[byIdentity[identity]]
		if already then container = already else register(container) end
	end
	pending.done, pending.container, pending.error = true, container, reason
	-- Only this load's own marker: a load that took a stale one over owns it now.
	if loading[identity] == pending then loading[identity] = nil end
	return container, reason
end

--- A memory-only container, created empty on first request and never written.
-- @author dop42
-- @param kind string
-- @param owner string
-- @param slots integer
-- @param maxWeight integer
-- @return table
function Containers.Transient(kind, owner, slots, maxWeight)
	owner = tostring(owner)
	local id = byIdentity[identityOf(kind, owner)]
	if id and loaded[id] then return loaded[id] end
	transientSequence = transientSequence - 1
	return register({
		id = transientSequence,
		kind = kind,
		owner = owner,
		slots = slots,
		maxWeight = maxWeight,
		items = {},
		transient = true,
	})
end

--- A loaded container by id, or nil.
-- @author dop42
-- @param id integer|nil
-- @return table|nil
function Containers.Get(id)
	return id and loaded[id] or nil
end

--- A loaded container by kind and owner, or nil.
-- @author dop42
-- @param kind string
-- @param owner string
-- @return table|nil
function Containers.Find(kind, owner)
	local id = byIdentity[identityOf(kind, tostring(owner))]
	return id and loaded[id] or nil
end

--- The LIVE table of every loaded container. A caller copies its keys before
--- anything that yields.
-- @author dop42
-- @return table<integer, table>
function Containers.All()
	return loaded
end

-- ── slots held by a use in progress ──────────────────────────────────────────
--
-- A USE HANDLER YIELDS, and the units it is about to consume sat in a slot the
-- player could still drag, split, swap, hand over or drop while it ran -- or
-- use a second time. The handler applied its effect, the consume afterwards
-- found the stack gone, and the effect was free. While a slot is held, nothing
-- may MOVE its stack (`Move`, `Split`, `Sort`) and `Remove`, which takes by name
-- from wherever it finds the item, never takes from a held slot. `TakeFromSlot`
-- is still allowed: it names the slot itself, and a handler consuming its own
-- stack (the currency deposit) is the one caller that has to.

--- Holds one slot of a container for a use in progress. False when it is held.
-- @author dop42
-- @param container table
-- @param slot integer
-- @return boolean
function Containers.Hold(container, slot)
	container.held = container.held or {}
	if container.held[slot] then return false end
	container.held[slot] = true
	return true
end

--- Releases a slot held by `Hold`.
-- @author dop42
-- @param container table
-- @param slot integer
function Containers.Release(container, slot)
	if container.held == nil then return end
	container.held[slot] = nil
	if next(container.held) == nil then container.held = nil end
end

--- Whether a slot of a container is held by a use in progress.
-- @author dop42
-- @param container table|nil
-- @param slot any
-- @return boolean
function Containers.IsHeld(container, slot)
	return container ~= nil and container.held ~= nil and slot ~= nil and
		container.held[slot] == true
end

local isHeld = Containers.IsHeld

--- The grams a container holds.
-- @author dop42
-- @param container table
-- @return integer
function Containers.Weight(container)
	local total = 0
	for _, entry in pairs(container.items) do
		total = total + Catalog.WeightOf(entry.name, entry.count)
	end
	return total
end

--- How many units of an item one slot holds.
--
-- AMMUNITION STACKS TO ITS BOX. `AMMO.MAX` in `data/weapons.lua` is how many
-- rounds fit in one box -- five hundred for a handgun -- and the catalogue read
-- it into `entry.ammo.max`, where nothing read it: a slot of rounds held up to
-- MAX_STACK like any other stack. It is that slot's ceiling now, never above
-- MAX_STACK.
-- @author dop42
-- @param name string
-- @return integer
function Containers.StackLimit(name)
	local entry = Catalog.Get(name)
	if entry and entry.stackable then
		local box = type(entry.ammo) == 'table' and entry.ammo.max or nil
		if type(box) == 'number' and box >= 1 and box < Options.MAX_STACK then return box end
		return Options.MAX_STACK
	end
	return 1
end

local stackLimit = Containers.StackLimit

--- Whether units of an item stack onto a slot.
local function stacksWith(slot, name, metadata)
	if not slot or slot.name ~= name then return false end
	if stackLimit(name) <= 1 then return false end
	return Common.SameMetadata(slot.metadata, metadata)
end

--- Whether a weight change keeps a container under its limit.
local function fitsWeight(container, delta)
	if delta <= 0 then return true end
	return Containers.Weight(container) + delta <= container.maxWeight
end

--- Counts an item's units, optionally only in stacks whose metadata matches.
-- @author dop42
-- @param container table|nil
-- @param name string
-- @param metadata table|nil nil matches any stack
-- @return integer
function Containers.CountIn(container, name, metadata)
	if not container then return 0 end
	local total = 0
	for _, entry in pairs(container.items) do
		if entry.name == name and
			(metadata == nil or Common.SameMetadata(entry.metadata, metadata)) then
			total = total + entry.count
		end
	end
	return total
end

--- Counts the units of an item whose metadata CARRIES every field of `match`.
-- `CountIn` asks "the same stack", which is whole-table equality and the right
-- question for a merge. A key asks a narrower one -- "any key whose plate is
-- this" -- and a key whose label was written differently (another language, a
-- model renamed in the catalogue) is still the key to that car. Only scalar
-- fields are compared: a table in `match` never matches, rather than matching
-- by reference and answering nothing for a reason nobody could read.
-- @author dop42
-- @param container table|nil
-- @param name string
-- @param match table field -> string|number|boolean
-- @return integer
function Containers.CountWhere(container, name, match)
	if not container or type(match) ~= 'table' or next(match) == nil then return 0 end
	for _, value in pairs(match) do
		if type(value) == 'table' then return 0 end
	end
	local total = 0
	for _, entry in pairs(container.items) do
		local metadata = entry.metadata
		if entry.name == name and type(metadata) == 'table' then
			local carries = true
			for key, value in pairs(match) do
				if metadata[key] ~= value then carries = false break end
			end
			if carries then total = total + entry.count end
		end
	end
	return total
end

--- Whether free and stackable slots take the units, weight aside.
local function hasRoom(container, name, count, metadata)
	local limit = stackLimit(name)
	local room = 0
	for slot = 1, container.slots do
		local current = container.items[slot]
		if not current then
			room = room + limit
		elseif stacksWith(current, name, metadata) then
			room = room + math.max(0, limit - current.count)
		end
		if room >= count then return true end
	end
	return false
end

--- Whether a container takes the units, by slots and by weight.
-- Both limits are re-derived here, server-side, whatever the client believes.
-- @author dop42
-- @param container table|nil
-- @param name string
-- @param count any
-- @param metadata table|nil
-- @return boolean
-- @return string|nil
function Containers.CanCarry(container, name, count, metadata)
	if not container then return false, 'not_found' end
	count = Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return false, 'bad_count' end
	if not fitsWeight(container, Catalog.WeightOf(name, count)) then return false, 'too_heavy' end
	if not hasRoom(container, name, count, metadata) then return false, 'no_room' end
	return true, nil
end

-- ── what a screen receives ───────────────────────────────────────────────────

-- Metadata keys a screen actually draws. When a payload will not fit, everything
-- else goes first.
local SHOWN = { serial = true, ammo = true, durability = true, label = true, description = true }

-- Most JSON values one pushed container may carry. A net event carries 48 KiB and
-- the client's JSON decoder 1,024 values; a container goes to 200 slots and a
-- stack is four values plus its metadata.
local VALUE_BUDGET = 900

-- Containers whose first trimmed push has been logged, so it is said once and not
-- on every push. Forgotten when the container is unloaded.
local trimLogged = {}

--- Counts the JSON values of plain data; nil counts none.
local function valuesOf(value)
	if value == nil then return 0 end
	if type(value) ~= 'table' then return 1 end
	local count = 1
	for _, item in pairs(value) do count = count + valuesOf(item) end
	return count
end

--- Builds the payload a screen draws: the slots, the stacks and the weight.
-- The catalogue is not in it: both halves load the same data files. The server
-- always keeps whole metadata; only the copy on the wire is ever trimmed.
-- @author dop42
-- @param container table
-- @return table
function Containers.Describe(container)
	local items = {}
	local weight = 0
	local values = 8
	for slot, entry in pairs(container.items) do
		items[#items + 1] = { slot = slot, name = entry.name, count = entry.count,
			metadata = entry.metadata }
		weight = weight + Catalog.WeightOf(entry.name, entry.count)
		values = values + 4 + valuesOf(entry.metadata)
	end

	local payload = {
		id = container.id,
		kind = container.kind,
		title = container.title,
		slots = container.slots,
		maxWeight = container.maxWeight,
		weight = weight,
		items = items,
	}

	local size = Common.EncodedSize(payload)
	if size ~= nil and size <= 40960 and values <= VALUE_BUDGET then return payload end

	values = 8
	for index = 1, #items do
		local metadata = items[index].metadata
		if type(metadata) == 'table' then
			local kept = {}
			for key, value in pairs(metadata) do
				if SHOWN[key] and type(value) ~= 'table' then kept[key] = value end
			end
			items[index].metadata = next(kept) and kept or nil
		end
		values = values + 4 + valuesOf(items[index].metadata)
	end
	for index = #items, 1, -1 do
		if values <= VALUE_BUDGET then break end
		values = values - valuesOf(items[index].metadata)
		items[index].metadata = nil
	end

	if not trimLogged[container.id] then
		trimLogged[container.id] = true
		Open77.log.warn(('[inventory] container %d is too heavy to push whole (%s bytes, %d ' ..
			'values); metadata trimmed'):format(container.id, tostring(size), values))
	end
	return payload
end

--- Pushes a container to everyone watching it, and a bag to its owner.
-- @author dop42
-- @param container table
function Containers.Publish(container)
	local payload
	for source, view in pairs(viewing) do
		if view.id == container.id then
			payload = payload or Containers.Describe(container)
			TriggerClientEvent(M.Event.CONTAINER, source, payload)
		end
	end
	if container.kind ~= KIND.CHARACTER then return end
	local owner = M.Players.SourceOf(container.owner)
	if not owner then return end
	TriggerClientEvent(M.Event.OWN, owner, payload or Containers.Describe(container))
end

--- Records a container open beside a player's bag, and sends it.
-- @author dop42
-- @param source Source
-- @param container table
-- @param staff boolean|nil a staff search, which reach does not close
function Containers.View(source, container, staff)
	viewing[source] = { id = container.id, staff = staff == true }
	TriggerClientEvent(M.Event.SECONDARY, source, Containers.Describe(container))
end

--- What a player has open beside their bag, or nil.
-- @author dop42
-- @param source Source
-- @return table|nil
function Containers.Viewing(source)
	return viewing[source]
end

--- Stops a player viewing their second container, telling the screen when asked.
-- @author dop42
-- @param source Source
-- @param tell boolean|nil
function Containers.CloseSecondary(source, tell)
	if not viewing[source] then return end
	viewing[source] = nil
	if tell then TriggerClientEvent(M.Event.SECONDARY, source, false) end
end

--- A snapshot of every viewer, safe to walk while closing some of them.
-- @author dop42
-- @return table[]
function Containers.Viewers()
	local list = {}
	for source, view in pairs(viewing) do
		list[#list + 1] = { source = source, id = view.id, staff = view.staff }
	end
	return list
end

--- Tells every other resource on the host that a container's contents moved.
--
-- WHICH CONTAINER, NOT WHAT IS IN IT. A bag a player is sorting changes forty
-- times a drag, and the whole of it on the bus each time would be forty copies
-- of a table only the listener that cares about it should pay for. A listener
-- that wants the contents asks the `GetInventory` / `CountItem` exports.
-- @param container table
local function announce(container)
	if container.transient and container.kind ~= KIND.CHARACTER then
		-- A pile and the boot of a car nobody owns: memory-only, numbered by a
		-- counter, and gone with their vehicle. Nothing outside can name one.
		return
	end
	local isBag = container.kind == KIND.CHARACTER
	local source = isBag and M.Players.SourceOf(container.owner) or nil
	OPX.Publish(M.Event.ON_CHANGED, source, {
		kind = container.kind,
		owner = container.owner,
		container = container.id,
		citizenId = isBag and container.owner or nil,
	})
	if not isBag then return end

	-- WHAT A BAG GAINED AND LOST, BY ITEM NAME, which is what a creator listening
	-- for "the player now has a lockpick" needs and `ON_CHANGED` never says. The
	-- bag is tallied against the tally of its last change, so a drag inside it is
	-- nothing and a give, a pickup, a craft, a use or an export call is one entry
	-- per item that moved. A walk over the bag's slots, on the server, per commit.
	local before, after = container.tally or {}, tallyOf(container)
	container.tally = after
	local changes = {}
	for name, count in pairs(after) do
		local delta = count - (before[name] or 0)
		if delta ~= 0 then changes[#changes + 1] = { name = name, delta = delta, count = count } end
	end
	for name, count in pairs(before) do
		if after[name] == nil then changes[#changes + 1] = { name = name, delta = -count, count = 0 } end
	end
	if #changes == 0 then return end
	table.sort(changes, function(a, b) return a.name < b.name end)
	OPX.Publish(M.Event.ON_ITEMS, source, {
		citizenId = container.owner,
		changes = changes,
	})
end

--- The one way out of an operation: mark, push, check the held weapon, clear an
--- emptied pile.
-- A direct call and not a hook registry: the weapons half is the only thing that
-- reacts to a change, and it is loaded before any operation can run.
local function commit(first, second)
	local distinct = second ~= nil and second.id ~= first.id
	local now = OPX.Now()
	announce(first)
	if distinct then announce(second) end

	first.touchedAt = now
	if not first.transient then M.Storage.MarkDirty(first.id) end
	Containers.Publish(first)
	if distinct then
		second.touchedAt = now
		if not second.transient then M.Storage.MarkDirty(second.id) end
		Containers.Publish(second)
	end

	if first.kind == KIND.CHARACTER then M.Weapons.CheckHeld(first) end
	if distinct and second.kind == KIND.CHARACTER then M.Weapons.CheckHeld(second) end

	M.World.CheckEmptyDrop(first)
	if distinct then M.World.CheckEmptyDrop(second) end
end

--- Places units onto matching stacks first, then into free slots.
local function insert(container, name, count, metadata)
	local limit = stackLimit(name)
	local remaining = count
	if limit > 1 then
		for slot = 1, container.slots do
			if remaining <= 0 then break end
			local current = container.items[slot]
			if stacksWith(current, name, metadata) then
				local moved = math.min(limit - current.count, remaining)
				if moved > 0 then
					current.count = current.count + moved
					remaining = remaining - moved
				end
			end
		end
	end
	for slot = 1, container.slots do
		if remaining <= 0 then break end
		if not container.items[slot] then
			local moved = math.min(limit, remaining)
			container.items[slot] = { name = name, count = moved, metadata = Common.Copy(metadata) }
			remaining = remaining - moved
		end
	end
end

--- A weapon serial: two letters and eight hexadecimal digits.
-- Enough to tell two copies of one weapon apart. It is not a secret and nothing
-- is authorised by it.
-- @author dop42
-- @return string
function Containers.NewSerial()
	serialSequence = serialSequence + 1
	local letters = string.char(65 + math.random(0, 25), 65 + math.random(0, 25))
	return ('%s%04X%04X'):format(letters, (OPX.Now() // 1000) % 65536,
		(serialSequence * 7919 + math.random(0, 4095)) % 65536)
end

--- Adds catalogue items; a weapon goes in one unit per slot, each with a serial
--- and zero rounds.
-- @author dop42
-- @param container table|nil
-- @param name string
-- @param count any
-- @param metadata table|nil
-- @return boolean
-- @return string|nil
function Containers.Add(container, name, count, metadata)
	if not container then return false, 'not_found' end
	local entry = Catalog.Get(name)
	if not entry then return false, 'unknown_item' end
	count = Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return false, 'bad_count' end
	local carried, reason = Containers.CanCarry(container, name, count, metadata)
	if not carried then return false, reason end

	if entry.weapon then
		for _ = 1, count do
			local copy = Common.Copy(metadata) or {}
			-- A caller may name the serial of ONE weapon it is putting back; more
			-- than one would give several copies the same serial.
			copy.serial = (count == 1 and type(copy.serial) == 'string' and copy.serial ~= '')
				and copy.serial or Containers.NewSerial()
			copy.ammo = Common.Integer(copy.ammo, 0, 100000) or 0
			insert(container, name, 1, copy)
		end
	else
		insert(container, name, count, metadata)
	end
	commit(container)
	return true, nil
end

--- Removes units from the last slot backwards; nil metadata matches any stack.
-- @author dop42
-- @param container table|nil
-- @param name string
-- @param count any
-- @param metadata table|nil
-- @return boolean
-- @return string|nil
function Containers.Remove(container, name, count, metadata)
	if not container then return false, 'not_found' end
	count = Common.Integer(count, 1, Options.MAX_STACK)
	if not count then return false, 'bad_count' end
	-- Only units that are not held by a use in progress can be taken by name.
	local available = 0
	for slot, entry in pairs(container.items) do
		if not isHeld(container, slot) and entry.name == name and
			(metadata == nil or Common.SameMetadata(entry.metadata, metadata)) then
			available = available + entry.count
		end
	end
	if available < count then return false, 'not_enough' end

	local remaining = count
	-- A stack may sit beyond the current slot count -- a container that was
	-- resized smaller keeps what was already in it -- so the walk starts at the
	-- highest occupied slot, not at `container.slots`.
	local last = container.slots
	for slot in pairs(container.items) do
		if slot > last then last = slot end
	end
	for slot = last, 1, -1 do
		if remaining <= 0 then break end
		local current = container.items[slot]
		if current and not isHeld(container, slot) and current.name == name and
			(metadata == nil or Common.SameMetadata(current.metadata, metadata)) then
			local taken = math.min(current.count, remaining)
			current.count = current.count - taken
			remaining = remaining - taken
			if current.count <= 0 then container.items[slot] = nil end
		end
	end
	commit(container)
	return true, nil
end

--- Empties a container.
-- @author dop42
-- @param container table|nil
-- @return boolean
-- @return string|nil
function Containers.Clear(container)
	if not container then return false, 'not_found' end
	container.items = {}
	commit(container)
	return true, nil
end

--- Takes units out of one precise slot, never a look-alike somewhere else.
-- @author dop42
-- @param container table|nil
-- @param slot integer
-- @param count any
-- @return boolean
-- @return string|nil
function Containers.TakeFromSlot(container, slot, count)
	if not container then return false, 'not_found' end
	local entry = container.items[slot]
	if not entry then return false, 'empty_slot' end
	count = Common.Integer(count, 1, entry.count)
	if not count then return false, 'bad_count' end
	entry.count = entry.count - count
	if entry.count <= 0 then container.items[slot] = nil end
	commit(container)
	return true, nil
end

--- The stack in one slot, or nil.
-- @author dop42
-- @param container table|nil
-- @param slot integer
-- @return table|nil
function Containers.GetSlot(container, slot)
	return container and container.items[slot] or nil
end

--- Replaces the metadata of one stack.
-- @author dop42
-- @param container table|nil
-- @param slot integer
-- @param metadata table|nil
-- @return boolean
-- @return string|nil
function Containers.SetMetadata(container, slot, metadata)
	local entry = Containers.GetSlot(container, slot)
	if not entry then return false, 'empty_slot' end
	entry.metadata = Common.Copy(metadata)
	commit(container)
	return true, nil
end

--- Moves, stacks or swaps a slot, within one container or across two.
-- A nil `toSlot` places the units wherever they fit; a nil `count` moves the whole
-- stack; a swap moves whole stacks only, because half a stack has nowhere to go
-- back to.
-- @author dop42
-- @param from table|nil
-- @param fromSlot integer
-- @param to table|nil
-- @param toSlot integer|nil
-- @param count integer|nil
-- @return boolean
-- @return string|nil
function Containers.Move(from, fromSlot, to, toSlot, count)
	if not from or not to then return false, 'not_found' end
	local source = from.items[fromSlot]
	if not source then return false, 'empty_slot' end
	-- A stack a use is consuming stays where it is, and nothing is swapped or
	-- stacked into its place (see `Hold`).
	if isHeld(from, fromSlot) then return false, 'in_use' end
	if toSlot ~= nil and isHeld(to, Common.Integer(toSlot, 1, to.slots)) then
		return false, 'in_use'
	end
	-- A drawn weapon leaves the bag only once its rounds have been read back
	-- (see `Weapons.BeforeLeave`).
	if to.id ~= from.id then
		local refusal = M.Weapons.BeforeLeave(from, source)
		if refusal then return false, refusal end
	end

	-- WHAT MAY NOT BE LEFT ON THE FLOOR MAY NOT BE LEFT ANYWHERE THAT IS NEVER
	-- WRITTEN, and until this line the rule only covered the floor. `DROP = false`
	-- was checked in `Actions.Drop` and nowhere else, so the whole of it could be
	-- walked around: withdraw eddies, open the boot of any vehicle this resource
	-- did not spawn -- ambient traffic, an admin `/car`, anything with no plate in
	-- `live`, which also skips the owner check because `ownerCitizenId` is nil --
	-- and move the stack in. That container is transient. Nothing marks it dirty,
	-- nothing ever writes it, and `SweepVehicles` discards it five seconds after
	-- the vehicle goes. A balance deleted, with no row and nothing for staff to
	-- settle from: exactly the hazard `data/items.lua` names for a ground pile and
	-- closes there.
	--
	-- CHECKED AT THIS LAYER AND NOT AT THE DOOR, because `transient` is what the
	-- rule is actually about -- a pile and a plateless boot are the same promise,
	-- "this is memory and it is going away" -- and a third memory-only container
	-- added later is covered the day it is written rather than the day somebody
	-- remembers. It reads the SOURCE stack's name because that is what crosses:
	-- on the swap branch a stack moves each way, and only the one leaving `from`
	-- is entering something that will not keep it.
	if to.transient and to.id ~= from.id then
		local item = Catalog.Get(source.name)
		if item and item.droppable == false then return false, 'no_drop' end
	end

	if count == nil then
		count = source.count
	else
		count = Common.Integer(count, 1, Options.MAX_STACK)
		if not count then return false, 'bad_count' end
		if count > source.count then count = source.count end
	end
	local same = from.id == to.id

	if toSlot == nil then
		if same then return false, 'bad_slot' end
		if not fitsWeight(to, Catalog.WeightOf(source.name, count)) then return false, 'too_heavy' end
		if not hasRoom(to, source.name, count, source.metadata) then return false, 'no_room' end
		insert(to, source.name, count, source.metadata)
		source.count = source.count - count
		if source.count <= 0 then from.items[fromSlot] = nil end
		commit(from, to)
		return true, nil
	end

	toSlot = Common.Integer(toSlot, 1, to.slots)
	if not toSlot then return false, 'bad_slot' end
	if same and fromSlot == toSlot then return true, nil end

	local target = to.items[toSlot]
	if not target then
		if not same and not fitsWeight(to, Catalog.WeightOf(source.name, count)) then
			return false, 'too_heavy'
		end
		local whole = count == source.count
		to.items[toSlot] = {
			name = source.name,
			count = count,
			-- A whole stack hands its metadata over; a part must not share the
			-- table, or a later edit of one would change the other.
			metadata = whole and source.metadata or Common.Copy(source.metadata),
		}
		source.count = source.count - count
		if source.count <= 0 then from.items[fromSlot] = nil end
	elseif stacksWith(target, source.name, source.metadata) then
		local moved = math.min(stackLimit(source.name) - target.count, count)
		if moved <= 0 then return false, 'no_room' end
		if not same and not fitsWeight(to, Catalog.WeightOf(source.name, moved)) then
			return false, 'too_heavy'
		end
		target.count = target.count + moved
		source.count = source.count - moved
		if source.count <= 0 then from.items[fromSlot] = nil end
	else
		if count ~= source.count then return false, 'cannot_swap' end
		if not same then
			-- A swap moves weight both ways, and both containers have to hold the
			-- result: checking only the destination lets an overweight stack be
			-- parked in the lighter one.
			local incoming = Catalog.WeightOf(source.name, source.count)
			local outgoing = Catalog.WeightOf(target.name, target.count)
			if not fitsWeight(to, incoming - outgoing) then return false, 'too_heavy' end
			if not fitsWeight(from, outgoing - incoming) then return false, 'too_heavy' end
		end
		from.items[fromSlot] = target
		to.items[toSlot] = source
	end

	commit(from, to)
	return true, nil
end

--- Splits part of a stack into the first free slot.
-- @author dop42
-- @param container table|nil
-- @param slot integer
-- @param count any
-- @return boolean
-- @return string|nil
function Containers.Split(container, slot, count)
	if not container then return false, 'not_found' end
	local source = container.items[slot]
	if not source then return false, 'empty_slot' end
	if isHeld(container, slot) then return false, 'in_use' end
	-- At most one less than the stack: splitting all of it is a move, and would
	-- otherwise leave an empty stack behind.
	count = Common.Integer(count, 1, source.count - 1)
	if not count then return false, 'bad_count' end
	for free = 1, container.slots do
		if not container.items[free] then
			container.items[free] = { name = source.name, count = count,
				metadata = Common.Copy(source.metadata) }
			source.count = source.count - count
			commit(container)
			return true, nil
		end
	end
	return false, 'no_room'
end

--- Packs a container from slot one, by weight or by label.
-- @author dop42
-- @param container table|nil
-- @param mode string weight or name
-- @return boolean
-- @return string|nil
function Containers.Sort(container, mode)
	if not container then return false, 'not_found' end
	if mode ~= 'weight' and mode ~= 'name' then return false, 'bad_request' end
	-- Sorting moves every stack, a held one with the rest.
	if container.held ~= nil then return false, 'in_use' end
	local entries = {}
	for slot, entry in pairs(container.items) do
		entries[#entries + 1] = {
			entry = entry,
			slot = slot,
			weight = Catalog.WeightOf(entry.name, entry.count),
			label = Catalog.Label(entry.name):lower(),
		}
	end
	-- The slot is the last tiebreak, so two sorts of one container agree: `pairs`
	-- has no order and a comparison that can answer neither way raises in Lua 5.4.
	table.sort(entries, function(a, b)
		if mode == 'weight' and a.weight ~= b.weight then return a.weight > b.weight end
		if a.label ~= b.label then return a.label < b.label end
		if a.entry.count ~= b.entry.count then return a.entry.count > b.entry.count end
		return a.slot < b.slot
	end)
	local sorted = {}
	for index = 1, #entries do sorted[index] = entries[index].entry end
	container.items = sorted
	commit(container)
	return true, nil
end

--- Closes a container for its viewers and forgets it, writing nothing.
-- It does not yield, which is why a pile that vanishes and a recycled vehicle's
-- storage call this and not `Unload`: both run inside a guarded sweep, and a
-- guarded slice runs under `pcall`, which a yield must not cross.
-- @author dop42
-- @param id integer
-- @param written boolean|nil true when the caller has just written this
--   container and verified it clean, so nothing is being lost
function Containers.Discard(id, written)
	local container = loaded[id]
	if not container then return end

	-- WHAT WENT WITH IT, SAID OUT LOUD. This is the one place in the module where
	-- items cease to exist, and it used to do it in complete silence: no audit
	-- line, no log line, not even the `log.warn` in `Unload` -- that one sits
	-- inside the branch a transient skips. A pile sweeping itself up is ordinary
	-- and expected; a boot full of somebody's things going with a despawned car
	-- is the same code path, and staff asking "where did it go" had nothing at
	-- all to read. Only when there is something to say: `CheckEmptyDrop` discards
	-- emptied piles constantly, and a line per empty pile is a journal nobody
	-- reads and therefore a journal that hides this one.
	local carried, kinds = 0, {}
	for _, stack in pairs(container.items) do
		carried = carried + 1
		kinds[#kinds + 1] = ('%s x%d'):format(tostring(stack.name), tonumber(stack.count) or 0)
	end
	-- AND "DESTROYED" ONLY WHEN SOMETHING WAS. This line was written for the
	-- case it names -- a boot full of somebody's things going with a despawned
	-- car -- and `Unload` calls the same function on the ordinary path, AFTER
	-- writing the container and checking it came back clean. So every clean
	-- logout filed `character 39N-FRKJ: 2 stack(s) destroyed` at severity WARN
	-- about a sniper rifle and 351 rounds that were sitting safely in the
	-- database, and staff reading the journal would have gone looking for a loss
	-- that never happened. A line that cries wolf costs more than no line: the
	-- one it hides is the real one.
	--
	-- The caller knows which it is, because the caller is the one that either
	-- wrote or did not.
	if carried > 0 then
		table.sort(kinds)
		local saved = written == true
		OPX.Audit.Log({
			event = saved and 'inventory.unloaded' or 'inventory.discarded',
			severity = saved and 'info' or 'warn',
			message = ('%s %s: %d stack(s) %s'):format(tostring(container.kind),
				tostring(container.owner), carried,
				saved and 'written and unloaded' or 'destroyed'),
			data = { kind = container.kind, owner = container.owner,
				transient = container.transient == true, items = table.concat(kinds, ', ') } })
	end

	container.unloadWhenClean = nil
	for _, view in ipairs(Containers.Viewers()) do
		if view.id == id then Containers.CloseSecondary(view.source, true) end
	end
	loaded[id] = nil
	trimLogged[id] = nil
	local identity = identityOf(container.kind, container.owner)
	if byIdentity[identity] == id then byIdentity[identity] = nil end
	M.Storage.Forget(id)
end

--- Writes a container until it is clean, closes its viewers, and forgets it.
-- Yields. A container that could not be written is kept in memory and marked, so
-- the sweep keeps trying and the write that finally succeeds unloads it: letting
-- it go now would lose everything not yet written.
-- @author dop42
-- @param id integer
function Containers.Unload(id)
	local container = loaded[id]
	if not container then return end
	if not container.transient then
		local clean = M.Storage.SaveUntilClean(container)
		-- The write yielded: if the container was replaced meanwhile, it is no
		-- longer this call's to forget.
		if loaded[id] ~= container then return end
		if not clean then
			container.unloadWhenClean = true
			Open77.log.warn(('[inventory] container %d could not be written; kept in memory ' ..
				'until it is'):format(id))
			return
		end
	end
	-- Written and verified clean above, so nothing is being lost and the audit
	-- line must not say it is. A transient reaches here having written nothing,
	-- which is what `transient` means, and keeps the loud line.
	Containers.Discard(id, not container.transient)
end

--- Puts away the stashes another resource loaded by name and then left alone.
-- @author dop42
--
-- A stash the creator exports reach is LOADED, NEVER OPENED (see
-- `main.lua`, `withStash`), so nothing else would ever unload it, and a caller
-- walking a thousand names would hold a thousand containers for the life of the
-- resource. A stash a player opened (`World.Stash`) is marked the same way. One
-- marked `external` and untouched for `idleMs` is written and unloaded, unless
-- somebody has it open; it loads again on the next call.
-- Yields: an unload writes first.
-- @param idleMs integer
-- @return integer how many were unloaded
function Containers.SweepExternal(idleMs)
	local now = OPX.Now()
	local open = {}
	for _, view in pairs(viewing) do open[view.id] = true end
	local due = {}
	for id, container in pairs(loaded) do
		-- An open one is in use, and its idle time starts again when it closes.
		if container.external and open[id] then container.externalAt = now end
		if container.external and not open[id]
			and now - (container.externalAt or 0) >= idleMs then
			due[#due + 1] = id
		end
	end
	local unloaded = 0
	for index = 1, #due do
		local container = loaded[due[index]]
		-- Re-read after every unload, which yields: a stash touched or opened
		-- meanwhile stays.
		if container and container.external and not Containers.IsViewed(due[index])
			and OPX.Now() - (container.externalAt or 0) >= idleMs then
			Containers.Unload(due[index])
			if loaded[due[index]] == nil then unloaded = unloaded + 1 end
		end
	end
	return unloaded
end

--- Whether any player has a container open.
-- @author dop42
-- @param id integer
-- @return boolean
function Containers.IsViewed(id)
	for _, view in pairs(viewing) do
		if view.id == id then return true end
	end
	return false
end
