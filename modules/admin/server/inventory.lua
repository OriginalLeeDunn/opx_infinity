--- The bridge to the `inventory` contract, and the staff bag commands.
-- @author dop42
--
-- What used to be three levels of export call -- dispatch, promise, answer -- is
-- a function call inside one Lua state, so this file is mostly the translation
-- between the contract's refusal codes and the ones a staff member reads.
--
-- WHAT THE CONTRACT DOES NOT SAY. An item view carries `weapon = true` and
-- `ammo = true`, and nothing about a weapon's class, the ammunition item it
-- loads, or an ammunition item's full load. `server/weapons.lua` works around it
-- by naming ammunition by its own item; see the module header.
--
-- Every reader here yields: `GetInventory` on an offline citizen id loads that
-- bag from the database. So every command below hands the work to a
-- `CreateThread` after it has answered everything it can answer without one.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Text = OPX.Text
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit
local inform = Server.Inform

M.Inventory = {}
local Inventory = M.Inventory

-- The contract's refusal codes in this module's own words. A code that is not
-- here reads as a plain refusal and the original is kept in the audit.
local CODES = {
	bad_target = 'bad_holder',
	bad_argument = 'bad_count',
	not_loaded = 'no_character',
	not_found = 'unknown_citizen',
	no_character = 'unknown_citizen',
	unknown_item = 'unknown_item',
	bad_count = 'bad_count',
	not_enough = 'not_enough',
	no_room = 'bag_no_room',
	too_heavy = 'bag_too_heavy',
}

-- Suggestion parameters shared by the bag commands.
Inventory.HOLDER = { name = 'playerId|me|citizenId', help = 'admin.help.holder' }
local TARGET = Inventory.HOLDER
local ITEM = { name = 'item', help = 'admin.help.itemName' }
local COUNT = { name = 'count', help = 'admin.help.count', optional = true }

-- The catalogue, read once and kept: it is built at load and never changes while
-- the resource runs.
local catalog

--- Whether the inventory contract answered at start.
-- @author dop42
-- @return boolean
function Inventory.Running()
	return Server.Contract('inventory') ~= nil
end

--- The largest count a give or a removal accepts, read live from the panel.
-- @author dop42
-- @return integer
function Inventory.MaxCount()
	return math.floor(OPX.Tune.Number('ADMIN_INVENTORY_MAX_COUNT', 1))
end

--- Turns a contract `Result` into the (value, code, reason) triple this module's
--- callers read.
-- @author dop42
-- @param result table|nil
-- @return any|nil
-- @return string|nil the refusal code a player reads
-- @return string|nil the contract's own code, for the audit
function Inventory.Read(result)
	if type(result) ~= 'table' then return nil, 'inventory_unavailable', 'no_contract' end
	if result.ok ~= true then
		local code = M.Trimmed(result.error, 64) or 'refused'
		return nil, CODES[code] or 'refused', code
	end
	return result.value, nil, nil
end

