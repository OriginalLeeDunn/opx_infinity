--- Weapon and ammunition commands through the `inventory` contract.
-- @author dop42
--
-- WHAT CHANGED AND WHY. The resource this came from asked the inventory which
-- ammunition item each weapon loads and how large a full load was, so
-- `weapon.give <holder> <weapon> <count>` could put the right rounds in beside
-- the gun and `weapon.ammo` could top up exactly what the bag's weapons take.
-- The `inventory` contract's item view carries `weapon = true` and `ammo = true`
-- and nothing else, so ammunition is now NAMED BY ITS OWN ITEM:
--
--   weapon.give     <holder> <weapon> [ammoItem] [count]
--   weapon.giveammo <holder> <ammoItem> [count]
--   weapon.ammo     <holder> [ammoItem|all] [count]   -- tops up what is carried
--
-- Adding `class`, `ammoName` and `ammoMax` to `Catalog.ViewOf` in the inventory
-- module would restore the original three shapes unchanged.
--
-- `weapon.holster` puts the target's drawn weapon away through the contract's
-- `HolsterWeapon`. It used to refuse every time, because the contract published
-- `GetHeldWeapon` and no way to put one away -- so the staff menu's Holster row
-- and the command answered "not available" to every operator, always.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Inventory = M.Inventory
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit
local tell, inform = Server.Tell, Server.Inform

M.Weapons = {}
local Weapons = M.Weapons

local TARGET = Inventory.HOLDER

-- Collects the serials of one weapon's stacks in a bag, so that a weapon added
-- and then orphaned can be found again and taken back.
local function serialsOf(bag, name)
	local serials = {}
	for _, row in ipairs(bag.items) do
		local serial = row.name == name and type(row.metadata) == 'table' and row.metadata.serial
		if type(serial) == 'string' then serials[serial] = true end
	end
	return serials
end

-- The count an ammunition give uses when none is typed.
local function defaultAmmo()
	return math.floor(M.Bounded('INVENTORY.DEFAULT_AMMO', M.Section('INVENTORY').DEFAULT_AMMO,
		1, 100000, 60))
end

-- Gives a weapon and its ammunition together, both or neither. Yields.
local function giveWithAmmo(source, raw, event, target, who, playerId, entry, ammo, count)
	local both = locale('admin.inventory.pair', { label = entry.label, count = count,
		ammo = ammo.label })
	local bag, bagCode, bagReason = Inventory.Bag(target)
	if not bag then
		Inventory.Fail(source, raw, event, playerId, who, bagCode, bagReason)
		return false
	end

	-- Asked BEFORE anything is added, so the common refusal costs no write at
	-- all: a weapon is never stackable, so it always needs a slot of its own,
	-- and the ammunition needs one unless a plain stack of it is already there.
	local weight = bag.weight + (entry.weight or 0) + (ammo.weight or 0) * count
	local stacked = false
	for _, row in ipairs(bag.items) do
		if row.name == ammo.name and (row.metadata == nil or next(row.metadata) == nil) then
			stacked = true
		end
	end
	local code, reason
	if bag.maxWeight > 0 and weight > bag.maxWeight then
		code, reason = 'bag_too_heavy', 'too_heavy'
	elseif bag.slots - #bag.items < (stacked and 1 or 2) then
		code, reason = 'bag_no_room', 'no_room'
	else
		local carried
		carried, code, reason = Inventory.Carry(target, entry.name, 1, { ammo = 0 })
		if carried then carried, code, reason = Inventory.Carry(target, ammo.name, count) end
		if carried then code = nil end
	end
	if code then
		Inventory.Fail(source, raw, event, playerId, who, code, reason, { item = both })
		return false
	end

	local before = serialsOf(bag, entry.name)
	local contract = Server.Contract('inventory')
	local added, addCode, addReason = Inventory.Read(contract.AddItem(target, entry.name, 1,
		{ ammo = 0 }))
	if added == nil then
		Inventory.Fail(source, raw, event, playerId, who, addCode, addReason, { item = entry.label })
		return false
	end
	added, addCode, addReason = Inventory.Read(contract.AddItem(target, ammo.name, count))
	if added ~= nil then return true end

	-- The weapon is in and its ammunition was refused. It is taken back by the
	-- serial the bag did not carry a moment ago, so a weapon the holder already
	-- owned is never the one removed.
	local after = Inventory.Bag(target)
	local taken
	for _, row in ipairs(after and after.items or {}) do
		local serial = row.name == entry.name and type(row.metadata) == 'table' and row.metadata.serial
		if taken == nil and type(serial) == 'string' and not before[serial] then
			taken = Inventory.Take(target, entry.name, 1, row.metadata) and serial or false
		end
	end
	if not taken then
		audit(source, event, false, playerId, ('%s: %s given, %dx %s refused (%s), not taken back')
			:format(who, entry.name, count, ammo.name, tostring(addReason)))
		refuse(source, raw, 'give_partial', { label = entry.label, who = who, count = count,
			ammo = ammo.label, reason = addReason })
		return false
	end
	audit(source, event, false, playerId, ('%s taken back from %s: its ammunition was refused')
		:format(taken, who))
	Inventory.Fail(source, raw, event, playerId, who, addCode, addReason, { item = both })
	return false