--- The catalogue as a sorted list and a lookup by name.
-- @author dop42
-- @return table|nil
-- @return string|nil the refusal code
function Inventory.Catalog()
	if catalog ~= nil then return catalog end
	local contract = Server.Contract('inventory')
	if contract == nil then return nil, 'inventory_unavailable' end

	local read, views = pcall(contract.GetItems)
	if not read or type(views) ~= 'table' then return nil, 'inventory_unavailable' end

	local items, byName = {}, {}
	for name, view in pairs(views) do
		if type(name) == 'string' and type(view) == 'table' then
			local entry = {
				name = name,
				label = M.Trimmed(view.label, 48) or name,
				category = M.Trimmed(view.category, 32) or 'misc',
				weight = math.max(0, Text.Integer(view.weight) or 0),
				weapon = view.weapon == true,
				ammo = view.ammo == true,
			}
			items[#items + 1] = entry
			byName[name] = entry
		end
	end
	table.sort(items, function(left, right)
		if left.label == right.label then return left.name < right.name end
		return left.label < right.label
	end)
	catalog = { items = items, byName = byName }
	return catalog
end

--- Finds a catalogue item by its exact name, without case.
-- @author dop42
-- @param index table
-- @param token any
-- @return table|nil
function Inventory.Item(index, token)
	if type(token) ~= 'string' then return nil end
	return index.byName[token:lower()]
end

--- Finds a weapon item by name, with or without its `weapon_` prefix.
-- @author dop42
-- @param index table
-- @param token any
-- @return table|nil
function Inventory.Weapon(index, token)
	if type(token) ~= 'string' then return nil end
	local lowered = token:lower()
	local entry = index.byName[lowered] or index.byName['weapon_' .. lowered]
	if entry == nil or not entry.weapon then return nil end
	return entry
end

--- Finds an ammunition item by its exact name, without case.
-- @author dop42
-- @param index table
-- @param token any
-- @return table|nil
function Inventory.Ammo(index, token)
	local entry = Inventory.Item(index, token)
	if entry == nil or not entry.ammo then return nil end
	return entry
end

--- Labels a stored item, falling back to its stored name.
-- @author dop42
-- @param index table|nil
-- @param name string
-- @return string
function Inventory.LabelOf(index, name)
	local entry = index and index.byName[name]
	return entry and entry.label or name
end

-- Formats a connected player as a name and an id in brackets.
local function playerLabel(playerId)
	return ('%s [%d]'):format(Server.LabelOf(playerId) or '?', playerId)
end

--- Resolves a typed holder: me, a player id, or a citizen id online or not.
-- @author dop42
-- @param source Source
-- @param token any
-- @return integer|string|nil the target the contract takes
-- @return string|nil how the answer names them
-- @return integer|nil the connected player id, when there is one
-- @return string|nil the refusal code
function Inventory.Target(source, token)
	if token == nil then return nil, nil, nil, 'no_target' end
	local word = tostring(token)
	local lowered = word:lower()
	if lowered == 'me' or lowered == 'self' then
		if source <= 0 then return nil, nil, nil, 'console_has_no_player' end
		return source, playerLabel(source), source, nil
	end
	local playerId = Text.Integer(word)
	if playerId ~= nil then
		if playerId <= 0 then return nil, nil, nil, 'bad_holder' end
		if Server.NameOf(playerId) == nil then return nil, nil, nil, 'not_connected' end
		return playerId, playerLabel(playerId), playerId, nil
	end
	if #word > 32 or not word:match('^[%w_%-]+$') then return nil, nil, nil, 'bad_holder' end

	-- A citizen id that belongs to somebody in the world is answered as that
	-- player, so the toast reaches them and the audit names the slot.
	local character = Server.Contract('character')
	if character ~= nil then
		local read, player = pcall(character.GetPlayerByCitizenId, word)
		if read and type(player) == 'table' and type(player.PlayerData) == 'table' then
			local online = Text.Integer(player.PlayerData.source)
			if online ~= nil and online > 0 then return word, playerLabel(online), online, nil end
		end
	end
	return word, word, nil, nil
end

--- Resolves a holder, answering the refusals that need no contract call.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param token any
-- @return integer|string|nil
-- @return string|nil
-- @return integer|nil
-- @param harm string|nil the audit event of an action that hurts the holder: a
-- connected holder who is protected is refused (see `Server.Protected`)
function Inventory.Resolve(source, raw, token, harm)
	local target, who, playerId, code = Inventory.Target(source, token)
	if target == nil then
		refuse(source, raw, code)
		return nil
	end
	if harm ~= nil and playerId ~= nil and Server.Shielded(source, raw, playerId, harm) then
		return nil
	end
	if not Inventory.Running() then
		refuse(source, raw, 'inventory_unavailable')
		return nil
	end
	return target, who, playerId
end

--- Parses a typed count: nil when omitted, false outside `least`..the maximum.
-- @author dop42
-- @param token any
-- @param least integer zero where zero means none, one elsewhere
-- @return integer|false|nil
function Inventory.Count(token, least)
	if token == nil then return nil end
	local value = Text.Integer(token)
	if value == nil or value < least or value > Inventory.MaxCount() then return false end
	return value
end

--- Reads every stack of a bag. Yields.
-- @author dop42
-- @param target integer|string
-- @return table|nil
-- @return string|nil the refusal code
-- @return string|nil the contract's own code
function Inventory.Bag(target)
	local contract = Server.Contract('inventory')
	if contract == nil then return nil, 'inventory_unavailable', 'no_contract' end
	local bag, code, reason = Inventory.Read(contract.GetInventory(target))
	if bag == nil then return nil, code, reason end
	local items = {}
	for _, row in ipairs(type(bag.items) == 'table' and bag.items or {}) do
		local slot, name = Text.Integer(row.slot), M.Trimmed(row.name, 48)
		if slot and name then
			items[#items + 1] = { slot = slot, name = name, count = Text.Integer(row.count) or 0,
				metadata = type(row.metadata) == 'table' and row.metadata or nil }
		end
	end
	table.sort(items, function(left, right) return left.slot < right.slot end)
	return {
		title = M.Trimmed(bag.title, 48) or '?',
		slots = Text.Integer(bag.slots) or 0,
		maxWeight = Text.Integer(bag.maxWeight) or 0,
		weight = Text.Integer(bag.weight) or 0,
		items = items,
	}, nil, nil
end

-- WHICH WEAPON GRANT A BAG ACTION ALSO NEEDS. The bag commands move whatever
-- the catalogue holds, and the catalogue holds the weapons and their rounds:
-- `inventory.give pistol` handed out a gun to an operator refused
-- `weapon.give`, and `inventory.clear` disarmed a player for one refused
-- `weapon.remove`. A weapon or ammunition item now needs the weapon command
-- that does the same thing, on top of the bag command.
local WEAPON_GRANTS = {
	give = { weapon = 'WEAPON_GIVE', ammo = 'WEAPON_GIVEAMMO' },
	take = { weapon = 'WEAPON_REMOVE', ammo = 'WEAPON_AMMO' },
}

--- Whether the operator holds the weapon grant a bag action on this item also
--- needs, refusing and auditing when not. A plain item needs none.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param event string
-- @param playerId Source|nil
-- @param item table|nil a catalogue entry
-- @param action string 'give' or 'take'
-- @return boolean
function Inventory.WeaponGrant(source, raw, event, playerId, item, action)
	if type(item) ~= 'table' or (not item.weapon and not item.ammo) then return true end
	local name = Command[WEAPON_GRANTS[action][item.weapon and 'weapon' or 'ammo']]
	if Server.Permitted(source, name) == true then return true end
	audit(source, event, false, playerId, ('%s needs %s'):format(tostring(item.name), name))
	refuse(source, raw, 'weapon_not_granted',
		{ item = tostring(item.label or item.name), command = name })
	return false
end

--- Audits a refused bag action and answers the refusal.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param event string
-- @param playerId Source|nil
-- @param who string|nil
-- @param code string
-- @param reason string|nil
-- @param params table|nil
function Inventory.Fail(source, raw, event, playerId, who, code, reason, params)
	audit(source, event, false, playerId, ('%s: %s'):format(who or '-', tostring(reason or code)))
	params = params or {}
	params.who = params.who or who or '?'
	params.reason = reason
	params.max = params.max or Inventory.MaxCount()
	refuse(source, raw, code, params)
end

--- Whether the bag would take those units. Yields.
-- @author dop42
-- @param target integer|string
-- @param name string
-- @param count integer
-- @param metadata table|nil
-- @return boolean
-- @return string|nil
-- @return string|nil
function Inventory.Carry(target, name, count, metadata)
	local contract = Server.Contract('inventory')
	if contract == nil then return false, 'inventory_unavailable', 'no_contract' end
	local carried, code, reason = Inventory.Read(contract.CanCarry(target, name, count, metadata))
	if carried == nil then return false, code, reason end
	if carried ~= true then return false, 'bag_no_room', 'no_room' end
	return true, nil, nil
end

--- `CanCarry` then `AddItem`, without answering anything. Yields.
-- @author dop42
-- @param target integer|string
-- @param name string
-- @param count integer
-- @param metadata table|nil
-- @return boolean
-- @return string|nil
-- @return string|nil
function Inventory.Add(target, name, count, metadata)
	local carried, code, reason = Inventory.Carry(target, name, count, metadata)
	if not carried then return false, code, reason end
	local contract = Server.Contract('inventory')
	local added, addCode, addReason = Inventory.Read(contract.AddItem(target, name, count, metadata))
	if added == nil then return false, addCode, addReason end
	return true, nil, nil
end

--- Takes units out of a bag. Yields.
-- @author dop42
-- @param target integer|string
-- @param name string
-- @param count integer
-- @param metadata table|nil
-- @return boolean
-- @return string|nil
-- @return string|nil
function Inventory.Take(target, name, count, metadata)
	local contract = Server.Contract('inventory')
	if contract == nil then return false, 'inventory_unavailable', 'no_contract' end
	local taken, code, reason = Inventory.Read(contract.RemoveItem(target, name, count, metadata))
	if taken == nil then return false, code, reason end
	return true, nil, nil
end

--- Adds items to a bag, answering and auditing a refusal. Yields.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param event string
-- @param target integer|string
-- @param who string
-- @param playerId Source|nil
-- @param name string
-- @param count integer
-- @param metadata table|nil
-- @param label string
-- @return boolean
function Inventory.Give(source, raw, event, target, who, playerId, name, count, metadata, label)
	local added, code, reason = Inventory.Add(target, name, count, metadata)
	if not added then
		Inventory.Fail(source, raw, event, playerId, who, code, reason, { item = label })
		return false
	end
	return true
end

-- Formats a stack's rounds and serial for a report row.
local function extraOf(metadata)
	if type(metadata) ~= 'table' then return '' end
	local parts = {}
	local ammo = Text.Integer(metadata.ammo)
	if ammo then parts[#parts + 1] = locale('admin.inventory.rounds', { rounds = ammo }) end
	local serial = M.Trimmed(metadata.serial, 24)
	if serial then parts[#parts + 1] = '#' .. serial end
	return #parts > 0 and ('  ' .. table.concat(parts, '  ')) or ''
end

-- Formats grams as kilograms with one decimal.
local function kilograms(grams)
	return ('%.1f'):format(grams / 1000)
end

--- Registers the four bag commands.
-- @author dop42
function Inventory.Register()
	Server.Command(Command.INVENTORY_VIEW, {
		help = 'admin.help.invView', params = { TARGET }, read = true,
		handler = function(source, args, raw)
			local target, who, playerId = Inventory.Resolve(source, raw, args[1])
			if target == nil then return end
			Server.Heavy(source, raw, function()
				local bag, code, reason = Inventory.Bag(target)
				if not bag then
					return Inventory.Fail(source, raw, 'admin.inventory.view', playerId, who, code, reason)
				end
				local index = Inventory.Catalog()
				local lines = { locale('admin.inventory.header', {
					who = who, title = bag.title, used = #bag.items, slots = bag.slots,
					weight = kilograms(bag.weight), maxWeight = kilograms(bag.maxWeight),
				}) }
				for _, row in ipairs(bag.items) do
					lines[#lines + 1] = locale('admin.inventory.row', {
						slot = row.slot, label = Inventory.LabelOf(index, row.name), name = row.name,
						count = row.count, extra = extraOf(row.metadata),
					})
				end
				if #bag.items == 0 then lines[#lines + 1] = locale('admin.inventory.empty') end
				audit(source, 'admin.inventory.view', true, playerId, bag.title)
				answer(source, raw, true, 'admin.text.lines', { lines = table.concat(lines, '\n') })
			end)
		end,
	})

	Server.Command(Command.INVENTORY_GIVE, {
		help = 'admin.help.invGive', params = { TARGET, ITEM, COUNT },
		handler = function(source, args, raw)
			if M.Trimmed(args[2], 48) == nil then
				return refuse(source, raw, 'unknown_item', { item = '?' })
			end
			local wanted = Inventory.Count(args[3], 1)
			if wanted == false then
				return refuse(source, raw, 'bad_count', { max = Inventory.MaxCount() })
			end
			wanted = wanted or 1
			local target, who, playerId = Inventory.Resolve(source, raw, args[1])
			if target == nil then return end
			Server.Heavy(source, raw, function()
				local event = 'admin.inventory.give'
				local index, code = Inventory.Catalog()
				if not index then return Inventory.Fail(source, raw, event, playerId, who, code) end
				local item = Inventory.Item(index, args[2])
				if item == nil then
					return Inventory.Fail(source, raw, event, playerId, who, 'unknown_item',
						M.Trimmed(args[2], 48), { item = M.Trimmed(args[2], 48) })
				end
				if not Inventory.WeaponGrant(source, raw, event, playerId, item, 'give') then return end
				if not Inventory.Give(source, raw, event, target, who, playerId, item.name, wanted, nil,
					item.label) then
					return
				end
				audit(source, event, true, playerId, ('%dx %s to %s'):format(wanted, item.name, who))
				inform(source, playerId, 'admin.toast.itemGiven',
					{ count = wanted, label = item.label }, 'info')
				answer(source, raw, true, 'admin.done.itemGiven',
					{ count = wanted, label = item.label, who = who })
			end)
		end,
	})

	Server.Command(Command.INVENTORY_REMOVE, {
		help = 'admin.help.invRemove', params = { TARGET, ITEM, COUNT },
		handler = function(source, args, raw)
			local name = type(args[2]) == 'string' and args[2]:lower() or nil
			if name == nil or #name > 48 or not name:match('^[%w_%-%.]+$') then
				return refuse(source, raw, 'unknown_item', { item = M.Trimmed(args[2], 48) or '?' })
			end
			local wanted = Inventory.Count(args[3], 1)
			if wanted == false then
				return refuse(source, raw, 'bad_count', { max = Inventory.MaxCount() })
			end
			wanted = wanted or 1
			local target, who, playerId = Inventory.Resolve(source, raw, args[1], 'admin.inventory.remove')
			if target == nil then return end
			Server.Heavy(source, raw, function()
				local event = 'admin.inventory.remove'
				local index = Inventory.Catalog()
				local item = index and Inventory.Item(index, name) or nil
				if not Inventory.WeaponGrant(source, raw, event, playerId, item, 'take') then return end
				local label = Inventory.LabelOf(index, name)
				local removed, code, reason = Inventory.Take(target, name, wanted)
				if not removed then
					return Inventory.Fail(source, raw, event, playerId, who, code, reason,
						{ item = label, count = wanted })
				end
				audit(source, event, true, playerId, ('%dx %s from %s'):format(wanted, name, who))
				inform(source, playerId, 'admin.toast.itemTaken',
					{ count = wanted, label = label }, 'warning')
				answer(source, raw, true, 'admin.done.itemRemoved',
					{ count = wanted, label = label, who = who })
			end)
		end,
	})

	Server.Command(Command.INVENTORY_CLEAR, {
		help = 'admin.help.invClear', params = { TARGET },
		handler = function(source, args, raw)
			local target, who, playerId = Inventory.Resolve(source, raw, args[1], 'admin.inventory.clear')
			if target == nil then return end
			Server.Heavy(source, raw, function()
				local event = 'admin.inventory.clear'
				-- A clear takes everything, so every weapon and round in the bag is
				-- checked against its grant first. A bag that cannot be read is not
				-- cleared: what it holds is exactly what this cannot vouch for.
				local bag, readCode, readReason = Inventory.Bag(target)
				if bag == nil then
					return Inventory.Fail(source, raw, event, playerId, who, readCode, readReason)
				end
				local index = Inventory.Catalog()
				for _, stack in ipairs(bag.items) do
					local item = index and Inventory.Item(index, stack.name) or nil
					if not Inventory.WeaponGrant(source, raw, event, playerId, item, 'take') then return end
				end
				local contract = Server.Contract('inventory')
				local cleared, code, reason = Inventory.Read(contract.ClearInventory(target))
				if cleared == nil then
					return Inventory.Fail(source, raw, event, playerId, who, code, reason)
				end
				audit(source, event, true, playerId, who)
				inform(source, playerId, 'admin.toast.bagCleared', nil, 'warning')
				answer(source, raw, true, 'admin.done.bagCleared', { who = who })
			end)
		end,
	})
end