end

-- Reads the catalogue, the named weapon and the bag, answering a failure. Yields.
local function weaponsInBag(source, raw, event, target, who, playerId, token)
	local index, code = Inventory.Catalog()
	if not index then return Inventory.Fail(source, raw, event, playerId, who, code) end
	local only
	if token ~= nil then
		only = Inventory.Weapon(index, token)
		if only == nil then
			return Inventory.Fail(source, raw, event, playerId, who, 'unknown_weapon',
				M.Trimmed(token, 48))
		end
	end
	local bag, bagCode, bagReason = Inventory.Bag(target)
	if not bag then return Inventory.Fail(source, raw, event, playerId, who, bagCode, bagReason) end
	return index, only, bag
end

--- Registers every weapon command.
-- @author dop42
function Weapons.Register()
	Server.Command(Command.WEAPON_GIVE, {
		help = 'admin.help.giveWeapon',
		params = { TARGET,
			{ name = 'weapon', help = 'admin.help.weaponName' },
			{ name = 'ammo', help = 'admin.help.giveAmmoName', optional = true },
			{ name = 'count', help = 'admin.help.giveAmmoCount', optional = true } },
		handler = function(source, args, raw)
			if M.Trimmed(args[2], 48) == nil then return refuse(source, raw, 'unknown_weapon') end
			local wanted = Inventory.Count(args[4], 1)
			if wanted == false then
				return refuse(source, raw, 'bad_count', { max = Inventory.MaxCount() })
			end
			local target, who, playerId = Inventory.Resolve(source, raw, args[1])
			if target == nil then return end
			Server.Heavy(source, raw, function()
				local event = 'admin.weapon.give'
				local index, code = Inventory.Catalog()
				if not index then return Inventory.Fail(source, raw, event, playerId, who, code) end
				local entry = Inventory.Weapon(index, args[2])
				if entry == nil then
					return Inventory.Fail(source, raw, event, playerId, who, 'unknown_weapon',
						M.Trimmed(args[2], 48))
				end

				local ammo
				if args[3] ~= nil then
					ammo = Inventory.Ammo(index, args[3])
					if ammo == nil then
						return Inventory.Fail(source, raw, event, playerId, who, 'unknown_ammo',
							M.Trimmed(args[3], 48), { item = M.Trimmed(args[3], 48) or '?' })
					end
				end
				local count = ammo ~= nil and (wanted or defaultAmmo()) or 0

				if ammo == nil then
					if not Inventory.Give(source, raw, event, target, who, playerId, entry.name, 1,
						{ ammo = 0 }, entry.label) then
						return
					end
				elseif not giveWithAmmo(source, raw, event, target, who, playerId, entry, ammo, count) then
					return
				end

				audit(source, event, true, playerId, ('%s to %s, %dx %s'):format(entry.name, who, count,
					ammo and ammo.name or '-'))
				inform(source, playerId, 'admin.toast.weapon', { label = entry.label }, 'success')
				if count > 0 then
					inform(source, playerId, 'admin.toast.itemGiven',
						{ count = count, label = ammo.label }, 'info')
				end
				answer(source, raw, true, ammo and 'admin.done.weaponGivenAmmo' or 'admin.done.weaponGiven',
					{ label = entry.label, who = who, count = count, ammo = ammo and ammo.label or '' })
			end)
		end,
	})

	Server.Command(Command.WEAPON_GIVEAMMO, {
		help = 'admin.help.giveAmmo',
		params = { TARGET,
			{ name = 'ammo', help = 'admin.help.ammoName' },
			{ name = 'count', help = 'admin.help.ammoCount', optional = true } },
		handler = function(source, args, raw)
			if M.Trimmed(args[2], 48) == nil then
				return refuse(source, raw, 'unknown_ammo', { item = '?' })
			end
			local typed = Inventory.Count(args[3], 1)
			if typed == false then
				return refuse(source, raw, 'bad_count', { max = Inventory.MaxCount() })
			end
			local target, who, playerId = Inventory.Resolve(source, raw, args[1])
			if target == nil then return end
			Server.Heavy(source, raw, function()
				local event = 'admin.weapon.giveammo'
				local index, code = Inventory.Catalog()
				if not index then return Inventory.Fail(source, raw, event, playerId, who, code) end
				local ammo = Inventory.Ammo(index, args[2])
				if ammo == nil then
					return Inventory.Fail(source, raw, event, playerId, who, 'unknown_ammo',
						M.Trimmed(args[2], 48), { item = M.Trimmed(args[2], 48) or '?' })
				end
				local count = typed or defaultAmmo()
				if not Inventory.Give(source, raw, event, target, who, playerId, ammo.name, count, nil,
					ammo.label) then
					return
				end
				audit(source, event, true, playerId, ('%dx %s to %s'):format(count, ammo.name, who))
				inform(source, playerId, 'admin.toast.itemGiven',
					{ count = count, label = ammo.label }, 'info')
				answer(source, raw, true, 'admin.done.ammoGiven',
					{ count = count, label = ammo.label, who = who })
			end)
		end,
	})

	Server.Command(Command.WEAPON_AMMO, {
		help = 'admin.help.ammo',
		params = { TARGET,
			{ name = 'ammo|all', help = 'admin.help.ammoOrAll', optional = true },
			{ name = 'count', help = 'admin.help.refillCount', optional = true } },
		handler = function(source, args, raw)
			local all = args[2] == nil or tostring(args[2]):lower() == 'all'
			local typed = Inventory.Count(args[3], 1)
			if typed == false then
				return refuse(source, raw, 'bad_count', { max = Inventory.MaxCount() })
			end
			local target, who, playerId = Inventory.Resolve(source, raw, args[1], 'admin.weapon.ammo')
			if target == nil then return end
			Server.Heavy(source, raw, function()
				local event = 'admin.weapon.ammo'
				local index, code = Inventory.Catalog()
				if not index then return Inventory.Fail(source, raw, event, playerId, who, code) end
				local only
				if not all then
					only = Inventory.Ammo(index, args[2])
					if only == nil then
						return Inventory.Fail(source, raw, event, playerId, who, 'unknown_ammo',
							M.Trimmed(args[2], 48), { item = M.Trimmed(args[2], 48) or '?' })
					end
				end
				local bag, bagCode, bagReason = Inventory.Bag(target)
				if not bag then
					return Inventory.Fail(source, raw, event, playerId, who, bagCode, bagReason)
				end

				-- What the holder already carries, so a refill tops up the rounds
				-- they use rather than handing out every calibre on the server.
				local types, seen = {}, {}
				if only ~= nil then
					types[1] = only
				else
					for _, row in ipairs(bag.items) do
						local entry = index.byName[row.name]
						if entry and entry.ammo and not seen[entry.name] then
							seen[entry.name] = true
							types[#types + 1] = entry
						end
					end
				end
				if #types == 0 then
					return answer(source, raw, false, 'admin.done.nothingToRefill', { who = who }, 'warning')
				end

				local count = typed or defaultAmmo()
				local given, failure = {}, nil
				for _, ammo in ipairs(types) do
					local added, addCode, addReason = Inventory.Add(target, ammo.name, count)
					if added then
						given[#given + 1] = ('%dx %s'):format(count, ammo.label)
						audit(source, event, true, playerId, ('%dx %s to %s'):format(count, ammo.name, who))
						inform(source, playerId, 'admin.toast.itemGiven',
							{ count = count, label = ammo.label }, 'info')
					else
						failure = failure or { code = addCode, reason = addReason, label = ammo.label }
					end
				end
				-- Both answers may go out: some calibres fitting and one not is a
				-- real outcome, and hiding either half would misreport it.
				if #given > 0 then
					answer(source, raw, true, 'admin.done.refilled',
						{ items = table.concat(given, ', '), who = who })
				end
				if failure then
					Inventory.Fail(source, raw, event, playerId, who, failure.code, failure.reason,
						{ item = failure.label })
				end
			end)
		end,
	})

	Server.Command(Command.WEAPON_REMOVE, {
		help = 'admin.help.removeWeapon',
		params = { TARGET, { name = 'weapon|all', help = 'admin.help.weaponOrAll' } },
		handler = function(source, args, raw)
			if M.Trimmed(args[2], 48) == nil then return refuse(source, raw, 'unknown_weapon') end
			local all = tostring(args[2]):lower() == 'all'
			local target, who, playerId = Inventory.Resolve(source, raw, args[1], 'admin.weapon.remove')
			if target == nil then return end
			Server.Heavy(source, raw, function()
				local event = 'admin.weapon.remove'
				local index, only, bag = weaponsInBag(source, raw, event, target, who, playerId,
					not all and args[2] or nil)
				if not bag then return end

				local counts, order = {}, {}
				for _, row in ipairs(bag.items) do
					local entry = index.byName[row.name]
					if entry and entry.weapon and (only == nil or only.name == entry.name) then
						if counts[row.name] == nil then order[#order + 1] = row.name end
						counts[row.name] = (counts[row.name] or 0) + row.count
					end
				end
				if #order == 0 then
					return answer(source, raw, false, 'admin.done.noWeapons', { who = who }, 'warning')
				end
				local removed, failure = 0, nil
				for _, name in ipairs(order) do
					local taken, takeCode, takeReason = Inventory.Take(target, name, counts[name])
					if taken then
						removed = removed + counts[name]
					else
						failure = { code = takeCode, reason = takeReason }
					end
				end
				-- `failure` is nil when nothing was even tried -- every stack counted
				-- zero -- and indexing it raised on this bare thread: no answer at all.
				if removed == 0 then
					return Inventory.Fail(source, raw, event, playerId, who,
						failure and failure.code or 'failed', failure and failure.reason or 'nothing taken')
				end
				audit(source, event, true, playerId, ('%d weapon(s) from %s%s'):format(removed, who,
					failure and (', then ' .. tostring(failure.reason)) or ''))
				inform(source, playerId, 'admin.toast.weaponsTaken', { count = removed }, 'warning')
				answer(source, raw, true, 'admin.done.weaponsRemoved', { count = removed, who = who })
			end)
		end,
	})

	Server.Command(Command.WEAPON_HOLSTER, {
		help = 'admin.help.holster',
		params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' } },
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1], 'admin.weapon.holster')
			if playerId == nil then return end
			-- THROUGH THE CONTRACT, never the engine slot directly: taking the slot
			-- behind the inventory's back would leave it believing the player is
			-- still armed, and its rounds would never be read back into the bag.
			local contract = Server.Contract('inventory')
			if contract == nil or type(contract.HolsterWeapon) ~= 'function' then
				audit(source, 'admin.weapon.holster', false, playerId, 'no holster on the contract')
				return refuse(source, raw, 'holster_unavailable', { id = playerId })
			end
			local ran, put = pcall(contract.HolsterWeapon, playerId)
			if not ran or type(put) ~= 'table' or put.ok ~= true then
				local code = ran and type(put) == 'table' and put.error or nil
				audit(source, 'admin.weapon.holster', false, playerId,
					tostring(ran and code or put))
				return refuse(source, raw, code == 'not_armed' and 'not_armed'
					or 'holster_unavailable', { id = playerId })
			end
			audit(source, 'admin.weapon.holster', true, playerId,
				tostring(type(put.value) == 'table' and put.value.name or '?'))
			answer(source, raw, true, 'admin.done.holstered', { id = playerId })
		end,
	})

	Server.Command(Command.WEAPON_READ, {
		help = 'admin.help.loadout', params = { TARGET }, read = true,
		handler = function(source, args, raw)
			local target, who, playerId = Inventory.Resolve(source, raw, args[1])
			if target == nil then return end
			Server.Heavy(source, raw, function()
				local index, _, bag = weaponsInBag(source, raw, 'admin.weapon.read', target, who, playerId)
				if not bag then return end
				local drawn
				if playerId ~= nil then
					local contract = Server.Contract('inventory')
					local read, held = pcall(contract.GetHeldWeapon, playerId)
					if read and type(held) == 'table' and type(held.serial) == 'string' then drawn = held end
				end
				local lines = { locale('admin.loadout.header', { who = who }) }
				for _, row in ipairs(bag.items) do
					local entry = index.byName[row.name]
					if entry and entry.weapon then
						local metadata = type(row.metadata) == 'table' and row.metadata or {}
						local serial = M.Trimmed(metadata.serial, 24) or '-'
						local rounds = metadata.ammo ~= nil and ('  ' .. locale('admin.inventory.rounds',
							{ rounds = OPX.Text.Integer(metadata.ammo) or 0 })) or ''
						local mark = drawn and metadata.serial == drawn.serial and
							('  ' .. locale('admin.loadout.drawn')) or ''
						lines[#lines + 1] = locale('admin.loadout.row', { slot = row.slot, label = entry.label,
							serial = serial, rounds = rounds, drawn = mark })
					end
				end
				if #lines == 1 then lines[2] = locale('admin.loadout.empty') end
				answer(source, raw, true, 'admin.text.lines', { lines = table.concat(lines, '\n') })
			end)
		end,
	})
end
